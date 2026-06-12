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
- [ ] Post-parity optimization pass (Aho-Corasick anchor scan, case-name walk, allocation reduction) under the live two-sided bm gate. Current vm baseline ~1.29s/1.7MB citation-dense.
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
