# incitez WASM ABI — the browser-world `incitez.h`

This is the **consumer contract** for the incitez WASM artifact. Build against
this document, never against the Zig source. It is the WASM analogue of
`include/incitez.h`: the stable boundary the browser demo (incitez_web) and any
other JS/WASM consumer codes to.

The artifact is **VM-only**: the PCRE2 alternate engine is comptime-excluded
(`build_options.enable_pcre2 = false`), so the module has no C dependency and no
engine selector. One engine, one contract.

---

## 1. Provenance — where the artifact comes from

- **Flake attribute:** `packages.<system>.wasm` → a derivation whose single
  output file is `incitez.wasm`.
  - Example: `nix build github:pmarreck/incitez#packages.aarch64-darwin.wasm`
    produces `result/incitez.wasm`.
  - As a flake input from incitez_web:
    ```nix
    inputs.incitez.url = "github:pmarreck/incitez";
    # ...
    incitez.packages.${system}.wasm   # → $out/incitez.wasm
    ```
  - `<system>` is **your builder's** system (e.g. `x86_64-linux` on CI). The
    emitted `incitez.wasm` is a `wasm32-freestanding` binary and is
    **byte-identical regardless of which host built it** — the per-system
    attribute only reflects where the *build* ran, not the target.
- **Garnix cache:** Garnix builds `packages.*` on every push to `yolo`, so the
  artifact is served from `cache.garnix.io` (already trusted in Peter's nix
  config). You should never have to build it yourself.
- **Size:** ~515 KB (`ReleaseSmall`). No compression applied; gzip/brotli at
  your serving layer if you care about transfer size.

---

## 2. Module shape — freestanding, zero imports

The module is **`wasm32-freestanding`, NOT WASI**. It instantiates with an
**empty import object** — no memory import, no WASI shim, no abort/trap import:

```js
const { instance } = await WebAssembly.instantiate(bytes, {});  // {} — nothing required
```

If `WebAssembly.instantiate(bytes, {})` ever throws "incompatible import type"
or names a missing import, that is a contract violation on our side — file it.
Today the import list is empty.

Memory is **exported, not imported**: `instance.exports.memory` is the WASM
linear memory. It is a reactor module (no `_start`); all entry points are the
explicit exports below.

---

## 3. Exports

| Export | Signature | Purpose |
|---|---|---|
| `memory` | `WebAssembly.Memory` | the linear memory; all pointers are byte offsets into `memory.buffer` |
| `incitez_alloc` | `(len: u32) -> u32` | allocate `len` writable bytes; returns a pointer (offset), or `0` on OOM |
| `incitez_free` | `(ptr: u32) -> void` | free a buffer returned by `incitez_alloc` **or** `incitez_extract`; `0` is a no-op |
| `incitez_extract` | `(ptr: u32, len: u32) -> u32` | extract citations from `len` UTF-8 bytes at `ptr`; returns a result pointer, or `0` on OOM |
| `incitez_clean` | `(ptr: u32, len: u32) -> u32` | normalize flat text (eyecite recipe) + offset map; result pointer, or `0` on OOM. Optional, for flat-text callers — see §5 |
| `incitez_selftest` | `() -> u32` | run the embedded corpus; returns `(passed << 16) | total` |
| `incitez_version_ptr` | `() -> u32` | pointer to a NUL-terminated ASCII version string (read until `\0`) |

All `u32`. There are no i64/externref/multi-value signatures, so no BigInt
juggling on the JS side.

---

## 4. Memory ownership — the protocol, spelled out

Two allocations cross the boundary per call, and **you own and free both**:

1. **Input buffer** — you allocate it, fill it, pass it in, and free it:
   ```js
   const inBytes = new TextEncoder().encode(text);
   const inPtr = ex.incitez_alloc(inBytes.length);     // you own inPtr
   new Uint8Array(ex.memory.buffer).set(inBytes, inPtr);
   const resPtr = ex.incitez_extract(inPtr, inBytes.length);  // you own resPtr
   // ... read the result (below) ...
   ex.incitez_free(inPtr);
   ex.incitez_free(resPtr);
   ```

