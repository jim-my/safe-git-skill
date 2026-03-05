# safe-git Skill Design

**Date**: 2026-03-05
**Status**: Approved

## Problem

Claude reliably violates three git safety rules even when they exist in CLAUDE.md:

1. **Amending pushed commits after pre-commit failure** — pre-commit rejects the commit (no commit is created), Claude fixes the code, then does `git commit --amend` which amends the last *pushed* commit instead
2. **Creating a PR while on main/master** — Claude runs `gh pr create` without verifying the current branch
3. **Staging irrelevant files** — Claude uses `git add .` or `git add -A` instead of staging specific files

Root cause: CLAUDE.md rules are always-loaded but diluted by competing instructions. During error-recovery mode (e.g. after a pre-commit failure), Claude doesn't re-consult them.

## Solution

A `safe-git` skill with hard-gate checklists, invoked before git operations, plus two complementary shell hooks as automated backstops.

## Skill Design

**Name**: `safe-git`
**Trigger**: Use before staging files, committing (including after pre-commit failures), or creating a PR — enforces safe git operations
**Type**: Rigid (checklists must be followed exactly)

### Gate 1 — Before starting any work on a task

1. Run `git branch --show-current`
2. If result is `main` or `master` → **STOP**, create a feature branch first, then begin work

### Gate 2 — Before staging files

1. Run `git status` and review ALL changes
2. Stage specific files only: `git add <file1> <file2>`
3. `git add .` and `git add -A` are **FORBIDDEN**

### Gate 3 — Before any commit

1. **If recovering from a pre-commit failure**: the failed commit never existed — use a fresh `git commit -m "..."`, NEVER `--amend`
2. Before ANY `git commit --amend`: run `git log @{u}..HEAD --oneline`
   - Returns nothing → amend is **FORBIDDEN**, create a new commit instead
   - Returns commits → amend is safe

## Complementary Hooks (Automated Backstops)

These hooks provide mechanical protection independent of Claude's judgment.

### pre-commit hook — blocks direct commits to main

```bash
#!/bin/bash
branch=$(git branch --show-current)
if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
  echo "ERROR: Direct commit to $branch is not allowed. Create a feature branch first."
  exit 1
fi
```

### pre-push hook — blocks pushing to main

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

## Distribution

- Skill lives in `~/work/20-safe-git-skill/` as a standalone git repo
- Install by symlinking `SKILL.md` into `~/.claude/skills/safe-git/SKILL.md`
- Hooks are recommended setup documented in the skill itself

## Out of Scope

- Enforcing commit message format (separate concern)
- Branch naming conventions
- PR template enforcement
