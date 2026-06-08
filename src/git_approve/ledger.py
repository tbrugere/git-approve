"""The approval ledger: a per-worktree record of approved ``(oid, path)`` pairs.

Plain text, one ``"<oid>\\t<path>\\n"`` per line, UTF-8. The ledger's existence is
the per-worktree opt-in switch for enforcement.
"""

from __future__ import annotations

import os
import tempfile
from pathlib import Path

import pygit2

# A staged entry is identified by (oid, path). A deletion uses a sentinel oid.
type LedgerEntry = tuple[str, str]


class Ledger:
    """An approval ledger backed by the file at ``<git-dir>/approved``."""

    path: Path

    def __init__(self, path: Path) -> None:
        self.path = path

    @classmethod
    def from_repo(cls, repo: pygit2.Repository) -> Ledger:
        # repo.path is libgit2 git_repository_path: the *per-worktree* git dir
        # (e.g. /repo/.git/worktrees/<name>/ in a linked worktree). This is the
        # correct scope — each worktree has its own index and thus its own
        # approvals, so they never leak across worktrees.
        return cls(Path(repo.path) / "approved")

    def exists(self) -> bool:
        """Whether this worktree has opted in to enforcement."""
        return self.path.is_file()

    def read(self) -> set[LedgerEntry]:
        """Return the recorded ``(oid, path)`` pairs; empty set if absent."""
        if not self.path.is_file():
            return set()
        entries: set[LedgerEntry] = set()
        for line in self.path.read_text(encoding="utf-8").splitlines():
            if not line:
                continue
            oid, _, p = line.partition("\t")
            if p:
                entries.add((oid, p))
        return entries

    def write(self, entries: set[LedgerEntry]) -> None:
        """Atomically write the ledger (temp file in the same dir + ``os.replace``)."""
        body = "".join(f"{oid}\t{p}\n" for oid, p in sorted(set(entries)))
        # delete_on_close=False keeps the temp file alive past close() so we can
        # os.replace it; delete=True still removes it on context-manager exit, so
        # an error before the replace leaves nothing behind (and the cleanup
        # tolerates the already-moved file on the success path).
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=self.path.parent,
            prefix=".approved.",
            delete=True,
            delete_on_close=False,
        ) as f:
            f.write(body)
            f.close()
            os.replace(f.name, self.path)

    def remove(self) -> bool:
        """Delete the ledger (disable enforcement). Return True if it existed."""
        if self.exists():
            self.path.unlink()
            return True
        return False
