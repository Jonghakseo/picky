//
//  PickyPickleRenamePolicy.swift
//  Picky
//
//  Pure validation for an explicit Pickle display-name change. The same rules
//  apply to the inline title field in the conversation header and to
//  `picky pickle-rename`, so the two surfaces can never disagree about which
//  names are accepted.
//

import Foundation

enum PickyPickleRenamePolicy {
    /// Unicode scalars, not characters: the daemon counts code points, and a
    /// name is rejected rather than silently truncated.
    static let maximumTitleScalarCount = 200

    enum Rejection: Error, Equatable {
        case empty
        case controlCharacter
        case tooLong(scalarCount: Int)
    }

    /// Returns the title to persist, or the reason it cannot be persisted.
    ///
    /// Control characters are checked on the raw input, exactly like the
    /// daemon's `/[\p{Cc}\p{Zl}\p{Zp}]/u`: a trailing newline must be rejected
    /// rather than laundered by the trim, so both ends agree on which names
    /// exist.
    static func normalizedTitle(_ raw: String) -> Result<String, Rejection> {
        if raw.unicodeScalars.contains(where: isRejectedScalar) { return .failure(.controlCharacter) }
        // Match ECMAScript trim: Foundation also trims U+200B and omits U+FEFF.
        let whitespace = CharacterSet.whitespacesAndNewlines
            .subtracting(.controlCharacters)
            .union(CharacterSet(charactersIn: "\u{FEFF}"))
        let trimmed = raw.trimmingCharacters(in: whitespace)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let scalarCount = trimmed.unicodeScalars.count
        guard scalarCount <= maximumTitleScalarCount else { return .failure(.tooLong(scalarCount: scalarCount)) }
        return .success(trimmed)
    }

    /// `Cc`, `Zl`, `Zp` only. `CharacterSet.controlCharacters` is a wider set:
    /// it also contains format characters (`Cf`, e.g. U+200E), which the daemon
    /// accepts, so using it here would reject names the CLI can still create.
    private static func isRejectedScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: true
        default: false
        }
    }
}

extension PickyPickleRenamePolicy.Rejection {
    var message: String {
        switch self {
        case .empty: "A Pickle name cannot be empty."
        case .controlCharacter: "A Pickle name cannot contain line breaks or control characters."
        case .tooLong(let scalarCount):
            "A Pickle name must be at most \(PickyPickleRenamePolicy.maximumTitleScalarCount) characters (received \(scalarCount))."
        }
    }
}
