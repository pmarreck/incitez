# Where incitez exceeds eyecite

incitez's thesis is **meet AND surpass** eyecite. The *meet* bar is a live
differential gate: every push compares incitez against the pinned eyecite oracle
over its full ported corpus, and they must agree **215/215, 0 fenced** — that
parity is the trust anchor that makes every claim below believable. This document
catalogs the *surpass*: cases where eyecite is demonstrably wrong (verified
against the live oracle) and incitez is more correct.

Each entry is **additive**: identical to eyecite on the inputs the corpus
exercises (so the 215/215 gate is never spent), diverging only where eyecite
errs. Details + the pinning tests live in `docs/principled_divergences.md`.

---

## 1. En-dash / em-dash page ranges in pin cites

**eyecite:** parses pin-cite page ranges only with an ASCII hyphen-minus; a real
en-dash (`–`, U+2013) or em-dash range — common in typeset opinions — is dropped.

**incitez:** recovers en/em-dash pin ranges (e.g. `530 U. S. 238, 241–242
(2000)` → `pin_cite: "241–242"`). Found in the wild on *Cunningham v. Cornell
Univ.* (2025). eyecite's corpus is hyphen-only, so the gate stays 215/215.

*Details: principled_divergences.md §3. Tests: `tests/realworld/`, en-dash unit test.*

## 2. Structural-newline boundaries in the case-name walk

**eyecite:** treats every `\n` as ordinary whitespace and walks *through* it, so
a section heading on the line above a citation bleeds into the party name
(`TABLE OF AUTHORITIES Cases Albritton v. Gandy …` → plaintiff `"TABLE OF
AUTHORITIES Cases Albritton"`). The universal `clean_text(['all_whitespace'])`
preprocessing makes this worse by destroying the boundary signal.

**incitez:** when the input carries a structural newline (docscan emits a lone
`\n` only at a real boundary; intra-paragraph wraps are joined to spaces), the
case-name walk-back treats it as a **hard stop** — the heading is excluded
(`DISCUSSION\nSmith Co., 1 U.S. 1` → `defendant: "Smith Co."`). incitez consumes
the preserved structure rather than re-deriving it; eyecite structurally cannot
do this without losing source offsets.

**Verified end-to-end (2026-06-15, real Brann appellate brief):** docscan's
`splitToAHeaders` now emits a lone `\n` after ToA section headers, so the extract
reads `… TABLE OF AUTHORITIES\nCases\nAlbritton v. Gandy, 531 So. 2d 381 …`. On that
exact pipeline output incitez yields plaintiff **`"Albritton"`**, while the live
eyecite oracle yields **`"Cases\nAlbritton"`** — it keeps the heading *and* the
literal newline. (1 of 348 cites in the brief; full docscan→incitez pipeline.)

*Details: principled_divergences.md §4. Contract: CITATION_PIPELINE_RESPONSIBILITIES.md.
Test: "structural newline is a hard walk-back stop".*

## 3. Leading Bluebook signals (Compare / Accord / Contra / Consider …)

**eyecite:** filters the support signals `See`, `Cf.`, `See also`, but **not**
the comparison/contradiction signals `Compare`, `Accord`, `Contra` (nor
`Consider`) — it leaves them glued to the plaintiff (`Compare Gideon v.
Wainwright` → plaintiff `"Compare Gideon"`). It also over-strips: a signal word
*embedded in a real party name* gets removed, and it drops a leading single
letter (`I See Deadpeople v. State` → `"Deadpeople"`, losing both the inner
`See` and the `I`).

**incitez:** strips the full introductory-signal set, but **leading-position
only** — using capitalization + position as the signal:
- `Compare Gideon v. Wainwright` → `"Gideon"` (leading signal removed).
- `I See Deadpeople v. State of California` → `"I See Deadpeople"` (the embedded
  `See` survives; the leading `I` is kept — **incitez beats eyecite on both**).
- `Accord v. Honda` → `"Accord"` (a litigant literally named a signal word,
  sitting right before `v.`, is the party, not a signal — empty-guard).

Bounded heuristic, not full grammar parsing — it raises the bar without
pretending to parse English. Additive: the marker-free corpus has no leading
signals eyecite handles differently, so the gate stays 215/215.

*Details: principled_divergences.md (signal stripping). Test: "leading Bluebook
signals stripped, embedded ones kept".*

---

## Also more correct, by reasoned choice (not strictly "vs eyecite errors")

- **Adjacent same-reporter citations** — incitez finds all of them; eyecite's
  finditer starves the middle one (principled_divergences.md §1).
- **Performance** — not a correctness surpass, but incitez runs the same corpus
  1–2 orders of magnitude faster, and stays sub-quadratic under a machine-
  independent scaling gate (`tests/scaling`) that eyecite has no equivalent of.

## How a new surpass earns a place here

1. Reproduce the eyecite behavior against the **live** oracle (not from memory).
2. Confirm incitez is more correct, and that the fix is **additive** — the
   differential gate stays 215/215 (or the corpus divergence is fenced + reasoned).
3. Pin it with a characterization test and document it in
   `principled_divergences.md`; add a one-paragraph entry here.
