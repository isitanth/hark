import Foundation
import HarkCore
import Testing

@Suite struct PlanSchemaTests {
    private func object() throws -> [String: Any] {
        let data = try #require(CalculationPlan.schema.json.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// One result's object, under `results.items`.
    private func item() throws -> [String: Any] {
        let properties = try #require(try object()["properties"] as? [String: [String: Any]])
        return try #require(properties["results"]?["items"] as? [String: Any])
    }

    /// The fixture is M14.0's measured `plan-schema-m14.json` (SHA-256 4c6da70c…), as `json.dumps(…, indent=2)` writes
    /// it; its item is 0.1.0's schema, the frozen `plan-schema.json` with `unit_label` added last.
    @Test func theSchemaIsTheFixtureByteForByte() throws {
        #expect(CalculationPlan.schema.name == "plan")
        #expect(CalculationPlan.schema.json == (try MathFixtures.text("plan-schema.json")))
    }

    @Test func theUnitLabelIsAPlainString() throws {
        let properties = try #require(try item()["properties"] as? [String: [String: Any]])
        #expect(properties["unit_label"]?["type"] as? String == "string")
        #expect(properties["unit_label"]?.count == 1)
    }

    /// Today's keywords, plus `items` and the type `array` under `results` only: no `minItems` or `maxItems`.
    @Test func itUsesOnlyEveryEnforcersSubset() throws {
        let allowed: Set<String> = ["type", "properties", "required", "enum", "additionalProperties"]
        let schema = try object()
        #expect(Set(schema.keys).isSubset(of: allowed))
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == ["results"])
        let top = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(Set(top.keys) == ["results"])
        #expect(Set(try #require(top["results"]).keys) == ["type", "items"])
        #expect(top["results"]?["type"] as? String == "array")
        let item = try item()
        #expect(Set(item.keys).isSubset(of: allowed))
        #expect(item["additionalProperties"] as? Bool == false)
        let properties = try #require(item["properties"] as? [String: [String: Any]])
        for property in properties.values { #expect(Set(property.keys).isSubset(of: ["type", "enum"])) }
        #expect(item["required"] as? [String] == ["understood", "formula", "unit", "unit_label"])
    }

    @Test func understoodComesFirst() throws {
        let json = CalculationPlan.schema.json
        let order = ["\"results\"", "\"understood\"", "\"formula\"", "\"unit\"", "\"unit_label\""].compactMap {
            json.range(of: $0)?.lowerBound
        }
        #expect(order.count == 5 && order == order.sorted())
    }

    @Test func theEnumIsTheResultUnits() throws {
        let properties = try #require(try item()["properties"] as? [String: [String: Any]])
        #expect(properties["unit"]?["enum"] as? [String] == ResultUnit.allCases.map(\.rawValue))
    }
}
