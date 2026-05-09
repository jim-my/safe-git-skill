# safe-git

A Claude Code and Codex skill backed by a small guard CLI. The script handles fast mechanical checks; the skill tells agents when to run it and what to do if it blocks. The CLI is the enforcement boundary: agents should not emulate `safe-git` checks by hand when the command is missing.

## What it prevents

1. Committing directly to `main` or `master` (pre-commit hook, including the detached-HEAD rebase case). *Requires hooks installed in the repo — see "Install hooks" below.*
2. Pushing to `main` or `master` (pre-push hook). *Requires hooks installed in the repo.*
3. Starting implementation in the main worktree (`check start`).
4. Starting implementation from a stale or diverged branch (`check start`).
5. Starting implementation or opening a PR while a rebase/merge/cherry-pick/revert/bisect is in progress — HEAD is partial, any "ok" would be harmful (`check start`, `check pr`, `check done`).
6. Tearing down a branch whose PR is not `MERGED`, or tearing down a dirty working tree (`check done`).

It also provides `worktree start`, a safe creation path that records the worktree's purpose in repo-local git metadata so later sessions can see what the worktree is for. If work already started on a feature branch in the main checkout, `worktree adopt` moves that clean branch into a linked worktree and returns the main checkout to the default branch.

The `check` commands run at agent-prompt time and always enforce once invoked. The hooks run at `git commit`/`git push` time but are copy-to-install per-repo — the skill installer does not wire them globally. If `safe-git` is unavailable, install or repair it before relying on this skill.

## Commands

```bash
safe-git worktree start .worktrees/<task> -b <feature-branch> --purpose "<why this worktree exists>"
safe-git worktree adopt .worktrees/<task> --purpose "<why this worktree exists>"
safe-git check start              # before creating a branch, worktree, or starting work on a ticket
safe-git check start --read-only  # investigation only; worktree+freshness advisory
safe-git check start --no-fetch   # skip `git fetch`; freshness uses cached refs
safe-git check pr                 # before opening a PR
safe-git check done               # after PR merges — fast-forward default branch, then remove worktree + local branch
```

`worktree start` creates a linked worktree from the default base ref, writes `.git/safe-git/worktrees/<branch>.md` in the repo common git dir with branch/path/base/created metadata, optional issue/title fields, the required purpose, and an initial timestamped activity-log entry. The metadata stays outside the worktree, so it does not dirty project files. Use `--base <ref>` to override the default base, `--issue <id>` and `--title <text>` to capture issue context, and `--no-fetch` only when the caller already fetched.

`worktree adopt` must run from the main worktree while it is checked out on a clean, non-main branch. It verifies the branch is fresh, switches the main checkout back to the local default branch, fast-forwards that branch to `origin/<default>`, creates a linked worktree for the original branch, and writes the same repo-local metadata. It refuses dirty worktrees, detached HEAD, main/master, stale or diverged branches, linked-worktree callers, missing local default branches, and unknown flags. Use `--no-fetch` only when the caller already fetched.

`check done` verifies the PR state is `MERGED` **and** that local `HEAD` matches the PR's `headRefOid` (so commits made after the merge aren't destroyed) via `gh pr view` before doing anything. It switches the main worktree to the default branch, fetches `origin/<default>`, and fast-forwards to that explicit ref before deleting the feature worktree/branch, so local `main` is current after cleanup without depending on local upstream configuration. Refuses on dirty tree, detached HEAD, main/master branch, missing PR, non-merged PR, divergent local HEAD, default-branch fast-forward failure, or missing `gh`.

Unknown flags are rejected with a usage hint — typos like `--readonly` will fail loudly rather than silently falling through to the write-mode path.

`check stage` and `check amend` are deliberately not shipped — see SKILL.md for the rationale.

## Install

Clone this repository and run the installer from the checkout:

```bash
./install.sh
```

This installs the skill into `~/.agents/skills/safe-git/`, links both `~/.claude/skills/safe-git/` and `~/.codex/skills/safe-git/`, and links `~/.local/bin/safe-git`.

## Install hooks

Add mechanical protection to any repo:

```bash
cp hooks/pre-commit <your-repo>/.git/hooks/pre-commit
cp hooks/pre-push <your-repo>/.git/hooks/pre-push
chmod +x <your-repo>/.git/hooks/pre-commit <your-repo>/.git/hooks/pre-push
```

`pre-commit` blocks direct commits to `main`/`master`, including commits made during a rebase of `main`/`master` (detached HEAD).
`pre-push` blocks pushing to `main`/`master`.
