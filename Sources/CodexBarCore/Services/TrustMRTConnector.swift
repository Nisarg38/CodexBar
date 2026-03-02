import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif

public struct TrustMRTConnectedUser: Sendable {
    public let username: String
    public let avatarURL: URL?

    public init(username: String, avatarURL: URL?) {
        self.username = username
        self.avatarURL = avatarURL
    }
}

public struct TrustMRTConnectionResult: Sendable {
    public let pluginToken: String
    public let user: TrustMRTConnectedUser

    public init(pluginToken: String, user: TrustMRTConnectedUser) {
        self.pluginToken = pluginToken
        self.user = user
    }
}

public enum TrustMRTConnectorError: LocalizedError {
    case unsupportedPlatform
    case invalidURL
    case invalidState
    case startFailed(String)
    case callbackTimeout
    case callbackMissingCode
    case callbackStateMismatch
    case exchangeFailed(status: Int, body: String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "TrustMRT connect is only available on macOS."
        case .invalidURL:
            "TrustMRT connect URL is invalid."
        case .invalidState:
            "TrustMRT returned an invalid state."
        case let .startFailed(message):
            "Unable to start TrustMRT connect flow: \(message)"
        case .callbackTimeout:
            "Timed out waiting for browser callback."
        case .callbackMissingCode:
            "Browser callback did not include a connect code."
        case .callbackStateMismatch:
            "Browser callback state did not match."
        case let .exchangeFailed(status, body):
            "TrustMRT exchange failed (\(status)): \(body)"
        case .malformedResponse:
            "TrustMRT response was malformed."
        }
    }
}

public final class TrustMRTConnector: @unchecked Sendable {
    private struct StartResponse: Decodable {
        let success: Bool
        let connectUrl: String
    }

    private struct ExchangeResponse: Decodable {
        struct ExchangeUser: Decodable {
            let username: String
            let avatarUrl: String?
        }

        let success: Bool
        let pluginToken: String
        let user: ExchangeUser
    }

