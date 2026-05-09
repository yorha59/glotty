import SwiftUI
import Translation
import NaturalLanguage
import AVFoundation
import CoreServices

struct PopupView: View {
    let sourceText: String
    let onClose: () -> Void

    @State private var translated: String = ""
    @State private var configuration: TranslationSession.Configuration?
    @State private var status: Status = .working
    @State private var detectedSource: NLLanguage?
    @State private var targetLang: String = "en"
    @State private var availableLanguages: [Locale.Language] = []
    @State private var elapsedMs: Int = 0
    private let startedAt = CFAbsoluteTimeGetCurrent()

    enum Status {
        case working
        case ready
        case failed(String)
    }

    private var isSingleWord: Bool {
        LanguagePolicy.isSingleWord(sourceText)
    }

    private var sourcePronunciation: [PhoneticEntry] {
        isSingleWord ? Pronunciation.pronounce(sourceText, language: detectedSource) : []
    }

    private var translatedPronunciation: [PhoneticEntry] {
        guard isSingleWord, !translated.isEmpty else { return [] }
        let lang = NLLanguage(rawValue: targetLang)
        return Pronunciation.pronounce(translated, language: lang)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceBlock

            Divider()

            translationBlock

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text(detectedSource?.rawValue ?? "auto")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("→")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Menu {
                    ForEach(availableLanguages, id: \.minimalIdentifier) { lang in
                        let id = lang.minimalIdentifier
                        Button {
                            changeTarget(to: id)
                        } label: {
                            if id == targetLang {
                                Label(localizedName(for: id), systemImage: "checkmark")
                            } else {
                                Text(localizedName(for: id))
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(localizedName(for: targetLang))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.caption2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                Text("\(elapsedMs)ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Esc")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 380, height: 200)
        .background(.regularMaterial)
        .onAppear { setupConfiguration() }
        .task { await loadAvailableLanguages() }
        .translationTask(configuration) { session in
            await translate(using: session)
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var sourceBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sourceText)
                    .font(.system(.body))
                    .textSelection(.enabled)
                    .lineLimit(3)
                phoneticView(text: sourceText,
                             fallbackLanguage: detectedSource?.rawValue,
                             entries: sourcePronunciation)
            }
            Spacer(minLength: 0)
            // Top-level speak only when no per-row buttons exist (e.g. sentence input).
            if sourcePronunciation.isEmpty {
                speakButton(text: sourceText, language: detectedSource?.rawValue)
            }
            closeButton
        }
    }

    private var translationBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                switch status {
                case .working:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Translating…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                case .ready:
                    Text(translated)
                        .font(.system(.title3, design: .rounded))
                        .textSelection(.enabled)
                    phoneticView(text: translated,
                                 fallbackLanguage: targetLang,
                                 entries: translatedPronunciation)
                case .failed(let message):
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
            // Top-level speak only when no per-row buttons (sentences, etc.).
            if case .ready = status, translatedPronunciation.isEmpty {
                speakButton(text: translated, language: targetLang)
            }
        }
    }

