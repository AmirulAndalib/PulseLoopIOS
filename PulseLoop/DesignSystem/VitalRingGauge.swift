import SwiftUI

// Custom circular gauges for vitals. Built on `Shape`/`Canvas` rather than SwiftUI `Gauge` because
// the multi-zone track and the blood-pressure dual ring need bespoke arc rendering. Colors resolve
// through `VitalColorToken`/zones so a gauge matches its chart and legend exactly.

// MARK: - Arc shape

/// An arc spanning `startFraction…endFraction` of a full turn, measured clockwise from the top
/// (12 o'clock). `inset` shrinks the radius so concentric rings (e.g. BP systolic/diastolic) don't
/// overlap. Fractions are clamped to [0, 1].
struct RingSegment: Shape {
    let startFraction: Double
    let endFraction: Double
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2 - inset
        guard radius > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let start = max(0, min(1, startFraction))
        let end = max(0, min(1, endFraction))
        // -90° puts 0 at the top; full turn sweeps clockwise.
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90 + 360 * start),
            endAngle: .degrees(-90 + 360 * end),
            clockwise: false
        )
        return path
    }
}

// MARK: - Single-value gauge

/// A full-circle gauge: muted zone arcs in the track, a bright value arc, a marker dot, and a center
/// stack (value / unit / status). Sized large for full-width cards, small for compact two-up cards.
struct VitalRingGauge: View {
    let value: Double
    let domain: ClosedRange<Double>
    let zones: [MetricZone]
    let valueColor: Color
    let centerValue: String
    var centerUnit: String?
    var centerStatus: String?
    var subtitle: String?
    var size: CGFloat = 200
    var lineWidth: CGFloat = 16

    private func fraction(_ v: Double) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0 }
        return max(0, min(1, (v - domain.lowerBound) / span))
    }

    var body: some View {
        ZStack {
            // Track
            Circle()
                .stroke(PulseColors.elevated, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Muted zone arcs across the bounded part of each zone.
            ForEach(zones) { zone in
                let lower = fraction(zone.lower ?? domain.lowerBound)
                let upper = fraction(zone.upper ?? domain.upperBound)
                if upper > lower {
                    RingSegment(startFraction: lower, endFraction: upper)
                        .stroke(zone.color.opacity(0.30), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }
            }

            // Value arc from the bottom-ish origin up to the current value.
            RingSegment(startFraction: 0, endFraction: fraction(value))
                .stroke(valueColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Marker dot at the current value.
            markerDot

            VStack(spacing: 2) {
                Text(centerValue)
                    .font(.system(size: size * 0.26, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .contentTransition(.numericText())
                if let centerUnit {
                    Text(centerUnit).font(.system(size: size * 0.08, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                }
                if let centerStatus {
                    Text(centerStatus.uppercased())
                        .font(.system(size: size * 0.075, weight: .semibold)).tracking(1.0)
                        .foregroundStyle(valueColor)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: size * 0.065)).foregroundStyle(PulseColors.textMuted)
                }
            }
            .padding(lineWidth + 4)
        }
        .frame(width: size, height: size)
    }

    private var markerDot: some View {
        let angle = Angle.degrees(-90 + 360 * fraction(value))
        let r = size / 2 - lineWidth / 2
        return Circle()
            .fill(PulseColors.textPrimary)
            .frame(width: lineWidth * 0.5, height: lineWidth * 0.5)
            .offset(x: r * cos(angle.radians), y: r * sin(angle.radians))
    }
}

// MARK: - Dual-ring gauge (blood pressure)

/// Two concentric ring gauges for blood pressure: outer = systolic, inner = diastolic, each on its
/// own domain and zones. The center shows `122/78` and the worse-of-the-two category.
struct DualVitalRingGauge: View {
    let systolic: Double
    let diastolic: Double
    let systolicDomain: ClosedRange<Double>
    let diastolicDomain: ClosedRange<Double>
    let systolicZones: [MetricZone]
    let diastolicZones: [MetricZone]
    let statusLabel: String
    let statusColor: Color
    var size: CGFloat = 220
    var lineWidth: CGFloat = 14

    private func fraction(_ v: Double, _ domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return 0 }
        return max(0, min(1, (v - domain.lowerBound) / span))
    }

    var body: some View {
        ZStack {
            ringTrack(inset: 0)
            zoneArcs(systolicZones, domain: systolicDomain, inset: 0)
            RingSegment(startFraction: 0, endFraction: fraction(systolic, systolicDomain), inset: 0)
                .stroke(PulseColors.bloodPressure, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            let innerInset = lineWidth + 8
            ringTrack(inset: innerInset)
            zoneArcs(diastolicZones, domain: diastolicDomain, inset: innerInset)
            RingSegment(startFraction: 0, endFraction: fraction(diastolic, diastolicDomain), inset: innerInset)
                .stroke(PulseColors.bloodPressure.opacity(0.7), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(Int(systolic))").font(.system(size: size * 0.20, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("/").font(.system(size: size * 0.13, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                    Text("\(Int(diastolic))").font(.system(size: size * 0.20, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .foregroundStyle(PulseColors.textPrimary)
                Text("mmHg").font(.system(size: size * 0.06, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                Text(statusLabel.uppercased())
                    .font(.system(size: size * 0.06, weight: .semibold)).tracking(1.0)
                    .foregroundStyle(statusColor)
            }
        }
        .frame(width: size, height: size)
    }

    private func ringTrack(inset: CGFloat) -> some View {
        RingSegment(startFraction: 0, endFraction: 1, inset: inset)
            .stroke(PulseColors.elevated, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private func zoneArcs(_ zones: [MetricZone], domain: ClosedRange<Double>, inset: CGFloat) -> some View {
        ForEach(zones) { zone in
            let lower = fraction(zone.lower ?? domain.lowerBound, domain)
            let upper = fraction(zone.upper ?? domain.upperBound, domain)
            if upper > lower {
                RingSegment(startFraction: lower, endFraction: upper, inset: inset)
                    .stroke(zone.color.opacity(0.28), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
    }
}
