import SwiftUI
import AppKit
import Translation
import NaturalLanguage
import AVFoundation
import CoreServices

/// Which Fn-leader command produced this popup. The view branches on this:
/// `.translate` runs the standard Apple-Translation pipeline; `.polish` skips
/// translation entirely and calls the selected LLM provider.
enum PopupMode: Equatable {
    case translate
    case polish
}

struct PopupView: View {
    let sourceText: String
    let mode: PopupMode
    let onClose: () -> Void

    @State private var translated: String = ""
    @State private var configuration: TranslationSession.Configuration?
    @State private var status: Status = .working
    @State private var backTranslated: String = ""
    @State private var backConfiguration: TranslationSession.Configuration?
    @State private var polishStatus: Status = .working
    @State private var polishResult: PolishResult = .empty
    @State private var polishProviderName: String = ""
    @State private var copiedVariantIndex: Int? = nil
    @State private var detectedSource: NLLanguage?
    @State private var targetLang: String = "en"
    @State private var availableLanguages: [Locale.Language] = []
    /// All dict entries that returned content, in the user's configured priority
    /// order (Settings → Dictionaries). Each rendered as its own region so the
    /// priority list is visible end-to-end, not just the first source + first target.
    @State private var dictResults: [DictionaryLookup.SourcedEntry] = []
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

    /// First monolingual (source-language) dict in priority order that returned
    /// content. Classification uses `DictionarySelection.dictionaryKind` (name-based)
    /// not the script-content heuristic — that was misclassifying monolingual English
    /// dicts whose entries happened to contain IPA or typographic glyphs outside the
    /// Latin Unicode ranges.
    private var monolingualDictResult: DictionaryLookup.SourcedEntry? {
        dictResults.first {
            $0.entry.hasContent
                && DictionarySelection.dictionaryKind(for: $0.dictionary) == .monolingual
        }
    }

    private var bilingualDictResult: DictionaryLookup.SourcedEntry? {
        dictResults.first {
            $0.entry.hasContent
                && DictionarySelection.dictionaryKind(for: $0.dictionary) == .bilingual
        }
    }

    // Translation phonetics removed per design — translation row stays single-line.

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    sourceBlock

                    if mode == .translate, !sourcePronunciation.isEmpty {
                        regionDivider
                        titledRegion("Phonetics") {
                            phoneticView(text: sourceText,
                                         fallbackLanguage: detectedSource?.rawValue,
                                         entries: sourcePronunciation)
                        }
                    }

                    if let mono = monolingualDictResult {
                        regionDivider
                        titledRegion("Source language explanation") {
                            dictionaryView(result: mono)
                        }
                    }

                    if let bi = bilingualDictResult {
                        regionDivider
                        titledRegion("Bilingual dictionary") {
                            dictionaryView(result: bi)
                        }
                    }

