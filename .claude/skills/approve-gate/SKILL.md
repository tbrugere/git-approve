---
name: approve-gate
description: >-
  Hand off staged work for human approval before committing, using the
  git-approve CLI. Use when you have staged changes that a human must review and
  approve before the commit lands: it enables enforcement, waits in the
  background until every staged file is approved, then resumes to commit.
  Triggers: "wait for approval", "let me review before you commit", "gate this
  commit", "don't commit until I approve".
argument-hint: [commit message]
---

# approve-gate

Gate your staged work behind human approval via `git-approve`: stage → enable →
wait in the background → commit once everything is approved.

**Never approve on the human's behalf.** Do not run `git-approve approve`, and do
not bypass with `git commit --no-verify`. Approval is the human's job; yours is
to set up the gate and continue once it clears.

## Steps

1. Ensure the work to review is **staged** (`git add` the relevant files). Then
   check what's pending:
   ```bash
   git-approve pending
   ```
   If nothing is staged, stop and tell the user there's nothing to gate.

2. Turn on enforcement for this worktree (idempotent — makes the pre-commit hook
   actually block an unapproved commit):
   ```bash
   git-approve enable
   ```

3. Launch the wait **in the background** — use the Bash tool with
   `run_in_background: true` so you can end the turn and be resumed when it
   exits:
   ```bash
   git-approve wait
   ```
   It blocks until every staged file is approved, then exits 0.

4. Tell the user what's pending and how to approve, then **end your turn**:
   - review the staged diff (`:GApproveReview` in nvim, or the `nvds` alias);
   - approve with `gok <file>` / `git-approve approve <file>`, or
     `git-approve approve .` for everything;
   - `git-approve pending` shows what's left.

5. **On resume** (the background `git-approve wait` has exited): confirm
   `git-approve pending` prints nothing, then commit the approved work. Use
   `$ARGUMENTS` as the commit message if given; otherwise write a concise message
   describing the staged change. Continue with the original task afterward.

If you ran `wait` with `--timeout` and it exited non-zero, approval did **not**
complete — report that and do not commit.
