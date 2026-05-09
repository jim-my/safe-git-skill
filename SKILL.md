---
name: safe-git
description: Use before creating a branch, adding a worktree, starting work on a ticket, or opening a PR. Runs a fast guard that refuses unsafe states - working in the main worktree, on a stale or diverged branch, or on main/master itself. Pre-commit/pre-push hooks (when installed) also block commits or pushes to main/master.
---

# safe-git

**Announce at start:** "I'm using the safe-git skill to verify safe git operations."

## Fast Path

This skill is backed by `~/.local/bin/safe-git`. Do not emulate its checks manually: if the command is missing or not executable, stop and install or repair the skill before starting implementation, creating a worktree, opening a PR, or tearing down a branch.

Run the guard command for the operation you are about to do:

```bash
~/.local/bin/safe-git worktree start .worktrees/<task> -b <feature-branch> --purpose "<why this worktree exists>"
~/.local/bin/safe-git worktree adopt .worktrees/<task> --purpose "<why this worktree exists>"
~/.local/bin/safe-git check start    # before writing any code
~/.local/bin/safe-git check pr       # before opening a PR
~/.local/bin/safe-git check done     # after the PR merges — fast-forwards the default branch, then tears down the worktree and local branch
```

When creating a new linked worktree, prefer `worktree start` over raw `git worktree add`. It creates the worktree from the default base, requires a purpose, and writes `.git/safe-git/worktrees/<branch>.md` in the repo common git dir with branch/path/base/created metadata, optional issue/title fields, and an initial timestamped activity-log entry. The metadata stays outside the worktree, so it does not dirty project files. Use `--base <ref>` when the default base is wrong, and `--issue <id>` / `--title <text>` when starting from an issue.

If work already happened on `main` or `master`, do not just create a branch and continue in the main worktree. Move the work into a linked worktree instead: stash or patch the changes, run `safe-git worktree start .worktrees/<task> -b <feature-branch> --purpose "<why this worktree exists>"`, then apply the changes there. If you already created a feature branch as a recovery step and the tree is clean, run `safe-git worktree adopt .worktrees/<task> --purpose "<why this worktree exists>"` before continuing.

When work has already started on a clean non-main branch in the main worktree, use `worktree adopt` to move that branch into a linked worktree. It checks branch freshness, returns the main checkout to the default branch, creates a linked worktree for the original branch, and records the same metadata. It refuses dirty state; commit or stash first.

If the command exits 0, continue. If it exits nonzero, stop and follow the printed instruction. Do not bypass a block without telling the user the exact risk.

For read-only investigation, use:

```bash
~/.local/bin/safe-git check start --read-only
```

For chained checks where the caller just fetched, skip the fetch:

```bash
~/.local/bin/safe-git check start --no-fetch
```

`check done` verifies the branch's PR is `MERGED` **and** that local `HEAD` matches the PR's `headRefOid` via `gh pr view` before touching anything. It switches the main worktree to the default branch, fetches `origin/<default>`, and fast-forwards to that explicit ref before deleting the feature worktree/branch. If `gh` isn't available, the PR isn't merged, the tree is dirty, local HEAD has drifted from the merged tip, or the default branch cannot fast-forward, it refuses — no partial teardown.

After merging a PR, if this checkout is on the merged PR branch, immediately run `~/.local/bin/safe-git check done` before the final response. If this checkout is on the default branch but a local PR branch or worktree remains, switch to that branch or worktree and run `~/.local/bin/safe-git check done` there. If cleanup is not applicable because the merge was remote-only or no local PR branch/worktree remains, say that explicitly.

## Policy (code-enforced)

The following are enforced by `safe-git check`, and — in repos where the pre-commit/pre-push hooks have been installed — by those hooks at `git commit`/`git push` time. The installer does not wire hooks globally (see the "Install hooks" section of `README.md`); in repos without hooks, only the `check` commands enforce. A green `ok` from the script, or a clean `git commit`/`git push` **in a hook-installed repo**, means these held:

- Not committing directly to `main`/`master` (pre-commit hook, `check start`, `check pr`).
- Not pushing to `main`/`master` (pre-push hook).
- Not starting implementation in the main worktree — use a linked worktree from the default base (`check start`).
- Not creating unlabeled safe-git worktrees — `worktree start` requires a purpose and records local context.
- Not starting implementation on a stale or diverged branch (`check start`).
- Not starting implementation while a rebase/merge/cherry-pick/revert/bisect is in progress — HEAD is partial (`check start`, `check pr`, `check done`).
- Not continuing a rebase that would land commits on `main`/`master` (pre-commit hook detects the detached-HEAD-during-rebase case).
- Not tearing down a branch whose PR is not `MERGED` — `check done` refuses on OPEN/CLOSED/DRAFT state, missing PR, or `gh` unavailable.
- Not tearing down a branch whose local tip diverges from the PR's merged commit — `check done` refuses if local `HEAD` does not match the PR's `headRefOid` (e.g., commits added locally after merge).
- Not tearing down a dirty working tree — `check done` refuses on any unstaged, staged, or untracked change.
- Not deleting `main`/`master` via teardown — `check done` refuses when the current branch is the default.
- Not leaving the main worktree stale after teardown — `check done` fetches `origin/<default>` and fast-forwards the default branch to that explicit ref before deleting the feature worktree/branch.

## Policy (advisory)

Follow these even though no code blocks them. A wrapper that tried to enforce them would either be narration (exit 0 + warning — useless) or add agent-/shell-/OS-specific complexity beyond what a skill should carry. Agents that bypass policy also bypass wrappers (shell alias, env prefix, explicit path), so the honest control here is agent discipline.

- Stage explicit paths only. Do not use `git add .`, `git add -A`, or `git add --all`.
- Do not `git commit --amend` once HEAD is visible on a remote branch. If in doubt, create a fresh commit.
- After a failed pre-commit hook, create a new commit — do not `--amend` to recover.

## Out of scope

`check stage` and `check amend` used to exist but printed warnings and returned 0, which a compliant agent reads as permission. A guard whose `ok` doesn't mean safe is worse than no tool. They were dropped rather than shipped as narration.

If you need to enforce staging or amend discipline, the right shape is a wrapper command that refuses the unsafe form at exit-code level (e.g. `safe-git stage <paths>` that rejects `.`/`-A`/`--all`). Not shipped here.

## Capture gaps

If you notice or later discover this skill missed something it should have caught — wrong instruction, missing check, guard let through unsafe state, blocker fired wrongly — save the gap as `feedback_safe_git_gap_<topic>.md` in memory, including the `self-review` §4 global-candidate marker. Accumulated gaps inform when to fold a fix back into the skill or guard script.
