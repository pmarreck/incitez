# Principled divergences from eyecite

incitez's goal is to **meet and surpass** eyecite — not to clone it. The
differential gate (`scripts/differential`) enforces *meet*: 100% agreement
with the pinned live eyecite oracle across its entire corpus. This document
records where incitez intentionally **diverges to be more correct**, or
deliberately **matches eyecite's effective output for a reasoned correctness
verdict** rather than by reflex.

The rule, stated once:

> **Obvious correctness + companion documentation > bug-matching.** When
> eyecite has an obvious upstream bug, we do the correct thing and explain
> why — we do not silently replicate the bug. When eyecite's *output* is
> correct even though its *internals* are buggy, we match the output and say
> so, so a future reader doesn't "fix" us into eyecite's mistake.

This is distinct from the differential **fence ledger**
(`tests/expected_divergences.json`), which tracks *not-yet-ported* gaps and is
currently **empty** (full type parity). A divergence here is a *choice*, not
a gap. If a divergence ever shows up against a real corpus text, it gets a
fence with reason `principled: …` pointing here; today the known cases are
exercised by dedicated tests instead, because eyecite's own corpus does not
contain the triggering inputs.

---

## 1. Adjacent same-reporter citations — incitez is MORE correct (we diverge)

**eyecite:** drops a citation. When two citations with the same reporter are
packed back-to-back separated by a *single* boundary character, Python
`finditer` (and our literal PCRE2 oracle) consume the trailing boundary of
one match, which starves the next match's required leading boundary, so the
middle citation is silently lost.

**incitez VM:** finds all of them. The VM checks the boundary but resumes
scanning at the citation core, leaving the separator available for the next
match.

**Verdict: incitez is more correct.** Every one of those citations is real.

**Scope:** only triggers under single-character separation, which synthetic
concatenation produces but real legal prose (sentences, `"; "` between cites)
does not — which is why the differential gate over eyecite's corpus shows
0 divergences. Pinned by the `seam:` tests in `src/extract.zig` and described
in `docs/architecture.md` → Honest edges.

---

## 2. Attorney-General surname exclusion — eyecite's bug is accidentally CORRECT (we match, with reasoning)

**eyecite:** `is_valid_name` rejects reference anchors whose name is in
`DISALLOWED_NAMES`. That list has two parts: a handful of lowercase common
words (`state`, `united states`, `people`, `commonwealth`, `mass`) that work,
and ~80 Attorney-General surnames (`Ashcroft`, `Barr`, `Kennedy`, `Smith`, …)
that **do not** — they are stored capitalized but compared against
`name.lower()`, so they never match. The entire AG list is dead code.

**eyecite's evident intent:** exclude those common surnames so a reference
like `Smith at 5` isn't generated for an ambiguous-but-common name.

**incitez:** matches eyecite's *effective* behavior — we do **not** exclude
the AG surnames — but as a *reasoned* choice, not blind replication:

- reference extraction already **requires a pin cite** (`Smith at 5`, never a
  bare `Smith`) and the name must come from an actually-cited case's party, so
  the false-positive risk the list guards against is largely controlled;
- **activating the exclusion would drop real references** —
  `Smith v. Jones, 1 U.S. 1 … Smith at 5` is a genuine reference to that case,
  and excluding `Smith` would be a false negative.

**Verdict: here the obvious bug accidentally produces the more-correct
output (extract the reference); eyecite's intent is the worse behavior.** So
being more correct means *matching* eyecite's effective output, not diverging
from it. We implement only the working lowercase set (the inert
`commissionerakerman` concatenation artifact can never match a real
name, so it is dropped rather than carried as noise). See `isDisallowedName` in `src/extract.zig`.

---

## Audit note

Other eyecite quirks incitez replicates are *legitimate behavior*, not bugs,
and are matched deliberately (the differential gate validates each):

- `get_court_by_paren` returns the **last** prefix match when no exact match
  exists — arbitrary but deterministic; not wrong, so matched.
- `CaseCitation.__hash__` gives a page-less citation an identity hash (never
  equal to anything) — intentional "for safety"; matched in resolution.
- Pre-citation year overrides a post-paren year — eyecite behavior, matched
  (and originally a gate-found parity fix).

If a future eyecite quirk is found to produce *wrong* output, it goes in
section 1's style (diverge + document), never silently cloned.

---

## 3. En-dash / em-dash page ranges in pin cites — incitez is MORE correct (we surpass)

**eyecite:** `PIN_CITE_REGEX` accepts only hyphen-minus (`-`) in a page range,
so a pin like `241–242` written with an **en-dash** (or `44—45` with an
em-dash) is silently dropped — the citation is found but loses its pin cite.

**incitez:** accepts hyphen-minus, en-dash (U+2013), and em-dash (U+2014) as
range separators (`pinDashLen` in `src/extract.zig`), recovering the pin.

**Verdict: incitez is more correct.** Real judicial opinions routinely
typeset page ranges with en/em-dashes; the dropped pin is real information.

**How it was found:** real-world validation on *Cunningham v. Cornell Univ.*,
No. 23-1007 (U.S. 2025) — see `tests/realworld/` and `scripts/validate-realworld`.
On that opinion incitez and eyecite otherwise agree 23/23 (identical types,
reporters, pages, years, antecedents); the only difference was the two
en-dash pins, which incitez now recovers. eyecite's own corpus uses
hyphen-minus throughout, so the differential gate stays **215/215, 0 fenced**
— a strict improvement on real text with no cost to the meet bar.

## 4. Structural-newline boundaries in the case-name walk — incitez surpasses (boundary-aware)

**eyecite's behavior:** eyecite's case-name walk-back treats every `\n` as
ordinary whitespace (`\s`). On real PDF-extracted text it therefore walks
*through* a structural newline — e.g. the line break after an all-caps section
heading — and swallows the heading into the party name. Verified against the
live oracle: `TABLE OF AUTHORITIES Cases Albritton v. Gandy, 531 So. 2d 381`
yields `plaintiff = "TABLE OF AUTHORITIES Cases Albritton"` in **both** eyecite
and (flat-text) incitez. The universal `clean_text(['all_whitespace'])`
preprocessing everyone runs makes this *worse*, not better: collapsing `\s+`→
space destroys the very newline that marked the boundary.

**incitez's behavior (the surpass):** when the input carries a structural
newline, the case-name walk-back treats a lone `\n` as a **hard stop** — a case
name may not cross a structural boundary. So the heading is excluded:
`DISCUSSION\nSmith Co., 1 U.S. 1` → `defendant = "Smith Co."` (not
`"DISCUSSION\nSmith Co."`).

**Why this is principled, not lossy guessing:** incitez does **not** re-derive
structure from flat text (that would be eyecite's ceiling). The signal comes
from upstream: **docscan** owns structure-aware extraction — it joins
intra-paragraph line-wraps to spaces (recovering ~47% recall lost to mid-token
breaks) and emits a lone `\n` *only* at a real structural boundary (heading /
paragraph / list break). incitez merely *consumes* that preserved signal. See
`CITATION_PIPELINE_RESPONSIBILITIES.md` (Peter + Einstein, 2026-06-14).

**Additive superset — the meet bar is untouched:** on **flat, marker-free text**
(no `\n`) the walk-back is byte-identical to eyecite, so the differential gate
stays **215/215, 0 fenced** (the eyecite corpus is single-line). The divergence
only appears on *structured* input, where incitez is strictly more correct than
anything that flattens-then-collapses. Pinned by the characterization test
`"case name: structural newline is a hard walk-back stop"` in `src/extract.zig`.
