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
                guard let id = note.userInfo?["requestID"] as? String,
                      let prompt = note.userInfo?["prompt"] as? String else { return }
                serveChat(id: id, prompt: prompt)
            }
        }
    }

    private static func serveChat(id: String, prompt: String) {
        guard let provider = LLMRegistry.current() else {
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
