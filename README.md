# safe-git

A Claude Code and Codex skill backed by a small guard CLI. The script handles fast mechanical checks; the skill tells agents when to run it and what to do if it blocks. The CLI is the enforcement boundary: agents should not emulate `safe-git` checks by hand when the command is missing.

Agent trigger: invoke `safe-git` before any local code edit that is more than a trivial one-line typo/comment/docs fix. Creating a local branch, starting a ticket, adopting existing branch work, opening a PR, and cleaning up after merge also count as guarded operations.

## What it prevents

1. Committing directly to `main` or `master` (pre-commit hook, including the detached-HEAD rebase case). *Requires hooks installed in the repo — see "Install hooks" below.*
2. Pushing to `main` or `master` (pre-push hook). *Requires hooks installed in the repo.*
3. Pushing a ticket branch whose pushed SHA lacks a g-review receipt (pre-push hook). When the pushing checkout, a worktree on the pushed source or destination branch or with the pushed commit as its HEAD, or a detached worktree carries `.plans/ticket-*-evidence.md` matching the branch, the hook runs `skillbin g-review-receipt find-current --head-sha <pushed SHA> --for-push` and refuses the push unless a receipt exists for the exact pushed SHA, written on a clean tree, with verdict `clean` or `findings` fully dispositioned. The parent writes schema-7 receipts from validated canonical JSON judgments and Git/preflight metadata; Markdown is presentation only. Schema-6 receipts remain history, but require fresh review before a push. A hand-rolled `git push` + `gh pr create` or a typed-but-unrun `g-review: clean` cannot bypass the review gate. There is no stale-receipt survival: a post-review commit or reviewed-base tip change invalidates it. Current-head Codex approval is still required before merge. A matching ticket push fails if `skillbin` is absent; restore it on PATH or explicitly override an intentional WIP push with `SAFE_GIT_SKIP_RECEIPT_GATE=1`. *Requires hooks installed in the repo.*
4. Starting implementation in the main worktree (`check start`).
5. Starting implementation from a stale or diverged branch (`check start`).
6. Starting implementation or opening a PR while a rebase/merge/cherry-pick/revert/bisect is in progress — HEAD is partial, any "ok" would be harmful (`check start`, `check pr`, `check done`).
7. Tearing down a branch whose PR is not `MERGED`, or tearing down a dirty working tree (`check done`).
8. Tearing down a plan-only branch that has drifted from its base, or whose recorded base cannot be verified (`check plan-done`).

It also provides `worktree start`, a safe creation path that records the worktree's purpose in repo-local git metadata so later sessions can see what the worktree is for. If work already started on a feature branch in the main checkout, `worktree adopt` moves that clean branch into a linked worktree and returns the main checkout to the default branch.

The `check` commands run at agent-prompt time and always enforce once invoked. The hooks run at `git commit`/`git push` time; `worktree start`/`adopt` auto-install them into the repo's shared hooks dir (see "Install hooks" below), but the skill installer does not wire them globally — a repo never touched by `worktree start`/`adopt` has no hooks until you install them by hand. If `safe-git` is unavailable, install or repair it before relying on this skill.

## Commands

```bash
safe-git worktree start .worktrees/<task> -b <feature-branch> --purpose "<why this worktree exists>"
safe-git worktree start .worktrees/<slug>-<issue-id> -b <feature-branch> --issue "#<issue-id>" --title "<issue title>" --ticket-source github --purpose "<why this worktree exists>"
safe-git worktree adopt .worktrees/<task> --purpose "<why this worktree exists>"
safe-git worktree plan-id         # print the field for an exact branch plan
safe-git worktree plan-id --bind  # assign an ID to an older guarded worktree
safe-git check start              # before creating a branch, worktree, or starting work on a ticket
safe-git check start --read-only  # investigation only; worktree+freshness advisory
safe-git check start --no-fetch   # skip `git fetch`; freshness uses cached refs
safe-git check pr                 # before opening a PR
safe-git check done               # after PR merges — fast-forward default branch, then remove worktree + local branch
safe-git check plan-done           # plan-only ticket (no PR) — remove worktree + local branch after verifying they sit at the recorded base
safe-git check plan-done --resume-branch <branch> --ticket-source <github|local> --ticket-id <id>  # reconcile an interrupted plan-only teardown from the main checkout
```

