# incitez — Project Overview

**incitez** ("insights on citations, Zig") is a legal-citation extraction
engine: feature parity with [eyecite](https://github.com/freelawproject/eyecite)
(Free Law Project, BSD-2-Clause), at 1–2 orders of magnitude better
performance. It is the citation-extraction engine under the legal_ai
verification harness and an optional docscan dependency.

The full design brief (licensing findings, test strategy, data strategy, API
sketch, milestones, perf targets) lives at `docs/incitez_design.md` — that is
the spec.

## Architecture

House hexagonal pattern:

```
C CLI (cli/main.c, all I/O) ──► C FFI (include/incitez.h) ──► Zig core (src/, pure, no I/O)
```

- The C FFI is the public API for non-Zig consumers; the C CLI dogfoods it
  (the CLI MUST keep going through `include/incitez.h` — it IS the dogfood
  that validates the FFI boundary). Because the C CLI already exercises the
  FFI, **sibling-Zig consumers (e.g. docscan, future Zig dependents) may
  import the Zig module directly** rather than routing through the C ABI —
  no double-marshalling required. The WASM ABI is the contract for the
  browser consumer (incitez_web); see `docs/wasm_abi.md`.
- ReleaseFast by default; flake.nix + Garnix CI; Zig pinned to 0.16.0
  via zig-overlay.
- All deps are flake-local (no globally-installed tooling): eyecite,
  reporters-db, and courts-db are pinned non-flake inputs in `flake.nix`
  (`flake.lock` is the pin). Run `scripts/link-deps` to symlink them into
  `deps/` for source analysis.
- A WASM build target is on the horizon (browser demo) — keep the core free
  of anything WASM-hostile.

## Terminology

- **Full citation**: `volume reporter page` with optional pin cite, court,
  year — e.g. `410 U.S. 113, 116 (1973)`.
- **Short citation**: abbreviated re-reference — e.g. `410 U.S. at 116`.
- **Supra**: reference back to a previously cited work by party name —
  e.g. `Roe, supra, at 116`.
- **Id./Ibid.**: reference to the immediately preceding citation.
- **Resolution pass**: linking short/supra/id forms to their full-citation
  antecedents.
- **Reporter**: a published volume series of judicial opinions (e.g. `U.S.`,
  `F.3d`); the reporters-db JSON enumerates them and their variants.
- **Differential oracle**: pinned-version eyecite run over the same corpus at
  test time (nix-provided Python, never ships); verdicts must agree. When in
  doubt, the oracle decides (MFIC discipline).

## Verification (MFIC-shaped)

1. eyecite's ported test corpus = the acceptance suite.
2. Differential CI gate vs pinned eyecite.
3. Mutation suite: perturbed citations must degrade predictably.
4. Two-sided (±10%) benchmark gate, history committed, hardware-keyed.
5. `std.testing.allocator` proves leak-freedom.
