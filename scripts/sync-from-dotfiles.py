#!/usr/bin/env python3
"""Sync this repo from agent-skills/safe-git in the dotfiles repo, the source of truth.

That directory runs on its own, and its test suite fails if it stops being so.
This script exports it from the source's committed HEAD, runs the suite on the
export, and only then mirrors it here, so a failed export or test run changes
nothing. It refuses to run over uncommitted changes, so if the mirror step itself
fails, `git checkout -- . && git clean -fd` restores this repo. It also refuses an
export path that this repo's ignore rules match, which could overwrite a local
ignored file or be left out of the sync commit.

Usage: scripts/sync-from-dotfiles.py [--source DOTFILES_DIR] [--no-tests]
"""

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

TARGET = Path(__file__).resolve().parent.parent
SKILL = "agent-skills/safe-git"
# Paths this repo owns; the sync neither overwrites nor deletes them. Ignored files survive too.
TARGET_OWNED = [".git", ".gitignore", "justfile", "docs/", "scripts/", ".worktrees/", "worktrees/"]


def fail(msg):
    sys.exit(f"sync-from-dotfiles: {msg}")


def run(*cmd, **kwargs):
    try:
        return subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs).stdout
    except subprocess.CalledProcessError as err:
        fail(f"{' '.join(cmd)} exited {err.returncode}:\n{err.stdout}{err.stderr}")


def is_owned(path):
    return any(path == owned or (owned.endswith("/") and path.startswith(owned)) for owned in TARGET_OWNED)


def remove_stale_tracked_files(build):
    """Delete what git tracks and the export dropped, so ignored files are never candidates."""
    for path in filter(None, run("git", "-C", str(TARGET), "ls-files", "-z").split("\0")):
        exported = build / path
        # A tracked file where the export now has a directory still has to go.
        if is_owned(path) or (os.path.lexists(exported) and not exported.is_dir()):
            continue
        stale = TARGET / path
        stale.unlink()
        for parent in stale.parents:
            if parent == TARGET or any(parent.iterdir()):
                break
            parent.rmdir()


def refuse_ignored_export_paths(build):
    paths = [str(p.relative_to(build)) for p in build.rglob("*") if not p.is_dir()]
    paths = [path for path in paths if not is_owned(path)]
    check = subprocess.run(["git", "-C", str(TARGET), "check-ignore", "--no-index", "--stdin", "-z"],
                           input="\0".join(paths), capture_output=True, text=True)
    if check.returncode > 1:
        fail(f"git check-ignore failed:\n{check.stderr}")
    ignored = list(filter(None, check.stdout.split("\0")))
    if ignored:
        fail("export paths match this repo's ignore rules:\n" + "\n".join(ignored))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--source", type=Path,
                        default=Path(os.environ.get("DOTFILES_DIR", Path.home() / ".dotfiles")))
    parser.add_argument("--no-tests", action="store_true", help="skip test/run.sh on the export")
    args = parser.parse_args()
    source = args.source.resolve()

    dirty = run("git", "-C", str(TARGET), "status", "--porcelain", "--untracked-files=normal").strip()
    if dirty:
        fail(f"this repo has uncommitted changes the sync would overwrite; commit them first:\n{dirty}")

    with tempfile.TemporaryDirectory(prefix="safe-git-sync-") as tmp:
        build = Path(tmp) / "build"
        build.mkdir()
        archive = Path(tmp) / "export.tar"
        head = run("git", "-C", str(source), "rev-parse", "HEAD").strip()
        run("git", "-C", str(source), "archive", "--output", str(archive), f"{head}:{SKILL}")
        run("tar", "-xf", str(archive), "-C", str(build))
        if not args.no_tests:
            print("sync-from-dotfiles: running test/run.sh on a copy of the export")
            scratch = Path(tmp) / "test-copy"
            shutil.copytree(build, scratch, symlinks=True)
            run("bash", "test/run.sh", cwd=scratch, stdin=subprocess.DEVNULL)

        (build / "SYNCED_FROM").write_text(f"{head}\n")
        refuse_ignored_export_paths(build)
        remove_stale_tracked_files(build)
        excludes = [f"--exclude=/{owned}" for owned in TARGET_OWNED]
        run("rsync", "-a", *excludes, f"{build}/", f"{TARGET}/")
    print(f"sync-from-dotfiles: synced {SKILL} at {head[:12]}")


if __name__ == "__main__":
    main()