`worktree start` creates a linked worktree from the default base ref, writes `.git/safe-git/worktrees/<branch>.md` in the repo common git dir with branch/path/base/created metadata, optional issue/title/ticket-source fields, the required purpose, and an initial timestamped activity-log entry. The metadata stays outside the worktree, so it does not dirty project files. Run it from the main worktree, not from an existing linked worktree. Use `--base <ref>` to override the default base, `--issue <id>` and `--title <text>` to capture issue context, `--ticket-source <github|local>` to record the ticket source (binds plan-only evidence archiving), and `--no-fetch` only when the caller already fetched. For GitHub issue work, include the issue id in the worktree path, such as `.worktrees/<slug>-<issue-id>`, so the ticket remains visible in `git worktree list` and shell prompts. `worktree start` and `worktree adopt` reject target paths that resolve inside the main checkout unless the target is under that checkout's `.worktrees/` directory; use `.worktrees/<task>` or a path outside the main checkout.

`worktree adopt` must run from the main worktree while it is checked out on a clean, non-main branch. It verifies the branch is fresh, switches the main checkout back to the local default branch, fast-forwards that branch to `origin/<default>`, creates a linked worktree for the original branch, and writes the same repo-local metadata. It refuses dirty worktrees, detached HEAD, main/master, stale or diverged branches, linked-worktree callers, missing local default branches, and unknown flags. Use `--no-fetch` only when the caller already fetched.

If that fast-forward or worktree creation fails, adoption attempts to restore the
original feature checkout and still exits nonzero. Any completed default-branch
fast-forward is retained. If Git also refuses checkout restoration, the error
names the branch and recovery command; inspect `git status` and resolve the
failure before retrying. Recovery never forces a checkout or deletes partial state.

`check done` verifies the PR state is `MERGED` **and** that local `HEAD` matches the PR's `headRefOid` (so commits made after the merge aren't destroyed) via `gh pr view` before doing anything. It switches the main worktree to the default branch, fetches `origin/<default>`, and fast-forwards to that explicit ref before deleting the feature worktree/branch, so local `main` is current after cleanup without depending on local upstream configuration. Refuses on dirty tree, detached HEAD, main/master branch, missing PR, non-merged PR, divergent local HEAD, default-branch fast-forward failure, or missing `gh`. From a linked worktree, a dirty main checkout does not block cleanup: the worktree and branch are removed first, then the default branch is fast-forwarded only when the main checkout is already on it and `git merge --ff-only` does not conflict with the local edits; otherwise `check done` prints a `WARNING:` with the command to run later and never switches the dirty checkout's branch.

`check plan-done` is the cleanup path for a plan-only ticket that completes at Phase 2 and intentionally never opens a PR, so it cannot rely on a `gh` merge signal. It reads the branch's recorded base from the worktree metadata (`- Base:`, pinned to an immutable commit SHA at `worktree start`), verifies the working tree is clean and `git rev-parse HEAD` equals the recorded base exactly (a two-dot count would only prove ancestry, so a branch reset behind its base is refused), then removes the worktree (if any) and the local branch. The ticket workflow persists the branch before teardown; if the process stops after a destructive step but before recording completion, rerun from the main checkout with `--resume-branch <branch> --ticket-source <github|local> --ticket-id <id>`. Resume revalidates that ticket identity against surviving metadata and its durable archive before reconciling an intact, partial, or already-absent branch/worktree. It never calls `gh`, never fetches, and never moves the default branch beyond switching a plan-only branch checked out in the main worktree back to the default branch. A dirty main checkout does not block cleanup of a separate linked ticket worktree; when the main checkout is itself the surviving ticket worktree, its dirtiness blocks resume. It also refuses a dirty surviving linked ticket worktree, a branch that differs from the recorded base, main/master branch, detached HEAD, ref-like branch aliases, missing/unparsable metadata while the branch still exists (including the literal `- Base: existing branch` written by `worktree adopt`), or an unverified plan-only stop. The evidence's Phase 2 checkpoint must record `status: plan_only` AND `plan_review: clean`, both the live and archived evidence must be regular non-symlink files with identical bytes, and the preserved live `.plans/` tree must match the source-qualified archive at `<main-checkout>/.plans/ticket-<source>-<id>/.plans/` — leaving remaining state intact for recovery.

