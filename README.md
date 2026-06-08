# warp-claude-workflow

The Claude-Code-specific [Warp](https://www.warp.dev/) machinery: **launch configs + worktree scripts** for running [Claude Code](https://www.claude.com/product/claude-code) with native worktree tabs. Maps to `~/.warp/{tab_configs,bin}`.

Generic Warp settings (theme, keybindings) are **not** here - Warp's own cloud Settings Sync owns those on your account. Only the custom scripts Warp never syncs live in this repo. See "Recommended Warp settings" below for what to toggle yourself.

## What's here

- `tab_configs/` - `launch` (the unified [wlaunch](https://github.com/thomast8/wlaunch) TUI via `wl`) plus `claude_continue` / `claude_resume` / `claude_split` (Claude conversation resume + side-by-side panes - the cases wlaunch doesn't cover). The per-flavour here/PR/worktree Claude and lazygit/serie launchers are retired; wlaunch handles those.
- `bin/` - the worktree machinery the launchers call: pick a repo/PR, create the worktree under `${WARP_WORKTREES_DIR:-~/worktrees}/<repo>/<name>`, copy gitignored dev files (`.env*`, `.claude/settings.local.json`), report cwd to Warp (OSC 7), and launch the tool. Pairs with the `ca` / `caw` / `wl` shell launchers in [`shell-editor-dotfiles`](https://github.com/thomast8/shell-editor-dotfiles).

The `launch` tab config runs the `wl` shell function, which drives the `wlaunch`
binary (built to `~/.warp/bin/wlaunch`). `Cmd+T` stays a plain terminal; reach the
launcher via the **`+` menu** ("Launch · pick" → opens it as a tab) or by typing `wl`.
(Native Warp *launch configurations* would also put it in the Command Palette, but they
always open a **new window** - a known Warp limitation - so the tab config is the
in-window path. Warp also can't bind a key directly to a config.)

## Recommended Warp settings

Set these in your own Warp (they cloud-sync to your account):

- Third-party CLI-agent toolbar on; auto-open composer on agent start.
- Vertical tabs; Option-as-Meta on the left Option key (for Claude Code shortcuts).
- `Cmd+T` = a plain terminal that inherits the current repo (`working_directory_config = previous_dir`); `Cmd+D` split right, `Cmd+Shift+D` split down.
- Notifications via the official `warp@claude-code-warp` plugin.

## Use it

Copy `tab_configs/` and `bin/` into `~/.warp/` (`chmod +x ~/.warp/bin/*`), or let [`mac-dev-bootstrap`](https://github.com/thomast8/mac-dev-bootstrap) lay them down. Identity-free.
