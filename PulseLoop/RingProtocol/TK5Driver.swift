import Foundation
@preconcurrency import CoreBluetooth

/// TK5 driver. Owns the length-prefixed CRC16 framing and the split-channel topology: the command
/// characteristic `be940001` is *both* the write target and a notify source (command replies), while
/// `be940003` carries the async live/history stream. The standard `180D`/`2A37` Heart Rate
/// characteristic is also subscribed as an auth-independent fallback live-HR source.
///
/// Because `be940001` is simultaneously the write and a notify characteristic, `RingBLEClient`'s
/// discovery subscribes any `notifyUUIDs` entry even when it also matches `writeUUID`.
@MainActor
final class TK5Driver: WearableDriver {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let decoder = TK5Decoder()

    init(writer: RingCommandWriter) {
        self.writer = writer
    }

    // MARK: BLE topology
    //
    // Only the proprietary `be940000` service is used. The standard `180D`/`2A37` Heart Rate
    // characteristic is intentionally NOT subscribed: on the TK5 it emits a cached resting HR
    // periodically even when the ring is off the finger (observed as a constant ~87 bpm), which would
    // override a real on-demand measurement. The official app never subscribes it either — live HR
    // comes solely from the proprietary `06 01` stream, which reflects actual finger contact.
    let serviceUUIDs: [CBUUID] = [CBUUID(string: TK5UUIDs.service)]
    let writeUUID = CBUUID(string: TK5UUIDs.command)
    let notifyUUIDs: [CBUUID] = [
        CBUUID(string: TK5UUIDs.command),   // command replies (also the write char)
        CBUUID(string: TK5UUIDs.stream),    // async live + history stream
    ]
    let batteryServiceUUID: CBUUID? = nil   // battery is in-band (0x02 0x00 status, payload[5])
    let batteryCharUUID: CBUUID? = nil

    // MARK: Framing
    func frame(_ command: Data) -> Data {
        // Logical command is `[type, cmd, payload…]`; insert the total-length field and append CRC16.
        TK5Frame.frame([UInt8](command))
    }

    // MARK: Inbound decode
    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        guard let frame = TK5Frame(validating: data) else {
            return [.unknown(commandId: data.first ?? 0, raw: data)]
        }
        return decoder.decode(frame)
    }

    func makeSyncEngine() -> RingSyncEngine {
        TK5SyncEngine(writer: writer)
    }
}
