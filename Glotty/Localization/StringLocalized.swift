import Foundation
import SwiftUI

/// Shortcut wrapper to force a runtime string through Foundation's
/// localization machinery. SwiftUI's `Text("Done")` (literal) goes
/// through this path automatically, but `Text(myString)` (variable)
/// does NOT — the `String` overload bypasses LocalizedStringKey.
/// Same for `Button(myString)`, `LabeledContent(myString)`,
/// `Picker("…", selection: …) { Text(option.name) }`, etc.
///
/// Wrap any non-literal display string with `.t` so the swizzled
/// `Bundle.localizedString` sees it and the LLM-cache layer can
/// translate it. Idempotent — wrapping an already-translated
/// string is a cache hit.
extension String {
    /// "Localize this user-facing string". Short name because it
    /// gets used everywhere a runtime string ends up displayed.
    var t: String {
        Bundle.main.localizedString(forKey: self, value: nil, table: nil)
    }
}

/// Helper for SwiftUI sites that want a Text built from a runtime
/// String but still localized. `Text(loc: myString)` becomes
/// `Text(myString.t)` under the hood — handy when the caller has
/// a plain String and doesn't want a `.t` dance in the call site.
extension Text {
    init(loc string: String) {
        self.init(string.t)
    }
}
