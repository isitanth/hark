import Foundation
import HarkCore
import Testing

/// whisper.cpp takes no encoder path. It derives one from the weights, and getting it wrong is silent: the
/// model still loads, just on Metal alone, and the only sign is whisper's own "failed to load Core ML model"
/// line. These assertions are the alarm.
///
/// The derivation drops the extension, drops a trailing quantisation suffix, and appends `-encoder.mlmodelc`.
/// The middle step is the one that is easy to get backwards: there is one encoder per model, shared by all its
/// quantisations, so it is named for the unquantised model and the published archive already unpacks under
/// exactly the right name. An earlier version of this file asserted the opposite and the install renamed the
/// directory to match, which meant Core ML never loaded for any tier.
@Suite struct CoreMLEncoderPathTests {
    /// Written out rather than derived, so changing the derivation has to be done twice on purpose. Every
    /// `installed` value below was copied from a whisper.cpp b5130 log line on 2026-09-21.
    private static let expected: [ModelTier: (weights: String, installed: String)] = [
        .small: ("ggml-small-q8_0.bin", "ggml-small-encoder.mlmodelc"),
        .medium: ("ggml-medium-q8_0.bin", "ggml-medium-encoder.mlmodelc"),
        .large: ("ggml-large-v3-q5_0.bin", "ggml-large-v3-encoder.mlmodelc"),
    ]

    private let layout = ModelLayout(models: URL(filePath: "/models"))

    @Test(arguments: ModelTier.allCases)
    func theEncoderIsNamedForTheUnquantisedModel(_ tier: ModelTier) throws {
        let names = try #require(Self.expected[tier])
        #expect(ModelCatalog.entry(for: tier).weights.file == names.weights)
        #expect(layout.coreMLEncoder(for: tier).lastPathComponent == names.installed)
    }

    /// What `ditto` writes is what gets installed. No rename, because the archive is already right.
    @Test(arguments: ModelTier.allCases)
    func theArchiveUnpacksUnderTheNameItIsInstalledUnder(_ tier: ModelTier) throws {
        let names = try #require(Self.expected[tier])
        let encoder = try #require(ModelCatalog.entry(for: tier).coreMLEncoder)
        #expect(encoder.file == "\(names.installed).zip")
        #expect(encoder.archiveContentName == names.installed)
        #expect(layout.coreMLEncoder(for: tier).lastPathComponent == encoder.archiveContentName)
    }

    /// Every quantisation of one model shares its encoder, which is why the suffix is stripped at all.
    @Test(
        arguments: [
            ("ggml-small-q8_0.bin", "ggml-small-encoder.mlmodelc"),
            ("ggml-small-q5_1.bin", "ggml-small-encoder.mlmodelc"),
            ("ggml-small.bin", "ggml-small-encoder.mlmodelc"),
            ("ggml-large-v3-q5_0.bin", "ggml-large-v3-encoder.mlmodelc"),
            ("ggml-large-v3-turbo-q8_0.bin", "ggml-large-v3-turbo-encoder.mlmodelc"),
            // "-q" that is not a quantisation suffix stays put.
            ("ggml-quirky.bin", "ggml-quirky-encoder.mlmodelc"),
        ])
    func quantisationSuffixesCollapseToOneEncoder(_ weights: String, _ encoder: String) {
        let url = URL(filePath: "/m").appending(path: weights, directoryHint: .notDirectory)
        #expect(ModelInstallation.coreMLEncoderURL(for: url).lastPathComponent == encoder)
    }

    @Test(arguments: ModelTier.allCases)
    func theEncoderIsASiblingOfTheWeightsAndAgreesWithTheContractType(_ tier: ModelTier) {
        let weights = layout.weights(for: tier)
        let encoder = layout.coreMLEncoder(for: tier)
        #expect(encoder == ModelInstallation.coreMLEncoderURL(for: weights))
        #expect(encoder.deletingLastPathComponent() == weights.deletingLastPathComponent())
    }

    /// A `ModelInstallation` built from the layout is what the Transcriber hands whisper.cpp.
    @Test(arguments: ModelTier.allCases)
    func theInstallationRoundTripsToTheSamePath(_ tier: ModelTier) {
        let installation = ModelInstallation(
            tier: tier,
            weights: layout.weights(for: tier),
            coreMLEncoder: layout.coreMLEncoder(for: tier))
        #expect(ModelInstallation.coreMLEncoderURL(for: installation.weights) == installation.coreMLEncoder)
    }

    @Test func everyTierResolvesToADistinctEncoderDirectory() {
        let encoders = ModelTier.allCases.map { layout.coreMLEncoder(for: $0) }
        #expect(Set(encoders).count == ModelTier.allCases.count)
    }
}
