#!/usr/bin/env python3
"""eyecite-side of the cross-implementation benchmark (pinned oracle env).

Modes:
  steady <file> <iters>   warm-loop timing of get_citations() over <file>;
                          prints "eyecite: BYTES bytes, N cites, NS ns/iter, MB/s"
                          matching tools/bench.zig's line format.
  oneshot <file>          single get_citations() incl. interpreter is the
                          process itself — used by hyperfine for cold-start.

get_citations uses eyecite's DEFAULT tokenizer (AhocorasickTokenizer:
pyahocorasick string prefilter + Python re per candidate) — the fair
"eyecite default" baseline from the design brief. Extraction only (no
resolve_citations), matching incitez's extractWithEngine.
"""

import sys
import time

from eyecite import get_citations


def main():
    mode = sys.argv[1]
    path = sys.argv[2]
    with open(path, encoding="utf-8") as f:
        text = f.read()
    nbytes = len(text.encode("utf-8"))

    if mode == "oneshot":
        # the whole process is the measurement (hyperfine times it)
        n = len(get_citations(text))
        sys.stderr.write(f"{n} cites\n")
        return 0

    if mode == "steady":
        iters = int(sys.argv[3])
        n = len(get_citations(text))  # warmup
        t0 = time.perf_counter_ns()
        for _ in range(iters):
            get_citations(text)
        t1 = time.perf_counter_ns()
        ns_total = t1 - t0
        ns_per = ns_total // iters
        mb_s = (nbytes * iters * 1000.0) / ns_total
        print(f"eyecite: {nbytes} bytes, {n} cites, {ns_per} ns/iter, {mb_s:.2f} MB/s")
        return 0

    sys.stderr.write(f"unknown mode {mode}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main())
