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
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
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

        // Check if the server has requested a fresh sync (e.g. new profile created).
        // If so, clear the baseline so the next export sends complete data.
        do {
            let syncEndpoint = self.settings.trustMRTAPIBaseURL.appending(path: "api/plugin/sync-status")
            let syncStatus = try await self.trustMRTExporter.checkSyncStatus(
                endpoint: syncEndpoint,
                pluginToken: token)
            if syncStatus.syncNeeded {
                self.trustMRTExporter.clearBaseline()
                self.trustMRTExportLogger.info("Sync requested by server — cleared baseline for full re-export")
            }
        } catch {
            // Don't block normal exports if the sync check fails
            self.trustMRTExportLogger.debug("Sync status check failed (non-fatal): \(error.localizedDescription)")
        }

        guard !Task.isCancelled else { return }

        let snapshots = self.currentTrustMRTProviderSnapshots()
        if snapshots.isEmpty {
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
                currentSnapshots: snapshots)
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

    private func currentTrustMRTProviderSnapshots() -> [String: TrustMRTProviderSnapshot] {
        var summary: [String: TrustMRTProviderSnapshot] = [:]
        for provider in UsageProvider.allCases {
            guard let snapshot = self.tokenSnapshots[provider] else { continue }
            guard let tokens = snapshot.last30DaysTokens, tokens >= 0 else { continue }

            // Aggregate input/output tokens from daily entries
            var totalInput = 0
            var totalOutput = 0
            for entry in snapshot.daily {
                totalInput += entry.inputTokens ?? 0
                totalOutput += entry.outputTokens ?? 0
            }
            let hasBreakdown = totalInput > 0 || totalOutput > 0

            summary[provider.rawValue] = TrustMRTProviderSnapshot(
                tokens: tokens,
                costUSD: snapshot.last30DaysCostUSD,
                inputTokens: hasBreakdown ? totalInput : nil,
                outputTokens: hasBreakdown ? totalOutput : nil,
                daily: snapshot.daily)
        }
        return summary
    }
}
