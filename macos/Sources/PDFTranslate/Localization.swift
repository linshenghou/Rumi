import Foundation

/// Native bundle localization follows the user's macOS language order, with English as the fallback.
enum L10n {
    static let bundle: Bundle = {
        if Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil {
            return Bundle.main
        }
        return Bundle.module
    }()

    static func text(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: bundle, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }
}
