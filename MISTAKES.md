# Mistakes log (continuous improvement)

## 2026-06-11 — glossed-over jj warning cost a debugging cycle
During vendoring, `jj git push` printed "Refused to snapshot some files:
data/courts_db/courts.json: 1.8MiB (max 1.0MiB)" — I saw the output and
moved on. The file was silently absent from every subsequent commit; local
`zig build test` (reads disk) stayed green while the Nix-sandboxed build
(reads git tree) failed later with a confusing FileNotFound deep in the
build graph. Lessons: (1) jj warnings about REFUSED operations are errors
in disguise — stop and resolve; (2) the local-vs-sandbox split is itself a
detector: when only the sandbox fails, suspect untracked/unsnapshotted
files first. Fix shipped: .jj-repo-config.toml (max-new-file-size=8MiB) +
./setup installer.

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

## 2026-06-12 — gsed range-delete ate a `continue` (caught by the sandbox suite)
`gsed '/pattern/,+1d'` deleted the matched print AND the control-flow line
after it, turning a guarded skip into fall-through onto invalid state — a
SEGV that only the sandboxed nix suite caught (local zig-build run predated
the edit). Lessons: (1) after ANY mechanical multi-line edit, grep the
surrounding control flow, not just the target line; (2) the local-vs-sandbox
duplication keeps catching what single-environment testing would miss.
