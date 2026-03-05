# safe-git Skill Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a `safe-git` skill that prevents Claude from amending pushed commits, working on main, and staging irrelevant files.

**Architecture:** A single `SKILL.md` with three hard-gate checklists, plus two shell hook scripts (pre-commit, pre-push) that act as automated backstops. The skill is distributed as a standalone git repo with a symlink install into `~/.claude/skills/`.

**Tech Stack:** Markdown (skill), Bash (hooks), symlink (install)

---

### Task 1: Write SKILL.md

**Files:**
- Create: `SKILL.md`

**Step 1: Create the skill file**

```markdown
---
name: safe-git
description: Use before staging files, committing (including after pre-commit failures), or creating a PR — enforces safe git operations to prevent amending pushed commits, working on main, and staging irrelevant files
---

# safe-git

**Announce at start:** "I'm using the safe-git skill to verify safe git operations."

## Gate 1 — Before starting any work on a task

1. Run `git branch --show-current`
2. If result is `main` or `master` → **STOP**

   Do not proceed. Create a feature branch first:
   ```bash
   git checkout -b <descriptive-branch-name>
   ```
   Then begin work on the feature branch.

## Gate 2 — Before staging files

1. Run `git status` and review ALL listed changes
2. Identify which files are relevant to the current task
3. Stage specific files only:
   ```bash
   git add path/to/file1 path/to/file2
   ```
4. `git add .` and `git add -A` are **FORBIDDEN** — they silently include unrelated changes

## Gate 3 — Before any commit

### If recovering from a pre-commit hook failure:

The pre-commit hook rejected the commit — **no commit was created**.
After fixing the issue, use a fresh commit:

```bash
git commit -m "your message"
```

`git commit --amend` is **FORBIDDEN** in this case. The commit you would be amending is the last *pushed* commit, not a new one.

### Before any other use of `git commit --amend`:

Run:
```bash
git log @{u}..HEAD --oneline
```

- **Returns commits** → amend is safe (those commits are unpushed)
- **Returns nothing** → amend is **FORBIDDEN**, all commits are already pushed

  Use a fresh commit instead:
  ```bash
  git commit -m "your message"
  ```

## Recommended Hook Setup

Install these hooks in each repo to add mechanical protection independent of this skill.

### pre-commit — blocks direct commits to main/master

Save to `.git/hooks/pre-commit` and run `chmod +x .git/hooks/pre-commit`:

```bash
#!/bin/bash
branch=$(git branch --show-current)
if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  echo "ERROR: Direct commit to $branch is not allowed. Create a feature branch first."
  exit 1
fi
```

### pre-push — blocks pushing to main/master

Save to `.git/hooks/pre-push` and run `chmod +x .git/hooks/pre-push`:

```bash
#!/bin/bash
while read local_ref local_sha remote_ref remote_sha; do
  if [[ "$remote_ref" =~ refs/heads/main ]] || [[ "$remote_ref" =~ refs/heads/master ]]; then
    echo "ERROR: Pushing to main/master is blocked. Use a feature branch and PR."
    exit 1
  fi
done
exit 0
```
```

**Step 2: Verify structure**

Run: `cat SKILL.md`
Expected: Three gates visible, hook scripts included, frontmatter correct

**Step 3: Commit**

```bash
git add SKILL.md
git commit -m "feat: add safe-git SKILL.md with three hard-gate checklists"
```

---

### Task 2: Write hook scripts as standalone files

**Files:**
- Create: `hooks/pre-commit`
- Create: `hooks/pre-push`

**Step 1: Create hooks directory and pre-commit script**

```bash
#!/bin/bash
branch=$(git branch --show-current)
if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  echo "ERROR: Direct commit to $branch is not allowed. Create a feature branch first."
  exit 1
fi
```

Save to `hooks/pre-commit`.

**Step 2: Create pre-push script**

```bash
#!/bin/bash
while read local_ref local_sha remote_ref remote_sha; do
  if [[ "$remote_ref" =~ refs/heads/main ]] || [[ "$remote_ref" =~ refs/heads/master ]]; then
    echo "ERROR: Pushing to main/master is blocked. Use a feature branch and PR."
    exit 1
  fi
done
exit 0
```

Save to `hooks/pre-push`.

**Step 3: Make executable**

Run: `chmod +x hooks/pre-commit hooks/pre-push`

**Step 4: Test pre-commit hook manually**

