import AppKit
import SwiftUI

/// Small floating panel shown while ElevenLabs is generating or playing speech
/// — gives long clips a visible progress bar (and a stop button), since Fn+V
/// has no popup of its own. Non-activating, top-center, mirrors the Fn HUD's
/// panel config. Driven by `ElevenLabsTTS.shared` (an ObservableObject).
@MainActor
final class SpeechHUDController {
    static let shared = SpeechHUDController()
    private var panel: NSPanel?
    private var dismissWork: DispatchWorkItem?
    private var hovering = false
    /// True once playback ended — the HUD may fade (unless hovered).
    private var canDismiss = false

    /// Gap from the bottom edge of the active screen's visible area.
    private static let bottomMargin: CGFloat = 72

    /// The screen the user is working on — the one under the mouse, then the
    /// key window's screen, then the main display. Keeps the HUD on the screen
    /// you're actually using on a multi-monitor setup, not always the primary.
    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return s
        }
        return NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first!
    }

    func show() {
        canDismiss = false
        dismissWork?.cancel(); dismissWork = nil
        let panel = ensurePanel()
        panel.alphaValue = 1
        let host = panel.contentView!
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        let screen = Self.activeScreen().visibleFrame
        panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2,
                                     y: screen.minY + Self.bottomMargin))
        panel.orderFrontRegardless()
    }

    /// Immediate hide (the stop button / a failed request).
    func hide() {
        dismissWork?.cancel(); dismissWork = nil
        panel?.orderOut(nil)
        panel?.alphaValue = 1
    }

    /// Playback ended — keep the HUD up for a beat, then fade. Held open while
    /// the user hovers it (fades once the mouse leaves).
    func scheduleFadeOut() {
        canDismiss = true
        if !hovering { startFadeTimer() }
    }

    /// Driven by the HUD's `.onHover`.
    func setHovering(_ h: Bool) {
        hovering = h
        if h {
            dismissWork?.cancel(); dismissWork = nil
        } else if canDismiss {
            startFadeTimer()
        }
    }

    private func startFadeTimer() {
        dismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeAndHide() }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func fadeAndHide() {
        guard let panel, canDismiss else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.canDismiss else { return }
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
            }
        })
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 64),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: SpeechHUDView())
        panel = p
        return p
    }
}

private struct SpeechHUDView: View {
    @ObservedObject private var tts = ElevenLabsTTS.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Group {
                if tts.phase == .generating {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Generating\u{2026}").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Waveform(progress: tts.progress) { ElevenLabsTTS.shared.seek(to: $0) }
                }
            }
            .frame(width: 150)
            Button { ElevenLabsTTS.shared.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Stop")
        }
        .frame(width: 232, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .shadow(radius: 12, y: 4)
        .onHover { SpeechHUDController.shared.setHovering($0) }
        .padding(14)
    }
}

/// Sound-wave progress indicator: fixed-height bars (a stable pseudo-waveform)
/// that fill with the accent color up to `progress` and stay dim beyond it, so
/// playback reads as a wave sweeping left to right.
private struct Waveform: View {
    let progress: Double
    /// Called with the new 0…1 position while the user drags to scrub.
    var onSeek: (Double) -> Void = { _ in }
    private static let heights: [CGFloat] = (0..<30).map { i in
        let w = (sin(Double(i) * 0.55) + sin(Double(i) * 0.27 + 1.2)) * 0.5
        return CGFloat(6 + (w * 0.5 + 0.5) * 16)
    }
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(Self.heights.enumerated()), id: \.offset) { idx, h in
                    Capsule()
                        .fill(Double(idx) / Double(Self.heights.count) <= progress
                              ? Color.accentColor
                              : Color.secondary.opacity(0.3))
                        .frame(height: h)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    onSeek(min(1, max(0, v.location.x / max(1, geo.size.width))))
                }
            )
        }
        .frame(width: 150, height: 24)
        .animation(.linear(duration: 0.08), value: progress)
    }
}
