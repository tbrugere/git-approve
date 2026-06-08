# git-approve

A per-file **approval bit** for staged git changes, enforced by a global
`pre-commit` hook.

## Why

Workflow: an agent stages part of the work; a human reviews the staged diff
(e.g. with the `nvds` alias = `nvim -c "G difftool -y --cached"`) and only then
commits. Once an agent does the staging, staging can no longer double as the
approval step, and git has no native per-file "approved" flag on the index — so
this builds one.

**Core property:** approval is keyed to the **staged blob oid**, not just the
path. If different content is re-staged for an already-approved file, the oid
changes and the approval is automatically void. You can never commit content you
never reviewed.

## How it works

- `git-approve approve [paths]` records `(oid, path)` pairs in a ledger at
  `<git-dir>/approved`. The ledger's existence is the per-repo **opt-in switch**.
- The `pre-commit` hook only enforces when that ledger exists, and blocks the
  commit if any staged file's `(oid, path)` is not in it.
- The ledger lives in the **per-worktree** git directory (`repo.path`), so
  approvals are scoped per worktree and never leak across them. Removing a
  worktree removes its ledger automatically.
- The hook reads `GIT_INDEX_FILE`, so partial commits (`git commit <paths>`) are
  evaluated against exactly the subset being committed.

## Commands

```
git-approve approve [PATHS...]   # approve all staged files, or just PATHS  (alias: gok)
git-approve revoke  [PATHS...]   # un-approve all, or just PATHS (enforcement stays on)  (alias: gnok)
git-approve status  [-q] [PATHS] # show ✓/✗ per staged file; exit 1 if any pending  (alias: gcs)
git-approve enable               # opt this worktree into enforcement (empty ledger)
git-approve disable              # remove the ledger, turning enforcement off for this worktree
```

`enable`/`disable` are the explicit on/off switch for a worktree. The first
`approve` also creates the ledger, so it implicitly enables enforcement too.

git also exposes the console script as a subcommand: `git approve <subcommand>`.

`git-approve pending` prints staged-but-unapproved paths, one per line — the
hook for editor integration.

## Neovim plugin

[`nvim/`](nvim/) ships fugitive-flavored commands: `:GApproveReview` opens a
difftool of just the staged-and-unapproved files, and `:GApprove` / `:GUnapprove`
act on the current file. See [nvim/README.md](nvim/README.md).

## Development

```sh
uv sync                 # install deps + dev tools (ruff, ty, pytest)
uv run pytest           # tests against throwaway repos under tmp
uv run ruff check .     # lint
uv run ty check         # typecheck
```

Requires Python 3.14+, `click`, and `pygit2`.

## Deployment (manual)

```sh
# 1. Put `git-approve` on PATH (also enables `git approve ...`):
uv tool install .                     # or: pipx install .

# 2. Point global hooks at this project's hooks dir:
git config --global core.hooksPath /path/to/git-approve/hooks
chmod +x /path/to/git-approve/hooks/pre-commit

# 3. Shell aliases (e.g. in ~/dotfiles/zsh/.aliases):
alias gok='git-approve approve'
alias gnok='git-approve revoke'
alias gcs='git-approve status'
```

### Keeping repo-local hooks working (optional)

A global `core.hooksPath` replaces `.git/hooks` lookup wholesale, so any
repo-local hook (husky, lefthook, …) stops firing. The `pre-commit` hook already
chains a repo-local `pre-commit`. To chain the other hook names, symlink the
provided `_chain` script under each:

```sh
cd /path/to/git-approve/hooks
for h in commit-msg prepare-commit-msg pre-push post-commit \
         post-checkout post-merge pre-rebase; do
    ln -s _chain "$h"
done
```

## Known limitations

- A repo with a **local** `core.hooksPath` (e.g. husky v9) shadows the global
  hook → no enforcement there.
- GUI git clients may launch with a `PATH` that doesn't include the `git-approve`
  console script.
- Filenames containing tabs or newlines are out of scope (the ledger is
  tab-delimited, one entry per line).
- `git commit --no-verify` bypasses enforcement — the intended human escape
  hatch. Agents must not use it.
