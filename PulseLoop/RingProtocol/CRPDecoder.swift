import Foundation
@preconcurrency import CoreBluetooth

/// Reassembles CRP command replies (`fdd3`) that span multiple BLE notifications. A logical frame
/// starts with `FD DA …` and its declared total length (`CRPProtocol.frameLength`) tells us when it
/// is complete. Mirrors the vendor's `g1/a.k()`. One assembler instance per connection — a fresh
/// `CRPDriver` is built on every connect, so state always starts clean.
final class CRPFrameAssembler {
    private var buffer: [UInt8] = []
    private var expected = 0

    /// Feed one notification chunk. Returns the complete frame when the last chunk lands, else nil.
    func append(_ chunk: Data) -> Data? {
        if chunk.isEmpty { return nil }
        if CRPProtocol.isFrameStart(chunk) {
            expected = CRPProtocol.frameLength(chunk)
            buffer = []
        }
        // A continuation chunk with no in-progress frame is noise — drop it.
        if expected <= 0 { return nil }
        buffer.append(contentsOf: chunk)
        if buffer.count >= expected {
            let frame = buffer.count == expected ? buffer : Array(buffer.prefix(expected))
            buffer = []
            expected = 0
            return Data(frame)
        }
        return nil
    }
}

/// Decodes CRP notifications into `RingDecodedEvent`s. Routing is by source characteristic (the
/// `from` UUID `CRPDriver.ingest` passes through), matching the vendor's `g1/a.a(characteristic)`
/// dispatch:
///   - `fdd1` → raw current-steps triples (no CRP header)
///   - `fdd3` → framed `FD DA …` command replies (already reassembled by `CRPFrameAssembler`)
///
/// NOTE: This ring does NOT use the standard `2a37` HR characteristic — all vital results come
/// back as framed replies on `fdd3` with group/cmd routing. The `2a37` path is dead code for CRP
/// rings (removed during port).
///
/// Group-1 replies (`g1/a.java` lines 664–712) carry real-time vital results:
///   cmd 9  → HR (payload[0] = bpm, per `e1/f.b()`)
///   cmd 10 → HRV (payload[0] = ms)
///   cmd 11 → SpO2 (payload[0] = percent)
///   cmd 14 → stress (payload[0] = 0..100)
///   cmd 32 → temperature (payload[0..] = raw)
///   Other cmd values → command acknowledgment.
enum CRPDecoder {

    static func decode(_ data: Data, from characteristic: CBUUID, now: Date = Date()) -> [RingDecodedEvent] {
        switch characteristic {
        case CRPUUIDs.stepsNotifyCBUUID:
            return decodeCurrentSteps(data, now: now)
        default:
            return CRPProtocol.isFrameStart(data) ? decodeFramedReply(data, now: now) : []
        }
    }

    /// `fdd1` push — little-endian 3-byte triples: [steps][distance][calories]. From `e1/k.b`.
    /// distance is metres, calories kcal (vendor units).
    private static func decodeCurrentSteps(_ data: Data, now: Date) -> [RingDecodedEvent] {
        let b = [UInt8](data)
        if b.isEmpty || b.count % 3 != 0 { return [] }
        let steps = le3(b, 0)
        let distance = b.count >= 6 ? le3(b, 3) : 0
        let calories = b.count >= 9 ? le3(b, 6) : 0
        return [.activityUpdate(timestamp: now, steps: steps,
                                distanceMeters: Double(distance), calories: Double(calories))]
    }

    /// Framed `fdd3` reply: `FD DA 10 <len> <group> <cmd> <payload>`.
    /// Real-time vital results come on group 1; history queries on group 7; device info on group 7.
    private static func decodeFramedReply(_ frame: Data, now: Date) -> [RingDecodedEvent] {
        let b = [UInt8](frame)
        if b.count < CRPProtocol.headerSize { return [] }
        let group = Int(b[4])
        let cmd = Int(b[5])
        let payload = b.count > CRPProtocol.headerSize ? Array(b[CRPProtocol.headerSize..<b.count]) : []

        // Group 1: real-time vital results (decompiled `g1/a.java` lines 664–712).
        if group == CRPCommands.groupDevice {
            return decodeVitalResult(cmd: cmd, payload: payload, now: now)
        }

        // Group 7: history queries + device info (decompiled `b1/e0` + `b1/r`).
        if group == CRPCommands.groupDeviceInfo {
            return decodeHistoryOrDeviceInfoResponse(cmd: cmd, payload: payload, now: now)
        }

        // Unknown group/cmd — ack.
        return [.commandAck(commandId: UInt8(truncatingIfNeeded: (group << 4) | (cmd & 0x0F)))]
    }

