#!/usr/bin/env python3
"""Differential gate, oracle side + comparator (runs in the pinned eyecite
env, test-time only).

Modes:
  build-texts <find_corpus.json> <resolve_corpus.json> <out_texts.json>
      Assemble the deterministic differential text set.
  compare <texts.json> <incitez_dump.json> <ledger.json>
      Run live eyecite over the texts, diff against incitez's dump
      (byte-span normalized), apply the expected-divergence ledger.
      Exit nonzero on any UNFENCED divergence or any STALE fence.
"""

import json
import sys

from eyecite import get_citations


def serialize(cite, text):
    md = cite.metadata
    span = cite.span()
    # char offsets -> byte offsets
    bs = len(text[: span[0]].encode("utf-8"))
    be = len(text[: span[1]].encode("utf-8"))
    out = {
        "type": type(cite).__name__,
        "span": [bs, be],
        "volume": cite.groups.get("volume"),
        "reporter": cite.groups.get("reporter"),
        "page": cite.groups.get("page"),
        "pin_cite": getattr(md, "pin_cite", None),
        "court": getattr(md, "court", None),
        "parenthetical": getattr(md, "parenthetical", None),
        "extra": getattr(md, "extra", None),
        "plaintiff": getattr(md, "plaintiff", None),
        "defendant": getattr(md, "defendant", None),
        "antecedent_guess": getattr(md, "antecedent_guess", None),
        "year": getattr(cite, "year", None),
    }
    if hasattr(cite, "corrected_reporter"):
        try:
            out["corrected_reporter"] = cite.corrected_reporter()
        except Exception:  # noqa: BLE001
            out["corrected_reporter"] = None
    return out


def build_texts(find_path, resolve_path, out_path):
    texts = []
    with open(find_path) as f:
        find = json.load(f)
    for cases in sorted(find["methods"].items()):
        for case in cases[1]:
            if case.get("clean_steps") or case.get("kwargs"):
                continue
            texts.append(case["text"])
    with open(resolve_path) as f:
        res = json.load(f)
    for cases in sorted(res["methods"].items()):
        for case in cases[1]:
            for row in case["rows"]:
                texts.append(row[1])
    # synthetic adjacency/concatenation cases (seam semantics)
    texts.append("1 U.S. 1; 2 F.2d 3; 3 So.2d 4")
    texts.append("Foo v. Bar, 1 U.S. 1 (1982). Baz v. Qux, 2 F.2d 2 (1983). Id. at 5.")
    with open(out_path, "w") as f:
        json.dump(texts, f, indent=0, ensure_ascii=False)
        f.write("\n")
    print(f"built {len(texts)} differential texts")


COMPARED_FIELDS = [
    "type", "span", "volume", "reporter", "page", "pin_cite", "court",
    "parenthetical", "extra", "plaintiff", "defendant", "antecedent_guess",
    "year", "corrected_reporter",
]


def compare(texts_path, dump_path, ledger_path):
    with open(texts_path) as f:
        texts = json.load(f)
    with open(dump_path) as f:
        ours = json.load(f)
    with open(ledger_path) as f:
        ledger = json.load(f)

    fences = {entry["text"]: entry for entry in ledger["divergences"]}
    fence_hits = set()
    unfenced = []

    for text, mine in zip(texts, ours, strict=True):
        theirs = [serialize(c, text) for c in get_citations(text)]
        mine_cites = mine["cites"]

        def norm(c):
            return tuple(
                tuple(v) if isinstance(v := c.get(k), list) else v
                for k in COMPARED_FIELDS
            )

        agree = len(theirs) == len(mine_cites) and all(
            norm(a) == norm(b) for a, b in zip(theirs, mine_cites)
        )
        if agree:
            if text in fences:
                # fence no longer needed: stale ledger entry
                fences[text]["stale"] = True
            continue
        if text in fences:
            fence_hits.add(text)
            continue
        unfenced.append((text, theirs, mine_cites))

    failures = 0
    for text, theirs, mine_cites in unfenced:
        failures += 1
        print(f"\nUNFENCED DIVERGENCE: {text!r}", file=sys.stderr)
        print(f"  eyecite: {json.dumps(theirs, ensure_ascii=False)}", file=sys.stderr)
        print(f"  incitez: {json.dumps(mine_cites, ensure_ascii=False)}", file=sys.stderr)
    for text, entry in fences.items():
        if entry.get("stale"):
            failures += 1
            print(
                f"\nSTALE FENCE (now agreeing — remove from ledger): {text!r}",
                file=sys.stderr,
            )
        elif text not in fence_hits:
            failures += 1
            print(
                f"\nDEAD FENCE (text not in differential set): {text!r}",
                file=sys.stderr,
            )

    total = len(texts)
    print(
        f"differential: {total - len(unfenced) - len(fence_hits)}/{total} agree, "
        f"{len(fence_hits)} fenced, {len(unfenced)} unfenced"
    )
    return 1 if failures else 0


def main():
    mode = sys.argv[1]
    if mode == "build-texts":
        build_texts(*sys.argv[2:5])
        return 0
    if mode == "compare":
        return compare(*sys.argv[2:5])
    print(f"unknown mode {mode}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
