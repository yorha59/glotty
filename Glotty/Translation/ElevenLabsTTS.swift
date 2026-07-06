import Foundation
import AVFoundation

/// Opt-in cloud TTS backend (ElevenLabs). Used only when enabled + a key is
/// stored (Settings → Voice); otherwise the app falls back to the on-device
/// system voice (see `Speaker`). Observable so the floating `SpeechHUD` can
/// show generation/playback progress. Synthesized audio is cached on disk
/// (`VoiceCache`) so repeats are instant + don't re-bill the user's quota.
@MainActor
final class ElevenLabsTTS: NSObject, ObservableObject {
    static let shared = ElevenLabsTTS()

    enum Phase: Equatable { case idle, generating, playing }
    @Published private(set) var phase: Phase = .idle
    /// Playback position 0…1 (only meaningful while `.playing`).
    @Published private(set) var progress: Double = 0

    nonisolated static let keychainAccount    = "elevenlabs"
    nonisolated static let enabledDefaultsKey = "glotty.tts.elevenlabs.enabled"
    nonisolated static let voiceDefaultsKey   = "glotty.tts.elevenlabs.voice"
    nonisolated static let modelDefaultsKey   = "glotty.tts.elevenlabs.model"

    nonisolated static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"
    nonisolated static let defaultModel   = "eleven_multilingual_v2"

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var progressTimer: Timer?

    /// Enabled AND a key stored. Read per call so toggling takes effect at once.
    nonisolated static var isConfigured: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
            && (Keychain.read(account: keychainAccount).map { !$0.isEmpty } ?? false)
    }

    /// Synthesize + play `text` (cache first, then network). Drives the HUD via
    /// `phase`. On any failure calls `onFailure` so the caller falls back to the
    /// system voice — speech never goes silent.
    func speak(_ text: String, onFailure: @escaping () -> Void) {
        guard let key = Keychain.read(account: Self.keychainAccount), !key.isEmpty else {
            onFailure(); return
        }
        let voice = UserDefaults.standard.string(forKey: Self.voiceDefaultsKey) ?? Self.defaultVoiceID
        let model = UserDefaults.standard.string(forKey: Self.modelDefaultsKey) ?? Self.defaultModel
        cancel()

        if let cached = VoiceCache.load(text: text, voice: voice, model: model) {
            play(cached)
            return
        }

        phase = .generating
        SpeechHUDController.shared.show()
        task = Task { [weak self] in
            do {
                let data = try await Self.fetch(text: text, voiceID: voice, model: model, apiKey: key)
                if Task.isCancelled { return }
                VoiceCache.store(data, text: text, voice: voice, model: model)
                self?.play(data)
            } catch {
                Log.debug(.app, "ElevenLabs TTS failed (\(error.localizedDescription)) — falling back to the system voice")
                self?.phase = .idle
                SpeechHUDController.shared.hide()
                // Don't fail silently: the user turned on the cloud voice and
                // hears the system one instead. Surface why, then fall back.
                // The common case is HTTP 402 — the default voice is a Voice-
                // Library voice free plans can't call; give an actionable hint
                // instead of ElevenLabs's misleading "upgrade your subscription".
                // NB: keep each String(localized:) as a standalone binding —
                // extract-strings.sh doesn't catch it when nested in a "\(…)".
                let ns = error as NSError
                let isPlanBlock = ns.code == 402
                    || ns.localizedDescription.contains("payment_required")
                    || ns.localizedDescription.contains("library voices")
                let toastMsg: String
                if isPlanBlock {
                    toastMsg = String(localized: "That ElevenLabs voice needs a paid plan. Open Settings → Voice and pick one of your own voices (Glotty will do this for you), or clear the key to use the free system voice.")
                } else {
                    let head = String(localized: "ElevenLabs voice failed — using the system voice.")
                    toastMsg = "\(head) \(ns.localizedDescription.prefix(160))"
                }
                HUDController.shared.toast(
                    toastMsg,
                    systemImage: "exclamationmark.triangle", duration: 5)
                onFailure()
            }
        }
    }

    private func play(_ data: Data) {
        do {
            let p = try AVAudioPlayer(data: data)
            p.delegate = self
            player = p
            p.play()
            progress = 0
            phase = .playing
            startProgressTimer()
            SpeechHUDController.shared.show()
        } catch {
            Log.debug(.app, "ElevenLabs audio decode/play failed: \(error.localizedDescription)")
            phase = .idle
            SpeechHUDController.shared.hide()
        }
    }

    /// Stop generation + playback (the HUD's stop button).
    func stop() {
        cancel()
        progress = 0
        phase = .idle
        SpeechHUDController.shared.hide()
    }

    /// Play already-synthesized audio (a cache entry tapped in Settings).
    func playCached(_ data: Data) {
        cancel()
        play(data)
    }

    /// Seek playback to `fraction` (0…1) — the draggable wave scrubber.
    func seek(to fraction: Double) {
        guard let p = player, p.duration > 0 else { return }
        let f = min(1, max(0, fraction))
        p.currentTime = f * p.duration
        progress = f
    }

    private func cancel() {
        task?.cancel(); task = nil
        player?.stop(); player = nil
        progressTimer?.invalidate(); progressTimer = nil
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = min(1, p.currentTime / p.duration)
            }
        }
    }

    /// One TTS round-trip. Returns the MP3 bytes; throws on non-2xx (the body
    /// usually carries the ElevenLabs error JSON, surfaced in the message).
    nonisolated static func fetch(text: String, voiceID: String, model: String, apiKey: String) async throws -> Data {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "model_id": model])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "ElevenLabs", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(body.prefix(200))"])
        }
        return data
    }

    /// A selectable ElevenLabs voice (for the Settings picker).
    struct Voice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    /// List the account's available voices (premade + the user's own).
    nonisolated static func listVoices(apiKey: String) async throws -> [Voice] {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices") else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "ElevenLabs", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"])
        }
        struct Payload: Decodable {
            let voices: [Item]
            struct Item: Decodable { let voice_id: String; let name: String }
        }
        return try JSONDecoder().decode(Payload.self, from: data)
            .voices.map { Voice(id: $0.voice_id, name: $0.name) }
    }
}

extension ElevenLabsTTS: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.progressTimer?.invalidate()
            self?.progressTimer = nil
            self?.progress = 1   // leave the wave full while the HUD lingers
            self?.phase = .idle
            SpeechHUDController.shared.scheduleFadeOut()
        }
    }
}
