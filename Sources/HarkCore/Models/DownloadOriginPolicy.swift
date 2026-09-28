import Foundation

/// The origin allow-list for model downloads.
///
/// Model downloads are the only network traffic Hark makes, so this is not defence in depth — it is the whole
/// defence. It is applied to the URL we start with and again to every redirect target, because the case worth
/// catching is a redirect that walks off the origin, not a typo in `ModelCatalog`.
public enum DownloadOriginPolicy {
    /// The registrable domains Hugging Face serves from. Both are needed, and the second is not obvious.
    ///
    /// `huggingface.co` is where the pinned URLs point. `hf.co` is where they land: since the move to Xet
    /// storage, resolving an LFS object returns a signed 302 to `us.aws.cdn.hf.co`, which is a *different*
    /// registrable domain rather than a subdomain of the first. Allowing only `huggingface.co` refuses every
    /// real download at its first hop, which is exactly what shipped until a download was tried for real.
    public static let domains = ["huggingface.co", "hf.co"]

    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), !host.isEmpty else {
            return false
        }
        return domains.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// Nil when `url` is allowed, otherwise the failure naming the host we refused.
    public static func rejection(for url: URL) -> ModelInstallFailure? {
        guard !allows(url) else { return nil }
        return .forbiddenOrigin(url.host() ?? url.absoluteString)
    }
}
