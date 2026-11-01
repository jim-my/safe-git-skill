---
name: safe-git
description: Use before local code edits, creating a branch, adding a worktree, starting work on a ticket, or opening a PR. Runs a fast guard that refuses unsafe states - working in the main worktree, on a stale or diverged branch, or on main/master itself. Pre-commit/pre-push hooks (when installed) also block commits or pushes to main/master.
---

# safe-git

**Announce at start:** "I'm using the safe-git skill to verify safe git operations."

## Fast Path

This skill is backed by `~/.local/bin/safe-git`. Do not emulate its checks manually: if the command is missing or not executable, stop and install or repair the skill before starting implementation, creating a worktree, opening a PR, or tearing down a branch.

Invoke `safe-git` before any local code edit that is more than a trivial one-line typo/comment/docs fix. Creating a local branch, starting a ticket, adopting existing branch work, opening a PR, and cleaning up after merge also count as guarded operations. If work will change files, the safe path is a linked worktree unless `safe-git` explicitly accepts the current checkout.

Run the guard command for the operation you are about to do:

```bash
~/.local/bin/safe-git worktree start .worktrees/<task> -b <feature-branch> --purpose "<why this worktree exists>"
~/.local/bin/safe-git worktree start .worktrees/<slug>-<issue-id> -b <feature-branch> --issue "#<issue-id>" --title "<issue title>" --ticket-source github --purpose "<why this worktree exists>"
~/.local/bin/safe-git worktree adopt .worktrees/<task> --purpose "<why this worktree exists>"
~/.local/bin/safe-git worktree plan-id  # copy its output to the first line of an exact branch plan
~/.local/bin/safe-git worktree plan-id --bind  # existing guarded worktree with no ID
~/.local/bin/safe-git check start    # before writing any code
~/.local/bin/safe-git check pr       # before opening a PR
~/.local/bin/safe-git check done     # after the PR merges — fast-forwards the default branch, then tears down the worktree and local branch
~/.local/bin/safe-git check plan-done  # for a plan-only ticket (no PR) — tears down the worktree and local branch after verifying they sit exactly at the recorded base
~/.local/bin/safe-git check plan-done --resume-branch <branch> --ticket-source <github|local> --ticket-id <id>  # reconcile an interrupted plan-only teardown from main
```

When creating a new linked worktree, prefer `worktree start` over raw `git worktree add`. It creates the worktree from the default base, requires a purpose, and writes `.git/safe-git/worktrees/<branch>.md` in the repo common git dir with branch/path/base/created metadata, optional issue/title/ticket-source fields, and an initial timestamped activity-log entry. The metadata stays outside the worktree, so it does not dirty project files. Run it from the main worktree, not from an existing linked worktree. Use `--base <ref>` when the default base is wrong, `--issue <id>` / `--title <text>` when starting from an issue, and `--ticket-source <github|local>` when the ticket is GitHub or local (the recorded source binds plan-only evidence archiving to the correct ticket). For GitHub issue work, include the issue id in the worktree path, such as `.worktrees/<slug>-<issue-id>`, so `git worktree list` and shell prompts identify the ticket without opening metadata. `worktree start` and `worktree adopt` reject target paths that resolve inside the main checkout unless the target is under that checkout's `.worktrees/` directory; use `.worktrees/<task>` or a path outside the main checkout.

If work already happened on `main` or `master`, do not just create a branch and continue in the main worktree. Move the work into a linked worktree instead: stash or patch the changes, run `safe-git worktree start .worktrees/<task> -b <feature-branch> --purpose "<why this worktree exists>"`, then apply the changes there. If you already created a feature branch as a recovery step and the tree is clean, run `safe-git worktree adopt .worktrees/<task> --purpose "<why this worktree exists>"` before continuing.

When work already happened on `main` and the intended changes are untracked files mixed with unrelated untracked files, prefer the copy-by-explicit-path recovery: create a fresh safe-git worktree from the default base, create parent directories as needed, copy only the intended paths into the worktree, then stage those exact paths. Verify the PR worktree with `git status --short`, `git diff --cached --name-only`, and `git ls-files --others --exclude-standard` before committing. Leave unrelated untracked files in the original checkout untouched.

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

`check done` verifies the branch's PR is `MERGED` **and** that local `HEAD` matches the PR's `headRefOid` via `gh pr view` before touching anything. It switches the main worktree to the default branch, fetches `origin/<default>`, and fast-forwards to that explicit ref before deleting the feature worktree/branch. If `gh` isn't available, the PR isn't merged, the tree is dirty, local HEAD has drifted from the merged tip, or the default branch cannot fast-forward, it refuses — no partial teardown. A dirty main checkout does not block cleanup of a separate linked worktree: `check done` removes the worktree and branch first, then fast-forwards the default branch only if the main checkout is already on it and `git merge --ff-only` accepts the local edits, otherwise it prints a `WARNING:` with the command to run later. It never switches a dirty main checkout to another branch.

