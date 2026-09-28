import Foundation

// swift-format-ignore: AlwaysUseLowerCamelCase
/// Looks `key` up in this target's Localizable.xcstrings.
nonisolated func L(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: #bundle)
}
