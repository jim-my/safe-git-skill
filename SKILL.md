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
   > **WARNING:** `git add .` and `git add -A` are **FORBIDDEN** — they silently include unrelated changes. Stop immediately. Do not run these commands. Explain the situation to the user.
4. Verify staged files:
   ```bash
   git diff --staged --stat
   ```
   Confirm only intended files appear. If unintended files are staged, unstage them:
   ```bash
   git restore --staged <file>
   ```

## Gate 3 — Before any commit

### If recovering from a pre-commit hook failure:

The pre-commit hook rejected the commit — **no commit was created**.
After fixing the issue, use a fresh commit:

```bash
git commit -m "your message"
```

`git commit --amend` is **FORBIDDEN** in this case. Stop immediately. Do not run this command. Explain the situation to the user. The commit you would be amending is the last *pushed* commit, not a new one.

### Before any other use of `git commit --amend`:

Run:
```bash
git log @{u}..HEAD --oneline
```

> **Note:** If this command fails with "no upstream configured" or similar error, the branch is local-only (never pushed). Amend is safe.

- **Returns commits** → amend is safe (those commits are unpushed)
- **Returns nothing** → amend is **FORBIDDEN**, all commits are already pushed. Stop immediately. Do not run this command. Explain the situation to the user.

  Use a fresh commit instead:
  ```bash
  git commit -m "your message"
  ```

## Gate 4 — Before creating a PR

1. Run `git branch --show-current`
2. If result is `main` or `master` → **STOP immediately. Do not proceed.**

   You cannot create a PR from main/master. Create a feature branch first:
   ```bash
   git checkout -b <descriptive-branch-name>
   # move your changes to the feature branch if needed
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
