## 2026-06-11 16:59 — arm64-Apple M4 Max — 1745550 bytes input
```
vm: 1745550 bytes, 20700 cites, 449489966 ns/iter, 3.9 MB/s
pcre2: 1745550 bytes, 20550 cites, 7793259658 ns/iter, 0.2 MB/s
one-shot mean: vm 0.9030735544s, pcre2 15.666180183299996s
```

## 2026-06-12 02:10 — arm64-Apple M4 Max — 1745550 bytes input
```
vm: 1745550 bytes, 29550 cites, 1287010891 ns/iter, 1.4 MB/s
pcre2: 1745550 bytes, 29400 cites, 16120387583 ns/iter, 0.1 MB/s
one-shot mean: vm 2.6173458208s, pcre2 34.5456147084s
```

> **Gate note (2026-06-12):** +186% vm regression vs the 2026-06-11 baseline is
> ACCEPTED as explained feature growth: that baseline measured the bare
> full-citation matcher; this one includes short-form programs (~2× patterns
> per anchor), id/supra token scans, case-name backward walks, the
> filter_citations pass, and pre-citation antecedents — and finds 29,550
> cites vs 20,700 on the same input. Optimization pass (Aho-Corasick anchors,
> case-name walk efficiency) is scheduled post-parity per Peter's direction.