Unknown flags are rejected with a usage hint — typos like `--readonly` will fail loudly rather than silently falling through to the write-mode path.

`check stage` and `check amend` are deliberately not shipped — see SKILL.md for the rationale.

## Branch plan provenance

In a guarded linked worktree, run `safe-git worktree plan-id` and copy its
`g-review-work-id: <id>` output as the first line of the exact branch-named
review plan. The ID is recorded when `worktree start` or `worktree adopt` runs;
it stays stable through commits and rebases. An older guarded worktree without
an ID can use `safe-git worktree plan-id --bind` once. The command refuses
malformed or mismatched metadata. The `g-review` skill, when installed, documents
plan locations and branch-name encoding in its plan audit instructions.

## Main checkout resolution

Operations that need the main checkout call the bundled `bin/resolve-main-worktree`.
This supports ordinary repositories, submodules (including their linked
worktrees and per-worktree configuration), and the main checkout of a
`--separate-git-dir` repository. If no main checkout can be resolved — for
example, from a linked worktree of a bare or separate-Git-directory repository —
the operation refuses before creating or removing a worktree. Run creation from
the main checkout when one exists; otherwise cleanup requires manual inspection.
Newline-bearing main checkout and worktree target paths are refused. `worktree start` and `worktree adopt` reject these targets before creating a worktree or switching branches.

## Install

```bash
./install.sh
```

This installs the skill into `~/.agents/skills/safe-git/`, links both `~/.claude/skills/safe-git/` and `~/.codex/skills/safe-git/`, and links `~/.local/bin/safe-git`.

Some features serve the separate `ticket` and `g-review` skills. The core guard and hooks need neither:

- The pre-push receipt gate engages only when `.plans/ticket-*-evidence.md` matches the pushed branch. It then needs `skillbin` and the `g-review` helpers, and blocks that push without them; override it with `SAFE_GIT_SKIP_RECEIPT_GATE=1`.
- `check plan-done` refuses to run unless the worktree was started with ticket metadata and has the ticket workflow's evidence.
- `worktree plan-id` runs, but only `g-review` reads the ID it prints.

## Install hooks

`worktree start` and `worktree adopt` auto-install/refresh the hooks into the
shared `git rev-parse --git-common-dir`/hooks dir, which covers the main checkout
and every linked worktree. They manage hooks carrying the `safe-git-managed-hook`
marker (and recognize/upgrade a pre-marker legacy safe-git hook); a foreign
`pre-commit`/`pre-push` is left untouched, with a note. So in normal
ticket/worktree flow you get the hooks for free.

Exception: if the repo sets `core.hooksPath` at all (relative, absolute, or
global — Husky, pre-commit, a global policy), auto-install is skipped with a
note, because the redirected dir may live inside the worktree (dirtying it) or
govern other repos. Install the hooks into your configured hooks dir by hand.

To add the protection to a repo by hand (e.g. one you never run `worktree
start` in):

```bash
cp hooks/pre-commit <your-repo>/.git/hooks/pre-commit
cp hooks/pre-push <your-repo>/.git/hooks/pre-push
chmod +x <your-repo>/.git/hooks/pre-commit <your-repo>/.git/hooks/pre-push
```

`pre-commit` blocks direct commits to `main`/`master`, including commits made during a rebase of `main`/`master` (detached HEAD).
`pre-push` blocks pushing to `main`/`master`, and refuses pushing a ticket branch whose Phase 4 receipt is incomplete (see "What it prevents" #3).
