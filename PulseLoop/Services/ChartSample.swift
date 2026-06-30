import Foundation

/// A charting sample carrying enough context to render honestly: a real timestamp (so spacing
/// reflects time, not array index) and a source-quality flag (so low-confidence stretches can be
/// styled differently). Built from the store's `[MetricSample]` at view-model time.
struct ChartSample: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let value: Double
    let quality: SourceQuality

    init(id: UUID = UUID(), timestamp: Date, value: Double, quality: SourceQuality = .good) {
        self.id = id
        self.timestamp = timestamp
        self.value = value
        self.quality = quality
    }
}

enum ChartSampleBuilder {
    /// Map stored samples to chart samples, tagging each with a single resolved quality. Samples are
    /// assumed already time-sorted by `metricRange`; we sort defensively anyway.
    static func from(_ samples: [MetricSample], quality: SourceQuality = .good) -> [ChartSample] {
        samples
            .sorted { $0.timestamp < $1.timestamp }
            .map { ChartSample(timestamp: $0.timestamp, value: $0.value, quality: quality) }
    }

    /// Split a series into contiguous segments, breaking wherever the gap between adjacent samples
    /// exceeds `maxGap`. This prevents a line from drawing a false bridge across hours with no data
    /// (e.g. connecting a 2 AM reading straight to a 10 PM reading). Pure and order-preserving.
    static func segments(_ samples: [ChartSample], maxGap: TimeInterval) -> [[ChartSample]] {
        guard let first = samples.first else { return [] }
        guard samples.count > 1 else { return [[first]] }

        var result: [[ChartSample]] = []
        var current: [ChartSample] = [first]
        for (a, b) in zip(samples, samples.dropFirst()) {
            if b.timestamp.timeIntervalSince(a.timestamp) > maxGap {
                result.append(current)
                current = [b]
            } else {
                current.append(b)
            }
        }
        result.append(current)
        return result
    }

    /// The maximum allowed gap before a line breaks, tuned per range so denser windows break sooner.
    /// 24h → 90 min, 7d → 36 h, 30d → 4 days, 12mo → ~45 days.
    static func maxGap(for range: MetricRange) -> TimeInterval {
        switch range {
        case .twentyFourHours: return 90 * 60
        case .sevenDays: return 36 * 3600
        case .thirtyDays: return 4 * 86_400
        case .twelveMonths: return 45 * 86_400
        }
    }
}
