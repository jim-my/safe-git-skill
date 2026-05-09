# Tests for `safe-git check pr`.

test_check_pr_passes_on_feature_branch_clean_state() {
  make_repo_with_remote
  make_linked_worktree feature
  cd "$WT_DIR"
  capture "$SAFE_GIT" check pr
  assert_ok
  assert_stdout_contains "eligible for PR creation"
}

test_check_pr_refuses_on_main() {
  make_repo_with_remote
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check pr
  assert_fails_with "current branch is main"
  assert_stderr_contains "safe-git worktree start"
  assert_stderr_not_contains "Create a feature branch before writing"
}

test_check_pr_refuses_dirty_main_with_recovery_guidance() {
  make_repo_with_remote
  (
    cd "$REPO_DIR"
    echo dirty >dirty.txt
  )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check pr
  assert_fails_with "current branch is main"
  assert_stderr_contains "work already happened"
  assert_stderr_contains "linked worktree"
  assert_stderr_not_contains "Create a feature branch before writing"
}

test_check_pr_refuses_on_master() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b master
  capture "$SAFE_GIT" check pr
  assert_fails_with "current branch is master"
}

test_check_pr_refuses_on_detached_head() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet --detach HEAD
  capture "$SAFE_GIT" check pr
  assert_fails_with "detached HEAD"
}

test_check_pr_refuses_mid_rebase() {
  make_repo_with_remote
  make_linked_worktree feature
  fake_partial_state "$WT_DIR" rebase-merge
  cd "$WT_DIR"
  capture "$SAFE_GIT" check pr
  assert_fails_with "rebase in progress"
}

test_check_pr_refuses_mid_merge() {
  make_repo_with_remote
  make_linked_worktree feature
  fake_partial_state "$WT_DIR" merge
  cd "$WT_DIR"
  capture "$SAFE_GIT" check pr
  assert_fails_with "merge in progress"
}

test_check_pr_refuses_on_positional_argument() {
  make_repo_with_remote
  make_linked_worktree feature
  cd "$WT_DIR"
  capture "$SAFE_GIT" check pr extra-arg
  assert_fails_with "unknown option for check pr"
}
