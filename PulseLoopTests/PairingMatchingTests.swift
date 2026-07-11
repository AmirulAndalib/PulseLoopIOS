import XCTest
import CoreBluetooth
import UIKit
@testable import PulseLoop

/// The pairing flow must recognize the whole Colmi/Yawell ring family by advertised name (they all
/// share `ColmiDriver`), without the jring coordinator wrongly claiming them.
///
/// Since Phase B it must also do something strictly harder: separate the *two* Colmi families, which
/// speak entirely different protocols and can advertise the identical local name. That is why the
/// advertisement is only a hint here and the user's app-type pick is the authority — the cross-claim
/// matrix below pins the hint's behavior, and `testPreferredFamilyOverridesAutoMatch` pins the override
/// that makes a wrong hint harmless.
@MainActor
final class PairingMatchingTests: XCTestCase {
    private let noAdv = AdvertisementInfo(serviceUUIDs: [], manufacturerData: nil)

    private func bytes(_ hex: String) -> Data {
        var out = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let n = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<n], radix: 16)!)
            i = n
        }
        return Data(out)
    }

    /// A SmartHealth-family advertisement: the `1078` product code in manufacturer data, no QRing
    /// service. PROVISIONAL — no real SmartHealth-Colmi capture exists yet (plan B0).
    private var smartHealthAdv: AdvertisementInfo {
        AdvertisementInfo(serviceUUIDs: [], manufacturerData: bytes("10780a01aabbccdd"))
    }

    /// A QRing-Colmi: advertises the Nordic-UART-style service, no SmartHealth marker.
    private var qringAdv: AdvertisementInfo {
        AdvertisementInfo(serviceUUIDs: [CBUUID(string: ColmiUUIDs.serviceV1)], manufacturerData: nil)
    }

    /// The TK5's real capture: `10786501…` — note it *contains* `1078`, so only the name half of the
    /// SmartHealth conjunction keeps it out of the Colmi family.
    private var tk5Adv: AdvertisementInfo {
        AdvertisementInfo(serviceUUIDs: [], manufacturerData: bytes("10786501000101120000000000"))
    }

    private func colmiMatches(_ name: String) -> Bool {
        ColmiCoordinator.matches(name: name, advertisement: noAdv)
    }

    func testColmiFamilyNamesMatch() {
        let names = [
            "R02_A1B2", "R03_1234", "R06_FFFF", "COLMI R07_9", "R09_00AA",
            "COLMI R10_xyz", "COLMI R12_x", "R05_1A2B", "R10_DEAD", "R11_BEEF",
            "R11C_BEEF", "H59_anything",
        ]
        for name in names {
            XCTAssertTrue(colmiMatches(name), "expected Colmi match for \(name)")
        }
    }

    func testNonColmiNamesDoNotMatch() {
        for name in ["SMART_RING", "Mi Band 5", "Galaxy Watch", "R0X_NOPE", "Random"] {
            XCTAssertFalse(colmiMatches(name), "did not expect Colmi match for \(name)")
        }
    }

    func testColmiMatchesByServiceUUID() {
        let adv = AdvertisementInfo(serviceUUIDs: [CBUUID(string: ColmiUUIDs.serviceV1)], manufacturerData: nil)
        XCTAssertTrue(ColmiCoordinator.matches(name: "Unlabeled", advertisement: adv))
    }

    func testJringDoesNotClaimColmiNames() {
        XCTAssertFalse(JringCoordinator.matches(name: "R02_A1B2", advertisement: noAdv))
        XCTAssertTrue(JringCoordinator.matches(name: "SMART_RING", advertisement: noAdv))
    }

    func testCatalogFamiliesAreRegistered() {
        // Every family every carousel card can resolve to — including via its app variants — must have a
        // registered coordinator, or picking that variant would silently fall back to the jring driver.
        let registeredTypes = Set(RingBLEClient.coordinators.map { $0.deviceType })
        for model in WearableModel.catalog {
            for family in model.families {
                XCTAssertTrue(registeredTypes.contains(family), "no coordinator for \(model.displayName) (\(family))")
            }
        }
    }

    // MARK: - Registry cross-claim matrix (B3)

    /// The one ordering constraint in the registry, stated as a test so a re-sort can't silently break
    /// it: behind `ColmiCoordinator` — whose matcher needs only the name — no SmartHealth ring would
    /// ever be claimed.
    func testSmartHealthColmiPrecedesQRingColmi() {
        let order = RingBLEClient.coordinators.map { $0.deviceType }
        guard let smartHealth = order.firstIndex(of: .colmiSmartHealth),
              let qring = order.firstIndex(of: .colmiR02) else {
            return XCTFail("both Colmi coordinators must be registered")
        }
        XCTAssertLessThan(smartHealth, qring)
    }

    /// Registry order + each coordinator's matcher, end to end: every ring lands on exactly one driver.
    func testRegistryCrossClaimMatrix() {
        let cases: [(String, String?, AdvertisementInfo, RingDeviceType?)] = [
            ("jring", "SMART_RING", noAdv, .jring),
            ("QRing-Colmi advertising its service", "R09_00AA", qringAdv, .colmiR02),
            ("QRing-Colmi with a bare advertisement", "R09_00AA", noAdv, .colmiR02),
            ("SmartHealth-Colmi", "R09_00AA", smartHealthAdv, .colmiSmartHealth),
            ("SmartHealth-Colmi (COLMI-prefixed name)", "COLMI R10_xyz", smartHealthAdv, .colmiSmartHealth),
            ("TK5", "TK5 24AA", tk5Adv, .tk5),
            ("TK5, name only", "TK5 24AA", noAdv, .tk5),
            ("unknown peripheral", "Galaxy Watch", noAdv, nil),
        ]
        for (label, name, advertisement, expected) in cases {
            XCTAssertEqual(
                RingBLEClient.matchDeviceType(name: name, advertisement: advertisement),
                expected,
                label
            )
        }
    }

    /// The TK5's own manufacturer data (`10786501…`) *contains* the `1078` SmartHealth marker — every
    /// ring in this SDK family does. Only the name half of the conjunction keeps the TK5 out of the
    /// Colmi family, so assert it directly: TK5 auto-detection is exactly what it was.
    func testSmartHealthColmiDoesNotClaimTheTK5() {
        XCTAssertTrue(tk5Adv.manufacturerData!.hexString.contains(
            ColmiSmartHealthCoordinator.Advertisement.manufacturerHexMarker
        ))
        XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "TK5 24AA", advertisement: tk5Adv))
        XCTAssertTrue(TK5Coordinator.matches(name: "TK5 24AA", advertisement: tk5Adv))
    }

    /// The marker lives in the manufacturer data's **company-ID slot**, so it is matched as a prefix. An
    /// unanchored substring test over the hex string is not even byte-aligned — mfr bytes `a1 07 8f`
    /// stringify to `"a1078f"` — and Colmi's manufacturer payload commonly embeds the MAC, so an unlucky
    /// QRing-Colmi would be tagged as the SmartHealth family, defaulting the picker (and the first
    /// connect) to a protocol its firmware doesn't speak.
    func testSmartHealthMarkerIsAnchoredToTheCompanyIDSlot() {
        let straddling = AdvertisementInfo(serviceUUIDs: [], manufacturerData: bytes("a1078fcc"))
        XCTAssertTrue(straddling.manufacturerData!.hexString.contains("1078"))   // the trap it must not fall into
        XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "R09_00AA", advertisement: straddling))
        XCTAssertEqual(RingBLEClient.matchDeviceType(name: "R09_00AA", advertisement: straddling), .colmiR02)
    }

    /// The conjunction, term by term. Each half alone is not enough.
    func testSmartHealthColmiRequiresAllThreeSignals() {
        // Colmi name + marker + no QRing service → claimed.
        XCTAssertTrue(ColmiSmartHealthCoordinator.matches(name: "R09_00AA", advertisement: smartHealthAdv))
        // Colmi name, but no manufacturer data at all → not claimed (falls through to QRing-Colmi).
        XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "R09_00AA", advertisement: noAdv))
        // Colmi name + marker, but the ring advertises a QRing service → disqualified.
        for uuid in ColmiSmartHealthCoordinator.Advertisement.qringServiceUUIDs {
            let conflicted = AdvertisementInfo(
                serviceUUIDs: [uuid],
                manufacturerData: smartHealthAdv.manufacturerData
            )
            XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "R09_00AA", advertisement: conflicted))
            XCTAssertEqual(
                RingBLEClient.matchDeviceType(name: "R09_00AA", advertisement: conflicted), .colmiR02
            )
        }
        // Marker, but not a Colmi-line name → not claimed.
        XCTAssertFalse(ColmiSmartHealthCoordinator.matches(name: "Unlabeled", advertisement: smartHealthAdv))
    }

    // MARK: - The user's pick is authoritative (B4)

    /// The load-bearing rule of the whole variant design: an explicit family beats the auto-match. This
    /// is what makes the provisional advertisement heuristic safe to be wrong — in *either* direction.
    func testPreferredFamilyOverridesAutoMatch() {
        func family(preferred: RingDeviceType?, autoMatched: RingDeviceType?) -> RingDeviceType {
            RingBLEClient.coordinatorType(preferredFamily: preferred, autoMatched: autoMatched).deviceType
        }
        // The hint said QRing, the user says SmartHealth (and vice versa) — the user wins both ways.
        XCTAssertEqual(family(preferred: .colmiSmartHealth, autoMatched: .colmiR02), .colmiSmartHealth)
        XCTAssertEqual(family(preferred: .colmiR02, autoMatched: .colmiSmartHealth), .colmiR02)
        // A ring the scan recognized as nothing still gets the declared driver, not the jring fallback.
        XCTAssertEqual(family(preferred: .colmiSmartHealth, autoMatched: nil), .colmiSmartHealth)
        // No declaration → the auto-match still rules, unchanged.
        XCTAssertEqual(family(preferred: nil, autoMatched: .tk5), .tk5)
        XCTAssertEqual(family(preferred: nil, autoMatched: .colmiR02), .colmiR02)
        XCTAssertEqual(family(preferred: nil, autoMatched: .jring), .jring)
        // Neither → jring, preserving the pre-existing reconnect-to-unknown-peripheral behavior.
        XCTAssertEqual(family(preferred: nil, autoMatched: nil), .jring)
    }

    // MARK: - Which ring a tap actually connects (B4)

    /// The card-level hint is taken from whichever ring sorted first in the scan — which, with two Colmi
    /// rings in range, is not necessarily the one the user tapped. This user owns exactly that pair, so
    /// the tapped row's *own* scan tag has to outrank the hint: otherwise tapping the correctly-identified
    /// SmartHealth R09 while a nearer QRing ring set the hint would install `ColmiDriver` against a YCBT
    /// ring — the auto-match was right and we'd have overridden it with a hint from another peripheral.
    func testATappedRowOutranksAHintSourcedFromAnotherRing() {
        let card = WearableModel.colmiR09
        // Hint says QRing (from the other ring); the tapped row is the SmartHealth one.
        XCTAssertEqual(card.variant(picked: nil, rowFamily: .colmiSmartHealth, hinted: .qring), .smartHealth)
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: .colmiSmartHealth, hinted: .qring), .colmiSmartHealth)
        // …and the mirror image: a SmartHealth hint must not drag a QRing-tagged row onto the YCBT stack.
        XCTAssertEqual(card.variant(picked: nil, rowFamily: .colmiR02, hinted: .smartHealth), .qring)
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: .colmiR02, hinted: .smartHealth), .colmiR02)
    }

    /// The rule the whole design rests on, one level up from `testPreferredFamilyOverridesAutoMatch`: the
    /// user's pick beats even a row the scan claimed. Only the *scan* is a hint; the human is not.
    func testAnExplicitPickOutranksTheRowsOwnTag() {
        let card = WearableModel.colmiR09
        XCTAssertEqual(card.preferredFamily(picked: .smartHealth, rowFamily: .colmiR02, hinted: .qring), .colmiSmartHealth)
        XCTAssertEqual(card.preferredFamily(picked: .qring, rowFamily: .colmiSmartHealth, hinted: .smartHealth), .colmiR02)
    }

    /// A row the scan recognized as nothing is fair game for the card's hint/default — the alternative is
    /// the jring fallback, which is certainly wrong. A row it recognized as *another family* is not:
    /// forcing the carousel's family on it would hand a jring the Colmi driver merely because the user
    /// hadn't swiped away from the Colmi card.
    func testUnrecognizedRowsTakeTheCardDefaultAndUnrelatedRowsKeepTheirOwnDriver() {
        let card = WearableModel.colmiR09
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: nil, hinted: .smartHealth), .colmiSmartHealth)
        XCTAssertEqual(card.preferredFamily(picked: nil, rowFamily: nil, hinted: nil), .colmiR02)   // card default
        XCTAssertNil(card.preferredFamily(picked: .smartHealth, rowFamily: .jring, hinted: .smartHealth))
        XCTAssertNil(card.preferredFamily(picked: .smartHealth, rowFamily: .tk5, hinted: nil))
        // Single-firmware cards never override anything: jring/TK5 pairing is auto-detection, as before.
        for model in [WearableModel.jring, WearableModel.tk5] {
            XCTAssertNil(model.variant(picked: .smartHealth, rowFamily: .colmiSmartHealth, hinted: .smartHealth))
            XCTAssertNil(model.preferredFamily(picked: .smartHealth, rowFamily: nil, hinted: .smartHealth))
        }
    }

    func testColmiCardsOfferBothAppsAndTK5OffersNone() {
        for model in WearableModel.catalog where model.family == .colmiR02 {
            XCTAssertEqual(model.appVariants.map(\.variant), [.qring, .smartHealth], model.displayName)
            XCTAssertEqual(model.families, [.colmiR02, .colmiSmartHealth], model.displayName)
            XCTAssertEqual(model.family(for: .qring), .colmiR02)
            XCTAssertEqual(model.family(for: .smartHealth), .colmiSmartHealth)
            XCTAssertEqual(model.family(for: nil), .colmiR02)   // untouched picker = the card's default
            XCTAssertEqual(model.variant(for: .colmiSmartHealth), .smartHealth)
            XCTAssertEqual(model.otherVariant(than: .smartHealth), .qring)
            XCTAssertEqual(model.otherVariant(than: .qring), .smartHealth)
            XCTAssertNotEqual(model.blurb(for: .smartHealth), model.blurb(for: .qring))
        }
        // Single-firmware cards: no picker, no override, no behavior change anywhere.
        for model in [WearableModel.jring, WearableModel.tk5] {
            XCTAssertTrue(model.appVariants.isEmpty, model.displayName)
            XCTAssertEqual(model.families, [model.family], model.displayName)
            XCTAssertEqual(model.blurb(for: .smartHealth), model.blurb, model.displayName)
            XCTAssertEqual(model.family(for: .smartHealth), model.family, model.displayName)
            XCTAssertNil(model.otherVariant(than: .qring), model.displayName)
        }
    }

    func testAdvertisedNamesResolveToExactModels() {
        let expected = [
            "SMART_RING": "jring",
            "R02_A1B2": "colmi-r02",
            "R03_1234": "colmi-r03",
            "R06_FFFF": "colmi-r06",
            "COLMI R07_9": "colmi-r07",
            "R09_00AA": "colmi-r09",
            "COLMI R10_xyz": "colmi-r10",
            "R11C_BEEF": "colmi-r11",
            "COLMI R12_x": "colmi-r12",
            "R05_1A2B": "yawell-r05",
            "R10_DEAD": "yawell-r10",
            "R11_BEEF": "yawell-r11",
            "H59_anything": "h59",
        ]
        for (name, modelID) in expected {
            XCTAssertEqual(WearableModel.model(advertisedName: name)?.id, modelID, name)
        }
    }

    func testDetectedModelOverridesCarouselSelection() {
        let model = WearableModel.resolve(
            advertisedName: "COLMI R10_xyz",
            selectedModelID: WearableModel.colmiR02.id,
            family: .colmiR02
        )
        XCTAssertEqual(model?.id, WearableModel.colmiR10.id)
    }

    func testCarouselSelectionIsFallbackForGenericAdvertisement() {
        let model = WearableModel.resolve(
            advertisedName: "Unlabeled",
            selectedModelID: WearableModel.colmiR12.id,
            family: .colmiR02
        )
        XCTAssertEqual(model?.id, WearableModel.colmiR12.id)
    }

    /// A Colmi connecting as `.colmiSmartHealth` is still a "Colmi R09" — without variant-aware resolve
    /// it would identify as no model at all and the device card would lose its name and product art.
    func testResolveIsVariantAware() {
        XCTAssertEqual(
            WearableModel.resolve(advertisedName: "R09_00AA", selectedModelID: nil, family: .colmiSmartHealth)?.id,
            "colmi-r09"
        )
        XCTAssertEqual(
            WearableModel.resolve(advertisedName: "R09_00AA", selectedModelID: nil, family: .colmiR02)?.id,
            "colmi-r09"
        )
        XCTAssertEqual(
            WearableModel.resolve(advertisedName: nil, selectedModelID: "colmi-r10", family: .colmiSmartHealth)?.id,
            "colmi-r10"
        )
        // A card that can't be this family still doesn't resolve to it.
        XCTAssertNil(WearableModel.resolve(advertisedName: "TK5 24AA", selectedModelID: nil, family: .colmiSmartHealth))
        XCTAssertNil(WearableModel.resolve(advertisedName: "R09_00AA", selectedModelID: nil, family: .tk5))
    }

    func testUnknownLegacyColmiHasNoExactModel() {
        XCTAssertNil(WearableModel.resolve(advertisedName: nil, selectedModelID: nil, family: .colmiR02))
        XCTAssertEqual(RingDeviceType.colmiR02.displayName, "Colmi / Yawell ring")
        XCTAssertEqual(RingDeviceType.colmiSmartHealth.displayName, "Colmi ring (SmartHealth)")
    }

    func testColmiR11ReusesYawellR11Image() {
        XCTAssertEqual(WearableModel.colmiR11.imageName, WearableModel.yawellR11.imageName)
    }

    // MARK: - SmartHealth-Colmi capabilities (B3)

    /// The two YCBT families drive one shared stack, so this family can only ever claim what the stack
    /// implements — i.e. a subset of the (hardware-exercised) TK5's set. A capability outside that is a
    /// card that can never fill.
    func testSmartHealthColmiClaimsNothingTheYCBTStackCannotDeliver() {
        let colmi = ColmiSmartHealthCoordinator()
        let everythingItCouldClaim = colmi.capabilities.union(colmi.bitmapGatedCapabilities)
        XCTAssertTrue(everythingItCouldClaim.isSubset(of: TK5Coordinator().capabilities))
        // It must not inherit jring-only or QRing-only actions the YCBT stack has no command for.
        for absent: WearableCapability in [.combinedVitalsMeasurement, .powerOff, .factoryReset] {
            XCTAssertFalse(everythingItCouldClaim.contains(absent), absent.rawValue)
        }
    }

    /// A gate no bit can ever satisfy is not a deferred decision — it is a dead promise: it reads as
    /// "supported if the ring says so" while being permanently unreachable. Every gated capability must
    /// be derivable from the bitmap parser.
    func testEveryGatedCapabilityIsDerivableFromTheBitmap() {
        let allOnes = [UInt8](repeating: 0xFF, count: 32)
        let derivable = YCBTSupportFunction.capabilities(from: allOnes)
        XCTAssertFalse(ColmiSmartHealthCoordinator().bitmapGatedCapabilities.isEmpty)
        XCTAssertTrue(ColmiSmartHealthCoordinator().bitmapGatedCapabilities.isSubset(of: derivable))
    }

    /// The gated set resolves through B2's additive-only refinement formula: a silent ring keeps the
    /// baseline, a claiming ring gains exactly what it claimed, and nothing outside the pre-approved
    /// list can ever be added.
    func testBitmapRefinementForTheSmartHealthColmi() {
        let colmi = ColmiSmartHealthCoordinator()
        // Baseline and gated are disjoint — a gated capability the baseline already grants is a no-op.
        XCTAssertTrue(colmi.capabilities.isDisjoint(with: colmi.bitmapGatedCapabilities))
        // A ring that claims nothing (or answers with a truncated bitmap): the baseline stands.
        XCTAssertEqual(colmi.refinedCapabilities(bitmapDerived: []), colmi.capabilities)
        // A ring with a temperature + BP sensor gains exactly those two…
        XCTAssertEqual(
            colmi.refinedCapabilities(bitmapDerived: [.temperature, .bloodPressure]),
            colmi.capabilities.union([.temperature, .bloodPressure])
        )
        // …and a bitmap claiming something the family never pre-approved cannot conjure it up.
        XCTAssertEqual(colmi.refinedCapabilities(bitmapDerived: [.powerOff]), colmi.capabilities)
    }

    // MARK: - Support level

    func testSupportLevelIsPerFamily() {
        XCTAssertEqual(RingDeviceType.jring.supportLevel, .full)
        XCTAssertEqual(RingDeviceType.colmiR02.supportLevel, .full)
        XCTAssertEqual(RingDeviceType.tk5.supportLevel, .limited)
        XCTAssertEqual(RingDeviceType.colmiSmartHealth.supportLevel, .limited)
    }

    /// Both YCBT families are unproven, and only unproven families get a badge. A Colmi card therefore
    /// carries one *only* while its picker is on SmartHealth — the same physical ring, a different
    /// driver's maturity.
    func testLimitedSupportFamiliesCarryTheBadge() {
        XCTAssertEqual(WearableModel.tk5.supportLevel, .limited)
        XCTAssertEqual(WearableModel.tk5.supportLevel.badgeLabel, "Limited support")

        for model in WearableModel.catalog where model.family != .tk5 {
            XCTAssertEqual(model.supportLevel, .full, model.displayName)
            XCTAssertNil(model.supportLevel.badgeLabel, model.displayName)
        }
        for model in WearableModel.catalog where model.family == .colmiR02 {
            XCTAssertEqual(model.supportLevel(for: .qring), .full, model.displayName)
            XCTAssertEqual(model.supportLevel(for: .smartHealth), .limited, model.displayName)
        }
    }

    // MARK: - Wrong-choice failure path (B5)

    /// The message a stalled connect shows. It has to name both apps: the one we tried (so the user knows
    /// what was attempted) and the one to try instead (so the failure is actionable in one tap).
    func testConnectFailureMessageNamesBothApps() {
        for family: RingDeviceType in [.colmiSmartHealth, .colmiR02] {
            let message = RingConnectFailure.message(family: family)
            XCTAssertTrue(message.contains("QRing"), message)
            XCTAssertTrue(message.contains("SmartHealth"), message)
        }
        // The one we tried is named first — the sentence is "didn't answer as a <tried> ring".
        XCTAssertTrue(RingConnectFailure.message(family: .colmiSmartHealth)
            .hasPrefix("This ring didn't answer as a SmartHealth ring."))
        XCTAssertTrue(RingConnectFailure.message(family: .colmiR02)
            .hasPrefix("This ring didn't answer as a QRing ring."))
    }

    /// A single-firmware family has no other app to suggest, so it must not offer one.
    func testConnectFailureMessageIsGenericWithoutVariants() {
        for family: RingDeviceType? in [.jring, .tk5, nil] {
            let message = RingConnectFailure.message(family: family)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("QRing"), message)
            XCTAssertFalse(message.contains("SmartHealth"), message)
        }
    }

    func testAppVariantMapsToAndFromItsFamily() {
        XCTAssertEqual(RingAppVariant(family: .colmiR02), .qring)
        XCTAssertEqual(RingAppVariant(family: .colmiSmartHealth), .smartHealth)
        XCTAssertNil(RingAppVariant(family: .jring))
        XCTAssertNil(RingAppVariant(family: .tk5))
        XCTAssertEqual(RingAppVariant.qring.other, .smartHealth)
        XCTAssertEqual(RingAppVariant.smartHealth.other, .qring)
    }

    /// Every catalog model must name an imageset that exists, or `RingArtView` renders an empty
    /// platter (a non-nil `imageName` has no fallback path). Resolve against the app bundle rather
    /// than `.main` so this holds whether or not the test target is hosted.
    func testEveryCatalogImageNameResolvesToAnAsset() {
        let appBundle = Bundle(for: RingBLEClient.self)
        for model in WearableModel.catalog {
            guard let imageName = model.imageName else { continue }
            XCTAssertNotNil(
                UIImage(named: imageName, in: appBundle, compatibleWith: nil),
                "missing imageset '\(imageName)' for \(model.displayName)"
            )
        }
        XCTAssertEqual(WearableModel.tk5.imageName, "tk5")
    }
}
