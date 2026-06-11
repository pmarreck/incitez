#!/usr/bin/env python3
"""Extract eyecite's FindTest corpus into JSON for incitez's acceptance suite.

This is the one justified Python exception (test-time only, never ships):
eyecite is the differential oracle, and this extractor runs INSIDE the pinned
oracle env (nix build .#eyecite-env).

Method: AST-parse tests/test_FindTest.py, eval each method's `test_pairs`
tuple using eyecite's own test factories, then for every (text, expected)
pair run get_citations() and:
  1. VERIFY the result matches the factory expectations using eyecite's own
     comparison semantics (run_test_pairs logic, replicated) — an integrity
     gate proving the oracle agrees with its own acceptance suite;
  2. serialize the ACTUAL found citations (types, groups, metadata, spans)
     as the corpus entry.
Methods whose test_pairs cannot be evaluated are listed LOUDLY, never
silently dropped.

Output JSON is committed at tests/corpus/eyecite_corpus.json with upstream
attribution (BSD-2-Clause, Free Law Project).
"""

import ast
import dataclasses
import json
import sys
from copy import copy
from datetime import datetime

from eyecite import get_citations
from eyecite.models import ResourceCitation
from eyecite import test_factories

EVAL_NAMESPACE = {
    name: getattr(test_factories, name)
    for name in dir(test_factories)
    if not name.startswith("_")
}
EVAL_NAMESPACE.update({"datetime": datetime, "copy": copy})


def comparison_attrs(cite):
    """eyecite's run_test_pairs equality, replicated verbatim (mutates!)."""
    cite.metadata.pin_cite_span_start = None
    cite.metadata.pin_cite_span_end = None
    out = {"groups": cite.groups, "metadata": cite.metadata}
    if isinstance(cite, ResourceCitation):
        out["year"] = cite.year
        out["corrected_reporter"] = cite.corrected_reporter()
    return out


def serialize(cite):
    """Full-fidelity snapshot of a found citation (BEFORE comparison nulls
    the pin_cite span fields)."""
    md = dataclasses.asdict(cite.metadata)
    rec = {
        "type": type(cite).__name__,
        "groups": cite.groups,
        "metadata": md,
        "span": list(cite.span()),
        "full_span": list(cite.full_span()),
        "matched_text": cite.matched_text(),
    }
    if isinstance(cite, ResourceCitation):
        rec["year"] = cite.year
        rec["corrected_reporter"] = cite.corrected_reporter()
    return rec


def uses_custom_tokenizer(method_node):
    """True if the method passes a custom `tokenizers=` to run_test_pairs —
    those cases exercise tokenizer internals, not the default pipeline."""
    for node in ast.walk(method_node):
        if isinstance(node, ast.Call):
            func = node.func
            if (
                isinstance(func, ast.Attribute)
                and func.attr == "run_test_pairs"
                and any(kw.arg == "tokenizers" for kw in node.keywords)
            ):
                return True
    return False


def extract_method(method_node, src_path):
    """Eval every `test_pairs = ...` assignment in order, threading the
    namespace — some methods build the list in two steps (literal, then a
    comprehension appending kwargs). Returns the final value."""
    ns = dict(EVAL_NAMESPACE)
    found = False
    for node in ast.walk(method_node):
        if (
            isinstance(node, ast.Assign)
            and len(node.targets) == 1
            and isinstance(node.targets[0], ast.Name)
            and node.targets[0].id == "test_pairs"
        ):
            expr = ast.Expression(node.value)
            ast.fix_missing_locations(expr)
            code = compile(expr, src_path, "eval")
            ns["test_pairs"] = eval(code, ns)  # noqa: S307 (trusted pinned source)
            found = True
    return ns["test_pairs"] if found else None


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <eyecite-src-dir> <out.json>", file=sys.stderr)
        return 1
    src_path = f"{sys.argv[1]}/tests/test_FindTest.py"
    with open(src_path) as f:
        tree = ast.parse(f.read(), src_path)

    methods = {}
    skipped = []
    mismatches = 0

    for cls in (n for n in tree.body if isinstance(n, ast.ClassDef)):
        for method in (n for n in cls.body if isinstance(n, ast.FunctionDef)):
            if not method.name.startswith("test_"):
                continue
            if uses_custom_tokenizer(method):
                skipped.append(
                    f"{cls.name}.{method.name}: custom tokenizer — not the default pipeline"
                )
                continue
            try:
                pairs = extract_method(method, src_path)
            except Exception as e:  # noqa: BLE001 — loud skip below
                skipped.append(f"{cls.name}.{method.name}: eval failed: {e!r}")
                continue
            if pairs is None:
                continue
            if not all(
                isinstance(p, tuple)
                and len(p) >= 2
                and isinstance(p[0], str)
                and isinstance(p[1], (list, tuple))
                and all(isinstance(k, dict) for k in p[2:])
                for p in pairs
            ):
                skipped.append(
                    f"{cls.name}.{method.name}: test_pairs not in (text, [cites], kwargs?) shape"
                )
                continue

            cases = []
            for q, expected, *rest in pairs:
                kwargs = dict(rest[0]) if rest else {}
                clean_steps = kwargs.get("clean_steps", [])
                call_kwargs = dict(kwargs)
                if "html" in clean_steps:
                    call_kwargs["markup_text"] = q
                else:
                    call_kwargs["plain_text"] = q
                try:
                    found = get_citations(**call_kwargs)
                except Exception as e:  # noqa: BLE001 — loud skip below
                    skipped.append(
                        f"{cls.name}.{method.name}: get_citations({q!r}) raised: {e!r}"
                    )
                    continue

                case = {
                    "text": q,
                    "kwargs": {
                        k: v for k, v in kwargs.items() if k != "clean_steps"
                    },
                    "clean_steps": clean_steps,
                    "cites": [serialize(c) for c in found],
                }

                # Integrity gate: pinned oracle must satisfy its own suite
                found_types = [type(c).__name__ for c in found]
                exp_types = [type(c).__name__ for c in expected]
                if found_types != exp_types:
                    mismatches += 1
                    print(
                        f"ORACLE MISMATCH (types) in {method.name} for {q!r}:\n"
                        f"  found:    {found_types}\n  expected: {exp_types}",
                        file=sys.stderr,
                    )
                    continue
                for a, b in zip(found, expected):
                    if comparison_attrs(a) != comparison_attrs(b):
                        mismatches += 1
                        print(
                            f"ORACLE MISMATCH (attrs) in {method.name} for {q!r}",
                            file=sys.stderr,
                        )
                        break
                else:
                    cases.append(case)

            if cases:
                methods[method.name] = cases

    out = {
        "_source": "eyecite tests/test_FindTest.py (Free Law Project)",
        "_license": "BSD-2-Clause — see THIRD_PARTY_LICENSES",
        "_eyecite_version": "2.7.6",
        "_extractor": "tools/extract_corpus.py",
        "methods": methods,
    }
    with open(sys.argv[2], "w") as f:
        json.dump(out, f, indent=1, sort_keys=True, ensure_ascii=False, default=str)
        f.write("\n")

    total = sum(len(v) for v in methods.values())
    print(f"extracted {total} cases across {len(methods)} methods")
    if skipped:
        print(f"\nSKIPPED ({len(skipped)}) — handle these manually:", file=sys.stderr)
        for s in skipped:
            print(f"  - {s}", file=sys.stderr)
    if mismatches:
        print(f"\n{mismatches} ORACLE MISMATCHES — corpus incomplete", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
