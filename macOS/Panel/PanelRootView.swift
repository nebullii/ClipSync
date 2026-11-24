// Owned by the Mac panel UI engineer.
//
// SwiftUI content of the panel: top bar (search / inline editor, pinboard tabs, kind
// chips, settings) above the horizontal card strip. Views are kept small so the type
// checker never has to solve one giant body.

import SwiftUI
import AppKit
import ClipCore

struct PanelRootView: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelTopBar(viewModel: viewModel)
            PanelCardStrip(viewModel: viewModel)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Top bar

struct PanelTopBar: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        HStack(spacing: 12) {
            PanelSearchSlot(viewModel: viewModel)
                .frame(width: 240)
            if let editor = viewModel.inlineEditor {
                PanelInlineEditorActions(editor: editor, viewModel: viewModel)
                Spacer(minLength: 8)
            } else {
                PanelPinboardTabs(viewModel: viewModel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PanelKindChips(viewModel: viewModel)
            PanelSettingsButton(viewModel: viewModel)
        }
        .frame(height: PanelMetrics.topBarHeight)
    }
}

/// The search field always stays in the hierarchy (so the controller's weak reference
/// stays valid); the inline editor field is layered on top while active.
struct PanelSearchSlot: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        let editing = viewModel.inlineEditor != nil
        ZStack {
            PanelSearchField(text: $viewModel.searchText, bridge: viewModel.focusBridge)
                .opacity(editing ? 0 : 1)
                .allowsHitTesting(!editing)
                .accessibilityHidden(editing)
            if let editor = viewModel.inlineEditor {
                PanelEditorField(text: $viewModel.editorText, placeholder: editor.placeholder, bridge: viewModel.focusBridge)
            }
        }
    }
}

struct PanelInlineEditorActions: View {
    let editor: PanelInlineEditor
    let viewModel: PanelViewModel

    var body: some View {
        HStack(spacing: 8) {
            Label(editor.prompt, systemImage: editor.systemImageName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Button("Save") { viewModel.commitEditor() }
                .controlSize(.small)
            Button("Cancel") { viewModel.cancelEditor() }
                .controlSize(.small)
            Text("↩ to save, esc to cancel")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

struct PanelKindChips: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PanelKindFilter.allCases) { filter in
                PanelKindChip(
                    filter: filter,
                    isSelected: viewModel.kindFilter == filter,
                    action: { viewModel.setKindFilter(filter) }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter by kind")
    }
}

struct PanelKindChip: View {
    let filter: PanelKindFilter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: filter.systemImageName)
                    .font(.system(size: 10, weight: .semibold))
                Text(filter.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(chipBackground)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show \(filter.title.lowercased())")
        .accessibilityLabel("\(filter.title) filter")
        .accessibilityAddTraits(selectedTraits)
    }

    private var selectedTraits: AccessibilityTraits {
        return isSelected ? [.isSelected] : []
    }

    private var chipBackground: some View {
        Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
    }
}

struct PanelSettingsButton: View {
    let viewModel: PanelViewModel

    var body: some View {
        Button(action: { viewModel.openSettings() }) {
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("ClipSync Settings")
        .accessibilityLabel("Settings")
    }
}

// MARK: - Strip

struct PanelCardStrip: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        Group {
            if viewModel.rows.isEmpty {
                PanelEmptyStateView(state: viewModel.emptyState)
            } else {
                PanelCardScroller(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PanelCardScroller: View {
    @ObservedObject var viewModel: PanelViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: PanelMetrics.cardSpacing) {
                    ForEach(viewModel.rows) { row in
                        cell(for: row)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .onChange(of: viewModel.scrollRequest) { _, _ in
                scrollToSelection(proxy)
            }
        }
    }

    private func cell(for row: PanelCardRow) -> some View {
        PanelCardCell(
            row: row,
            isSelected: row.index == viewModel.selectedIndex,
            referenceDate: viewModel.referenceDate,
            pinboards: viewModel.pinboardRows,
            currentPinboardID: viewModel.currentPinboardID,
            viewModel: viewModel
        )
        .id(row.id)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        guard let id = viewModel.selectedID else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(id, anchor: nil)
        }
    }
}

// MARK: - Empty states

struct PanelEmptyStateView: View {
    let state: PanelEmptyState

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch state {
        case .noHistory: return "doc.on.clipboard"
        case .noResults: return "magnifyingglass"
        case .noItemsOfKind: return "line.3.horizontal.decrease.circle"
        case .emptyPinboard: return "pin"
        }
    }

    private var title: String {
        switch state {
        case .noHistory: return "Nothing copied yet"
        case .noResults(let query): return "No matches for “\(query)”"
        case .noItemsOfKind(let kind): return "No \(kind.lowercased()) here"
        case .emptyPinboard(let name): return "“\(name)” is empty"
        }
    }

    private var message: String {
        switch state {
        case .noHistory:
            return "Copy text, links, images or files in any app and they will show up here."
        case .noResults:
            return "Try fewer or different words. Search looks at text, titles, image text and app names."
        case .noItemsOfKind:
            return "Choose “All” to see everything."
        case .emptyPinboard:
            return "Drag a card onto this pinboard's tab, or right-click a card and choose Add to Pinboard."
        }
    }
}
