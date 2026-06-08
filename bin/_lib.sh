#!/usr/bin/env bash
# Shared helpers for the Warp worktree tab configs / launchers.

WARP_STATE_DIR="${WARP_STATE_DIR:-$HOME/.warp/state}"
RECENTS_FILE="$WARP_STATE_DIR/recent-repos"

# Copy gitignored dev files (env + editor/agent config) from a main checkout into
# a freshly created worktree, so the worktree is immediately runnable.
_copy_gitignored_dev_files() {
  local src="$1" dst="$2" item
  # Small gitignored env / editor files - safe to copy wholesale.
  for item in .env .env.local .env.development.local .env.production.local .env.test.local .envrc .zed; do
    if [ -e "$src/$item" ] && [ ! -e "$dst/$item" ]; then
      cp -R "$src/$item" "$dst/$item" 2>/dev/null && echo "worktree: copied $item" >&2
    fi
  done
  # .claude: copy ONLY the gitignored local settings, never the whole directory. A
  # repo's .claude can balloon to gigabytes (nested worktrees/, session logs) - a
  # recursive copy would stall for minutes and duplicate nested git worktrees.
  if [ -f "$src/.claude/settings.local.json" ] && [ ! -e "$dst/.claude/settings.local.json" ]; then
    mkdir -p "$dst/.claude" \
      && cp "$src/.claude/settings.local.json" "$dst/.claude/settings.local.json" 2>/dev/null \
      && echo "worktree: copied .claude/settings.local.json" >&2
  fi
}

# Main worktree root for the current repo (so we base new worktrees off the primary
# checkout even from inside a linked worktree).
_main_repo_root() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}'
}

# Central base for worktrees: <WARP_WORKTREES_DIR>/<repo-name>/ (default ~/worktrees).
# Keeps both ~/GitRepos and the repo itself clean (no siblings, no in-tree dirs that
# tools would recurse into). Pass the main repo root.
_worktree_base() {
  printf '%s/%s' "${WARP_WORKTREES_DIR:-$HOME/worktrees}" "$(basename "$1")"
}

# Report the current directory to Warp via OSC 7. Tab configs run our script and we
# cd + exec straight into claude, so the shell never emits its own cwd update - we
# must, or the tab/sidebar/bottom-bar stay stuck on the launch dir ($HOME) with no
# folder or git branch.
_report_cwd() {
  printf '\033]7;file://%s%s\a' "${HOST:-${HOSTNAME:-$(hostname 2>/dev/null)}}" "$PWD"
}

# Recently-focused repos (most-recent-first), existing only. Maintained by the
# zshrc chpwd hook.
_recent_repos() {
  [ -f "$RECENTS_FILE" ] || return 0
  while IFS= read -r r; do [ -n "$r" ] && [ -d "$r" ] && printf '%s\n' "$r"; done < "$RECENTS_FILE"
}

# Default repo: the current one (main worktree root) if inside a repo, else NOTHING -
# so callers fall through to _repo_pick and prompt. We deliberately do NOT silently use
# the most-recent repo: recent-repos only updates on cd (not on tab focus, which Warp
# can't reliably report), so from a $HOME tab it'd be stale and pick the wrong repo
# (e.g. a PR picker showing 0 results). _repo_pick lists recents first, so the likely
# repo is still one keystroke.
_repo_default() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 && _main_repo_root
}

# Pick a repo: most-recent-first, then every other repo under ~/GitRepos, deduped (so
# you can always reach a repo you haven't cd'd into lately, with recents on top). fzf
# if available, else a numbered menu.
_repo_pick() {
  local repos
  repos="$({ _recent_repos; find "${GIT_REPOS_DIR:-$HOME/GitRepos}" -maxdepth 2 -type d -name .git -prune 2>/dev/null | sed 's#/\.git$##'; } | awk 'NF && !seen[$0]++')"
  [ -n "$repos" ] || return 1
  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$repos" | fzf --prompt='repo > ' --height=40% --reverse
  else
    local sel
    PS3='repo #: '
    select sel in $repos; do [ -n "$sel" ] && { printf '%s' "$sel"; break; }; done
  fi
}

# Format raw "number<TAB>title<TAB>branch<TAB>author" lines into
# "number<TAB><aligned ANSI display>": bold #number index, truncated+padded title
# and branch, then @author. Pipe the display through fzf with --ansi --with-nth=2.
_format_pr_lines() {
  awk -F'\t' '
    function trunc(s, n) { return (length(s) > n) ? substr(s, 1, n - 1) "…" : s }
    { printf "%s\t\033[1m#%-5s\033[0m %-50s  \033[2m⎇ %-28s @%s\033[0m\n", \
             $1, $1, trunc($2, 50), trunc($3, 28), $4 }'
}

