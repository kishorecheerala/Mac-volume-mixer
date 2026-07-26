// FineTune/Views/Rows/ChromeTabRow.swift
import SwiftUI

/// A row representing an individual open Google Chrome tab or window inside the mixer view.
struct ChromeTabRow: View {
    let tab: ChromeTabAudioItem
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let isFocused: Bool

    @State private var isHovered = false

    init(
        tab: ChromeTabAudioItem,
        onVolumeChange: @escaping (Float) -> Void,
        onMuteToggle: @escaping () -> Void,
        isFocused: Bool = false
    ) {
        self.tab = tab
        self.onVolumeChange = onVolumeChange
        self.onMuteToggle = onMuteToggle
        self.isFocused = isFocused
    }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Tab icon (globe or favicon placeholder)
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DesignTokens.Colors.textSecondary)
                .frame(width: 16, height: 16)

            // Tab title + window indicator
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DesignTokens.Colors.textPrimary)
                    .lineLimit(1)

                Text("Window \(tab.windowID) • \(tab.discoverySource.rawValue.uppercased())")
                    .font(.system(size: 9))
                    .foregroundColor(DesignTokens.Colors.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Mute Button
            Button(action: onMuteToggle) {
                Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundColor(tab.isMuted ? DesignTokens.Colors.mutedIndicator : DesignTokens.Colors.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.isMuted ? "Unmute \(tab.title)" : "Mute \(tab.title)")

            // Volume Slider (0 - 100%)
            Slider(
                value: Binding(
                    get: { tab.isMuted ? 0.0 : tab.volume },
                    set: { newVol in onVolumeChange(newVol) }
                ),
                in: 0...1
            )
            .frame(width: 100)
            .tint(DesignTokens.Colors.accentPrimary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isFocused ? DesignTokens.Colors.accentPrimary.opacity(0.15) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isFocused ? DesignTokens.Colors.accentPrimary : Color.clear, lineWidth: 1)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}
