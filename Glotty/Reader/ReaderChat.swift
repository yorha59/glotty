import SwiftUI

/// A lightweight tutor chat for the reader's side panel. The user adds a
/// selected passage as context ("Ask"), then asks follow-up questions; replies
/// stream from the configured LLM provider. Session-only (not persisted).
@MainActor
final class ReaderChat: ObservableObject {
    struct Msg: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
    }

    @Published var messages: [Msg] = []
    @Published var context: String?          // the attached passage
    @Published var input: String = ""
    @Published var isStreaming = false

    private var task: Task<Void, Never>?

    /// Attach a selection as the passage the conversation is about.
    func attach(_ text: String) {
        context = ReaderState.cleanSelection(text)
    }
    func clearContext() { context = nil }

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isStreaming else { return }
        input = ""
        messages.append(Msg(role: .user, text: q))

        guard let provider = LLMRegistry.current() else {
            messages.append(Msg(role: .assistant,
                text: String(localized: "No language model is configured. Choose one in Settings → Language Model.")))
            return
        }

        let prompt = buildPrompt()
        messages.append(Msg(role: .assistant, text: ""))
        let idx = messages.count - 1
        isStreaming = true
        task = Task { [weak self] in
            do {
                for try await snapshot in provider.chatCompletionStream(prompt: prompt) {
                    guard let self else { return }
                    if self.messages.indices.contains(idx) { self.messages[idx].text = snapshot }
                }
            } catch is CancellationError {
                // stopped by the user
            } catch {
                if let self, self.messages.indices.contains(idx), self.messages[idx].text.isEmpty {
                    self.messages[idx].text = String(localized: "Couldn't get a reply: ") + error.localizedDescription
                }
            }
            self?.isStreaming = false
        }
    }

    func stop() { task?.cancel(); isStreaming = false }

    func reset() {
        stop()
        messages.removeAll()
        context = nil
    }

    private func buildPrompt() -> String {
        let langCode = UserDefaults.standard.string(forKey: "glotty.targetLang").flatMap { $0.isEmpty ? nil : $0 }
            ?? Locale.current.language.languageCode?.identifier ?? "en"
        let lang = Locale.current.localizedString(forLanguageCode: langCode) ?? "the reader's language"

        var p = "You are a patient reading tutor helping someone understand a document. "
        p += "Answer clearly and concisely in \(lang). Use the selected passage as the main context.\n\n"
        if let ctx = context, !ctx.isEmpty {
            p += "Selected passage:\n\"\"\"\n\(ctx)\n\"\"\"\n\n"
        }
        for m in messages {   // ends with the user's latest question
            p += (m.role == .user ? "User: " : "Assistant: ") + m.text + "\n"
        }
        p += "Assistant:"
        return p
    }
}
