import AppKit
import Testing

@MainActor
enum PickyHubAccessibilityObservation {
    static func label(of element: Any?) -> String? {
        string("accessibilityLabel", of: element)
    }

    static func describe(_ element: Any?) -> String {
        guard let element else { return "nil" }
        let fields = ["accessibilityLabel", "accessibilityTitle", "accessibilityRole", "accessibilityIdentifier"]
        let values = fields.map { "\($0)=\(string($0, of: element) ?? "nil")" }.joined(separator: ", ")
        return "\(String(reflecting: type(of: element))) protocol=\(element is NSAccessibilityProtocol), \(values)"
    }

    // AppKit single-cell controls and some SwiftUI AX nodes still expose
    // their actual public accessibility output through the informal API.
    static func legacyValue(_ attribute: NSAccessibility.Attribute, of element: Any) -> Any? {
        guard let object = element as? NSObject,
              object.accessibilityAttributeNames().contains(attribute) else { return nil }
        return object.accessibilityAttributeValue(attribute)
    }

    private static func string(_ name: String, of element: Any?) -> String? {
        let selector = NSSelectorFromString(name)
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}

@MainActor
struct PickyHubAccessibilityObservationTests {
    @Test func labelDoesNotRequireTheFullAccessibilityProtocol() {
        let element: NSObject = LabelOnlyAccessibilityElement()
        #expect((element as? NSAccessibilityProtocol) == nil)
        #expect(PickyHubAccessibilityObservation.label(of: element) == "Focus probe")
    }

    @Test func missingElementOrUnsupportedSelectorHasNoLabel() {
        #expect(PickyHubAccessibilityObservation.label(of: nil) == nil)
        #expect(PickyHubAccessibilityObservation.label(of: NSObject()) == nil)
    }
}

// SwiftUI.AccessibilityNode exposes this selector without formally conforming
// to the full NSAccessibility protocol. No view or window is needed here.
@MainActor
private final class LabelOnlyAccessibilityElement: NSObject {
    @objc func accessibilityLabel() -> String { "Focus probe" }
}
