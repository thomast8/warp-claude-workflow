#!/usr/bin/env bash
# Real-git contract checks for canonical default-branch ownership and shared feature/
# PR worktree reuse. All repositories live under a fresh temporary directory.
set -euo pipefail
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="$ROOT_DIR/bin/canonical-checkout.sh"
SETUP="$ROOT_DIR/bin/worktree-setup.sh"
PR_SETUP="$ROOT_DIR/bin/pr-worktree.sh"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/canonical-checkout.XXXXXX")"
RUN_DIR="$(cd "$RUN_DIR" && pwd -P)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

new_repo() {
  local name="$1" repo
  repo="$RUN_DIR/$name/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.name check
  git -C "$repo" config user.email check@example.com
  git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" switch -q -c feature/parked
  printf '%s\n' "$repo"
}

branch_of() {
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached\n'
}

repo="$(new_repo 'clean secondary')"
secondary="$RUN_DIR/clean secondary/main"
git -C "$repo" worktree add -q "$secondary" main
resolved="$($CANONICAL "$repo")"
[ "$resolved" = "$repo" ] || fail "canonical path was $resolved, want $repo"
[ "$(branch_of "$repo")" = main ] || fail "primary checkout did not switch to main"
[ "$(branch_of "$secondary")" = detached ] || fail "secondary main checkout was not detached"
pass "clean secondary main is detached and primary becomes canonical"

repo="$(new_repo dirty-secondary)"
secondary="$RUN_DIR/dirty-secondary/main"
git -C "$repo" worktree add -q "$secondary" main
printf 'keep me\n' > "$secondary/uncommitted.txt"
if "$CANONICAL" "$repo" >"$RUN_DIR/dirty-secondary/out" 2>"$RUN_DIR/dirty-secondary/err"; then
  fail "dirty secondary main unexpectedly reconciled"
fi
[ "$(branch_of "$repo")" = feature/parked ] || fail "dirty-secondary failure moved primary"
[ "$(branch_of "$secondary")" = main ] || fail "dirty-secondary failure detached secondary"
[ -f "$secondary/uncommitted.txt" ] || fail "dirty-secondary failure lost its file"
grep -q 'dirty worktree' "$RUN_DIR/dirty-secondary/err" || fail "dirty-secondary error was not actionable"
pass "dirty secondary main is preserved and rejected"

repo="$(new_repo locked-secondary)"
secondary="$RUN_DIR/locked-secondary/main"
git -C "$repo" worktree add -q "$secondary" main
git -C "$repo" worktree lock --reason 'contract check' "$secondary"
if "$CANONICAL" "$repo" >"$RUN_DIR/locked-secondary/out" 2>"$RUN_DIR/locked-secondary/err"; then
  fail "locked secondary main unexpectedly reconciled"
fi
[ "$(branch_of "$secondary")" = main ] || fail "locked secondary was detached"
grep -q 'locked worktree' "$RUN_DIR/locked-secondary/err" || fail "locked-secondary error was not actionable"
pass "locked secondary main is preserved and rejected"

repo="$(new_repo dirty-primary)"
printf 'keep me\n' > "$repo/uncommitted.txt"
if "$CANONICAL" "$repo" >"$RUN_DIR/dirty-primary/out" 2>"$RUN_DIR/dirty-primary/err"; then
  fail "dirty primary unexpectedly reconciled"
fi
[ "$(branch_of "$repo")" = feature/parked ] || fail "dirty primary changed branch"
[ -f "$repo/uncommitted.txt" ] || fail "dirty primary lost its file"
grep -q 'primary checkout is dirty' "$RUN_DIR/dirty-primary/err" || fail "dirty-primary error was not actionable"
pass "dirty primary checkout is preserved and rejected"

repo="$(new_repo ignored-overwrite)"
git -C "$repo" switch -q main
printf 'default contents\n' > "$repo/local.env"
git -C "$repo" add local.env
git -C "$repo" commit -q -m 'track default env'
git -C "$repo" switch -q feature/parked
printf 'local.env\n' > "$repo/.gitignore"
git -C "$repo" add .gitignore
git -C "$repo" commit -q -m 'ignore local env'
printf 'UNCOMMITTED SECRET VALUE\n' > "$repo/local.env"
secondary="$RUN_DIR/ignored-overwrite/main"
git -C "$repo" worktree add -q "$secondary" main
if "$CANONICAL" "$repo" >"$RUN_DIR/ignored-overwrite/out" 2>"$RUN_DIR/ignored-overwrite/err"; then
  fail "ignored-file collision unexpectedly reconciled"
fi
[ "$(branch_of "$repo")" = feature/parked ] || fail "ignored-file collision moved primary"
[ "$(branch_of "$secondary")" = main ] || fail "ignored-file collision did not restore secondary main"
grep -q 'UNCOMMITTED SECRET VALUE' "$repo/local.env" || fail "ignored local file was overwritten"
pass "ignored local files are preserved and ownership is rolled back"

repo="$(new_repo rebase-primary)"
printf 'feature\n' > "$repo/feature.txt"
git -C "$repo" add feature.txt
git -C "$repo" commit -q -m feature
secondary="$RUN_DIR/rebase-primary/main"
git -C "$repo" worktree add -q "$secondary" main
if git -C "$repo" rebase --exec false main >"$RUN_DIR/rebase-primary/rebase-out" 2>"$RUN_DIR/rebase-primary/rebase-err"; then
  fail "rebase setup unexpectedly completed"
