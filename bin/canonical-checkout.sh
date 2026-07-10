#!/usr/bin/env bash
# Reconcile a repository so its primary checkout owns the default branch, then print
# the primary path. Clean secondary default-branch worktrees are detached in place;
# dirty, locked, missing, or otherwise unsafe states fail without discarding work.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/_lib.sh"

requested="${1:-}"
[ -n "$requested" ] \
  || { echo "canonical-checkout: pass a repository path" >&2; exit 2; }
git -C "$requested" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "canonical-checkout: not a git repository: $requested" >&2; exit 2; }

repo_root="$(git -C "$requested" worktree list --porcelain \
  | awk '/^worktree /{print substr($0,10); exit}')"
[ -n "$repo_root" ] && [ -d "$repo_root" ] \
  || { echo "canonical-checkout: primary checkout is missing for $requested" >&2; exit 1; }

default_branch="$(_default_branch "$repo_root" || true)"
[ -n "$default_branch" ] \
  || { echo "canonical-checkout: could not resolve origin/HEAD, main, or master in $repo_root" >&2; exit 1; }

current_branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
if [ "$current_branch" = "$default_branch" ]; then
  printf '%s\n' "$repo_root"
  exit 0
fi

operation_in_progress() {
  local worktree="$1" git_dir state
  git_dir="$(git -C "$worktree" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  for state in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer; do
    if [ -e "$git_dir/$state" ]; then
      printf '%s\n' "$state"
      return 0
    fi
  done
  return 1
}

if operation="$(operation_in_progress "$repo_root")"; then
  echo "canonical-checkout: repository operation in progress ($operation): $repo_root" >&2
  echo "canonical-checkout: finish or abort it explicitly, then retry" >&2
  exit 1
fi

# Capture the complete worktree record holding the default branch. The record carries
# lock/prunable flags that are not present on the branch line itself.
record="$(git -C "$repo_root" worktree list --porcelain \
  | awk -v target="refs/heads/$default_branch" 'BEGIN{RS=""; FS="\n"} {
      for (i=1; i<=NF; i++) if ($i == "branch " target) { print; exit }
    }')"
holder="$(printf '%s\n' "$record" | awk '/^worktree /{print substr($0,10); exit}')"

if [ -n "$holder" ] && [ "$holder" != "$repo_root" ]; then
  if printf '%s\n' "$record" | grep -Eq '^locked($| )'; then
    echo "canonical-checkout: '$default_branch' is held by locked worktree: $holder" >&2
    echo "canonical-checkout: close its agent/session and unlock it explicitly, then retry" >&2
    exit 1
  fi
  if printf '%s\n' "$record" | grep -Eq '^prunable($| )' || [ ! -d "$holder" ]; then
    echo "canonical-checkout: '$default_branch' has a stale worktree registration: $holder" >&2
    echo "canonical-checkout: inspect it and run 'git worktree prune' explicitly, then retry" >&2
    exit 1
  fi
  if operation="$(operation_in_progress "$holder")"; then
    echo "canonical-checkout: repository operation in progress ($operation): $holder" >&2
    echo "canonical-checkout: finish or abort it explicitly, then retry" >&2
    exit 1
  fi
  if [ -n "$(git -C "$holder" status --porcelain=v1 --untracked-files=all)" ]; then
    echo "canonical-checkout: '$default_branch' is held by dirty worktree: $holder" >&2
    echo "canonical-checkout: commit or stash its changes, then retry" >&2
    exit 1
  fi
fi

if [ -n "$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)" ]; then
  shown_branch="${current_branch:-detached HEAD}"
  echo "canonical-checkout: primary checkout is dirty on '$shown_branch': $repo_root" >&2
  echo "canonical-checkout: commit or stash its changes, then retry" >&2
  exit 1
fi

if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$default_branch"; then
  target_ref="$default_branch"
elif git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$default_branch"; then
  target_ref="origin/$default_branch"
else
  echo "canonical-checkout: default branch '$default_branch' disappeared before switching" >&2
  exit 1
