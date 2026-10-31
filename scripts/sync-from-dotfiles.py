#!/usr/bin/env python3
"""Sync this repo from agent-skills/safe-git in the dotfiles repo, the source of truth.

That directory runs on its own, and its test suite fails if it stops being so.
This script exports it from the source's committed HEAD, runs the suite on the
export, and only then mirrors it here, so a failed sync changes nothing. It
refuses to run over uncommitted changes.

Usage: scripts/sync-from-dotfiles.py [--source DOTFILES_DIR] [--no-tests]
"""

import argparse
import os
import subprocess
import sys
import tempfile
from pathlib import Path

TARGET = Path(__file__).resolve().parent.parent
SKILL = "agent-skills/safe-git"
# Paths this repo owns; the sync neither overwrites nor deletes them.
TARGET_OWNED = [".git", ".gitignore", "justfile", "docs/", "scripts/", ".worktrees/", "worktrees/"]


def fail(msg):
    sys.exit(f"sync-from-dotfiles: {msg}")


def run(*cmd, **kwargs):
    try:
        return subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs).stdout
    except subprocess.CalledProcessError as err:
        fail(f"{' '.join(cmd)} exited {err.returncode}:\n{err.stdout}{err.stderr}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--source", type=Path,
                        default=Path(os.environ.get("DOTFILES_DIR", Path.home() / ".dotfiles")))
    parser.add_argument("--no-tests", action="store_true", help="skip test/run.sh on the export")
    args = parser.parse_args()
    source = args.source.resolve()

    dirty = run("git", "-C", str(TARGET), "status", "--porcelain").strip()
    if dirty:
        fail(f"this repo has uncommitted changes the sync would overwrite; commit them first:\n{dirty}")

    with tempfile.TemporaryDirectory(prefix="safe-git-sync-") as tmp:
        build = Path(tmp) / "build"
        build.mkdir()
        archive = Path(tmp) / "export.tar"
        run("git", "-C", str(source), "archive", "--output", str(archive), f"HEAD:{SKILL}")
        run("tar", "-xf", str(archive), "-C", str(build))
        if not args.no_tests:
            print("sync-from-dotfiles: running test/run.sh on the export")
            run("bash", "test/run.sh", cwd=build, stdin=subprocess.DEVNULL)

        head = run("git", "-C", str(source), "rev-parse", "HEAD").strip()
        (build / "SYNCED_FROM").write_text(f"{head}\n")
        excludes = [f"--exclude=/{owned}" for owned in TARGET_OWNED]
        run("rsync", "-a", "--delete", *excludes, f"{build}/", f"{TARGET}/")
    print(f"sync-from-dotfiles: synced {SKILL} at {head[:12]}")


if __name__ == "__main__":
    main()
