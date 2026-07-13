import Foundation

// Keep stable localization keys beside their English fallbacks. Translations live in
// Resources/<language>.lproj/Localizable.strings and follow the user's system language.
func localized(_ key: String, _ english: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: english, comment: "")
}

func localizedFormat(_ key: String, _ english: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key, english), locale: .current, arguments: arguments)
}