# Does <wt>'s HEAD sit on a commit the remote-tracking ref <tracking> has pointed at,
# now or anywhere in its reflog? If yes, every local commit was fetched from the
# remote before it moved, so a divergence is a force-push/rebase and resetting onto
# <tracking> loses nothing that wasn't already published. If no, the local branch
# carries commits authored locally and never pushed - which must not be reset. This
# is what separates "someone rebased this PR" (safe to take, even your OWN PR) from
# "I have unpushed work on this branch" (keep it), and unlike a patch-id check it
# still recognizes the force-push when the rebase also changed commit content.
_head_was_published_on() {
  local wt="$1" tracking="$2" head sha
  head="$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null)" || return 1
  for sha in $(git -C "$wt" rev-parse --verify --quiet "$tracking" 2>/dev/null) \
             $(git -C "$wt" reflog show --format='%H' "$tracking" 2>/dev/null); do
    git -C "$wt" merge-base --is-ancestor "$head" "$sha" 2>/dev/null && return 0
  done
  return 1
}

# Bring a reused worktree's checked-out branch up to <tracking> (a remote-tracking
# ref) as aggressively as is SAFE, so a tab opens on current code instead of a stale
# snapshot. Callers already ran `git fetch`, but a fetch only moves the remote-
# tracking ref - this is what actually advances the local branch. Uncommitted changes
# are ALWAYS stashed first and re-applied after, never dropped; committed work that
# was never published is never discarded (see _head_was_published_on).
#
#   _sync_worktree <wt> <tracking>
#
# - behind, not diverged -> fast-forward.
# - diverged but HEAD was published on <tracking> before -> force-push/rebase, so
#   hard-reset onto it (dropped commits are stale copies, recoverable via reflog).
# - diverged with genuinely unpushed local commits -> leave the branch and warn.
_sync_worktree() {
  local wt="$1" target="$2" behind ahead action="ff" ok=0 stashed=0
  git -C "$wt" rev-parse --verify --quiet "$target^{commit}" >/dev/null 2>&1 || return 0

  behind="$(git -C "$wt" rev-list --count "HEAD..$target" 2>/dev/null || echo 0)"
  [ "${behind:-0}" -gt 0 ] || return 0           # already current (or only ahead) -> nothing to do
  ahead="$(git -C "$wt" rev-list --count "$target..HEAD" 2>/dev/null || echo 0)"

  if [ "${ahead:-0}" -gt 0 ]; then               # diverged: reset only if nothing local is unpublished
    if _head_was_published_on "$wt" "$target"; then
      action="reset"
    else
      action="bail"
    fi
  fi

  if [ "$action" = "bail" ]; then
    printf 'worktree: %s commit(s) behind %s and you have unpushed local commits - left as-is (git rebase %s)\n' \
      "$behind" "$target" "$target" >&2
    return 0
  fi

  # Stash tracked + untracked changes so the sync can't clobber them.
  if ! { git -C "$wt" diff --quiet 2>/dev/null && git -C "$wt" diff --cached --quiet 2>/dev/null; }; then
    if git -C "$wt" stash push -u -m 'warp-autosync' >/dev/null 2>&1; then
      stashed=1
    else
      printf 'worktree: warning: %s behind %s but local changes would not stash - left as-is (git pull)\n' \
        "$behind" "$target" >&2
      return 0
    fi
  fi

  if [ "$action" = "reset" ]; then
    if git -C "$wt" reset --hard "$target" >/dev/null 2>&1; then
      ok=1
      printf 'worktree: %s was force-pushed; reset onto it (%s stale local commit(s) saved in reflog)\n' \
        "$target" "$ahead" >&2
    fi
  else
    if git -C "$wt" merge --ff-only "$target" >/dev/null 2>&1; then
      ok=1
      printf 'worktree: synced %s commit(s) to %s\n' "$behind" "$target" >&2
    fi
  fi
  [ "$ok" = 1 ] || printf 'worktree: warning: could not advance to %s\n' "$target" >&2

  if [ "$stashed" = 1 ]; then
    if git -C "$wt" stash pop >/dev/null 2>&1; then
      printf 'worktree: re-applied your uncommitted changes on top of %s\n' "$target" >&2
    else
      printf 'worktree: warning: uncommitted changes are stashed but conflicted on re-apply - run: git -C %s stash pop\n' "$wt" >&2
    fi
  fi
  return 0
}
