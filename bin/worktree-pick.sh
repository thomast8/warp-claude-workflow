#!/usr/bin/env bash
# Worktree picker: pick an open PR (by title) or start a new branch, create the
# worktree (copying gitignored dev files), and PRINT its path. Defaults to the
# current repo, inherited from the caller's cwd - run it from a repo (or a Cmd+D
# split, which inherits the repo) and it won't ask which repo. The `caw` shell
# function captures the printed path and does `cd` + `claude` so Warp shows the
# worktree folder + branch and you stay in it on exit.
#
#   worktree-pick.sh [branch]   # a branch arg skips the picker -> straight to new branch
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_lib.sh"

arg="${1:-}"; case "$arg" in "{{"*"}}") arg="";; esac
[ -n "$arg" ] && exec "$SCRIPT_DIR/worktree-setup.sh" "$arg"

repo_root="$(_repo_default || true)"; [ -n "$repo_root" ] || repo_root="$(_repo_pick || true)"
{ [ -n "$repo_root" ] && git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; } \
  || { echo "worktree-pick: no git repository selected" >&2; exit 1; }
cd "$repo_root"
_export_gh_token

if ! command -v fzf >/dev/null 2>&1; then
  exec "$SCRIPT_DIR/worktree-setup.sh"   # no fzf: just prompt for a new branch
fi

set +e
sel="$( { printf '\t\033[1m  +\033[0m new branch…\n'
          command -v gh >/dev/null 2>&1 && \
            gh pr list --limit 50 --json number,title,headRefName,author \
              --jq '.[] | "\(.number)\t\(.title)\t\(.headRefName)\t\(.author.login)"' 2>/dev/null \
              | _format_pr_lines
        } | fzf --ansi --delimiter='\t' --with-nth=2 --prompt='worktree > ' --height=40% --reverse )"
rc=$?; set -e
[ "$rc" -eq 0 ] || { echo "worktree-pick: cancelled" >&2; exit 130; }

num="$(printf '%s' "$sel" | cut -f1)"
if [ -n "$num" ]; then
  exec "$SCRIPT_DIR/pr-worktree.sh" "$num"
else
  exec "$SCRIPT_DIR/worktree-setup.sh"
fi
