import AppKit

/// Glotty side of the standalone-Reader IPC. When a look-up/translate arrives
/// from the Reader app it carries the book context, stashed here; the popup's
/// capture echoes the finished result back. Also runs a chat server that streams
/// LLM replies back to the Reader's chat panel.
@MainActor
enum ReaderIPCBridge {
    /// Context of the most recent look-up that came from the standalone Reader
    /// (nil for the in-process menu-bar reader, which captures locally).
    static var pendingCapture: ReaderMark.Capture?

    /// The result was written to the shared `BookLibrary` by the popup; tell the
    /// Reader to underline the term (small payload — the answer stays in the
    /// shared store, avoiding oversized distributed-notification userInfo).
    static func notifyRecorded(_ cap: ReaderMark.Capture) {
        post(ReaderIPC.resultName, cap.userInfo)
    }

    /// Start serving chat requests from the Reader (LLM stream → notifications).
    static func startChatServer() {
        DistributedNotificationCenter.default().addObserver(
            forName: ReaderIPC.chatRequestName, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                // The prompt travels via a shared file (too big for userInfo);
                // the notification carries only the id.
                guard let id = note.userInfo?["requestID"] as? String,
                      let prompt = ReaderIPCFile.readPrompt(id: id) else { return }
                serveChat(id: id, prompt: prompt)
            }
        }
    }

    /// Serve the reader's provider/model picker. The list is JSON-encoded into
    /// a single userInfo string: distributed-notification payloads drop
    /// oversized or non-plist values, and a nested provider→models structure is
    /// exactly the shape that gets silently lost.
    static func startProviderServer() {
        let nc = DistributedNotificationCenter.default()
        nc.addObserver(forName: ReaderIPC.providersRequestName, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let list = GlottyReaderServices.configuredProviders(scope: .reader)
                let json = (try? JSONEncoder().encode(list)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                post(ReaderIPC.providersReplyName, ["providers": json])
            }
        }
        nc.addObserver(forName: ReaderIPC.selectModelName, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let provider = note.userInfo?["provider"] as? String else { return }
                GlottyReaderServices.applySelection(
                    providerID: provider, modelID: (note.userInfo?["model"] as? String) ?? "",
                    scope: .reader)
            }
        }
    }

    private static func serveChat(id: String, prompt: String) {
        guard let provider = ReaderModelSelection.provider() else {
            post(ReaderIPC.chatDoneName, ["requestID": id,
                 "error": String(localized: "No language model is configured in Glotty.")])
            return
        }
        Task { @MainActor in
            do {
                // Stream deltas, not the growing cumulative snapshot, so each
                // notification stays small.
                var sent = ""
                for try await snapshot in provider.chatCompletionStream(prompt: prompt) {
                    let delta = snapshot.hasPrefix(sent) ? String(snapshot.dropFirst(sent.count)) : snapshot
                    if snapshot.hasPrefix(sent) {
                        if !delta.isEmpty { post(ReaderIPC.chatChunkName, ["requestID": id, "delta": delta]) }
                    } else {
                        post(ReaderIPC.chatChunkName, ["requestID": id, "delta": snapshot, "reset": "1"])
                    }
                    sent = snapshot
                }
                post(ReaderIPC.chatDoneName, ["requestID": id])
            } catch {
                post(ReaderIPC.chatDoneName, ["requestID": id, "error": error.localizedDescription])
            }
        }
    }

    private static func post(_ name: Notification.Name, _ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: info, deliverImmediately: true)
    }
}
