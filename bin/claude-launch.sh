#!/usr/bin/env bash
# Launch Claude Code, defaulting to the most-recent repo when the tab opens outside
# a repo (e.g. a Cmd+T / new tab that starts in $HOME). Reports cwd to Warp (OSC 7)
# so the tab picks up the folder + git branch. Used by claude_here.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_lib.sh"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  repo="$(_recent_repos | head -1)"
  [ -n "$repo" ] && cd "$repo"
fi
_report_cwd
exec claude
