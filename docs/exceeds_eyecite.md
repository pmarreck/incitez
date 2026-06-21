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

## 4. Glued volume↔reporter (OCR-dropped space: `116U. S.`)

**eyecite:** its full-citation regex requires whitespace between the volume and the
reporter (`$volume $reporter`), so when OCR drops that space — `116U. S.` for `116 U. S.`,
a common scanned-text artifact — eyecite finds **nothing**. Verified: 0 citations on
`Boyd v. United States, 116U. S. 616 (1886)`.

**incitez:** makes that one space optional (`$volume ?$reporter`), recovering glued forms:
`116U. S. 616` → `116 U.S. 616`. Verified on the Mapp v. Ohio demo (three glued forms,
`116`/`168`/`364 U. S.`, all recovered). It stays **citation-aware** — a *known* reporter
must still anchor the match, so `401k` / `3D` / `5G` never become citations — and
**span-correct** (no text rewrite; the span points at the original glued bytes), so the
differential holds **215/215** and the change costs ~1%.

*Tests: "glued volume-reporter is recognized" + "relaxed volume-reporter boundary does NOT
create false citations" in `src/extract.zig`. Reported by incitez_web from a real OCR'd brief.*

## 5. Section-markerless federal statutes (`42 CFR 488.5`, `31 U.S.C. 9701`)

Federal agencies and the Federal Register routinely drop the `§`/`sec.` marker,
writing `42 CFR 488.5`, `31 U.S.C. 9701`, `10 CFR 171.16(c)`. eyecite requires the
marker by grammar, so to it these are **not citations**. Verified against the live
oracle:

| input | eyecite | incitez |
|---|---|---|
| `42 CFR 488.5(a)(4)(i)` | 0 cites | FullLawCitation — title 42, § 488.5 |
| `31 U.S.C. 9701` | 0 cites | FullLawCitation — title 31, § 9701 |
| `10 CFR 171.16(c)` | 0 cites | FullLawCitation — title 10, § 171.16 |
| `31 U.S.C. § 9701` | 1 cite | 1 cite — unchanged (parity preserved) |

**incitez:** emits an *additional* no-marker program for the federal statute /
regulation reporters (U.S.C., C.F.R. and their variations `USC`/`CFR`/…) with the
`§`/`sec.` made optional. It stays **citation-aware and false-positive-safe**: a
*known* federal reporter (`U.S.C.`/`CFR`) must anchor the match — so a case
reporter (`5 U.S. 137`) is never mistaken for a statute — and the section must be
**digit-leading** (`$law_section`), so a regulation-part list
(`10 CFR Parts 15, 170, and 171`) and prose (`Title 42 CFR was amended`) never
become citations. The marker-bearing form is untouched, so the differential holds
**215/215, 0 unfenced** (the marker-free corpus never triggers it). This is what
lets statute deep-links (title/section → Cornell LII) work on federal/agency text,
where the markerless style dominates: on incitez_web's two Federal Register demos
it recovers **+21 and +36** statute cites (raw 35→56, 29→65) that were previously
invisible to both engines.

*Tests: "no-marker federal statute surpass: positives extract with title/section"
+ "… negatives do NOT false-match" (set-based classifier tests) in
`src/extract.zig`; implemented as a bare-optional codegen transform in
`tools/gen_tables.zig`. Motivated by incitez_web's Federal Register demo files.*

## 6. Antecedent short-form statutes (`Id. § 1985` after `42 U.S.C. § 1983`)

Legal writing cites a statute in full once, then refers to further sections by a
bare `§ N` ("...under 42 U.S.C. § 1983. Id. § 1985."). eyecite has **no**
short-form law citation: a reporter-less `§ N` becomes an `UnknownCitation` and its
number is dropped (verified against the live oracle; tracked upstream as
[eyecite #299](https://github.com/freelawproject/eyecite/issues/299), which the
maintainer confirmed is an unaddressed limitation, not a deliberate choice).

**incitez:** resolves the bare `§ N` to a new `ShortLawCitation` that **inherits the
title + reporter** of the most recent `FullLawCitation` in scope, capturing the
section (and any subsection as the pin cite). So `Id. § 1985` after `42 U.S.C. §
1983` yields `title 42 · U.S.C. · § 1985` — enough to deep-link it (Cornell LII)
exactly like a full statute cite.

This is the one place where exceeding eyecite required **respecting** a real
ambiguity rather than charging through it (Chesterton's Fence): an *isolated* `§ N`
genuinely cannot name its code, so incitez deliberately keeps eyecite's
`UnknownCitation` there. The context that makes a bare `§` linkable is an
**antecedent** law cite — and it must be a *law* one. The rule: statute context
persists through `id.` tokens (the canonical `Id. § N` bridge), but **any
intervening case / journal / reference / supra citation clears it**, so a `§` after
a *case* cite, or with no law antecedent at all, stays `UnknownCitation`. That keeps
the eyecite **parity floor** for the ambiguous cases (differential still **215/215,
0 fenced** — the marker-free corpus has no antecedent-§ to trigger it) while
surpassing on the resolvable ones.

*Tests: "law short-form: bare § after a full law cite inherits title + reporter" +
"law short-form parity: isolated bare § stays unknown" (set-based: antecedent
upgrades, isolated/case-antecedent stay unknown) in `src/extract.zig`. Design from
the Chesterton's-Fence research in `principled_divergences.md §6`.*

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
