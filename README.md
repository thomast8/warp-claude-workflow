# warp-claude-workflow

The Claude-Code-specific [Warp](https://www.warp.dev/) machinery: **launch configs + worktree scripts** for running [Claude Code](https://www.claude.com/product/claude-code) with native worktree tabs. Maps to `~/.warp/{tab_configs,bin}`.

Generic Warp settings (theme, keybindings) are **not** here - Warp's own cloud Settings Sync owns those on your account. Only the custom scripts Warp never syncs live in this repo. See "Recommended Warp settings" below for what to toggle yourself.

## What's here

- `tab_configs/` - launch configs: `claude_worktree` (`Cmd+T`: new-branch worktree + Claude), `claude_pr` (pick an open PR via fzf -> worktree + Claude), `claude_here` (Claude in the current repo).
- `bin/` - the worktree machinery the launchers call: pick a repo/PR, create the worktree under `${WARP_WORKTREES_DIR:-~/worktrees}/<repo>/<name>`, copy gitignored dev files (`.env*`, `.claude/settings.local.json`), report cwd to Warp (OSC 7), and launch Claude. Pairs with the `ca` / `caw` shell launchers in [`shell-editor-dotfiles`](https://github.com/thomast8/shell-editor-dotfiles).

## Recommended Warp settings

Set these in your own Warp (they cloud-sync to your account):

- Third-party CLI-agent toolbar on; auto-open composer on agent start.
- Vertical tabs; Option-as-Meta on the left Option key (for Claude Code shortcuts).
- `Cmd+T` = a plain terminal that inherits the current repo (`working_directory_config = previous_dir`); `Cmd+D` split right, `Cmd+Shift+D` split down.
- Notifications via the official `warp@claude-code-warp` plugin.

## Use it

Copy `tab_configs/` and `bin/` into `~/.warp/` (`chmod +x ~/.warp/bin/*`), or let [`mac-dev-bootstrap`](https://github.com/thomast8/mac-dev-bootstrap) lay them down. Identity-free.
