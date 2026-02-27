import AppKit
import CodexBarCore
import Foundation

extension UsageStore {
    var trustMRTConnectedUsername: String? {
        self.settings.trustMRTConnectedUsername
    }

    var trustMRTConnectedAvatarURL: URL? {
        self.settings.trustMRTConnectedAvatarURL.flatMap(URL.init(string:))
    }

    var trustMRTIsConnected: Bool {
        self.settings.trustMRTConnectedUsername != nil
    }

    func connectTrustMRT() async {
        guard !self.trustMRTConnecting else { return }
        self.trustMRTConnecting = true
        self.trustMRTLastError = nil

        defer { self.trustMRTConnecting = false }

        let connector = TrustMRTConnector(
            apiBaseURL: self.settings.trustMRTAPIBaseURL,
            webBaseURL: self.settings.trustMRTWebBaseURL,
            openURL: { url in
                DispatchQueue.main.async {
                    _ = NSWorkspace.shared.open(url)
                }
            })

        do {
            let result = try await connector.connect()
            try self.trustMRTTokenStore.storeToken(result.pluginToken)
            self.settings.trustMRTEnabled = true
            self.settings.trustMRTConnectedUsername = result.user.username
            self.settings.trustMRTConnectedAvatarURL = result.user.avatarURL?.absoluteString
            self.trustMRTLastExportStatus = "Connected to @\(result.user.username)"
            self.trustMRTLastError = nil
            self.scheduleTrustMRTExport(reason: "connected")
            self.trustMRTConnectLogger.info(
                "TrustMRT connected",
                metadata: ["username": result.user.username])
        } catch {
            let message = error.localizedDescription
            self.trustMRTLastError = message
            self.trustMRTConnectLogger.error("TrustMRT connect failed: \(message)")
        }
    }

    func disconnectTrustMRT() {
        self.trustMRTExportTask?.cancel()
        self.trustMRTExportTask = nil

        do {
            try self.trustMRTTokenStore.storeToken(nil)
        } catch {
            self.trustMRTLastError = error.localizedDescription
        }
        self.trustMRTExporter.clearBaseline()
        self.settings.trustMRTEnabled = false
        self.settings.trustMRTConnectedUsername = nil
        self.settings.trustMRTConnectedAvatarURL = nil
        self.trustMRTLastExportStatus = "Disconnected"
        self.trustMRTLastExportAt = nil
    }

    func scheduleTrustMRTExport(reason: String) {
        guard self.settings.trustMRTEnabled else { return }
        guard self.settings.trustMRTConnectedUsername != nil else { return }

        self.trustMRTExportTask?.cancel()
        self.trustMRTExportTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTrustMRTExport(reason: reason)
        }
    }

    private func performTrustMRTExport(reason: String) async {
        guard !Task.isCancelled else { return }

        let token: String?
        do {
            token = try self.trustMRTTokenStore.loadToken()
        } catch is CancellationError {
            self.trustMRTExportLogger.debug("TrustMRT export cancelled during token load")
            return
        } catch {
            self.trustMRTLastError = error.localizedDescription
            self.trustMRTExportLogger.error("TrustMRT token load failed: \(error.localizedDescription)")
            return
        }

        guard !Task.isCancelled else { return }

        let totals = self.currentTrustMRTProviderTotals()
        if totals.isEmpty {
            self.trustMRTLastExportStatus = "Waiting for Codex/Claude usage totals"
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let endpoint = self.settings.trustMRTAPIBaseURL.appending(path: "api/plugin/import")

        do {
            let result = try await self.trustMRTExporter.exportUsage(
                endpoint: endpoint,
                pluginToken: token,
                appVersion: version,
                source: "trustmrt",
                currentTotals: totals)
            guard !Task.isCancelled else { return }

            switch result {
            case let .posted(providerCount):
                self.trustMRTLastExportAt = Date()
                self.trustMRTLastExportStatus = "Exported \(providerCount) provider updates"
                self.trustMRTLastError = nil
                self.trustMRTExportLogger.info(
                    "TrustMRT export posted",
                    metadata: ["reason": reason, "providers": "\(providerCount)"])
            case .skippedNoDelta:
                self.trustMRTLastExportStatus = "No new tokens"
                self.trustMRTLastError = nil
            }
        } catch is CancellationError {
            self.trustMRTExportLogger.debug(
                "TrustMRT export cancelled",
                metadata: ["reason": reason])
        } catch {
            self.trustMRTLastError = error.localizedDescription
            self.trustMRTExportLogger.error(
                "TrustMRT export failed: \(error.localizedDescription)",
                metadata: ["reason": reason])
        }
    }

    private func currentTrustMRTProviderTotals() -> [String: Int] {
        var summary: [String: Int] = [:]
        for provider in [UsageProvider.codex, .claude] {
            guard let snapshot = self.tokenSnapshots[provider] else { continue }
            guard let tokens = snapshot.last30DaysTokens, tokens >= 0 else { continue }
            summary[provider.rawValue] = tokens
        }
        return summary
    }
}
