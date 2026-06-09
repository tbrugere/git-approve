"""Tests for git_approve against throwaway repos under tmp_path."""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from git_approve.core import ZERO_OID, GitApprove

HOOKS_DIR = Path(__file__).resolve().parent.parent / "hooks"


def git(cwd: Path, *args: str, check: bool = True, **kw) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", *args],
        cwd=cwd,
        text=True,
        capture_output=True,
        check=check,
        **kw,
    )


def init_repo(cwd: Path) -> None:
    git(cwd, "init", "-b", "main")
    git(cwd, "config", "user.email", "test@example.com")
    git(cwd, "config", "user.name", "Test")
    git(cwd, "config", "commit.gpgsign", "false")


@pytest.fixture
def ga(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> GitApprove:
    """A fresh git repo with one committed file, cwd set to its workdir."""
    init_repo(tmp_path)
    (tmp_path / "base.txt").write_text("base\n")
    git(tmp_path, "add", "base.txt")
    git(tmp_path, "commit", "-m", "init")
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("GIT_INDEX_FILE", raising=False)
    return GitApprove.open()


def stage(cwd: Path, name: str, content: str) -> None:
    (cwd / name).write_text(content)
    git(cwd, "add", name)


# --------------------------------------------------------------------------- #
# 1. Direction check — oid keying is right regardless of diff delta direction.
# --------------------------------------------------------------------------- #
def test_staged_oid_matches_index(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "base.txt", "modified\n")
    entries = ga.staged_entries()
    assert entries["base.txt"] == str(ga.repo.index["base.txt"].id)


# --------------------------------------------------------------------------- #
# 2 + 3. Approve flips status to approved; re-staging voids the approval.
# --------------------------------------------------------------------------- #
def test_approve_then_restage_voids(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    assert ga.status(quiet=True) == 0  # no ledger yet -> inactive
    ga.approve(("a.txt",))
    assert ga.ledger.exists()
    assert ga.status(quiet=True) == 0  # approved

    # Re-stage different content: oid changes, approval is void.
    stage(tmp_path, "a.txt", "two\n")
    assert ga.status(quiet=True) == 1


# --------------------------------------------------------------------------- #
# 4. Staged deletion is approvable.
# --------------------------------------------------------------------------- #
def test_staged_deletion_approvable(ga: GitApprove, tmp_path: Path) -> None:
    git(tmp_path, "rm", "--cached", "base.txt")
    entries = ga.staged_entries()
    assert entries["base.txt"] == ZERO_OID
    ga.approve(("base.txt",))
    assert ga.status(quiet=True) == 0


# --------------------------------------------------------------------------- #
# 5. No ledger -> enforcement inactive, exit 0.
# --------------------------------------------------------------------------- #
def test_no_ledger_inactive(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    assert not ga.ledger.exists()
    assert ga.status(quiet=True) == 0


# --------------------------------------------------------------------------- #
# 6. Revoke a path and revoke-all leave enforcement on (ledger still exists).
# --------------------------------------------------------------------------- #
def test_revoke(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    stage(tmp_path, "b.txt", "two\n")
    ga.approve()
    assert ga.status(quiet=True) == 0

    ga.revoke(("a.txt",))
    assert ga.status(quiet=True) == 1  # a.txt now pending, b.txt still approved

    ga.revoke()  # revoke everything, but keep enforcement on
    assert ga.ledger.exists()
    assert ga.ledger.read() == set()
    assert ga.status(quiet=True) == 1  # both pending now


def test_approve_directory_and_dot(
    ga: GitApprove, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    (tmp_path / "sub").mkdir()
    stage(tmp_path, "sub/a.txt", "a\n")
    stage(tmp_path, "sub/b.txt", "b\n")
    stage(tmp_path, "top.txt", "t\n")
    staged = ga.staged_entries()

    # A directory matches every staged file under it, but nothing outside it.
    ga.approve(("sub",))
    ledger = ga.ledger.read()
    assert (staged["sub/a.txt"], "sub/a.txt") in ledger
    assert (staged["sub/b.txt"], "sub/b.txt") in ledger
    assert (staged["top.txt"], "top.txt") not in ledger

    # `.` selects everything staged.
    ga.approve((".",))
    assert ga.status(quiet=True) == 0

    # Revoking a directory un-approves just that subtree.
    ga.revoke(("sub",))
    assert (staged["top.txt"], "top.txt") in ga.ledger.read()
    assert not any(p.startswith("sub/") for _, p in ga.ledger.read())


def test_approve_path_relative_to_cwd(
    ga: GitApprove, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    (tmp_path / "sub").mkdir()
    stage(tmp_path, "sub/a.txt", "a\n")
    staged = ga.staged_entries()

    # From inside sub/, "a.txt" must resolve to the repo-relative "sub/a.txt".
    monkeypatch.chdir(tmp_path / "sub")
    ga.approve(("a.txt",))
    assert (staged["sub/a.txt"], "sub/a.txt") in ga.ledger.read()


def test_revoke_without_ledger_is_noop(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    ga.revoke()  # no ledger yet
    assert not ga.ledger.exists()  # revoke must not create/enable one


# --------------------------------------------------------------------------- #
# 6b. disable removes the ledger entirely.
# --------------------------------------------------------------------------- #
def test_disable(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    ga.approve()
    assert ga.ledger.exists()
    ga.disable()
    assert not ga.ledger.exists()
    assert ga.status(quiet=True) == 0  # inactive again


def test_enable(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    assert not ga.ledger.exists()
    ga.enable()
    assert ga.ledger.exists()
    assert ga.ledger.read() == set()  # empty: nothing approved yet
    assert ga.status(quiet=True) == 1  # a.txt pending under active enforcement
    ga.enable()  # idempotent
    assert ga.ledger.read() == set()


# --------------------------------------------------------------------------- #
# 7. Partial commit honors GIT_INDEX_FILE.
# --------------------------------------------------------------------------- #
def test_partial_commit_git_index_file(
    ga: GitApprove, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    stage(tmp_path, "a.txt", "one\n")
    stage(tmp_path, "b.txt", "two\n")
    ga.approve(("a.txt",))  # approve only a.txt

    # Whole index: b.txt is pending.
    assert ga.status(quiet=True) == 1

    # Build a temp index containing only a.txt, like `git commit a.txt` does.
    temp_index = tmp_path / "tmp-index"
    env = {**os.environ, "GIT_INDEX_FILE": str(temp_index)}
    git(tmp_path, "read-tree", "HEAD", env=env)
    git(tmp_path, "add", "a.txt", env=env)

    monkeypatch.setenv("GIT_INDEX_FILE", str(temp_index))
    entries = ga.staged_entries()
    assert set(entries) == {"a.txt"}  # only the subset being committed
    assert ga.status(quiet=True) == 0


# --------------------------------------------------------------------------- #
# 8. Unborn HEAD (fresh init) doesn't crash.
# --------------------------------------------------------------------------- #
def test_unborn_head(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    init_repo(tmp_path)
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv("GIT_INDEX_FILE", raising=False)
    ga = GitApprove.open()
    assert ga.repo.head_is_unborn

    stage(tmp_path, "first.txt", "hi\n")
    entries = ga.staged_entries()
    assert "first.txt" in entries
    assert ga.status(quiet=True) == 0  # no ledger yet
    ga.approve()
    assert ga.status(quiet=True) == 0


# --------------------------------------------------------------------------- #
# 9. Worktree isolation — approvals do not leak across worktrees.
# --------------------------------------------------------------------------- #
def test_worktree_isolation(
    ga: GitApprove, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    wt_b = tmp_path.parent / "wt-b"
    git(tmp_path, "worktree", "add", str(wt_b))
    try:
        # Stage the same path in both worktrees.
        stage(tmp_path, "foo.py", "main-side\n")
        stage(wt_b, "foo.py", "wt-b-side\n")

        # Approve in the main worktree.
        ga.approve(("foo.py",))
        assert ga.ledger.path.is_file()

        # wt-b's ledger lives under .git/worktrees/wt-b/ and must not exist.
        monkeypatch.chdir(wt_b)
        ga_b = GitApprove.open()
        assert "worktrees" in ga_b.repo.path
        assert ga_b.ledger.path == Path(ga_b.repo.path) / "approved"
        assert not ga_b.ledger.exists()  # approval did not leak
    finally:
        git(tmp_path, "worktree", "remove", "--force", str(wt_b))

    # Removing the worktree took its git dir (and any ledger) with it.
    assert not (tmp_path / ".git" / "worktrees" / "wt-b").exists()


# --------------------------------------------------------------------------- #
# End-to-end: the deployed pre-commit hook blocks/allows real commits.
# --------------------------------------------------------------------------- #
def test_hook_blocks_and_allows(ga: GitApprove, tmp_path: Path) -> None:
    git(tmp_path, "config", "core.hooksPath", str(HOOKS_DIR))

    stage(tmp_path, "a.txt", "one\n")
    # No ledger yet -> hook is a no-op, commit succeeds.
    git(tmp_path, "commit", "-m", "no ledger")

    # Opt in by approving a staged file, then re-stage to void the approval so
    # there is a pending file at commit time.
    stage(tmp_path, "b.txt", "two\n")
    ga.approve()  # creates ledger, approves b.txt
    stage(tmp_path, "b.txt", "two-modified\n")  # oid changes -> approval void
    blocked = git(tmp_path, "commit", "-m", "should block", check=False)
    assert blocked.returncode != 0
    assert "commit blocked" in blocked.stderr

    # Re-approve the current content -> commit succeeds.
    ga.approve(("b.txt",))
    git(tmp_path, "commit", "-m", "approved")


def test_pending(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    stage(tmp_path, "b.txt", "two\n")
    assert ga.pending() == ["a.txt", "b.txt"]  # no ledger -> all pending
    ga.approve(("a.txt",))
    assert ga.pending() == ["b.txt"]
    ga.approve(("b.txt",))
    assert ga.pending() == []


def test_wait_returns_when_all_approved(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    ga.approve()
    assert ga.wait(timeout=0.01) == 0  # nothing pending -> immediate


def test_wait_times_out(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    ga.enable()  # a.txt pending, never approved
    assert ga.wait(interval=0.01, timeout=0.05) == 1


def test_wait_unblocks_on_approval(
    ga: GitApprove, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    stage(tmp_path, "a.txt", "one\n")
    ga.enable()
    staged = ga.staged_entries()

    # Approve during the first poll's sleep, so the next poll sees it done.
    def fake_sleep(_seconds: float) -> None:
        ga.ledger.write({(staged["a.txt"], "a.txt")})

    monkeypatch.setattr("git_approve.core.time.sleep", fake_sleep)
    assert ga.wait(interval=0.01) == 0


def test_pre_commit_enforcement(ga: GitApprove, tmp_path: Path) -> None:
    stage(tmp_path, "a.txt", "one\n")
    assert ga.pre_commit() == 0  # no ledger -> inactive, allowed
    ga.enable()
    assert ga.pre_commit() == 1  # a.txt pending -> blocked
    ga.approve(("a.txt",))
    assert ga.pre_commit() == 0  # approved -> allowed


def test_hook_chains_local_pre_commit(ga: GitApprove, tmp_path: Path) -> None:
    git(tmp_path, "config", "core.hooksPath", str(HOOKS_DIR))
    # Drop a repo-local pre-commit that records it ran, then fails.
    local_hooks = tmp_path / ".git" / "hooks"
    local_hooks.mkdir(exist_ok=True)
    marker = tmp_path / "ran"
    hook = local_hooks / "pre-commit"
    hook.write_text(f"#!/bin/sh\ntouch {marker}\nexit 1\n")
    hook.chmod(0o755)

    stage(tmp_path, "a.txt", "one\n")
    res = git(tmp_path, "commit", "-m", "x", check=False)
    assert res.returncode != 0  # local hook's failure propagates
    assert marker.exists()  # local hook actually ran (chaining works)
