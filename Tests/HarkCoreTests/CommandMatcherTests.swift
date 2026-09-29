import Foundation
import HarkCore
import Testing

/// The bundled default (ConfigFixtures.commands, which the fixture test holds to default-commands.yaml): open,
/// launch, show, start / ouvre, ouvrir, lance, lancer, affiche, afficher, démarre, démarrer; the fillers there, among
/// them the determiners (notre, votre, ce, du…); Finder, Safari, Notes ("note"), Mail, Messages, Calendar
/// ("calendrier"), Music ("musique"), System Settings ("settings", "réglages", "réglages système"), Terminal.
private let bundled = ConfigFixtures.commands

private func match(_ said: String, in config: CommandConfig = bundled, scorer: CommandMatcher.Scorer? = nil)
    -> CommandMatch?
{
    let matcher = scorer.map { CommandMatcher(config: config, scorer: $0) } ?? CommandMatcher(config: config)
    return matcher.match(Normalizer.normalize(said))
}

private func table(
    _ commands: [CommandEntry], verbs: [String] = ["ouvre", "open"], fillers: [String] = ["le", "the"],
    threshold: Double = 0.85
) -> CommandConfig {
    CommandConfig(
        defaults: CommandDefaults(threshold: threshold), openVerbs: ["x": verbs], fillers: ["x": fillers],
        commands: commands)
}

struct SpokenCase: Sendable, CustomTestStringConvertible {
    let said: String
    let id: String?

    var testDescription: String { said }
}

/// Your examples first, then the edges of the template.
let spokenCases: [SpokenCase] = [
    .init(said: "Ouvre le Finder.", id: "open_finder"),
    .init(said: "Ouvre Finder", id: "open_finder"),
    .init(said: "Open the Finder.", id: "open_finder"),
    .init(said: "Launch Finder!", id: "open_finder"),
    .init(said: "Finder is slow today.", id: nil),
    .init(said: "Ouvre le frigo.", id: nil),
    .init(said: "Ouvre Finder quand tu peux.", id: nil),
    .init(said: "Ouvre Finder et Safari.", id: nil),
    .init(said: "Ouvre Safari, puis le Finder.", id: nil),
    .init(said: "Ouvre le Finder pour demain.", id: nil),
    .init(said: "Ouvre le finder, probablement.", id: nil),
    .init(said: "Ouvre l'application Safari.", id: "open_safari"),
    .init(said: "I need to open Finder tomorrow.", id: nil),
    .init(said: "Please open Finder.", id: nil),
    .init(said: "New note for the meeting.", id: nil),
    .init(said: "Open.", id: nil),
    .init(said: "Ouvre le.", id: nil),
    .init(said: "Démarre Safari.", id: "open_safari"),
    .init(said: "Demarre safari", id: "open_safari"),
    .init(said: "Ouvre les réglages système.", id: "open_system_settings"),
    .init(said: "Ouvre les réglages.", id: "open_system_settings"),
    .init(said: "Open System Settings.", id: "open_system_settings"),
    .init(said: "Show my notes.", id: "open_notes"),
    .init(said: "Ouvre l’app Notes.", id: "open_notes"),
    .init(said: "Lance la musique.", id: "open_music"),
    .init(said: "Affiche mon calendrier.", id: "open_calendar"),
    .init(said: "Open le Finder.", id: "open_finder"),
    .init(said: "Start the VPN.", id: nil),
    .init(said: "Openness is a virtue.", id: nil),
    // "notre" scores 0.953 against "note": a filler now, so it is never taken for Notes.
    .init(said: "Ouvre notre dossier partagé.", id: nil),
    .init(said: "Ouvre votre boîte mail.", id: "open_mail"),
    .init(said: "", id: nil),
]

@Suite struct CommandMatcherTests {
    @Test(arguments: spokenCases)
    func theTemplate(_ scenario: SpokenCase) {
        #expect(match(scenario.said)?.command.id == scenario.id)
    }

