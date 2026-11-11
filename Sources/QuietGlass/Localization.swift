import Foundation

/// Looks up a localized string from the app bundle, falling back to the key itself.
func QG(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}

/// Looks up a localized format string and substitutes the given arguments.
func QG(_ format: String, _ arguments: CVarArg...) -> String {
    let localized = NSLocalizedString(format, tableName: nil, bundle: .main, value: format, comment: "")
    return String(format: localized, arguments: arguments)
}
