import Foundation

// The partial plan, while it streams (M13, plan §4.3): `IntentSplit`'s twin. S1 implements this.

public enum PlanStream {
    /// The `understood` value as far as the partial JSON holds it, unescaped; nil until its opening quote. Nothing
    /// else of the plan is ever shown.
    public static func understood(partial: String) -> String? {
        nil
    }
}
