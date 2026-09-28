import Foundation

extension CommandConfig {
    /// This config with the active profile's base URL set to `text`, trimmed, and `llm:` written out when the file
    /// had none. Nil when `text` is not an absolute URL at all. Whether it is an address Hark may send a key to is the
    /// parser's to say: Settings parses `yaml()` of the result before it writes it or tests it.
    public func settingServerAddress(_ text: String) -> CommandConfig? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host(percentEncoded: false) != nil else {
            return nil
        }
        var llm = effectiveLLM
        guard var profile = llm.activeProfile else { return nil }
        profile.baseURL = url
        llm.profiles[llm.provider] = profile
        var next = self
        next.llm = llm
        return next
    }
}
