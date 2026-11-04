import Foundation

// The words that name a result (M14, plan §4.2), beside `SpokenNumbers`. The contract's stubs; S1 implements them.

/// « résultat un », "result 2", « le deuxième résultat », "the last result", ①…⑳. Two uses: its phrases are taken out
/// before the spoken-constant check, and a follow-up that names a result goes to the exact path past the frozen word
/// check, its block list still winning. `MathIntent`'s frozen lists are not touched.
public enum ResultWords {
    /// The result numbers `text` names, in order; `count` is how many the conversation holds ("the last" names it).
    /// The contract's stub names none.
    public static func named(in text: String, count: Int) -> [Int] {
        []
    }

    /// `text` with each phrase that names a result replaced by a space. The contract's stub returns `text`.
    public static func stripped(_ text: String) -> String {
        text
    }
}
