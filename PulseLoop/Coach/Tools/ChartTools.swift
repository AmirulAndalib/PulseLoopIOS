import Foundation
import SwiftData

/// `prepare_chart` — builds a ready-to-render `CoachChart` with embedded data.
/// The model copies the returned `chart` object verbatim into the final
/// response's `chart` field (same contract as the web app).
@MainActor
enum ChartTools {
    static var all: [AnyCoachTool] { [prepareChart] }

    private struct Annotation: Decodable { let x: String; let label: String }
    private struct Args: Decodable {
        let chartType: String, title: String, metric: String
        let start: String, end: String, annotations: [Annotation]
        enum CodingKeys: String, CodingKey {
            case chartType = "chart_type", title, metric, start, end, annotations
        }
    }

    struct PreparedChart: Encodable {
        let chart: CoachChart
        let pointCount: Int
        let note: String
    }

    private static var prepareChart: AnyCoachTool {
        .make(
            name: "prepare_chart",
            label: "Preparing a chart",
            description: "Build a ready-to-render chart (with embedded data) from ring data for a metric + date range. Returns a chart object to copy verbatim into the final response's `chart` field. For chart_type 'sleep_stage', uses the most recent sleep session in range.",
            parameters: JSONSchema.object([
                "chart_type": JSONSchema.enumString(["line", "bar", "dot", "sleep_stage", "sparkline"]),
                "title": JSONSchema.string,
                "metric": JSONSchema.enumString(["steps", "hr", "spo2", "sleep", "active_minutes", "calories", "distance"]),
                "start": JSONSchema.string,
                "end": JSONSchema.string,
                "annotations": JSONSchema.array(JSONSchema.object(
                    ["x": JSONSchema.string, "label": JSONSchema.string], required: ["x", "label"]
                )),
            ], required: ["chart_type", "title", "metric", "start", "end", "annotations"]),
            argsType: Args.self
        ) { args, ctx in
            guard let chartType = CoachChartType(rawValue: args.chartType) else {
                return .error("unknown chart_type '\(args.chartType)'")
            }
            guard let metric = CoachChartMetric.from(args.metric) else {
                return .error("unknown metric '\(args.metric)'")
            }

            let points: [CoachChartPoint]
            if chartType == .sleepStage {
                points = sleepStagePoints(start: args.start, end: args.end, context: ctx.modelContext)
            } else {
                points = CoachDataAccess.dailySeries(metric: metric, start: args.start, end: args.end, context: ctx.modelContext)
                    .map { CoachChartPoint(x: CoachDataAccess.localDateString($0.date), y: $0.value, series: nil) }
            }

            let chart = CoachChart(
                chartType: chartType,
                title: args.title,
                metric: metric,
                range: CoachChartRange(start: args.start, end: args.end),
                data: points,
                annotations: args.annotations.map { CoachChartAnnotation(x: $0.x, label: $0.label) }
            )
            return .encoding(PreparedChart(
                chart: chart,
                pointCount: points.count,
                note: "Copy this chart object verbatim into the final response's `chart` field. Empty data means there's nothing to plot for that range."
            ))
        }
    }

    private static func sleepStagePoints(start: String, end: String, context: ModelContext) -> [CoachChartPoint] {
        guard let session = CoachDataAccess.sleepSessions(start: start, end: end, context: context).last else { return [] }
        return SleepRepository.blocks(sessionId: session.id, context: context)
            .sorted { $0.startMinute < $1.startMinute }
            .map { CoachChartPoint(x: String($0.startMinute), y: Double($0.durationMinutes), series: $0.stage.rawValue) }
    }
}
