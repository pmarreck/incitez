# incitez per-key-function microbenchmarks

Hardware-keyed history of each extraction **phase** measured in isolation by
`incitez-bench micro` (driven by `./bm` Section 3). CLAUDE.md mandates
benchmarking "over key functions" and LOUDLY flagging sudden deltas — a single
end-to-end number once hid a `referenceScan` O(cites×text) quadratic until it
dominated runtime. `./bm` two-sided-gates each phase (±25%) against the most
recent entry below for the same hardware. Rerunning is implicit acceptance of a
new baseline.

Phases: `match` (vmScan+tokenScan+merge), `finish` (case-name walk + metadata),
`reference` (pincited-reference scan), `filter` (overlap dedup), `resolve`
(short/supra/id linking), `total` (end-to-end).

