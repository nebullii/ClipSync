import SwiftUI
import ClipCore

/// Horizontal kind filter chips: All, Text, Links, Images, Files, Colors.
struct KindFilterBar: View {
    @Binding var selection: KindFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(KindFilter.allCases) { filter in
                    KindFilterChip(filter: filter, isSelected: filter == selection) {
                        selection = filter
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filter by kind")
        .accessibilityIdentifier("history.kindFilter")
    }
}

private struct KindFilterChip: View {
    let filter: KindFilter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(filter.title, systemImage: filter.systemImage)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
                .background(
                    Capsule().fill(isSelected ? Theme.accent : Color(uiColor: .tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(filter.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        .accessibilityIdentifier("filter.\(filter.rawValue)")
    }
}