    @Test func aMatchSaysWhatWasHeard() throws {
        let found = try #require(match("Ouvre les réglages système."))
        #expect(found.verb == "ouvre")
        #expect(found.alias == "reglages systeme")
        #expect(found.score == 1)
        #expect(
            found.command == ResolvedCommand(id: "open_system_settings", action: .openApp, target: "System Settings"))
    }

    /// A misheard app name still opens it; a word that only looks like one does not.
    @Test func theAppNameIsTheOneThingMatchedApproximately() throws {
        let fynder = try #require(match("Ouvre le Fynder."))
        #expect(fynder.command.id == "open_finder")
        #expect(fynder.score >= 0.85 && fynder.score < 1)
        #expect(match("Ouvre le fichier.") == nil)
        // The verb is not: "ouvrirons" is not "ouvre".
        #expect(match("Ouvrirons le Finder.") == nil)
    }

    // MARK: - The threshold

    /// The stub scores every pair not said as written, so only the threshold decides.
    @Test(arguments: [(0.85.nextDown, false), (0.85, true), (0.85.nextUp, true)])
    func theThresholdIsInclusive(_ score: Double, _ matches: Bool) {
        let found = match("ouvre fynder", in: table([CommandEntry(id: "f", app: "Finder")]), scorer: { _, _ in score })
        #expect((found != nil) == matches)
        if matches { #expect(found?.score == score) }
    }

    @Test(arguments: [(0.9.nextDown, false), (0.9, true)])
    func theFilesThresholdIsTheOneUsed(_ score: Double, _ matches: Bool) {
        let config = table([CommandEntry(id: "f", app: "Finder")], threshold: 0.9)
        #expect((match("ouvre fynder", in: config, scorer: { _, _ in score }) != nil) == matches)
    }

    /// Every word of an alias has to clear the threshold; one good word does not carry the other.
    @Test func eachWordOfAnAliasIsHeldToTheThreshold() {
        let config = table([CommandEntry(id: "s", app: "System Settings")])
        let scorer: CommandMatcher.Scorer = { said, _ in said == "sistem" ? 0.9 : 0.5 }
        #expect(match("open sistem settings", in: config, scorer: scorer)?.score == 0.9)
        #expect(match("open sistem sittings", in: config, scorer: scorer) == nil)
    }

    // MARK: - Which app

    @Test func anAliasSaidAsWrittenBeatsACloserSoundingOne() {
        let config = table([CommandEntry(id: "nodes", app: "Nodes"), CommandEntry(id: "notes", app: "Notes")])
        #expect(JaroWinkler.similarity("notes", "nodes") >= 0.85)
        #expect(match("ouvre notes", in: config)?.command.id == "notes")
    }

    @Test func theHigherScoreWinsAtOnePosition() {
        let config = table([CommandEntry(id: "a", app: "Alpha"), CommandEntry(id: "b", app: "Beta")])
        let scorer: CommandMatcher.Scorer = { _, alias in alias == "beta" ? 0.95 : 0.9 }
        #expect(match("ouvre gamma", in: config, scorer: scorer)?.command.id == "b")
    }

    @Test func theLongerAliasWinsWhenBothAreSaidAsWritten() {
        let config = table([
            CommandEntry(id: "short", app: "Reglages"), CommandEntry(id: "long", app: "Reglages Systeme"),
        ])
        #expect(match("ouvre reglages systeme", in: config)?.command.id == "long")
        #expect(match("ouvre reglages", in: config)?.command.id == "short")
    }

    @Test func onATieTheEarlierAliasInTheFileWins() {
        let config = table([CommandEntry(id: "a", app: "Alpha"), CommandEntry(id: "b", app: "Beta")])
        #expect(match("ouvre gamma", in: config, scorer: { _, _ in 0.9 })?.command.id == "a")
    }

    /// The first app named decides, however much better a later one matches: it has to end what was said, and
    /// nothing further along is looked at.
    @Test func theFirstAppNamedDecides() {
        #expect(match("Ouvre le Fynder, Safari.") == nil)
        #expect(match("Ouvre le Fynder.")?.command.id == "open_finder")
    }

    /// A polite ending may follow the app (your decision of 2026-09-29, which amends the rule of 2026-09-24).
    @Test(arguments: [
        ("Ouvre les réglages système, s’il te plaît.", "open_system_settings"),
        ("Ouvre-moi les messages s'il te plaît.", "open_messages"),
        ("Ouvrez Safari, s'il vous plaît.", "open_safari"),
        ("Open Safari please.", "open_safari"),
        ("Open the Finder, please!", "open_finder"),
    ])
    func aPoliteEndingMayFollowTheApp(_ said: String, _ id: String) {
        #expect(match(said)?.command.id == id)
    }

    /// Anything else after the app is still text, and so is the ending without a command before it.
    @Test(arguments: [
        "Ouvre Notes maintenant.", "Ouvre Safari s'il te plaît, merci.", "Ouvre Safari, please, now.",
        "Ouvre le Finder pour demain, s'il te plaît.", "Ouvre, s'il te plaît.", "S'il te plaît.", "Please.",
        "Please open Safari.", "Tu peux ouvrir Safari s'il te plaît ?",
    ])
    func anythingElseAfterTheAppIsText(_ said: String) {
        #expect(match(said) == nil)
    }

    /// After the spoken prefix too: "Arc, ouvre Safari s'il te plaît" runs the command.
    @Test func aPoliteEndingFollowsAnAdjacentApp() {
        let matcher = CommandMatcher(config: bundled)
        let id = { (said: String) in matcher.match(Normalizer.normalize(said), adjacent: true)?.command.id }
        #expect(id("Ouvre Safari s'il te plaît.") == "open_safari")
        #expect(id("Show me how to use Terminal, please.") == nil)
    }

    /// The file's `endings:` replace the default; an empty table turns them off.
    @Test func theFilesEndingsAreTheOnesAllowed() {
        var config = bundled
        config.endings = ["fr": ["merci"]]
        #expect(match("Ouvre Safari, merci.", in: config)?.command.id == "open_safari")
        #expect(match("Ouvre Safari, s'il te plaît.", in: config) == nil)
        config.endings = [:]
        #expect(match("Open Safari please.", in: config) == nil)
        config.endings = nil
        #expect(match("Open Safari please.", in: config)?.command.id == "open_safari")
    }

    /// An app whose name ends with the words of an ending is heard whole first.
    @Test func aNameThatEndsLikeAnEndingIsHeardWhole() {
        let config = table([CommandEntry(id: "wait", app: "Please Wait"), CommandEntry(id: "safari", app: "Safari")])
        var withEndings = config
        withEndings.endings = ["en": ["please"]]
        #expect(match("open please wait", in: withEndings)?.command.id == "wait")
        #expect(match("open safari please", in: withEndings)?.command.id == "safari")
    }

    // MARK: - Verbs and fillers

    /// Whisper cuts "TextEdit" into "texte d'édit", whose "d" is a filler: a second pass without the fillers inside the
    /// name opens it. What the first pass matched, or refused for words after the app, stays as it was.
    @Test func fillersInsideTheNameAreSkippedOnASecondPass() {
        let config = CommandConfig(
            openVerbs: ["fr": ["ouvre", "affiches"]], fillers: ["fr": ["d", "de", "le", "moi"]],
            commands: [
                CommandEntry(id: "open_textedit", app: "TextEdit", aliases: ["texte edit"]),
                CommandEntry(id: "open_finder", app: "Finder"),
            ])
        let matcher = CommandMatcher(config: config)
        let id = { (said: String) in matcher.match(Normalizer.normalize(said))?.command.id }
        #expect(id("Ouvre texte d'édit.") == "open_textedit")
        #expect(id("Affiches-moi texte d'édit.") == "open_textedit")
        #expect(id("Ouvre texte edit.") == "open_textedit")
        #expect(id("Ouvre le Finder.") == "open_finder")
        #expect(id("Ouvre le Finder de Pierre.") == nil)
        #expect(id("Ouvre le Finder pour demain.") == nil)
        // A filler after the name is not inside it: still text.
        #expect(id("Ouvre le Finder, moi.") == nil)
    }

    /// After the spoken prefix only a command with the app right after the verb runs.
    @Test func adjacentWantsTheAppRightAfterTheVerb() {
        let config = CommandConfig(
            openVerbs: ["en": ["show"], "fr": ["ouvre"]], fillers: ["en": ["me", "the"], "fr": ["le"]],
            commands: [
                CommandEntry(id: "open_terminal", app: "Terminal"), CommandEntry(id: "open_finder", app: "Finder"),
            ])
        let matcher = CommandMatcher(config: config)
        let id = { (said: String) in matcher.match(Normalizer.normalize(said), adjacent: true)?.command.id }
        #expect(id("ouvre le Finder") == "open_finder")
        #expect(id("show me the Terminal") == "open_terminal")
        #expect(id("show me how to use Terminal") == nil)
        #expect(matcher.match(Normalizer.normalize("show me how to use Terminal"))?.command.id == "open_terminal")
    }

    /// "application", "appli" and "app" are fillers (2026-09-29): after the spoken prefix "Arc, ouvre-moi l'application
    /// Messages" runs the command. Without the prefix those words were already passed over.
    @Test func theWordsForAnAppAreFillers() {
        let matcher = CommandMatcher(config: bundled)
        let id = { (said: String) in matcher.match(Normalizer.normalize(said), adjacent: true)?.command.id }
        #expect(id("Ouvre-moi l'application Messages.") == "open_messages")
        #expect(id("Ouvre l'appli Messages.") == "open_messages")
        #expect(id("Open the app Safari.") == "open_safari")
        #expect(id("Ouvre l'application.") == nil)
        #expect(id("Ouvre l'application de Pierre.") == nil)
    }

    /// A name that starts with one of those words is still heard whole.
    @Test func anAppNamedWithTheWordAppIsHeardWhole() {
        var config = bundled
        config.commands.append(CommandEntry(id: "open_app_store", app: "App Store"))
        #expect(match("Ouvre l'App Store.", in: config)?.command.id == "open_app_store")
        #expect(match("Open App Store.", in: config)?.command.id == "open_app_store")
    }

    @Test func aVerbOfSeveralWordsIsMatchedWhole() {
        let config = table([CommandEntry(id: "f", app: "Finder")], verbs: ["peux-tu ouvrir", "ouvre"])
        #expect(match("Peux-tu ouvrir le Finder ?", in: config)?.verb == "peux tu ouvrir")
        #expect(match("Peux-tu le Finder ?", in: config) == nil)
    }

    /// A filler is skipped rather than tried as an app, so an app that shares its name cannot be reached through it.
    @Test func aFillerIsNeverTriedAsAnApp() {
        let config = table([CommandEntry(id: "the", app: "The"), CommandEntry(id: "f", app: "Finder")])
        #expect(match("open the finder", in: config)?.command.id == "f")
        #expect(match("open the", in: config) == nil)
    }

    @Test func everyLanguageIsTriedOnEveryUtterance() {
        let config = CommandConfig(
            openVerbs: ["en": ["open"], "fr": ["ouvre"]], fillers: ["en": ["the"], "fr": ["le"]],
            commands: [CommandEntry(id: "f", app: "Finder")])
        for said in ["open le finder", "ouvre the finder", "open finder", "ouvre finder"] {
            #expect(match(said, in: config)?.command.id == "f", "\(said)")
        }
    }

    @Test func withoutVerbsNothingIsACommand() {
        let config = CommandConfig(commands: [CommandEntry(id: "f", app: "Finder")])
        #expect(match("open finder", in: config) == nil)
        #expect(CommandMatcher.empty.match("open finder") == nil)
    }

    /// A path in `app` is reached by the bundle's own name.
    @Test func anAppGivenByPathAnswersToItsName() {
        let config = table([CommandEntry(id: "t", app: "/System/Applications/Utilities/Terminal.app")])
        #expect(match("open the terminal", in: config)?.command.target == "/System/Applications/Utilities/Terminal.app")
    }

    /// The review's P2: fillers are skipped before an app is looked for, so an app whose name starts with one was
    /// out of reach.
    @Test func anAppWhoseNameStartsWithAFillerCanBeOpened() throws {
        let config = table(
            [CommandEntry(id: "unarchiver", app: "The Unarchiver"), CommandEntry(id: "equipe", app: "L'Équipe")],
            fillers: ["the", "l"])
        for said in ["Open The Unarchiver.", "Open Unarchiver.", "Ouvre L'Équipe.", "Ouvre Équipe."] {
            #expect(match(said, in: config) != nil, "\(said)")
        }
        #expect(try #require(match("Open The Unarchiver.", in: config)).alias == "the unarchiver")
        // A filler alone is never an app.
        #expect(match("open the", in: config) == nil)
    }

    @Test func aNameEndingInDotAppAnswersToItsName() {
        #expect(match("open safari", in: table([CommandEntry(id: "s", app: "Safari.app")]))?.command.id == "s")
    }

    /// The second review's P2: "Clock" and "The Clock" both configured, in either order, each answers to its own name.
    @Test(arguments: [false, true])
    func anAppNamedWithAFillerAndOneWithoutEachGetTheirOwn(_ reversed: Bool) {
        let both = [CommandEntry(id: "clock", app: "Clock"), CommandEntry(id: "the_clock", app: "The Clock")]
        let config = table(reversed ? both.reversed() : both, fillers: ["the"])
        #expect(match("Open the Clock.", in: config)?.command.id == "the_clock")
        #expect(match("Open Clock.", in: config)?.command.id == "clock")
    }

    /// A name as written beats another command's name stripped of its "the".
    @Test func aNameAsWrittenBeatsAStrippedOne() {
        let config = table(
            [
                CommandEntry(id: "unarchiver", app: "The Unarchiver"),
                CommandEntry(id: "pro", app: "Unarchiver Pro", aliases: ["unarchiver"]),
            ], fillers: ["the"])
        #expect(match("ouvre unarchiver", in: config)?.command.id == "pro")
        #expect(match("ouvre the unarchiver", in: config)?.command.id == "unarchiver")
    }

    /// A filler of several words that runs into an app's name does not swallow it.
    @Test func anAppThatStartsInsideAFillerIsHeard() {
        let config = table([CommandEntry(id: "nyt", app: "New York Times")], fillers: ["the new", "the"])
        #expect(match("Open the New York Times.", in: config)?.command.id == "nyt")
        #expect(match("Open New York Times.", in: config)?.command.id == "nyt")
    }

    @Test(arguments: [
        ("ce", true), ("ma", true), ("L'", true), ("ta musique", false), ("mes notes", false), ("?!", false),
        ("de la", false), ("The The", false),
    ])
    func onlyFillersIsSaidOfOneFillerTheMatcherAlwaysSkips(_ text: String, _ onlyFillers: Bool) {
        #expect(CommandMatcher.isOnlyFillers(text, in: bundled) == onlyFillers)
    }

    /// The editor lets through a name of several fillers because the matcher hears it said as written.
    @Test func aNameOfSeveralFillersIsHeard() {
        let config = table(
            [CommandEntry(id: "tt", app: "The The"), CommandEntry(id: "dl", app: "De La")],
            fillers: ["the", "de", "la"])
        #expect(match("Open The The.", in: config)?.command.id == "tt")
        #expect(match("Ouvre De La.", in: config)?.command.id == "dl")
        #expect(
            CommandEntry.problems(app: "The The", aliases: ["de la"], in: table([], fillers: ["the", "de", "la"]))
                .isEmpty)
    }

    /// Such a name is not also indexed as its last filler: "the" alone would fuzzily catch "their" and "them".
    @Test(
        arguments: [
            ("Open their calendar.", "open_calendar"), ("Open these notes.", "open_notes"), ("Open them.", nil),
            ("Open then Safari.", "open_safari"), ("Open The The.", "tt"),
        ] as [(String, String?)])
    func aNameOfSeveralFillersCatchesNothingNearAFiller(_ said: String, _ id: String?) {
        var config = bundled
        config.commands.append(CommandEntry(id: "tt", app: "The The"))
        #expect(match(said, in: config)?.command.id == id)
    }

    /// Passing over a rest of fillers does not stop the stripping: the word after it is still a way to say the name.
    @Test func aNameThatEndsPastAFillerOfSeveralWordsIsHeardByItsLastWord() {
        let config = table([CommandEntry(id: "ttn", app: "The The New")], fillers: ["the new", "the"])
        #expect(match("Open new.", in: config)?.command.id == "ttn")
        #expect(match("Open the the new.", in: config)?.command.id == "ttn")
        #expect(match("Open them.", in: config) == nil)
    }

    @Test func aDraftSaysWhatCannotBeHeard() {
        #expect(
            CommandEntry.problems(app: "Safari", aliases: ["navigateur"], in: bundled, editing: "open_safari").isEmpty)
        #expect(CommandEntry.problems(app: "?!", aliases: [], in: bundled) == [.appUnsayable])
        #expect(CommandEntry.problems(app: ".app", aliases: [], in: bundled) == [.appUnsayable])
        #expect(CommandEntry.problems(app: "Notre", aliases: [], in: bundled) == [.onlyFillers("Notre")])
        #expect(
            CommandEntry.problems(app: "Safari", aliases: ["…", "ce", "le web"], in: bundled, editing: "open_safari")
                == [.aliasUnsayable("…"), .onlyFillers("ce")])
    }

    /// A name another command already says is caught as typed, on its normalized form, and names that command's app.
    @Test func aDraftSaysWhatAnotherCommandAlreadyOpens() {
        #expect(
            CommandEntry.problems(app: "safari", aliases: [], in: bundled) == [.collision("safari", otherApp: "Safari")]
        )
        #expect(
            CommandEntry.problems(app: "Pages", aliases: ["Nôte !", "livre"], in: bundled)
                == [.collision("Nôte !", otherApp: "Notes")])
        #expect(
            CommandEntry.problems(app: "/Applications/Safari.app", aliases: [], in: bundled)
                == [.collision("Safari", otherApp: "Safari")])
    }

    /// The command being edited keeps its own names, and an alias may repeat its own app or another of its aliases.
    @Test func aDraftDoesNotCollideWithItself() {
        #expect(
            CommandEntry.problems(app: "Notes", aliases: ["note", "Notes", "NOTE"], in: bundled, editing: "open_notes")
                .isEmpty)
        #expect(CommandEntry.problems(app: "Pages", aliases: ["pages", "Pages"], in: bundled).isEmpty)
        #expect(
            CommandEntry.problems(app: "Carnet", aliases: ["note"], in: bundled, editing: "open_safari")
                == [.collision("note", otherApp: "Notes")])
    }
}
