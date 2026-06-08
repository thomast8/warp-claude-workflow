#!/usr/bin/env bash
# Open a git worktree on an existing PR's head branch, copy gitignored dev files,
# then PRINT its path (the caller cd's + launches Claude, so Warp shows the folder).
# Defaults to the current repo (inherited from the caller's cwd), else the most-recent.
# With no PR number it shows an fzf picker (bold #number, aligned title + branch + author).
#
# Worktrees live in <WARP_WORKTREES_DIR>/<repo>/pr<n> (default ~/worktrees/<repo>/pr<n>).
#
#   pr-worktree.sh [pr-number]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_lib.sh"

# Redirected block (see worktree-setup.sh): keeps the caller's stdout pipe out of git's
# background processes so $(...) can't hang; only the final path -> stdout, after it.
{
  repo_root="$(_repo_default || true)"; [ -n "$repo_root" ] || repo_root="$(_repo_pick || true)"
  { [ -n "$repo_root" ] && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; } \
    || { echo "pr-worktree: no git repository selected" >&2; exit 1; }
  cd "$repo_root"
  repo_name="$(basename "$repo_root")"
  wt_base="$(_worktree_base "$repo_root")"

  pr="${1:-}"; case "$pr" in ""|"{{"*"}}") pr="";; esac
  if [ -z "$pr" ]; then
    if command -v fzf >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
      prs="$(gh pr list --limit 50 --json number,title,headRefName,author \
               --jq '.[] | "\(.number)\t\(.title)\t\(.headRefName)\t\(.author.login)"' 2>/dev/null)"
      if [ -z "$prs" ]; then
        echo "pr-worktree: no open PRs in $repo_name - run 'caw' to start a new branch instead." >&2
        exit 1
      fi
      set +e
      sel="$(printf '%s\n' "$prs" | _format_pr_lines \
             | fzf --ansi --delimiter='\t' --with-nth=2 --prompt='PR > ' --height=40% --reverse)"
      rc=$?; set -e
      [ "$rc" -eq 0 ] || { echo "pr-worktree: cancelled" >&2; exit 130; }
      pr="$(printf '%s' "$sel" | cut -f1)"
    else
      printf 'PR number (in %s): ' "$repo_name" >&2
      read -r pr
    fi
  fi
  [ -n "$pr" ] || { echo "pr-worktree: no PR number given" >&2; exit 1; }

  branch="$(gh pr view "$pr" --json headRefName -q .headRefName 2>/dev/null)" \
    || { echo "pr-worktree: could not resolve PR #$pr (is gh authed for this repo?)" >&2; exit 1; }
  [ -n "$branch" ] || { echo "pr-worktree: empty head branch for PR #$pr" >&2; exit 1; }
  git fetch --quiet origin "$branch" 2>/dev/null || true

  # A branch can only be checked out in one worktree. If this PR's branch is already
  # checked out somewhere (incl. the main checkout), reuse that worktree instead of
  # failing with "already checked out" / "a branch named ... already exists".
  existing="$(git worktree list --porcelain \
    | awk -v b="branch refs/heads/$branch" '/^worktree /{p=substr($0,10)} $0==b{print p; exit}')"
  wt="$wt_base/pr${pr}"
  if [ -n "$existing" ]; then
    wt="$existing"
  elif [ ! -d "$wt" ]; then
    mkdir -p "$wt_base"
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git worktree add "$wt" "$branch"                      # local branch exists, not checked out
    else
      git worktree add -b "$branch" "$wt" "origin/$branch"  # create local branch from origin
    fi
  fi
  _copy_gitignored_dev_files "$repo_root" "$wt"

  # Auto-sync: move this (possibly reused, possibly stale) worktree onto the PR's
  # current head. The fetch at line ~50 updated origin/$branch, but a fetch never
  # moves the local branch - this does, hard-resetting if the PR was force-pushed or
  # rebased. Unpushed local commits (e.g. on your OWN PR) are detected and kept; see
  # _sync_worktree.
  _sync_worktree "$wt" "origin/$branch"
} >&2

printf '%s\n' "$wt"
