import AppKit
import SwiftUI

/// Two-stage card shown when the user presses Fn → T without any
/// activated macOS dictionaries. Stage 1 explains the problem and
/// hands off to Settings → Dictionaries. Stage 2 appears
/// automatically when the dictionary count goes from zero to
/// non-zero (the user activated something) and prompts them to
/// highlight a sample word and try Translate end-to-end.
///
/// Modelled on `WelcomeWindowController` — fixed-size styled window,
/// singleton controller, `isShowing` flag the hotkey path can check.
/// Unlike Welcome, this window does NOT intercept Fn-T while open:
/// once stage 2 is reached, dictionaries are activated and the gate
/// in `handleFire` no longer fires, so a real Fn-T press from the
/// user produces a real Translate popup against the sample word.
@MainActor
final class TranslateGuideWindowController: ObservableObject {
    static let shared = TranslateGuideWindowController()

    /// UserDefaults flag. Set to `true` on dismiss (any path —
    /// closing the window, clicking Done, clicking Skip) so the
    /// gate in `AppDelegate.handleFire` only ever fires once.
    static let userDefaultsKey = "glotty.dictionaries.guidanceShown"

    /// Current activated-dictionary count, observed by the view to
    /// decide which stage to render. The poll timer updates this
    /// every 1.5s while the window is on screen.
    @Published var dictionaryCount: Int = 0

    private var window: NSWindow?
    private var host: NSViewController?
    private var pollTimer: Timer?

    var isShowing: Bool { window != nil }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        dictionaryCount = DictionaryLookup.availableDictionaries().count

        let view = TranslateGuideView(
            controller: self,
            onOpenDictionarySettings: {
                SettingsWindowController.shared.show(selecting: .dictionaries)
            },
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )
        let host = NSHostingController(rootView: view)
        self.host = host

        let w = NSWindow(contentViewController: host)
        // Use the standard swizzled localization (Glotty's UI
        // language). Unlike Welcome — which uses OSLocalizer to
        // show OS-language strings to a user who hasn't configured
        // Glotty yet — by the time the Translate gate fires, the
        // user has completed setup and expects strings in the
        // Glotty UI language they (implicitly or explicitly) chose.
        w.title = "Set up Translate".t
        // `.resizable` as the fallback to the screen-clamped size below —
        // the user can always drag an edge if the auto size doesn't fit.
        w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.setContentSizeClampedToScreen(NSSize(width: 460, height: 340))
        w.contentMinSize = NSSize(width: 360, height: 260)
        w.center()
        w.collectionBehavior = [.moveToActiveSpace]
        window = w

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }

        // Poll for dict-state changes. macOS doesn't broadcast a
        // notification when the user toggles dictionaries in
        // Dictionary.app or Settings → Dictionaries, and
        // `DictionaryLookup.availableDictionaries()` is cheap (it
        // reads the active-dictionaries list once and walks it).
        // 1.5s is responsive enough that toggling feels live
        // without burning CPU when the window sits idle.
        let timer = Timer.scheduledTimer(
            withTimeInterval: 1.5,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let count = DictionaryLookup.availableDictionaries().count
                if count != self.dictionaryCount {
                    self.dictionaryCount = count
                }
            }
        }
        pollTimer = timer

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        UserDefaults.standard.set(true, forKey: Self.userDefaultsKey)
        pollTimer?.invalidate()
        pollTimer = nil
        window?.orderOut(nil)
        window = nil
        host = nil
    }
}

// MARK: - View

private struct TranslateGuideView: View {
    @ObservedObject var controller: TranslateGuideWindowController
    let onOpenDictionarySettings: () -> Void
    let onDismiss: () -> Void

    /// Sample word for the try-it stage. `ephemeral` is recognizable
    /// across English dictionaries (literary register, no proper
    /// noun, no specialized jargon) and has a definition rich enough
    /// to demonstrate Glotty's popup — etymology, synonyms, example
    /// sentence — without being so common the user already knows it.
    private let sampleWord = "ephemeral"

    private var isReady: Bool { controller.dictionaryCount > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            if isReady {
                stageReady
            } else {
                stageNeedsSetup
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.25), value: isReady)
        .localizationAware()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isReady ? "checkmark.seal.fill" : "book.closed")
                .font(.system(size: 32))
                .foregroundStyle(isReady ? Color.green : Color.accentColor)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 2) {
                Text(isReady
                     ? "You're set — try Translate"
                     : "Activate a dictionary first")
                    .font(.title3.weight(.semibold))
                Text(isReady
                     ? "\(controller.dictionaryCount) dictionary\(controller.dictionaryCount == 1 ? "" : "s") active"
                     : "Translate needs a dictionary to look words up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stageNeedsSetup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Glotty's Translate uses the dictionaries macOS has activated. You don't have any activated yet — open Settings → Dictionaries to enable the ones you need (English, Chinese, Japanese, and more are included with macOS).".t)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stageReady: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Highlight the word below in any app — your browser, a doc, Notes — then press Fn → T. Glotty's popup should appear with the definition and translation.".t)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(sampleWord)
                    .font(.title2.italic().weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.gray.opacity(0.12))
                    )
                    .textSelection(.enabled)
                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack {
            if isReady {
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Skip for now") { onDismiss() }
                Spacer()
                Button("Open Dictionary Settings") { onOpenDictionarySettings() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
