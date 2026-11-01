#!/usr/bin/env bash
# Tests for safe-git's pre-commit / pre-push hook scripts.
#
# Hook scripts are invoked directly (not through `git commit` /
# `git push`), so the tests don't depend on git's exact hook-runner
# contract — only on the documented inputs each hook receives:
#
#   pre-commit: no args, no stdin. Inspects HEAD via `git`.
#   pre-push:   `<remote> <url>` args; reads `local_ref local_sha
#               remote_ref remote_sha` lines on stdin.

run_pre_commit() {
  ( cd "$1" && bash "$HOOKS_DIR/pre-commit" )
}

run_pre_push() {
  local repo="$1" stdin="$2"
  ( cd "$repo" && printf '%s\n' "$stdin" | bash "$HOOKS_DIR/pre-push" origin file:///dev/null )
}

# Manufacture detached-HEAD + rebase-merge state with a given head-name.
# The hook reads .git/rebase-merge/head-name (or rebase-apply variant)
# to identify the branch the rebase started from.
fake_rebase_merge_on() {
  local repo="$1" head_name="$2"
  (
    cd "$repo" || exit 1
    git checkout --quiet --detach HEAD
  )
  local git_dir
  git_dir="$( cd "$repo" && cd "$(git rev-parse --git-dir)" && pwd )"
  mkdir -p "$git_dir/rebase-merge"
  printf '%s\n' "$head_name" >"$git_dir/rebase-merge/head-name"
}

# --- pre-commit -------------------------------------------------------

test_pre_commit_blocks_direct_commit_on_main() {
  make_repo_with_remote
  capture run_pre_commit "$REPO_DIR"
  assert_fails_with "Direct commit to main is not allowed"
}

test_pre_commit_blocks_direct_commit_on_master() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && git checkout --quiet -b master )
  capture run_pre_commit "$REPO_DIR"
  assert_fails_with "Direct commit to master is not allowed"
}

test_pre_commit_blocks_during_rebase_merge_on_main() {
  make_repo_with_remote
  fake_rebase_merge_on "$REPO_DIR" refs/heads/main
  capture run_pre_commit "$REPO_DIR"
  assert_fails_with "Rebase on main detected"
}

test_pre_commit_blocks_during_rebase_merge_on_master() {
  make_repo_with_remote
  fake_rebase_merge_on "$REPO_DIR" refs/heads/master
  capture run_pre_commit "$REPO_DIR"
  assert_fails_with "Rebase on master detected"
}

test_pre_commit_allows_during_rebase_of_feature_branch() {
  make_repo_with_remote
  fake_rebase_merge_on "$REPO_DIR" refs/heads/feature
  capture run_pre_commit "$REPO_DIR"
  assert_ok
}

test_pre_commit_allows_commit_on_feature_branch() {
  make_repo_with_remote
  make_linked_worktree feature
  capture run_pre_commit "$WT_DIR"
  assert_ok
}

# --- pre-push ---------------------------------------------------------

test_pre_push_blocks_push_to_main() {
  make_repo_with_remote
  capture run_pre_push "$REPO_DIR" \
    "refs/heads/feature aaaaaaa refs/heads/main bbbbbbb"
  assert_fails_with "Pushing to main/master is blocked"
}

test_pre_push_blocks_push_to_master() {
  make_repo_with_remote
  capture run_pre_push "$REPO_DIR" \
    "refs/heads/feature aaaaaaa refs/heads/master bbbbbbb"
  assert_fails_with "Pushing to main/master is blocked"
}

test_pre_push_allows_push_to_feature_branch() {
  make_repo_with_remote
  capture run_pre_push "$REPO_DIR" \
    "refs/heads/feature aaaaaaa refs/heads/feature bbbbbbb"
  assert_ok
}

# --- pre-push ticket receipt gate ------------------------------------

