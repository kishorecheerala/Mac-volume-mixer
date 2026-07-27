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
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MacVolumeMixer", category: "ChromeTabAudioService")

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

        // Discover Chrome tabs via JXA
        let scriptTabs = await fetchAppleScriptTabs()
        updateTabsList(with: scriptTabs)
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

            if isMediaOrAudioTab(tab) {
                updated.append(tab)
            }
        }

        // Fallback: If no media tabs matched, include active tabs from open windows so the list is never empty
        if updated.isEmpty && !newTabs.isEmpty {
            var seenWindows = Set<Int>()
            for tab in newTabs {
                if !seenWindows.contains(tab.windowID) {
                    seenWindows.insert(tab.windowID)
                    updated.append(tab)
                }
            }
        }

        self.tabs = updated
    }

    private func isMediaOrAudioTab(_ tab: ChromeTabAudioItem) -> Bool {
        if volumeMap[tab.id] != nil || muteMap[tab.id] != nil {
            return true
        }
        if tab.isPlayingAudio {
            return true
        }
        let titleLower = tab.title.lowercased()
        let urlLower = (tab.url ?? "").lowercased()

        let mediaKeywords = [
            "netflix", "youtube", "hotstar", "primevideo", "spotify", "twitch",
            "hulu", "disney", "soundcloud", "vimeo", "moviebox", "shuttletv",
            "movierulz", "apple.com/music", "hbomax", "max.com", "peacock",
            "paramount", "bilibili", "plex", "crunchyroll", "jiocinema", "zee5",
            "sonyliv", "1flex", "thesvg", "watch", "stream", "play", "video",
            "listen", "live tv", "radio", "podcast", "player"
        ]

        return mediaKeywords.contains(where: { titleLower.contains($0) || urlLower.contains($0) })
    }

    // MARK: - JXA (JavaScript for Automation) Fallback Implementation
    // JXA is used instead of traditional AppleScript because when multiple Chrome
    // instances are running (e.g. user's Chrome + a headless Chrome), AppleScript's
    // `tell application "Google Chrome"` may target the wrong instance (the headless
    // one with 0 windows). JXA's `Application("Google Chrome")` correctly resolves
    // to the user's primary Chrome instance with actual windows and tabs.

    private func fetchAppleScriptTabs() async -> [ChromeTabAudioItem] {
        return await Task.detached {
            let jxaSource = """
            ObjC.import('stdlib');
            var chrome = Application('Google Chrome');
            var wins = chrome.windows();
            var result = [];
            for (var wi = 0; wi < wins.length; wi++) {
                var tabs = wins[wi].tabs();
                for (var ti = 0; ti < tabs.length; ti++) {
                    var t = tabs[ti];
                    try {
                        var isAudible = false;
                        try { isAudible = t.audible(); } catch(e) {}
                        result.push((wi+1) + '|||' + (ti+1) + '|||' + t.id() + '|||' + (isAudible ? '1' : '0') + '|||' + (t.title() || '') + '|||' + (t.url() || ''));
                    } catch(e) {}
                }
            }
            result.join('\\n');
            """

            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-l", "JavaScript", "-e", jxaSource]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = Pipe()

            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                self.logger.warning("JXA tab discovery process error: \(error)")
                return []
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
            return self.parseAppleScriptResponse(text)
        }.value
    }

    nonisolated func parseAppleScriptResponse(_ text: String) -> [ChromeTabAudioItem] {
        var items: [ChromeTabAudioItem] = []
        let lines = text.components(separatedBy: .newlines)

        for line in lines {
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 6 else { continue }

            let winIdxStr = parts[0].trimmingCharacters(in: .whitespaces)
            let tabIdxStr = parts[1].trimmingCharacters(in: .whitespaces)
            let tabID = parts[2].trimmingCharacters(in: .whitespaces)
            let audibleStr = parts[3].trimmingCharacters(in: .whitespaces)
            let title = parts[4].trimmingCharacters(in: .whitespaces)
            let url = parts[5].trimmingCharacters(in: .whitespaces)

            guard let winIdx = Int(winIdxStr) else { continue }

            let compositeID = "win_\(winIdx)_tab_\(tabID)"
            let displayTitle = title.isEmpty ? "Tab \(tabIdxStr)" : title
            let isAudible = (audibleStr == "1")

            let item = ChromeTabAudioItem(
                id: compositeID,
                tabID: tabID,
                windowID: winIdx,
                title: displayTitle,
                url: url.isEmpty ? nil : url,
                isPlayingAudio: isAudible,
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

        // JXA script to set volume/mute on a specific tab by its ID
        let jxaSource = """
        var chrome = Application('Google Chrome');
        var wins = chrome.windows();
        for (var wi = 0; wi < wins.length; wi++) {
            var tabs = wins[wi].tabs();
            for (var ti = 0; ti < tabs.length; ti++) {
                var t = tabs[ti];
                try {
                    if (String(t.id()) === '\(tab.tabID)') {
                        t.execute({javascript: "(function(){ var els = Array.from(document.querySelectorAll('video, audio')); els.forEach(function(m){ m.volume = \(volumeVal); m.muted = \(isMutedVal); }); })()"});
                    }
                } catch(e) {}
            }
        }
        """

        Task.detached {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-l", "JavaScript", "-e", jxaSource]
            task.standardOutput = Pipe()
            task.standardError = Pipe()

            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                self.logger.warning("Error applying tab volume via JXA: \(error)")
            }
        }
    }
}
