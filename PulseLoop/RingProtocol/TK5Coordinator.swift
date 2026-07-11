import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for the TK5 ring (SmartHealth app). Declares the capabilities we can actually decode
/// and recognizes the device from its advertisement.
///
/// The *protocol* is not TK5-specific — the ring speaks YCBT, so the driver, encoder, decoder and sync
/// engine it builds are the shared `YCBT*` types. This file is the whole of what makes a TK5 a TK5:
/// its advertised identity and its capability set.
///
/// Recognition is name-first: the TK5's proprietary `be940000` service is **not advertised** (only
/// standard Heart Rate + a generic `FEE7` service are), so the reliable signal is the `TK5 …` local
/// name, backed up by the manufacturer-data prefix observed in the nRF capture.
@MainActor
final class TK5Coordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .tk5

    /// Manufacturer-data prefix from the capture (`10786501…`, company 0x7810). The trailing bytes are
    /// device-specific (they echo the name suffix), so only the prefix is matched.
    private static let manufacturerHexPrefix = "10786501"

    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        if let name, name.uppercased().hasPrefix("TK5") { return true }
        if WearableModel.model(advertisedName: name)?.family == .tk5 { return true }
        if let mfg = advertisement.manufacturerData, mfg.hexString.hasPrefix(manufacturerHexPrefix) {
            return true
        }
        return false
    }

    /// Everything the ring stores and `YCBTHealthRecords` decodes: live + history HR, SpO₂ (live *and*
    /// the all-day `05 1A` log), day steps, HRV, blood pressure, temperature, blood sugar, the
    /// deep/light/REM sleep timeline, and the in-band battery.
    ///
    /// **Stress and fatigue are ring-stored, not app-derived**: the body-data record (`05 33`) carries
    /// them as the SDK's `pressure` and `body` fields, alongside VO₂max and the HRV frequency-domain
    /// metrics. Temperature likewise has both a dedicated log (`05 1E`) and a field in the All record.
    ///
    /// `manualHeartRate` / `manualSpo2` / `manualHrv` / `manualBloodPressure` surface the "Measure now"
    /// buttons in Vitals: a spot reading toggles the live `03 2f` stream on in the metric's own mode,
    /// collects the first good sample from the `06 01` (HR) / `06 02` (SpO₂) / `06 03` (BP *and* HRV)
    /// frames, then toggles the same mode off. All four ride the one stream, so any of them can be
    /// measured on demand — one at a time.
    ///
    /// `measurementInterval` surfaces the Measurement-settings screen: the ring's five `01 xx
    /// {enable, interval}` monitors map 1:1 onto it (HR `01 0C`, BP `01 1C`, temperature `01 20`,
    /// SpO₂ `01 26`, HRV `01 45`), and the interval is floored at the firmware's 30-minute minimum.
    ///
    /// This is the *decodable* set, not a per-unit truth: firmware variants differ, and which history
    /// types actually return records is what the on-device checkpoint establishes (which is also why
    /// `supportLevel` stays `.limited` — see `docs/hardware/tk5.md`).
    let capabilities: Set<WearableCapability> = [
        .heartRate, .spo2, .spo2History, .steps, .battery, .hrv, .bloodPressure,
        .temperature, .stress, .fatigue, .bloodSugar,
        .sleep, .remSleep,
        .manualHeartRate, .manualSpo2, .manualHrv, .manualBloodPressure,
        .realtimeHeartRate, .realtimeSteps,
        .findDevice, .measurementInterval,
    ]

    /// The TK5 keeps its static set: nothing above is bitmap-gated, so its `02 01` reply can neither add
    /// nor remove a capability. That is deliberate — there is one TK5 SKU and it is the ring we have on
    /// the bench, so gating it would trade a known-good capability set for a runtime dependency on a
    /// parser no hardware had yet exercised.
    ///
    /// The handshake still *requests* the bitmap and `YCBTSupportFunction` still parses it, so every TK5
    /// session prints the decoded claim to the debug feed. That is the point: it validates the bit table
    /// against real hardware, at zero behavioural risk, before the Colmi family — whose SKUs genuinely
    /// differ on which sensors they carry — starts depending on it.
    let bitmapGatedCapabilities: Set<WearableCapability> = []

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        YCBTDriver(writer: writer)
    }
}
