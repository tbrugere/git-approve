"""``git-approve`` command-line interface (click).

Installed as the ``git-approve`` console script, which git also exposes as
``git approve <subcommand>``.
"""

from __future__ import annotations

import click

from .core import GitApprove


@click.group()
@click.version_option(package_name="git-approve")
def cli() -> None:
    """Mark individual staged files as approved before committing."""


@cli.command()
@click.argument("paths", nargs=-1, type=click.Path())
def approve(paths: tuple[str, ...]) -> None:
    """Approve staged files (all staged, or just the given PATHS)."""
    GitApprove.open().approve(paths)


@cli.command()
@click.argument("paths", nargs=-1, type=click.Path())
def revoke(paths: tuple[str, ...]) -> None:
    """Revoke approvals (all, or just the given PATHS).

    Revoked files become pending again; enforcement stays on. Use `disable` to
    turn enforcement off entirely.
    """
    GitApprove.open().revoke(paths)


@cli.command()
def enable() -> None:
    """Create an empty ledger, opting this worktree into enforcement."""
    GitApprove.open().enable()


@cli.command()
def disable() -> None:
    """Remove the ledger, turning off enforcement for this worktree."""
    GitApprove.open().disable()


@cli.command()
@click.option("-q", "--quiet", is_flag=True, help="Exit code only; no output.")
@click.argument("paths", nargs=-1, type=click.Path())
def status(paths: tuple[str, ...], quiet: bool) -> None:
    """Show approval status of staged files. Exit 1 if any are pending."""
    raise SystemExit(GitApprove.open().status(paths, quiet=quiet))


@cli.command()
def pending() -> None:
    """Print staged files that are not approved, one per line."""
    for path in GitApprove.open().pending():
        click.echo(path)


@cli.command()
@click.option("--interval", type=float, default=1.0, show_default=True,
              help="Seconds between checks.")
@click.option("--timeout", type=float, default=None,
              help="Give up and exit 1 after this many seconds.")
def wait(interval: float, timeout: float | None) -> None:
    """Block until all staged files are approved (for agent/background use).

    Exits 0 once nothing is pending, or 1 on --timeout. Run it in the background
    and have your agent resume when it exits.
    """
    raise SystemExit(GitApprove.open().wait(interval=interval, timeout=timeout))


@cli.group()
def hooks() -> None:
    """Entry points invoked by the installed git hook scripts."""


@hooks.command(name="pre-commit")
def pre_commit() -> None:
    """Enforce approvals for a commit (called by the pre-commit hook)."""
    raise SystemExit(GitApprove.open().pre_commit())
