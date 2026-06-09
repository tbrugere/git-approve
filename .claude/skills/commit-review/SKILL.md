---
name: commit-review
description: >-
  Commit work as a series of small, atomic commits, gating each one on human
  review before it lands. Use when the user wants their changes committed but
  wants to review each commit first ("commit and let me review", "split into
  atomic commits and let me approve each one", "review-driven commits"). For
  each commit it stages just that change, pings the user, waits via the
  git-approve CLI until it is approved, then commits and moves to the next.
  Requires the git-approve CLI and its pre-commit hook installed.
argument-hint: [scope / instructions]
---

# commit-review

Turn the current changes into a sequence of small, atomic commits, and gate each
one on the human's approval before it is committed.

**Rules**
- Never approve on the user's behalf (do not run `git-approve approve`) and never
  bypass the hook (`git commit --no-verify`). You stage, ping, and wait —
  approval is the human's.
- Follow the project's existing commit conventions (study `git log` first).
- Each commit must be atomic and self-consistent (ideally independently
  buildable): split unrelated changes apart, keep related ones together.

## 1. Plan the commits

- See what changed: `git status`, `git diff`, `git diff --cached`.
- Infer conventions from history: `git log --oneline -20` plus a few full
  messages, for message style, prefixes, and how finely commits are split.
- Draft an **ordered list of atomic commits** — each with the files/hunks it
  covers and a proposed message — and show it to the user before starting.
  Fold in `$ARGUMENTS` if provided.
- Turn enforcement on so commits are actually gated: `git-approve enable`.

## 2. Per-commit loop

For each planned commit, in order:

1. **Stage exactly that commit.** Stage only its paths or hunks
   (`git add <paths>`, or `git add -p` for partial files); leave everything else
   unstaged. Verify with `git-approve pending` that the staged set is precisely
   what you intend for this commit.
2. **Ping the user** that commit *N of M* is staged for review — by whatever
   means are available: the push-notification tool, a Slack message if a Slack
   integration is connected, and always a clear note in the chat. Include the
   proposed commit message and how to review and approve:
   - review the staged diff: `:GApproveReview` (nvim) or the `nvds` alias;
   - approve: `git-approve approve .` (or per file, `gok <file>`);
   - `git-approve pending` lists what's still unapproved.
3. **Wait for approval.** Run `git-approve wait` with the Bash tool and
   `run_in_background: true`, then end your turn. It blocks until everything
   staged is approved, then exits 0 and you are resumed.
4. **On resume**, confirm `git-approve pending` prints nothing, then `git commit`
   with the prepared message. Continue to the next planned commit.

If `wait` exits non-zero (e.g. a `--timeout` you set), approval did not
complete — report that and do not commit.

## 3. Finish

When the last commit lands, ping the user once more that the series is complete
and summarize the commits you made.
