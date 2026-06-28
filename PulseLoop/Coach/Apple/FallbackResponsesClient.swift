import Foundation

/// Wraps a primary `ResponsesClient` with a secondary one used only when the
/// primary throws. Built for the on-device provider: try Apple's local model
/// first, and if it's unavailable or a generation fails, transparently retry the
/// same request on a chosen cloud provider.
///
/// Each `send` carries the full request body, so the secondary can serve a turn
/// the primary never saw. (A mid-conversation failover loses prior on-device
/// turn state — acceptable: the common case is the primary being unusable from
/// the start, which the resolver routes straight to the secondary instead.)
final class FallbackResponsesClient: ResponsesClient, @unchecked Sendable {
    private let primary: ResponsesClient
    private let secondary: ResponsesClient

    init(primary: ResponsesClient, secondary: ResponsesClient) {
        self.primary = primary
        self.secondary = secondary
    }

    func send(requestBody: Data) async throws -> OpenAIResponse {
        do {
            return try await primary.send(requestBody: requestBody)
        } catch {
            return try await secondary.send(requestBody: requestBody)
        }
    }
}