    private let apiBaseURL: URL
    private let webBaseURL: URL?
    private let session: URLSession
    private let openURL: @Sendable (URL) -> Void
    private let callbackTimeout: TimeInterval
    private static let stateAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)

    public init(
        apiBaseURL: URL,
        webBaseURL: URL?,
        session: URLSession = .shared,
        callbackTimeout: TimeInterval = 180,
        openURL: @escaping @Sendable (URL) -> Void)
    {
        self.apiBaseURL = apiBaseURL
        self.webBaseURL = webBaseURL
        self.session = session
        self.callbackTimeout = callbackTimeout
        self.openURL = openURL
    }

    public func connect() async throws -> TrustMRTConnectionResult {
        #if canImport(Network)
        let expectedState = Self.makeRandomState()
        let callbackServer = CallbackLoopbackServer(webRedirectURL: self.webBaseURL)
        let callbackURL = try await callbackServer.start()
        defer { callbackServer.stop() }

        let startURL = try self.makeStartURL(callbackURL: callbackURL, state: expectedState)
        let (startData, startResponse) = try await self.session.data(from: startURL)
        guard let startHTTP = startResponse as? HTTPURLResponse else {
            throw TrustMRTConnectorError.malformedResponse
        }
        guard startHTTP.statusCode == 200 else {
            let body = String(data: startData, encoding: .utf8) ?? "unknown"
            throw TrustMRTConnectorError.startFailed(body)
        }

        let start = try JSONDecoder().decode(StartResponse.self, from: startData)
        guard start.success, let browserURL = URL(string: start.connectUrl) else {
            throw TrustMRTConnectorError.malformedResponse
        }

        self.openURL(browserURL)

        let callback = try await callbackServer.waitForCallback(timeout: self.callbackTimeout)
        guard let code = callback.code, !code.isEmpty else {
            throw TrustMRTConnectorError.callbackMissingCode
        }
        guard callback.state == expectedState else {
            throw TrustMRTConnectorError.callbackStateMismatch
        }

        var exchangeRequest = URLRequest(
            url: self.apiBaseURL.appending(path: "api/plugin/trustmrt/connect/exchange"))
        exchangeRequest.httpMethod = "POST"
        exchangeRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        exchangeRequest.httpBody = try JSONEncoder().encode([
            "code": code,
            "state": callback.state,
        ])

        let (exchangeData, exchangeResponse) = try await self.session.data(for: exchangeRequest)
        guard let exchangeHTTP = exchangeResponse as? HTTPURLResponse else {
            throw TrustMRTConnectorError.malformedResponse
        }
        guard exchangeHTTP.statusCode == 200 else {
            let body = String(data: exchangeData, encoding: .utf8) ?? "unknown"
            throw TrustMRTConnectorError.exchangeFailed(status: exchangeHTTP.statusCode, body: body)
        }

        let exchange = try JSONDecoder().decode(ExchangeResponse.self, from: exchangeData)
        guard exchange.success else {
            throw TrustMRTConnectorError.malformedResponse
        }
        let avatarURL = exchange.user.avatarUrl.flatMap(URL.init(string:))
        return TrustMRTConnectionResult(
            pluginToken: exchange.pluginToken,
            user: TrustMRTConnectedUser(username: exchange.user.username, avatarURL: avatarURL))
        #else
        throw TrustMRTConnectorError.unsupportedPlatform
        #endif
    }

    private func makeStartURL(callbackURL: URL, state: String) throws -> URL {
        var components = URLComponents(
            url: self.apiBaseURL.appending(path: "api/plugin/trustmrt/connect/start"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "callbackUrl", value: callbackURL.absoluteString),
            URLQueryItem(name: "state", value: state),
        ]
        if let webBaseURL {
            components?.queryItems?.append(
                URLQueryItem(name: "webBaseUrl", value: webBaseURL.absoluteString))
        }
        guard let url = components?.url else {
            throw TrustMRTConnectorError.invalidURL
        }
        return url
    }

    private static func makeRandomState(length: Int = 48) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        #if canImport(Security)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            for index in bytes.indices {
                bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
            }
        }
        #else
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        #endif

        let mapped = bytes.map { Self.stateAlphabet[Int($0) % Self.stateAlphabet.count] }
        return String(bytes: mapped, encoding: .utf8) ?? ""
    }
}

#if canImport(Network)
private struct CallbackPayload: Sendable {
    let code: String?
    let state: String
}

private final class CallbackLoopbackServer: @unchecked Sendable {
    private enum CallbackError: Error {
        case listenerFailed
    }

    private let webRedirectURL: URL?
    private let queue = DispatchQueue(label: "trustmrt.loopback.server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var callbackContinuation: CheckedContinuation<CallbackPayload, Error>?
    private var callbackResolved = false
    private var pendingCallbackResult: Result<CallbackPayload, Error>?
    private var didResumeStart = false

    init(webRedirectURL: URL? = nil) {
        self.webRedirectURL = webRedirectURL
    }

    func start() async throws -> URL {
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        self.lock.withLock {
            self.didResumeStart = false
            self.callbackResolved = false
            self.pendingCallbackResult = nil
            self.callbackContinuation = nil
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receiveRequest(on: connection, buffer: Data())
        }

        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.lock.lock()
                    if self.didResumeStart {
                        self.lock.unlock()
                        return
                    }
                    self.didResumeStart = true
                    self.lock.unlock()
                    if let raw = listener.port?.rawValue {
                        continuation.resume(returning: raw)
                    } else {
                        continuation.resume(throwing: CallbackError.listenerFailed)
                    }
                case let .failed(error):
                    self.lock.lock()
                    if self.didResumeStart {
                        self.lock.unlock()
                        return
                    }
                    self.didResumeStart = true
                    self.lock.unlock()
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }

        guard let url = URL(string: "http://127.0.0.1:\(port)/callback") else {
            throw TrustMRTConnectorError.invalidURL
        }
        return url
    }

