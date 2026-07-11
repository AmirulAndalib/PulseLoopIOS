import XCTest
@testable import PulseLoop

/// What `RingBLEClient` remembers about a ring *between* connections: its family, its exact catalog
/// model, and what its own capability bitmap claimed.
///
/// All three have to be re-adopted before a new session publishes its first `.deviceIdentified`, because
/// that event overwrites the persisted `Device` row wholesale — anything the client can't name at that
/// moment is not merely missing from the UI, it is erased from the store.
@MainActor
final class RingIdentityMemoryTests: XCTestCase {
    private let deviceTypeKey = "ring.lastDeviceType"
    private let modelKey = "ring.lastWearableModel"
    private let capabilitiesKey = "ring.lastCapabilities"

    /// An R09 whose `02 01` bitmap claimed a temperature sensor on a previous connect.
    private var rememberedSmartHealthCapabilities: Set<WearableCapability> {
        ColmiSmartHealthCoordinator().capabilities.union([.temperature])
    }

    /// Seed (and, on teardown, clear) the client's cross-connection memory. Starts from a clean slate so
    /// a test never inherits another's — or a previous run's — remembered ring.
    private func remember(deviceType: String? = nil, model: String? = nil, capabilities: Set<WearableCapability>? = nil) {
        let defaults = UserDefaults.standard
        let keys = [deviceTypeKey, modelKey, capabilitiesKey]
        keys.forEach { defaults.removeObject(forKey: $0) }
        addTeardownBlock {
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
        deviceType.map { defaults.set($0, forKey: deviceTypeKey) }
        model.map { defaults.set($0, forKey: modelKey) }
        capabilities.map { defaults.set($0.csv, forKey: capabilitiesKey) }
    }

    /// iOS killed the app mid-session and relaunched it for a BLE event. `willRestoreState` has no
    /// advertisement to re-derive anything from, so it re-adopts what was remembered. Before it did, the
    /// restored session reached `.connected` with a nil model id and nulled `Device.wearableModelID` —
    /// the device card lost its name and product art until some later reconnect happened to carry a
    /// resolvable GAP name.
    func testRestoredSessionReadoptsFamilyModelAndClaimedCapabilities() {
        remember(deviceType: "colmiSmartHealth", model: "colmi-r09", capabilities: rememberedSmartHealthCapabilities)
        let client = RingBLEClient(startManager: false)

        client.adoptRememberedIdentity()

        XCTAssertEqual(client.activeDeviceType, .colmiSmartHealth)
        XCTAssertEqual(client.activeWearableModelID, "colmi-r09")
        XCTAssertTrue(client.activeCapabilities.contains(.temperature))
    }

    /// The bitmap arrives partway into a handshake; `Device.capabilitiesRaw` is overwritten at the start
    /// of one. So a connect that never gets an answer — a dropped `02 01` reply, or firmware that answers
    /// with a short array — must not be able to strip a capability the ring already told us it has: the
    /// Vitals/Today cards for it would vanish for the whole session *and* while offline afterwards.
    func testAConnectWhoseBitmapNeverArrivesKeepsWhatTheRingAlreadyClaimed() {
        remember(capabilities: rememberedSmartHealthCapabilities)
        let client = RingBLEClient(startManager: false)

        client.installDriver(ColmiSmartHealthCoordinator.self)   // no `.supportFunctions` follows

        XCTAssertEqual(client.activeCapabilities, rememberedSmartHealthCapabilities)
    }

    /// The seed is fed through the same additive-only refinement as the bitmap itself, so it can only
    /// re-grant what *this* family gates. A set remembered from another ring can't leak a sensor into a
    /// family that has none — which is also why jring and QRing-Colmi (which gate nothing) are provably
    /// untouched by any of this.
    func testRememberedCapabilitiesCannotLeakIntoAFamilyThatGatesNothing() {
        remember(capabilities: TK5Coordinator().capabilities)
        let client = RingBLEClient(startManager: false)

        client.installDriver(JringCoordinator.self)
        XCTAssertEqual(client.activeCapabilities, JringCoordinator().capabilities)

        client.installDriver(ColmiCoordinator.self)
        XCTAssertEqual(client.activeCapabilities, ColmiCoordinator().capabilities)
    }

    /// Nothing remembered (a first-ever pairing): the family baseline, exactly as before.
    func testAFirstConnectStartsFromTheFamilyBaseline() {
        remember()
        let client = RingBLEClient(startManager: false)
        client.installDriver(ColmiSmartHealthCoordinator.self)
        XCTAssertEqual(client.activeCapabilities, ColmiSmartHealthCoordinator().capabilities)
        XCTAssertFalse(client.activeCapabilities.contains(.temperature))
    }
}
