import XCTest
@testable import PulseLoop

/// Locks the timestamp-based charting: gap-breaking and the timestamp-not-index regression guard.
final class ChartSampleSegmentTests: XCTestCase {

    private func sample(_ minutesFromNow: Double, _ value: Double) -> ChartSample {
        ChartSample(timestamp: Date(timeIntervalSince1970: minutesFromNow * 60), value: value)
    }

    func testGapBreaksAcrossLargeGap() {
        // Two readings 5 min apart, then a 6h jump, then two more 5 min apart.
        let samples = [
            sample(0, 70), sample(5, 72),
            sample(365, 68), sample(370, 69),   // 360 min == 6h after the previous
        ]
        let maxGap = ChartSampleBuilder.maxGap(for: .twentyFourHours)   // 90 min
        let segments = ChartSampleBuilder.segments(samples, maxGap: maxGap)
        XCTAssertEqual(segments.count, 2, "the 6h gap must split the line into two segments")
        XCTAssertEqual(segments[0].count, 2)
        XCTAssertEqual(segments[1].count, 2)
    }

    func testNoBreakWithinTolerance() {
        // Three readings 30 min apart stay one continuous segment at 24h tolerance.
        let samples = [sample(0, 70), sample(30, 71), sample(60, 72)]
        let segments = ChartSampleBuilder.segments(samples, maxGap: ChartSampleBuilder.maxGap(for: .twentyFourHours))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 3)
    }

    func testSingleSampleIsOneSegment() {
        let segments = ChartSampleBuilder.segments([sample(0, 70)], maxGap: 90 * 60)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].count, 1)
    }

    func testEmptyProducesNoSegments() {
        XCTAssertTrue(ChartSampleBuilder.segments([], maxGap: 90 * 60).isEmpty)
    }

    func testMaxGapPerRange() {
        XCTAssertEqual(ChartSampleBuilder.maxGap(for: .twentyFourHours), 90 * 60)
        XCTAssertEqual(ChartSampleBuilder.maxGap(for: .sevenDays), 36 * 3600)
        XCTAssertEqual(ChartSampleBuilder.maxGap(for: .thirtyDays), 4 * 86_400)
    }

    /// The core correctness guard: charting must be driven by timestamps, not array index. Two samples
    /// 8 hours apart must map to x-positions 8h apart in the time domain — not "one index apart".
    func testChartUsesTimestampSpacingNotIndex() {
        let early = sample(0, 70)
        let late = sample(480, 90)   // 8 hours later
        let chart = ChartSampleBuilder.from([
            MetricSample(timestamp: early.timestamp, value: early.value),
            MetricSample(timestamp: late.timestamp, value: late.value),
        ])
        XCTAssertEqual(chart.count, 2)
        // The x-values are real Dates whose spacing is 8h, not a unit index step.
        let spacing = chart[1].timestamp.timeIntervalSince(chart[0].timestamp)
        XCTAssertEqual(spacing, 8 * 3600, accuracy: 1, "timestamp spacing must reflect real time, not index")
        // And they're ordered ascending in time.
        XCTAssertLessThan(chart[0].timestamp, chart[1].timestamp)
    }

    func testFromSortsByTimestamp() {
        let out = ChartSampleBuilder.from([
            MetricSample(timestamp: Date(timeIntervalSince1970: 100), value: 2),
            MetricSample(timestamp: Date(timeIntervalSince1970: 50), value: 1),
        ])
        XCTAssertEqual(out.map(\.value), [1, 2], "samples must be time-sorted")
    }
}
