# safe-git

A Claude Code skill that enforces safe git operations through four hard-gate checklists.

## What it prevents

1. **Amending pushed commits after pre-commit failure** — when pre-commit rejects a commit (no commit is created), Claude fixes the code and blindly runs `git commit --amend`, amending the last *pushed* commit instead
2. **Working directly on main/master** — Claude starts work without verifying it's on a feature branch
3. **Staging irrelevant files** — Claude uses `git add .` instead of staging specific files
4. **Creating a PR from main/master** — Claude runs `gh pr create` without checking the current branch

## Install

```bash
git clone https://github.com/<you>/safe-git-skill ~/work/safe-git-skill
cd ~/work/safe-git-skill
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

**pre-commit**: blocks direct commits to main/master
**pre-push**: blocks pushing to main/master

## How it works

Claude invokes this skill before git operations. It enforces four gates:

- **Gate 1**: Check branch before starting any work — stop if on main/master
- **Gate 2**: Review `git status`, stage specific files only, verify with `git diff --staged --stat`
- **Gate 3**: Never amend after pre-commit failure; verify unpushed commits before any amend
- **Gate 4**: Check branch before creating a PR — stop if on main/master
