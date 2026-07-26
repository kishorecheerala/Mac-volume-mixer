// FineTune/Models/ChromeTabAudioItem.swift
import Foundation

/// Represents a discovery source for Chrome tabs.
enum ChromeTabDiscoverySource: String, Codable, Equatable, Sendable {
    case cdp
    case appleScript
}

/// Represents an individual Google Chrome tab or window with audio metadata and controls.
struct ChromeTabAudioItem: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let tabID: String
    let windowID: Int
    let title: String
    let url: String?
    let faviconURL: URL?
    var volume: Float  // 0.0 ... 1.0
    var isMuted: Bool
    var isPlayingAudio: Bool
    let discoverySource: ChromeTabDiscoverySource

    init(
        id: String,
        tabID: String,
        windowID: Int,
        title: String,
        url: String? = nil,
        faviconURL: URL? = nil,
        volume: Float = 1.0,
        isMuted: Bool = false,
        isPlayingAudio: Bool = false,
        discoverySource: ChromeTabDiscoverySource = .appleScript
    ) {
        self.id = id
        self.tabID = tabID
        self.windowID = windowID
        self.title = title
        self.url = url
        self.faviconURL = faviconURL
        self.volume = max(0.0, min(1.0, volume))
        self.isMuted = isMuted
        self.isPlayingAudio = isPlayingAudio
        self.discoverySource = discoverySource
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: ChromeTabAudioItem, rhs: ChromeTabAudioItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.volume == rhs.volume &&
        lhs.isMuted == rhs.isMuted &&
        lhs.isPlayingAudio == rhs.isPlayingAudio &&
        lhs.title == rhs.title
    }
}
