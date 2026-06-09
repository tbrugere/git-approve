"""Core git logic for ``git-approve`` (pygit2).

Approval is keyed to the *staged blob oid*, not just the path. If different
content is re-staged for an already-approved file, the oid changes and the
approval is automatically void: you can never commit content you never reviewed.
"""

from __future__ import annotations

import logging
import os
import time
from collections.abc import Iterable
from pathlib import Path

import click
import pygit2

from .ledger import Ledger

logger = logging.getLogger(__name__)

# Sentinel oid for a staged deletion (stable, meaningful "this path is deleted").
ZERO_OID = "0" * 40


class GitApproveError(click.ClickException):
    """Base for expected, user-facing errors.

    Inheriting from ClickException means click's main loop prints these as
    ``Error: <message>`` and exits 1 — the CLI needs no error-handling code.
    """


class NotARepoError(GitApproveError):
    def __init__(self) -> None:
        super().__init__("not inside a git repository")


class NothingStagedError(GitApproveError):
    def __init__(self) -> None:
        super().__init__("nothing is staged")


class GitApprove:
    """Operations over one worktree's staged changes and approval ledger."""

    repo: pygit2.Repository
    ledger: Ledger

    def __init__(self, repo: pygit2.Repository) -> None:
        self.repo = repo
        self.ledger = Ledger.from_repo(repo)

    @classmethod
    def open(cls) -> GitApprove:
        """Discover the enclosing repository, or raise NotARepoError."""
        path = pygit2.discover_repository(os.getcwd())
        if path is None:
            raise NotARepoError()
        return cls(pygit2.Repository(path))

    # ----------------------------------------------------------------------- #
    # Enumerating staged entries (oid-keyed, GIT_INDEX_FILE-aware)
    # ----------------------------------------------------------------------- #
    def staged_entries(self) -> dict[str, str]:
        """Map every path whose index content differs from HEAD to its oid.

        A staged deletion maps to ``ZERO_OID``.
        """
        # Honor GIT_INDEX_FILE: during a partial commit (`git commit <paths>`)
        # git points this at a temp index. libgit2 does NOT read that env var
        # automatically, so open it explicitly.
        idx_path = os.environ.get("GIT_INDEX_FILE")
        index = pygit2.Index(idx_path) if idx_path else self.repo.index
        index.read()

        if self.repo.head_is_unborn:
            # No HEAD: every index entry is a staged-new file.
            return {entry.path: str(entry.id) for entry in index}

        head_tree = self.repo.head.peel(pygit2.Commit).tree

        # Enumerate changed paths via the diff; take the authoritative oid
        # straight from the index. We diff from the tree side
        # (Tree.diff_to_index) rather than Index.diff_to_tree: a GIT_INDEX_FILE
        # index opened standalone has no associated repository, so its
        # diff_to_tree raises, whereas the tree always carries the repo.
        # Collecting BOTH delta sides makes this robust to the diff direction.
        diff = head_tree.diff_to_index(index)
        paths: set[str] = set()
        for delta in diff.deltas:
            for p in (delta.old_file.path, delta.new_file.path):
                if p:
                    paths.add(p)

        out: dict[str, str] = {}
        for p in paths:
            try:
                out[p] = str(index[p].id)
            except KeyError:  # path absent from index = staged deletion
                out[p] = ZERO_OID
        return out

    def _select(self, paths: tuple[str, ...]) -> dict[str, str]:
        """Staged entries, restricted to ``paths`` if given.

        Each path may name a file or a directory (matching every staged file
        under it); ``.`` selects everything staged. Paths are interpreted
        relative to the current directory, like git itself.
        """
        staged = self.staged_entries()
        if not paths:
            return staged
        matched = self._expand_paths(paths, staged)
        return {p: staged[p] for p in matched}

    def _to_repo_relative(self, arg: str) -> str | None:
        """Translate a cwd-relative path arg to a repo-root-relative posix path.

        Returns ``""`` for the worktree root, or None if it is outside the tree.
        Both sides are resolved so symlinked paths (e.g. /tmp) compare equal.
        """
        workdir = self.repo.workdir
        if workdir is None:
            return None
        try:
            rel = Path(arg).resolve().relative_to(Path(workdir).resolve())
        except ValueError:
            return None
        posix = rel.as_posix()
        return "" if posix == "." else posix

    def _expand_paths(
        self, args: tuple[str, ...], candidates: Iterable[str]
    ) -> set[str]:
        """Resolve path args to matching ``candidates`` (file, directory, or ``.``).

        Warns and skips any arg that matches nothing.
        """
        pool = set(candidates)
        out: set[str] = set()
        for arg in args:
            rel = self._to_repo_relative(arg)
            if rel is None:
                match: set[str] = set()
            elif rel == "":
                match = set(pool)  # worktree root: everything
            elif rel in pool:
                match = {rel}
            else:
                prefix = rel + "/"
                match = {c for c in pool if c.startswith(prefix)}
            if match:
                out |= match
            else:
                logger.warning("%r matched nothing, skipping", arg)
        return out

    # ----------------------------------------------------------------------- #
    # Operations
    # ----------------------------------------------------------------------- #
    def approve(self, paths: tuple[str, ...] = ()) -> None:
        """Approve staged ``(oid, path)`` pairs. Creates the ledger on first use."""
        if not self.staged_entries():
            raise NothingStagedError()
        selected = self._select(paths)
        if not selected:
            raise GitApproveError("nothing to approve")
        entries = self.ledger.read()
        entries |= {(oid, p) for p, oid in selected.items()}
        self.ledger.write(entries)
        for p in sorted(selected):
            click.echo(f"approved {p}")

    def revoke(self, paths: tuple[str, ...] = ()) -> None:
        """Revoke approvals (all, or just the given PATHS).

        PATHS may name files or directories; with no PATHS, everything is
        revoked. Revoked files become pending again; enforcement stays on.
        """
        if not self.ledger.exists():
            click.echo("enforcement inactive; nothing to revoke", err=True)
            return
        entries = self.ledger.read()
        ledger_paths = {p for _, p in entries}
        drop = ledger_paths if not paths else self._expand_paths(paths, ledger_paths)
        kept = {(oid, p) for (oid, p) in entries if p not in drop}
        self.ledger.write(kept)
        for p in sorted(drop):
            click.echo(f"revoked {p}")

    def enable(self) -> None:
        """Create an empty ledger, opting this worktree into enforcement."""
        if self.ledger.exists():
            click.echo("enforcement already active")
            return
        self.ledger.write(set())
        click.echo("enforcement enabled (nothing approved yet)")

    def disable(self) -> None:
        """Remove the ledger entirely, turning off enforcement for this worktree."""
        if self.ledger.remove():
            click.echo("enforcement disabled (ledger removed)")
        else:
            click.echo("enforcement was not active")

    def pending(self) -> list[str]:
        """Staged paths that are not approved, sorted.

        With no ledger nothing is approved, so every staged path is pending —
        which is what an editor wants when reviewing before opting in.
        """
        approved = self.ledger.read()
        staged = self.staged_entries()
        return sorted(p for p, oid in staged.items() if (oid, p) not in approved)

    def wait(self, interval: float = 1.0, timeout: float | None = None) -> int:
        """Block until no staged file is pending; return 0, or 1 on timeout.

        Designed to be launched in the background by an agent: it stages work,
        runs `git-approve wait`, and is resumed when the command exits because a
        human has approved everything. The staged set is recomputed each poll,
        so files staged or re-staged while waiting are accounted for.
        """
        deadline = None if timeout is None else time.monotonic() + timeout
        last: list[str] | None = None
        while True:
            pending = self.pending()
            if not pending:
                return 0
            if pending != last:
                click.echo(f"waiting on {len(pending)} unapproved file(s)...", err=True)
                last = pending
            if deadline is not None and time.monotonic() >= deadline:
                click.echo("timed out waiting for approval", err=True)
                return 1
            time.sleep(interval)

    def pre_commit(self) -> int:
        """Enforcement step for the pre-commit hook: block if anything is pending.

        The installed shell hook handles chaining repo-local hooks and the
        ledger opt-in guard; this is the verbose enforcement step it delegates to.
        """
        if self.status(quiet=True) == 0:
            return 0
        click.echo("✗ commit blocked: staged files are not approved.", err=True)
        self.status()  # show the ✓/✗ breakdown
        click.echo("Approve with: git-approve approve <file>   (alias: gok)", err=True)
        click.echo("Bypass with:  git commit --no-verify", err=True)
        return 1

    def status(self, paths: tuple[str, ...] = (), quiet: bool = False) -> int:
        """Print per-file approval status; return 1 if any staged file is pending.

        If no ledger exists, enforcement is inactive: stay quiet and return 0.
        """
        if not self.ledger.exists():
            if not quiet:
                click.echo("enforcement inactive (run `git-approve enable` to turn on)")
            return 0

        staged = self._select(paths)
        entries = self.ledger.read()

        pending = 0
        for p in sorted(staged):
            approved = (staged[p], p) in entries
            if not approved:
                pending += 1
            if not quiet:
                mark, color = ("✓", "green") if approved else ("✗", "red")
                click.secho(f"{mark} {p}", fg=color)

        if not quiet:
            total = len(staged)
            click.echo(f"{total - pending}/{total} approved", err=True)

        return 1 if pending else 0
