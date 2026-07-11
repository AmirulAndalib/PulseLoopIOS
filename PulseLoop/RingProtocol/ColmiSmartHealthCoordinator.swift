import Foundation
@preconcurrency import CoreBluetooth

/// Coordinator for Colmi rings that ship with the **SmartHealth** app (the R09/R10 the owner has).
///
/// Same product line as `ColmiCoordinator`, a completely different firmware: these speak YCBT — the
/// byte-identical protocol the TK5 speaks — so the entire stack they build (`YCBTDriver` → encoder,
/// decoder, history transfer, sync engine) is the shared one, and this file is the whole of what makes
/// them their own family: an advertised identity and a capability set. Colmi rings that ship with
/// **QRing** keep the GadgetBridge-derived `ColmiDriver`.
///
/// The two are told apart at *pairing*, not on the wire — see `RingAppVariant`.
@MainActor
final class ColmiSmartHealthCoordinator: WearableCoordinator {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    static let deviceType: RingDeviceType = .colmiSmartHealth

    // MARK: - Advertisement constants — PROVISIONAL

    /// ⚠️ **None of this has been checked against a real SmartHealth-Colmi advertisement.** We have no
    /// capture yet (plan B0: the owner takes one with nRF Connect). These constants are a *hint* that
    /// sets the default position of the pairing screen's app-type picker, and nothing more.
    ///
    /// The design deliberately does not depend on them being right. The user's explicit pick is what
    /// selects the driver (`RingBLEClient.coordinatorType(preferredFamily:autoMatched:)`), so a
    /// heuristic that never fires costs a toggle the user has to flip — not a working connection — and
    /// one that fires wrongly costs the same. That asymmetry is why this is a hint and not a decision:
    /// a QRing-Colmi and a SmartHealth-Colmi can advertise the *identical* local name, so no
    /// advertisement-only rule can ever be trusted to separate them.
    ///
    /// Refine exactly these two constants (and nothing else) once the capture exists.
    enum Advertisement {
        /// The SmartHealth product code, matched as a **prefix of the manufacturer data** — i.e. in the
        /// company-ID slot, which is where the only capture we have in this family puts it (the TK5's
        /// `10786501…`; its trailing bytes are that model's own, so we match less than `TK5Coordinator`
        /// does but at the same anchor).
        ///
        /// `BleHelper.filterDevice` merely *contains*-tests `1078` (and its siblings 1178/1278/1378/C5FE)
        /// against the whole raw scan record — but it has no choice: it never parses out the AD
        /// structures. We do (CoreBluetooth hands us the manufacturer data already isolated), and an
        /// unanchored substring test over hex is not even byte-aligned: manufacturer bytes `a1 07 8f`
        /// stringify to `"a1078f"` and would match. Colmi's manufacturer payload commonly embeds the MAC,
        /// so an unlucky QRing-Colmi would be tagged as this family, defaulting the picker to the wrong
        /// app for a ring we already support. Anchoring costs nothing and cannot do that.
        ///
        /// If the B0 capture shows a SmartHealth-Colmi carrying the code somewhere *other* than the first
        /// two bytes, the fix is here and is one line: match on a byte-aligned index instead of a prefix.
        static let manufacturerHexMarker = "1078"

        /// The QRing-flavoured Colmi rings advertise one of these. Presence is a positive disqualifier:
        /// this ring answers to the *other* driver, so the conjunction below rejects it outright.
        static let qringServiceUUIDs: [CBUUID] = [
            CBUUID(string: ColmiUUIDs.serviceV1),
            CBUUID(string: ColmiUUIDs.serviceV2),
        ]
    }

    /// The conjunction: a Colmi-line local name **and** the SmartHealth marker **and** no QRing service.
    ///
    /// The name half reuses the catalog's own Colmi patterns rather than restating them — a card that
    /// offers the SmartHealth app variant *is* the definition of "a Colmi-line name", and one list of
    /// regexes is one list to keep right. The conjunction is what keeps this matcher off a TK5 (whose
    /// `10786501…` carries the marker in the same slot — every ring in this SDK family does — but whose
    /// card offers no variants, so the *name* half rejects it) and off any Colmi that advertises the
    /// QRing service.
    static func matches(name: String?, advertisement: AdvertisementInfo) -> Bool {
        guard let model = WearableModel.model(advertisedName: name),
              model.variant(for: deviceType) != nil else { return false }
        guard let manufacturer = advertisement.manufacturerData,
              manufacturer.hexString.hasPrefix(Advertisement.manufacturerHexMarker) else { return false }
        return !advertisement.serviceUUIDs.contains { Advertisement.qringServiceUUIDs.contains($0) }
    }

    // MARK: - Capabilities

    /// The floor: what every YCBT ring does regardless of which sensors its SKU carries. A *family* is
    /// not a SKU here — two Colmi rings speaking this identical protocol can differ on whether they have
    /// a temperature or blood-pressure sensor at all — so anything sensor-dependent is deferred to
    /// `bitmapGatedCapabilities` and only claimed if the ring itself claims it.
    ///
    /// Two entries look like they belong in the gated set and deliberately don't, because they are
    /// *protocol* facts, not sensor facts — identical for every YCBT ring, and the TK5 (the one unit of
    /// this protocol we have on the bench) declares both as baseline:
    ///
    /// - `.measurementInterval` is the five `01 xx {enable, interval}` monitor writes. It is a settings
    ///   screen, not a sensor; a ring that doesn't implement one of the five NAKs that one write.
    /// - `.spo2History` is the all-day `05 1A` log. A ring without it answers the query with a no-data
    ///   header or `0xFC`, which `YCBTHistoryTransfer` skips permanently.
    ///
    /// Neither is named by any bit in `YCBTSupportFunction`, so gating them would not defer the decision
    /// — it would make them permanently unreachable (see `bitmapGatedCapabilities`).
    ///
    /// **`.fatigue` is deliberately absent**, unlike on the TK5. It rides the body-data record (`05 33`)
    /// and no bit names it, so we can neither gate it nor honestly promise it on hardware nobody has
    /// connected yet — and unlike the two above, an unsupported claim here *is* user-visible: `.fatigue`
    /// renders its own Vitals gauge, which would sit permanently at "No fatigue score yet". B6 (the
    /// first real sync) is what decides; adding a capability then is a one-line change, and a card that
    /// appears is a better surprise than one that never fills.
    let capabilities: Set<WearableCapability> = [
        .heartRate, .spo2, .spo2History, .steps, .sleep, .remSleep, .battery, .hrv,
        .manualHeartRate, .manualSpo2, .manualHrv,
        .realtimeHeartRate, .realtimeSteps,
        .findDevice, .measurementInterval,
    ]

    /// The per-SKU sensors: added only if this unit's `02 01` capability bitmap claims them (the
    /// refinement is `WearableCoordinator.refinedCapabilities`, which can only *add*, and only from
    /// this list).
    ///
    /// Every entry must be a capability `YCBTSupportFunction` can actually derive from a bit — a gate no
    /// bit can ever satisfy is not a deferred decision but a dead promise, permanently unreachable while
    /// reading as "supported if the ring says so". `PairingMatchingTests` asserts that invariant.
    ///
    /// These are exactly the rows the gap analysis marks `❔` for this family: present in the protocol,
    /// unknown per unit.
    let bitmapGatedCapabilities: Set<WearableCapability> = [
        .temperature, .bloodPressure, .stress, .bloodSugar, .manualBloodPressure,
    ]

    let iconSystemName = "circle.circle.fill"

    func makeDriver(writer: RingCommandWriter) -> WearableDriver {
        YCBTDriver(writer: writer)
    }
}
