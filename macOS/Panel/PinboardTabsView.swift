// Owned by the Mac panel UI engineer.
//
// "Clipboard history" + one tab per pinboard (color dot), "+" to create.
// Context menu: rename / color / delete. Drag a tab onto another tab to reorder;
// drag a card onto a tab to add it to that pinboard.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClipCore

struct PanelPinboardTabs: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                PanelHistoryTab(isSelected: viewModel.scope == .history) {
                    viewModel.setScope(.history)
                }
                ForEach(viewModel.pinboardRows) { row in
                    PanelPinboardTab(
                        row: row,
                        isSelected: viewModel.currentPinboardID == row.id,
                        viewModel: viewModel
                    )
                }
                PanelAddPinboardButton {
                    viewModel.beginCreatePinboard()
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinboards")
    }
}

/// Visual of a tab: optional color dot + title in a capsule.
struct PanelTabCapsule: View {
    let title: String
    let dotColor: Color?
    let isSelected: Bool
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let dotColor = dotColor {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
            } else {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(background)
        .overlay(border)
        .contentShape(Capsule())
    }

    private var background: some View {
        Capsule().fill(isSelected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.04))
    }

    private var border: some View {
        Capsule().strokeBorder(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2)
    }
}

struct PanelHistoryTab: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let traits: AccessibilityTraits = isSelected ? [.isButton, .isSelected] : [.isButton]
        PanelTabCapsule(title: "Clipboard history", dotColor: nil, isSelected: isSelected, isDropTarget: false)
            .onTapGesture(perform: action)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Clipboard history")
            .accessibilityAddTraits(traits)
            .accessibilityAction { action() }
    }
}

struct PanelPinboardTab: View {
    let row: PanelPinboardRow
    let isSelected: Bool
    let viewModel: PanelViewModel
    @State private var isDropTarget = false

    var body: some View {
        let traits: AccessibilityTraits = isSelected ? [.isButton, .isSelected] : [.isButton]
        PanelTabCapsule(
            title: row.name,
            dotColor: PanelPalette.color(hex: row.colorHex),
            isSelected: isSelected,
            isDropTarget: isDropTarget
        )
        .onTapGesture { viewModel.setScope(.pinboard(row.id)) }
        .contextMenu { PanelPinboardMenu(row: row, viewModel: viewModel) }
        .onDrag { viewModel.beginPinboardDrag(row.id) }
        .onDrop(of: [UTType.item], isTargeted: $isDropTarget) { _ in
            viewModel.handleDrop(onPinboard: row.id)
        }
        .help("Pinboard “\(row.name)” — drop cards here")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pinboard \(row.name)")
        .accessibilityAddTraits(traits)
        .accessibilityAction { viewModel.setScope(.pinboard(row.id)) }
        .accessibilityAction(named: Text("Rename")) { viewModel.beginRenamePinboard(row.id) }
        .accessibilityAction(named: Text("Delete")) { viewModel.deletePinboard(row.id) }
    }
}

struct PanelPinboardMenu: View {
    let row: PanelPinboardRow
    let viewModel: PanelViewModel

    var body: some View {
        Button("Rename…") { viewModel.beginRenamePinboard(row.id) }
        Menu("Color") {
            ForEach(PanelPalette.pinboardColors) { named in
                Button(colorTitle(named)) {
                    viewModel.setColor(named.hex, forPinboard: row.id)
                }
            }
        }
        Divider()
        Button("Delete Pinboard", role: .destructive) { viewModel.deletePinboard(row.id) }
    }

    private func colorTitle(_ named: PanelNamedColor) -> String {
        let isCurrent = named.hex.uppercased() == row.colorHex.uppercased()
        return isCurrent ? "✓ \(named.name)" : named.name
    }
}

struct PanelAddPinboardButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("New pinboard")
        .accessibilityLabel("New pinboard")
    }
}
