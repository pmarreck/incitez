# incitez — design brief (pre-scaffold)

*"insights on citations, Zig" — the citation-extraction engine under the legal_ai verification harness and an optional docscan dependency.*

## Decisions (made 2026-06-11)

- **Separate project**, not a docscan module. Own repo → independent visibility, independent licensing decisions, embeddable by anything (docscan, the legal_ai harness, third-party legal tech). docscan depends on it optionally.
- **Private repo at first** (`pmarreck/incitez`). Revisit openness at first paying engagement: the consulting edge is worth a few months of exclusivity; the long-run moat is execution + distribution, not secrecy.
- **House architecture:** Zig core (pure, no I/O) → C FFI → C CLI dogfooding the FFI. ReleaseFast default. flake.nix + Garnix. Scaffold next session via the `scaffold-zig-project` skill — do not hand-roll.

## Licensing (verified 2026-06-11)

- **eyecite is BSD-2-Clause** ("permissive… easy and safe to incorporate in your own libraries" — their words). **No cleanroom needed**: we may port the grammar directly, reuse their test cases, and vendor their data, with attribution preserved.
- reporters-db / courts-db: same org, expected BSD-2-Clause — **verify exact license text at vendor time** and carry the notices in a `THIRD_PARTY_LICENSES` file.

## Test strategy (MFIC-shaped)

1. **Port eyecite's test corpus** — they have a robust suite of citation strings (full / short / supra / id. / ibid., plus helpers like `case_citation`). BSD lets us translate the cases wholesale. This is the spec, pre-paid by 55M+ citations of field testing.
2. **Differential oracle in CI**: run pinned-version eyecite and incitez over the same corpus; verdicts must agree. *The justified exception to the no-Python rule:* eyecite runs at **test time only**, via nix-provided Python, as the independent reference oracle — there is no other oracle of comparable authority, and it never ships in the binary.
3. **Mutation coverage**: corrupt known-good citations (perturb reporter abbreviations, volume/page digits, punctuation) and assert extraction degrades *predictably* — the citation-domain shotgun test.
4. **Benchmark gate**: two-sided (±10%) per house testing principles; history committed, keyed to hardware.

## Data strategy

Vendor **reporters-db** + **courts-db** JSON; generate Zig tables at build time (comptime or codegen step). The grammar is stable (eyecite 2.7.x is polish-only); the data grows additively — periodic re-vendor refreshes coverage with no code change.

## Performance target

eyecite default = pyahocorasick prefilter + Python `re` per candidate + Python object construction; optional hyperscan tokenizer is native but the surrounding Python (token/citation object churn, overlap resolution, metadata parsing) remains.

Estimate (to be **measured**, never asserted — hyperfine + differential corpus):
- vs eyecite default: **~20–100× single-threaded** (typical expectation ~50×)
- vs eyecite+hyperscan: **~5–20×** (we beat the Python glue, not their regex engine)
- cold-start CLI: **2–3 orders of magnitude** (instant static binary vs Python import + tokenizer build) — decisive for per-document gate invocations
- batch: near-linear thread scaling (std.Thread.Pool); Python's GIL forces multiprocess + serialization overhead

Honest target to publish once measured: "1–2 orders of magnitude end-to-end; 100% agreement with eyecite on its own test corpus."

## API sketch

`incitez_extract(text: []const u8) → []Citation` where Citation = { kind: full|short|supra|id|unknown, span: [start,end), reporter, volume, page, pin, court?, year?, antecedent_ref? }. Resolution pass (linking short forms to antecedents) as a second function. C FFI mirrors with flat structs + arena ownership.

## Milestones

1. Scaffold (skill), vendor data, table codegen.
2. Full-citation matcher TDD'd against ported corpus.
3. Short/supra/id/ibid + resolution pass.
4. Differential CI gate vs pinned eyecite + mutation suite + benchmark gate.
5. C FFI + CLI (`incitez extract file.txt --json`).
6. docscan integration (citations as chunk metadata); legal_ai harness stage-1 wiring.
7. **WASM build target** — *Peter-endorsed 2026-06-11* (originated as Einstein's monetization proposal; ratified: "never leaving the browser is certainly a sell to lawyers"). Powers the mecha.llc browser demo: client-side citation checking where the document never leaves the lawyer's machine — the privilege-preserving differentiator no server-posting competitor matches. Architecture note: the core stays WASM-clean throughout milestones 1–6 (costs ~nothing); the server-side API and the WASM demo are complementary deployments of the same core, not a fork. Sequenced after the CLI milestone — not a license for present-day scope creep.

Effort calibration: z7z went first-line→feature-complete in ~72h of wall clock. This is smaller. Sessions, not weeks.
