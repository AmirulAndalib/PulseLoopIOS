import Foundation
@preconcurrency import CoreBluetooth

/// Reassembles CRP command replies (`fdd3`) that span multiple BLE notifications. A logical frame
/// starts with `FD DA …` and its declared total length (`CRPProtocol.frameLength`) tells us when it
/// is complete. Mirrors the vendor's `g1/a.k()`. One assembler instance per connection — a fresh
/// `CRPDriver` is built on every connect, so state always starts clean.
final class CRPFrameAssembler {
    nonisolated deinit {}   // skip the main-actor isolated-deinit hop (crashes on older sim runtimes)

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

    /// `calendar` resolves the ring's day-relative history (`day 0` = today) against the device's
    /// **local** midnight, which is what the ring stamps against. Injectable so tests can pin a zone.
    static func decode(_ data: Data, from characteristic: CBUUID, now: Date = Date(),
                       calendar: Calendar = .current) -> [RingDecodedEvent] {
        switch characteristic {
        case CRPUUIDs.stepsNotifyCBUUID:
            return decodeCurrentSteps(data, now: now)
        default:
            return CRPProtocol.isFrameStart(data) ? decodeFramedReply(data, now: now, calendar: calendar) : []
        }
    }

    /// All-day timeline frames carry sample slots at a fixed 5-minute cadence (`w0.b.a() / 5` in the
    /// vendor). Two slot widths: HR/SpO2/stress store one byte per slot (144 slots/frame, terminal
    /// frame index 1); HRV stores a little-endian 2-byte value per slot (72 slots/frame, terminal
    /// index 3). Both reassemble to a 288-slot (24 h) day across their frames.
    private static let timingSlotMinutes = 5
    private static let timingSlotsPerFrame1Byte = 144
    private static let timingSlotsPerFrame2Byte = 72
    /// `CRPHistoryDay` tops out at 14 days ago; a wilder value is a corrupt reply, not a real day.
    private static let maxHistoryDay = 14
    private static let maxSleepMinutes = 24 * 60

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
    /// Real-time vital results come on group 1; stored day history on group 2; device info on group 7;
    /// power control + the autonomous wear-state push on group 3.
    private static func decodeFramedReply(_ frame: Data, now: Date, calendar: Calendar) -> [RingDecodedEvent] {
        let b = [UInt8](frame)
        if b.count < CRPProtocol.headerSize { return [] }
        let group = Int(b[4])
        let cmd = Int(b[5])
        let payload = b.count > CRPProtocol.headerSize ? Array(b[CRPProtocol.headerSize..<b.count]) : []
        func ack() -> [RingDecodedEvent] {
            [.commandAck(commandId: UInt8(truncatingIfNeeded: (group << 4) | (cmd & 0x0F)))]
        }

        // Group 1: real-time vital results (decompiled `g1/a.java` lines 664–712).
        if group == CRPCommands.groupDevice {
            return decodeVitalResult(cmd: cmd, payload: payload, now: now)
        }

        // Group 2: sleep + the all-day "timing" vital timelines + temperature history.
        //   cmd 14          → sleep (`e1/j`), confirmed against a hardware capture.
        //   cmd 15/16/17/47 → HR/HRV/SpO2/stress all-day timeline (`e1/{f,g,d,l}`), confirmed
        //                     against zaggash's R11 capture (Android issue #29).
        //   cmd 48          → temperature history, still an ack until a non-empty capture pins it.
        if group == CRPCommands.groupHistory {
            if cmd == CRPCommands.cmdQueryHistorySleep {
                return decodeSleep(payload, now: now, calendar: calendar)
            }
            if let timing = decodeTimingHistory(cmd: cmd, payload: payload, now: now, calendar: calendar) {
                return timing
            }
            return ack()
        }

        // Group 7: device info (decompiled `b1/r`).
        if group == CRPCommands.groupDeviceInfo {
            return decodeHistoryOrDeviceInfoResponse(cmd: cmd, payload: payload, now: now)
        }

        // Group 3: power control + the autonomous wear-state push (`g1/a.java` case 3→7,
        // `onWearStateChange(payload[0] > 0)`). Confirmed against zaggash's R11: a spot measure
        // returns nothing while `payload[0] == 0` (ring off the finger).
        if group == CRPCommands.groupPower {
            if cmd == CRPCommands.cmdWearState, let first = payload.first {
                return [.wearingStatus(worn: first != 0, timestamp: now)]
            }
            return ack()
        }

        // Unknown group/cmd — ack.
        return ack()
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
        case CRPCommands.cmdResultHR:
            // HR from `e1/f.b()`: byte2int(payload[0]).
            guard value >= 40 && value <= 200 else { return [] }
            return [.heartRateSample(bpm: value, timestamp: now)]

        case CRPCommands.cmdResultHRV:
            // HRV: the vendor's live `onHrv()` receives byte2int(payload[0]).
            guard value >= 20 && value <= 200 else { return [] }
            return [.hrvSample(value: value, timestamp: now)]

        case CRPCommands.cmdResultSpO2:
            // SpO2 from `e1/d.b()`: byte2int(payload[0]).
            guard value >= 70 && value <= 100 else { return [] }
            return [.spo2Result(value: value, timestamp: now)]

        case CRPCommands.cmdResultStress:
            // Stress/physical strength: byte2int(payload[0]).
            guard value >= 0 && value <= 100 else { return [] }
            return [.stressSample(value: value, timestamp: now)]

        case CRPCommands.cmdResultTemp:
            // Vendor `e1/m.a(payload[1], payload[0])`: twoBytes2int / 10, valid 28.0…50.0 °C.
            guard payload.count >= 2 else { return [] }
            let celsius = Double((Int(payload[1]) << 8) | Int(payload[0])) / 10.0
            guard celsius >= 28.0 && celsius <= 50.0 else { return [] }
            return [.temperatureSample(celsius: celsius, timestamp: now)]

        default:
            // Acknowledgment for enable/disable commands.
            return [.commandAck(commandId: UInt8(truncatingIfNeeded: (CRPCommands.groupDevice << 4) | (cmd & 0x0F)))]
        }
    }

    /// Decode a CRP all-day "timing" vital-history reply (group 2). Returns `nil` for a non-timing
    /// group-2 cmd (e.g. temp cmd 48) so the caller falls back to an ack. Layout, confirmed against
    /// zaggash's R11 capture and the vendor parsers `e1/{f,g,d,l}.java`:
    ///   `[day][frameIndex][slot samples…]` — one 5-minute slot per sample, `0` = no reading.
    /// HR/SpO2/stress use one byte per slot; HRV a little-endian 2-byte value. Each slot's absolute
    /// time is `localMidnight(today − day) + (frameIndex*slotsPerFrame + slot)*5min`, matching the
    /// vendor's `w0.b.a()/5` slot indexing. Emits one `.historyMeasurement` per valid slot plus a
    /// trailing `.timingHistoryFrame` that drives the engine's next-frame follow-up.
    private static func decodeTimingHistory(cmd: Int, payload: [UInt8], now: Date,
                                            calendar: Calendar) -> [RingDecodedEvent]? {
        // (kind, sample byte-width, validity predicate) per vital. Ranges mirror the vendor clamps:
        // HR 40…200 (`e1/f.e`), SpO2 1…100 (`e1/d.e`, >100→0), HRV any positive (`e1/g.d`, no clamp),
        // stress 1…100 (`e1/l.d`, no clamp; 0 treated as no-reading). Zero is always "no sample".
        let kind: MeasurementKind
        let twoByte: Bool
        let valid: (Int) -> Bool
        switch cmd {
        case CRPCommands.cmdQueryTimingHR:
            kind = .heartRate; twoByte = false; valid = { $0 >= 40 && $0 <= 200 }
        case CRPCommands.cmdQueryTimingSpO2:
            kind = .spo2; twoByte = false; valid = { $0 >= 1 && $0 <= 100 }
        case CRPCommands.cmdQueryTimingHRV:
            kind = .hrv; twoByte = true; valid = { $0 >= 1 && $0 <= 300 }
        case CRPCommands.cmdQueryTimingStress:
            kind = .stress; twoByte = false; valid = { $0 >= 1 && $0 <= 100 }
        default:
            return nil
        }
        // [day][frameIndex] header; anything shorter is malformed.
        if payload.count < 2 { return [] }
        let day = Int(payload[0])
        let frameIndex = Int(payload[1])
        // A wilder day than CRPHistoryDay allows is a corrupt reply — ack without inventing samples.
        if day > maxHistoryDay {
            return [.commandAck(commandId: UInt8(truncatingIfNeeded: (CRPCommands.groupHistory << 4) | (cmd & 0x0F)))]
        }
        guard let midnight = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now)) else {
            return []
        }

        let slotsPerFrame = twoByte ? timingSlotsPerFrame2Byte : timingSlotsPerFrame1Byte
        let step = twoByte ? 2 : 1
        var events: [RingDecodedEvent] = []
        var slot = 0
        var i = 2
        while i + step - 1 < payload.count {
            let value = twoByte ? (Int(payload[i]) | (Int(payload[i + 1]) << 8)) : Int(payload[i])
            if valid(value) {
                let globalSlot = frameIndex * slotsPerFrame + slot
                let ts = midnight.addingTimeInterval(Double(globalSlot * timingSlotMinutes * 60))
                events.append(.historyMeasurement(kind: kind, value: Double(value), timestamp: ts))
            }
            i += step
            slot += 1
        }
        // Drive the vendor's sequential next-frame pull (see `.timingHistoryFrame`).
        events.append(.timingHistoryFrame(cmd: cmd, day: day, frameIndex: frameIndex))
        return events
    }

    /// Decode group-7 responses: history queries (cmd 4–7, 14, 48) and device info (cmd 0, 1, 13).
    /// History layouts are unconfirmed against hardware — emit as CommandAck so the raw-packet feed
    /// records them without inventing metric values. Extend `decodeHistoryOrDeviceInfoResponse`
    /// as more layouts are confirmed.
    private static func decodeHistoryOrDeviceInfoResponse(cmd: Int, payload: [UInt8], now: Date) -> [RingDecodedEvent] {
        return [.commandAck(commandId: UInt8(truncatingIfNeeded: (CRPCommands.groupDeviceInfo << 4) | (cmd & 0x0F)))]
    }

    private struct SleepTransition {
        let elapsed: Int
        let state: Int
    }

    /// Decode a sleep-history reply (`group 2 / cmd 14`), a faithful port of the vendor parser
    /// `e1/j.b` (Moyoung "Da Rings"). Layout: `[dayIndex]` then repeating 3-byte records
    /// `[state, hour, minute]`, where a record marks the moment sleep entered `state` and that state
    /// runs until the NEXT record's timestamp (state 0=awake, 1=light, 2=deep, 3=rem). The vendor
    /// requires `length % 3 == 1` (one day byte + N whole records); anything else is malformed.
    ///
    /// Confirmed against a hardware capture (Android issue #29): a `dayIndex 0` reply of 26 records
    /// decoded to a clean 01:07→08:05 night (245 light / 110 deep / 63 REM minutes).
    ///
    /// Emitted as `.sleepTimeline`s whose `stages` lists are one entry per minute, matching
    /// `ColmiDecoder`'s sleep shape. A day's reply can hold more than one bout (a night plus a nap),
    /// so we split at any awake run of `SleepSegmentation.sessionGapMinutes`+ — the same gap the
    /// persistence layer uses to separate sessions. Short mid-night wakes stay inside their bout.
    ///
    /// Two deliberate departures from the vendor:
    ///  - The vendor extends the final record's state to the current wall-clock when it isn't awake
    ///    (an in-progress sleep). We don't — a completed night always ends on an awake record, so the
    ///    only case affected is a sync taken mid-sleep, where showing the night up to the last real
    ///    transition beats inventing minutes up to "now".
    ///  - Session-start anchoring is ours (the vendor keeps minute-of-day only and lets the UI place
    ///    the date from `dayIndex`). We anchor the FIRST record on the wake day (`today − dayIndex`)
    ///    with the same evening-rollover rule as Colmi — a first record later in the clock than the
    ///    last means the night began before midnight — then place later bouts by elapsed offset.
    ///    NOTE: assumes `dayIndex` is the WAKE day; verified against a post-midnight capture, but an
    ///    evening-start night is not yet capture-confirmed.
    private static func decodeSleep(_ payload: [UInt8], now: Date, calendar: Calendar) -> [RingDecodedEvent] {
        // [dayIndex] + N*[state,hour,minute]; the vendor rejects any other shape outright.
        if payload.count < 4 || payload.count % 3 != 1 { return [] }
        let dayIndex = Int(payload[0])
        if dayIndex > maxHistoryDay { return [] }
        let recordCount = (payload.count - 1) / 3

        // Pass 1: fold records into monotonic transition points — an elapsed-minute offset from the
        // first valid record plus the state beginning there. Corrupt records are skipped without
        // advancing the cursor, matching the vendor's `iA >= 0` guard.
        var transitions: [SleepTransition] = []
        var firstMinuteOfDay = -1
        var lastMinuteOfDay = 0
        var elapsed = 0
        var prevHour = 0
        var prevMinute = 0
        for k in 0..<recordCount {
            let off = 1 + k * 3
            let state = Int(payload[off])
            let hour = Int(payload[off + 1])
            let minute = Int(payload[off + 2])
            if hour > 23 || minute > 59 { continue }
            if transitions.isEmpty {
                firstMinuteOfDay = hour * 60 + minute
                lastMinuteOfDay = firstMinuteOfDay
                transitions.append(SleepTransition(elapsed: 0, state: state))
            } else {
                let duration = sleepSegmentMinutes(prevHour: prevHour, prevMinute: prevMinute,
                                                   hour: hour, minute: minute)
                if duration < 0 || duration > maxSleepMinutes { continue }
                elapsed += duration
                lastMinuteOfDay = hour * 60 + minute
                transitions.append(SleepTransition(elapsed: elapsed, state: state))
            }
            prevHour = hour
            prevMinute = minute
        }
        if transitions.count < 2 { return [] }

        // Anchor the first record; every bout is then just an offset from it.
        let startOffset = firstMinuteOfDay > lastMinuteOfDay ? firstMinuteOfDay - 1440 : firstMinuteOfDay
        guard let wakeDayStart = calendar.date(byAdding: .day, value: -dayIndex,
                                               to: calendar.startOfDay(for: now)) else { return [] }
        let anchor = wakeDayStart.addingTimeInterval(Double(startOffset) * 60)

        // Pass 2: each transition's state runs until the next; split bouts on a long awake gap.
        var events: [RingDecodedEvent] = []
        var boutStages: [SleepStage] = []
        var boutStartElapsed = 0
        for i in 0..<(transitions.count - 1) {
            let segment = transitions[i]
            let duration = transitions[i + 1].elapsed - segment.elapsed
            if duration <= 0 { continue }
            let stage = mapSleepState(segment.state)
            if stage == .awake && duration >= SleepSegmentation.sessionGapMinutes {
                emitSleepBout(into: &events, anchor: anchor, startElapsed: boutStartElapsed, stages: boutStages)
                boutStages = []
                continue
            }
            if boutStages.isEmpty { boutStartElapsed = segment.elapsed }
            boutStages.append(contentsOf: repeatElement(stage, count: duration))
        }
        emitSleepBout(into: &events, anchor: anchor, startElapsed: boutStartElapsed, stages: boutStages)
        return events
    }

    /// Emit a bout as a `.sleepTimeline`, unless it holds no actual sleep (awake-only).
    private static func emitSleepBout(into events: inout [RingDecodedEvent], anchor: Date,
                                      startElapsed: Int, stages: [SleepStage]) {
        if !stages.contains(where: { $0 != .awake }) { return }
        events.append(.sleepTimeline(timestamp: anchor.addingTimeInterval(Double(startElapsed) * 60),
                                     stages: stages))
    }

    /// Minutes from a previous `hh:mm` to this one, wrapping across midnight (vendor `e1/j.a`).
    private static func sleepSegmentMinutes(prevHour: Int, prevMinute: Int, hour: Int, minute: Int) -> Int {
        let wrappedHour = prevHour > hour ? hour + 24 : hour
        return ((wrappedHour - prevHour) * 60 + minute) - prevMinute
    }

    /// Vendor `e1/j.c` state codes → shared `SleepStage`.
    private static func mapSleepState(_ state: Int) -> SleepStage {
        switch state {
        case 0: return .awake
        case 1: return .light
        case 2: return .deep
        case 3: return .rem
        default: return .unknown
        }
    }

    /// Little-endian unsigned 3-byte int at `offset`.
    private static func le3(_ b: [UInt8], _ offset: Int) -> Int {
        Int(b[offset]) | (Int(b[offset + 1]) << 8) | (Int(b[offset + 2]) << 16)
    }
}
