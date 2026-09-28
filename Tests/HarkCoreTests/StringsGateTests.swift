import Foundation
import Testing

/// Holds HarkApp's strings to account from the outside: HarkCoreTests cannot import HarkApp, so it
/// reads the sources and catalogs from disk and runs the checks in `StringsGate`.
@Suite struct StringsGateTests {
    /// Keys whose French text is the English text on purpose.
    static let identicalInFrench: Set<String> = [
        "settings.tab.audio"
    ]

    /// The repo root, or `HARK_STRINGS_GATE_ROOT` to point the gate at a copy of the tree.
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["HARK_STRINGS_GATE_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func appSources(under root: URL) throws -> [StringsGate.Source] {
        let directory = root.appendingPathComponent("Sources/HarkApp", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        return try files.sorted { $0.path < $1.path }.map { file in
            let relative = String(file.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
            return StringsGate.Source(path: relative, text: try String(contentsOf: file, encoding: .utf8))
        }
    }

    static func catalog(_ relative: String, under root: URL) throws -> StringsGate.Catalog {
        try StringsGate.catalog(Data(contentsOf: root.appendingPathComponent(relative)))
    }

    @Test func theAppStringsAreComplete() throws {
        let sources = try Self.appSources(under: Self.root)
        let catalog = try Self.catalog("Sources/HarkApp/Resources/Localizable.xcstrings", under: Self.root)
        let scan = StringsGate.scan(sources)
        #expect(sources.count > 1, "found no HarkApp sources under \(Self.root.path)")
        #expect(!scan.keys.isEmpty, "found no L( calls")

        let problems =
            scan.problems
            + StringsGate.coverage(scan.keys, catalog)
            + StringsGate.presence(catalog, name: "Localizable")
            + StringsGate.specifierParity(catalog)
            + StringsGate.translated(catalog, allowed: Self.identicalInFrench)
            + StringsGate.frenchSpacing(catalog)
        #expect(problems.isEmpty, "\(problems.count) problems:\n\(problems.joined(separator: "\n"))")
    }

    /// The Services menu's "Ask Hark", keyed by its NSMenuItem title in Info.plist.
    @Test func theServicesMenuStringsAreComplete() throws {
        let catalog = try Self.catalog("Support/ServicesMenu.xcstrings", under: Self.root)
        #expect(catalog.strings.keys.sorted() == ["Ask Hark"])
        let problems =
            StringsGate.presence(catalog, name: "ServicesMenu") + StringsGate.translated(catalog, allowed: [])
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test func theInfoPlistStringsAreComplete() throws {
        let catalog = try Self.catalog("Support/InfoPlist.xcstrings", under: Self.root)
        #expect(!catalog.strings.isEmpty)
        let problems = StringsGate.presence(catalog, name: "InfoPlist")
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    // MARK: The checks catch what they claim to

    static func source(_ text: String) -> [StringsGate.Source] {
        [StringsGate.Source(path: "Fixture.swift", text: text)]
    }

    struct Call: Sendable, CustomTestStringConvertible {
        var code: String
        var template: String?
        var testDescription: String { code }
    }

    static let accepted: [Call] = [
        Call(code: #"Text(L("panel.quit"))"#, template: "panel.quit"),
        Call(code: #"L("config.location \(line) \(column)")"#, template: "config.location \u{1} \u{1}"),
        Call(code: #"L("audio.device \(device.name)")"#, template: "audio.device \u{1}"),
        Call(code: #"L("quote \"x\"")"#, template: "quote \"x\""),
        Call(code: #"URL("x") + XL("y") + func L(_ key: String)"#, template: nil),
    ]

    @Test(arguments: accepted) func acceptsPlainLiterals(_ call: Call) {
        let scan = StringsGate.scan(Self.source(call.code))
        #expect(scan.problems.isEmpty)
        #expect(scan.keys.map(\.template) == (call.template.map { [$0] } ?? []))
    }

    static let rejected: [String] = [
        #"L(key)"#,
        #"L(isOn ? "a" : "b")"#,
        #"L("a" + suffix)"#,
        #"L("a" "b")"#,
        #"L("""\na\n""")"#,
        #"L("count \(items.count + 1)")"#,
        #"L("name \(user.name())")"#,
        #"L("name \(names[0])")"#,
        #"L("name \("x")")"#,
        #"L("fifty %")"#,
        #"L("tab\u{9}")"#,
    ]

    @Test(arguments: rejected) func rejectsAnythingButAPlainLiteral(_ code: String) {
        let scan = StringsGate.scan(Self.source("let a = 1\nlet b = \(code)\n"))
        #expect(scan.keys.isEmpty)
        #expect(scan.problems.count == 1)
        #expect(scan.problems.first?.hasPrefix("Fixture.swift:2: ") == true, "\(scan.problems)")
    }

    @Test func frenchSpacingCatchesABreakingSpaceBeforePunctuation() throws {
        let nbsp = "\u{A0}"
        let catalog = try Self.catalog([
            ("ok", "a: b", "a\(nbsp): b"),
            ("yaml", "apps: in the file", "apps: dans le fichier"),
            ("colon", "a: b", "a : b"),
            ("question", "Delete?", "Supprimer ?"),
            ("guillemet", "\"x\"", "« x\(nbsp)»"),
        ])
        let problems = StringsGate.frenchSpacing(catalog)
        #expect(problems.count == 3, "\(problems)")
        #expect(problems.allSatisfy { !$0.hasPrefix("ok:") && !$0.hasPrefix("yaml:") })
    }

    /// A catalog from (key, en, fr) rows; a nil value leaves that localization out.
    static func catalog(_ rows: [(String, String?, String?)], state: String = "translated") throws
        -> StringsGate.Catalog
    {
        func unit(_ value: String?) -> [String: Any]? {
            value.map { ["stringUnit": ["state": state, "value": $0]] }
        }
        var strings: [String: Any] = [:]
        for (key, en, fr) in rows {
            var localizations: [String: Any] = [:]
            localizations["en"] = unit(en)
            localizations["fr"] = unit(fr)
            strings[key] = ["extractionState": "manual", "localizations": localizations]
        }
        let json: [String: Any] = ["sourceLanguage": "en", "strings": strings, "version": "1.0"]
        return try StringsGate.catalog(JSONSerialization.data(withJSONObject: json))
    }

    @Test func presenceCatchesAMissingEmptyOrUntranslatedValue() throws {
        let good = try Self.catalog([("a", "Open", "Ouvrir")])
        #expect(StringsGate.presence(good, name: "C").isEmpty)
        #expect(
            StringsGate.presence(try Self.catalog([("a", "Open", nil)]), name: "C") == ["C: a has no fr stringUnit"])
        #expect(
            StringsGate.presence(try Self.catalog([("a", nil, "Ouvrir")]), name: "C") == ["C: a has no en stringUnit"])
        #expect(StringsGate.presence(try Self.catalog([("a", "Open", " ")]), name: "C") == ["C: a fr is empty"])
        #expect(
            StringsGate.presence(try Self.catalog([("a", "Open", "Ouvrir")], state: "needs_review"), name: "C") == [
                "C: a en is needs_review, not translated", "C: a fr is needs_review, not translated",
            ])
    }

    @Test func coverageCatchesAMissingKeyAndAnOrphan() throws {
        let catalog = try Self.catalog([
            ("panel.quit", "Quit", "Quitter"), ("config.location %lld %lld", "Line %lld", "Ligne %lld"),
            ("panel.orphan", "Gone", "Parti"),
        ])
        let used = StringsGate.scan(
            Self.source(
                """
                L("panel.quit")
                L("config.location \\(line) \\(column)")
                L("panel.missing")
                L("config.location \\(line)")
                """
            )
        ).keys
        #expect(
            StringsGate.coverage(used, catalog) == [
                "Fixture.swift:3: panel.missing is not in the catalog",
                "Fixture.swift:4: config.location \\(…) is not in the catalog",
                "catalog key panel.orphan is not used by any L( call",
            ])
    }

    struct Parity: Sendable, CustomTestStringConvertible {
        var key: String
        var en: String
        var fr: String
        var problems: Int
        var testDescription: String { "\(key) | \(en) | \(fr)" }
    }

    static let parities: [Parity] = [
        Parity(key: "a", en: "Open", fr: "Ouvrir", problems: 0),
        Parity(key: "a", en: "100%% local", fr: "100 %% local", problems: 0),
        Parity(key: "d %@ %lld", en: "%@ on %lld", fr: "%2$lld sur %1$@", problems: 0),
        Parity(key: "d %@ %lld", en: "%1$@ on %2$lld", fr: "%@ sur %lld", problems: 0),
        Parity(key: "d %@ %lld", en: "%@ on %lld", fr: "%lld sur %@", problems: 1),
        Parity(key: "d %@ %lld", en: "%@ on %lld", fr: "%@ sur %d", problems: 1),
        Parity(key: "d %@ %lld", en: "%@ on %lld", fr: "%@", problems: 1),
        Parity(key: "d %@ %lld", en: "%@", fr: "%@", problems: 2),
        Parity(key: "a", en: "Open", fr: "Ouvrir %@", problems: 1),
        Parity(key: "a", en: "100% local", fr: "100 %% local", problems: 1),
    ]

    @Test(arguments: parities) func specifierParityComparesPositionsAndTypes(_ row: Parity) throws {
        let catalog = try Self.catalog([(row.key, row.en, row.fr)])
        let problems = StringsGate.specifierParity(catalog)
        #expect(problems.count == row.problems, "\(problems)")
    }

    @Test func translatedCatchesACopyAndAStaleAllowList() throws {
        let catalog = try Self.catalog([("a", "Audio", "Audio"), ("b", "Open", "Ouvrir")])
        #expect(StringsGate.translated(catalog, allowed: ["a"]).isEmpty)
        #expect(StringsGate.translated(catalog, allowed: []).count == 1)
        #expect(StringsGate.translated(catalog, allowed: ["a", "b", "c"]).count == 2)
    }
}
