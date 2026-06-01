import SwiftUI
import Charts

/// Renders a `CoachChart` whose data is already embedded (computed by the
/// `prepare_chart` tool). Generic over the five chart types; uses the point
/// index for x-position so heterogeneous x labels (dates, minutes) stay ordered.
struct CoachChartView: View {
    let chart: CoachChart
    var height: CGFloat = 170

    private var color: Color {
        switch chart.metric {
        case .steps: return PulseColors.steps
        case .hr: return PulseColors.heartRate
        case .spo2: return PulseColors.spo2
        case .sleep: return PulseColors.sleep
        case .activeMinutes: return PulseColors.accent
        case .calories: return PulseColors.calories
        case .distance: return PulseColors.distance
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(chart.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PulseColors.textSecondary)

            if chart.data.isEmpty {
                Text("No data to plot for this range.")
                    .font(.system(size: 12))
                    .foregroundStyle(PulseColors.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                plot.frame(height: height)
            }

            if !chart.annotations.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chart.annotations) { a in
                        Text("• \(a.label)")
                            .font(.system(size: 11))
                            .foregroundStyle(PulseColors.textMuted)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "#0F141F"), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    @ViewBuilder private var plot: some View {
        let indexed = Array(chart.data.enumerated())
        switch chart.chartType {
        case .line, .sparkline:
            Chart(indexed, id: \.offset) { i, point in
                LineMark(x: .value("i", i), y: .value("y", point.y))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .foregroundStyle(color)
            }
            .chartXAxis(.hidden)
            .chartYAxis(chart.chartType == .sparkline ? .hidden : .automatic)

        case .dot:
            Chart(indexed, id: \.offset) { i, point in
                PointMark(x: .value("i", i), y: .value("y", point.y))
                    .symbolSize(34)
                    .foregroundStyle(color)
            }
            .chartXAxis(.hidden)

        case .bar:
            Chart(indexed, id: \.offset) { i, point in
                BarMark(x: .value("x", point.x), y: .value("y", point.y))
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                    .foregroundStyle(color.opacity(0.8))
            }
            .chartYAxis(.hidden)

        case .sleepStage:
            Chart(indexed, id: \.offset) { i, point in
                BarMark(x: .value("i", i), y: .value("min", point.y))
                    .foregroundStyle(by: .value("stage", point.series ?? "—"))
            }
            .chartForegroundStyleScale([
                "deep": SleepStageColors.deep,
                "light": SleepStageColors.light,
                "awake": SleepStageColors.awake,
            ])
            .chartXAxis(.hidden)
        }
    }
}
