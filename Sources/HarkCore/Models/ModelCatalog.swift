import Foundation

/// One downloadable file: ggml weights, or a zipped Core ML encoder.
public struct ModelArtifact: Sendable, Equatable {
    public let file: String
    public let url: URL
    /// The published size. The free-space check and the progress bar both need it before the first byte lands.
    public let byteCount: Int64
    /// Lowercase hex, 64 characters.
    public let sha256: String

    public init(file: String, url: URL, byteCount: Int64, sha256: String) {
        self.file = file
        self.url = url
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    /// An artefact that has to be unzipped after download, which is what doubles its space requirement.
    public var isArchive: Bool { file.hasSuffix(".zip") }

    /// What `ditto -x -k` writes into the destination directory: the file name without `.zip`.
    ///
    /// Not where it ends up. whisper.cpp derives the encoder path from the weights, which are quantised, so
    /// `ModelStore` renames this to whatever `ModelInstallation.coreMLEncoderURL(for:)` says.
    public var archiveContentName: String { isArchive ? String(file.dropLast(4)) : file }
}

public struct ModelCatalogEntry: Sendable, Equatable {
    public let tier: ModelTier
    /// The model's own name. Identical in every language, so it does not belong in the string catalog.
    public let displayName: String
    public let weights: ModelArtifact
    /// Nil for a tier with no published Core ML encoder. All three published ones exist at the pinned commit.
    public let coreMLEncoder: ModelArtifact?

    public init(tier: ModelTier, displayName: String, weights: ModelArtifact, coreMLEncoder: ModelArtifact?) {
        self.tier = tier
        self.displayName = displayName
        self.weights = weights
        self.coreMLEncoder = coreMLEncoder
    }

    public var artifacts: [ModelArtifact] { [weights, coreMLEncoder].compactMap(\.self) }

    /// Bytes to fetch. Not the same as bytes needed on disk — see `DiskSpacePolicy`.
    public var downloadByteCount: Int64 { artifacts.reduce(0) { $0 + $1.byteCount } }
}

/// The three tiers Hark ships, pinned to one whisper.cpp commit.
///
/// The commit is part of the contract, not decoration: Hugging Face serves `main` as a moving target, and a
/// requantised upload under the same file name would fail verification against a hash baked in here.
public enum ModelCatalog {
    public static let pinnedCommit = "5359861c739e955e79d9a303bcbc70fb988958b1"
    public static let host = "huggingface.co"

    /// Every component is a literal, so the only way this fails is a typo, which the catalogue tests catch.
    public static func url(forFile file: String) -> URL {
        URL(string: "https://\(host)/ggerganov/whisper.cpp/resolve/\(pinnedCommit)/\(file)")!
    }

    /// Total, so a missing tier is a compile error rather than a nil at runtime.
    public static func entry(for tier: ModelTier) -> ModelCatalogEntry {
        switch tier {
        case .small:
            ModelCatalogEntry(
                tier: .small,
                displayName: "Small",
                weights: artifact(
                    "ggml-small-q8_0.bin", 264_464_607,
                    "49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f"),
                coreMLEncoder: artifact(
                    "ggml-small-encoder.mlmodelc.zip", 163_083_239,
                    "de43fb9fed471e95c19e60ae67575c2bf09e8fb607016da171b06ddad313988b"))
        case .medium:
            ModelCatalogEntry(
                tier: .medium,
                displayName: "Medium",
                weights: artifact(
                    "ggml-medium-q8_0.bin", 823_369_779,
                    "42a1ffcbe4167d224232443396968db4d02d4e8e87e213d3ee2e03095dea6502"),
                coreMLEncoder: artifact(
                    "ggml-medium-encoder.mlmodelc.zip", 567_829_413,
                    "79b0b8d436d47d3f24dd3afc91f19447dd686a4f37521b2f6d9c30a642133fbd"))
        case .large:
            ModelCatalogEntry(
                tier: .large,
                displayName: "Large v3",
                weights: artifact(
                    "ggml-large-v3-q5_0.bin", 1_081_140_203,
                    "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"),
                coreMLEncoder: artifact(
                    "ggml-large-v3-encoder.mlmodelc.zip", 1_175_711_232,
                    "47837be7594a29429ec08620043390c4d6d467f8bd362df09e9390ace76a55a4"))
        }
    }

    public static var all: [ModelCatalogEntry] { ModelTier.allCases.map(entry(for:)) }

    private static func artifact(_ file: String, _ byteCount: Int64, _ sha256: String) -> ModelArtifact {
        ModelArtifact(file: file, url: url(forFile: file), byteCount: byteCount, sha256: sha256)
    }
}

/// The catalogue as a value, so `ModelStore` can be pointed at fixture artefacts in a test.
///
/// Production always uses `.standard`. Nothing else may ship a table: the pinned hashes are the only thing
/// standing between a download and whatever the CDN felt like serving.
public struct ModelCatalogTable: Sendable {
    public let entry: @Sendable (ModelTier) -> ModelCatalogEntry

    public init(entry: @escaping @Sendable (ModelTier) -> ModelCatalogEntry) {
        self.entry = entry
    }

    public static let standard = ModelCatalogTable(entry: ModelCatalog.entry(for:))

    public var all: [ModelCatalogEntry] { ModelTier.allCases.map(entry) }
}
