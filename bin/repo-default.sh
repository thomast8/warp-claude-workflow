#!/usr/bin/env bash
# Print the default repo: the current one if invoked inside a repo, else the
# most-recently-used repo from the recent-repos state file (maintained by the zshrc
# chpwd hook). Prints nothing if neither is available. Used by the claude_here tab
# config so a new "Claude here" tab lands in the repo you were working in instead of
# $HOME. NOTE: a tab config runs in $HOME, so this resolves to the most-recent repo,
# not necessarily the tab you came from - Warp can't tell a tab config that.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_lib.sh"
# Current repo if we're inside one; otherwise the most-recent repo. A tab config always
# runs in $HOME (never inside a repo), so in practice this is recent-repos[0] = the repo
# you were last working in. The shared _repo_default() stays strict (no recents fallback)
# for the worktree/PR pickers; the fallback lives here, where there's no picker to mislead.
d="$(_repo_default || true)"
[ -n "$d" ] || d="$(_recent_repos | head -n1 || true)"
[ -n "$d" ] && printf '%s\n' "$d"
