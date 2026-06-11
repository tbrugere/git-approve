# git-approve.nvim

A small **Neovim (Lua)** plugin for [`git-approve`](../README.md). Requires the
`git-approve` executable on `$PATH`. No other dependencies — the review diff is
implemented directly on `git`, not on vim-fugitive.

## Commands

| Command           | Description                                                                 |
|-------------------|-----------------------------------------------------------------------------|
| `:GApproveReview` | Open a diff tab for each staged-but-**unapproved** file (your review queue): HEAD on the left, the **staged** version on the right. Newly-added files (no HEAD version) are shown fullscreen, with no empty side. |
| `:GApprove [path]`  | Approve `path` (defaults to the current file; works from inside a review diff). |
| `:GUnapprove [path]`| Revoke `path` (defaults to the current file).                              |
| `:GApproveStage`    | Stage the current buffer's text into the index (the working-tree file is **not** modified) and approve it — "lock in what I'm looking at." Works on a normal file buffer or on a review diff's staged side. |

The typical loop: `:GApproveReview` to diff the unapproved staged files, then
`:GApprove` on each one you've reviewed (works from inside the diff).

**Auto-refresh.** While a `:GApproveReview` diff is open, the staged (right) side
updates automatically when a file is re-staged — whether from a terminal
(`git add` / `gok`) or from `:GApproveStage`. It uses a libuv filesystem watch on
the git directory (falling back to polling where fs-events aren't supported), so
it does not depend on terminal/tmux focus events. A buffer you've edited yourself
is left alone, so in-progress changes are never clobbered.

**Editable staged side.** The right (staged) buffer is editable: tweak it and run
`:GApproveStage` to re-stage exactly what you typed and approve it, all without
touching the working tree.

## Install

The plugin lives in this `nvim/` subdirectory of the repo; `plugin/*.lua`
auto-loads off the runtimepath.

**lazy.nvim** (point at the local checkout):

```lua
{ dir = "~/Code/git-approve/nvim" }
```

**packer.nvim:**

```lua
use { "~/Code/git-approve", rtp = "nvim" }
```

**Manual:** symlink it onto your `runtimepath`, e.g.

```sh
ln -s ~/Code/git-approve/nvim ~/.config/nvim/pack/plugins/start/git-approve
```
