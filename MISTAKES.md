# Mistakes log (continuous improvement)

## 2026-06-11 — pipe exit-code masking in commit gate
`./test 2>&1 | tail -5 && jj commit ...` gates on `tail`'s exit code (always
0), not `./test`'s. A failing suite got committed AND pushed before the
failure was noticed (it turned out green post-hoc, but only by luck — see
next entry). Rule: never pipe the test runner when its exit code gates a
commit; run it bare (capture to a file if output is needed), check `$?`,
THEN commit.

## 2026-06-11 — jj-colocated + nix `src = self` stale-tree race
`./test` runs `nix build`, whose `src = self` reads the git-exported tree —
which only reflects the working copy after a jj command snapshots/exports
it. Running ./test BEFORE `jj commit` tested the PREVIOUS tree, not the
edits under test. Correct order with this setup: `jj commit` (or any jj
command to snapshot) → `./test` → green ? push : (fix → `jj squash` →
re-test). The known-good-commit invariant is preserved by squashing fixes
before push, not by testing before commit.
