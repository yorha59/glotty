import SwiftUI
import AVFoundation

/// Self-contained player for a cached voice clip, shown as a sheet from
/// Settings → Voice → Cached clips. Unlike the floating `SpeechHUD` (driven by
/// the shared `ElevenLabsTTS`), this owns its own `AVAudioPlayer` so the popup
/// is fully independent: the full sentence is visible and sweeps with the accent
/// color as it plays (a karaoke-style highlight tied to playback position).
@MainActor
final class ClipPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var progress: Double = 0   // 0…1
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Load + autoplay (the user tapped the clip to hear it).
    func start(_ data: Data) {
        stop()
        guard let p = try? AVAudioPlayer(data: data) else { return }
        p.delegate = self
        player = p
        duration = p.duration
        play()
    }

    func play() {
        guard let player else { return }
        // Replay from the top once it has finished.
        if progress >= 1 { player.currentTime = 0; progress = 0 }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate(); timer = nil
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(to fraction: Double) {
        guard let player, player.duration > 0 else { return }
        let f = min(1, max(0, fraction))
        player.currentTime = f * player.duration
        progress = f
    }

    func stop() {
        player?.stop(); player = nil
        timer?.invalidate(); timer = nil
        isPlaying = false
        progress = 0
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = min(1, p.currentTime / p.duration)
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.progress = 1   // leave the whole sentence highlighted
            self?.timer?.invalidate(); self?.timer = nil
        }
    }
}

struct ClipPlaybackView: View {
    let entry: VoiceCache.Entry
    @StateObject private var player = ClipPlayer()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Text("Cached clip")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }

            ScrollView {
                highlighted
                    .font(.system(size: 19))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .animation(.linear(duration: 0.05), value: player.progress)
            }
            .frame(maxHeight: 240)

            HStack(spacing: 14) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)

                ClipScrubber(progress: player.progress) { player.seek(to: $0) }

                Text(timeLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 84, alignment: .trailing)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let data = VoiceCache.data(for: entry) { player.start(data) }
        }
        .onDisappear { player.stop() }
    }

    /// The sentence with the spoken-so-far portion in the accent color and the
    /// rest dimmed — the cut point tracks playback position.
    private var highlighted: Text {
        let text = entry.text
        let count = text.count
        let cut = max(0, min(count, Int((Double(count) * player.progress).rounded())))
        let idx = text.index(text.startIndex, offsetBy: cut)
        return Text(String(text[..<idx])).foregroundColor(.accentColor)
             + Text(String(text[idx...])).foregroundColor(.primary.opacity(0.5))
    }

    private var timeLabel: String {
        "\(Self.mmss(player.progress * player.duration)) / \(Self.mmss(player.duration))"
    }

    private static func mmss(_ t: Double) -> String {
        let s = Int(t.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Slim draggable progress bar for the clip player.
private struct ClipScrubber: View {
    let progress: Double
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                    .frame(height: 5)
                Capsule().fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * progress), height: 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    onSeek(min(1, max(0, v.location.x / max(1, geo.size.width))))
                }
            )
        }
        .frame(height: 22)
    }
}
