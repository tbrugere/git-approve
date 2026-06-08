# git-approve.nvim

Fugitive-flavored commands for [`git-approve`](../README.md). Requires
[vim-fugitive](https://github.com/tpope/vim-fugitive) and the `git-approve`
executable on `$PATH`.

## Commands

| Command           | Description                                                                 |
|-------------------|-----------------------------------------------------------------------------|
| `:GApproveReview` | Like `:Git difftool -y --cached`, but shows only staged files that are **not approved** — your review queue. |
| `:GApprove [path]`  | Approve `path` (defaults to the current file, fugitive buffers included).  |
| `:GUnapprove [path]`| Revoke `path` (defaults to the current file).                              |

The typical loop: `:GApproveReview` to diff the unapproved staged files, then
`:GApprove` on each one you've reviewed (works from inside the diff buffer).

Anything else is already available through fugitive's passthrough, e.g.
`:Git approve .`, `:Git approve status`, `:Git approve enable`.

## Install

The plugin lives in this `nvim/` subdirectory of the repo.

**lazy.nvim** (point at the local checkout):

```lua
{
  dir = "~/Code/git-approve/nvim",
  dependencies = { "tpope/vim-fugitive" },
}
```

**packer.nvim:**

```lua
use { "~/Code/git-approve", rtp = "nvim", requires = "tpope/vim-fugitive" }
```

**Manual:** symlink it onto your `runtimepath`, e.g.

```sh
ln -s ~/Code/git-approve/nvim ~/.config/nvim/pack/plugins/start/git-approve
```