                    regionDivider
                    switch mode {
                    case .translate:
                        titledRegion("Translation") {
                            translationBlock
                        }
                    case .polish:
                        titledRegion("Polished" + (polishProviderName.isEmpty ? "" : " · \(polishProviderName)")) {
                            polishBlock
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)

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
        // Fill whatever size the NSPanel set by PopupController hands us. We can't
        // use NSHostingController's `.preferredContentSize` here because the body
        // contains a ScrollView, and ScrollView's unbounded intrinsic size crashes
        // the auto-layout pass during measurement.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { setupConfiguration() }
        .task { await loadAvailableLanguages() }
        .task(id: mode == .polish ? "polish-\(sourceText)" : "") {
            guard mode == .polish else { return }
            await runPolish()
        }
        .translationTask(mode == .translate ? configuration : nil) { session in
            await translate(using: session)
        }
        .translationTask(mode == .translate ? backConfiguration : nil) { session in
            await backTranslate(using: session)
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private var regionDivider: some View {
        Divider()
            .overlay(.tertiary.opacity(0.35))
    }

    private func titledRegion<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceBlock: some View {
        Text(sourceText)
            .font(.system(isSingleWord ? .largeTitle : .title2, design: .rounded).weight(.bold))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .lineLimit(isSingleWord ? 2 : 4)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
    }

    private var translationBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !backTranslated.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("↩")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(backTranslated)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help("Back-translation — what the translation means in the source language")
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var polishBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch polishStatus {
            case .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Polishing into \(localizedName(for: targetLang)) via \(polishProviderName.isEmpty ? "LLM" : polishProviderName)…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            case .ready:
                if !polishResult.issues.isEmpty {
                    polishIssuesSection
                }
                if !polishResult.variants.isEmpty {
                    polishVariantsSection
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var polishIssuesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Issues")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            ForEach(Array(polishResult.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 1) {
                    if let original = issue.original, !original.isEmpty {
                        Text("“\(original)”")
                            .font(.callout)
                            .foregroundStyle(Color.orange)
                            .textSelection(.enabled)
                    }
                    Text(issue.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var polishVariantsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !polishResult.issues.isEmpty {
                Text("Polished — click any to copy")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Click any to copy")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(polishResult.variants.enumerated()), id: \.offset) { idx, variant in
                variantRow(index: idx, variant: variant)
            }
        }
    }

    private func variantRow(index idx: Int, variant: PolishVariant) -> some View {
        let copied = copiedVariantIndex == idx
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if copied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("\(idx + 1).")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption.weight(.semibold))
            .frame(width: 18, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(variant.text)
                    .font(.system(idx == 0 ? .title3 : .body, design: .rounded)
                        .weight(idx == 0 ? .medium : .regular))
                    .fixedSize(horizontal: false, vertical: true)
                if let back = variant.backTranslation, !back.isEmpty {
                    Text(back)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(copied ? Color.green.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { copyVariant(variant.text, index: idx) }
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.set() }
            else { NSCursor.arrow.set() }
        }
        .help("Click to copy the polished version (native-language translation shown below for reference)")
        .animation(.easeOut(duration: 0.15), value: copied)
    }

    private func copyVariant(_ text: String, index: Int) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        Self.dbg("copied variant #\(index + 1) (\(text.count) chars)")
        copiedVariantIndex = index
        // Auto-clear after a short delay so the green confirmation fades away.
        let target = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if copiedVariantIndex == target { copiedVariantIndex = nil }
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

    private func dictionaryView(result: DictionaryLookup.SourcedEntry) -> some View {
        // Cap to the first 2 POS sections and 2 senses each — keeps the popup tight.
        VStack(alignment: .leading, spacing: 4) {
            Text(result.dictionary.name)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ForEach(Array(result.entry.parts.prefix(2).enumerated()), id: \.offset) { _, part in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(part.label)
                        .font(.system(.caption2, design: .rounded).italic())
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(part.definitions.prefix(2), id: \.self) { def in
                            definitionRow(def)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func definitionRow(_ def: Definition) -> some View {
        let segments = splitDefinition(def.text)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let n = def.number {
                Text("\(n).")
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if segment.isExample {
                            Text("▸")
                                .font(.system(.callout))
                                .foregroundStyle(.tertiary)
                        }
                        Text(segment.text)
                            .font(.system(.callout))
                            .foregroundStyle(segment.isExample ? .secondary : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Break a definition into renderable lines.
    /// - `;` and `；` (full-width) split distinct glosses (each → its own line).
    /// - `▸` separates a gloss from its example sentence (example marked separately
    ///   so the row renders with a `▸` prefix and dimmer color).
    private func splitDefinition(_ text: String) -> [(text: String, isExample: Bool)] {
        var result: [(String, Bool)] = []
        let glossSegments = text.split(whereSeparator: { $0 == ";" || $0 == "；" })
        for gloss in glossSegments {
            let trimmed = gloss.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "▸", omittingEmptySubsequences: false)
            for (i, part) in parts.enumerated() {
                let cleaned = part.trimmingCharacters(in: .whitespaces)
                guard !cleaned.isEmpty else { continue }
                result.append((cleaned, i > 0))
            }
        }
        return result
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
        let savedTarget = UserDefaults.standard.string(forKey: "glotty.targetLang")
        let detected: NLLanguage?
        // Polish always re-detects: it needs to know what language you actually
        // selected so it doesn't ask the LLM to "rewrite X in X" (a no-op).
        if mode == .translate, let savedSource, !savedSource.isEmpty {
            detected = NLLanguage(rawValue: savedSource)
        } else {
            detected = LanguagePolicy.detectSourceLanguage(sourceText)
        }
        detectedSource = detected

        let target: String
        switch mode {
        case .translate:
            target = (savedTarget?.isEmpty == false
                      ? savedTarget!
                      : LanguagePolicy.preferredTarget(for: detected))
        case .polish:
            // Polish output language: user pref → fallback to English (the most
            // common "I want this in idiomatic <X>" case for our audience).
            target = polishTargetLanguage()
        }
        targetLang = target

        if LanguagePolicy.isSingleWord(sourceText) {
            let available = DictionaryLookup.availableDictionaries()
            // Two independent priority-ordered lookups — one per dict kind. The popup
            // shows the first hit from each list in its own region; this prevents a
            // bilingual dict from crowding out the source-language slot or vice versa.
            let monoIDs = DictionarySelection.selectedIDs(
                kind: .monolingual,
                sourcePreference: savedSource ?? "",
                targetPreference: savedTarget ?? "",
                detectedSource: detected,
                availableDictionaries: available
            )
            let biIDs = DictionarySelection.selectedIDs(
                kind: .bilingual,
                sourcePreference: savedSource ?? "",
                targetPreference: savedTarget ?? "",
                detectedSource: detected,
                availableDictionaries: available
            )
            let monoResults = DictionaryLookup.allSourcedEntries(for: sourceText, selectedIDs: monoIDs)
            let biResults   = DictionaryLookup.allSourcedEntries(for: sourceText, selectedIDs: biIDs)
            dictResults = monoResults + biResults
            Self.dbg("dict — mono=[\(monoResults.map(\.dictionary.name).joined(separator: ", "))] " +
                     "bi=[\(biResults.map(\.dictionary.name).joined(separator: ", "))]")
        }

        Self.dbg("setup — text='\(sourceText)' detected=\(detected?.rawValue ?? "nil") target=\(target)")
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
        backTranslated = ""
        backConfiguration = nil
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
        Self.dbg("translate begin — text='\(sourceText)' target=\(targetLang)")
        do {
            let response = try await session.translate(sourceText)
            translated = response.targetText
            status = .ready
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            Self.dbg("translate ok — '\(sourceText)' → '\(response.targetText)' in \(elapsedMs)ms")

            // Bilateral: kick off a back-translation (target → source) so the user
            // can see what the translation "means" in their source language and
            // verify the round-trip preserved their intent. Skip when source and
            // target match (identity round-trip).
            if let sourceLang = detectedSource?.rawValue,
               sourceLang != targetLang,
               !response.targetText.isEmpty {
                backTranslated = ""
                backConfiguration = TranslationSession.Configuration(
                    source: Locale.Language(identifier: targetLang),
                    target: Locale.Language(identifier: sourceLang)
                )
            }
        } catch {
            Self.dbg("translate FAIL — '\(sourceText)' err=\(error.localizedDescription)")
            status = .failed(error.localizedDescription)
        }
    }

    private func backTranslate(using session: TranslationSession) async {
        let textToReverse = translated
        guard !textToReverse.isEmpty else { return }
        Self.dbg("back-translate begin — '\(textToReverse)' target=\(detectedSource?.rawValue ?? "?")")
        do {
            let response = try await session.translate(textToReverse)
            backTranslated = response.targetText
            Self.dbg("back-translate ok — '\(textToReverse)' → '\(response.targetText)'")
        } catch {
            // Don't fail the whole popup — bilateral is best-effort, the forward
            // translation has already succeeded by this point.
            Self.dbg("back-translate FAIL — err=\(error.localizedDescription)")
        }
    }

    private func runPolish() async {
        guard let provider = LLMRegistry.current() else {
            polishStatus = .failed("No LLM provider configured.")
            return
        }
        let outputLanguage = polishTargetLanguage()
        targetLang = outputLanguage
        polishStatus = .working
        polishResult = .empty
        polishProviderName = provider.displayName

        // Mode = proofread when source language ≈ output language (e.g. en source +
        // en target → "fix my English"); otherwise = variants (cross-language).
        let detectedRoot = detectedSource?.rawValue.split(separator: "-").first.map(String.init)
        let outputRoot = outputLanguage.split(separator: "-").first.map(String.init)
        let native = userNativeLanguage()
        // Skip back-translation when native == output (would be a no-op).
        let nativeForPrompt: String? = (native == outputLanguage) ? nil : native
        let mode: PolishMode = (detectedRoot != nil && detectedRoot == outputRoot)
            ? .proofreadAndPolish(target: outputLanguage, nativeLanguage: nativeForPrompt)
            : .variants(target: outputLanguage, nativeLanguage: nativeForPrompt)

        Self.dbg("polish begin — text='\(sourceText)' target=\(outputLanguage) native=\(nativeForPrompt ?? "(none)") provider=\(provider.id) mode=\(mode)")
        do {
            let result = try await provider.polish(sourceText, mode: mode)
            polishResult = result
            polishStatus = .ready
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            Self.dbg("polish ok — variants=\(result.variants.count) issues=\(result.issues.count) in \(elapsedMs)ms")
        } catch {
            Self.dbg("polish FAIL — err=\(error.localizedDescription)")
            polishStatus = .failed(error.localizedDescription)
        }
    }

    /// User's saved native language (from the Profile tab). Empty defaults to the
    /// system locale, falling back to English.
    private func userNativeLanguage() -> String {
        let raw = UserDefaults.standard.string(forKey: "glotty.user.nativeLanguage")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    private func polishTargetLanguage() -> String {
        let savedPolish = UserDefaults.standard.string(forKey: "glotty.polishLang")
        return (savedPolish?.isEmpty == false ? savedPolish! : "en")
    }

    private static func dbg(_ msg: String) {
        let line = "[\(Date())] PopupView: \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: "/tmp/glotty-debug.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: url)
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
    /// Two formats are supported:
    ///   1. **Dialect-labeled**: `BrE x, y, AmE z, w` (Chinese-English bilingual dicts).
    ///      Returns the FIRST IPA per dialect.
    ///   2. **Comma-separated alternates**: `ˈʃɛdjuːl, ˈskɛdʒuːl` (Oxford-style).
    ///      Treats first as BrE, second as AmE. Single-variant returns one unlabeled.
    static func parseDictionaryDefinition(_ definition: String) -> [PhoneticEntry] {
        guard let first = definition.firstIndex(of: "|") else { return [] }
        let afterFirst = definition.index(after: first)
        guard let second = definition[afterFirst...].firstIndex(of: "|") else { return [] }

        let block = String(definition[afterFirst..<second])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if block.range(of: #"\bBrE\b"#, options: .regularExpression) != nil ||
           block.range(of: #"\bAmE\b"#, options: .regularExpression) != nil {
            return parseDialectLabeledBlock(block)
        }
        return parseAlternatesBlock(block)
    }

    /// "BrE həˈləʊ, hɛˈləʊ, AmE həˈloʊ, hɛˈloʊ" → first BrE + first AmE.
    static func parseDialectLabeledBlock(_ block: String) -> [PhoneticEntry] {
        var bre: String?
        var ame: String?
        var current: String? // "BrE" | "AmE" | nil

        for raw in block.split(separator: ",") {
            var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("BrE ") {
                current = "BrE"
                token = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if token.hasPrefix("AmE ") {
                current = "AmE"
                token = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            token = token.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !token.isEmpty else { continue }
            switch current {
            case "BrE" where bre == nil: bre = token
            case "AmE" where ame == nil: ame = token
            default: break
            }
        }

        var entries: [PhoneticEntry] = []
        if let bre {
            entries.append(PhoneticEntry(label: "BrE", value: "/\(bre)/", voiceLocale: "en-GB"))
        }
        if let ame {
            entries.append(PhoneticEntry(label: "AmE", value: "/\(ame)/", voiceLocale: "en-US"))
        }
        return entries
    }

    /// Oxford-style: `ˈʃɛdjuːl, ˈskɛdʒuːl` → BrE+AmE; single variant → unlabeled.
    static func parseAlternatesBlock(_ block: String) -> [PhoneticEntry] {
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
