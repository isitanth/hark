import Foundation
import HarkCore
import Testing

struct SelectionCase: Sendable, CustomTestStringConvertible {
    let name: String
    let selected: ModelTier?
    let inventory: [ModelTier: ModelSelectionPolicy.Inventory]
    let adopt: ModelTier?

    var testDescription: String { name }
}

private func installed() -> ModelSelectionPolicy.Inventory { .init(phase: .installed, hasWeights: true) }
private func absent() -> ModelSelectionPolicy.Inventory { .init(phase: .notInstalled, hasWeights: false) }
private func phase(_ phase: ModelInstallState.Phase, weights: Bool = false) -> ModelSelectionPolicy.Inventory {
    .init(phase: phase, hasWeights: weights)
}

let selectionCases: [SelectionCase] = [
    .init(
        name: "nothing selected, one tier installed", selected: nil,
        inventory: [.small: installed(), .medium: absent(), .large: absent()], adopt: .small),
    .init(
        name: "nothing selected, only large installed", selected: nil,
        inventory: [.small: absent(), .medium: absent(), .large: installed()], adopt: .large),
    .init(
        name: "nothing selected, nothing installed", selected: nil,
        inventory: [.small: absent(), .medium: absent(), .large: absent()], adopt: nil),
    .init(
        name: "nothing selected, two installed: the user chooses", selected: nil,
        inventory: [.small: installed(), .medium: installed(), .large: absent()], adopt: nil),
    .init(
        name: "nothing selected, one installed and one downloading", selected: nil,
        inventory: [.small: installed(), .medium: phase(.downloading), .large: absent()], adopt: .small),
    .init(
        name: "nothing selected, one installed and one failed", selected: nil,
        inventory: [.small: installed(), .medium: absent(), .large: phase(.failed)], adopt: .small),
    .init(
        name: "the selection is installed", selected: .small,
        inventory: [.small: installed(), .medium: absent(), .large: absent()], adopt: nil),
    .init(
        name: "the selected tier was deleted, one left", selected: .medium,
        inventory: [.small: installed(), .medium: absent(), .large: absent()], adopt: .small),
    .init(
        name: "the selected tier was deleted, two left", selected: .large,
        inventory: [.small: installed(), .medium: installed(), .large: absent()], adopt: nil),
    .init(
        name: "the selected tier is downloading", selected: .medium,
        inventory: [.small: installed(), .medium: phase(.downloading), .large: absent()], adopt: nil),
    .init(
        name: "the selected tier is paused", selected: .medium,
        inventory: [.small: installed(), .medium: phase(.paused), .large: absent()], adopt: nil),
    .init(
        name: "the selected tier was interrupted", selected: .medium,
        inventory: [.small: installed(), .medium: phase(.interrupted), .large: absent()], adopt: nil),
    .init(
        name: "the selected tier failed", selected: .medium,
        inventory: [.small: installed(), .medium: phase(.failed), .large: absent()], adopt: nil),
    .init(
        name: "the selected tier waits for its Core ML encoder", selected: .medium,
        inventory: [.small: installed(), .medium: phase(.notInstalled, weights: true), .large: absent()], adopt: nil),
    .init(
        name: "the selected tier is not in the inventory", selected: .large,
        inventory: [.small: installed()], adopt: .small),
    .init(name: "an empty inventory", selected: nil, inventory: [:], adopt: nil),
    .init(
        name: "a row that still says installed after a purge removed its weights", selected: nil,
        inventory: [.small: absent(), .medium: phase(.installed, weights: false), .large: absent()], adopt: nil),
    .init(
        name: "mid-purge: the stale row does not count as a second installed tier", selected: nil,
        inventory: [.small: installed(), .medium: phase(.installed, weights: false), .large: absent()], adopt: .small),
]

@Suite struct ModelSelectionPolicyTests {
    @Test(arguments: selectionCases)
    func adoptsOnlyALoneInstalledTier(_ scenario: SelectionCase) {
        #expect(
            ModelSelectionPolicy.tierToAdopt(selected: scenario.selected, inventory: scenario.inventory)
                == scenario.adopt)
    }

    @Test(arguments: ModelTier.allCases)
    func theAdoptedTierIsNeverAlreadySelected(_ tier: ModelTier) {
        let inventory = Dictionary(
            uniqueKeysWithValues: ModelTier.allCases.map { ($0, $0 == tier ? installed() : absent()) })
        #expect(ModelSelectionPolicy.tierToAdopt(selected: nil, inventory: inventory) == tier)
        #expect(ModelSelectionPolicy.tierToAdopt(selected: tier, inventory: inventory) == nil)
    }
}
