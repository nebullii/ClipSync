import SwiftUI
import ClipCore

/// Create or edit a pinboard: name + color (palette or custom). Presented once from the root.
struct PinboardEditorView: View {
    let mode: PinboardEditorMode

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var confirmingDelete = false
    @FocusState private var nameFocused: Bool

    init(mode: PinboardEditorMode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _colorHex = State(initialValue: ClipConstants.defaultPinboardColorHex)
        case .edit(let board):
            _name = State(initialValue: board.name)
            _colorHex = State(initialValue: board.colorHex)
        }
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var screenTitle: String {
        return isCreating ? "New Pinboard" : "Edit Pinboard"
    }

    private var saveTitle: String {
        return isCreating ? "Create" : "Save"
    }

    private var trimmedName: String {
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Pinboard name", text: $name)
                        .focused($nameFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("pinboardEditor.name")
                }
                Section("Color") {
                    PinboardColorPalette(selection: $colorHex)
                    ColorPicker("Custom color", selection: customColor, supportsOpacity: false)
                }
                if case .edit(let board) = mode {
                    Section {
                        Button("Delete Pinboard", role: .destructive) {
                            confirmingDelete = true
                        }
                    } footer: {
                        Text("\(board.itemCount) clips stay in your history.")
                    }
                }
            }
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle, action: save)
                        .disabled(trimmedName.isEmpty)
                        .accessibilityIdentifier("pinboardEditor.save")
                }
            }
            .confirmationDialog("Delete this pinboard?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: deleteBoard)
            } message: {
                Text("Its clips stay in your history.")
            }
            .onAppear {
                if isCreating {
                    nameFocused = true
                }
            }
        }
    }

    private var customColor: Binding<Color> {
        return Binding(
            get: { Color(clipHex: colorHex) },
            set: { newColor in
                if let hex = ColorMath.hexString(from: newColor) {
                    colorHex = hex
                }
            }
        )
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        switch mode {
        case .create(let item):
            model.createPinboard(name: trimmedName, colorHex: colorHex, adding: item)
        case .edit(let board):
            model.updatePinboard(board, name: trimmedName, colorHex: colorHex)
        }
        dismiss()
    }

    private func deleteBoard() {
        if case .edit(let board) = mode {
            model.deletePinboard(board)
        }
        dismiss()
    }
}

/// Swatches from `ClipConstants.pinboardPalette`.
private struct PinboardColorPalette: View {
    @Binding var selection: String

    private let columns = [GridItem(.adaptive(minimum: 44), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(ClipConstants.pinboardPalette, id: \.self) { hex in
                PaletteSwatch(hex: hex, isSelected: hex.uppercased() == selection.uppercased()) {
                    selection = hex
                }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct PaletteSwatch: View {
    let hex: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(clipHex: hex))
                .frame(width: 36, height: 36)
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(isSelected ? 0.9 : 0), lineWidth: 3)
                        .padding(-5)
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .opacity(isSelected ? 1 : 0)
                )
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PaletteSwatch.colorName(hex))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private static func colorName(_ hex: String) -> String {
        switch hex.uppercased() {
        case "#3B82F6": return "Blue"
        case "#22C55E": return "Green"
        case "#EAB308": return "Yellow"
        case "#F97316": return "Orange"
        case "#EF4444": return "Red"
        case "#A855F7": return "Purple"
        case "#EC4899": return "Pink"
        case "#6B7280": return "Gray"
        default: return "Color \(hex)"
        }
    }
}
