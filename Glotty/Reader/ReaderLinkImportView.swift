import SwiftUI

struct ReaderLinkImportView: View {
    let cancel: () -> Void
    let imported: (URL) throws -> Void
    @State private var link = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Link").font(.headline)
            Text("Paste a direct PDF or EPUB link.").foregroundStyle(.secondary)
            TextField("https://arxiv.org/pdf/2608.25512", text: $link)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .disabled(task != nil)
                .onSubmit { startImport() }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if task != nil {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { task?.cancel(); cancel() }.keyboardShortcut(.cancelAction)
                Button("Import") { startImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(task != nil || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 480)
        .onAppear { focused = true }
        .onDisappear { task?.cancel() }
    }

    private func startImport() {
        guard task == nil else { return }
        error = nil
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let download = try await ReaderLinkImport.download(link)
                defer { download.remove() }
                try Task.checkCancellation()
                try imported(download.url)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
