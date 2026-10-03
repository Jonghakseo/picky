import SwiftUI

/// A mutually exclusive dispatch choice that keeps the mode's distinct outcomes
/// readable without relying on a dense segmented control. Persistence stays in
/// the parent that owns the settings binding.
struct PickyDispatchModeChoiceView: View {
    private static let horizontalChoiceMinimumWidth = DS.Spacing.space8 * 5

    @Binding var selection: PickyArmedPickleDispatchMode
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        Group {
            if fontScale >= 1.3 {
                stackedChoices
            } else {
                ViewThatFits(in: .horizontal) {
                    horizontalChoices
                    stackedChoices
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var horizontalChoices: some View {
        HStack(spacing: DS.Spacing.space2) {
            choice(for: .followUp)
            choice(for: .steer)
        }
    }

    private var stackedChoices: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            choice(for: .followUp)
            choice(for: .steer)
        }
    }

    private func choice(for mode: PickyArmedPickleDispatchMode) -> some View {
        let isSelected = selection == mode
        return Button {
            selection = mode
        } label: {
            HStack(alignment: .top, spacing: DS.Spacing.space2) {
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    Text(mode.displayName)
                        .font(PickyHUDTypography.title)
                    Text(detailKey(for: mode))
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineSpacing(DS.Spacing.space1)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DS.Spacing.space2)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(PickyHUDTypography.supportingMedium)
                    .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textSecondary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.space3)
            .contentShape(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous))
        }
        .buttonStyle(PickyDispatchModeChoiceButtonStyle(isSelected: isSelected))
        .frame(minWidth: Self.horizontalChoiceMinimumWidth, maxWidth: .infinity)
        .accessibilityIdentifier(accessibilityIdentifier(for: mode))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func detailKey(for mode: PickyArmedPickleDispatchMode) -> LocalizedStringKey {
        switch mode {
        case .followUp: "settings.dispatch.followUp.detail"
        case .steer: "settings.dispatch.steer.detail"
        }
    }

    private func accessibilityIdentifier(for mode: PickyArmedPickleDispatchMode) -> String {
        switch mode {
        case .followUp: "settings.dispatch.followUp"
        case .steer: "settings.dispatch.steer"
        }
    }
}

private struct PickyDispatchModeChoiceButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isEnabled ? DS.Colors.textPrimary : DS.Colors.disabledText)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .stroke(borderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = isEnabled && $0 }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if !isEnabled { return DS.Colors.disabledBackground }
        if isPressed { return DS.Colors.surface4 }
        if isHovered { return DS.Colors.surface3 }
        if isSelected { return DS.Colors.accentSubtle }
        return DS.Colors.surface2
    }

    private func borderColor(isPressed: Bool) -> Color {
        if !isEnabled { return DS.Colors.borderSubtle }
        if isSelected { return DS.Colors.accentText }
        if isPressed || isHovered { return DS.Colors.borderStrong }
        return DS.Colors.borderSubtle
    }
}
