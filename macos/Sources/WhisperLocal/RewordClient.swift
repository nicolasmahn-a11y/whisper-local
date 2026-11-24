import Foundation
import OSLog

private let rewordLog = Logger(subsystem: "io.github.nicolasmahn.WhisperLocal", category: "reword")

struct RewordClient {
    var session: URLSession = .shared

    func models(serverURL: String, apiKey: String) async throws -> [String] {
        var request = URLRequest(url: try endpoint(serverURL, "models"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        let data = try await send(request, apiKey: apiKey)
        guard let list = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw RewordError.invalidJSON
        }
        return list.data.map(\.id)
    }

    func reword(
        _ text: String, model: String, serverURL: String, apiKey: String,
        vocabulary: Vocabulary = Vocabulary(), style: RewordStyle = .light, timeout: TimeInterval = 60,
        screenshot: Data? = nil
    ) async throws -> String {
        var request = URLRequest(url: try endpoint(serverURL, "chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.chatRequestBody(
            text: text, model: model, vocabulary: vocabulary, style: style, screenshot: screenshot
        )
        let data = try await send(request, apiKey: apiKey)
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let content = completion.choices.first?.message.content else { throw RewordError.invalidJSON }
        return content
    }

    static func chatRequestBody(
        text: String, model: String, vocabulary: Vocabulary = Vocabulary(), style: RewordStyle = .light,
        screenshot: Data? = nil
    ) -> Data {
        let system = Rewording.systemPrompt(vocabulary: vocabulary, style: style, withScreen: screenshot != nil)
        let user: Content = screenshot.map {
            .parts([
                Part(type: "image_url", imageURL: ImageURL(url: "data:image/png;base64," + $0.base64EncodedString())),
                Part(type: "text", text: "<dictation>" + text + "</dictation>"),
            ])
        } ?? .text(text)
        let request = ChatRequest(
            model: model,
            messages: [
                Message(role: "system", content: .text(system)),
                Message(role: "user", content: user),
            ],
            temperature: style == .light ? 0.2 : 0.3,
            chatTemplateKwargs: TemplateOptions(enableThinking: false)
        )
        return (try? JSONEncoder().encode(request)) ?? Data()
    }

    /// "" when the recording is silent.
    func transcribe(_ request: HeardRequest, serverURL: String, apiKey: String) async throws -> String {
        let seconds = WAV.duration(of: request.wav)
        var urlRequest = URLRequest(url: try endpoint(serverURL, "chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = HeardDictation.timeout
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Self.heardRequestBody(request)
        let data = try await send(urlRequest, apiKey: apiKey)
        guard let completion = try? JSONDecoder().decode(Completion.self, from: data),
              let content = completion.choices.first?.message.content else { throw RewordError.invalidJSON }
        let text = Rewording.clean(content)
        guard !HeardDictation.isRunaway(text, seconds: seconds) else { throw RewordError.runaway }
        // Empty stays a result: the caller lets Whisper decide whether the recording was silent.
        guard text.isEmpty || !HeardDictation.isTruncated(text, seconds: seconds) else {
            throw RewordError.truncated
        }
        return text
    }

    static func heardRequestBody(_ request: HeardRequest) -> Data {
        var parts: [Part] = request.screenshot.map {
            [Part(type: "image_url", imageURL: ImageURL(url: "data:image/png;base64," + $0.base64EncodedString()))]
        } ?? []
        parts.append(Part(type: "text", text: HeardDictation.instruction(language: request.language)))
        parts.append(Part(
            type: "input_audio",
            inputAudio: InputAudio(data: request.wav.base64EncodedString(), format: "wav")
        ))
        let body = ChatRequest(
            model: HeardDictation.model,
            messages: [
                Message(role: "system", content: .text(HeardDictation.systemPrompt(for: request))),
                Message(role: "user", content: .parts(parts)),
            ],
            temperature: 0.2,
            // Qwen3-Omni's template doesn't think, and with this flag it leaks "Assistant:" or goes blank.
            chatTemplateKwargs: nil
        )
        return (try? JSONEncoder().encode(body)) ?? Data()
    }

    private func send(_ request: URLRequest, apiKey: String) async throws -> Data {
        var request = request
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: SameOriginRedirectDelegate())
        } catch {
            throw RewordError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw RewordError.invalidJSON }
        guard (200..<300).contains(http.statusCode) else {
            // The body names the model and the reason (e.g. "not running"); the status code alone hides both.
            let path = request.url?.path ?? ""
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            rewordLog.error("HTTP \(http.statusCode) from \(path, privacy: .public): \(body, privacy: .public)")
            if http.statusCode == 401 || http.statusCode == 403 { throw RewordError.unauthorized }
            throw RewordError.response(http.statusCode)
        }
        return data
    }

    private func endpoint(_ serverURL: String, _ path: String) throws -> URL {
        guard let base = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil else { throw RewordError.invalidURL }
        return base.appending(path: path)
    }

    private struct ModelList: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    private struct Completion: Decodable {
        struct Choice: Decodable { let message: Message }
        struct Message: Decodable { let content: String? }
        let choices: [Choice]
    }

    private struct Message: Encodable {
        let role: String
        let content: Content
    }

    private enum Content: Encodable {
        case text(String)
        case parts([Part])

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .text(let text): try container.encode(text)
            case .parts(let parts): try container.encode(parts)
            }
        }
    }

    private struct Part: Encodable {
        let type: String
        var text: String?
        var imageURL: ImageURL?
        var inputAudio: InputAudio?

        enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
            case inputAudio = "input_audio"
        }
    }

    private struct ImageURL: Encodable { let url: String }

    private struct InputAudio: Encodable {
        let data: String
        let format: String
    }

    private struct TemplateOptions: Encodable {
        let enableThinking: Bool
        enum CodingKeys: String, CodingKey { case enableThinking = "enable_thinking" }
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [Message]
        let temperature: Double
        let chatTemplateKwargs: TemplateOptions?
        enum CodingKeys: String, CodingKey {
            case model, messages, temperature
            case chatTemplateKwargs = "chat_template_kwargs"
        }
    }
}

/// The model chosen per server and style, so the hot path skips GET /models.
final class RewordModelCache: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String: String] = [:]

    subscript(serverURL: String, style: RewordStyle) -> String? {
        get { lock.withLock { models[Self.key(serverURL, style)] } }
        set { lock.withLock { models[Self.key(serverURL, style)] = newValue } }
    }

    func removeAll() { lock.withLock { models.removeAll() } }

    private static func key(_ serverURL: String, _ style: RewordStyle) -> String { "\(style)|\(serverURL)" }
}