# A ticket-branch push: branch <type>/<slug>-<id> -> id 7, matching
# .plans/ticket-7-evidence.md. The SHAs are hardcoded placeholders; the receipt
# check is keyed by the pushed SHA itself, so any SHA works once a mock is
# installed.
TICKET_PUSH="refs/heads/feature/foo-7 aaaaaaa refs/heads/feature/foo-7 bbbbbbb"

test_pre_push_blocks_ticket_branch_without_receipt() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" "$(head_push_line feature/foo-7)"
  assert_fails_with "ticket receipt gate"
}

# `git push origin <branch>` from the main checkout must see evidence that lives
# only in that branch's linked worktree, the same as a push from the worktree.
test_pre_push_blocks_when_evidence_is_only_in_a_linked_worktree() {
  make_repo_with_remote
  make_linked_worktree feature/foo-7
  seed_ticket_evidence "$WT_DIR" 7
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" "$TICKET_PUSH"
  assert_fails_with "ticket receipt gate"
}

test_pre_push_blocks_when_skillbin_missing_and_evidence_is_in_a_linked_worktree() {
  make_repo_with_remote
  make_linked_worktree feature/foo-7
  seed_ticket_evidence "$WT_DIR" 7
  capture run_pre_push "$REPO_DIR" "$TICKET_PUSH"
  assert_fails_with "skillbin is required"
}

# The receipt lookup must run from the checkout that holds the evidence, because
# the helper judges that checkout's state.
test_pre_push_checks_receipt_from_the_worktree_holding_the_evidence() {
  make_repo_with_remote
  make_linked_worktree feature/foo-7
  seed_ticket_evidence "$WT_DIR" 7
  local expected
  expected="$(cd "$WT_DIR" && pwd -P)"
  cat >"$MOCK_BIN/skillbin" <<EOF
#!/usr/bin/env bash
[ "\$(pwd -P)" = "$expected" ]
EOF
  chmod +x "$MOCK_BIN/skillbin"
  capture run_pre_push "$REPO_DIR" "$TICKET_PUSH"
  assert_ok
}

# Git can export GIT_DIR to hooks, and it would repoint the lookup at the pushing
# checkout despite the cd.
test_pre_push_receipt_lookup_does_not_inherit_git_dir() {
  make_repo_with_remote
  make_linked_worktree feature/foo-7
  seed_ticket_evidence "$WT_DIR" 7
  cat >"$MOCK_BIN/skillbin" <<EOF
#!/usr/bin/env bash
[ -z "\${GIT_DIR:-}" ] && [ -z "\${GIT_WORK_TREE:-}" ]
EOF
  chmod +x "$MOCK_BIN/skillbin"
  capture bash -c 'cd "$1" && printf "%s\n" "$2" | GIT_DIR="$1/.git" GIT_WORK_TREE="$1" bash "$3" origin file:///dev/null' _ \
    "$REPO_DIR" "$TICKET_PUSH" "$HOOKS_DIR/pre-push"
  assert_ok
}

test_pre_push_blocks_when_pushed_from_inside_the_git_dir() {
  make_repo_with_remote
  make_linked_worktree feature/foo-7
  seed_ticket_evidence "$WT_DIR" 7
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR/.git" "$TICKET_PUSH"
  assert_fails_with "ticket receipt gate"
}

test_pre_push_blocks_when_evidence_is_in_a_detached_worktree() {
  make_repo_with_remote
  make_linked_worktree feature/foo-7
  seed_ticket_evidence "$WT_DIR" 7
  git -C "$WT_DIR" checkout --quiet --detach
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" "$TICKET_PUSH"
  assert_fails_with "ticket receipt gate"
}

# A shared `-7` suffix is not enough: another worktree's evidence belongs to the
# branch that worktree has checked out.
test_pre_push_ignores_same_suffix_evidence_on_another_worktrees_branch() {
  make_repo_with_remote
  make_linked_worktree feature/foo-7
  seed_ticket_evidence "$WT_DIR" 7
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" "refs/heads/feature/bar-7 aaaaaaa refs/heads/feature/bar-7 bbbbbbb"
  assert_ok
}

