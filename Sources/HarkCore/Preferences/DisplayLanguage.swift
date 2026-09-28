import Foundation

/// The language Hark's own interface is shown in, independent of the dictation language. Stored as macOS stores a
/// per-app language: `AppleLanguages` in the app's own defaults domain, which the whole process reads at launch.
public enum DisplayLanguage: String, Sendable, CaseIterable {
    /// No per-app value: the order set in System Settings applies.
    case system
    case english
    case french

    public static let defaultsKey = "AppleLanguages"

    /// Only the first element decides, as it does for the bundle's localization. Regional variants map to their
    /// language; anything Hark has no catalog for reads as `.system`.
    public init(appleLanguages: [String]?) {
        let language = appleLanguages?.first?.split(separator: "-").first.map(String.init)?.lowercased()
        switch language {
        case "en": self = .english
        case "fr": self = .french
        default: self = .system
        }
    }

    /// Nil means the key is removed.
    public var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .english: ["en"]
        case .french: ["fr"]
        }
    }
}