    @ViewBuilder
    private func phoneticView(text: String,
                              fallbackLanguage: String?,
                              entries: [PhoneticEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries, id: \.self) { entry in
                    HStack(spacing: 6) {
                        if let label = entry.label {
                            Text(label)
                                .font(.system(.caption2, design: .rounded).weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 26, alignment: .leading)
                        }
                        Text(entry.value)
                            .font(.system(.callout, design: .serif))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Button {
                            Speaker.shared.speak(text,
                                                 language: entry.voiceLocale ?? fallbackLanguage)
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help(entry.voiceLocale.map { "Pronounce (\($0))" } ?? "Pronounce")
                    }
                }
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Close (Esc)")
    }

    private func speakButton(text: String, language: String?) -> some View {
        Button {
            Speaker.shared.speak(text, language: language)
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Pronounce")
    }

    private func setupConfiguration() {
        let savedSource = UserDefaults.standard.string(forKey: "glotty.sourceLang")
        let detected: NLLanguage?
        if let savedSource, !savedSource.isEmpty {
            detected = NLLanguage(rawValue: savedSource)
        } else {
            detected = LanguagePolicy.detectSourceLanguage(sourceText)
        }
        detectedSource = detected

        let savedTarget = UserDefaults.standard.string(forKey: "glotty.targetLang")
        let target = (savedTarget?.isEmpty == false
                      ? savedTarget!
                      : LanguagePolicy.preferredTarget(for: detected))
        targetLang = target
        rebuildConfiguration()
    }

    private func changeTarget(to newLang: String) {
        guard newLang != targetLang else { return }
        targetLang = newLang
        // Per-translation override only — Settings panel owns the persistent default.
        rebuildConfiguration()
    }

    private func rebuildConfiguration() {
        translated = ""
        status = .working
        configuration = TranslationSession.Configuration(
            source: detectedSource.map { Locale.Language(identifier: $0.rawValue) },
            target: Locale.Language(identifier: targetLang)
        )
    }

    private func loadAvailableLanguages() async {
        let supported = await LanguageAvailability().supportedLanguages
        var seen = Set<String>()
        let unique = supported.filter { seen.insert($0.minimalIdentifier).inserted }
        availableLanguages = unique.sorted {
            localizedName(for: $0.minimalIdentifier)
                .localizedCaseInsensitiveCompare(localizedName(for: $1.minimalIdentifier))
                == .orderedAscending
        }
    }

    private func localizedName(for identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private func translate(using session: TranslationSession) async {
        do {
            let response = try await session.translate(sourceText)
            translated = response.targetText
            status = .ready
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}

struct PhoneticEntry: Hashable {
    let label: String?       // "BrE", "AmE", or nil for single-variant / transliteration
    let value: String        // e.g. "/ˈʃɛdjuːl/" or "fān yì"
    let voiceLocale: String? // "en-GB", "en-US", etc. — drives the speak button voice
}

/// Best-effort pronunciation:
/// - CJK: transliterate via CFStringTransform (pinyin / romaji / hangul-latin).
/// - Latin scripts: parse IPA from the macOS Dictionary entry (DCSCopyTextDefinition).
enum Pronunciation {
    static func pronounce(_ text: String, language: NLLanguage?) -> [PhoneticEntry] {
        if let translit = transliterate(text, from: language) {
            return [PhoneticEntry(label: nil, value: translit, voiceLocale: language?.rawValue)]
        }
        return ipa(for: text)
    }

    static func transliterate(_ text: String, from lang: NLLanguage?) -> String? {
        guard let lang else { return nil }
        let transform: CFString?
        switch lang {
        case .simplifiedChinese, .traditionalChinese:
            transform = kCFStringTransformMandarinLatin
        case .japanese, .korean:
            transform = kCFStringTransformToLatin
        default:
            transform = nil
        }
        guard let transform else { return nil }

        let mut = NSMutableString(string: text)
        guard CFStringTransform(mut, nil, transform, false) else { return nil }
        let result = mut as String
        return result == text ? nil : result
    }

    /// Look up the macOS Dictionary entry for `text` and parse out its IPA block.
    /// The actual parsing is in `parseDictionaryDefinition` so it can be unit-tested
    /// without hitting `DCSCopyTextDefinition` (which depends on the user's enabled
    /// dictionaries and is awkward to mock).
    static func ipa(for text: String) -> [PhoneticEntry] {
        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        guard let unmanaged = DCSCopyTextDefinition(nil, cfText, range) else { return [] }
        let definition = unmanaged.takeRetainedValue() as String
        return parseDictionaryDefinition(definition)
    }

    /// Parse the first `|…|` block out of a dictionary definition string.
    /// Comma-separated variants are deduped (Unicode-normalized, whitespace-stripped)
    /// and capped at two — Oxford convention is BrE first, AmE second.
    static func parseDictionaryDefinition(_ definition: String) -> [PhoneticEntry] {
        guard let first = definition.firstIndex(of: "|") else { return [] }
        let afterFirst = definition.index(after: first)
        guard let second = definition[afterFirst...].firstIndex(of: "|") else { return [] }

        let block = definition[afterFirst..<second]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = block
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        let unique = raw.filter { variant in
            let key = variant
                .components(separatedBy: .whitespacesAndNewlines).joined()
                .precomposedStringWithCanonicalMapping
            return seen.insert(key).inserted
        }

        let capped = Array(unique.prefix(2))

        switch capped.count {
        case 0: return []
        case 1:
            return [PhoneticEntry(label: nil, value: "/\(capped[0])/", voiceLocale: nil)]
        default:
            return [
                PhoneticEntry(label: "BrE", value: "/\(capped[0])/", voiceLocale: "en-GB"),
                PhoneticEntry(label: "AmE", value: "/\(capped[1])/", voiceLocale: "en-US"),
            ]
        }
    }
}

@MainActor
final class Speaker {
    static let shared = Speaker()
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ text: String, language: String?) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utt = AVSpeechUtterance(string: text)
        if let language, let voice = AVSpeechSynthesisVoice(language: language) {
            utt.voice = voice
        }
        synthesizer.speak(utt)
    }
}
