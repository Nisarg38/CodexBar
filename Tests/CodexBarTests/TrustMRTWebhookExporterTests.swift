import CodexBarCore
import Foundation
import Testing

@Suite(.serialized)
struct TrustMRTWebhookExporterTests {
    @Test
    func postsDeltaAndPersistsBaseline() async throws {
        let suiteName = "TrustMRTWebhookExporterTests.postsDeltaAndPersistsBaseline.\(UUID())"
        let defaults = try Self.makeIsolatedDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = makeStubSession()
        TrustMRTWebhookExporterStubURLProtocol.reset()

        let exporter = TrustMRTWebhookExporter(
            session: session,
            userDefaults: defaults,
            stateKey: "state")
        let endpoint = try #require(URL(string: "https://example.test/api/plugin/import"))

        let first = try await exporter.exportUsage(
            endpoint: endpoint,
            pluginToken: "plg_test",
            appVersion: "1.0.0",
            currentTotals: ["codex": 100, "claude": 40])
        #expect(first == .posted(providerCount: 2))
        #expect(TrustMRTWebhookExporterStubURLProtocol.requestCount == 1)

        let second = try await exporter.exportUsage(
            endpoint: endpoint,
            pluginToken: "plg_test",
            appVersion: "1.0.0",
            currentTotals: ["codex": 150, "claude": 40])
        #expect(second == .posted(providerCount: 1))
        #expect(TrustMRTWebhookExporterStubURLProtocol.requestCount == 2)
    }

    @Test
    func negativeDeltaResetsWithoutPost() async throws {
        let suiteName = "TrustMRTWebhookExporterTests.negativeDeltaResetsWithoutPost.\(UUID())"
        let defaults = try Self.makeIsolatedDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = makeStubSession()
        TrustMRTWebhookExporterStubURLProtocol.reset()

        let exporter = TrustMRTWebhookExporter(
            session: session,
            userDefaults: defaults,
            stateKey: "state")
        let endpoint = try #require(URL(string: "https://example.test/api/plugin/import"))

        _ = try await exporter.exportUsage(
            endpoint: endpoint,
            pluginToken: "plg_test",
            appVersion: "1.0.0",
            currentTotals: ["codex": 200])
        #expect(TrustMRTWebhookExporterStubURLProtocol.requestCount == 1)

        let result = try await exporter.exportUsage(
            endpoint: endpoint,
            pluginToken: "plg_test",
            appVersion: "1.0.0",
            currentTotals: ["codex": 100])
        #expect(result == .skippedNoDelta)
        #expect(TrustMRTWebhookExporterStubURLProtocol.requestCount == 1)
    }

    @Test
    func missingConfigurationThrowsAndSkipsRequest() async throws {
        let suiteName = "TrustMRTWebhookExporterTests.missingConfigurationThrows.\(UUID())"
        let defaults = try Self.makeIsolatedDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = makeStubSession()
        TrustMRTWebhookExporterStubURLProtocol.reset()

        let exporter = TrustMRTWebhookExporter(
            session: session,
            userDefaults: defaults,
            stateKey: "state")

        do {
            _ = try await exporter.exportUsage(
                endpoint: nil,
                pluginToken: "plg_test",
                appVersion: "1.0.0",
                currentTotals: ["codex": 100])
            Issue.record("Expected missing configuration error")
        } catch let error as TrustMRTExportError {
            guard case .missingConfiguration = error else {
                Issue.record("Unexpected TrustMRT export error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(TrustMRTWebhookExporterStubURLProtocol.requestCount == 0)
    }

    @Test
    func serverErrorReturnsStatusAndBody() async throws {
        let suiteName = "TrustMRTWebhookExporterTests.serverErrorReturnsStatusAndBody.\(UUID())"
        let defaults = try Self.makeIsolatedDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = makeStubSession()
        TrustMRTWebhookExporterStubURLProtocol.reset()
        TrustMRTWebhookExporterStubURLProtocol.statusCode = 500
        TrustMRTWebhookExporterStubURLProtocol.responseBody = #"{"error":"boom"}"#

        let exporter = TrustMRTWebhookExporter(
            session: session,
            userDefaults: defaults,
            stateKey: "state")
        let endpoint = try #require(URL(string: "https://example.test/api/plugin/import"))

        do {
            _ = try await exporter.exportUsage(
                endpoint: endpoint,
                pluginToken: "plg_test",
                appVersion: "1.0.0",
                currentTotals: ["codex": 100])
            Issue.record("Expected server error")
        } catch let error as TrustMRTExportError {
            guard case let .serverError(status, body) = error else {
                Issue.record("Unexpected TrustMRT export error: \(error)")
                return
            }
            #expect(status == 500)
            #expect(body.contains("boom"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func clearBaselineForcesNextExportToPostCurrentTotal() async throws {
        let suiteName = "TrustMRTWebhookExporterTests.clearBaselineForcesPost.\(UUID())"
        let defaults = try Self.makeIsolatedDefaults(suiteName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = makeStubSession()
        TrustMRTWebhookExporterStubURLProtocol.reset()

        let exporter = TrustMRTWebhookExporter(
            session: session,
            userDefaults: defaults,
            stateKey: "state")
        let endpoint = try #require(URL(string: "https://example.test/api/plugin/import"))

        let first = try await exporter.exportUsage(
            endpoint: endpoint,
            pluginToken: "plg_test",
            appVersion: "1.0.0",
            currentTotals: ["codex": 100])
        #expect(first == .posted(providerCount: 1))

        let second = try await exporter.exportUsage(
            endpoint: endpoint,
            pluginToken: "plg_test",
            appVersion: "1.0.0",
            currentTotals: ["codex": 100])
        #expect(second == .skippedNoDelta)
        #expect(TrustMRTWebhookExporterStubURLProtocol.requestCount == 1)

        exporter.clearBaseline()

        let third = try await exporter.exportUsage(
            endpoint: endpoint,
            pluginToken: "plg_test",
            appVersion: "1.0.0",
            currentTotals: ["codex": 100])
        #expect(third == .posted(providerCount: 1))
        #expect(TrustMRTWebhookExporterStubURLProtocol.requestCount == 2)
    }

    private static func makeIsolatedDefaults(suiteName: String) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private func makeStubSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [TrustMRTWebhookExporterStubURLProtocol.self]
    return URLSession(configuration: config)
}

final class TrustMRTWebhookExporterStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount: Int = 0
    nonisolated(unsafe) static var statusCode: Int = 200
    nonisolated(unsafe) static var responseBody = #"{"success":true}"#

    static func reset() {
        self.requestCount = 0
        self.statusCode = 200
        self.responseBody = #"{"success":true}"#
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1

        guard let url = self.request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: Self.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])
        else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let body = Data(Self.responseBody.utf8)
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: body)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
