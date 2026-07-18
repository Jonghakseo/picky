import Foundation

/// Narration pacing calibrated for annotation reveals. Weights follow OmniVoice
/// RuleDurationEstimator's Latin=1.0 relative scale. Absolute constants were
/// calibrated on 2026-07-18 against 11 recovered real Edge TTS turns
/// (Korean-dominant mixed prose, R²=0.995); recalibrate if provider or voice changes.
enum PickyNarrationPaceModel {
    /// Delay between provider `speak()` acceptance and audible speech.
    static let speechPrerollSeconds: TimeInterval = 0.92
    static let secondsPerWeightUnit: TimeInterval = 0.0837

    static func weightedUnits(forNarration text: String) -> Double {
        stripParentheticalsForSpeech(text).unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult + weight(of: scalar)
        }
    }

    static func weight(of scalar: Unicode.Scalar) -> Double {
        let code = scalar.value
        if (0x41...0x5A).contains(code) || (0x61...0x7A).contains(code) {
            return 1.0
        }
        if code == 0x20 {
            return 0.2
        }

        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark:
            return 0.0
        case .connectorPunctuation, .dashPunctuation, .openPunctuation,
             .closePunctuation, .initialPunctuation, .finalPunctuation,
             .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol,
             .otherSymbol:
            return 0.5
        case .decimalNumber, .letterNumber, .otherNumber:
            return 3.5
        case .spaceSeparator, .lineSeparator, .paragraphSeparator:
            return 0.2
        default:
            break
        }

        if (0xAC00...0xD7AF).contains(code)
            || (0x1100...0x11FF).contains(code)
            || (0x3130...0x318F).contains(code) {
            return 2.5
        }
        if (0x4E00...0x9FFF).contains(code)
            || (0x3400...0x4DBF).contains(code)
            || (0xF900...0xFAFF).contains(code) {
            return 3.0
        }
        if (0x3040...0x30FF).contains(code) {
            return 2.2
        }
        if code > 0x20000 {
            return 3.0
        }
        return 1.0
    }
}
