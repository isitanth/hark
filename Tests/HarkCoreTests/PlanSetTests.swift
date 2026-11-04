import Foundation
import HarkCore
import Testing

private func decode(_ reply: String, finish: String? = "stop") -> Result<PlanSet, PlanDefect> {
    PlanSet.decode(reply, finishReason: finish)
}

private let item = #"{"understood":"a","formula":"C1","unit":"none"}"#

/// The plan of one to three results (M14, plan §4.1): `multi.py`'s `decode_set` and its selftest shapes.
@Suite struct PlanSetTests {
    @Test func anArrayOfOneDecodes() throws {
        let set = try decode(
            #"{"results":[{"understood":"a","formula":"SUM(C1, C2)","unit":"EUR","unit_label":""}]}"#
        ).get()
        #expect(set.results == [CalculationPlan(understood: "a", formula: "SUM(C1, C2)", unit: .eur)])
    }

    @Test func threeResultsDecodeInTheModelsOrder() throws {
        let reply = """
            {"results": [
              {"understood": "one", "formula": "C1", "unit": "EUR", "unit_label": ""},
              {"understood": "two", "formula": "C2", "unit": "count", "unit_label": ""},
              {"understood": "three", "formula": "C3", "unit": "none", "unit_label": "To"}
            ]}
            """
        let set = try decode(reply).get()
        #expect(set.results.map(\.understood) == ["one", "two", "three"])
        #expect(set.results.map(\.unit) == [.eur, .count, .none])
        #expect(set.results[2].unitLabel == "To")
    }

    @Test func todaysFlatObjectIsAPlanOfOne() throws {
        let set = try decode(item).get()
        #expect(set.results == [CalculationPlan(understood: "a", formula: "C1", unit: .none)])
    }

    @Test func aFencedSetDecodes() throws {
        let set = try decode("```json\n{\"results\":[\(item)]}\n```").get()
        #expect(set.results.count == 1)
    }

    @Test func anItemMayOmitItsUnitLabel() throws {
        #expect(try decode(#"{"results":[\#(item)]}"#).get().results[0].unitLabel == "")
    }

    @Test(arguments: [
        #"{"results":[]}"#,
        #"{"results":[\#([String](repeating: item, count: 4).joined(separator: ","))]}"#,
        #"{"results":[{"understood":"a","formula":"C1","unit":"none","x":""}]}"#,
        "prose",
        #"{"results":[{"understood":"a","formula":"C1","unit":"JPY"}]}"#,
        #"{"results":[],"more":1}"#,
        #"{"results":[\#(item)],"more":1}"#,
        #"{"results":\#(item)}"#,
        #"{"results":"C1"}"#,
        #"{"results":[["C1"]]}"#,
        #"{"results":[{"understood":"a","formula":3,"unit":"none"}]}"#,
        #"{"results":[{"understood":"a","unit":"none"}]}"#,
        #"[\#(item)]"#,
        #"{"understood":"a","formula":"C1"}"#,
    ])
    func anyOtherShapeIsJSON(_ reply: String) {
        #expect(decode(reply) == .failure(.json))
    }

    @Test func aCutReplyIsTruncatedBeforeAnythingElse() {
        #expect(decode(#"{"results":[\#(item)]}"#, finish: "length") == .failure(.truncated))
        #expect(decode("prose", finish: "length") == .failure(.truncated))
    }

    @Test func oneBadItemRefusesTheWholeSet() {
        let reply = #"{"results":[\#(item),{"understood":"b","formula":"C2","unit":"none","kind":"x"}]}"#
        #expect(decode(reply) == .failure(.json))
    }

    @Test func everyParityReplyDecodesAsTodaysPlan() {
        var replies = 0
        for parityCase in MathFixtures.parity {
            for row in parityCase.rows {
                let today = CalculationPlan.decode(row.reply, finishReason: "stop").map { PlanSet(results: [$0]) }
                #expect(decode(row.reply) == today, "\(parityCase.id)")
                replies += 1
            }
        }
        #expect(replies >= 43)
    }

    @Test(arguments: MathFixtures.golden)
    func everyGoldenReplyDecodesAsAPlanOfOne(_ golden: MathFixtures.GoldenCase) throws {
        for reply in [golden.exact, golden.plain] {
            let today = try CalculationPlan.decode(reply, finishReason: "stop").get()
            #expect(try decode(reply).get().results == [today])
        }
    }
}