fi
if "$CANONICAL" "$repo" >"$RUN_DIR/rebase-primary/out" 2>"$RUN_DIR/rebase-primary/err"; then
  fail "in-progress rebase unexpectedly reconciled"
fi
[ "$(branch_of "$secondary")" = main ] || fail "rebase failure detached secondary main"
grep -q 'operation in progress' "$RUN_DIR/rebase-primary/err" || fail "rebase error was not actionable"
pass "in-progress repository operations fail before ownership changes"

repo="$(new_repo dangling-origin-head)"
git -C "$repo" remote add origin "$RUN_DIR/dangling-origin-head/origin.git"
git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop
resolved="$($CANONICAL "$repo")"
[ "$resolved" = "$repo" ] || fail "dangling origin/HEAD returned $resolved, want $repo"
[ "$(branch_of "$repo")" = main ] || fail "dangling origin/HEAD did not fall back to main"
pass "dangling origin/HEAD falls back to a valid main branch"

repo="$(new_repo post-switch-dirty)"
mkdir -p "$repo/locked"
printf 'feature only\n' > "$repo/locked/feature.txt"
git -C "$repo" add locked/feature.txt
git -C "$repo" commit -q -m 'add feature-only file'
secondary="$RUN_DIR/post-switch-dirty/main"
git -C "$repo" worktree add -q "$secondary" main
chmod a-w "$repo/locked"
if "$CANONICAL" "$repo" >"$RUN_DIR/post-switch-dirty/out" 2>"$RUN_DIR/post-switch-dirty/err"; then
  chmod u+w "$repo/locked"
  fail "dirty post-switch checkout unexpectedly reported success"
fi
chmod u+w "$repo/locked"
[ "$(branch_of "$repo")" = feature/parked ] || fail "post-switch anomaly did not restore primary branch"
[ "$(branch_of "$secondary")" = main ] || fail "post-switch anomaly did not restore secondary main"
grep -q 'filesystem path is not writable' "$RUN_DIR/post-switch-dirty/err" || fail "unwritable path was not reported"
pass "unwritable switch paths fail before changing checkout owners"

repo="$(new_repo remote-only-master)"
git -C "$repo" remote add origin "$RUN_DIR/remote-only-master/origin.git"
git -C "$repo" update-ref refs/remotes/origin/master refs/heads/main
git -C "$repo" branch -D main >/dev/null
resolved="$($CANONICAL "$repo")"
[ "$resolved" = "$repo" ] || fail "remote-only master returned $resolved, want $repo"
[ "$(branch_of "$repo")" = master ] || fail "remote-only master was not tracked in primary"
pass "remote-only master fallback becomes the canonical primary branch"

repo="$(new_repo default-selection)"
worktrees="$RUN_DIR/default-selection/worktrees"
resolved="$(cd "$repo" && WARP_WORKTREES_DIR="$worktrees" "$SETUP" main)"
[ "$resolved" = "$repo" ] || fail "selecting main returned $resolved, want $repo"
[ "$(branch_of "$repo")" = main ] || fail "selecting main did not canonicalize the primary"
[ "$(git -C "$repo" worktree list --porcelain | grep -c '^worktree ')" -eq 1 ] \
  || fail "selecting main created a secondary worktree"
pass "selecting main never creates an external worktree"

repo="$(new_repo feature-reuse)"
git -C "$repo" switch -q main
worktrees="$RUN_DIR/feature-reuse/worktrees"
first="$(cd "$repo" && WARP_WORKTREES_DIR="$worktrees" "$SETUP" feature/shared main)"
second="$(cd "$repo" && WARP_WORKTREES_DIR="$worktrees" "$SETUP" feature/shared main)"
[ "$first" = "$second" ] || fail "feature branch did not reuse its first worktree"
[ "$(git -C "$repo" worktree list --porcelain | grep -c 'branch refs/heads/feature/shared')" -eq 1 ] \
  || fail "feature branch has more than one owning worktree"
pass "feature branch reuses one shared worktree"

repo="$(new_repo pr-reuse)"
bare="$RUN_DIR/pr-reuse/origin.git"
git init -q --bare "$bare"
git -C "$repo" remote add origin "$bare"
git -C "$repo" commit -q --allow-empty -m pr
git -C "$repo" branch feature/pr
git -C "$repo" push -q -u origin main feature/pr
git -C "$repo" switch -q main
fake_bin="$RUN_DIR/pr-reuse/bin"
mkdir -p "$fake_bin"
printf '#!/bin/sh\nprintf "feature/pr\\n"\n' > "$fake_bin/gh"
chmod +x "$fake_bin/gh"
worktrees="$RUN_DIR/pr-reuse/worktrees"
first="$(cd "$repo" && PATH="$fake_bin:$PATH" WARP_WORKTREES_DIR="$worktrees" "$PR_SETUP" 42)"
second="$(cd "$repo" && PATH="$fake_bin:$PATH" WARP_WORKTREES_DIR="$worktrees" "$PR_SETUP" 42)"
[ "$first" = "$second" ] || fail "PR branch did not reuse its first worktree"
[ "$(git -C "$repo" worktree list --porcelain | grep -c 'branch refs/heads/feature/pr')" -eq 1 ] \
  || fail "PR branch has more than one owning worktree"
pass "PR branch reuses one shared worktree"

echo "RESULT: all canonical checkout checks passed"
echo "Temporary evidence: $RUN_DIR"
