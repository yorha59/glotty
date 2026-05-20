import SwiftUI
import AppKit
import Translation
import NaturalLanguage
import AVFoundation
import CoreServices

/// Which Fn-leader command produced this popup. The view branches on this:
/// `.translate` runs Apple's Translation framework (decode: foreign → native,
/// one-line gloss, with phonetics + dict sections). `.explain` runs the LLM
/// for a richer prose explanation in the user's native language — same
/// direction as Translate but verbose and contextual instead of terse. The
/// LLM's output is plain text, streamed token-by-token. `.polish` rewrites
/// the user's own draft, also via LLM.
enum PopupMode: Equatable {
    case translate
    case explain
    case polish
}

/// Visual tokens taken from the Figma design (`Popup - Translate` / `Popup - Polish`
/// frames in the Glotty UI Sync file). Each color is **adaptive** — the Figma value
/// drives the light-mode appearance, and system semantic colors drive dark mode so
/// the popup doesn't blast bright surfaces against a dark desktop.
enum PopupTokens {
    // Surfaces — solid in light mode, semantic / material in dark mode.
    static let surface       = Color.adaptive(
        light: Color(hex: 0xF8F8FA),
        dark:  Color(nsColor: NSColor.windowBackgroundColor)
    )
    static let border        = Color.adaptive(
        light: Color(hex: 0xD8D8DD),
        dark:  Color(nsColor: NSColor.separatorColor)
    )
    static let variantTint   = Color.adaptive(
        light: Color(hex: 0xE8F1FF),
        dark:  Color.accentColor.opacity(0.18)
    )
    static let variantSurface = Color.adaptive(
        light: Color.white,
        dark:  Color(nsColor: NSColor.controlBackgroundColor)
    )

    // Text — Figma greys in light, system label colors in dark so contrast is right.
    static let primaryText   = Color.adaptive(
        light: Color(hex: 0x1D1D1F),
        dark:  Color(nsColor: NSColor.labelColor)
    )
    static let secondaryText = Color.adaptive(
        light: Color(hex: 0x6E6E73),
        dark:  Color(nsColor: NSColor.secondaryLabelColor)
    )
    static let tertiaryText  = Color.adaptive(
        light: Color(hex: 0x9A9AA2),
        dark:  Color(nsColor: NSColor.tertiaryLabelColor)
    )
    /// SwiftUI's accent color is already light/dark adaptive — Apple's macOS blue
    /// reads fine on both surfaces, and matches the Figma `#0A84FF` in light mode.
    static let accent        = Color.accentColor

    // Sizing
    static let containerPadding: CGFloat = 14
    static let containerRadius: CGFloat = 16
    static let sectionGap: CGFloat = 10
    static let variantCardPadding: CGFloat = 10
    static let variantCardRadius: CGFloat = 8
    /// Fixed content width for the translate / explain popup. The popup
    /// auto-fits its *height* to the content (via
    /// NSHostingController.preferredContentSize), but width is anchored so
    /// layout is predictable and the panel doesn't jitter on async content
    /// arrival.
    static let translateContentWidth: CGFloat = 460
    /// Polish needs a bit more width for the variant cards (full sentences).
    /// Same auto-fit-height behaviour as translate.
    static let polishContentWidth: CGFloat = 560
    /// Uniform font size for every non-source-row element in the translate
    /// popup (section labels, dict names, POS labels, glosses, defs, examples,
    /// translation result). Source row stays at its dedicated large size; the
    /// footer keeps its smaller metadata size.
    static let bodySize: CGFloat = 14
}

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }

    /// Build a Color that picks `light` vs `dark` based on the runtime appearance
    /// of whatever view it's resolved in. Uses `NSColor`'s dynamic provider under
    /// the hood, so it tracks system appearance changes without needing to plumb
    /// `@Environment(\.colorScheme)` through every consumer.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return NSColor(isDark ? dark : light)
        })
    }
}

