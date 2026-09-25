import AppKit

/// `ReaderServices` for the standalone Reader app. Relays to a running Glotty
/// over distributed notifications and handles the replies:
///   • look-up / translate → Glotty shows its popup; when it finishes it echoes
///     the result back (`resultName`), which we record into `BookLibrary` and
///     underline in our own reader window.
///   • chat → we post the prompt (`chatRequestName`) and stream the reply from
///     the `chatChunk` / `chatDone` notifications Glotty posts back.
@MainActor
final class IPCReaderServices: NSObject, ReaderServices {
    private var chatConts: [String: AsyncThrowingStream<String, Error>.Continuation] = [:]
    private var chatAccum: [String: String] = [:]

    override init() {
        super.init()
        let nc = DistributedNotificationCenter.default()
        nc.addObserver(self, selector: #selector(onResult(_:)), name: ReaderIPC.resultName, object: nil)
        nc.addObserver(self, selector: #selector(onChatChunk(_:)), name: ReaderIPC.chatChunkName, object: nil)
        nc.addObserver(self, selector: #selector(onChatDone(_:)), name: ReaderIPC.chatDoneName, object: nil)
        nc.addObserver(self, selector: #selector(onProviders(_:)), name: ReaderIPC.providersReplyName, object: nil)
    }

    // MARK: look-up / translate

    func lookUp(_ text: String) { send(action: "explain", text: text) }
    func translate(_ text: String) { send(action: "translate", text: text) }

    private func send(action: String, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var info: [String: String] = ["action": action, "text": text]
        // Carry the book context so Glotty can echo the result back for capture.
        if let cap = ReaderMark.capture, cap.term == text {
            info.merge(cap.userInfo) { a, _ in a }
        }
        ReaderMark.capture = nil
        post(ReaderIPC.requestName, info)
    }

    @objc private func onResult(_ note: Notification) {
        // Glotty already wrote the answer to the shared library; just underline.
        guard let info = note.userInfo, let cap = ReaderMark.Capture(userInfo: info) else { return }
        ReaderWindowController.shared.state.markLookedUp(cap.term)
    }

    // MARK: chat

    func chatStream(prompt: String) -> AsyncThrowingStream<String, Error>? {
        let reqID = UUID().uuidString
        return AsyncThrowingStream { continuation in
            chatConts[reqID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.chatConts[reqID] = nil }
            }
            // The prompt carries page context (tens of KB) — too big for a
            // distributed notification, which drops oversized userInfo. Hand it
            // over via a shared file; the notification carries only the id.
            ReaderIPCFile.writePrompt(prompt, id: reqID)
            post(ReaderIPC.chatRequestName, ["requestID": reqID])
        }
    }

    @objc private func onChatChunk(_ note: Notification) {
        guard let id = note.userInfo?["requestID"] as? String,
              let delta = note.userInfo?["delta"] as? String else { return }
        if (note.userInfo?["reset"] as? String) == "1" { chatAccum[id] = delta }
        else { chatAccum[id, default: ""] += delta }
        chatConts[id]?.yield(chatAccum[id] ?? delta)
    }

    @objc private func onChatDone(_ note: Notification) {
        guard let id = note.userInfo?["requestID"] as? String else { return }
        if let err = note.userInfo?["error"] as? String {
            chatConts[id]?.finish(throwing: NSError(domain: "GlottyReader", code: 2,
                                                    userInfo: [NSLocalizedDescriptionKey: err]))
        } else {
            chatConts[id]?.finish()
        }
        chatConts[id] = nil
        chatAccum[id] = nil
    }

    // MARK: providers / model picker

    private var providerWaiters: [UUID: CheckedContinuation<[ReaderProvider], Never>] = [:]

    func providers() async -> [ReaderProvider] {
        await withCheckedContinuation { cont in
            let id = UUID()
            providerWaiters[id] = cont
            // Don't bail when Glotty is down — `post` starts it and retries, so
            // opening the picker brings the model list with it. Bailing early
            // is what made a quit Glotty look like "no providers configured".
            post(ReaderIPC.providersRequestName, [:])
            // A newly launched Glotty may not have registered its distributed
            // observer at the first post. Retry only while this pull is pending.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard self?.providerWaiters[id] != nil else { return }
                self?.post(ReaderIPC.providersRequestName, [:])
            }
            // Time out only this pull. An older timeout must never empty a newer
            // click's waiter, which caused the first menu open to return `[]`.
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let continuation = self?.providerWaiters.removeValue(forKey: id) else { return }
                continuation.resume(returning: [])
            }
        }
    }

    @objc private func onProviders(_ note: Notification) {
        let json = (note.userInfo?["providers"] as? String) ?? "[]"
        let list = (try? JSONDecoder().decode([ReaderProvider].self, from: Data(json.utf8))) ?? []
        resumeProviderWaiters(with: list)
    }

    private func resumeProviderWaiters(with list: [ReaderProvider]) {
        let waiting = Array(providerWaiters.values)
        providerWaiters.removeAll()
        for c in waiting { c.resume(returning: list) }
    }

    func selectModel(providerID: String, modelID: String) {
        post(ReaderIPC.selectModelName, ["provider": providerID, "model": modelID])
    }

    // MARK: transport

    /// Post to Glotty, launching it first if it isn't running (distributed
    /// notifications aren't queued, so we wait for it to register).
    private func post(_ name: Notification.Name, _ info: [String: String]) {
        let fire = {
            DistributedNotificationCenter.default().postNotificationName(
                name, object: nil, userInfo: info, deliverImmediately: true)
        }
        if isGlottyRunning {
            fire()
        } else if launchGlotty() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { fire() }
        } else {
            NSApp.presentError(NSError(domain: "GlottyReader", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    NSLocalizedString("Open the Glotty app to use look-up, translate, and chat.", comment: "")]))
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
