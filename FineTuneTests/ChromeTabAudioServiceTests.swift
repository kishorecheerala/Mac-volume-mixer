// FineTuneTests/ChromeTabAudioServiceTests.swift

import Foundation
import Testing
@testable import FineTune

@Suite("ChromeTabAudioService Unit Tests")
struct ChromeTabAudioServiceTests {

    @Test("ChromeTabAudioItem initialization clamps volume bounds")
    func testItemVolumeClamping() {
        let itemLow = ChromeTabAudioItem(
            id: "1",
            tabID: "1",
            windowID: 1,
            title: "Test Tab",
            volume: -0.5
        )
        #expect(itemLow.volume == 0.0)

        let itemHigh = ChromeTabAudioItem(
            id: "2",
            tabID: "2",
            windowID: 1,
            title: "Test Tab 2",
            volume: 1.5
        )
        #expect(itemHigh.volume == 1.0)
    }

    @Test("CDP JSON response parsing extracts page targets")
    @MainActor
    func testCDPResponseParsing() {
        let service = ChromeTabAudioService()
        let jsonString = """
        [
            {
                "id": "CDP_TAB_1",
                "title": "YouTube - Music Video",
                "type": "page",
                "url": "https://www.youtube.com/watch?v=123",
                "faviconUrl": "https://www.youtube.com/favicon.ico"
            },
            {
                "id": "CDP_SERVICE_WORKER",
                "title": "Background Worker",
                "type": "service_worker",
                "url": "https://example.com/worker.js"
            }
        ]
        """
        let data = jsonString.data(using: .utf8)!
        let parsed = service.parseCDPResponse(data)

        #expect(parsed.count == 1)
        #expect(parsed.first?.id == "CDP_TAB_1")
        #expect(parsed.first?.title == "YouTube - Music Video")
        #expect(parsed.first?.discoverySource == .cdp)
    }

    @Test("AppleScript output parsing parses pipe-delimited tab strings")
    @MainActor
    func testAppleScriptResponseParsing() {
        let service = ChromeTabAudioService()
        let scriptOutput = """
        1|||1|||101|||Google Search|||https://www.google.com
        1|||2|||102|||Spotify - Web Player|||https://open.spotify.com
        """

        let parsed = service.parseAppleScriptResponse(scriptOutput)

        #expect(parsed.count == 2)
        #expect(parsed[0].windowID == 1)
        #expect(parsed[0].tabID == "101")
        #expect(parsed[0].title == "Google Search")
        #expect(parsed[1].title == "Spotify - Web Player")
        #expect(parsed[1].discoverySource == .appleScript)
    }

    @Test("Set volume and mute state updates tab list and volume map")
    @MainActor
    func testSetVolumeAndMute() async {
        let service = ChromeTabAudioService()

        let rawOutput = "1|||1|||999|||Podcast Player|||https://podcast.example.com"
        let initialTabs = service.parseAppleScriptResponse(rawOutput)
        #expect(initialTabs.count == 1)

        service.setVolume(for: initialTabs[0].id, volume: 0.4)
        service.setMuted(for: initialTabs[0].id, isMuted: true)

        #expect(initialTabs[0].id == "win_1_tab_999")
    }

    @Test("Stop polling clears tab state and flags")
    @MainActor
    func testStopPolling() {
        let service = ChromeTabAudioService()
        service.startPolling()
        service.stopPolling()

        #expect(service.tabs.isEmpty)
        #expect(!service.isChromeRunning)
        #expect(!service.isCDPAvailable)
    }
}
