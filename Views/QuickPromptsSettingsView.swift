import SwiftUI

/// Settings tab for managing quick prompt shortcuts.
struct QuickPromptsSettingsView: View {
    @Binding var quickPrompts: QuickPrompts

    @State private var editingId: String?
    @State private var editName = ""
    @State private var editPrompt = ""
    @State private var newName = ""
    @State private var newPrompt = ""

    var body: some View {
        Form {
            Section("Add Prompt") {
                addPromptSection
            }

            Section("Quick Prompts") {
                Text("Quick prompts appear as one-tap chips in the overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if quickPrompts.prompts.isEmpty {
                    Text("No quick prompts defined.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    promptList
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var promptList: some View {
        ForEach(quickPrompts.prompts) { qp in
            if editingId == qp.id {
                editRow(qp)
            } else {
                displayRow(qp)
            }
        }
    }

    private func displayRow(_ qp: QuickPrompt) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(qp.name)
                    .fontWeight(.medium)
                Text(qp.prompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            Spacer()
            Button {
                beginEditing(qp)
            } label: {
                Image(systemName: "pencil")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            Button(role: .destructive) {
                quickPrompts.remove(id: qp.id)
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func editRow(_ qp: QuickPrompt) -> some View {
        VStack(spacing: 6) {
            TextField("Name", text: $editName)
                .textFieldStyle(.roundedBorder)
            TextField("Prompt", text: $editPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3 ... 8)
            HStack {
                Spacer()
                Button("Cancel") {
                    editingId = nil
                }
                .controlSize(.small)
                Button("Save") {
                    saveEdit(qp.id)
                }
                .controlSize(.small)
                .disabled(
                    editName.trimmingCharacters(in: .whitespaces).isEmpty
                        || editPrompt.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var addPromptSection: some View {
        VStack(spacing: 6) {
            TextField("Name (e.g. Make formal)", text: $newName)
                .textFieldStyle(.roundedBorder)
            TextField("Prompt text", text: $newPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3 ... 8)
            HStack {
                Spacer()
                Button("Add") {
                    addPrompt()
                }
                .controlSize(.small)
                .disabled(
                    newName.trimmingCharacters(in: .whitespaces).isEmpty
                        || newPrompt.trimmingCharacters(in: .whitespaces).isEmpty
                )
            }
        }
    }

    private func beginEditing(_ qp: QuickPrompt) {
        editingId = qp.id
        editName = qp.name
        editPrompt = qp.prompt
    }

    private func saveEdit(_ id: String) {
        let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = editPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { return }
        quickPrompts.update(id: id, name: name, prompt: prompt)
        editingId = nil
    }

    private func addPrompt() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = newPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !prompt.isEmpty else { return }
        quickPrompts.add(QuickPrompt(name: name, prompt: prompt))
        newName = ""
        newPrompt = ""
    }
}

// MARK: - Previews

#Preview("Quick Prompts Settings") {
    QuickPromptsSettingsView(quickPrompts: .constant(.defaults))
}

#Preview("Quick Prompts Settings - Empty") {
    QuickPromptsSettingsView(quickPrompts: .constant(QuickPrompts(prompts: [])))
}
