# incitez — Plan

Spec: `docs/incitez_design.md`. Kickoff: `inbox/2026-06-11-incitez-kickoff.md` (processed).

## In Progress
- [ ] M1: Private GitHub repo pmarreck/incitez (SSH), yolo bookmark, push, Garnix green

## Next
- [ ] M1: Vendor reporters-db + courts-db JSON (verify exact license text → THIRD_PARTY_LICENSES); build-time table codegen
  - Curiosity poke: reporters.json has nested variant/edition structures — flatten how? Measure comptime-parse vs codegen-step compile cost before choosing.
- [ ] M2: Port eyecite test corpus (full citations first) — attribution header in each ported file
- [ ] M2: TDD full-citation matcher (tokenizer → volume/reporter/page → pin/court/year metadata)
- [ ] M3: Short/supra/id/ibid matchers + resolution pass
- [ ] M4: Differential CI gate vs pinned eyecite (nix Python, test-time only) + mutation suite + two-sided ±10% benchmark gate (history committed, hardware-keyed)
- [ ] M5: C FFI (flat structs, arena ownership) + CLI `incitez extract file.txt --json`; notify Einstein via LLMsend
- [ ] M6: docscan integration + legal_ai harness wiring (planned with Einstein after M5)

## Completed
- [x] Read kickoff + design brief; copied spec into docs/ (2026-06-11 ~14:00 EST)
- [x] M1: Scaffold — build.zig, flake.nix (zig 0.16.0 pin; eyecite v2.7.6 / reporters-db 3.2.65 / courts-db 0.10.27 as pinned non-flake inputs), C FFI + C CLI skeletons, ./build + ./test, 13 CLI smoke assertions, all green locally (2026-06-11 14:20 EST)
  - Licenses verified at pin time: all three BSD-2-Clause (exact text read from store paths)
  - Curiosity poke kept open: does the Linux patchelf dance behave with a no-libc test binary? Garnix will tell.
