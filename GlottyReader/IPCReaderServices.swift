import AppKit

/// `ReaderServices` for the standalone Reader app: relays look-up / translate
/// requests to a running Glotty over a distributed notification. Glotty then
/// shows its explain / translate popup (a floating window over the reader).
///
/// Distributed notifications aren't queued, so Glotty must be running to
/// receive them — if it isn't, we launch it and retry once after it registers.
/// Chat streaming needs a return channel and lands in a later phase (XPC).
@MainActor
final class IPCReaderServices: ReaderServices {
    func lookUp(_ text: String) { send(action: "explain", text: text) }
    func translate(_ text: String) { send(action: "translate", text: text) }

    // Streaming chat over IPC is a later phase; nil → the panel shows the
    // "no model configured" line for now.
    func chatStream(prompt: String) -> AsyncThrowingStream<String, Error>? { nil }

    private func send(action: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let post = {
            DistributedNotificationCenter.default().postNotificationName(
                ReaderIPC.requestName, object: nil,
                userInfo: ["action": action, "text": text],
                deliverImmediately: true)
        }
        if isGlottyRunning {
            post()
        } else if launchGlotty() {
            // Give Glotty a moment to register its observer, then post once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { post() }
        } else {
            NSApp.presentError(NSError(
                domain: "GlottyReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    NSLocalizedString("Open the Glotty app to use look-up and translate.", comment: "")]))
        }
    }

    private var isGlottyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ReaderIPC.glottyBundleID).isEmpty
    }

    @discardableResult
    private func launchGlotty() -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ReaderIPC.glottyBundleID)
        else { return false }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        return true
    }
}
