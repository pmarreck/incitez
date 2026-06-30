# Future Directions

Bigger, not-yet-scheduled improvement ideas for incitez — the *why* and the
*shape*, not a task tracker. Active, scoped work lives in `PLAN.md`; this file is
the longer-horizon "someday / when unblocked" index. Each entry notes its trigger
or gate so it surfaces when the time is right.

## Post-OCR citation-token correction (gated on docscan consensus-OCR)

**Idea:** when incitez's input came from OCR (a scanned PDF via docscan), citation
tokens are frequently mangled in characteristic ways — `U.S.` → `U.8.`, `v.` → `»`,
dropped spaces (`116U. S.`), `§` → `8`/`S`. A post-OCR correction pass could
recognize a *near-miss* of a known citation shape (a reporter token one edit away
from a real reporter, a volume-reporter-page skeleton with an OCR-plausible
substitution) and repair it before/within extraction, recovering citations that
are currently lost to OCR noise.

**Why it's gated, not done now:** naive client-side *re-OCR* of the page is NOT a
clear win — it regresses as often as it helps (measured: re-OCR of Library of
Congress scans turned clean `U.S.`→`U.8.` and `v.`→`»`; see memory
`project-incitez-web-tesseract-reocr-probe`). The promising path is **docscan's
consensus-OCR** (multiple OCR engines/passes voting → a per-token confidence
signal), which is queued in docscan but not yet shipped. With a confidence signal
incitez could correct *low-confidence* tokens toward the nearest valid citation
shape (a constrained, reporter-anchored edit) instead of blindly rewriting text.

**Shape when unblocked:**
- Pure function over (text, optional per-token confidence) → corrected text +
  an offset map back to the original bytes (same `Breakpoint` contract as
  `src/clean.zig`), so spans still point at the real source.
- Reporter-anchored and edit-bounded: only repair a token that is ≤1–2 edits from
  a *known* reporter/marker AND completes a citation skeleton — never free-form
  rewriting. Differential-fence any new finds; treat as an additive surpass.
- **Trigger:** docscan ships consensus-OCR with a confidence/voting output.
  (Tracked as task #27.)

## Resolve supra lookup — O(supras × fulls) residual

The short-form (`ShortCaseCitation`) exact-duplication quadratic was **fixed**
(task #17, 2026-06-30): `full_case` cites are bucketed by (corrected_reporter,
volume) with a single-resource short-circuit, so the dominant repeated-citation
case resolves in O(1) — see the `resolveShort` doc-comment in `src/resolve.zig`.

The remaining linear scan is `resolveSupra` → `filterByAntecedent`, which matches a
supra cite's antecedent name as a substring of every full cite's party names. It
can't reuse the (reporter, volume) bucket — a supra has no volume — so it stays
O(supras × fulls); report-only in the scaling gate, and supra cites are far rarer
than shorts in real text. A future fix would index full cites by party-name tokens
(an inverted index) to prune candidates before the substring check.
