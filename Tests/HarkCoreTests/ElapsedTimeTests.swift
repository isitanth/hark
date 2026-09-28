import HarkCore
import Testing

@Suite struct ElapsedTimeTests {
    @Test(arguments: [
        (0, "0:00"), (-5, "0:00"), (999, "0:00"), (1_000, "0:01"), (59_999, "0:59"), (60_000, "1:00"),
        (599_999, "9:59"), (600_000, "10:00"), (1_799_999, "29:59"), (1_800_000, "30:00"),
        // The format does not clamp: a longer capture limit still reads right.
        (3_600_000, "60:00"),
    ])
    func text(milliseconds: Int, expected: String) {
        #expect(ElapsedTime.text(milliseconds: milliseconds) == expected)
    }
}
