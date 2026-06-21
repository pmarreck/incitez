# incitez — Plan

Spec: `docs/incitez_design.md`. Kickoff: `inbox/2026-06-11-incitez-kickoff.md` (processed).

## Direction (Peter, 2026-06-11)
The VM is the product; make it excellent. PCRE2 stays as a second oracle in the
dual-engine harness (and a possible later optimization target), but VM-first is
settled — the VM-WASM argument (no JIT needed in-browser) carried it.
Priority: correctness/parity slices first (metadata, short forms), THEN the
anchor-scan optimization (Aho-Corasick) under M4 benchmark gates.

## Status (2026-06-12) — full parity + WASM shipped
Peter opted into: docs (VM architecture.md), seam characterization test,
references, optimization pass. All DONE except the optimization pass. The WASM
artifact (M7) jumped the queue (Einstein order — it unblocked the incitez_web
team) and is now COMPLETE + pushed. **Optimization pass #4 is the active next
item** (profile-first, two-sided bm gate).

## Status snapshot (2026-06-12 ~07:40 EST)
- M1–M5 complete. Fence-closing campaign: journals, sections, laws done.
- Find corpus: **130/130** both engines. Resolution: **23/23** (full ResolveTest parity). Cross-engine: 0 divergences. Mutation: 179 texts / 176 reporter-kills. Differential gate: **215/215 agree, 0 fenced, 0 unfenced** — 100% agreement with the live eyecite oracle across ALL citation types.
- ALL citation types ported: case/short/supra/id/journal/law/section/reference. Find corpus 136/136 both engines, resolution 23/23.

