# incitez — Performance

incitez extracts legal citations **dramatically faster than
[eyecite](https://github.com/freelawproject/eyecite)** — the Free Law Project library
that powers CourtListener and the Caselaw Access Project — while finding the same
citations (verified **215/215** against eyecite's own corpus).

## Headline (Apple M4 Max — reproduce with `./bm`)

| scenario | eyecite | incitez | speedup |
|---|---|---|---|
| **Single run on a document** — cold CLI, the common case | ~172 ms | ~2.7 ms | **~64×** |
| **Full ~90-page appellate brief** — warm, engine only | 987 ms | 32 ms | **~31×** |
| **Mid-size brief** — warm, engine only | 591 ms | 16 ms | **~37×** |
| **Short excerpt** — warm, engine only | 4.0 ms | 0.7 ms | **~6×** |

**The lead widens with the document.** incitez holds **~4 MB/s regardless of size**;
eyecite falls from 0.7 MB/s to **0.13 MB/s** as briefs get longer and more
citation-dense — it scales super-linearly where incitez stays roughly linear. And on a
typical one-shot run, eyecite re-pays **~170 ms of Python + model import every time**;
incitez (a native binary, or WASM in the browser) does not.

Same citations found. On dense briefs eyecite emits repeated `Unknown overlap case`
warnings; incitez is silent.

> Honest framing: the multiple is **input-dependent** — ~6× on a tiny snippet up to
> ~30–37× on a full brief (warm), ~64× for a typical single run (cold). We report the
> regime and the size, not one flattering number, so the figure survives a skeptic
> re-running it.

## How these are measured — and gated on every run

- **Warm, engine-only**: in-process steady-state loop with process/interpreter startup
  excluded — the fair, apples-to-apples comparison of the parsing work itself.
- **Cold**: `hyperfine -N --warmup 2` over a single CLI invocation — the real-world
  "run it once" cost, startup included.
- `./bm` logs machine-keyed metrics to **`bench/<machine-id>.ndjson`** and **two-sided
  gates** them against this machine's last run: ±10% whole-pipeline, ±25% per key
  function (so an unexplained slow-down *or* speed-up fails the build). A
  machine-independent **scaling-ratio gate** (`tests/scaling`) fails any phase that
  grows super-linearly.

*Numbers above are from one M4 Max run. Reproduce: `./bm` (gated suite) or `./demo`
(live incitez-vs-eyecite head-to-head). Raw per-run history lives in `bench/`.*
