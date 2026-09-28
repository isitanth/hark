import Foundation
import HarkCore
import Testing

@Suite struct ModelCatalogTests {
    private static let lowercaseHex = Set("0123456789abcdef")

    @Test(arguments: ModelTier.allCases)
    func everyTierHasAnEntry(_ tier: ModelTier) {
        let entry = ModelCatalog.entry(for: tier)
        #expect(entry.tier == tier)
        #expect(!entry.displayName.isEmpty)
        #expect(ModelCatalog.all.contains(entry))
    }

    @Test func allCoversEveryTierExactlyOnce() {
        #expect(ModelCatalog.all.map(\.tier) == ModelTier.allCases)
    }

    @Test(arguments: ModelTier.allCases)
    func hashesAre64LowercaseHexCharacters(_ tier: ModelTier) {
        for artifact in ModelCatalog.entry(for: tier).artifacts {
            #expect(artifact.sha256.count == 64)
            #expect(artifact.sha256.allSatisfy(Self.lowercaseHex.contains))
        }
    }

    @Test(arguments: ModelTier.allCases)
    func urlsArePinnedToTheOneCommit(_ tier: ModelTier) {
        for artifact in ModelCatalog.entry(for: tier).artifacts {
            #expect(artifact.url.scheme == "https")
            #expect(artifact.url.host() == ModelCatalog.host)
            #expect(artifact.url.pathComponents.contains(ModelCatalog.pinnedCommit))
            #expect(artifact.url.lastPathComponent == artifact.file)
            #expect(artifact.byteCount > 0)
        }
    }

    @Test func nothingIsCopiedBetweenTiers() {
        let artifacts = ModelCatalog.all.flatMap(\.artifacts)
        #expect(Set(artifacts.map(\.sha256)).count == artifacts.count)
        #expect(Set(artifacts.map(\.file)).count == artifacts.count)
        #expect(Set(artifacts.map(\.byteCount)).count == artifacts.count)
    }

    @Test(arguments: ModelTier.allCases)
    func onlyTheEncoderIsAnArchive(_ tier: ModelTier) throws {
        let entry = ModelCatalog.entry(for: tier)
        let encoder = try #require(entry.coreMLEncoder)
        #expect(!entry.weights.isArchive)
        #expect(entry.weights.file.hasSuffix(".bin"))
        #expect(encoder.isArchive)
        #expect(entry.downloadByteCount == entry.weights.byteCount + encoder.byteCount)
    }

    @Test func theTableItself() {
        #expect(
            ModelCatalog.all.map(\.weights.file) == [
                "ggml-small-q8_0.bin", "ggml-medium-q8_0.bin", "ggml-large-v3-q5_0.bin",
            ])
        #expect(
            ModelCatalog.all.compactMap(\.coreMLEncoder?.file) == [
                "ggml-small-encoder.mlmodelc.zip", "ggml-medium-encoder.mlmodelc.zip",
                "ggml-large-v3-encoder.mlmodelc.zip",
            ])
        #expect(ModelCatalog.all.map(\.weights.byteCount) == [264_464_607, 823_369_779, 1_081_140_203])
        #expect(ModelCatalog.all.compactMap(\.coreMLEncoder?.byteCount) == [163_083_239, 567_829_413, 1_175_711_232])
    }

    @Test func theUrlTemplate() {
        #expect(
            ModelCatalog.url(forFile: "ggml-small-q8_0.bin").absoluteString
                == "https://huggingface.co/ggerganov/whisper.cpp/resolve/"
                + "5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q8_0.bin")
    }
}
