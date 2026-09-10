import SwiftUI

/// One keyboard-focusable button for the entire disclosure row, not just its
/// chevron. Expanded content takes the available width and reads from the left.
struct PickySettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: DS.Spacing.space2) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(PickyHUDTypography.supportingMedium)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: DS.Spacing.space2)
                }
                .frame(maxWidth: .infinity, minHeight: DS.Spacing.space8, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverAffordance()
            .accessibilityValue(Text(configuration.isExpanded
                ? "settings.disclosure.expanded" : "settings.disclosure.collapsed"))

            if configuration.isExpanded {
                configuration.content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
