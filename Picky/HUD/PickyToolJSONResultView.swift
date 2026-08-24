//
//  PickyToolJSONResultView.swift
//  Picky
//
//  Read-only, selectable JSON tree used by the Tool History result section.
//

import SwiftUI

struct PickyToolJSONResultView: View {
    let root: PickyJSONNode

    var body: some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            PickyToolJSONNodeView(node: root, label: nil, depth: 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.sm)
        }
        .defaultScrollAnchor(.topLeading)
        .frame(maxHeight: 260)
        .background(DS.Colors.surface3.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small))
    }
}

private enum PickyToolJSONNodeLabel: Equatable {
    case objectKey(String)
    case arrayIndex(Int)

    var displayText: String {
        switch self {
        case .objectKey(let key): "\(key):"
        case .arrayIndex(let index): "[\(index)]"
        }
    }

    var accessibilityName: String {
        switch self {
        case .objectKey(let key): key
        case .arrayIndex(let index): "[\(index)]"
        }
    }
}

private struct PickyToolJSONNodeView: View {
    let node: PickyJSONNode
    let label: PickyToolJSONNodeLabel?
    let depth: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded: Bool

    init(node: PickyJSONNode, label: PickyToolJSONNodeLabel?, depth: Int) {
        self.node = node
        self.label = label
        self.depth = depth
        _isExpanded = State(initialValue: depth < 2)
    }

    var body: some View {
        switch node.value {
        case .object(let members):
            collection(
                opening: "{",
                closing: "}",
                count: members.count,
                children: members.map { (.objectKey($0.key), $0.node) }
            )
        case .array(let items):
            collection(
                opening: "[",
                closing: "]",
                count: items.count,
                children: items.enumerated().map { (.arrayIndex($0.offset), $0.element) }
            )
        case .string, .number, .boolean, .null:
            scalarRow
        }
    }

    @ViewBuilder
    private func collection(
        opening: String,
        closing: String,
        count: Int,
        children: [(PickyToolJSONNodeLabel, PickyJSONNode)]
    ) -> some View {
        if count == 0 {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                labelText
                Text("\(opening)\(closing)")
                    .foregroundStyle(DS.Colors.textSecondary)
                    .textSelection(.enabled)
            }
            .font(PickyHUDTypography.supportingMonospaced)
            .padding(.leading, indentation + (label == nil ? 0 : DS.Spacing.md))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Button { isExpanded.toggle() } label: {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .pickyFont(size: 8, weight: .semibold)
                            .frame(width: DS.Spacing.sm)
                        labelText
                        Text(opening)
                            .foregroundStyle(DS.Colors.textSecondary)
                        Text(L10n.t("hud.toolHistory.json.itemCount", Int64(count)))
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                    .font(PickyHUDTypography.supportingMonospaced)
                    .padding(.vertical, 2)
                    .padding(.trailing, DS.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PickyToolJSONDisclosureButtonStyle())
                .padding(.leading, indentation)
                .accessibilityLabel(accessibilityLabel(count: count))
                .accessibilityValue(isExpanded
                    ? L10n.t("hud.toolHistory.json.expanded")
                    : L10n.t("hud.toolHistory.json.collapsed"))

                if isExpanded {
                    ForEach(Array(children.enumerated()), id: \.element.1.id) { _, child in
                        PickyToolJSONNodeView(node: child.1, label: child.0, depth: depth + 1)
                    }
                    Text(closing)
                        .font(PickyHUDTypography.supportingMonospaced)
                        .foregroundStyle(DS.Colors.textSecondary)
                        .textSelection(.enabled)
                        .padding(.leading, indentation + DS.Spacing.md)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.normal), value: isExpanded)
        }
    }

    private var scalarRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            labelText
            if let value = node.scalarDisplayText {
                Text(value)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        .font(PickyHUDTypography.supportingMonospaced)
        .padding(.leading, indentation + DS.Spacing.md)
    }

    @ViewBuilder
    private var labelText: some View {
        if let label {
            Text(label.displayText)
                .foregroundStyle(DS.Colors.textPrimary)
                .textSelection(.enabled)
        }
    }

    private var indentation: CGFloat {
        CGFloat(depth) * DS.Spacing.md
    }

    private func accessibilityLabel(count: Int) -> String {
        let name = label?.accessibilityName ?? node.collectionName ?? "JSON"
        return L10n.t("hud.toolHistory.json.collection.accessibilityLabel", name, Int64(count))
    }
}

private struct PickyToolJSONDisclosureButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                PickyHUDInteractionStateLayer.fill(
                    isHovered: isHovered,
                    isPressed: configuration.isPressed
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small))
            .onHover { isHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: isHovered)
    }
}
