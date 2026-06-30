import SwiftUI

// Custom gauges for vitals: a 270° open-bottom arc (gap at the bottom) with the metric's zones drawn
// as colored arc segments, a value arc, and a marker centered on the stroke. Built on `Shape` rather
// than SwiftUI `Gauge` because the multi-zone track and the BP dual ring need bespoke rendering.
// Colors resolve through `VitalColorToken`/zones so a gauge matches its chart and legend exactly.

/// Shared gauge geometry: a 270° sweep starting bottom-left, leaving a 90° gap centered at the
/// bottom. `0°` is at 3 o'clock and angles increase clockwise (SwiftUI convention).
private enum GaugeGeometry {
    /// Start at 135° (bottom-left); sweep 270° clockwise to 405° (bottom-right).
    static let startAngle: Double = 135
    static let sweep: Double = 270

    /// The on-screen angle for a 0…1 fraction along the arc.
    static func angle(for fraction: Double) -> Angle {
        .degrees(startAngle + sweep * max(0, min(1, fraction)))
    }
}

// MARK: - Arc shape

/// An arc spanning `startFraction…endFraction` of the 270° gauge sweep. `inset` shrinks the radius so
/// concentric rings (BP systolic/diastolic) don't overlap. Fractions are clamped to [0, 1].
struct RingSegment: Shape {
    let startFraction: Double
    let endFraction: Double
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(rect.width, rect.height) / 2 - inset
        guard radius > 0 else { return path }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        path.addArc(
            center: center,
            radius: radius,
            startAngle: GaugeGeometry.angle(for: startFraction),
            endAngle: GaugeGeometry.angle(for: endFraction),
            clockwise: false
        )
        return path
    }
}

// MARK: - Single-value gauge

/// A 270° gauge: muted zone arcs in the track, a bright value arc, a marker dot centered on the
/// stroke, and a center stack (value / unit / status). The value lives only here (the card chrome
/// does not repeat it).
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
            // Track (the full 270° arc).
            RingSegment(startFraction: 0, endFraction: 1)
                .stroke(PulseColors.elevated, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            // Muted zone arcs.
            ForEach(zones) { zone in
                let lower = fraction(zone.lower ?? domain.lowerBound)
                let upper = fraction(zone.upper ?? domain.upperBound)
                if upper > lower {
                    RingSegment(startFraction: lower, endFraction: upper)
                        .stroke(zone.color.opacity(0.32), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                }
            }

            // Value arc from the start up to the current value.
            RingSegment(startFraction: 0, endFraction: fraction(value))
                .stroke(valueColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

            markerDot

            VStack(spacing: 2) {
                Text(centerValue)
                    .font(.system(size: size * 0.30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(PulseColors.textPrimary)
                    .contentTransition(.numericText())
                if let centerUnit {
                    Text(centerUnit).font(.system(size: size * 0.08, weight: .medium)).foregroundStyle(PulseColors.textMuted)
                }
                if let centerStatus {
                    Text(centerStatus.uppercased())
                        .font(.system(size: size * 0.08, weight: .semibold)).tracking(1.0)
                        .foregroundStyle(valueColor)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: size * 0.065)).foregroundStyle(PulseColors.textMuted)
                }
            }
        }
        .frame(width: size, height: size)
    }

    /// Marker centered on the stroke centerline (`r = size/2 - lineWidth/2`), at the same angle basis
    /// as the arcs — this is what keeps it sitting cleanly on the ring.
    private var markerDot: some View {
        let angle = GaugeGeometry.angle(for: fraction(value))
        let r = size / 2 - lineWidth / 2
        return Circle()
            .fill(PulseColors.textPrimary)
            .frame(width: lineWidth * 0.55, height: lineWidth * 0.55)
            .offset(x: r * cos(angle.radians), y: r * sin(angle.radians))
    }
}

// MARK: - Dual-ring gauge (blood pressure)

/// Two concentric 270° gauges: outer = systolic, inner = diastolic, each on its own domain and zones.
/// Center shows `122/78` and the worse-of-the-two category. Each ring carries a marker.
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

    private var innerInset: CGFloat { lineWidth + 8 }

    var body: some View {
        ZStack {
            // Outer ring = systolic.
            ring(zones: systolicZones, domain: systolicDomain, value: systolic, inset: 0,
                 valueColor: PulseColors.bloodPressure)
            marker(fraction: fraction(systolic, systolicDomain), inset: 0)

            // Inner ring = diastolic.
            ring(zones: diastolicZones, domain: diastolicDomain, value: diastolic, inset: innerInset,
                 valueColor: PulseColors.bloodPressure.opacity(0.7))
            marker(fraction: fraction(diastolic, diastolicDomain), inset: innerInset)

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

    @ViewBuilder
    private func ring(zones: [MetricZone], domain: ClosedRange<Double>, value: Double,
                      inset: CGFloat, valueColor: Color) -> some View {
        RingSegment(startFraction: 0, endFraction: 1, inset: inset)
            .stroke(PulseColors.elevated, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        ForEach(zones) { zone in
            let lower = fraction(zone.lower ?? domain.lowerBound, domain)
            let upper = fraction(zone.upper ?? domain.upperBound, domain)
            if upper > lower {
                RingSegment(startFraction: lower, endFraction: upper, inset: inset)
                    .stroke(zone.color.opacity(0.30), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            }
        }
        RingSegment(startFraction: 0, endFraction: fraction(value, domain), inset: inset)
            .stroke(valueColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
    }

    private func marker(fraction: Double, inset: CGFloat) -> some View {
        let angle = GaugeGeometry.angle(for: fraction)
        let r = size / 2 - inset - lineWidth / 2
        return Circle()
            .fill(PulseColors.textPrimary)
            .frame(width: lineWidth * 0.5, height: lineWidth * 0.5)
            .offset(x: r * cos(angle.radians), y: r * sin(angle.radians))
    }
}
