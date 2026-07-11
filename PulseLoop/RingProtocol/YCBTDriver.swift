import Foundation
@preconcurrency import CoreBluetooth

/// YCBT driver. Owns the length-prefixed CRC16 framing and the split-channel topology: the command
/// characteristic `be940001` is *both* the write target and a notify source (command replies), while
/// `be940003` carries the async live/history stream. The standard `180D`/`2A37` Heart Rate
/// characteristic is deliberately left unsubscribed — see the BLE-topology note below.
///
/// Because `be940001` is simultaneously the write and a notify characteristic, `RingBLEClient`'s
/// discovery subscribes any `notifyUUIDs` entry even when it also matches `writeUUID`.
@MainActor
final class YCBTDriver: WearableDriver {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

    private weak var writer: RingCommandWriter?
    private let decoder = YCBTDecoder()
    /// GATT fragments → whole logical frames. A history data frame regularly exceeds `MTU-3` and is
    /// split across notifications, so a frame must never be validated against one notification's length
    /// — doing so throws away every fragmented frame as garbage.
    private let assembler = YCBTFrameAssembler()
    /// The history state machine. The driver owns it because only the driver sees frames (the sync
    /// engine sees decoded events), and it is handed to the engine so `runStartup` can seed the queue.
    private let transfer: YCBTHistoryTransfer

    init(writer: RingCommandWriter) {
        self.writer = writer
        self.transfer = YCBTHistoryTransfer(writer: writer)
    }

    // MARK: BLE topology
    //
    // Only the proprietary `be940000` service is used. The standard `180D`/`2A37` Heart Rate
    // characteristic is intentionally NOT subscribed: on the TK5 it emits a cached resting HR
    // periodically even when the ring is off the finger (observed as a constant ~87 bpm), which would
    // override a real on-demand measurement. The official app never subscribes it either — live HR
    // comes solely from the proprietary `06 01` stream, which reflects actual finger contact.
    let serviceUUIDs: [CBUUID] = [CBUUID(string: YCBTUUIDs.service)]
    let writeUUID = CBUUID(string: YCBTUUIDs.command)
    let notifyUUIDs: [CBUUID] = [
        CBUUID(string: YCBTUUIDs.command),   // command replies (also the write char)
        CBUUID(string: YCBTUUIDs.stream),    // async live + history stream
    ]
    let batteryServiceUUID: CBUUID? = nil   // battery is in-band (GetDeviceInfo 02 00, payload[5])
    let batteryCharUUID: CBUUID? = nil

    // MARK: Framing
    func frame(_ command: Data) -> Data {
        // Logical command is `[type, cmd, payload…]`; insert the total-length field and append CRC16.
        YCBTFrame.frame([UInt8](command))
    }

    // MARK: Lifecycle

    /// A reconnect re-uses this driver, so a frame left half-assembled when the old link dropped would
    /// otherwise be completed with bytes from the new one (and a history transfer would still think it
    /// was mid-type).
    func connectionDidStart() {
        assembler.reset()
        transfer.cancel()
    }

    /// Cancelling on the next *connect* is too late for the transfer: its stall watchdog is a timer, and
    /// a ring that drops out of range mid-dump leaves it running. It would step through the rest of the
    /// catalog while we're disconnected — one `05 xx` query every 10 s — into the write queue, and the
    /// reconnect would flush those stale queries before the handshake, desyncing the fresh transfer
    /// against dumps it never asked for. Killing it at disconnect is the only place that can't race.
    func connectionDidEnd() {
        assembler.reset()
        transfer.cancel()
    }

    // MARK: Inbound decode

    /// Every notification goes through the assembler first (one notification can carry several frames,
    /// and one frame several notifications). Health-group frames drive the history transfer; DevControl
    /// pushes must be acknowledged; everything else is a stateless decode.
    func ingest(_ data: Data, from characteristic: CBUUID) -> [RingDecodedEvent] {
        var events: [RingDecodedEvent] = []
        for logical in assembler.append(data, from: characteristic) {
            guard let frame = YCBTFrame(validating: logical) else {
                events.append(.unknown(commandId: logical.first ?? 0, raw: logical))
                continue
            }
            switch frame.type {
            case YCBTGroup.health:
                events.append(contentsOf: transfer.handle(cmd: frame.cmd, payload: frame.payload))
            case YCBTGroup.devControl:
                acknowledgePush(frame)
                events.append(contentsOf: decoder.decode(frame))
            default:
                events.append(contentsOf: decoder.decode(frame))
            }
        }
        return events
    }

    /// The ring **retransmits an unacknowledged DevControl push** until the app answers `04 <key> {00}`,
    /// so the ACK goes out before the frame is even decoded — `YCBTClientImpl.packetDevControlHandle`
    /// likewise sends `sendData2Device(dataType, {0})` first and parses second, and a slow decode must
    /// never be able to stall the ring.
    ///
    /// Two deliberate divergences from the SDK:
    ///   • A 1-byte `0xFB…0xFF` payload is an *error* frame, not a push. The SDK drops those for groups 4
    ///     and 6 without replying, and ACKing one would be answering a rejection as though it were a push
    ///     the ring never sent — worse, it could ping-pong with the ring's own error reply.
    ///   • The SDK only ACKs the keys in its own hard-coded table. We ACK every non-error key: an
    ///     unrecognised push still needs its retransmissions stopped (that is the whole point of the ACK),
    ///     and an ACK for a key the ring never pushed is inert.
    private func acknowledgePush(_ frame: YCBTFrame) {
        guard YCBTFrameError.detect(in: frame.payload) == nil else { return }
        writer?.enqueue(Data(YCBTDevControl.ack(key: frame.cmd)))
    }

    func makeSyncEngine() -> RingSyncEngine {
        YCBTSyncEngine(writer: writer, transfer: transfer)
    }
}
