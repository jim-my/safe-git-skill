# Tests for `safe-git check start`.

test_check_start_refuses_in_main_worktree() {
  make_repo_with_remote
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check start --no-fetch
  assert_fails_with "main worktree detected"
  assert_stderr_contains "safe-git worktree start"
  assert_stderr_contains "--purpose"
}

test_check_start_passes_in_linked_worktree_off_main_no_divergence() {
  make_repo_with_remote
  push_remote_branch_from_main feature
  checkout_linked_worktree_tracking feature
  cd "$WT_DIR"
  capture "$SAFE_GIT" check start --no-fetch
  assert_ok
  assert_stdout_contains "branch is up to date with origin/feature"
}

test_check_start_refuses_when_behind_upstream() {
  make_repo_with_remote
  push_remote_branch_from_main feature
  checkout_linked_worktree_tracking feature
  advance_remote_branch feature
  ( cd "$WT_DIR" && git fetch --quiet origin )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check start --no-fetch
  assert_fails_with "behind origin/feature"
}

test_check_start_refuses_when_diverged_from_upstream() {
  make_repo_with_remote
  push_remote_branch_from_main feature
  checkout_linked_worktree_tracking feature
  advance_remote_branch feature
  ( cd "$WT_DIR" && git fetch --quiet origin )
  # Local commit on top of the (now-stale) tracking ref creates ahead+behind.
  (
    cd "$WT_DIR"
    echo local >>local.txt
    git add local.txt
    git commit --quiet -m "local advance"
  )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check start --no-fetch
  assert_fails_with "diverged from origin/feature"
}

test_check_start_passes_with_no_upstream_no_same_named_remote_branch() {
  make_repo_with_remote
  make_linked_worktree feature  # --no-track => no upstream
  cd "$WT_DIR"
  capture "$SAFE_GIT" check start --no-fetch
  assert_ok
  assert_stdout_contains "no upstream and no same-named branch"
}

test_check_start_refuses_when_no_upstream_but_origin_has_same_name() {
  make_repo_with_remote
  push_remote_branch_from_main feature
  ( cd "$REPO_DIR" && git fetch --quiet origin )
  make_linked_worktree feature
  cd "$WT_DIR"
  capture "$SAFE_GIT" check start --no-fetch
  assert_fails_with "same-named branch exists on:"
  assert_stderr_contains "origin/feature"
}

test_check_start_refuses_when_no_upstream_but_non_origin_has_same_name() {
  make_repo_with_remote
  add_second_remote_with_branch upstream feature
  make_linked_worktree feature
  cd "$WT_DIR"
  capture "$SAFE_GIT" check start --no-fetch
  assert_fails_with "same-named branch exists on:"
  assert_stderr_contains "upstream/feature"
}

test_check_start_read_only_demotes_worktree_and_freshness() {
  # Main worktree + behind-upstream condition would normally fail.
  # --read-only short-circuits both checks once clean-state passes.
  make_repo_with_remote
  advance_remote_branch main
  ( cd "$REPO_DIR" && git fetch --quiet origin )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check start --read-only --no-fetch
  assert_ok
  assert_stdout_contains "read-only check; worktree isolation and freshness are advisory"
}

test_check_start_read_only_still_blocks_on_clean_state() {
  make_repo_with_remote
  fake_partial_state "$REPO_DIR" rebase-merge
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check start --read-only --no-fetch
  assert_fails_with "rebase in progress"
}

test_check_start_no_fetch_skips_fetch() {
  make_repo_with_remote
  make_linked_worktree feature
  mock_git_fail_on_fetch
  cd "$WT_DIR"
  capture "$SAFE_GIT" check start --no-fetch
  assert_ok
  if [[ "$STDERR" == *"mock-git: fetch is not allowed"* ]]; then
    fail_test "fetch was invoked under --no-fetch"
  fi
}

test_check_start_runs_fetch_without_no_fetch_flag() {
  # Counterpart to the --no-fetch test: confirm the wrapper actually
  # fires when the flag is absent. Without this, the previous test
  # could pass even if --no-fetch had no effect.
  make_repo_with_remote
  make_linked_worktree feature
  mock_git_fail_on_fetch
  cd "$WT_DIR"
  capture "$SAFE_GIT" check start
  assert_fails_with "mock-git: fetch is not allowed"
}

test_check_start_refuses_on_unknown_flag() {
  make_repo_with_remote
  make_linked_worktree feature
  cd "$WT_DIR"
  capture "$SAFE_GIT" check start --bogus
  assert_fails_with "unknown option for check start"
}
