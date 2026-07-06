import SwiftUI

/// Settings → Profile → "Glotty's persona" section. Lets the user
/// customize who Glotty is in chat: name, manner, speaking style,
/// and a freeform character note. All four fields land in the
/// system prompt the chat tutor uses (see `TutorPrompt.build`).
struct GlottyPersonaSection: View {
    @AppStorage(GlottyPersona.DefaultsKey.name)      private var name:      String = GlottyPersona.default.name
    @AppStorage(GlottyPersona.DefaultsKey.manner)    private var mannerRaw: String = GlottyPersona.default.manner.rawValue
    @AppStorage(GlottyPersona.DefaultsKey.style)     private var styleRaw:  String = GlottyPersona.default.style.rawValue
    @AppStorage(GlottyPersona.DefaultsKey.character) private var character: String = GlottyPersona.default.character
    /// Same "fade to read-only label after entry" pattern that the
    /// Profile → Display name field uses. `nameEditing` flips false
    /// on Submit / focus-out; the TextField is replaced by a
    /// labelled value with a pencil hint. Tapping the label flips
    /// editing back on and re-focuses the field.
    @State private var nameEditing = false
    @FocusState private var nameFocused: Bool

    private var mannerBinding: Binding<GlottyPersona.Manner> {
        Binding(
            get: { GlottyPersona.Manner(rawValue: mannerRaw) ?? GlottyPersona.default.manner },
            set: { mannerRaw = $0.rawValue }
        )
    }

    private var styleBinding: Binding<GlottyPersona.Style> {
        Binding(
            get: { GlottyPersona.Style(rawValue: styleRaw) ?? GlottyPersona.default.style },
            set: { styleRaw = $0.rawValue }
        )
    }

    var body: some View {
        Section {
            Group {
                if name.isEmpty || nameEditing {
                    TextField("Name", text: $name, prompt: Text("Glotty"))
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit { nameEditing = false }
                        .onChange(of: nameFocused) { _, focused in
                            if !focused { nameEditing = false }
                        }
                        .transition(.opacity)
                } else {
                    LabeledContent("Name") {
                        HStack(spacing: 6) {
                            Text(name)
                                .foregroundStyle(.secondary)
                            Image(systemName: "pencil")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        nameEditing = true
                        // @FocusState updates need to land after the
                        // TextField has been added back to the tree.
                        DispatchQueue.main.async { nameFocused = true }
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: nameEditing)
            .animation(.easeInOut(duration: 0.2), value: name.isEmpty)
            Picker("Manner", selection: mannerBinding) {
                ForEach(GlottyPersona.Manner.allCases) { m in
                    Text(m.displayName.t).tag(m)
                }
            }
            Picker("Speaking style", selection: styleBinding) {
                ForEach(GlottyPersona.Style.allCases) { s in
                    Text(s.displayName.t).tag(s)
                }
            }
            ZStack(alignment: .topLeading) {
                if character.isEmpty {
                    Text("e.g. \u{201C}Loves indie games and dry humor. Bilingual in French.\u{201D}".t)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $character)
                    .frame(minHeight: 80)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
            }
        } header: {
            Text("Glotty's persona".t)
        } footer: {
            Text("How Glotty acts in chat. Reset by clearing the fields. Affects the conversational chat (Fn → C) and proactive reminder notifications.".t)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