2. **Result buffer** — `incitez_extract` returns a pointer to a buffer laid out
   as a **4-byte little-endian length prefix followed by that many UTF-8 JSON
   bytes**:

   ```
   resPtr → [ u32 json_len (LE) ][ json_len bytes of UTF-8 JSON ]
   ```

   ```js
   const dv = new DataView(ex.memory.buffer);
   const jsonLen = dv.getUint32(resPtr, true);          // little-endian
   const jsonBytes = new Uint8Array(ex.memory.buffer, resPtr + 4, jsonLen);
   const json = new TextDecoder().decode(jsonBytes);
   const cites = JSON.parse(json);
   ```

### Ownership rules

- **You free everything.** Both `inPtr` and `resPtr` are freed with
  `incitez_free`. There is no separate `free_result`; one freer for both.
- **The result is a fresh allocation, not a reused scratch buffer.** It stays
  valid until *you* free it. Multiple result buffers may coexist — the
  allocator reuses freed regions, it does not clobber live ones. You do **not**
  have to copy-before-next-call, but freeing promptly keeps the heap small.
- **⚠️ Re-derive your views after every call that can allocate.**
  `incitez_extract` (and `incitez_alloc`) may grow linear memory, and a WASM
  memory grow **detaches the old `ArrayBuffer`**. Any `Uint8Array`/`DataView`
  you built over `memory.buffer` *before* the call is now empty/stale. Always
  construct fresh views over `ex.memory.buffer` **after** the call, exactly as
  shown above. This is the single most common consumer bug.

---

## 5. Input contract — UTF-8 plain text only

- Input is **raw UTF-8 bytes of plain text.** No length cap beyond available
  memory. NUL bytes in the middle are fine (we use the explicit `len`, not
  C-string termination).
- **No HTML / markup handling.** eyecite ships `clean_text` and a `markup_text`
  HTML path (tag stripping, entity decoding, offset remapping). incitez does
  **not** port that — it is **out of scope by design** (text-in only; see
  PROJECT_OVERVIEW.md). **If your source is HTML, strip it to plain text
  *before* calling**, and be aware that citation spans will be offsets into your
  *stripped* text, not the original HTML. Mirroring eyecite's markup-offset
  remapping is a consumer-layer (or future) concern, not part of this ABI.
- Spans (`span`, `full_span`) are **byte offsets into the input you passed**,
  not codepoint or UTF-16 indices. If you slice the original JS string by these
  offsets, slice the *bytes* (or convert), not the UTF-16 string.

### Preprocessing real-world (PDF/OCR) input — the recommended pipeline

Raw PDF/OCR text keeps **layout line-breaks mid-sentence and mid-citation**.
Those `\n`s cost ~47% of citations (split tokens stop matching) and break party
attribution. eyecite has the same problem — its documented answer is
`clean_text(['all_whitespace', ...])` *before* `get_citations`. Two ways to feed
incitez correctly:

**A. Structure-aware (recommended): docscan → incitez.** docscan extracts
PDF→text *using layout knowledge*: it **joins intra-paragraph line-wraps to
single spaces** (recovers the lost recall at the source) and emits a **lone `\n`
ONLY at a real structural boundary** (heading / paragraph / list break). incitez
treats that lone `\n` as a **hard case-name boundary**: the walk-back will not
cross it, so a preceding section heading never bleeds into the party. This
**exceeds eyecite**, which flattens `\n`→space and swallows the heading (see
`docs/principled_divergences.md` §4). docscan also returns an **offset map**
(`{emitted_off, original_off}` breakpoints) so spans map back to the original
document — see "the span chain" below.

