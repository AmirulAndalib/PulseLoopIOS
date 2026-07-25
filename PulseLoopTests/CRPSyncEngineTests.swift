import XCTest
@testable import PulseLoop

/// Unit tests for `CRPSyncEngine` — the connect handshake and interactive commands enqueue the right
/// CRP frames. Mirrors the vendor's connect flow (set clock, then user info). Ported from the Android
/// app's `CRPSyncEngineTest.kt`, adapted to iOS's `UserProfileValues` initializer.
@MainActor
final class CRPSyncEngineTests: XCTestCase {
    private final class FakeWriter: RingCommandWriter {
        nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)
        var sent: [Data] = []
        func enqueue(_ command: Data) { sent.append(command) }
        /// (group, cmd) of each written frame.
        var opcodes: [[Int]] { sent.map { let b = [UInt8]($0); return [Int(b[4]), Int(b[5])] } }
        func payloadByte(_ frame: Int, _ index: Int) -> Int { Int([UInt8](sent[frame])[index]) }
    }

    /// The connect handshake's leading commands, in order: set-time, firmware query, then user info
    /// once a profile exists. Everything after that is the all-day timing config plus the history
    /// pull, covered by their own tests below.
    func testRunStartupSendsSetTimeThenUserInfoOnceAProfileIsStored() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        // set-time, then the firmware query that keeps the UI off "Firmware: reading".
        XCTAssertEqual(Array(w.opcodes.prefix(2)), [[1, 1], [7, 1]])

        w.sent.removeAll()
        engine.setUserProfile(UserProfileValues(metric: true, sex: "male", age: 30, heightCm: 180, weightKg: 75))
        engine.runStartup()
        XCTAssertEqual(Array(w.opcodes.prefix(3)), [[1, 1], [7, 1], [1, 0]])
    }

    func testHeartRateStartAndStopEnqueueGroup1Cmd9() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.startHeartRate()
        engine.stopHeartRate()
        XCTAssertEqual(w.opcodes, [[1, 9], [1, 9]])
        XCTAssertEqual(w.payloadByte(0, 6), 1)   // enable
        XCTAssertEqual(w.payloadByte(1, 6), 0)   // disable
    }

    func testFindDeviceEnqueuesItsCommand() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.findDevice()
        XCTAssertEqual(w.opcodes, [[9, 2]])
    }

    func testApplyUserProfilePushesUserInfoImmediately() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.applyUserProfile(UserProfileValues(metric: true, sex: "female", age: 25, heightCm: 165, weightKg: 60))
        XCTAssertEqual(w.opcodes, [[1, 0]])
        // height passes through; stride is estimated as ~0.43*height.
        XCTAssertEqual(w.payloadByte(0, 6), 165)
        XCTAssertEqual(w.payloadByte(0, 10), Int(165.0 * 0.43))   // 70
    }

    // MARK: - All-day monitoring + history pull

    /// A fresh R11 ships with every all-day monitor OFF and cannot be asked what its config is, so
    /// connecting without a saved config must still force them on — otherwise the ring records
    /// nothing and every history query comes back empty (Android issue #29).
    func testRunStartupForcesAllDayMonitoringOnWithoutASavedConfig() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        // Enable-timing opcodes are group 1: HR 6, HRV 7, SpO2 8, stress 39, temp 13.
        for cmd in [6, 7, 8, 39, 13] {
            XCTAssertTrue(w.opcodes.contains([1, cmd]), "expected all-day enable for group1/cmd\(cmd)")
        }
    }

    /// The history pull uses the group-2 opcodes. The old group-7 ones were the device-info group
    /// and the ring answered every one of them empty.
    func testRunStartupQueriesHistoryOnGroupTwo() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        for cmd in [15, 17, 16, 47, 48, 14] {   // HR, SpO2, HRV, stress, temp, sleep
            XCTAssertTrue(w.opcodes.contains([2, cmd]), "expected group2/cmd\(cmd) history query")
        }
        XCTAssertFalse(w.opcodes.contains { $0[0] == 7 && $0[1] != 1 },
                       "group 7 should carry only the firmware query now")
    }

    /// Each timing query starts at frame 0 of today.
    func testHistoryQueriesStartAtTodayFrameZero() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        guard let index = w.opcodes.firstIndex(of: [2, 15]) else { return XCTFail("no HR history query") }
        XCTAssertEqual(w.payloadByte(index, 6), 0)   // day = today
        XCTAssertEqual(w.payloadByte(index, 7), 0)   // frameIndex = 0
    }

    /// A frame below the vital's terminal index pulls the next one — the vendor's sequential
    /// `insertBleMessage(<query>.b(day, index + 1))`.
    func testTimingFrameBelowTerminalIndexRequestsTheNextFrame() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        XCTAssertEqual(w.opcodes, [[2, 15]])
        XCTAssertEqual(w.payloadByte(0, 7), 1, "should ask for frame 1")
    }

    /// HR/SpO2/stress finish at frame 1 (two 144-slot frames); HRV runs to frame 3 (four 72-slot).
    func testTerminalFrameIndexEndsTheWalkPerVital() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()

        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 1))
        XCTAssertTrue(w.sent.isEmpty, "HR terminates at frame 1")

        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 16, day: 0, frameIndex: 1))
        XCTAssertEqual(w.opcodes, [[2, 16]], "HRV continues past frame 1")

        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 16, day: 0, frameIndex: 3))
        XCTAssertTrue(w.sent.isEmpty, "HRV terminates at frame 3")
    }

    /// A ring that re-sends the same frame must not trigger a request storm.
    func testDuplicateFrameDoesNotRequestTwice() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        XCTAssertEqual(w.sent.count, 1)
    }

    /// Each sync pass re-pulls the whole timeline, so the dedupe guard resets on every startup.
    func testFollowUpGuardResetsEachSyncPass() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        engine.runStartup()
        w.sent.removeAll()
        engine.handle(.timingHistoryFrame(cmd: 15, day: 0, frameIndex: 0))
        XCTAssertEqual(w.sent.count, 1, "a new pass may re-request frame 1")
    }

    /// A non-timing event must not be mistaken for a history cursor.
    func testNonTimingEventsAreIgnoredByHandle() {
        let w = FakeWriter()
        let engine = CRPSyncEngine(writer: w)
        engine.runStartup()
        w.sent.removeAll()
        engine.handle(.heartRateSample(bpm: 60, timestamp: Date()))
        engine.handle(.wearingStatus(worn: false, timestamp: Date()))
        XCTAssertTrue(w.sent.isEmpty)
    }
}