    func waitForCallback(timeout: TimeInterval) async throws -> CallbackPayload {
        try await withThrowingTaskGroup(of: CallbackPayload.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw TrustMRTConnectorError.callbackTimeout }
                return try await withCheckedThrowingContinuation { continuation in
                    self.registerCallbackContinuation(continuation)
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw TrustMRTConnectorError.callbackTimeout
            }
            defer {
                group.cancelAll()
                self.lock.withLock {
                    self.callbackContinuation = nil
                }
            }
            guard let result = try await group.next() else {
                throw TrustMRTConnectorError.callbackTimeout
            }
            return result
        }
    }

    func stop() {
        self.listener?.cancel()
        self.listener = nil
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.complete(with: .failure(error))
                connection.cancel()
                return
            }

            var merged = buffer
            if let data {
                merged.append(data)
            }

            let headerTerminator = Data("\r\n\r\n".utf8)
            if merged.range(of: headerTerminator) == nil, !isComplete {
                self.receiveRequest(on: connection, buffer: merged)
                return
            }

            let payload = self.parseCallbackPayload(from: merged)
            if let payload {
                self.sendSuccessResponse(on: connection)
                self.complete(with: .success(payload))
                return
            }

            self.sendNonCallbackResponse(on: connection)
        }
    }

    private func parseCallbackPayload(from data: Data) -> CallbackPayload? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let firstLine = text.components(separatedBy: "\r\n").first else { return nil }
        let segments = firstLine.split(separator: " ")
        guard segments.count >= 2 else { return nil }
        let path = String(segments[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(path)") else { return nil }
        guard components.path == "/callback" else { return nil }
        let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        let state = components.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
        return CallbackPayload(code: code, state: state)
    }

    private func sendSuccessResponse(on connection: NWConnection) {
        let redirectTarget = self.webRedirectURL?.absoluteString ?? ""
        let metaRedirect = redirectTarget.isEmpty
            ? ""
            : "<meta http-equiv=\"refresh\" content=\"1;url=\(redirectTarget)/profile\" />"
        let statusText = redirectTarget.isEmpty
            ? "You can close this tab now."
            : "Redirecting to your profile…"
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\" />
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
          <title>TrustMRT Connected</title>
          \(metaRedirect)
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              background: #0a0a0f;
              color: #f4f4f5;
              font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif;
            }
            .card {
              max-width: 560px;
              padding: 24px;
              border: 1px solid #27272a;
              border-radius: 12px;
              background: #111118;
              text-align: center;
            }
            h3 { margin: 0 0 10px; }
            p { margin: 0; color: #d4d4d8; }
          </style>
        </head>
        <body>
          <div class=\"card\">
            <h3>TrustMRT Connected!</h3>
            <p>\(statusText)</p>
          </div>
        </body>
        </html>
        """
        let body = Data(html.utf8)
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendNonCallbackResponse(on connection: NWConnection) {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset=\"utf-8\" />
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
          <title>TrustMRT Connect</title>
          <style>
            body {
              margin: 0;
              min-height: 100vh;
              display: grid;
              place-items: center;
              background: #0a0a0f;
              color: #f4f4f5;
              font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif;
            }
          </style>
        </head>
        <body>
          <p>Waiting for TrustMRT callback…</p>
        </body>
        </html>
        """
        let body = Data(html.utf8)
        let headers = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r
        """
        var response = Data(headers.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func registerCallbackContinuation(_ continuation: CheckedContinuation<CallbackPayload, Error>) {
        var pending: Result<CallbackPayload, Error>?
        self.lock.lock()
        if let pendingCallbackResult = self.pendingCallbackResult {
            pending = pendingCallbackResult
            self.pendingCallbackResult = nil
        } else {
            self.callbackContinuation = continuation
        }
        self.lock.unlock()

        if let pending {
            continuation.resume(with: pending)
        }
    }

    private func complete(with result: Result<CallbackPayload, Error>) {
        let continuation: CheckedContinuation<CallbackPayload, Error>?
        self.lock.lock()
        guard !self.callbackResolved else {
            self.lock.unlock()
            return
        }
        self.callbackResolved = true
        continuation = self.callbackContinuation
        if continuation != nil {
            self.callbackContinuation = nil
        } else {
            self.pendingCallbackResult = result
        }
        self.lock.unlock()

        if let continuation {
            continuation.resume(with: result)
        }
        self.stop()
    }
}
#endif