**B. Flat text (direct callers, no docscan): run the eyecite recipe yourself.**
If you only have flat text, normalize it before calling — the same recipe
CourtListener and Harvard's Caselaw Access Project run:
- **`\s+` → single space** (eyecite's `all_whitespace`) — collapses newlines/tabs.
- **strip runs of `__`** (eyecite's `underscores`) — a common PDF-extraction artifact.
- **strip HTML to plain text** if your source is markup (incitez is text-in only).

The WASM build does the first two for you: **`incitez_clean(ptr, len)`** applies
the `\s+`→space + strip-`__` recipe and returns the cleaned text **plus an offset
map** so you can still map citation spans back to your original bytes. Result
layout (same shape as docscan's structured output, so you compose maps the same
way):

```
resPtr → [ u32 text_len (LE) ][ text_len cleaned UTF-8 bytes ]
         [ u32 n_breaks (LE) ][ n_breaks × { u32 emitted_off, u32 original_off } (LE) ]
```

The breakpoint array is sorted ascending by `emitted_off`, starts at `{0,0}`, and
is piecewise 1:1 (map a cleaned offset E: binary-search the largest `emitted_off
≤ E`, then `original_off + (E − emitted_off)`). Free `resPtr` with `incitez_free`.
HTML you still strip yourself (incitez is text-in).

This degrades gracefully to **exact eyecite parity** (you lose the structural-
boundary surpass, since collapsing `\s+` destroys the `\n` signal — that's the
cost of not going through docscan). Citation spans returned by `incitez_extract`
on the cleaned text are offsets into that *cleaned* text; use the `incitez_clean`
map to get back to the original.

### The span chain (PDF highlight, end to end)

original PDF bytes → **docscan** emits structure-aware text **+ offset map** →
**incitez** returns citation spans into the *emitted* text → **your app**
composes the two: for a citation span `[s,e)` in incitez output, map each
endpoint through docscan's breakpoint array (binary-search the largest
`emitted_off ≤ s`, then `original = original_off + (s − emitted_off)`) to get the
span in the **original** document. Each component owns exactly one hop.
---

## 6. Output — the `--json` schema (byte-identical to the CLI)

The JSON is produced by the same `src/json_out.zig` serializer the CLI uses, so
`wasm.extract(text)` is **byte-for-byte identical** to `incitez extract - --json`
on the same input. Always a JSON **array** (possibly empty `[]\n`), never `null`,
never a bare object.

Each element has these fields, **in this order** (order is stable — you can
byte-compare):

| Field | Type | Notes |
|---|---|---|
| `kind` | string | `"FullCaseCitation"`, `"ShortCaseCitation"`, `"SupraCitation"`, `"IdCitation"`, `"ReferenceCitation"`, `"FullJournalCitation"`, `"FullLawCitation"`, ... |
| `span` | `[u32, u32]` | `[start, end)` byte offsets of the matched citation token |
| `full_span` | `[u32, u32]` | `[start, end)` including party names / antecedent context |
| `volume` | string \| null | e.g. `"410"`; null for token-like cites (id/supra/reference) |
| `reporter` | string \| null | as written, e.g. `"U. S."`; null for token-like cites |
| `page` | string \| null | e.g. `"113"` |
| `corrected_reporter` | string \| null | canonical form, e.g. `"U.S."`; null for token-like cites |
| `pin_cite` | string \| null | pinpoint, e.g. `"at 116"` or `"241–242"` (en/em-dash preserved) |
| `court` | string \| null | resolved courts-db id, e.g. `"scotus"` |
| `year` | number \| null | e.g. `1973` |
| `parenthetical` | string \| null | trailing explanatory parenthetical |
| `extra` | string \| null | unparsed trailing tail |
| `plaintiff` | string \| null | extracted party (full case cites) |
| `defendant` | string \| null | extracted party (full case cites) |
| `antecedent_guess` | string \| null | best-guess antecedent for short/supra/id forms |
| `resolution` | number \| null | index (into this same array) of the anchoring full citation this cite resolves to; `null`/absent if unresolved |

Note: in the C FFI, `resolution`/`year` use `-1` as the absent sentinel; in the
**JSON** they serialize as `null`. Code to `null`.

---

## 7. Error signaling

- `incitez_extract` returns `0` **only on allocation failure** (genuine OOM).
  Render that as an internal error.
- **Empty or "unparseable" input is not an error.** Empty input and input with
  no citations both return a valid result buffer whose JSON is the empty array
  `[]\n`. You will never get `null`/`0` for "no citations found" — only for OOM.
- There is **no engine-selection error** in the WASM build (VM is the only
  engine; there is no engine parameter).
- The module does not trap on normal input. If you ever see a WASM trap
  (`unreachable`, OOB), treat it as a bug to file, not an expected error path.

---

## 8. `selftest()` — the self-verification badge

`incitez_selftest()` runs a small embedded corpus (full cite, id-resolution,
journal, law, the en-dash pin "surpass", and a negative case) and returns a
packed `u32`:

```js
const r = ex.incitez_selftest() >>> 0;
const passed = r >>> 16;       // high 16 bits
const total  = r & 0xffff;     // low 16 bits
// render: `engine self-verified ${passed}/${total}`
const ok = total > 0 && passed === total;
```

Call it on page load for the "engine self-verified N/N ✓" badge. Today it is
`6/6`. It is self-contained — no input, no allocation you need to manage.

---

## 9. Example vectors (seed differential fixtures)

These are **byte-exact** `incitez extract - --json` outputs — copy them verbatim
as your seed fixtures. Your consumer-side MFIC gate is then
`wasm.extract(input) === expected` byte-for-byte (and, separately, against a live
CLI run — maker ≠ checker).

**Vector 1 — full case citation with parties + year:**

Input:
```
Foo v. Bar, 1 U.S. 1 (1982).
```
Output:
```json
[
 {"kind": "FullCaseCitation", "span": [12, 20], "full_span": [0, 20], "volume": "1", "reporter": "U.S.", "page": "1", "corrected_reporter": "U.S.", "pin_cite": null, "court": "scotus", "year": 1982, "parenthetical": null, "extra": null, "plaintiff": "Foo", "defendant": "Bar", "antecedent_guess": null, "resolution": 0}
]
```

**Vector 2 — en-dash pin cite (the "surpass"; eyecite drops the pin, incitez keeps it):**

Input (the `–` is U+2013 EN DASH):
```
530 U. S. 238, 241–242 (2000)
```
Output:
```json
[
 {"kind": "FullCaseCitation", "span": [0, 13], "full_span": [0, 13], "volume": "530", "reporter": "U. S.", "page": "238", "corrected_reporter": "U.S.", "pin_cite": "241–242", "court": "scotus", "year": 2000, "parenthetical": null, "extra": null, "plaintiff": null, "defendant": null, "antecedent_guess": null, "resolution": 0}
]
```

**Vector 3 — full citation + a resolving `Id.` reference:**

Input:
```
Foo v. Bar, 1 U.S. 1 (1982). Id. at 5.
```
Output:
```json
[
 {"kind": "FullCaseCitation", "span": [12, 20], "full_span": [0, 20], "volume": "1", "reporter": "U.S.", "page": "1", "corrected_reporter": "U.S.", "pin_cite": null, "court": "scotus", "year": 1982, "parenthetical": null, "extra": null, "plaintiff": "Foo", "defendant": "Bar", "antecedent_guess": null, "resolution": 0},
 {"kind": "IdCitation", "span": [29, 37], "full_span": [29, 37], "volume": null, "reporter": null, "page": null, "corrected_reporter": null, "pin_cite": "at 5", "court": null, "year": null, "parenthetical": null, "extra": null, "plaintiff": null, "defendant": null, "antecedent_guess": null, "resolution": 0}
]
```

Note in Vector 3 that the `IdCitation`'s `resolution` is `0` — it points at array
index 0, the full citation it refers back to.

---

## 10. Minimal reference consumer (copy/paste)

This is the whole boundary, end to end. (It is also what
`tests/wasm/smoke.mjs` does, which gates every push via `checks.wasm`.)

```js
const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const ex = instance.exports;
const enc = new TextEncoder(), dec = new TextDecoder();

function extract(text) {
  const inB = enc.encode(text);
  const inPtr = ex.incitez_alloc(inB.length);
  if (inPtr === 0) throw new Error("OOM (alloc)");
  new Uint8Array(ex.memory.buffer).set(inB, inPtr);     // view BEFORE extract
  const resPtr = ex.incitez_extract(inPtr, inB.length);
  if (resPtr === 0) { ex.incitez_free(inPtr); throw new Error("OOM (extract)"); }
  const dv = new DataView(ex.memory.buffer);            // re-derive AFTER extract
  const len = dv.getUint32(resPtr, true);
  const json = dec.decode(new Uint8Array(ex.memory.buffer, resPtr + 4, len));
  ex.incitez_free(inPtr);
  ex.incitez_free(resPtr);
  return JSON.parse(json);
}
```

---

## 11. Versioning & stability

- `incitez_version_ptr()` → NUL-terminated ASCII (currently `"0.1.0"`). Read
  until `\0`. Surface it in your UI so a stale cached artifact is visible.
- The **export set, memory protocol, and JSON field order are the contract.**
  We will not silently remove an export or reorder fields. New *optional* JSON
  fields may be appended at the end of an object over time; code defensively
  (don't assume the object has exactly these keys forever), but the existing
  fields and their order are stable.
- The reference, run-in-CI consumer is `tests/wasm/smoke.mjs`. If your loader
  disagrees with it, the smoke test is the source of truth for the protocol.

— incitez (engine side)
