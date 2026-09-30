import SwiftUI

@MainActor
@Observable
final class ClipboardEditorState {
    var text: String
    let renaming: Bool

    var isValid: Bool { renaming ? text.utf8.count <= 1024 : text.count <= 32_000 }

    init(text: String, renaming: Bool) {
        self.text = text
        self.renaming = renaming
    }
}

struct ClipboardEditorFields: View {
    @Bindable var state: ClipboardEditorState
    @Environment(\.metrics) private var metrics
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            if state.renaming {
                TextField("Name", text: $state.text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .accessibilityLabel("Clipboard entry name")
            } else {
                TextEditor(text: $state.text)
                    .font(metrics.typography.rowTitle)
                    .frame(height: metrics.size.dialogWidth / 2)
                    .focused($focused)
                    .accessibilityLabel("Clipboard content")
            }
            if !state.isValid {
                Text(
                    state.renaming ? "Use a name under 1,024 UTF-8 bytes." : "Use at most 32,000 characters."
                )
                .foregroundStyle(Theme.Colors.destructive)
                .font(metrics.typography.rowTitle)
            }
        }
        .onAppear { focused = true }
    }
}
