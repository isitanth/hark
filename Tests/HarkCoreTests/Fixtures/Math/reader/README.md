# Recorded reader cases

One file per case of the visual-math measurement (2026-10-26), for `SheetBuilderParityTests` and
`RegionReaderTests`. The documents are fictional: invented names, amounts and addresses, rendered for the measurement.
No image is stored here.

They come from one Vision run, tag `v2f` (run_v2f.py), and its derived `v2f-rows` and `v2f-rows-codes`
(rows_for_lines.py, glyph_codes.py), never mixed with another run. A local converter, outside the repo, wrote them
offline on 2026-10-29 at commit 03b642b; no Vision and no model call.

Each file holds:

- `document`: what the document request gave, before any step: tables with their box and cells (`r`, `c`, `rs`, `cs`,
  `transcript`, `box`, `lines`), and every line of the image. A cell the prototype split by lines is regrouped, its
  transcript the lines joined by `\n`, its box their union.
- `crops`: every crop read the ladder asks for, by box and rung (0 to 3 of `Rung.ladder`): the rejected reads, then
  the accepted one. For the code letters (R8), the read that won, at the first rung, and a blank read for the others.
- `spans`: `harness.amount_spans` for every item text holding two amounts or more, in Unicode scalar offsets.
- `expected`: each item's ID, text, table, row, column and uncertain flag; the listing the harness numbered without
  splitting on amounts (`listing`, as recorded) and with it (`splitListing`).

Boxes are normalized to the region, top-left origin, rounded to 1e-4 as the prototype recorded them.
