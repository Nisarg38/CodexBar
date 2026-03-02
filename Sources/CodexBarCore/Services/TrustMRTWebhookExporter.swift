import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Snapshot of a provider's current totals, used to compute deltas for export.
///
/// Conforms to `Codable` for baseline persistence in UserDefaults.
/// The `daily` field is transient (not encoded/decoded) — it carries raw
/// per-day entries only for the current export cycle.
public struct TrustMRTProviderSnapshot: Sendable, Equatable {
    public let tokens: Int
    public let costUSD: Double?
    public let inputTokens: Int?
    public let outputTokens: Int?
    /// Per-day breakdown entries from the provider's usage data.
    /// Transient — not persisted in the baseline.
    public let daily: [CostUsageDailyReport.Entry]

    public init(tokens: Int, costUSD: Double? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, daily: [CostUsageDailyReport.Entry] = []) {
        self.tokens = tokens
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.daily = daily
    }

    private enum CodingKeys: String, CodingKey {
        case tokens, costUSD, inputTokens, outputTokens
    }
}

extension TrustMRTProviderSnapshot: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tokens = try container.decode(Int.self, forKey: .tokens)
        self.costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        self.daily = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tokens, forKey: .tokens)
        try container.encodeIfPresent(costUSD, forKey: .costUSD)
        try container.encodeIfPresent(inputTokens, forKey: .inputTokens)
        try container.encodeIfPresent(outputTokens, forKey: .outputTokens)
    }
}

public struct TrustMRTProviderDelta: Sendable, Encodable {
    public let provider: String
    public let totalTokens: Int
    /// USD cost for these tokens. Encoded as "cost" to match the TrustMRT HTTP API.
    public let costUSD: Double?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let dailyBreakdown: [DailyEntry]?

    public struct DailyEntry: Sendable, Encodable {
        public let date: String           // "YYYY-MM-DD"
        public let totalTokens: Int
        public let cost: Double?
        public let inputTokens: Int?
        public let outputTokens: Int?
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case totalTokens
        case costUSD = "cost"
        case inputTokens
        case outputTokens
        case dailyBreakdown
    }

    public init(provider: String, totalTokens: Int, costUSD: Double? = nil, inputTokens: Int? = nil, outputTokens: Int? = nil, dailyBreakdown: [DailyEntry]? = nil) {
        self.provider = provider
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.dailyBreakdown = dailyBreakdown
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

public struct TrustMRTSyncStatus: Sendable, Decodable {
    public let syncNeeded: Bool
    public let requestedAt: Double?
}

public enum TrustMRTExportResult: Sendable, Equatable {
    case posted(providerCount: Int)
    case skippedNoDelta
}

public final class TrustMRTWebhookExporter: @unchecked Sendable {
    private let session: URLSession
    private let userDefaults: UserDefaults

    private static let baselineKey = "trustmrt.exportBaseline"

    public init(
        session: URLSession = .shared,
        userDefaults: UserDefaults = .standard)
    {
        self.session = session
        self.userDefaults = userDefaults
    }

    /// Export that sends cost and token breakdown alongside token deltas.
    public func exportUsage(
        endpoint: URL?,
        pluginToken: String?,
        appVersion: String,
        source: String = "trustmrt",
        currentSnapshots: [String: TrustMRTProviderSnapshot]) async throws -> TrustMRTExportResult
    {
        let (endpoint, pluginToken) = try Self.validated(endpoint: endpoint, pluginToken: pluginToken)

        let previous = self.loadBaseline()

        var nextBaseline = previous
        var deltas: [TrustMRTProviderDelta] = []
        var sawNegativeDelta = false

        for (provider, current) in currentSnapshots {
            let prev = previous[provider]
            let tokenDelta = current.tokens - (prev?.tokens ?? 0)
            nextBaseline[provider] = current

            if tokenDelta > 0 {
                let costDelta = Self.positiveDelta(current.costUSD, prev?.costUSD)
                let inputDelta = Self.positiveDelta(current.inputTokens, prev?.inputTokens)
                let outputDelta = Self.positiveDelta(current.outputTokens, prev?.outputTokens)

                // Map per-day breakdown entries from the snapshot
                let dailyEntries: [TrustMRTProviderDelta.DailyEntry]? = {
                    let entries = current.daily.compactMap { entry -> TrustMRTProviderDelta.DailyEntry? in
                        guard let tokens = entry.totalTokens, tokens > 0 else { return nil }
                        return TrustMRTProviderDelta.DailyEntry(
                            date: entry.date,
                            totalTokens: tokens,
                            cost: entry.costUSD,
                            inputTokens: entry.inputTokens,
                            outputTokens: entry.outputTokens)
                    }
                    return entries.isEmpty ? nil : entries
                }()

                deltas.append(TrustMRTProviderDelta(
                    provider: provider,
                    totalTokens: tokenDelta,
                    costUSD: costDelta,
                    inputTokens: inputDelta,
                    outputTokens: outputDelta,
                    dailyBreakdown: dailyEntries))
            } else if tokenDelta < 0 {
                sawNegativeDelta = true
            }
        }

        if deltas.isEmpty {
            if sawNegativeDelta {
                self.saveBaseline(nextBaseline)
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

        self.saveBaseline(nextBaseline)
        return .posted(providerCount: deltas.count)
    }

    /// Check whether the server has requested a fresh sync.
    public func checkSyncStatus(
        endpoint: URL?,
        pluginToken: String?
    ) async throws -> TrustMRTSyncStatus {
        let (endpoint, pluginToken) = try Self.validated(endpoint: endpoint, pluginToken: pluginToken)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(pluginToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TrustMRTExportError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw TrustMRTExportError.serverError(status: http.statusCode, body: body)
        }

        return try JSONDecoder().decode(TrustMRTSyncStatus.self, from: data)
    }

    // MARK: - Helpers

    private static func validated(endpoint: URL?, pluginToken: String?) throws -> (URL, String) {
        guard let endpoint, let pluginToken, !pluginToken.isEmpty else {
            throw TrustMRTExportError.missingConfiguration
        }
        return (endpoint, pluginToken)
    }

    private static func positiveDelta<T: Numeric & Comparable>(_ current: T?, _ previous: T?) -> T? {
        guard let current else { return nil }
        let prev = previous ?? .zero
        let delta = current - prev
        return delta > .zero ? delta : nil
    }

    // MARK: - Baseline persistence

    private func loadBaseline() -> [String: TrustMRTProviderSnapshot] {
        guard let data = self.userDefaults.data(forKey: Self.baselineKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: TrustMRTProviderSnapshot].self, from: data)) ?? [:]
    }

    private func saveBaseline(_ baseline: [String: TrustMRTProviderSnapshot]) {
        guard let data = try? JSONEncoder().encode(baseline) else { return }
        self.userDefaults.set(data, forKey: Self.baselineKey)
    }

    public func clearBaseline() {
        self.userDefaults.removeObject(forKey: Self.baselineKey)
    }
}
