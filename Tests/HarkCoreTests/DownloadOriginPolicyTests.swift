import Foundation
import HarkCore
import Testing

@Suite struct DownloadOriginPolicyTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    /// The pinned origin, the older `cdn-lfs*` subdomains, and — the one that matters — the `hf.co` domain Xet
    /// storage actually redirects to. An allow-list of `huggingface.co` alone refuses every real download at
    /// its first hop, which is what shipped before a download was tried against the live service.
    @Test(
        arguments: [
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/abc/ggml-small-q8_0.bin",
            "https://cdn-lfs.huggingface.co/repos/00/ab/object?signature=deadbeef",
            "https://cdn-lfs-us-1.huggingface.co/repos/00/ab/object",
            // The observed Xet redirect, 2026-09-21: a different registrable domain, not a subdomain.
            "https://us.aws.cdn.hf.co/xet-bridge-us/641ab5d1/53268772?X-Xet-Cas-Uid=public&Expires=1789977864",
            "https://hf.co/ggerganov/whisper.cpp/resolve/abc/ggml-small-q8_0.bin",
            // Hosts are case-insensitive per RFC 3986, and a redirect is free to shout.
            "https://HuggingFace.CO/ggerganov/whisper.cpp/resolve/abc/ggml-small-q8_0.bin",
        ])
    func theHuggingFaceOriginAndItsSubdomainsAreAllowed(_ string: String) throws {
        let url = try url(string)
        #expect(DownloadOriginPolicy.allows(url))
        #expect(DownloadOriginPolicy.rejection(for: url) == nil)
    }

    @Test(
        arguments: [
            "https://evil.example/ggml-small-q8_0.bin",
            // The pair that a naive `contains` or a suffix match without the dot would wave through.
            "https://huggingface.co.evil.example/ggml-small-q8_0.bin",
            "https://nothuggingface.co/ggml-small-q8_0.bin",
            // The same pair again for the second domain, which is short enough to be easy to match too loosely.
            "https://hf.co.evil.example/ggml-small-q8_0.bin",
            "https://nothf.co/ggml-small-q8_0.bin",
            // Credentials in the authority put the real host after the @; the parser knows, a reader might not.
            "https://huggingface.co@evil.example/ggml-small-q8_0.bin",
            // Plaintext to the right host is still refused: these are signed URLs over hundreds of megabytes.
            "http://huggingface.co/ggml-small-q8_0.bin",
            "file:///etc/passwd",
        ])
    func everythingElseIsRefused(_ string: String) throws {
        let url = try url(string)
        #expect(!DownloadOriginPolicy.allows(url))
        #expect(DownloadOriginPolicy.rejection(for: url)?.code.hasPrefix("forbidden_origin:") == true)
    }

    @Test func theRejectionNamesTheHostItRefused() throws {
        let rejection = DownloadOriginPolicy.rejection(for: try url("https://evil.example/ggml-small-q8_0.bin"))
        #expect(rejection == .forbiddenOrigin("evil.example"))
    }

    /// Ties the policy to the table it guards: a catalogue URL that the allow-list would refuse is an install
    /// that fails on the first hop, and nothing else in the suite would catch it.
    @Test(arguments: ModelTier.allCases)
    func everyCatalogueURLPassesItsOwnPolicy(_ tier: ModelTier) {
        for artifact in ModelCatalog.entry(for: tier).artifacts {
            #expect(DownloadOriginPolicy.allows(artifact.url))
        }
    }
}