struct PopupView: View {
    let sourceText: String
    let mode: PopupMode
    let onClose: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    @State private var translated: String = ""
    @State private var configuration: TranslationSession.Configuration?
    @State private var status: Status = .working
    @State private var backTranslated: String = ""
    @State private var backConfiguration: TranslationSession.Configuration?
    @State private var polishStatus: Status = .working
    @State private var polishResult: PolishResult = .empty
    @State private var polishProviderName: String = ""
    /// Raw LLM output as it streams. Polish output is JSON, which is unreadable
    /// during the early skeleton-only chunks — so we show it as raw text in a
    /// small terminal-style block while streaming, then crossfade to the
    /// parsed variant cards once the stream finishes.
    @State private var polishRawText: String = ""
    @State private var copiedVariantIndex: Int? = nil
    /// Explain mode runs the LLM for a prose explanation in the user's native
    /// language. Text streams in chunk-by-chunk and we render it directly — no
    /// JSON shape, no variant cards.
    @State private var explainText: String = ""
    @State private var explainStatus: Status = .working
    @State private var explainProviderName: String = ""
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

    /// Show the Translation section unless source and target are the *same
    /// language* AND the framework returned the input unchanged (e.g. Chinese
    /// sentence translated into Chinese is a no-op). Cross-language pairs like
    /// en→zh or zh→en always render — even if the text happens to match (rare
    /// edge case for single tokens like "OK"), the result is still meaningful
    /// because it crossed a language boundary. `.working` / `.failed` always
    /// render so the spinner / error stays visible.
    private var shouldShowTranslationSection: Bool {
        switch status {
        case .working, .failed:
            return true
        case .ready:
            let tgt = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tgt.isEmpty else { return false }

            // Compare language roots — "zh-Hans" and "zh-Hant" both share root
            // "zh", so a Simplified ↔ Traditional pass that happens to no-op
            // still gets suppressed. Cross-language never suppresses.
            let srcRoot = detectedSource?.rawValue.split(separator: "-").first.map(String.init)
            let tgtRoot = targetLang.split(separator: "-").first.map(String.init)
            let sameLanguage = (srcRoot != nil) && srcRoot == tgtRoot
            guard sameLanguage else { return true }

            let src = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            return tgt != src
        }
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
        outerLayout
            .background(containerBackground)
            .onAppear { setupConfiguration() }
            .task { await loadAvailableLanguages() }
            .task(id: mode == .polish ? "polish-\(sourceText)" : "") {
                guard mode == .polish else { return }
                await runPolish()
            }
            // Explain calls the LLM for a prose explanation — same direction as
            // Translate (output in user's native language) but verbose and
            // contextual. The id includes targetLang so changing the target via
            // the footer menu re-fires the LLM.
            .task(id: mode == .explain ? "explain-\(sourceText)-\(targetLang)" : "") {
                guard mode == .explain else { return }
                await runExplain()
            }
            // Apple Translation only powers decode (`.translate`). Explain and
            // Polish are both LLM-driven (handled by the task modifiers above).
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

    /// All three modes use the same auto-fit layout: no ScrollView, fixed
    /// width per mode, intrinsic height. The hosting controller's
    /// `preferredContentSize` drives the panel size so it tracks the content
    /// exactly — no large blank area below a short Polish result, and the
    /// translate panel doesn't get cut off by a scroll bar either.
    private var outerLayout: some View {
        VStack(alignment: .leading, spacing: PopupTokens.sectionGap) {
            contentColumn
            footerBar
        }
        .padding(PopupTokens.containerPadding)
        .frame(width: contentWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Polish wants a wider content column (variant cards hold full sentences);
    /// translate and explain stay at the original 460pt.
    private var contentWidth: CGFloat {
        switch mode {
        case .polish:              return PopupTokens.polishContentWidth
        case .translate, .explain: return PopupTokens.translateContentWidth
        }
    }

    /// All section blocks above the footer. Extracted so both layouts can reuse it.
    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: PopupTokens.sectionGap) {
            sourceBlock

            if mode == .translate, !sourcePronunciation.isEmpty {
                regionDivider
                sectionLabel("Phonetics")
                phoneticView(text: sourceText,
                             fallbackLanguage: detectedSource?.rawValue,
                             entries: sourcePronunciation)
            }

            if mode == .translate, let mono = monolingualDictResult {
                regionDivider
                sectionLabel("Source language explanation")
                dictionaryView(result: mono)
            }

            if mode == .translate, let bi = bilingualDictResult {
                regionDivider
                sectionLabel("Bilingual dictionary")
                dictionaryView(result: bi)
            }

            // Hide the whole Translation section (label + body + divider
            // above) when the translation is identical to the source —
            // happens when the user picks a Chinese sentence and the
            // target is also Chinese, so the framework returns the input
            // unchanged. Polish mode always shows; its variants are
            // rewrites, not identity.
            if mode == .polish || mode == .explain || shouldShowTranslationSection {
                regionDivider
                switch mode {
                case .translate:
                    sectionLabel("Translation")
                    translationBlock
                case .explain:
                    sectionLabel(explainSectionLabel)
                    explainBlock
                case .polish:
                    sectionLabel("Polished" + (polishProviderName.isEmpty ? "" : " · \(polishProviderName)"))
                    polishBlock
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var regionDivider: some View {
        Rectangle()
            .fill(PopupTokens.border)
            .frame(height: 1)
    }

    /// Container background: flat Figma surface in light mode, translucent
    /// `.regularMaterial` in dark mode (the previous design — readable against a
    /// dark desktop without the harshness of a solid pale surface).
    @ViewBuilder
    private var containerBackground: some View {
        let shape = RoundedRectangle(cornerRadius: PopupTokens.containerRadius, style: .continuous)
        if colorScheme == .dark {
            shape
                .fill(.regularMaterial)
                .overlay(shape.strokeBorder(PopupTokens.border.opacity(0.6), lineWidth: 0.5))
        } else {
            shape
                .fill(PopupTokens.surface)
                .overlay(shape.strokeBorder(PopupTokens.border, lineWidth: 1))
        }
    }

    /// Section header — same body size as content per user request, but weight +
    /// color keep it distinguishable as a label.
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: PopupTokens.bodySize, weight: .semibold))
            .foregroundStyle(PopupTokens.tertiaryText)
    }

    /// Bottom-of-popup footer per Figma: `source → target  [spacer]  142ms · Esc`.
    /// All 11pt regular tertiary. The target name is a Menu (per-popup override).
    private var footerBar: some View {
        HStack(spacing: 6) {
            Text(footerSourceLabel)
                .font(.system(size: 11))
                .foregroundStyle(PopupTokens.tertiaryText)
            Text("→")
                .font(.system(size: 11))
                .foregroundStyle(PopupTokens.tertiaryText)
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
                    Text(footerTargetLabel)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(PopupTokens.tertiaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
            Text("\(elapsedMs)ms · Esc")
                .font(.system(size: 11))
                .foregroundStyle(PopupTokens.tertiaryText)
        }
    }

    /// Footer label for the source language. Use the language code (e.g. `en`)
    /// for the source — matches Figma's `en → Chinese (Simplified)`.
    private var footerSourceLabel: String {
        detectedSource?.rawValue ?? "auto"
    }

    /// Footer label for the target language. Figma uses `Chinese (Simplified)`
    /// style with parens; macOS Locale gives `Chinese, Simplified` with a comma.
    /// Reformat to match Figma.
    private var footerTargetLabel: String {
        let raw = localizedName(for: targetLang)
        // `Chinese, Simplified` → `Chinese (Simplified)`
        if let commaRange = raw.range(of: ", ") {
            let head = raw[..<commaRange.lowerBound]
            let tail = raw[commaRange.upperBound...]
            return "\(head) (\(tail))"
        }
        return raw
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

    /// Source headword. Figma: 34pt bold for single-word translate/explain,
    /// 24pt for sentence translate/explain, 26pt for polish (longer source text).
    private var sourceBlock: some View {
        let size: CGFloat
        switch mode {
        case .translate, .explain: size = isSingleWord ? 34 : 24
        case .polish:              size = 26
        }
        return Text(sourceText)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(PopupTokens.primaryText)
            .textSelection(.enabled)
            .lineLimit((mode == .translate || mode == .explain) && isSingleWord ? 2 : 4)
            .minimumScaleFactor(0.82)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var translationBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch status {
            case .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Translating…")
                        .font(.system(size: PopupTokens.bodySize))
                        .foregroundStyle(PopupTokens.secondaryText)
                }
            case .ready:
                // Uniform body size for non-source-row content. Source row is the
                // only "large" element on the page.
                Text(translated)
                    .font(.system(size: PopupTokens.bodySize, weight: .medium))
                    .foregroundStyle(PopupTokens.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                Text(message)
                    .font(.system(size: PopupTokens.bodySize))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Explanation in English · Anthropic Claude" — the section label shown
    /// above the streaming explanation block. Mirrors the polish label format
    /// so the provider attribution stays consistent across modes.
    private var explainSectionLabel: String {
        let base = "Explanation in \(footerTargetLabel)"
        return explainProviderName.isEmpty ? base : "\(base) · \(explainProviderName)"
    }

    /// Working-state spinner label for polish (single mode now — explain has
    /// its own dedicated block).
    private var polishWorkingLabel: String {
        let provider = polishProviderName.isEmpty ? "LLM" : polishProviderName
        return "Polishing into \(footerTargetLabel) via \(provider)…"
    }

    /// The Explain mode body — prose that streams in token by token. The
    /// prompt asks the LLM for three titled sections (`## Title\nBody`); we
    /// split on blank lines, peel off the title line from each block, and
    /// render title and body in a vertical stack so each section is visually
    /// distinct.
    private var explainBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch explainStatus {
            case .working where explainText.isEmpty:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(explainWorkingLabel)
                        .font(.system(size: PopupTokens.bodySize))
                        .foregroundStyle(PopupTokens.secondaryText)
                }
            case .working, .ready:
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(explainSections.enumerated()), id: \.offset) { _, section in
                        VStack(alignment: .leading, spacing: 4) {
                            if !section.title.isEmpty {
                                Text(section.title)
                                    .font(.system(size: PopupTokens.bodySize, weight: .semibold))
                                    .foregroundStyle(PopupTokens.accent)
                            }
                            if !section.body.isEmpty {
                                Text(section.body)
                                    .font(.system(size: PopupTokens.bodySize))
                                    .foregroundStyle(PopupTokens.primaryText)
                                    .textSelection(.enabled)
                                    .lineSpacing(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: PopupTokens.bodySize))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One parsed section from the streamed explanation. Either field may be
    /// empty mid-stream (e.g. the title has arrived but no body yet).
    private struct ExplainSection {
        let title: String
        let body: String
    }

    /// Split the streamed explanation into titled sections. Blocks separated
    /// by blank lines; within each block the first line is the title (stripped
    /// of `## ` or `**…**` markdown) and the remaining lines are the body.
    /// During streaming the last block may have just a title with no body —
    /// that's fine, it'll render title-only and the body fills in as chunks
    /// arrive.
    private var explainSections: [ExplainSection] {
        explainText
            .components(separatedBy: "\n\n")
            .compactMap { block -> ExplainSection? in
                let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }

                // Split first line vs rest.
                if let newlineRange = trimmed.range(of: "\n") {
                    let firstLine = trimmed[..<newlineRange.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let rest = trimmed[newlineRange.upperBound...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let (title, isTitle) = Self.parseTitleLine(firstLine)
                    if isTitle {
                        return ExplainSection(title: title, body: rest)
                    }
                    // No title marker on the first line — render the whole
                    // block as body-only so we don't lose content if the LLM
                    // skips the `##` prefix.
                    return ExplainSection(title: "", body: trimmed)
                }

                // Single-line block (mid-stream, before the body starts).
                let (title, isTitle) = Self.parseTitleLine(trimmed)
                if isTitle {
                    return ExplainSection(title: title, body: "")
                }
                return ExplainSection(title: "", body: trimmed)
            }
    }

    /// Strip a leading title marker from `line`. Returns `(title, isTitle)`:
    /// `## Foo` → `("Foo", true)`; `**Foo**` → `("Foo", true)`; anything else →
    /// `(line, false)`.
    private static func parseTitleLine(_ line: String) -> (String, Bool) {
        if line.hasPrefix("## ") {
            return (String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines), true)
        }
        if line.hasPrefix("##") {
            return (String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines), true)
        }
        if line.hasPrefix("**"), line.hasSuffix("**"), line.count >= 4 {
            let inner = line.dropFirst(2).dropLast(2)
            return (String(inner).trimmingCharacters(in: .whitespacesAndNewlines), true)
        }
        return (line, false)
    }

    private var explainWorkingLabel: String {
        let provider = explainProviderName.isEmpty ? "LLM" : explainProviderName
        return "Asking \(provider) to explain in \(footerTargetLabel)…"
    }

    private var polishBlock: some View {
        VStack(alignment: .leading, spacing: PopupTokens.sectionGap) {
            switch polishStatus {
            case .working where polishRawText.isEmpty:
                // Pre-first-chunk: tiny header spinner so the user knows we're
                // waiting for the model. Flips to the terminal as soon as any
                // text arrives.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(polishWorkingLabel)
                        .font(.system(size: 13))
                        .foregroundStyle(PopupTokens.secondaryText)
                }
            case .working:
                polishStreamingTerminal
                    .transition(.opacity)
            case .ready:
                Group {
                    if !polishResult.variants.isEmpty {
                        polishVariantsSection
                    }
                    if !polishResult.issues.isEmpty {
                        regionDivider
                        sectionLabel("Issues")
                        polishIssuesSection
                    }
                }
                .transition(.opacity)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: isPolishReady)
    }

    /// SwiftUI .animation needs a `Hashable` value to compare. Boolean shortcut
    /// for "are we showing the terminal or the final cards" — flips exactly
    /// once per polish run, which is when the crossfade should happen.
    private var isPolishReady: Bool {
        if case .ready = polishStatus { return true }
        return false
    }

    /// Terminal-style block shown while the LLM streams raw JSON. Dark surface,
    /// monospace text, blinking cursor — visually distinct from the popup so
    /// the user knows "this is in-progress output, not the final result".
    private var polishStreamingTerminal: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text("Streaming from \(polishProviderName.isEmpty ? "LLM" : polishProviderName)…")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.green.opacity(0.9))
                Spacer()
            }
            Text(polishRawText + "▍")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.88, green: 0.92, blue: 0.88))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.22), lineWidth: 0.5)
                )
        )
    }

    /// Figma: "Issues" label (rendered by sectionLabel above) + body text
    /// 13pt regular `#6E6E73`. Issue spans (if present) are quoted with
    /// orange tint to stay distinguishable.
    private var polishIssuesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(polishResult.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 1) {
                    if let original = issue.original, !original.isEmpty {
                        Text("“\(original)”")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.orange)
                            .textSelection(.enabled)
                    }
                    Text(issue.explanation)
                        .font(.system(size: 13))
                        .foregroundStyle(PopupTokens.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Figma: variants rendered as rounded cards. First variant has a light blue
    /// tint (`#E8F1FF`), the rest are white. Border `#D8D8DD`, 8pt radius, 10pt
    /// padding. Each card contains `text` (15pt medium) + `Back: …` (11pt regular
    /// secondary). Click to copy; brief green tint as confirmation.
    private var polishVariantsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(polishResult.variants.enumerated()), id: \.offset) { idx, variant in
                variantCard(index: idx, variant: variant)
            }
        }
    }

    private func variantCard(index idx: Int, variant: PolishVariant) -> some View {
        let copied = copiedVariantIndex == idx
        let baseTint: Color = idx == 0 ? PopupTokens.variantTint : PopupTokens.variantSurface
        let backgroundColor: Color = copied ? Color.green.opacity(0.12) : baseTint
        // No `.textSelection(.enabled)` on inner Text — text selection captures
        // mouse clicks before they reach the card's `onTapGesture`, breaking the
        // click-to-copy behavior. The whole card is the copy target instead.
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(variant.text)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(PopupTokens.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if copied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            if let back = variant.backTranslation, !back.isEmpty {
                Text(back)
                    .font(.system(size: 11))
                    .foregroundStyle(PopupTokens.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PopupTokens.variantCardPadding)
        .background(
            RoundedRectangle(cornerRadius: PopupTokens.variantCardRadius, style: .continuous)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: PopupTokens.variantCardRadius, style: .continuous)
                        .strokeBorder(PopupTokens.border, lineWidth: 1)
                )
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
                                .font(.system(size: PopupTokens.bodySize, design: .rounded).weight(.semibold))
                                .foregroundStyle(PopupTokens.tertiaryText)
                                .frame(width: 36, alignment: .leading)
                        }
                        Text(entry.value)
                            .font(.system(size: PopupTokens.bodySize, design: .serif))
                            .foregroundStyle(PopupTokens.secondaryText)
                            .textSelection(.enabled)
                        Button {
                            Speaker.shared.speak(text,
                                                 language: entry.voiceLocale ?? fallbackLanguage)
                        } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: PopupTokens.bodySize))
                                .foregroundStyle(PopupTokens.tertiaryText)
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
        // Figma: dict name 12pt semibold accent blue; bilingual gloss 20pt semibold;
        // monolingual defs 14pt regular.
        let isBilingual = DictionarySelection
            .dictionaryKind(for: result.dictionary) == .bilingual
        return VStack(alignment: .leading, spacing: 6) {
            Text(result.dictionary.name)
                .font(.system(size: PopupTokens.bodySize, weight: .semibold))
                .foregroundStyle(PopupTokens.accent)
                .lineLimit(1)
                .truncationMode(.middle)

            ForEach(Array(result.entry.parts.prefix(2).enumerated()), id: \.offset) { _, part in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(part.label)
                        .font(.system(size: PopupTokens.bodySize, design: .rounded).italic())
                        .foregroundStyle(PopupTokens.tertiaryText)
                        .frame(width: 56, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(part.definitions.prefix(2), id: \.self) { def in
                            definitionRow(def, prominentGloss: isBilingual)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func definitionRow(_ def: Definition, prominentGloss: Bool = false) -> some View {
        let segments = splitDefinition(def.text)
        // Uniform body size — bilingual vs monolingual differ only by weight.
        let glossFont: Font = prominentGloss
            ? .system(size: PopupTokens.bodySize, weight: .semibold)
            : .system(size: PopupTokens.bodySize)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if let n = def.number {
                Text("\(n).")
                    .font(.system(size: PopupTokens.bodySize, design: .rounded).weight(.semibold))
                    .foregroundStyle(PopupTokens.tertiaryText)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if segment.isExample {
                            Text("▸")
                                .font(.system(size: PopupTokens.bodySize))
                                .foregroundStyle(PopupTokens.tertiaryText)
                        }
                        Text(segment.text)
                            .font(segment.isExample
                                  ? .system(size: PopupTokens.bodySize)
                                  : glossFont)
                            .foregroundStyle(segment.isExample
                                             ? PopupTokens.secondaryText
                                             : PopupTokens.primaryText)
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

        // Detection runs for all modes — for `.explain` it's purely cosmetic
        // (footer label only); the LLM call doesn't depend on it. The selection
        // language might be anything the user picked, and the explanation goes
        // out in their native language regardless.
        let detected: NLLanguage? = LanguagePolicy.detectSourceLanguage(sourceText)
        detectedSource = detected

        let target: String
        switch mode {
        case .translate:
            // Default direction: saved target (or preferred fallback) for the
            // source language. Bilateral flip: when source language matches
            // target language (e.g. saved target is zh-Hans and the user picks
            // Chinese text), translate in the opposite direction instead — so
            // zh source → en. Without this flip the only sensible outcome would
            // be suppressing the row, which loses information.
            var initial = (savedTarget?.isEmpty == false
                           ? savedTarget!
                           : LanguagePolicy.preferredTarget(for: detected))
            let srcRoot = detected?.rawValue.split(separator: "-").first.map(String.init)
            let tgtRoot = initial.split(separator: "-").first.map(String.init)
            if let srcRoot, srcRoot == tgtRoot {
                // First try the saved source preference as the new target — that
                // gives the user explicit control over the other half of the pair.
                let savedSourcePref = UserDefaults.standard.string(forKey: "glotty.sourceLang")?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let pref = savedSourcePref, !pref.isEmpty,
                   pref.split(separator: "-").first.map(String.init) != srcRoot {
                    initial = pref
                } else {
                    // Otherwise fall back to the heuristic — preferredTarget(.chinese)
                    // returns "en", preferredTarget(.english) returns user-locale
                    // or zh-Hans.
                    initial = LanguagePolicy.preferredTarget(for: detected)
                }
            }
            target = initial
        case .explain:
            // Explain output = the user's native language. That's the saved
            // Translation "target" (where decode lands its results). Empty →
            // fall back to the Profile native lang, then English.
            let trimmedTarget = savedTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedTarget.isEmpty {
                target = trimmedTarget
            } else {
                target = userNativeLanguage()
            }
        case .polish:
            // Polish output language: user pref → fallback to English (the most
            // common "I want this in idiomatic <X>" case for our audience).
            target = polishTargetLanguage()
        }
        targetLang = target

        // Dictionary lookup is decode-mode only (`.translate`). Explain reads
        // a single prose block from the LLM; polish has no dict section.
        if mode == .translate, LanguagePolicy.isSingleWord(sourceText) {
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

        Self.dbg("setup — mode=\(mode) text='\(sourceText)' detected=\(detected?.rawValue ?? "nil") target=\(target)")
        rebuildConfiguration()
    }

    private func changeTarget(to newLang: String) {
        guard newLang != targetLang else { return }
        targetLang = newLang
        // Per-translation override only — Settings panel owns the persistent default.
        rebuildConfiguration()
    }

    private func rebuildConfiguration() {
        // Explain doesn't use the Apple Translation pipeline — re-firing the
        // LLM on target change is handled by the `.task(id: "explain-…")`
        // modifier in `body` (the id contains `targetLang`).
        if mode == .explain { return }

        translated = ""
        backTranslated = ""
        backConfiguration = nil

        // Skip the translation pass entirely when source and target are the same
        // language — the result would just duplicate the source row. Marking the
        // status `.ready` with empty `translated` lets `shouldShowTranslationSection`
        // hide the row without ever flashing a spinner.
        let srcRoot = detectedSource?.rawValue.split(separator: "-").first.map(String.init)
        let tgtRoot = targetLang.split(separator: "-").first.map(String.init)
        if let srcRoot, srcRoot == tgtRoot {
            status = .ready
            configuration = nil
            Self.dbg("translate skipped — source language matches target (\(targetLang))")
            return
        }

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
            translated = Self.flattenWhitespace(response.targetText)
            status = .ready
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            Self.dbg("translate ok — '\(sourceText)' → '\(response.targetText)' in \(elapsedMs)ms")

            // Bilateral: kick off a back-translation (target → source) so the user
            // can see what the translation "means" in their source language and
            // verify the round-trip preserved their intent. Skip when source and
            // target match (identity round-trip). Only `.translate` triggers
            // back-translation — Explain and Polish are LLM-driven and don't
            // use the Apple Translation pipeline.
            if mode == .translate,
               let sourceLang = detectedSource?.rawValue,
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
            backTranslated = Self.flattenWhitespace(response.targetText)
            Self.dbg("back-translate ok — '\(textToReverse)' → '\(response.targetText)'")
        } catch {
            // Don't fail the whole popup — bilateral is best-effort, the forward
            // translation has already succeeded by this point.
            Self.dbg("back-translate FAIL — err=\(error.localizedDescription)")
        }
    }

    /// Explain calls the LLM with the explain prompt (prose, no JSON) and
    /// streams the accumulated text into `explainText` chunk by chunk so the
    /// popup fills in live.
    private func runExplain() async {
        guard let provider = LLMRegistry.current() else {
            explainStatus = .failed("No LLM provider configured. Add one in Settings → Language Model.")
            return
        }
        let outputLanguage = targetLang
        explainStatus = .working
        explainText = ""
        explainProviderName = provider.displayName

        Self.dbg("explain begin — text='\(sourceText)' target=\(outputLanguage) provider=\(provider.id)")
        do {
            for try await snapshot in provider.explainStream(sourceText, targetLanguage: outputLanguage) {
                explainText = snapshot
            }
            explainStatus = .ready
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            Self.dbg("explain ok — \(explainText.count) chars in \(elapsedMs)ms")
        } catch {
            Self.dbg("explain FAIL — err=\(error.localizedDescription)")
            explainStatus = .failed(error.localizedDescription)
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
            // Stream the **raw** text via chatCompletionStream — the same
            // transport Explain uses — and only parse the JSON once the stream
            // finishes. Why not the structured polishStream? Polish output is
            // JSON, so the partial parser yields nothing useful until the
            // first variant text appears, leading to a perceived "stuck" beat.
            // Showing raw text in the terminal block gives instant feedback;
            // the structured cards take over at the end.
            polishRawText = ""
            let prompt = PolishPrompt.build(text: sourceText, mode: mode)
            for try await accumulated in provider.chatCompletionStream(prompt: prompt) {
                polishRawText = accumulated
            }
            polishResult = PolishResult.parse(polishRawText)
            polishStatus = .ready
            elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
            Self.dbg("polish ok — variants=\(polishResult.variants.count) issues=\(polishResult.issues.count) in \(elapsedMs)ms")
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

    /// Apple's `Translation` framework sometimes returns multi-line output even
    /// for single-line input (especially when the source selection contained
    /// line breaks from a wrapped paragraph). Collapse any whitespace run —
    /// `\r\n`, `\n`, `\r`, tab, multiple spaces — into a single space so the
    /// Translation row stays a clean inline string.
    static func flattenWhitespace(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
