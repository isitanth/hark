import Foundation

/// The HUD's timer text, from the audio captured rather than the key press, so it reads `30:00` exactly when the
/// capture stops at the limit.
public enum ElapsedTime {
    /// `m:ss`, the seconds floored and minutes unpadded. Minutes are not clamped, so a changed capture limit still
    /// reads right. The digits are ASCII in every language, so the text is not localized.
    public static func text(milliseconds: Int) -> String {
        let seconds = max(0, milliseconds) / 1_000
        let remainder = seconds % 60
        return "\(seconds / 60):" + (remainder < 10 ? "0" : "") + "\(remainder)"
    }
}
