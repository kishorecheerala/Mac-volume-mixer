// FineTune/Audio/ChromeTabAudioService.swift
import Foundation
import AppKit
import os

/// Service responsible for discovering and controlling individual Google Chrome tabs and windows.
@MainActor
@Observable
final class ChromeTabAudioService {
    private(set) var tabs: [ChromeTabAudioItem] = []
    private(set) var isChromeRunning: Bool = false
    private(set) var isCDPAvailable: Bool = false

    private var volumeMap: [String: Float] = [:]   // tabId -> volume (0.0 ... 1.0)
    private var muteMap: [String: Bool] = [:]      // tabId -> isMuted

    private nonisolated(unsafe) var pollTask: Task<Void, Never>?
    private let cdpPort: Int
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "ChromeTabAudioService")

    init(cdpPort: Int = 9222) {
        self.cdpPort = cdpPort
    }

    deinit {
        // MainActor isolated cleanup in deinit via task cancellation
        pollTask?.cancel()
    }

    // MARK: - Lifecycle & Control

    func startPolling() {
        guard pollTask == nil else { return }
        logger.info("Starting Chrome tab discovery polling")
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshTabs()
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2 seconds
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        tabs = []
        isChromeRunning = false
        isCDPAvailable = false
        logger.info("Stopped Chrome tab discovery polling")
    }

    // MARK: - Tab Operations

    func setVolume(for tabID: String, volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        volumeMap[tabID] = clamped

        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[index].volume = clamped
            applyTabState(tabs[index])
        }
    }

    func setMuted(for tabID: String, isMuted: Bool) {
        muteMap[tabID] = isMuted

        if let index = tabs.firstIndex(where: { $0.id == tabID }) {
            tabs[index].isMuted = isMuted
            applyTabState(tabs[index])
        }
    }

    func toggleMute(for tabID: String) {
        if let tab = tabs.first(where: { $0.id == tabID }) {
            setMuted(for: tabID, isMuted: !tab.isMuted)
        }
    }

    // MARK: - Tab Discovery

    func refreshTabs() async {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome")
            + NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome.canary")
            + NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome.beta")
            + NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome.dev")
            + NSRunningApplication.runningApplications(withBundleIdentifier: "org.chromium.Chromium")
            + NSRunningApplication.runningApplications(withBundleIdentifier: "com.brave.Browser")

        let anyChrome = !runningApps.isEmpty || NSWorkspace.shared.runningApplications.contains(where: {
            ($0.bundleIdentifier?.localizedCaseInsensitiveContains("Chrome") == true) ||
            ($0.localizedName?.localizedCaseInsensitiveContains("Chrome") == true)
        })

        guard anyChrome else {
            if isChromeRunning {
                isChromeRunning = false
                isCDPAvailable = false
                tabs = []
            }
            return
        }

        isChromeRunning = true

        // Try CDP first
        if let cdpTabs = await fetchCDPTabs() {
            isCDPAvailable = true
            updateTabsList(with: cdpTabs)
        } else {
            isCDPAvailable = false
            // Fallback to AppleScript
            let scriptTabs = await fetchAppleScriptTabs()
            updateTabsList(with: scriptTabs)
        }
    }

    private func updateTabsList(with newTabs: [ChromeTabAudioItem]) {
        var updated: [ChromeTabAudioItem] = []
        for var tab in newTabs {
            if let savedVol = volumeMap[tab.id] {
                tab.volume = savedVol
            }
            if let savedMute = muteMap[tab.id] {
                tab.isMuted = savedMute
            }
            updated.append(tab)
        }
        self.tabs = updated
    }

    // MARK: - CDP (Chrome DevTools Protocol) Implementation

    private func fetchCDPTabs() async -> [ChromeTabAudioItem]? {
        guard let url = URL(string: "http://localhost:\(cdpPort)/json/list") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8 // Fast timeout for responsiveness

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            return parseCDPResponse(data)
        } catch {
            return nil
        }
    }

    nonisolated func parseCDPResponse(_ data: Data) -> [ChromeTabAudioItem] {
        struct CDPTarget: Decodable {
            let id: String
            let title: String?
            let type: String?
            let url: String?
            let faviconUrl: String?
        }

        guard let targets = try? JSONDecoder().decode([CDPTarget].self, from: data) else {
            return []
        }

        var result: [ChromeTabAudioItem] = []
        for (index, target) in targets.enumerated() {
            guard target.type == "page" || target.type == nil else { continue }
            let title = (target.title?.isEmpty == false) ? target.title! : "Chrome Tab \(index + 1)"
            let favicon: URL? = target.faviconUrl.flatMap { URL(string: $0) }

            let item = ChromeTabAudioItem(
                id: target.id,
                tabID: target.id,
                windowID: 1,
                title: title,
                url: target.url,
                faviconURL: favicon,
                discoverySource: .cdp
            )
            result.append(item)
        }
        return result
    }

    // MARK: - AppleScript Fallback Implementation

    private func fetchAppleScriptTabs() async -> [ChromeTabAudioItem] {
        return await Task.detached {
            let scriptSource = """
            tell application "Google Chrome"
                if not running then return ""
                set resultList to ""
                set winIdx to 1
                repeat with w in windows
                    set tabIdx to 1
                    repeat with t in tabs of w
                        try
                            set tabTitle to title of t
                            set tabURL to URL of t
                            set tabID to id of t
                            set resultList to resultList & (winIdx as text) & "|||" & (tabIdx as text) & "|||" & (tabID as text) & "|||" & tabTitle & "|||" & tabURL & "\n"
                        end try
                        set tabIdx to tabIdx + 1
                    end repeat
                    set winIdx to winIdx + 1
                end repeat
                return resultList
            end tell
            """

            guard let script = NSAppleScript(source: scriptSource) else { return [] }
            var errorInfo: NSDictionary?
            let output = script.executeAndReturnError(&errorInfo)

            if let errorInfo {
                self.logger.warning("AppleScript tab execution info: \(errorInfo)")
            }

            guard let text = output.stringValue else { return [] }
            return self.parseAppleScriptResponse(text)
        }.value
    }

    nonisolated func parseAppleScriptResponse(_ text: String) -> [ChromeTabAudioItem] {
        var items: [ChromeTabAudioItem] = []
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 5 else { continue }

            let winIdxStr = parts[0].trimmingCharacters(in: .whitespaces)
            let tabIdxStr = parts[1].trimmingCharacters(in: .whitespaces)
            let tabID = parts[2].trimmingCharacters(in: .whitespaces)
            let title = parts[3].trimmingCharacters(in: .whitespaces)
            let url = parts[4].trimmingCharacters(in: .whitespaces)

            guard let winIdx = Int(winIdxStr) else { continue }

            let compositeID = "win_\(winIdx)_tab_\(tabID)"
            let displayTitle = title.isEmpty ? "Tab \(tabIdxStr)" : title

            let item = ChromeTabAudioItem(
                id: compositeID,
                tabID: tabID,
                windowID: winIdx,
                title: displayTitle,
                url: url.isEmpty ? nil : url,
                discoverySource: .appleScript
            )
            items.append(item)
        }
        return items
    }

    // MARK: - Script Application

    private func applyTabState(_ tab: ChromeTabAudioItem) {
        let volumeVal = tab.isMuted ? 0.0 : tab.volume
        let isMutedVal = tab.isMuted ? "true" : "false"

        let jsString = "Array.from(document.querySelectorAll('video, audio')).forEach(function(m){ m.volume = \(volumeVal); m.muted = \(isMutedVal); });"

        if tab.discoverySource == .appleScript {
            let scriptText = """
            tell application "Google Chrome"
                try
                    execute tab id \(tab.tabID) of window \(tab.windowID) javascript "\(jsString)"
                end try
            end tell
            """
            Task.detached {
                if let script = NSAppleScript(source: scriptText) {
                    var err: NSDictionary?
                    script.executeAndReturnError(&err)
                }
            }
        } else if tab.discoverySource == .cdp {
            // For CDP target, send HTTP POST or JS execution fallback
            let scriptText = """
            tell application "Google Chrome"
                try
                    execute tab id "\(tab.tabID)" javascript "\(jsString)"
                end try
            end tell
            """
            Task.detached {
                if let script = NSAppleScript(source: scriptText) {
                    var err: NSDictionary?
                    script.executeAndReturnError(&err)
                }
            }
        }
    }
}
