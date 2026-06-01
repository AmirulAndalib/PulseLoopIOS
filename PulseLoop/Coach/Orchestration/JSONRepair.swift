import Foundation

/// Best-effort parsing of the model's final structured output into a
/// `CoachResponse`. Tries a direct decode, then extracts the outermost JSON
/// object if the model wrapped it in prose or a code fence.
enum CoachResponseParser {
    static func parse(_ text: String) -> CoachResponse? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let direct = CoachResponse.decode(fromJSON: trimmed) { return direct }
        if let stripped = stripCodeFence(trimmed), let r = CoachResponse.decode(fromJSON: stripped) { return r }
        if let object = extractOutermostObject(trimmed), let r = CoachResponse.decode(fromJSON: object) { return r }
        return nil
    }

    private static func stripCodeFence(_ text: String) -> String? {
        guard text.hasPrefix("```") else { return nil }
        var body = text
        if let firstNewline = body.firstIndex(of: "\n") {
            body = String(body[body.index(after: firstNewline)...])
        }
        if let fenceRange = body.range(of: "```", options: .backwards) {
            body = String(body[..<fenceRange.lowerBound])
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractOutermostObject(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return String(text[start...end])
    }
}
