import Foundation

/// Nights before today to pull once per connection. See `CRPSyncEngine.sendSleepBackfill`.
private let crpSleepBackfillDays = 6

/// Per-connection orchestration for a CRP ("crrepa") ring. Ported in spirit from the Moyoung
/// "Da Rings" connect flow (`d1/b.java` + `b1` package builders): after the link is up the app sets
/// the clock and pushes user anthropometrics, then the ring streams current steps (`fdd1`) on its own
/// and answers measurement commands.
///
/// Scope: clock + user-info handshake, spot HR + SpO2 (Measure button), all-day vital timing
/// enable/disable driven by `MeasurementSettings`, find-device. Steps and battery arrive as
/// autonomous pushes/reads (see `CRPDriver`). HRV / stress / temperature are all-day metrics — their
/// timing is enabled here and live results decode via `CRPDecoder`. Of the stored day timelines,
/// sleep (group-2/cmd-14) is decoded (`CRPDecoder.decodeSleep`, confirmed against a hardware
/// capture), and the group-2 all-day "timing" vital histories (HR/SpO2/HRV/stress) decode into
/// `.historyMeasurement` samples; their multi-frame replies reassemble via the next-frame follow-up
/// in `handle`.
///
/// Factory reset / power off: the CRP command (`CRPProtocol.factoryReset`, group 3 / cmd 0) is known,
/// but iOS's `RingSyncEngine` exposes no factory-reset/power-off hook (the Colmi encoder has the
/// opcodes too, with no invocation path), so there is nothing to wire it into here — which is why
/// `CRPCoordinator` doesn't claim `.factoryReset` even though the Android coordinator does.
@MainActor
final class CRPSyncEngine: RingSyncEngine {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private var profile: UserProfileValues?

    /// User-chosen all-day measurement config. Applied in the connect handshake and updatable
    /// live via `applyMeasurementSettings`. `nil` ⇒ the user has never saved one, and a fresh R11
    /// ships with every all-day monitor OFF, so it records nothing to sync. We therefore fall back to
    /// `MeasurementSettings.allOnDefault` (matching how `ColmiSyncEngine` force-enables on connect)
    /// so the day timeline actually accumulates.
    ///
    /// Note this is a *forced* default, not a read-back: `sendConnectionReadBacks` now asks the ring
    /// for each monitor's current interval, but the replies are only surfaced as diagnostics — we
    /// still impose a config rather than adopting the ring's. Matching the vendor here (query state,
    /// apply the saved config, leave the ring alone otherwise) is a known open divergence on both
    /// platforms; it needs the read-back replies confirmed against hardware first.
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
        // The 23-sends/0-replies in the 2026-07-25 capture were our fault, not the ring's: the old
        // opcode was group 7 cmd 1, which the vendor SDK uses for `querySavedGomoreKey`, not
        // firmware. The real query is group 3 cmd 3 (`b1/l.k` → `d1/b.queryFirmwareVersion`), and it
        // answers with a UTF-8 string — `MOY-R1K3-2.1.6` on zaggash's R11.
        send(CRPProtocol.queryFirmwareVersion())
        if let profile { send(userInfoFrame(profile)) }
        sendConnectionReadBacks()
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

    /// Whether this connection's read-backs have been sent. A fresh `CRPSyncEngine` is built per
    /// connection (`RingBLEClient.installDriver` calls `driver.makeSyncEngine()` on connect), so
    /// instance state gives "once per connection" for free.
    private var readBacksSent = false

    /// Ask the ring to describe itself, once per connection.
    ///
    /// `querySupportSpO2Type` answers NOT_SUPPORT / SLEEP_OXYGEN / TIMING_OXYGEN; the timing-state
    /// queries report each all-day monitor's configured interval (0 = off). Together they are the
    /// evidence base for whether a silent history query means "the monitor is off" or "this ring
    /// lacks the sensor" — stress (`2/47`), temperature (`2/22`) and firmware (formerly `7/1`) all
    /// went unanswered on zaggash's ring, and these replies are how we tell those apart next capture.
    ///
    /// Deliberately **not** part of the poll pass. `runStartup` doubles as the background re-sync,
    /// but what a ring supports cannot change between syncs. Re-asking would add six writes to every
    /// pass on a ring that funnels the handshake, timing config, history pull *and* on-demand
    /// measures through the single `fdd2` channel — and a spot SpO2 needs ~48 s of that channel to
    /// return a reading.
    ///
    /// **Call order matters: this must run BEFORE `applyTimingSettings`.** The state queries report
    /// each monitor's *current* interval, and `applyTimingSettings` force-enables everything moments
    /// later. Ask afterwards and every reply describes the state we just imposed, which answers
    /// nothing — the whole point is to learn whether stress and temperature were silent because their
    /// monitor was off. `CRPSyncEngineTests` pins the ordering; if that assertion ever fails, fix the
    /// call site rather than the expectation.
    private func sendConnectionReadBacks() {
        if readBacksSent { return }
        readBacksSent = true
        send(CRPProtocol.querySupportSpO2Type())
        send(CRPProtocol.queryTimingHeartRateState())
        send(CRPProtocol.queryTimingHrvState())
        send(CRPProtocol.queryTimingSpO2State())
        send(CRPProtocol.queryTimingStressState())
        send(CRPProtocol.queryTimingTempState())
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
        sendSleepBackfill()
    }

    /// Whether this connection has already backfilled older nights. Same "fresh engine per
    /// connection" trick as `readBacksSent`.
    private var sleepBackfillSent = false

    /// Pull the nights *before* today, once per connection.
    ///
    /// The poll pass above only ever asks for `daysAgo = 0`, so the app's stored history could only
    /// ever grow one night at a time from whenever the user installed. Asking for the ring's own
    /// back-catalogue is what actually restores a user's history.
    ///
    /// Safe to send blind. Each reply is self-describing: `payload[0]` is the ring's own day index,
    /// so `CRPDecoder.decodeSleep` dates a night from the reply rather than from what we asked for,
    /// and a day the ring has no record of simply produces no reply — the same nothing we get today.
    ///
    /// Once per connection, and deliberately short of the decoder's 14-day ceiling: `runStartup` is
    /// also the background sync, and this ring funnels the handshake, timing config, history pull
    /// *and* on-demand measures through one `fdd2` channel (a spot SpO2 needs ~48 s of it). A week is
    /// the useful-recovery/quiet-channel trade; raise it once hardware shows the ring answers deeper.
    private func sendSleepBackfill() {
        if sleepBackfillSent { return }
        sleepBackfillSent = true
        for daysAgo in 1...crpSleepBackfillDays { send(CRPProtocol.queryHistorySleep(daysAgo: daysAgo)) }
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
    /// Takes a non-optional `MeasurementSettings` because that is `RingSyncEngine`'s requirement.
    /// It used to take `MeasurementSettings?`, which is a *different* signature — so it satisfied
    /// nothing, the protocol's no-op default extension supplied conformance instead, and every
    /// `RingSyncCoordinator` call landed there. The user's saved config was silently discarded and
    /// `runStartup` always fell back to `.allOnDefault`.
    func setMeasurementSettings(_ settings: MeasurementSettings) {
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