```bash
# Simulate being on main
git init /tmp/test-safe-git-hook
cd /tmp/test-safe-git-hook
git checkout -b main 2>/dev/null || true
cp ~/work/20-safe-git-skill/hooks/pre-commit .git/hooks/pre-commit
touch testfile && git add testfile
git commit -m "test"
```

Expected: `ERROR: Direct commit to main is not allowed.` and exit code 1

**Step 5: Clean up test repo**

```bash
rm -rf /tmp/test-safe-git-hook
```

**Step 6: Commit**

```bash
cd ~/work/20-safe-git-skill
git add hooks/
git commit -m "feat: add standalone pre-commit and pre-push hook scripts"
```

---

### Task 3: Write install script

**Files:**
- Create: `install.sh`

**Step 1: Create install script**

```bash
#!/bin/bash
set -e

SKILL_DIR="$HOME/.claude/skills/safe-git"

echo "Installing safe-git skill..."

mkdir -p "$SKILL_DIR"

# Symlink SKILL.md into Claude skills directory
ln -sf "$(pwd)/SKILL.md" "$SKILL_DIR/SKILL.md"

echo "Installed: $SKILL_DIR/SKILL.md -> $(pwd)/SKILL.md"
echo ""
echo "To install hooks in a repo, copy or symlink from $(pwd)/hooks/:"
echo "  cp $(pwd)/hooks/pre-commit <your-repo>/.git/hooks/pre-commit"
echo "  cp $(pwd)/hooks/pre-push <your-repo>/.git/hooks/pre-push"
echo "  chmod +x <your-repo>/.git/hooks/pre-commit <your-repo>/.git/hooks/pre-push"
```

Save to `install.sh`.

**Step 2: Make executable**

Run: `chmod +x install.sh`

**Step 3: Run install script and verify**

Run: `./install.sh`

Expected output: `Installed: /Users/jimmyyan/.claude/skills/safe-git/SKILL.md -> .../SKILL.md`

**Step 4: Verify symlink**

Run: `ls -la ~/.claude/skills/safe-git/`

Expected: `SKILL.md -> /Users/jimmyyan/work/20-safe-git-skill/SKILL.md`

**Step 5: Commit**

```bash
git add install.sh
git commit -m "feat: add install script for symlinking skill into ~/.claude/skills"
```

---

### Task 4: Write README.md

**Files:**
- Create: `README.md`

**Step 1: Create README**

```markdown
# safe-git

A Claude Code skill that enforces safe git operations through three hard-gate checklists.

## What it prevents

1. **Amending pushed commits after pre-commit failure** — when pre-commit rejects a commit (no commit is created), Claude fixes the code and blindly runs `git commit --amend`, amending the last *pushed* commit instead
2. **Working directly on main/master** — Claude starts work without verifying it's on a feature branch
3. **Staging irrelevant files** — Claude uses `git add .` instead of staging specific files

## Install

```bash
git clone https://github.com/<you>/safe-git-skill ~/work/20-safe-git-skill
cd ~/work/20-safe-git-skill
./install.sh
```

This symlinks `SKILL.md` into `~/.claude/skills/safe-git/`.

## Install hooks (recommended)

Add mechanical protection to any repo:

```bash
cp hooks/pre-commit <your-repo>/.git/hooks/pre-commit
cp hooks/pre-push <your-repo>/.git/hooks/pre-push
chmod +x <your-repo>/.git/hooks/pre-commit <your-repo>/.git/hooks/pre-push
```

## How it works

The skill is invoked by Claude before git operations. It provides three gates:

- **Gate 1**: Check branch before starting any work
- **Gate 2**: Review and stage specific files only
- **Gate 3**: Never amend after pre-commit failure; verify unpushed commits before any amend
```

**Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with install instructions and problem description"
```

---

### Task 5: Verify end-to-end

**Step 1: Check skill is visible to Claude**

Run: `ls -la ~/.claude/skills/safe-git/`

Expected: `SKILL.md` symlink pointing to `~/work/20-safe-git-skill/SKILL.md`

**Step 2: Verify skill frontmatter is valid**

Run: `head -5 ~/.claude/skills/safe-git/SKILL.md`

Expected:
```
---
name: safe-git
description: Use before staging files, committing...
---
```

**Step 3: Check final repo state**

Run: `git log --oneline`

Expected: 4 commits visible (SKILL.md, hooks, install.sh, README)

Run: `git status`

Expected: `nothing to commit, working tree clean`