test_pre_push_ignores_other_ticket_evidence_in_a_linked_worktree() {
  make_repo_with_remote
  make_linked_worktree feature/foo-7
  seed_ticket_evidence "$WT_DIR" 7
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" "refs/heads/feature/bar-8 aaaaaaa refs/heads/feature/bar-8 bbbbbbb"
  assert_ok
}

test_pre_push_allows_ticket_branch_with_push_eligible_receipt() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_receipt_check 0
  capture run_pre_push "$REPO_DIR" "$(head_push_line feature/foo-7)"
  assert_ok
}

# The receipt is keyed by the exact pushed SHA (not the checked-out HEAD), so a
# push of a non-HEAD ref is allowed when THAT SHA has a push-eligible receipt.
# Replaces the old pushed-SHA == HEAD guard (#1398), which existed only because
# the durable check evaluated the checkout's surface.
test_pre_push_allows_non_head_sha_with_receipt_for_pushed_sha() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_receipt_check 0
  capture run_pre_push "$REPO_DIR" \
    "refs/heads/feature/foo-7 deadbeefdeadbeefdeadbeefdeadbeefdeadbeef refs/heads/feature/foo-7 bbbbbbb"
  assert_ok
}

test_pre_push_receipt_gate_noop_without_evidence() {
  make_repo_with_remote
  # checker would fail if ever consulted; with no matching evidence file the
  # gate must not invoke it at all.
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" "$TICKET_PUSH"
  assert_ok
}

# P1 regression: a stale/archived evidence file for a DIFFERENT ticket must not
# block a push for the active ticket (gate is scoped to the branch's id).
test_pre_push_ignores_stale_other_ticket_evidence() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 426   # stale, would fail the check
  mock_skillbin_receipt_check 1
  # Active push is for ticket 7, which has no evidence file -> allowed.
  capture run_pre_push "$REPO_DIR" "$TICKET_PUSH"
  assert_ok
}

# P1 regression: `git push -u origin HEAD` (the documented ship path) passes
# local_ref=HEAD; the gate keys on remote_ref (the destination branch), so it
# still applies.
test_pre_push_blocks_ticket_branch_on_head_ref() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" "$(head_push_line foo-7 HEAD)"
  assert_fails_with "ticket receipt gate"
}

# P2 regression: a destination-renamed push (local branch != ticket branch),
# e.g. `git push origin HEAD:refs/heads/foo-7` from a `wip` branch, names the
# ticket branch only on the remote side. The gate must match the destination.
test_pre_push_blocks_destination_renamed_ticket_push() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" "$(head_push_line foo-7 refs/heads/wip)"
  assert_fails_with "ticket receipt gate"
}

# A branch deletion (local sha all-zero) needs no receipt and must not be blocked
# by a missing one.
test_pre_push_allows_ticket_branch_deletion() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" \
    "(delete) 0000000000000000000000000000000000000000 refs/heads/foo-7 cccccccc"
  assert_ok
}

# P2 regression: a hyphenated local-ticket id must match whole — id derived from
# the evidence filename, not by trimming the branch at the last hyphen.
test_pre_push_matches_hyphenated_local_ticket_id() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" "foo-bar"
  mock_skillbin_receipt_check 1
  capture run_pre_push "$REPO_DIR" "$(head_push_line local/slug-foo-bar)"
  assert_fails_with "ticket receipt gate"
}

# P2 regression (suffix collision): a stale `ticket-bar` evidence file must not
# change gating for a `...-foo-bar` push (the longest-matching id is the active
# ticket). Under the SHA-keyed check, gating is identical either way; this pins
# that the extra stale file does not flip an eligible push to blocked.
test_pre_push_ignores_suffix_collision_stale_receipt() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" "foo-bar"   # active ticket
  seed_ticket_evidence "$REPO_DIR" "bar"       # stale
  mock_skillbin_receipt_check 0
  capture run_pre_push "$REPO_DIR" "$(head_push_line local/slug-foo-bar)"
  assert_ok
}

