#!/usr/bin/env python3
"""Tests for sync-from-dotfiles.py, run against a copy of the real dotfiles inputs.

They need the dotfiles checkout (DOTFILES_DIR, default ~/.dotfiles). Usage: scripts/test_sync_from_dotfiles.py
"""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().with_name("sync-from-dotfiles.py")
DOTFILES = Path(os.environ.get("DOTFILES_DIR", Path.home() / ".dotfiles"))
INPUTS = ["agent-skills/safe-git"]


def git(cwd, *args):
    return subprocess.run(["git", "-c", "user.email=t@example.com", "-c", "user.name=t", *args],
                          cwd=cwd, check=True, capture_output=True, text=True).stdout


@unittest.skipUnless((DOTFILES / ".git").exists(), f"needs a dotfiles checkout at {DOTFILES}; set DOTFILES_DIR")
class SyncTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.source = Path(tmp.name) / "source"
        self.target = Path(tmp.name) / "target"

        self.source.mkdir()
        archive = Path(tmp.name) / "inputs.tar"
        subprocess.run(["git", "-C", str(DOTFILES), "archive", "--output", str(archive), "HEAD", *INPUTS], check=True)
        subprocess.run(["tar", "-xf", str(archive), "-C", str(self.source)], check=True)
        git(self.source, "init", "-q")
        git(self.source, "add", "-A")
        git(self.source, "commit", "-qm", "source")

        (self.target / "scripts").mkdir(parents=True)
        (self.target / "docs").mkdir()
        (self.target / "docs" / "owned.md").write_text("owned\n")
        (self.target / ".gitignore").write_text(".worktrees/\nworktrees/\n")
        (self.target / "justfile").write_text("# owned\n")
        for ignored in (".worktrees", "worktrees"):
            (self.target / ignored).mkdir()
            (self.target / ignored / "kept").write_text("kept\n")
        (self.target / "stale.txt").write_text("removed by the mirror\n")
        shutil.copy2(SCRIPT, self.target / "scripts")
        git(self.target, "init", "-q")
        git(self.target, "add", "-A")
        git(self.target, "commit", "-qm", "target")
        self.start_state = self.snapshot()

    def snapshot(self):
        return {p.relative_to(self.target): p.read_bytes() for p in self.target.rglob("*")
                if p.is_file() and ".git" not in p.relative_to(self.target).parts}

    def sync(self, *args):
        return subprocess.run(["python3", str(self.target / "scripts" / SCRIPT.name),
                               "--source", str(self.source), *args],
                              capture_output=True, text=True)

    def commit_source(self, rel, edit):
        path = self.source / rel
        path.write_text(edit(path.read_text()))
        git(self.source, "commit", "-qam", "edit")

    def assert_refused_untouched(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertEqual(self.snapshot(), self.start_state)

    def test_clean_sync_mirrors_export_and_records_source(self):
        result = self.sync("--no-tests")
        self.assertEqual(result.returncode, 0, result.stderr)
        head = git(self.source, "rev-parse", "HEAD").strip()
        self.assertEqual((self.target / "SYNCED_FROM").read_text().strip(), head)
        self.assertTrue(os.access(self.target / "bin" / "resolve-main-worktree", os.X_OK))
        self.assertTrue((self.target / "lib" / "gitenv.sh").is_file())
        self.assertEqual((self.target / "docs" / "owned.md").read_text(), "owned\n")
        for owned in (".gitignore", "justfile", ".worktrees/kept", "worktrees/kept", f"scripts/{SCRIPT.name}"):
            self.assertTrue((self.target / owned).is_file(), owned)
        self.assertFalse((self.target / "stale.txt").exists())

    def test_ignored_files_survive(self):
        with open(self.target / ".gitignore", "a") as ignore:
            ignore.write("local.env\ncache/\n")
        git(self.target, "commit", "-qam", "ignore more")
        (self.target / "local.env").write_text("keep\n")
        (self.target / "cache").mkdir()
        (self.target / "cache" / "entry").write_text("keep\n")
        result = self.sync("--no-tests")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.target / "local.env").read_text(), "keep\n")
        self.assertEqual((self.target / "cache" / "entry").read_text(), "keep\n")

    def test_second_sync_changes_nothing(self):
        self.assertEqual(self.sync("--no-tests").returncode, 0)
        git(self.target, "add", "-A")
        git(self.target, "commit", "-qm", "synced")
        self.assertEqual(self.sync("--no-tests").returncode, 0)
        self.assertEqual(git(self.target, "status", "--porcelain"), "")

    def test_export_that_stops_being_self_contained_is_refused(self):
        self.commit_source("agent-skills/safe-git/bin/safe-git",
                           lambda t: t + '\n. "$SAFE_GIT_BIN_DIR/../../other-skill/lib/x.sh"\n')
        self.assert_refused_untouched(self.sync(), "test_package_passes_every_detector")

    def test_dirty_target_is_refused(self):
        (self.target / "docs" / "owned.md").write_text("local edit\n")
        self.start_state = self.snapshot()
        self.assert_refused_untouched(self.sync("--no-tests"), "uncommitted changes")

    def test_failing_suite_leaves_target_untouched(self):
        self.commit_source("agent-skills/safe-git/test/run.sh", lambda _: "echo boom\nexit 1\n")
        self.assert_refused_untouched(self.sync(), "boom")

    def test_uncommitted_and_ignored_source_files_do_not_ship(self):
        (self.source / ".gitignore").write_text("junk.tmp\n")
        git(self.source, "add", ".gitignore")
        git(self.source, "commit", "-qm", "ignore")
        (self.source / "agent-skills/safe-git/junk.tmp").write_text("junk\n")
        (self.source / "agent-skills/safe-git/untracked.txt").write_text("untracked\n")
        with open(self.source / "agent-skills/safe-git/SKILL.md", "a") as skill:
            skill.write("\nUNCOMMITTED\n")
        self.assertEqual(self.sync("--no-tests").returncode, 0)
        self.assertFalse((self.target / "junk.tmp").exists())
        self.assertFalse((self.target / "untracked.txt").exists())
        self.assertNotIn("UNCOMMITTED", (self.target / "SKILL.md").read_text())


if __name__ == "__main__":
    unittest.main()
