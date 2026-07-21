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
    /// live via `applyMeasurementSettings`. `nil` ⇒ the user has never saved one, so the engine
    /// skips the vital enable commands (the ring's own settings are the source of truth).
    private var measurementSettings: MeasurementSettings?

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
        // Enable vital monitoring only when the user has configured it (mirrors the vendor app's
        // connect flow). Uses the user's polling interval for all vital types — the CRP protocol
        // takes a single interval byte per enable command, and MeasurementSettings only exposes
        // hrIntervalMinutes (no per-vital intervals), so we share it across the board.
        if let settings = measurementSettings {
            if settings.hrEnabled { send(CRPProtocol.enableTimingHeartRate(intervalMinutes: settings.hrIntervalMinutes)) }
            if settings.hrvEnabled { send(CRPProtocol.enableTimingHRV(intervalMinutes: settings.hrIntervalMinutes)) }
            if settings.stressEnabled { send(CRPProtocol.enableTimingStress(intervalMinutes: settings.hrIntervalMinutes)) }
            if settings.spo2Enabled { send(CRPProtocol.enableTimingSpO2(intervalMinutes: settings.hrIntervalMinutes)) }
            if settings.temperatureEnabled { send(CRPProtocol.enableTimingTemp()) }
        }
    }

    func handle(_ event: RingDecodedEvent) {
        // Steps/HR/battery are persisted by RingBLEClient via RingEventBridge; v1 keeps no engine-side
        // state (no staged history pipeline to advance).
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
        // Re-send vital enable/disable commands with the updated settings.
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
