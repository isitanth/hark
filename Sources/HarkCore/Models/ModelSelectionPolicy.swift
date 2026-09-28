import Foundation

/// Picks a model for the user when there is exactly one they could have meant.
///
/// A model can be installed with none selected: after the selected tier is deleted, after a purge followed by a
/// download, or when the weights were copied into the models folder by hand. The pipeline then fails every press
/// with `model_missing` although a usable model sits on disk. With a single installed tier there is nothing to
/// choose, so that tier is adopted; with two or more the choice stays the user's.
public enum ModelSelectionPolicy {
    /// What is known about one tier when the policy runs.
    public struct Inventory: Sendable, Equatable {
        public var phase: ModelInstallState.Phase
        /// The weights file exists, whatever the row says. With Core ML on, a tier whose encoder is still to come
        /// reads as not installed although its weights are in place, and a selection of it is still a live one.
        public var hasWeights: Bool

        public init(phase: ModelInstallState.Phase, hasWeights: Bool) {
            self.phase = phase
            self.hasWeights = hasWeights
        }
    }

    /// The tier to select, or nil to leave the selection alone.
    ///
    /// A selection stands while its tier is anything but gone: installed, downloading, paused, failed, or with its
    /// weights on disk. Only a selection of nothing, or of a tier that has left the disk entirely, is replaced.
    public static func tierToAdopt(selected: ModelTier?, inventory: [ModelTier: Inventory]) -> ModelTier? {
        if let selected, let entry = inventory[selected], entry.phase != .notInstalled || entry.hasWeights {
            return nil
        }
        // The row and the disk must agree: during a purge a row can still say installed after its files are gone.
        let installed = ModelTier.allCases.filter {
            inventory[$0].map { $0.phase == .installed && $0.hasWeights } == true
        }
        return installed.count == 1 ? installed.first : nil
    }
}
