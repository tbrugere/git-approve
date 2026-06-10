# git-approve

A per-file **approval bit** for staged git changes, enforced by a global
`pre-commit` hook.

## Why

My workflow before:
- elaborate detailed plan with agent
- agent codes everything, but does not stage or commit
- I review every file. Each time I reviewed a file I stage it (generally using `nvim + fugitive` for difftool)
- I commit and push

Pain point: that review process is painful because I have to review all the code for the whole feature at once. It would be easier to review smaller patches. Plus it would be better for my git history too. Model could just stage a partial commit, and I could review that. 

Problem: That’s great, but now I cannot use the staging area to mark changes as approved, since the model stages partial changes. Hence tooling to mark staged changes as approved.

New Workflow: an agent stages part of the work; a human reviews the staged diff
(e.g. with the `nvds` alias = `nvim -c "G difftool -y --cached"`) and only then
commits. Once an agent does the staging, staging can no longer double as the
approval step, and git has no native per-file "approved" flag on the index — so
this builds one.

Alternative: I could keep this workflow, but have the model `git stash` all pending changes but the part I’m reviewing. But with multiple worktrees working in parallel, managing all those stashes would become hell.

**Core property 1:** This ships with a pre-commit hook that checks for approval on all staged changes when enabled. You cannot commit unapproved changes. Now I feel quite a lot more confident allowing my agent to commit / stage itself because the code still *has* to go through me.

**Core property 2:** approval is keyed to the **staged blob oid**, not just the
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
git-approve pending              # list staged-but-unapproved paths (one per line)
git-approve wait [--timeout S]   # block until everything staged is approved, then exit 0
```

`enable`/`disable` are the explicit on/off switch for a worktree. The first
`approve` also creates the ledger, so it implicitly enables enforcement too.

git also exposes the console script as a subcommand: `git approve <subcommand>`.

`git-approve pending` prints staged-but-unapproved paths, one per line — the
hook for editor integration.

## Agent workflow

`git-approve wait` lets an agent hand off for human review without polling:
the agent stages partial work and runs `wait` in the **background**, which
blocks until every staged file is approved, then exits 0. In Claude Code, a
backgrounded command resuming the agent on exit means the loop is just:

1. stage work, `git-approve enable` (if not already on);
2. run `git-approve wait` as a background task and end the turn;
3. on resume (all approved), commit.

The staged set is re-checked each poll, so files staged or re-staged while
waiting are picked up. `--timeout` is a safety valve (exit 1).

### Claude Code skills

Two skills under [`.claude/skills/`](.claude/skills/) drive an agent through the
gate (neither ever approves on your behalf):

- **[`/approve-gate`](.claude/skills/approve-gate/SKILL.md)** — gate a single
  staged batch: stage → `enable` → background `wait` → commit on resume.
- **[`/commit-review`](.claude/skills/commit-review/SKILL.md)** — split the work
  into small atomic commits, then for each one stage it, ping you, wait for
  approval, and commit before moving to the next.

Install them personally so they work in any project:

```sh
ln -s "$(pwd)/.claude/skills/approve-gate"  ~/.claude/skills/approve-gate
ln -s "$(pwd)/.claude/skills/commit-review" ~/.claude/skills/commit-review
# or copy:  cp -r .claude/skills/* ~/.claude/skills/
```

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
