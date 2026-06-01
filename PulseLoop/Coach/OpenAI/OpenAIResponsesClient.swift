import Foundation

/// Transport-agnostic interface the orchestrator depends on (so tests can inject
/// a stub). Takes a pre-serialized request body so no non-Sendable dictionaries
/// cross the concurrency boundary.
protocol ResponsesClient: Sendable {
    func send(requestBody: Data) async throws -> OpenAIResponse
}

/// Hand-rolled OpenAI Responses API client (`POST /v1/responses`). There's no
/// official Swift SDK for the Responses API, so this is a thin URLSession call.
struct OpenAIResponsesClient: ResponsesClient {
    let apiKey: String
    let session: URLSession
    let endpoint: URL

    init(
        apiKey: String,
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) {
        self.apiKey = apiKey
        self.session = session
        self.endpoint = endpoint
    }

    func send(requestBody: Data) async throws -> OpenAIResponse {
        guard !apiKey.isEmpty else { throw ResponsesError.missingAPIKey }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = requestBody
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResponsesError.transport(error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ResponsesError.http(status: http.statusCode, body: body)
        }

        return try OpenAIResponse.parse(data)
    }
}