# Fail-closed: any non-zero skillbin exit (e.g. a crash, not just a clean
# "missing") must block the push, never fall through.
test_pre_push_fails_closed_on_skillbin_error() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_receipt_check 2   # error/crash exit, distinct from rc=1
  capture run_pre_push "$REPO_DIR" "$(head_push_line feature/foo-7)"
  assert_fails_with "ticket receipt gate"
}

# Multi-ref push: a receipt-less ticket among several pushed branches blocks.
test_pre_push_blocks_when_one_of_multiple_branches_incomplete() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_receipt_check 1
  # foo-8 has no evidence (skipped before any receipt check); foo-7 is the
  # active ticket and reaches the receipt gate.
  capture run_pre_push "$REPO_DIR" \
    "$(printf 'refs/heads/foo-8 aaa refs/heads/foo-8 bbb\n%s' "$(head_push_line foo-7)")"
  assert_fails_with "ticket receipt gate"
}

test_pre_push_receipt_gate_blocks_matching_ticket_when_skillbin_absent() {
  rm -f "$SANDBOX_BIN/skillbin"
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  capture run_pre_push "$REPO_DIR" "$TICKET_PUSH"
  assert_fails_with "skillbin is required"
}

test_pre_push_receipt_gate_allows_non_ticket_when_skillbin_absent() {
  rm -f "$SANDBOX_BIN/skillbin"
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 426
  capture run_pre_push "$REPO_DIR" "$TICKET_PUSH"
  assert_ok
}

test_pre_push_receipt_gate_bypassed_by_env() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_receipt_check 1
  export SAFE_GIT_SKIP_RECEIPT_GATE=1
  capture run_pre_push "$REPO_DIR" "$TICKET_PUSH"
  unset SAFE_GIT_SKIP_RECEIPT_GATE
  assert_ok
  assert_stderr_contains "ticket receipt gate bypassed"
}

# Wiring: the hook must key the check on the exact pushed SHA and pass
# --for-push, so a receipt that merely exists (e.g. dirty-tree or undispositioned
# findings) cannot authorize a push without the eligibility check.
test_pre_push_passes_pushed_sha_and_for_push_flag() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_capture_receipt_check
  export MOCK_VERIFY_LOG="$TEST_TMP/receipt-argv.log"
  local head
  head="$(git -C "$REPO_DIR" rev-parse HEAD)"
  capture run_pre_push "$REPO_DIR" "$(head_push_line feature/foo-7 HEAD)"
  unset MOCK_VERIFY_LOG
  assert_ok
  grep -F "g-review-receipt find-current" "$TEST_TMP/receipt-argv.log" >/dev/null
  grep -F -- "--head-sha $head" "$TEST_TMP/receipt-argv.log" >/dev/null
  grep -F -- "--for-push" "$TEST_TMP/receipt-argv.log" >/dev/null
}

# Git may invoke an installed hook while the caller is below the worktree root.
# The receipt helper resolves the main-checkout store from cwd, so the hook must
# anchor that call at the repository root rather than inherit the caller's cwd.
test_pre_push_runs_receipt_check_from_repo_root() {
  make_repo_with_remote
  seed_ticket_evidence "$REPO_DIR" 7
  mock_skillbin_capture_receipt_check
  export MOCK_VERIFY_LOG="$TEST_TMP/receipt-cwd.log"
  mkdir -p "$REPO_DIR/nested/caller"
  capture run_pre_push "$REPO_DIR/nested/caller" "$(head_push_line feature/foo-7 HEAD)"
  unset MOCK_VERIFY_LOG
  assert_ok
  grep -Fx "pwd=$REPO_DIR" "$TEST_TMP/receipt-cwd.log" >/dev/null
}
