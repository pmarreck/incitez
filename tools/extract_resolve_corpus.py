#!/usr/bin/env python3
"""Extract eyecite's ResolveTest checkResolution cases into JSON.

Runs inside the pinned oracle env (test-time only). AST-walks
tests/test_ResolveTest.py for self.checkResolution((idx|None, "text"), ...)
calls, then VERIFIES each case against the live oracle by replicating the
test procedure (per-row get_citations, combined resolve_citations) before
recording it. Methods using other helpers are listed loudly, never dropped
silently.
"""

import ast
import json
import sys
from collections import defaultdict

from eyecite import get_citations
from eyecite.resolve import resolve_citations


def run_oracle(rows):
    """Replicate checkResolution: extract one cite per row text, resolve the
    combined list, return cluster index per row (None = unresolved)."""
    citations = []
    for _, text in rows:
        cites = get_citations(text)
        if len(cites) != 1:
            return None, f"{len(cites)} cites in {text!r}"
        citations.append(cites[0])
    resolutions = resolve_citations(citations)
    # map resource -> cluster index by first appearance
    cluster_of_cite = {}
    cluster_index = {}
    for resource, members in resolutions.items():
        for m in members:
            cluster_of_cite[id(m)] = resource
    out = []
    for c in citations:
        resource = cluster_of_cite.get(id(c))
        if resource is None:
            out.append(None)
            continue
        if resource not in cluster_index:
            cluster_index[resource] = len(cluster_index)
        out.append(cluster_index[resource])
    return out, None


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <eyecite-src-dir> <out.json>", file=sys.stderr)
        return 1
    src_path = f"{sys.argv[1]}/tests/test_ResolveTest.py"
    with open(src_path) as f:
        tree = ast.parse(f.read(), src_path)

    methods = {}
    skipped = []
    mismatches = 0

    for cls in (n for n in tree.body if isinstance(n, ast.ClassDef)):
        for method in (n for n in cls.body if isinstance(n, ast.FunctionDef)):
            if not method.name.startswith("test_"):
                continue
            cases = []
            uses_other = False
            for node in ast.walk(method):
                if not isinstance(node, ast.Call):
                    continue
                func = node.func
                if not isinstance(func, ast.Attribute):
                    continue
                if func.attr in (
                    "checkReferenceResolution",
                    "checkReferenceResolutionList",
                    "assertResolution",
                ):
                    uses_other = True
                if func.attr != "checkResolution":
                    continue
                try:
                    rows = [
                        ast.literal_eval(arg) for arg in node.args
                    ]
                except ValueError as e:
                    skipped.append(f"{method.name}: non-literal args: {e!r}")
                    continue
                if not all(
                    isinstance(r, tuple) and len(r) == 2 and isinstance(r[1], str)
                    for r in rows
                ):
                    skipped.append(f"{method.name}: unexpected row shape")
                    continue
                actual, err = run_oracle(rows)
                if err:
                    skipped.append(f"{method.name}: oracle: {err}")
                    continue
                expected = [r[0] for r in rows]
                if actual != expected:
                    mismatches += 1
                    print(
                        f"ORACLE MISMATCH in {method.name}:\n"
                        f"  rows:     {rows}\n  expected: {expected}\n  actual:   {actual}",
                        file=sys.stderr,
                    )
                    continue
                cases.append({"rows": [[r[0], r[1]] for r in rows]})
            if uses_other:
                skipped.append(f"{method.name}: uses non-checkResolution helpers (partial/none extracted)")
            if cases:
                methods[method.name] = cases

    out = {
        "_source": "eyecite tests/test_ResolveTest.py (Free Law Project)",
        "_license": "BSD-2-Clause — see THIRD_PARTY_LICENSES",
        "_eyecite_version": "2.7.6",
        "_extractor": "tools/extract_resolve_corpus.py",
        "methods": methods,
    }
    with open(sys.argv[2], "w") as f:
        json.dump(out, f, indent=1, sort_keys=True, ensure_ascii=False)
        f.write("\n")

    total = sum(len(v) for v in methods.values())
    print(f"extracted {total} resolution cases across {len(methods)} methods")
    if skipped:
        print(f"\nSKIPPED ({len(skipped)}):", file=sys.stderr)
        for s in skipped:
            print(f"  - {s}", file=sys.stderr)
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main())
