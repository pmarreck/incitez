# incitez

**incitez** ("insights on citations, Zig") is a legal-citation extraction engine
in Zig: a drop-in-grade alternative to [eyecite](https://github.com/freelawproject/eyecite)
(Free Law Project, BSD-2-Clause) — the tool that powers CourtListener and
Harvard's Caselaw Access Project — built to **meet *and* surpass** it.

It extracts full case citations, short forms, supra, id/ibid, journal, law,
section, and reference citations, with party names, pin cites, courts, years,
parentheticals, and short→full resolution. Pure in-memory Zig core (no I/O)
behind a C FFI, with a C CLI and a browser WebAssembly build.

## How it compares to eyecite

The whole design is honest about the bar: **equivalent where eyecite is the
authority, faster everywhere, and more correct where eyecite has real-world
weaknesses.**

### Parity — the trust anchor (verified, not claimed)

incitez agrees with the pinned eyecite oracle **215/215, 0 divergences** across
eyecite's *own* ported test corpus, re-checked on every push by a live
differential gate (`scripts/differential`, CI `checks.differential`). On
eyecite's corpus eyecite *is* the ground truth, so this proves incitez is **not
worse** — the credibility floor that makes the claims below believable. It is
**not** by itself a superiority claim.

### Speed — measured superior

Same work, warm, engine-processing-only (no Python interpreter-import artifact),
recomputed live — never hardcoded:

| input | eyecite (Python) | incitez (Zig) | faster |
|---|---|---|---|
| real 90-page appellate brief (121 KB text) | ~970 ms | ~31 ms | **~31×** |
| benchmark corpus, steady-state (116 KB) | 2561 ms | 47 ms | **54.8×** |
| cold-start single invocation | 0.432 s | 0.0069 s | **62.7×** |

(Apple M4 Max; see `BENCHMARKS.md`, hardware-keyed + two-sided regression-gated.
Run it yourself: `./demo` or `./bm`.) Cite counts match or slightly *exceed*
eyecite on real input (e.g. 2160 vs 2159 — incitez recovers one eyecite's
`finditer` drops; 324 = 324 on the brief).

### Accuracy — verified-superior in specific, real-world classes

Where eyecite is **demonstrably wrong** (confirmed against the live oracle),
incitez is right. These are objectively checkable case classes, **additive** to
the 215/215 parity (the marker-free corpus never triggers them). Full catalog +
methodology in [`docs/exceeds_eyecite.md`](docs/exceeds_eyecite.md):

- **En-dash / em-dash pin ranges** — eyecite drops `241–242` (non-ASCII dash);
  incitez recovers it.
- **Structural-newline boundaries** — a section heading on the line above a
  citation bleeds into eyecite's party name; incitez treats the boundary as a
  hard stop (`TABLE OF AUTHORITIES\nAlbritton v. Gandy` → `Albritton`, not
  `TABLE OF AUTHORITIES … Albritton`).
- **Leading Bluebook signals** — eyecite leaves `Compare`/`Accord`/`Contra`/
  `Consider` glued to the plaintiff; incitez strips them, leading-position-only,
  so a signal word *embedded* in a real name survives.

These are documented case classes, each independently verifiable. A **systematic
precision/recall study** over a labeled real-document corpus (the rigorous,
quantified next step) is tracked, not yet complete — we don't claim a single
accuracy multiple we can't yet defend.

## Architecture

```
C CLI (cli/main.c, all I/O) ──► C FFI (include/incitez.h) ──► Zig core (src/, pure, no I/O)
                                                              └► WASM (src/wasm.zig) for the browser
```

- The C CLI dogfoods the FFI; sibling-Zig consumers may import the core directly.
- A VM-only WASM artifact (`packages.wasm`) powers the privilege-preserving
  browser demo (incitez_web) — citations extracted client-side, nothing leaves
  the browser. Consumer contract: [`docs/wasm_abi.md`](docs/wasm_abi.md).
- Pipeline split: **docscan** owns structure-aware PDF→text (and emits structural
  boundary markers); **incitez** owns citation logic and the span contract;
  **incitez_web** composes them client-side in the browser.

## Usage

```sh
./build                      # build via nix (sandboxed); → zig-out/bin/
./test                       # full suite: unit + acceptance + mutation + CLI + WASM smoke
./bm                         # benchmarks (per-function + vs-eyecite), regression-gated
./demo [brief.pdf]           # the incitez-vs-eyecite head-to-head (parity / speed / surpass)

zig-out/bin/incitez extract <file|-|@stdin> [--json]
```

Input is UTF-8 plain text; for real PDFs, extract via docscan (structure-aware)
or run the eyecite recipe (`incitez_clean`: collapse `\s+`, strip `__`). See
`docs/wasm_abi.md §5`.

## Verification (MFIC-shaped)

1. eyecite's ported corpus = the acceptance suite.
2. Live differential gate vs pinned eyecite (CI).
3. Mutation suite — perturbed citations must degrade predictably.
4. Per-function microbenchmarks + a machine-independent **scaling-ratio gate**
   (`tests/scaling`) that fails any phase growing super-linearly.
5. `std.testing.allocator` proves leak-freedom.

## License

Proprietary © 2026 Mecha LLC, all rights reserved — see [`LICENSE`](LICENSE).
Incorporates BSD-2-Clause data/grammar from Free Law Project (reporters-db,
courts-db, eyecite); those notices are retained in
[`THIRD_PARTY_LICENSES`](THIRD_PARTY_LICENSES).
