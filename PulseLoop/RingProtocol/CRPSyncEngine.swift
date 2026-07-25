import Foundation

/// Per-connection orchestration for a CRP ("crrepa") ring. Ported in spirit from the Moyoung
/// "Da Rings" connect flow (`d1/b.java` + `b1` package builders): after the link is up the app sets
/// the clock and pushes user anthropometrics, then the ring streams current steps (`fdd1`) on its own
/// and answers measurement commands. There is no bulk history state machine in v1, so most of the
/// `RingSyncEngine` surface is left as the protocol's no-op defaults.
///
/// v1 scope: clock + user-info handshake, live/manual heart rate, find-device, factory reset.
/// Steps and battery arrive as autonomous pushes/reads (see `CRPDriver`) and need no command here.
/// Sleep / SpO2 / HRV / stress / temperature and history sync are deliberately deferred — their
/// reply layouts aren't yet confirmed against the decompile, and `CRPCoordinator` doesn't advertise
/// those capabilities, so nothing calls the corresponding methods.
///
/// Factory reset / power off: the CRP command (`CRPProtocol.factoryReset`, group 3 / cmd 0) is known,
/// but iOS's `RingSyncEngine` exposes no factory-reset/power-off hook (the Colmi encoder has the
/// opcodes too, with no invocation path), so there is nothing to wire it into here — matching the
/// Android `CRPSyncEngine`, whose `factoryReset()` this port intentionally does not surface as a
/// capability.
@MainActor
final class CRPSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private var profile: UserProfileValues?

    /// User-chosen all-day measurement config. Applied in the connect handshake and updatable
    /// live via `applyMeasurementSettings`. `nil` ⇒ the user has never saved one; unlike QRing/YCBT
    /// the CRP ring exposes no way to read back its own config, so a fresh R11 ships with every
    /// all-day monitor OFF and never records anything to sync. We therefore fall back to
    /// `MeasurementSettings.allOnDefault` (matching how `ColmiSyncEngine` force-enables on connect)
    /// so the day timeline actually accumulates.
    private var measurementSettings: MeasurementSettings?

    /// Frame follow-ups already requested this poll pass, keyed `cmd * 100 + frameIndex`, so a ring
    /// that re-sends the same frame can't trigger a request storm. Cleared at the start of every
    /// `queryAllHistory` pass so each sync re-pulls the full timeline.
    private var requestedTimingFrames: Set<Int> = []

    init(writer: RingCommandWriter?) {
        self.writer = writer
    }

    func runStartup() {
        // Set the device clock first (matches the vendor's connect handshake), then user info so
        // the ring's step/calorie algorithm has real inputs.
        send(CRPProtocol.setTime())
        // Query firmware version so the UI doesn't show "Firmware: reading" (zaggash's report).
        send(CRPProtocol.queryFirmwareVersion())
        if let profile { send(userInfoFrame(profile)) }
        // Enable all-day vital monitoring. A fresh ring has these OFF, so without this the ring
        // stores no HR/SpO2/HRV/stress/temperature history and every history query below returns an
        // empty reply (Android issue #29, zaggash's full-day capture). When the user has saved a
        // config we honour it exactly (interval included); until then we fall back to allOnDefault.
        applyTimingSettings(measurementSettings ?? .allOnDefault)
        // Pull the day's stored all-day timeline. runStartup() IS the poll pass (the background sync
        // and a foreground sync both re-invoke it), so this runs at the app's configured cadence; the
        // ring samples at hrIntervalMinutes (above). The ring only emits history replies once asked.
        queryAllHistory()
    }

    /// Request the stored all-day timelines the ring has accumulated: the group-2 "timing" vital
    /// timelines (HR/SpO2/HRV/stress), temperature, and sleep. Vendor `u3/g1.java` fires the same set
    /// on its sync pass. Each timing query pulls frame 0; the reply drives `handle` to pull the next
    /// frame until the day is complete.
    private func queryAllHistory() {
        requestedTimingFrames.removeAll()
        send(CRPProtocol.queryTimingHeartRateHistory())
        send(CRPProtocol.queryTimingSpO2History())
        send(CRPProtocol.queryTimingHrvHistory())
        send(CRPProtocol.queryTimingStressHistory())
        send(CRPProtocol.queryHistoryTemp())
        send(CRPProtocol.queryHistorySleep())
    }

    /// The last frame index each timing vital emits before its day is complete (vendor terminal
    /// index: HR/SpO2/stress finalize at frame 1 — two 144-slot frames; HRV at frame 3 — four
    /// 72-slot frames). A reply below this index triggers a pull of the next frame.
    private func terminalFrameIndex(cmd: Int) -> Int {
        cmd == CRPCommands.cmdQueryTimingHRV ? 3 : 1
    }

    /// Build the next-frame query for a timing vital, or `nil` for a non-timing cmd.
    private func timingQuery(cmd: Int, day: Int, frameIndex: Int) -> Data? {
        switch cmd {
        case CRPCommands.cmdQueryTimingHR:
            return CRPProtocol.queryTimingHeartRateHistory(day: day, frameIndex: frameIndex)
        case CRPCommands.cmdQueryTimingHRV:
            return CRPProtocol.queryTimingHrvHistory(day: day, frameIndex: frameIndex)
        case CRPCommands.cmdQueryTimingSpO2:
            return CRPProtocol.queryTimingSpO2History(day: day, frameIndex: frameIndex)
        case CRPCommands.cmdQueryTimingStress:
            return CRPProtocol.queryTimingStressHistory(day: day, frameIndex: frameIndex)
        default:
            return nil
        }
    }

    func handle(_ event: RingDecodedEvent) {
        // Steps/HR/battery are persisted by RingBLEClient via RingEventBridge. The one piece of
        // engine-side state is the all-day timeline's multi-frame pull: on each timing-history frame
        // the ring returns, request the next frame until the vital's terminal index — the vendor's
        // sequential `insertBleMessage(<query>.b(day, index + 1))` (`e1/{f,d,g,l}.java`). The samples
        // themselves are decoded + persisted via the bridge; this only advances the cursor.
        guard case let .timingHistoryFrame(cmd, day, frameIndex) = event else { return }
        if frameIndex >= terminalFrameIndex(cmd: cmd) { return }
        let nextIndex = frameIndex + 1
        // Guard against a ring that re-sends the same frame spamming duplicate follow-ups.
        guard requestedTimingFrames.insert(cmd * 100 + nextIndex).inserted else { return }
        send(timingQuery(cmd: cmd, day: day, frameIndex: nextIndex))
    }

    // MARK: - Heart rate (standard 2a37 stream, started/stopped via the fdda command channel)
    func startHeartRate() { send(CRPProtocol.measureHeartRate(true)) }
    func stopHeartRate() { send(CRPProtocol.measureHeartRate(false)) }

    // MARK: - SpO2 (command verified; result parsing deferred, so capability isn't advertised)
    func startSpO2() { send(CRPProtocol.measureSpO2(true)) }
    func stopSpO2() { send(CRPProtocol.measureSpO2(false)) }

    func findDevice() { send(CRPProtocol.findDevice(true)) }

    func setGoal(steps: Int) {
        // Step-goal command layout not yet confirmed from the decompile; no-op for now.
    }

    // MARK: - User profile
    func setUserProfile(_ profile: UserProfileValues) { self.profile = profile }

    func applyUserProfile(_ profile: UserProfileValues) {
        self.profile = profile
        send(userInfoFrame(profile))
    }

    // MARK: - Measurement settings
    func setMeasurementSettings(_ settings: MeasurementSettings?) {
        measurementSettings = settings
    }

    func applyMeasurementSettings(_ settings: MeasurementSettings) {
        measurementSettings = settings
        applyTimingSettings(settings)
    }

    /// Send the all-day enable/disable command for every vital. The CRP protocol takes a single
    /// interval byte per enable, and `MeasurementSettings` carries only `hrIntervalMinutes` (no
    /// per-vital cadence), so the HR interval is shared across the board. Disabled vitals are
    /// explicitly turned off so a reconnect can't leave a previously-enabled monitor running.
    private func applyTimingSettings(_ settings: MeasurementSettings) {
        if settings.hrEnabled { send(CRPProtocol.enableTimingHeartRate(intervalMinutes: settings.hrIntervalMinutes)) }
        else { send(CRPProtocol.disableTimingHeartRate()) }
        if settings.hrvEnabled { send(CRPProtocol.enableTimingHRV(intervalMinutes: settings.hrIntervalMinutes)) }
        else { send(CRPProtocol.disableTimingHRV()) }
        if settings.stressEnabled { send(CRPProtocol.enableTimingStress(intervalMinutes: settings.hrIntervalMinutes)) }
        else { send(CRPProtocol.disableTimingStress()) }
        if settings.spo2Enabled { send(CRPProtocol.enableTimingSpO2(intervalMinutes: settings.hrIntervalMinutes)) }
        else { send(CRPProtocol.disableTimingSpO2()) }
        if settings.temperatureEnabled { send(CRPProtocol.enableTimingTemp()) }
        else { send(CRPProtocol.disableTimingTemp()) }
    }

    func resyncTime() { send(CRPProtocol.setTime()) }

    /// Map the app's `UserProfileValues` onto the CRP user-info payload. Stride length isn't carried
    /// by the profile, so estimate it from height (~0.43·height, a common default).
    private func userInfoFrame(_ p: UserProfileValues) -> Data {
        let heightCm = Int(p.heightCm)
        let strideCm = min(255, max(0, Int(Double(heightCm) * 0.43)))
        return CRPProtocol.setUserInfo(
            heightCm: heightCm,
            weightKg: Int(p.weightKg),
            ageYears: Int(p.age),
            gender: Int(p.gender),
            strideCm: strideCm
        )
    }

    private func send(_ frame: Data?) {
        if let frame { writer?.enqueue(frame) }
    }
}
