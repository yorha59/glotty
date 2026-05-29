import AppKit
import SwiftUI

/// Interactive first-run walkthrough. Shown once on the very first launch
/// (gated by the `welcomeShown` UserDefaults flag) and re-openable later
/// from the menu-bar mascot menu. Stepped layout: welcome → hotkey demo →
/// provider setup → done.
@MainActor
final class WelcomeWindowController {
    static let shared = WelcomeWindowController()

    /// Set to true when the user finishes or dismisses the walkthrough.
    /// Reading is the cheapest possible "has this user seen onboarding"
    /// signal — preferred over schema-guessing against MemoryStore.
    static let userDefaultsKey = "glotty.welcomeShown"

    private var window: NSWindow?

    /// Show the walkthrough on first run only. Cheap no-op if the flag is
    /// set. Safe to call from `applicationDidFinishLaunching`; defers to
    /// the next runloop tick to avoid the SwiftUI App-scene init deadlock
    /// that bit the permissions opener.
    func showIfFirstRun() {
        guard !UserDefaults.standard.bool(forKey: Self.userDefaultsKey) else { return }
        DispatchQueue.main.async { [weak self] in self?.show() }
    }

    /// Force-show the walkthrough — used by the menu-bar "Show welcome…"
    /// item so curious users can revisit it.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let view = WelcomeView(
            onClose: { [weak self] in self?.dismiss(markShown: true) },
            onOpenSettings: { SettingsWindowController.shared.show(selecting: .languageModel) }
        )
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]

        let w = NSWindow(contentViewController: host)
        w.title = "Welcome to Glotty"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.center()
        w.collectionBehavior = [.moveToActiveSpace]
        window = w

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.dismiss(markShown: true) }
        }

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func dismiss(markShown: Bool) {
        if markShown {
            UserDefaults.standard.set(true, forKey: Self.userDefaultsKey)
        }
        window?.orderOut(nil)
        window = nil
    }
}

/// Stepped SwiftUI body. Each step is a small struct holding the title,
/// body, and an optional embedded view (the hotkey grid, the "Open
/// Settings" button). Bottom bar shows page dots + Back/Next so the
/// user can flip through at their own pace.
private struct WelcomeView: View {
    let onClose: () -> Void
    let onOpenSettings: () -> Void

    @State private var step: Int = 0

    private static let contentWidth: CGFloat = 460

    private var stepCount: Int { 4 }

    var body: some View {
        VStack(spacing: 18) {
            mascotHeader

            VStack(alignment: .leading, spacing: 10) {
                Text(currentTitle)
                    .font(.title2.weight(.semibold))
                Text(currentBody)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                currentExtra
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 4)

            footerBar
        }
        .padding(24)
        .frame(width: Self.contentWidth)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Header

    /// Big mascot at the top — uses the same status-bar icon asset as the
    /// menu so the user starts to associate the face with Glotty before
    /// they ever see the live mascot.
    private var mascotHeader: some View {
        HStack {
            Spacer()
            if let mascot = NSImage(named: "StatusItemIcon") {
                Image(nsImage: mascot)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
            }
            Spacer()
        }
    }

    // MARK: - Step content

    private var currentTitle: String {
        switch step {
        case 0: return "Welcome to Glotty"
        case 1: return "Hold Fn, then a letter"
        case 2: return "Pick your AI provider"
        default: return "You're all set"
        }
    }

    private var currentBody: String {
        switch step {
        case 0:
            return "Glotty is a language tutor that lives in your menu bar. Select text in any app, hold the Fn-leader key, and Glotty pops up to translate, explain, polish, or chat — all powered by the LLM you choose."
        case 1:
            return "While text is selected, hold Fn to bring up the action menu, then press the highlighted letter for what you want. The HUD shows all four commands."
        case 2:
            return "Glotty needs an LLM behind it. Pick a stock provider — OpenAI, Google Gemini, Z.AI, DeepSeek, Kimi — or add any OpenAI-compatible endpoint."
        default:
            return "Click the mascot in the menu bar any time to open Settings, browse Memory, or revisit this welcome. Have fun."
        }
    }

    /// Step-specific embedded content. Step 1 shows the hotkey grid;
    /// step 2 gets an Open-Settings button; the rest are bare prose.
    @ViewBuilder
    private var currentExtra: some View {
        switch step {
        case 1:
            hotkeyGrid
        case 2:
            Button {
                onOpenSettings()
            } label: {
                Label("Open Language Model settings", systemImage: "arrow.up.right.square")
            }
            .controlSize(.large)
        default:
            EmptyView()
        }
    }

    /// Mirrors the live `HUDView` rows so first-run users see exactly
    /// what the in-flight HUD will look like. Reads the current hotkey
    /// bindings so a customised Fn-leader still teaches accurately.
    private var hotkeyGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            commandRow(key: Keycode.label(for: Keycode.currentTranslate()),
                       label: "Translate to your native language")
            commandRow(key: Keycode.label(for: Keycode.currentExplain()),
                       label: "Explain — prose, in your native language")
            commandRow(key: Keycode.label(for: Keycode.currentPolish()),
                       label: "Polish — idiomatic rewrites of your draft")
            commandRow(key: Keycode.label(for: Keycode.currentChat()),
                       label: "Chat — open a free-form session with Glotty")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )
        )
    }

    private func commandRow(key: String, label: String) -> some View {
        HStack(spacing: 10) {
            Text("\(Keycode.currentLeader().label) + \(key)")
                .font(.system(.callout, design: .monospaced).bold())
                .frame(minWidth: 60, alignment: .leading)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            pageIndicator

            Spacer()

            if step > 0 {
                Button("Back") { step -= 1 }
                    .controlSize(.large)
            }
            Button(step == stepCount - 1 ? "Done" : "Next") {
                if step == stepCount - 1 {
                    onClose()
                } else {
                    step += 1
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<stepCount, id: \.self) { idx in
                Circle()
                    .fill(idx == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
