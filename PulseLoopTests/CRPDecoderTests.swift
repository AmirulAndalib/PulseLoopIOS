import XCTest
import CoreBluetooth
@testable import PulseLoop

/// Unit tests for CRP inbound decoding + reassembly (`CRPDecoder`, `CRPFrameAssembler`) and the
/// `CRPDriver.ingest` routing. Byte layouts are from the decompiled Moyoung app (`e1/k.b` steps,
/// `e1/f.b` HR, `g1/a.k` frame reassembly). No BLE stack needed. Ported from the Android app's
/// `CRPDecoderTest.kt`.
@MainActor
final class CRPDecoderTests: XCTestCase {

    private let fdd1 = CRPUUIDs.stepsNotifyCBUUID
    private let fdd3 = CRPUUIDs.cmdNotifyCBUUID

    // MARK: - Steps

    func testCurrentStepsPushDecodesLittleEndianStepsDistanceCalories() {
        // steps=1000 (E8 03 00), distance=500 (F4 01 00), calories=42 (2A 00 00)
        let data = Data([0xE8, 0x03, 0x00, 0xF4, 0x01, 0x00, 0x2A, 0x00, 0x00])
        let events = CRPDecoder.decode(data, from: fdd1)
        XCTAssertEqual(events.count, 1)
        guard case let .activityUpdate(_, steps, distanceMeters, calories) = events[0] else {
            return XCTFail("expected activityUpdate, got \(events[0])")
        }
        XCTAssertEqual(steps, 1000)
        XCTAssertEqual(distanceMeters, 500)
        XCTAssertEqual(calories, 42)
    }

    func testStepsPushWithOnlyTheStepTripleDecodesDistanceAndCaloriesZero() {
        guard case let .activityUpdate(_, steps, distanceMeters, calories) =
                CRPDecoder.decode(Data([0x0A, 0x00, 0x00]), from: fdd1)[0] else {
            return XCTFail("expected activityUpdate")
        }
        XCTAssertEqual(steps, 10)
        XCTAssertEqual(distanceMeters, 0)
        XCTAssertEqual(calories, 0)
    }

    func testStepsPushOfNonMultipleOfThreeLengthIsRejected() {
        XCTAssertTrue(CRPDecoder.decode(Data([1, 2]), from: fdd1).isEmpty)
    }

    // MARK: - Assembler

    func testAssemblerReturnsASinglePacketFrameImmediately() {
        let a = CRPFrameAssembler()
        let frame = CRPProtocol.frame(group: 1, cmd: 9, payload: [0x50]) // len 7
        XCTAssertEqual(a.append(frame), frame)
    }

    func testAssemblerReassemblesAFrameSplitAcrossTwoNotifications() {
        let a = CRPFrameAssembler()
        // A 10-byte frame: FD DA 10 0A 02 05 + 4 payload bytes, delivered as 6 + 4.
        let full = CRPProtocol.frame(group: 2, cmd: 5, payload: [1, 2, 3, 4]) // size 10
        XCTAssertNil(a.append(Data(full.prefix(6))))          // header only — not complete
        let done = a.append(Data(full.suffix(4)))             // continuation completes it
        XCTAssertEqual(done, full)
    }

    func testAssemblerDropsAContinuationWithNoInProgressFrame() {
        let a = CRPFrameAssembler()
        XCTAssertNil(a.append(Data([1, 2, 3, 4])))
    }

    // MARK: - Vital result decoding (group 1, real-time)

    func testGroup1Cmd9DecodesHeartRateBpm() {
        // HR response: group1/cmd9, payload[0]=74 (0x4A) → 74 bpm
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdMeasureHR, payload: [0x4A])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .heartRateSample(bpm, _) = events[0] else {
            return XCTFail("expected heartRateSample, got \(events[0])")
        }
        XCTAssertEqual(bpm, 74)
    }

    func testGroup1Cmd9HeartRateBelowPlausibilityThresholdDropped() {
        // bpm=30 is below the 40..200 guard.
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdMeasureHR, payload: [0x1E])
        XCTAssertTrue(CRPDecoder.decode(frame, from: fdd3).isEmpty)
    }

    func testGroup1Cmd9HeartRateAbovePlausibilityThresholdDropped() {
        // bpm=250 is above the 40..200 guard.
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdMeasureHR, payload: [0xFA])
        XCTAssertTrue(CRPDecoder.decode(frame, from: fdd3).isEmpty)
    }

    func testGroup1Cmd10DecodesHRV() {
        // HRV response: group1/cmd10, payload[0]=45 → 45 ms
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdEnableTimingHRV, payload: [0x2D])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .hrvSample(value, _) = events[0] else {
            return XCTFail("expected hrvSample, got \(events[0])")
        }
        XCTAssertEqual(value, 45)
    }

    func testGroup1Cmd11DecodesSpO2() {
        // SpO2 response: group1/cmd11, payload[0]=96 → 96%
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdEnableTimingSpO2, payload: [0x60])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .spo2Result(value, _) = events[0] else {
            return XCTFail("expected spo2Result, got \(events[0])")
        }
        XCTAssertEqual(value, 96)
    }

    func testGroup1Cmd14DecodesStress() {
        // Stress response: group1/cmd14, payload[0]=42 → stress 42
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdEnableTimingStress, payload: [0x2A])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .stressSample(value, _) = events[0] else {
            return XCTFail("expected stressSample, got \(events[0])")
        }
        XCTAssertEqual(value, 42)
    }

    func testGroup1Cmd32DecodesTemperature() {
        // Temp response: group1/cmd32, payload[0]=38 → 38 °C (placeholder layout)
        let frame = CRPProtocol.frame(group: 1, cmd: CRPCommands.cmdEnableTimingTemp, payload: [0x26])
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case let .temperatureSample(celsius, _) = events[0] else {
            return XCTFail("expected temperatureSample, got \(events[0])")
        }
        XCTAssertEqual(celsius, 38.0)
    }

    func testGroup1UnknownCmdReturnsCommandAck() {
        // Unknown cmd in group 1 → ack, not a fabricated metric.
        let frame = CRPProtocol.frame(group: 1, cmd: 99)
        let events = CRPDecoder.decode(frame, from: fdd3)
        XCTAssertEqual(events.count, 1)
        guard case .commandAck = events[0] else {
            return XCTFail("expected commandAck, got \(events[0])")
        }
    }

    // MARK: - Driver routing

    func testDriverRoutesFdd1ToStepsAndReassemblesFdd3Replies() {
        let driver = CRPDriver(writer: nil)
        let steps = driver.ingest(Data([0x05, 0x00, 0x00]), from: fdd1)
        XCTAssertEqual(steps.count, 1)
        guard case .activityUpdate = steps[0] else { return XCTFail("expected activityUpdate") }

        // A framed reply split across two fdd3 notifications yields exactly one decoded event.
        let full = CRPProtocol.frame(group: 1, cmd: 9, payload: [0x50]) // size 7
        XCTAssertTrue(driver.ingest(Data(full.prefix(4)), from: fdd3).isEmpty)
        XCTAssertEqual(driver.ingest(Data(full.suffix(3)), from: fdd3).count, 1)
    }
}
