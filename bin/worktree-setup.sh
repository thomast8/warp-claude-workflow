#!/usr/bin/env bash
# Create a new-branch git worktree, copy gitignored dev files, then PRINT its path.
# The caller (the `caw` shell function, or a tab config's two-step cd + claude) does
# the cd + Claude launch in its own shell, so Warp's integration shows the worktree
# folder + branch and you stay in the worktree when Claude exits.
#
# Worktrees live in a central base, <WARP_WORKTREES_DIR>/<repo>/<branch> (default
# ~/worktrees/<repo>/<branch>) - keeps both ~/GitRepos and the repo itself clean.
#
#   worktree-setup.sh [--pick-repo] [branch] [base-ref]
#
# --pick-repo : prompt for which repo (among your active/recent ones). Used by the
#               worktree tab config, which opens in $HOME and so can't inherit a repo.
# Without it  : default to the current repo (inherited from the caller's cwd), else
#               the most-recently-used repo.
# No branch (or an un-substituted {{...}}) -> prompts for one, and re-prompts if the
# name can't be used (clashes with an existing branch or a "<name>/..." namespace).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_lib.sh"

# Everything below runs with stdout redirected to stderr, so prompts, git progress and
# "copied ..." lines stay visible but never pollute the captured value. This MUST be a
# redirected block, not `exec 3>&1`: it keeps the caller's stdout pipe out of every
# child's fd table, so a background `git gc --auto` (spawned by `git fetch`) can't
# inherit it and hang the caller's $(...). Only the final path, printed after the
# block, reaches real stdout.
{
  pick=0
  if [ "${1:-}" = "--pick-repo" ]; then pick=1; shift; fi

  if [ "$pick" -eq 1 ]; then
    repo_root="$(_repo_pick || true)"
  else
    repo_root="$(_repo_default || true)"
    [ -n "$repo_root" ] || repo_root="$(_repo_pick || true)"
  fi
  { [ -n "$repo_root" ] && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; } \
    || { echo "worktree-setup: no git repository selected" >&2; exit 1; }
  cd "$repo_root"
  repo_name="$(basename "$repo_root")"
  wt_base="$(_worktree_base "$repo_root")"
  mkdir -p "$wt_base"

  base="${2:-}"; case "$base" in "{{"*"}}") base="";; esac
  if [ -z "$base" ]; then
    if   git show-ref --verify --quiet refs/remotes/origin/main;   then base="origin/main"
    elif git show-ref --verify --quiet refs/remotes/origin/master; then base="origin/master"
    else base="HEAD"; fi
  fi
  git fetch --quiet origin 2>/dev/null || true

  # Acquire a usable branch name and create its worktree. On creation failure (name
  # clashes with an existing branch or a "<name>/..." namespace, or the branch is
  # already checked out elsewhere) re-prompt when interactive; bail if the name was
  # passed as an argument.
  branch_arg="${1:-}"; case "$branch_arg" in "{{"*"}}") branch_arg="";; esac
  branch="$branch_arg"
  while :; do
    if [ -z "$branch" ]; then
      printf 'New branch name (in %s): ' "$repo_name" >&2
      read -r branch || { echo "worktree-setup: cancelled" >&2; exit 130; }
    fi
    [ -n "$branch" ] || { echo "worktree-setup: no branch name given" >&2; exit 1; }
    safe_branch="${branch//\//-}"
    wt="$wt_base/$safe_branch"
    if [ -d "$wt" ]; then
      break                                                  # worktree dir already exists -> reuse
    elif git show-ref --verify --quiet "refs/heads/$branch"; then
      if git worktree add "$wt" "$branch"; then break; fi    # existing branch -> check it out
    else
      if git worktree add -b "$branch" "$wt" "$base"; then break; fi   # new branch
    fi
    [ -n "$branch_arg" ] && exit 1                           # name came from an argument -> don't loop
    echo "worktree-setup: could not create a worktree for '$branch' (see git error above); try another name." >&2
    branch=""
  done
  _copy_gitignored_dev_files "$repo_root" "$wt"

  # Auto-sync: fast-forward to the upstream tracking ref if the worktree is behind and clean.
  # Applies when an existing worktree is reused - new worktrees start fresh from $base.
  upstream="$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [ -n "$upstream" ]; then
    behind="$(git -C "$wt" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)"
    if [ "$behind" -gt 0 ]; then
      if git -C "$wt" diff --quiet 2>/dev/null && git -C "$wt" diff --cached --quiet 2>/dev/null; then
        git -C "$wt" merge --ff-only "$upstream" >/dev/null 2>&1 \
          && printf 'worktree: synced %s commit(s) to %s\n' "$behind" "$upstream" >&2 \
          || printf 'worktree: warning: could not fast-forward to %s\n' "$upstream" >&2
      else
        printf 'worktree: warning: %s commit(s) behind %s (dirty worktree - run: git pull)\n' "$behind" "$upstream" >&2
      fi
    fi
  fi
} >&2

printf '%s\n' "$wt"
