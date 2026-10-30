import Foundation
import HarkCore
import Testing

@Suite struct PlanSchemaTests {
    private func object() throws -> [String: Any] {
        let data = try #require(CalculationPlan.schema.json.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The fixture is the frozen `plan-schema.json` (SHA-256 d4e2d2ed…) with `unit_label` added last for 0.1.0, as
    /// `json.dumps(…, ensure_ascii=False, indent=2)` writes it; the frozen file stays as measured.
    @Test func theSchemaIsTheFixtureByteForByte() throws {
        #expect(CalculationPlan.schema.name == "plan")
        #expect(CalculationPlan.schema.json == (try MathFixtures.text("plan-schema.json")))
    }

    @Test func theUnitLabelIsAPlainString() throws {
        let properties = try #require(try object()["properties"] as? [String: [String: Any]])
        #expect(properties["unit_label"]?["type"] as? String == "string")
        #expect(properties["unit_label"]?.count == 1)
    }

    @Test func itUsesOnlyEveryEnforcersSubset() throws {
        let allowed: Set<String> = ["type", "properties", "required", "enum", "additionalProperties"]
        let schema = try object()
        #expect(Set(schema.keys).isSubset(of: allowed))
        #expect(schema["additionalProperties"] as? Bool == false)
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        for property in properties.values { #expect(Set(property.keys).isSubset(of: ["type", "enum"])) }
        #expect(schema["required"] as? [String] == ["understood", "formula", "unit", "unit_label"])
    }

    @Test func understoodComesFirst() throws {
        let json = CalculationPlan.schema.json
        let order = ["\"understood\"", "\"formula\"", "\"unit\"", "\"unit_label\""].compactMap {
            json.range(of: $0)?.lowerBound
        }
        #expect(order.count == 4 && order == order.sorted())
    }

    @Test func theEnumIsTheResultUnits() throws {
        let properties = try #require(try object()["properties"] as? [String: [String: Any]])
        #expect(properties["unit"]?["enum"] as? [String] == ResultUnit.allCases.map(\.rawValue))
    }
}