    /// Decode group-1 vital result replies. Confirmed against `g1/a.java` and `e1/f.java` (HR),
    /// `e1/g.java` (HRV), `e1/d.java` (SpO2), `e1/h.java` (stress/physical strength), and the
    /// vendor's `onMeasureComplete` flow for temperature (cmd 32).
    ///
    /// Layout: `payload[0]` is the metric value for all types. Plausibility guards prevent
    /// garbage samples (HR 40–200, SpO2 70–100, stress 0–100, HRV 20–200).
    private static func decodeVitalResult(cmd: Int, payload: [UInt8], now: Date) -> [RingDecodedEvent] {
        guard !payload.isEmpty else {
            return [.commandAck(commandId: UInt8(truncatingIfNeeded: (CRPCommands.groupDevice << 4) | (cmd & 0x0F)))]
        }
        let value = Int(payload[0])

        switch cmd {
        case CRPCommands.cmdMeasureHR:
            // HR from `e1/f.b()`: byte2int(payload[0]).
            guard value >= 40 && value <= 200 else { return [] }
            return [.heartRateSample(bpm: value, timestamp: now)]

        case CRPCommands.cmdEnableTimingHRV:
            // HRV from `e1/g.d()`: twoBytes2int(payload[1], payload[0]), but vendor's onHrv()
            // callback receives byte2int(payload[0]) for the live measurement path.
            // We accept either layout: single-byte if payload is 1 byte, two-byte otherwise.
            let hrvValue: Int
            if payload.count >= 2 {
                hrvValue = Int(payload[0]) | (Int(payload[1]) << 8)
            } else {
                hrvValue = value
            }
            guard hrvValue >= 20 && hrvValue <= 200 else { return [] }
            return [.hrvSample(value: hrvValue, timestamp: now)]

        case CRPCommands.cmdEnableTimingSpO2:
            // SpO2 from `e1/d.b()`: byte2int(payload[0]).
            guard value >= 70 && value <= 100 else { return [] }
            return [.spo2Result(value: value, timestamp: now)]

        case CRPCommands.cmdEnableTimingStress:
            // Stress/physical strength from `e1/h.c()`: byte2int(payload[0]).
            guard value >= 0 && value <= 100 else { return [] }
            return [.stressSample(value: value, timestamp: now)]

        case CRPCommands.cmdEnableTimingTemp:
            // Temperature: vendor uses onMeasureComplete with payload. Layout unconfirmed.
            // Emit as temperature_sample with raw byte as placeholder until verified.
            return [.temperatureSample(celsius: Double(value), timestamp: now)]

        default:
            // Acknowledgment for enable/disable commands.
            return [.commandAck(commandId: UInt8(truncatingIfNeeded: (CRPCommands.groupDevice << 4) | (cmd & 0x0F)))]
        }
    }

    /// Decode group-7 responses: history queries (cmd 4–7, 14, 48) and device info (cmd 0, 1, 13).
    /// History layouts are unconfirmed against hardware — emit as CommandAck so the raw-packet feed
    /// records them without inventing metric values. Extend `decodeHistoryOrDeviceInfoResponse`
    /// as more layouts are confirmed.
    private static func decodeHistoryOrDeviceInfoResponse(cmd: Int, payload: [UInt8], now: Date) -> [RingDecodedEvent] {
        return [.commandAck(commandId: UInt8(truncatingIfNeeded: (CRPCommands.groupDeviceInfo << 4) | (cmd & 0x0F)))]
    }

    /// Little-endian unsigned 3-byte int at `offset`.
    private static func le3(_ b: [UInt8], _ offset: Int) -> Int {
        Int(b[offset]) | (Int(b[offset + 1]) << 8) | (Int(b[offset + 2]) << 16)
    }
}
