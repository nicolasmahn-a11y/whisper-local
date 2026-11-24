import Foundation

enum ModelStartError: LocalizedError, Equatable {
    case invalidURL
    case needsHTTPS
    case unreachable
    case unauthorized
    case busy
    case response(Int)
    case wouldStop([String])

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid model server URL"
        case .needsHTTPS: "Starting models needs an https:// model server"
        case .unreachable: "Model server unreachable"
        case .unauthorized: "Admin key rejected"
        case .busy: "Model is already starting"
        case .response(let code): "Model server returned HTTP \(code)"
        case .wouldStop(let models): "Starting it would stop \(models.joined(separator: ", "))"
        }
    }
}

/// Starts a model on the gateway through its admin API, so dictation can use it again.
struct ModelControl {
    var session: URLSession = .shared

    /// Never asks the gateway to stop other models: that is not this app's call.
    func start(_ model: String, serverURL: String, adminKey: String) async throws {
        var request = URLRequest(url: try Self.startURL(model, serverURL: serverURL))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: SameOriginRedirectDelegate())
        } catch {
            throw ModelStartError.unreachable
        }
        guard let http = response as? HTTPURLResponse else { throw ModelStartError.response(0) }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw ModelStartError.unauthorized
        case 409:
            let stopping = (try? JSONDecoder().decode(Conflict.self, from: data))?.error.wouldStop ?? []
            throw stopping.isEmpty ? ModelStartError.busy : ModelStartError.wouldStop(stopping)
        default: throw ModelStartError.response(http.statusCode)
        }
    }

    /// The gateway accepts the admin key only over HTTPS or from the server itself; plain http to
    /// another host would also send the key across the network in clear.
    /// Foundation versions differ on whether an IPv6 host keeps its brackets, so both forms count.
    static func startURL(_ model: String, serverURL: String) throws -> URL {
        guard let base = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = base.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = base.host?.lowercased(), !host.isEmpty,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw ModelStartError.invalidURL }
        guard scheme == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else {
            throw ModelStartError.needsHTTPS
        }
        var path = components.path.split(separator: "/").map(String.init)
        if path.last == "v1" { path.removeLast() }
        components.path = "/" + (path + ["admin", "models", model, "start"]).joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw ModelStartError.invalidURL }
        return url
    }

    private struct Conflict: Decodable {
        struct Detail: Decodable {
            let wouldStop: [String]?
            enum CodingKeys: String, CodingKey { case wouldStop = "would_stop" }
        }
        let error: Detail
    }
}
