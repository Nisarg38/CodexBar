import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TrustMRTProviderDelta: Sendable, Encodable {
    public let provider: String
    public let totalTokens: Int

    public init(provider: String, totalTokens: Int) {
        self.provider = provider
        self.totalTokens = totalTokens
    }
}

public struct TrustMRTExportPayload: Sendable, Encodable {
    public let source: String
    public let version: String
    public let providers: [TrustMRTProviderDelta]

    public init(source: String, version: String, providers: [TrustMRTProviderDelta]) {
        self.source = source
        self.version = version
        self.providers = providers
    }
}

public enum TrustMRTExportError: LocalizedError {
    case missingConfiguration
    case invalidResponse
    case serverError(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            "TrustMRT export is not configured."
        case .invalidResponse:
            "TrustMRT export returned an invalid response."
        case let .serverError(status, body):
            "TrustMRT export failed (\(status)): \(body)"
        }
    }
}

public enum TrustMRTExportResult: Sendable, Equatable {
    case posted(providerCount: Int)
    case skippedNoDelta
}

public final class TrustMRTWebhookExporter: @unchecked Sendable {
    private let session: URLSession
    private let userDefaults: UserDefaults
    private let stateKey: String

    public init(
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard,
        stateKey: String = "trustmrt.lastExportedTotals")
    {
        self.session = session
        self.userDefaults = userDefaults
        self.stateKey = stateKey
    }

    public func exportUsage(
        endpoint: URL?,
        pluginToken: String?,
        appVersion: String,
        source: String = "trustmrt",
        currentTotals: [String: Int]) async throws -> TrustMRTExportResult
    {
        guard let endpoint, let pluginToken, !pluginToken.isEmpty else {
            throw TrustMRTExportError.missingConfiguration
        }

        let previous = self.userDefaults.dictionary(forKey: self.stateKey) as? [String: Int] ?? [:]

        var nextTotals = previous
        var deltas: [TrustMRTProviderDelta] = []
        var sawNegativeDelta = false

        for (provider, currentValue) in currentTotals {
            let previousValue = previous[provider] ?? 0
            let delta = currentValue - previousValue
            nextTotals[provider] = currentValue

            if delta > 0 {
                deltas.append(TrustMRTProviderDelta(provider: provider, totalTokens: delta))
            } else if delta < 0 {
                sawNegativeDelta = true
            }
        }

        if deltas.isEmpty {
            if sawNegativeDelta {
                self.userDefaults.set(nextTotals, forKey: self.stateKey)
            }
            return .skippedNoDelta
        }

        let payload = TrustMRTExportPayload(
            source: source,
            version: appVersion,
            providers: deltas.sorted { $0.provider < $1.provider })
        let encoded = try JSONEncoder().encode(payload)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(pluginToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = encoded

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrustMRTExportError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw TrustMRTExportError.serverError(status: http.statusCode, body: body)
        }

        self.userDefaults.set(nextTotals, forKey: self.stateKey)
        return .posted(providerCount: deltas.count)
    }

    public func clearBaseline() {
        self.userDefaults.removeObject(forKey: self.stateKey)
    }
}
