# incitez architecture: why the VM, and how it works

This documents the load-bearing design decision of incitez — *the matcher is
a reporter-anchored pattern VM, not a regex engine* — and the dual-engine
harness that keeps it honest. Written to answer "why is this fast?" and "why
two engines?" for the next reader.

## The two engines, and why there are two

incitez has two interchangeable citation-finding implementations behind one
`Engine` enum (`src/extract.zig`):

- **`.vm` — the product.** A reporter-anchored bounded-backtracking pattern
  VM. This is what ships; it is ~50× faster than eyecite (measured, see
  `BENCHMARKS.md`).
- **`.pcre2` — the oracle.** eyecite's regexes, *verbatim*, run through
  PCRE2. It exists only at test time, as an independent second
  implementation to check the VM against.

They are a maker/checker pair. The VM is clever and fast; the PCRE2 path is
deliberately dumb and literal. Their value is precisely that they share *no*
matching machinery, so when they agree (and both agree with the pinned
eyecite oracle over its own corpus), the agreement means something. See the
MFIC discipline in the canonical brief: *if the same author wrote both the
check and the thing checked, could it pass with wrong work?* The PCRE2
oracle stays literal forever for this reason — independence over elegance.
**Do not optimize the oracle.** Its speed is irrelevant by design; making it
clever taints the one property it exists to provide.

## Raison d'être of the VM

eyecite's model: ~1,400 reporter editions, each with one or more regex
templates (default `volume reporter,? page`), all wrapped in non-alphanumeric
boundaries. Naively, that is ~5,600 regexes. eyecite runs them via a
pyahocorasick *prefilter* — a prefix automaton that finds which editions'
strings appear in the text, then runs only those editions' full regexes over
the whole text. Even so, the Python object churn and per-occurrence
re-scanning dominate.

The insight: **a citation is anchored by its reporter string.** "1 U.S. 1"
cannot exist without "U.S." present at a known offset. So instead of asking
each pattern "do you appear anywhere?", we scan once for reporter *anchors*
and verify a citation *locally* around each hit. No pattern ever re-scans the
whole document.

## M.O. — how the VM matches (`src/extract.zig`, `src/reporters.zig`)

Three layers, cheapest first:

1. **First-byte gate** (`firstByteCandidate`). A 256-bit set
   (`tables.key_first_bytes`, four `u64`s) of every byte that could start a
   reporter key. One bit test per input byte rules out the vast majority of
   positions in O(1). This is the regex engine's first-char discrimination,
   precomputed.

2. **Anchor lookup** (`reporters.lookup`, `bestMatchAt`). At a surviving
   position, probe longest-key-first; each probe is a binary search over the
   `match_table` — a single sorted array of every reporter abbreviation and
   spelling variant, each pointing at its edition. O(max_key_len · log n).
   The sorted array *is* a serialized prefix structure (see "Why fast"
   below); binary search over it is prefix discrimination without a separate
   automaton.

3. **Local verify** (`tryProgram`, `matchSeq`/`run`). For each candidate
   edition, run its compiled *programs* around the anchor. A program is split
   at the reporter into PRE (must consume exactly up to the anchor — this is
   what pins "volume" to immediately precede "U.S.") and POST (continues
   after). The interpreter is a bounded-backtracking VM over a tiny
   instruction set — `lit`, `class` (256-bit set + min/max count), `open`/
   `close` capture, ordered `alt`, `opt` — with a fixed frame-stack depth
   guard. **There is no general regex engine in the core.** It runs over a
   few dozen bytes around each anchor, never the whole document.

Metadata (year, court, pin cite, parenthetical, case names, resolution) is a
second pass over the found citations — see `finishCitation` and the
per-type finishers. Both engines converge into that shared pass, so they are
compared on identical downstream logic.

## Build-time codegen (`tools/gen_tables.zig`)

The VM's instruction programs and the match table are generated at build
time from the vendored reporters-db / courts-db / journals.json / laws.json,
mirroring eyecite's own extractor construction:

- regexes.json variables are flattened and fixpoint-expanded exactly like
  `reporters_db.utils.process_variables` (the `_optional` rule, the `$page`
  and `$full_cite` overrides);
- each edition's templates are compiled by a **strict, closed-vocabulary
  regex-subset parser** into PRE/POST instruction programs;
- anything outside the supported subset (an unrecognized construct, an
  unresolved `$variable`, a dangling variation) **aborts the build**. Upstream
  data drift is loud, never silent — re-vendoring new data either compiles or
  fails the build with the exact byte offset.

The same pass also emits the eyecite-literal extractor strings the PCRE2
oracle consumes, so the two engines are generated from one source of truth
but share no *matching* code.

## Why it's fast — and the prior art

The VM is **the trie idea taken to its conclusion.** Factoring a flat
alternation of literals (`U.S.|U. S.|US`) into shared-prefix form is, by its
established names: *left / alternation factoring*; the artifact is a **trie**;
generalized to share suffixes too, the **minimal DFA / DAWG**. DFA-based
engines (RE2, Rust `regex`, Hyperscan) subsume this entirely; Perl's
`Regexp::Assemble` / `Regexp::Trie` and Perl 5.10+'s in-engine TRIE node, and
Python's `trieregex`, do it explicitly. PCRE2 deliberately does *not* —
ordered-alternation semantics are observable (captures, `(*MARK)`), so
auto-rewrite is unsafe, and its perf budget went to JIT instead.

incitez doesn't build a regex trie; it builds the **sorted match table**,
which is the same prefix-discrimination as a sorted array + binary search,
plus the first-byte bitset as a one-instruction prefilter. The result beats
even an optimally combined alternation regex, because:

- a combined regex still touches every byte and pays general-engine overhead
  at each candidate; the bitset gate + binary-search anchor does strictly
  less work, and the bounded pattern-VM runs only at real reporter hits;
- eyecite's ahocorasick prefilter finds which editions *could* match, then
  re-scans the whole text with each one's regex; the VM verifies locally and
  never re-scans.

The flat templates in reporters-db stay the human-maintained **source**; the
generated tables and programs are the **artifact** — never hand-edited, and
the generator gets a free exhaustive equivalence check against the finite
edition list (a misplaced character would drop a reporter, and the corpus +
differential gate would catch it).

## Honest edges

- **Adjacent same-reporter citations** separated by a *single* boundary char:
  eyecite's `finditer` (and our literal PCRE2 path) consume the trailing
  boundary, starving the next match's leading boundary, and drop it. The VM
  resumes after the citation core, keeps the separator, and finds all of
  them — arguably *more* correct (all are real citations). This only arises
  in synthetic concatenation; real prose separates citations with more than
  one character. Pinned by `tests/` and documented; see the seam test.
- **Spans are byte offsets** (what FFI/C consumers index with), not Python
  code-point offsets; the acceptance/differential drivers convert.
- The PCRE2 oracle's cruder "all-extractors + merge" loses some of eyecite's
  nominative-reporter overlap resolution, so on pathological adjacency it
  diverges from *both* the VM and eyecite more than they diverge from each
  other. Expected; it is the dumb checker, not the product.