fi

# Git can report a successful switch while leaving old files behind when their parent
# directory is not writable. Check every path that differs between the two trees before
# changing either checkout owner.
git -C "$repo_root" diff --name-only HEAD "$target_ref" -- >/dev/null \
  || { echo "canonical-checkout: could not preflight '$default_branch' paths" >&2; exit 1; }
while IFS= read -r -d '' changed_path; do
  parent="$repo_root/$(dirname "$changed_path")"
  while [ ! -d "$parent" ] && [ "$parent" != "$repo_root" ]; do
    parent="$(dirname "$parent")"
  done
  if [ ! -w "$parent" ]; then
    echo "canonical-checkout: filesystem path is not writable for '$changed_path': $parent" >&2
    echo "canonical-checkout: fix its permissions explicitly, then retry" >&2
    exit 1
  fi
done < <(git -C "$repo_root" diff --name-only -z HEAD "$target_ref" --)

original_branch="$current_branch"
original_sha="$(git -C "$repo_root" rev-parse --verify HEAD)"
holder_detached=0

rollback_ownership() {
  local ok=0 actual_branch actual_sha backup path
  actual_branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  actual_sha="$(git -C "$repo_root" rev-parse --verify HEAD 2>/dev/null || true)"
  if { [ -n "$original_branch" ] && [ "$actual_branch" != "$original_branch" ]; } \
    || { [ -z "$original_branch" ] && { [ -n "$actual_branch" ] || [ "$actual_sha" != "$original_sha" ]; }; }; then
    backup=""
    while IFS= read -r -d '' path; do
      [ -n "$backup" ] || backup="$(mktemp -d "${TMPDIR:-/tmp}/canonical-checkout-rollback.XXXXXX")"
      mkdir -p "$backup/$(dirname "$path")"
      if mv "$repo_root/$path" "$backup/$path"; then
        echo "canonical-checkout: preserved rollback obstruction at $backup/$path" >&2
      else
        ok=1
      fi
    done < <(git -C "$repo_root" ls-files --others --exclude-standard -z)
  fi
  if [ -n "$original_branch" ]; then
    if [ "$actual_branch" != "$original_branch" ]; then
      git -C "$repo_root" switch --no-overwrite-ignore "$original_branch" >&2 || ok=1
    fi
  elif [ -n "$original_sha" ] && { [ -n "$actual_branch" ] || [ "$actual_sha" != "$original_sha" ]; }; then
    git -C "$repo_root" switch --detach --no-overwrite-ignore "$original_sha" >&2 || ok=1
  fi
  if [ "$holder_detached" -eq 1 ]; then
    git -C "$holder" switch "$default_branch" >&2 || ok=1
  fi
  return "$ok"
}

fail_after_mutation() {
  local reason="$1"
  echo "canonical-checkout: $reason" >&2
  if rollback_ownership; then
    echo "canonical-checkout: restored the original checkout ownership" >&2
  else
    echo "canonical-checkout: rollback was incomplete; inspect both worktrees before continuing" >&2
  fi
  exit 1
}

if [ -n "$holder" ] && [ "$holder" != "$repo_root" ]; then
  git -C "$holder" switch --detach >&2 \
    || { echo "canonical-checkout: could not detach default branch worktree: $holder" >&2; exit 1; }
  holder_detached=1
fi

if [ "$target_ref" = "$default_branch" ]; then
  git -C "$repo_root" switch --no-overwrite-ignore "$default_branch" >&2 \
    || fail_after_mutation "could not switch the primary checkout to '$default_branch'"
else
  git -C "$repo_root" switch --no-overwrite-ignore --track -c "$default_branch" "origin/$default_branch" >&2 \
    || fail_after_mutation "could not create local tracking branch '$default_branch'"
fi

actual_branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
remaining="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)"
if [ "$actual_branch" != "$default_branch" ] || [ -n "$remaining" ]; then
  fail_after_mutation "post-switch verification failed for '$default_branch' in $repo_root"
fi

printf '%s\n' "$repo_root"