`check plan-done` is for a plan-only ticket that completes at Phase 2 and intentionally never opens a PR, so there is no `gh` signal to trust. It reads the branch's recorded base from the worktree metadata (`- Base:`, pinned to an immutable commit SHA at `worktree start`), then verifies the working tree is clean and `git rev-parse HEAD` is exactly equal to the recorded base before removing the worktree (if any) and the local branch. (A two-dot count would only prove HEAD is an ancestor of the base; exact equality is required so a branch reset behind its base is refused.) The ticket flow persists the exact branch before teardown; after an interrupted destructive step, rerun from the main checkout with `--resume-branch <branch> --ticket-source <github|local> --ticket-id <id>`. Resume revalidates that ticket identity against surviving metadata and its durable archive before reconciling an intact, partial, or already-absent branch/worktree. It never calls `gh` or fetches. A dirty main checkout does not block cleanup of a separate linked ticket worktree; when the main checkout is itself the surviving ticket worktree, its dirtiness blocks resume. It also refuses a dirty surviving linked ticket worktree, a branch that differs from the recorded base, a main/master branch, detached HEAD, ref-like branch aliases, missing/unparsable metadata while the branch still exists (including the literal `- Base: existing branch` written by `worktree adopt`), or an unverified plan-only stop. The evidence's Phase 2 checkpoint must record `status: plan_only` AND `plan_review: clean`, both the live and archived evidence must be regular non-symlink files with identical bytes, and the preserved live `.plans/` tree must match the source-qualified archive at `<main-checkout>/.plans/ticket-<source>-<id>/.plans/` — leaving remaining state intact for recovery.

After merging a PR, if this checkout is on the merged PR branch, immediately run `~/.local/bin/safe-git check done` before the final response. If this checkout is on the default branch but a local PR branch or worktree remains, switch to that branch or worktree and run `~/.local/bin/safe-git check done` there. If cleanup is not applicable because the merge was remote-only or no local PR branch/worktree remains, say that explicitly.

## Maintainer Checks

Guarded operations are `safe-git` commands that create, adopt, check, push,
delete, or otherwise gate local Git/worktree state. When adding or changing one,
design it to be idempotent before documenting it as safe. Define what happens if
the command is run twice, if a previous run stopped after creating only part of
its state, and if stale metadata or a half-removed worktree already exists.
Prefer reconcile/adopt or refuse-with-recovery behavior over assuming a clean
first run.

## Policy (code-enforced)

The following are enforced by `safe-git check`, and — in repos where the pre-commit/pre-push hooks have been installed — by those hooks at `git commit`/`git push` time. `worktree start` and `worktree adopt` now auto-install/refresh the hooks into the repo's shared hooks dir (covering the main checkout and every linked worktree); the installer still does not wire them globally (see the "Install hooks" section of `README.md`), so a repo never touched by `worktree start`/`adopt` enforces only via the `check` commands. A green `ok` from the script, or a clean `git commit`/`git push` **in a hook-installed repo**, means these held:

- Not committing directly to `main`/`master` (pre-commit hook, `check start`, `check pr`).
- Not pushing to `main`/`master` (pre-push hook).
- Not pushing a ticket branch whose pushed SHA lacks a g-review receipt (pre-push hook). When `.plans/ticket-*-evidence.md` matching the branch is present in the pushing checkout, a worktree on the pushed source or destination branch or with the pushed commit as its HEAD, or a detached worktree, the hook runs `skillbin g-review-receipt find-current --head-sha <pushed SHA> --for-push` and refuses the push unless a receipt exists for the **exact pushed SHA**, written on a clean tree, with verdict `clean` or `findings` fully dispositioned. The parent writes schema-7 receipts from validated canonical JSON judgments and Git/preflight metadata; Markdown is presentation only. Schema-6 receipts remain history, but require fresh review before a push. A typed-but-unrun `g-review: clean` cannot be pushed. There is no stale-receipt survival path: a post-review commit or reviewed-base tip change requires re-running g-review before pushing. This is push authorization only: current-head Codex approval is still required before merge. Closes the hand-rolled `git push` + `gh pr create` path around the ticket review gate. A matching ticket push also fails when `skillbin` is missing; restore it on PATH or explicitly override an intentional WIP push with `SAFE_GIT_SKIP_RECEIPT_GATE=1`.
- Not starting implementation in the main worktree — use a linked worktree from the default base (`check start`).
- Not creating unlabeled safe-git worktrees — `worktree start` requires a purpose and records local context.
- Not starting implementation on a stale or diverged branch (`check start`).
- Not starting implementation while a rebase/merge/cherry-pick/revert/bisect is in progress — HEAD is partial (`check start`, `check pr`, `check done`, `check plan-done`).
- Not continuing a rebase that would land commits on `main`/`master` (pre-commit hook detects the detached-HEAD-during-rebase case).
- Not tearing down a branch whose PR is not `MERGED` — `check done` refuses on OPEN/CLOSED/DRAFT state, missing PR, or `gh` unavailable.
- Not tearing down a branch whose local tip diverges from the PR's merged commit — `check done` refuses if local `HEAD` does not match the PR's `headRefOid` (e.g., commits added locally after merge).
- Not tearing down a dirty working tree — `check done` and `check plan-done` refuse on any unstaged, staged, or untracked change.
- Not deleting `main`/`master` via teardown — `check done` and `check plan-done` refuse when the current branch is the default.
- Not leaving a clean main worktree stale after teardown — `check done` fetches `origin/<default>` and fast-forwards the default branch to that explicit ref before deleting the feature worktree/branch. A dirty main checkout gets a best-effort fast-forward after teardown and a `WARNING:` when it cannot move.
- Not tearing down a plan-only branch that has drifted from its base — `check plan-done` refuses when the branch has any commits beyond the base recorded in the worktree metadata, so plan-only cleanup never destroys committed work.
- Not deleting a plan-only branch when its recorded base cannot be verified — `check plan-done` refuses on missing metadata or the unverifiable `- Base: existing branch` literal (`worktree adopt`), leaving the branch/worktree intact for manual recovery.

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