## Next increment (awaiting Peter's opt-in)
- [x] References (ReferenceCitation) DONE (2026-06-12) — last 6 fences healed; **FULL eyecite type parity**, differential ledger EMPTY (215/215 agree, 0 fenced, 0 unfenced).
- [x] Optimization pass #4 DONE (2026-06-12 ~16:00 EST) — NOT the expected Aho-Corasick: per-function profiling (the matching loop was never the bottleneck) exposed **four O(n²)-on-citation-density quadratics** the whole-pipeline number hid. Fixed referenceScan (unique-name cache), filterCitations (span→last-index map — the dominant one), resolve full² (resource-key map), finishCitation (bounded span scan). **1.7MB citation-dense doc: 60s → 2.6s (23×).** Differential 215/215, ./test green. Controls added: per-key-function microbench + gate (CLAUDE.md L32), and the machine-independent **scaling-ratio gate** (`tests/scaling`, ./bm Section 4, flake `checks.scaling`) — fails any phase growing ≥2.8×/doubling; it caught the finishCitation quadratic itself.
  - Residual: resolve exact-duplication O(dups²) in resolveShort/supra (report-only in the gate, ~3% runtime, real docs fine) — tracked (task #17).
- [x] Citation pipeline slice DONE (2026-06-14 ~00:00 EST) — newline/structure handling per `CITATION_PIPELINE_RESPONSIBILITIES.md` (Peter+Einstein). incitez owns logic + span contract; docscan owns the structural signal. **THE SURPASS:** boundary-aware case-name walk-back — a lone `\n` (docscan structural marker) is a HARD antecedent stop, killing the all-caps-heading bleed that **eyecite itself gets wrong** (verified vs live oracle). Additive (marker-free corpus has no `\n` → differential 215/215, 0 fenced); principled divergence §4 + characterization test. Plus opt-in `incitez_clean` (eyecite recipe `\s+`→space + strip `__`, with offset map) for flat-text callers, and `docs/wasm_abi.md` pipeline/recipe/span-chain docs. Marker + offset-map contract agreed with docscan; they build structure-aware extraction in parallel, incitez_web composes for source-highlighting.
- [x] Statute title/section ABI bump DONE (2026-06-17 ~14:00 EST) — `FullLawCitation` now surfaces `title` + `section` (U.S.C. + C.F.R.) so incitez_web can build Cornell LII statute links (`/uscode/text/{title}/{section}`, `/cfr/text/{title}/{section}`). C.F.R.'s leading number is named `chapter` upstream but IS the Title, so `title` falls back to the `chapter` group (the title-chapter hyphenated state patterns always capture `title`, so the fallback never misfires). Subsection (e.g. `(a)(4)(B)`) stays in `pin_cite`. Exposed via JSON (native+WASM), C FFI struct, `docs/wasm_abi.md §6`. Differential **215/215** intact (title/section excluded from COMPARED_FIELDS; statute volume/page stay null = eyecite parity); `./bm` gates pass. `yolo @ c7188622`; shipped to incitez_web (its #7).
- [x] Clean recipe v2 — newline-aware DONE (2026-06-17 ~18:00 EST) — the flat-text `incitez_clean` (used by incitez_web) now preserves structure: a blank line (2+ `\n`) → `\n\n` paragraph/section break (matcher hard-stop, stops heading bleed); a single `\n` → space (un-wraps hard-wrapped lines, rejoining citations split across a wrap); a dot-leader line (ToC/ToA, 5+ consecutive periods) keeps its break. Offset map preserved. Validated on incitez_web's FedReg demos: wrapped cites rejoin, ~451/298 breaks preserved, extraction does NOT regress (49/32 == old collapse-all recipe, both recovering ~14/~3 wrap-split cites over raw). diffdump bypasses clean() ⇒ 215/215 untouched. `yolo @ aefdefe6`.
- [x] No-§ federal statute SURPASS DONE (2026-06-17 ~19:30 EST) — federal docs drop the `§`/`sec.` ("42 CFR 488.5", "31 U.S.C. 9701"); eyecite returns 0 for these (verified), incitez recovers them. Additive no-marker program for U.S.C./C.F.R. (+variations) in `gen_tables.zig` — marker optional via bare `§? ?` quantifiers (NOT `(?:§ )?` — the VM's group-unroll mishandles a literal-space-bearing group; [[memory]]). Digit-leading `$law_section` + known-reporter anchor guard false positives ("10 CFR Parts 15" → none). Set-based classifier tests (positives + negatives). **Differential 215/215, 0 unfenced** (corpus never triggers it). On the FedReg demos: medicare 35→56 (+13 CFR +8 USC), nrc 29→65 (+5 CFR +31 USC) — each now title/section-linkable to Cornell LII. exceeds_eyecite.md §5.
- [x] Antecedent short-form law SURPASS DONE (2026-06-21 EST) — a bare `§ N` ("Id. § 1985") following a FullLawCitation now resolves to a new `ShortLawCitation` inheriting the antecedent's title + reporter (eyecite drops it as UnknownCitation; confirmed unaddressed-limitation upstream, eyecite #299). Chesterton's-Fence research first: the fence is load-bearing ONLY for isolated/case-antecedent § (genuinely under-determined → kept as UnknownCitation = parity); removed only for the resolvable antecedent case. `lawShortFormResolve` (post-filter pass) + `parseBareSection`; context persists through `id`/`§` tokens, cleared by any case/journal/reference/supra cite. New `short_law` Kind across extract/json/ffi/diffdump/wasm_abi (ABI add). Set-based tests (antecedent upgrades; isolated + case-antecedent stay unknown). **Differential 215/215, 0 fenced** (corpus has no antecedent-§); ./bm gates pass. exceeds_eyecite.md §6 + principled_divergences.md §6. Optionally upstreamable to eyecite #299.
- [ ] LLM-as-case-name-adjudicator idea (M4 differential referee; NOT extraction path).

## Design notes (M2 matcher, from reading eyecite internals)
- eyecite extractor model: per-edition regex templates (default `$full_cite` = `$volume $reporter,? $page`), expanded via regexes.json variables; 208 of 1368 editions carry custom templates; short-cite regexes derived by `at ...page` substitution.
- The regexes.json variable vocabulary is CLOSED (~15 structural shapes: format_neutral, year_included, paragraph, nominative volume, alpha/digit-suffix volumes, comma/period/roman pages, two state one-offs). Plan: gen_tables classifies expanded templates into a pattern enum consumed by hand-written Zig micro-parsers — no regex engine in the core. Strict: unclassifiable template = build error.
- Metadata pass (add_post_citation): pin_cite, court (via paren), year/month/day, parenthetical, extra; case names via backward scan with stop-words (v, in re, see, etc.).
- Acceptance driver design: embed corpus JSON, compare per-case; two-sided ratchet constant (pass-count must equal expectation — regression AND unbumped-progress both fail).

## Next
- [ ] M1: Vendor reporters-db + courts-db JSON (verify exact license text → THIRD_PARTY_LICENSES); build-time table codegen
  - Curiosity poke: reporters.json has nested variant/edition structures — flatten how? Measure comptime-parse vs codegen-step compile cost before choosing.
- [ ] M2: Port eyecite test corpus (full citations first) — attribution header in each ported file
- [ ] M2: TDD full-citation matcher (tokenizer → volume/reporter/page → pin/court/year metadata)
- [ ] Future parity slice: law/journal/§ (UnknownCitation) extraction — unlocks the 4 ResolveTest gaps + 2 corpus methods
- [ ] Post-parity optimization pass (Peter-ordered AFTER correctness): Aho-Corasick anchor scan, case-name walk efficiency, allocation reduction — under the now-live bm gate (current vm baseline 1287ms/1.7MB incl. all features)
## (M5 done — see Completed)
- [ ] M6: docscan integration + legal_ai harness wiring (planned with Einstein after M5)
- [x] M7 COMPLETE: WASM build target (Peter-ratified) — browser demo for **incitez_web** (Elm UI). `packages.<system>.wasm` → `$out/incitez.wasm` (wasm32-freestanding, ReleaseSmall, ~515KB, PCRE2 comptime-excluded). `src/wasm.zig` ABI (alloc/extract/free + selftest 6/6 + version), output byte-identical to CLI `--json` via shared `src/json_out.zig`. `checks.wasm` = node `tests/wasm/smoke.mjs` MFIC gate (zero-import instantiate + full ABI), also in `./test`. Consumer contract: `docs/wasm_abi.md`. incitez_web pinged + unblocked for M2 (2026-06-12 ~11:40 EST). In-browser the VM advantage WIDENS — wasm has no executable pages, so PCRE2 would run interpreted; the VM needs no JIT.
## Completed
- [x] M5 COMPLETE: C FFI (flat structs, arena ownership, resolution indices) + CLI `incitez extract <file|-|@stdin> [--json] [--engine vm|pcre2]` with INCITEZ_ENGINE env, JSON output, spaces-in-paths + exit-code CLI tests (13 assertions); FFI dogfooded by the C CLI and by Zig-side export tests (2026-06-12 ~07:30 EST)
- [x] M4 COMPLETE: mutation suite (162/162 reporter kills, 0 engine disagreements on mutants), differential gate vs LIVE eyecite (189/215 agree, 26 fenced w/ reasons, 0 unfenced; CI check .#checks.differential green), bm gate fired +186% -> investigated, explained (feature growth), annotated + accepted (2026-06-12 ~06:00 EST)
  - gate-found parity fixes: pre-cite year OVERRIDES post year; empty plaintiff stays ""
- [x] M3 COMPLETE: resolution pass — resolve.py port, 19/23 ResolveTest corpus (4 = law/journal gaps) (2026-06-12 ~04:00 EST)
- [x] M3: short/supra/id/ibid + filter_citations — 113/113 both engines (2026-06-12 ~02:30 EST)
- [x] M2: case names — find_case_name port (element walker over words/spaces/citations/placeholders/stop-words, all scan branches, _process_case_name v-split + strip_stop_words two-pass, Python negative-slice quirk mirrored); driver compares plaintiff+defendant; 64/64 both engines, 0/193 divergences, leak-free (2026-06-12 ~00:30 EST)
- [x] M2: pin_cite + parenthetical + extra metadata — full POST_FULL_CITATION_REGEX branch parity; driver compares all three; 64/64 both engines, 0/193 divergences (2026-06-11 ~20:30 EST)
- [x] PCRE2 dual-engine harness (Peter-directed): pcre2 fork as flake input (static+JIT), eyecite-literal extractors emitted by codegen, Engine enum, per-engine corpus ratchets (64/64 BOTH), cross-engine differential 0/193, ./bm engine benchmark — vm 17.35× faster wall-clock than JIT'd PCRE2 on 1.7MB (449ms vs 7.8s steady-state; one-shot 0.90s vs 15.7s) (2026-06-11 ~19:30 EST)
- [x] Read kickoff + design brief; copied spec into docs/ (2026-06-11 ~14:00 EST)
- [x] M2: corpus port — 193 oracle-verified cases / 6 methods → tests/corpus/eyecite_corpus.json; .#eyecite-env (pinned eyecite 2.7.6) in flake (2026-06-11 ~15:00 EST)
- [x] M1: Garnix CI green on yolo (incl. Linux patchelf path — poke answered) (2026-06-11 ~16:45 EST)
- [x] M2: court resolution — courts-db codegen (gen_courts.zig), get_court_by_paren (exact-then-last-prefix quirk replicated), guess_court scotus; driver compares court; 64/64 (2026-06-11 ~17:50 EST)
- [x] M2: year metadata — post-citation court/date paren + CA pre-citation year; driver compares year; 64/64 (2026-06-11 ~17:15 EST)
  - year ceiling constant 2027 (clockless core) — bump with corpus re-extraction or inject; divergence note: pre-cite year lacks eyecite's case-name gate
- [x] M2: full-citation matcher CORE — pattern-VM (build-time compiled from eyecite templates, strict closed vocabulary), 64/64 eligible corpus cases green incl. all custom shapes; acceptance ratchet at 64 (2026-06-11 ~16:30 EST)
  - 1 known unanchored program (S.W. fuzzy regex) deliberately skipped at runtime — revisit with differential gate
  - spans are BYTE offsets (vs eyecite's code-point offsets) by design; driver converts
- [x] M1: Scaffold — build.zig, flake.nix (zig 0.16.0 pin; eyecite v2.7.6 / reporters-db 3.2.65 / courts-db 0.10.27 as pinned non-flake inputs), C FFI + C CLI skeletons, ./build + ./test, 13 CLI smoke assertions, all green locally (2026-06-11 14:20 EST)
  - Licenses verified at pin time: all three BSD-2-Clause (exact text read from store paths)
  - Curiosity poke kept open: does the Linux patchelf dance behave with a no-libc test binary? Garnix will tell.
