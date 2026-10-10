import Foundation
import CoreGraphics

/// Decides whether a key-down's typed characters should travel with the event so the
/// controlled Mac types what the controller's keyboard layout produced, not what its own
/// layout maps that virtual key code to.
enum KeyCharacters {
    /// Max UTF-8 bytes carried in the binary trailer; longer strings are dropped (keycode only).
    static let maxBytes = 32

    /// The characters to inject, or nil to fall back to keycode-only injection.
    static func override(for chars: String?, flags: UInt64) -> String? {
        guard let chars, !chars.isEmpty else { return nil }                   // dead key / none
        let f = CGEventFlags(rawValue: flags)
        // Shortcuts are keycode-based: apps match them on charactersIgnoringModifiers, which
        // an injected unicode string would corrupt (⇧ case etc.).
        if f.contains(.maskCommand) || f.contains(.maskControl) { return nil }
        for scalar in chars.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || v == 0x7F { return nil }                            // control chars
            if (0xF700...0xF8FF).contains(v) { return nil }                    // NSEvent function-key PUA
        }
        return chars
    }
}
