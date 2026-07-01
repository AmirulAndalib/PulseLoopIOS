import SwiftUI
import SwiftData
import Charts

/// Tap-through trends for the daily activity summary widget. Apple-Fitness-style compact overview:
/// a Week/Month/Year segmented control drives three stacked histogram sections (Steps, Distance,
/// Calories), each showing the average-per-day for the range, a date-range label, a metric-colored
/// bar chart, and a dashed goal line + label inside the chart. UI only — all data comes from the
/// existing `MetricsService.metricRange` fetch path (daily bars for Week/Month, monthly-total bars
/// for Year); no new data plumbing, storage, or goal logic.
struct ActivityTrendsView: View {
    @Binding var path: NavigationPath
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]

    @State private var period: MetricRange = .sevenDays

    private var units: UnitsPreference { profiles.first?.units ?? .metric }
    private var distanceUnit: String { UnitsFormatter.distance(meters: 0, units: units).unit }

    var body: some View {
        let summary = MetricsService.buildTodaySummary(context: modelContext)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                periodSelector
                    .padding(.bottom, 2)

                stepsSection(summary)
                distanceSection(summary)
                caloriesSection(summary)
            }
            .padding(16)
            .padding(.bottom, 40)
            .animation(.easeInOut(duration: 0.25), value: period)
        }
        .background(PulseColors.background)
        .navigationTitle("Activity Trends")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Period selector

    private var periodSelector: some View {
        Picker("Period", selection: $period) {
            Text("Week").tag(MetricRange.sevenDays)
            Text("Month").tag(MetricRange.thirtyDays)
            Text("Year").tag(MetricRange.twelveMonths)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Metric sections

    /// Per-day samples for a metric in the current period, so every bar is comparable to the daily
    /// goal line. Week uses the aligned Mon–Sun 7-day trend (exactly 7 points, correct even in demo
    /// mode). Month uses `metricRange` daily bars. Year always returns a fixed 12-bucket scaffold of
    /// the last 12 calendar months (oldest→newest), each holding that month's per-day average — months
    /// with no data render as empty bars — so the axis is stable and the bars sit against the daily goal.
    private func samples(for metric: MetricKey, trend: [DailyMetricPoint]) -> [MetricSample] {
        if period == .sevenDays {
            return trend.map { MetricSample(timestamp: $0.date, value: $0.value) }
        }
        if period != .twelveMonths {
            return MetricsService.metricRange(metric: metric, range: period, context: modelContext)
        }
        let cal = Calendar.current
        // Monthly totals keyed by year-month from the existing fetch.
        let raw = MetricsService.metricRange(metric: metric, range: .twelveMonths, context: modelContext)
        var totals: [DateComponents: Double] = [:]
        for s in raw {
            let key = cal.dateComponents([.year, .month], from: s.timestamp)
            totals[key, default: 0] += s.value
        }
        // Build the last 12 months, oldest first, filling gaps with 0.
        let thisMonthStart = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return (0..<12).reversed().compactMap { offset -> MetricSample? in
            guard let monthStart = cal.date(byAdding: .month, value: -offset, to: thisMonthStart) else { return nil }
            let key = cal.dateComponents([.year, .month], from: monthStart)
            let days = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
            let perDay = days > 0 ? (totals[key] ?? 0) / Double(days) : 0
            return MetricSample(timestamp: monthStart, value: perDay)
        }
    }

    private func stepsSection(_ summary: TodaySummary) -> some View {
        let samples = samples(for: .steps, trend: summary.trends.steps7d)
        let values = samples.map(\.value)
        let avg = dailyAverage(values)
        return metricSection(
            title: "Steps",
            color: PulseColors.steps,
            values: values,
            samples: samples,
            average: avg.map { "\(Int($0.rounded()).formatted()) steps/day" },
            goal: Double(summary.goals.stepsDaily),
            goalLabel: "Goal \(summary.goals.stepsDaily.formatted())"
        )
    }

    private func distanceSection(_ summary: TodaySummary) -> some View {
        let samples = samples(for: .distance, trend: summary.trends.distance7d)
        // Convert every metre sample to the user's display unit for both bars and the average.
        let values = samples.map { Double(UnitsFormatter.distance(meters: $0.value, units: units).value) ?? 0 }
        let avg = dailyAverage(values)
        let goalDisplay = Double(UnitsFormatter.distance(meters: summary.goals.distanceMetersDaily, units: units).value) ?? 0
        return metricSection(
            title: "Distance",
            color: PulseColors.distance,
            values: values,
            samples: samples,
            average: avg.map { String(format: "%.2f \(distanceUnit)/day", $0) },
            goal: goalDisplay > 0 ? goalDisplay : nil,
            goalLabel: goalDisplay > 0 ? String(format: "Goal %.1f \(distanceUnit)", goalDisplay) : nil
        )
    }

    private func caloriesSection(_ summary: TodaySummary) -> some View {
        // If the ring doesn't track active energy, show the section empty (— cal/day, no bars) rather
        // than raw ring values — matches the summary widget and the Today page's `isVisible` gating.
        let available = MetricsService.isVisible(.calories, context: modelContext)
        let samples = available ? samples(for: .calories, trend: summary.trends.calories7d) : []
        let values = samples.map(\.value)
        let avg = dailyAverage(values)
        return metricSection(
            title: "Calories",
            color: PulseColors.calories,
            values: values,
            samples: samples,
            average: avg.map { "\(Int($0.rounded()).formatted()) cal/day" },
            goal: Double(summary.goals.caloriesDaily),
            goalLabel: "Goal \(summary.goals.caloriesDaily.formatted()) cal"
        )
    }

    // MARK: - Section card

    private func metricSection(
        title: String,
        color: Color,
        values: [Double],
        samples: [MetricSample],
        average: String?,
        goal: Double?,
        goalLabel: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(color)
                Spacer()
                Text(average ?? "— /day")
                    .font(.system(size: 19, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(average == nil ? PulseColors.textMuted : PulseColors.textPrimary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            Text(rangeLabel(samples: samples))
                .font(.system(size: 12))
                .foregroundStyle(PulseColors.textMuted)

            TrendBarChart(
                values: values,
                color: color,
                goal: goal,
                goalLabel: goalLabel,
                axisLabels: axisLabels(count: values.count, samples: samples)
            )
            .frame(height: 96)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(PulseColors.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(PulseColors.borderSubtle, lineWidth: 1))
    }

    // MARK: - Derived values

    /// The headline average-per-day: the mean of the per-day bar values shown. Bars are already daily
    /// (Week/Month) or per-month daily-averages (Year). For Year the 12-month scaffold pads missing
    /// months with 0, so average only the months that actually have data (mirrors "days with data").
    /// Empty ⇒ nil (rendered as "— /day"); never divides by zero.
    private func dailyAverage(_ values: [Double]) -> Double? {
        let considered = period == .twelveMonths ? values.filter { $0 > 0 } : values
        guard !considered.isEmpty else { return nil }
        return considered.reduce(0, +) / Double(considered.count)
    }

    // MARK: - Labels

    private func rangeLabel(samples: [MetricSample]) -> String {
        let cal = Calendar.current
        switch period {
        case .twelveMonths:
            let year = cal.component(.year, from: samples.last?.timestamp ?? Date())
            return "\(year)"
        default:
            guard let first = samples.first?.timestamp, let last = samples.last?.timestamp else {
                return period == .thirtyDays ? "Last 30 days" : "Last 7 days"
            }
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return "\(f.string(from: first)) – \(f.string(from: last))"
        }
    }

    /// Sparse x-axis labels keyed by bar index. Week: every day (M–S). Month: a date roughly every
    /// ~4 days (denser than week starts). Year: 3-letter month for all 12 buckets.
    private func axisLabels(count: Int, samples: [MetricSample]) -> [Int: String] {
        let cal = Calendar.current
        switch period {
        case .sevenDays:
            let letters = ["M", "T", "W", "T", "F", "S", "S"]
            var map: [Int: String] = [:]
            for i in 0..<count {
                if let ts = samples[safe: i]?.timestamp {
                    let weekday = cal.component(.weekday, from: ts) // 1=Sun..7=Sat
                    map[i] = letters[(weekday + 5) % 7]
                } else {
                    map[i] = letters[safe: i] ?? ""
                }
            }
            return map
        case .twelveMonths:
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            var map: [Int: String] = [:]
            for i in 0..<count {
                if let ts = samples[safe: i]?.timestamp {
                    map[i] = months[cal.component(.month, from: ts) - 1]
                }
            }
            return map
        default: // .thirtyDays — label the day-of-month at a stable step (~every 4th bar)
            var map: [Int: String] = [:]
            guard count > 0 else { return map }
            let step = Swift.max(1, Int((Double(count) / 7).rounded()))
            for i in stride(from: 0, to: count, by: step) {
                if let ts = samples[safe: i]?.timestamp {
                    map[i] = "\(cal.component(.day, from: ts))"
                }
            }
            return map
        }
    }
}

// MARK: - Compact trend bar chart

/// Metric-colored histogram with an independent y-scale, a dashed goal line + right-aligned goal
/// label, and sparse x-axis labels. The last (most recent) bar uses the full color; older bars are
/// muted. Bars over the goal extend above the line (no visual cap). Nil/zero-safe scaling.
private struct TrendBarChart: View {
    let values: [Double]
    let color: Color
    var goal: Double?
    var goalLabel: String?
    var axisLabels: [Int: String]

    private var chartMax: Double {
        let observed = values.max() ?? 0
        let target = Swift.max(goal ?? 0, observed) * 1.15
        return target > 0 ? target : 1
    }

    /// Slightly thicker, count-aware bars: chunky for few bars (Week/Year), thinner but still solid
    /// for the dense Month view.
    private var barWidth: MarkDimension {
        switch values.count {
        case 0...12: return .fixed(14)
        case 13...20: return .fixed(10)
        default: return .fixed(6)
        }
    }

    /// Stable per-bar category key (zero-padded so the string sort matches index order). A categorical
    /// x-axis puts bars and their labels on the same band, so they align by construction.
    private func key(_ index: Int) -> String { String(format: "%03d", index) }
    private var orderedKeys: [String] { (0..<values.count).map(key) }

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                BarMark(
                    x: .value("bar", key(index)),
                    y: .value("value", value),
                    width: barWidth
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
                .foregroundStyle(color.opacity(index == values.count - 1 ? 1 : 0.55))
            }
            if let goal, goal > 0 {
                RuleMark(y: .value("goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(color.opacity(0.7))
                    .annotation(position: .top, alignment: .trailing) {
                        if let goalLabel {
                            Text(goalLabel)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(color)
                        }
                    }
            }
        }
        .chartYScale(domain: 0...chartMax)
        .chartYAxis(.hidden)
        .chartXScale(domain: orderedKeys) // fixed category order = stable slots, empty bars keep their place
        .chartXAxis {
            AxisMarks(values: orderedKeys) { value in
                if let k = value.as(String.self), let index = Int(k), let label = axisLabels[index] {
                    AxisValueLabel {
                        Text(label).font(.system(size: 10)).foregroundStyle(PulseColors.textMuted)
                    }
                }
            }
        }
        .overlay(alignment: .center) {
            if values.isEmpty {
                Text("No data for this period")
                    .font(.system(size: 12)).foregroundStyle(PulseColors.textMuted)
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
