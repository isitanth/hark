import Foundation

// The word check, decision 4 (M13). S1 implements this, a port of the frozen `wordcheck.py`.

public enum MathIntent {
    /// Whether the spoken instruction asks for a calculation, in English or French. False sends the framed ask down
    /// today's path.
    public static func isComputation(_ instruction: String) -> Bool {
        false
    }
}
