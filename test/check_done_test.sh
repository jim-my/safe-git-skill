# Tests for `safe-git check done`.
#
# Helper: bring REPO_DIR onto a feature branch with one commit. Sets
# FEATURE_SHA = HEAD of that branch (used as the mocked headRefOid).
# Sets via globals (not stdout) because `$(...)` capture would run the
# helper in a subshell and lose WT_DIR / FEATURE_SHA.
prep_feature_in_main_worktree() {
  local branch="${1:-feature}"
  (
    cd "$REPO_DIR"
    git checkout --quiet -b "$branch"
    echo work >work.txt
    git add work.txt
    git commit --quiet -m "feature work"
  )
  FEATURE_SHA="$( cd "$REPO_DIR" && git rev-parse HEAD )"
}

# Helper: same idea, but in a linked worktree at WT_DIR. Sets WT_DIR
# (via make_linked_worktree) and FEATURE_SHA.
prep_feature_in_linked_worktree() {
  local branch="${1:-feature}"
  make_linked_worktree "$branch"
  (
    cd "$WT_DIR"
    echo work >work.txt
    git add work.txt
    git commit --quiet -m "feature work"
  )
  FEATURE_SHA="$( cd "$WT_DIR" && git rev-parse HEAD )"
}

# --- success cases -----------------------------------------------------

test_check_done_main_worktree_merged_success() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  mkdir -p "$REPO_DIR/.git/safe-git/worktrees"
  echo metadata >"$REPO_DIR/.git/safe-git/worktrees/feature.md"
  mock_gh MERGED "$FEATURE_SHA"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_stdout_contains "branch feature deleted"
  # Branch is gone.
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_fails
  # We are back on main.
  capture git -C "$REPO_DIR" branch --show-current
  assert_ok
  assert_eq main "$STDOUT" current_branch
  # Only the main worktree remains.
  local count
  count="$(git -C "$REPO_DIR" worktree list --porcelain | grep -c '^worktree ')"
  assert_eq 1 "$count" worktree_count
  assert_file_absent "$REPO_DIR/.git/safe-git/worktrees/feature.md"
}

test_check_done_linked_worktree_with_spaced_main_path() {
  REPO_DIR="$TEST_TMP/has space/repo"
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mkdir -p "$REPO_DIR/.git/safe-git/worktrees"
  echo metadata >"$REPO_DIR/.git/safe-git/worktrees/feature.md"
  mock_gh MERGED "$FEATURE_SHA"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_stdout_contains "worktree $WT_DIR and branch feature removed"
  # Linked worktree directory is gone.
  assert_file_absent "$WT_DIR"
  # Branch is gone.
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_fails
  assert_file_absent "$REPO_DIR/.git/safe-git/worktrees/feature.md"
}

test_check_done_linked_worktree_fast_forwards_main_after_cleanup() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  advance_remote_branch main merged-pr
  local remote_main
  remote_main="$(git --git-dir="$REMOTE_DIR" rev-parse main)"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  capture git -C "$REPO_DIR" rev-parse HEAD
  assert_ok
  assert_eq "$remote_main" "$STDOUT" main_head_after_cleanup
}

test_check_done_fast_forwards_main_without_upstream() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  advance_remote_branch main merged-pr
  local remote_main
  remote_main="$(git --git-dir="$REMOTE_DIR" rev-parse main)"
  git -C "$REPO_DIR" branch --unset-upstream main
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  capture git -C "$REPO_DIR" rev-parse HEAD
  assert_ok
  assert_eq "$remote_main" "$STDOUT" main_head_without_upstream
}

test_check_done_fast_forwards_main_from_origin_when_upstream_is_non_origin() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  add_second_remote_with_branch backup main
  advance_remote_branch main merged-pr
  local origin_main backup_main
  origin_main="$(git --git-dir="$REMOTE_DIR" rev-parse main)"
  backup_main="$(git --git-dir="$TEST_TMP/backup.git" rev-parse main)"
  git -C "$REPO_DIR" branch --set-upstream-to backup/main main
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  capture git -C "$REPO_DIR" rev-parse HEAD
  assert_ok
  assert_eq "$origin_main" "$STDOUT" main_head_from_origin
  if [[ "$STDOUT" == "$backup_main" ]]; then
    fail_test "main fast-forwarded from backup remote instead of origin"
  fi
}

# --- divergent / dirty refusals ---------------------------------------

test_check_done_refuses_when_local_diverges_from_pr_head() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  # Add a commit AFTER the mocked headRefOid.
  (
    cd "$REPO_DIR"
    echo extra >extra.txt
    git add extra.txt
    git commit --quiet -m "post-merge local"
  )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "differs from PR's merged tip"
  # Branch must still exist.
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_ok
}

test_check_done_refuses_on_unstaged_dirty_tree() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  # Modify a tracked file without staging.
  ( cd "$REPO_DIR" && echo dirty >>work.txt )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "working tree is dirty"
}

test_check_done_refuses_on_staged_dirty_tree() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  ( cd "$REPO_DIR" && echo dirty >>work.txt && git add work.txt )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "working tree is dirty"
}

test_check_done_refuses_on_untracked_dirty_tree() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  ( cd "$REPO_DIR" && echo new >untracked.txt )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "working tree is dirty"
}

# A dirty main checkout is unrelated to the feature worktree being torn
# down: cleanup proceeds, and git's own ff-only overwrite check decides
# whether main can move without touching the local edits.
test_check_done_linked_worktree_cleans_up_and_fast_forwards_dirty_main() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  advance_remote_branch main merged-pr
  local remote_main
  remote_main="$(git --git-dir="$REMOTE_DIR" rev-parse main)"
  ( cd "$REPO_DIR" && echo main-dirty >main-untracked.txt )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_stdout_contains "worktree $WT_DIR and branch feature removed"
  assert_file_absent "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_fails
  capture git -C "$REPO_DIR" rev-parse HEAD
  assert_eq "$remote_main" "$STDOUT" main_head_after_cleanup
  assert_eq main-dirty "$(cat "$REPO_DIR/main-untracked.txt")" main_dirty_file
}

test_check_done_linked_worktree_cleans_up_when_dirty_main_blocks_fast_forward() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  advance_remote_branch main merged-pr
  local main_before
  main_before="$(git -C "$REPO_DIR" rev-parse HEAD)"
  # The incoming commit adds advance.txt; an untracked copy blocks ff-only.
  ( cd "$REPO_DIR" && echo local-edit >advance.txt )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_stderr_contains "did not fast-forward main"
  assert_stderr_contains "git merge --ff-only --no-autostash origin/main"
  assert_file_absent "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_fails
  capture git -C "$REPO_DIR" rev-parse HEAD
  assert_eq "$main_before" "$STDOUT" main_head_unchanged
  assert_eq local-edit "$(cat "$REPO_DIR/advance.txt")" main_dirty_file
}

# merge.autoStash would otherwise stash the edit, fast-forward, and
# re-apply it with conflict markers instead of refusing.
test_check_done_linked_worktree_dirty_main_ignores_merge_autostash() {
  make_repo_with_remote
  (
    cd "$REPO_DIR"
    echo base >advance.txt
    git add advance.txt
    git commit --quiet -m "track advance.txt"
    git push --quiet origin main
  )
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  # The incoming commit edits the tracked file the main checkout dirties.
  advance_remote_branch main merged-pr
  git -C "$REPO_DIR" config merge.autoStash true
  local main_before
  main_before="$(git -C "$REPO_DIR" rev-parse HEAD)"
  ( cd "$REPO_DIR" && echo local-edit >advance.txt && git add advance.txt )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_stderr_contains "did not fast-forward main"
  assert_stderr_contains "git merge --ff-only --no-autostash origin/main"
  assert_file_absent "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse HEAD
  assert_eq "$main_before" "$STDOUT" main_head_unchanged
  assert_eq local-edit "$(cat "$REPO_DIR/advance.txt")" main_dirty_file
  capture git -C "$REPO_DIR" stash list
  assert_eq "" "$STDOUT" no_autostash_entry
}

# status.showUntrackedFiles=no must not make an untracked-only main
# checkout look clean, or the clean path would switch its branch.
test_check_done_dirty_main_detection_ignores_show_untracked_config() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  git -C "$REPO_DIR" config status.showUntrackedFiles no
  (
    cd "$REPO_DIR"
    git checkout --quiet -b side
    echo main-dirty >main-untracked.txt
  )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_stderr_contains "main worktree is dirty and on side"
  assert_stderr_contains "git merge --ff-only --no-autostash origin/main"
  capture git -C "$REPO_DIR" branch --show-current
  assert_eq side "$STDOUT" main_worktree_branch
}

test_check_done_linked_worktree_cleans_up_when_dirty_main_fetch_fails() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  ( cd "$REPO_DIR" && echo main-dirty >main-untracked.txt )
  git -C "$REPO_DIR" remote set-url origin "$TEST_TMP/missing-remote.git"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_stderr_contains "fetching origin/main failed"
  assert_stderr_contains "git merge --ff-only --no-autostash origin/main"
  assert_file_absent "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_fails
}

# Recovery advice printed for a dirty main on another branch must check
# out the default branch first; a bare merge would advance that branch.
test_check_done_dirty_main_on_side_branch_advice_targets_default_when_fetch_fails() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  (
    cd "$REPO_DIR"
    git checkout --quiet -b side
    echo main-dirty >main-untracked.txt
  )
  git -C "$REPO_DIR" remote set-url origin "$TEST_TMP/missing-remote.git"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_stderr_contains "git checkout main && git fetch origin main && git merge --ff-only --no-autostash origin/main"
  assert_stderr_not_contains "fetching origin/main failed"
  capture git -C "$REPO_DIR" branch --show-current
  assert_eq side "$STDOUT" main_worktree_branch
}

test_check_done_refuses_untracked_feature_file_despite_show_untracked_config() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  git -C "$REPO_DIR" config status.showUntrackedFiles no
  ( cd "$WT_DIR" && echo new >untracked.txt )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "working tree is dirty"
  assert_file_present "$WT_DIR/untracked.txt"
}

test_check_done_linked_worktree_leaves_dirty_main_on_its_branch() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  (
    cd "$REPO_DIR"
    git checkout --quiet -b side
    echo main-dirty >main-untracked.txt
  )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_stderr_contains "main worktree is dirty and on side"
  assert_stderr_contains "git merge --ff-only --no-autostash origin/main"
  assert_file_absent "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_fails
  capture git -C "$REPO_DIR" branch --show-current
  assert_eq side "$STDOUT" main_worktree_branch
  assert_eq main-dirty "$(cat "$REPO_DIR/main-untracked.txt")" main_dirty_file
}

# --- gh-mock failure modes --------------------------------------------

test_check_done_refuses_when_gh_not_on_path() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  # No mock_gh — sandbox PATH does not include gh.
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "gh CLI not available"
}

test_check_done_refuses_when_gh_pr_view_fails() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  mock_gh_failing
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "gh pr view failed"
}

test_check_done_refuses_on_empty_head_ref_oid() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  mock_gh MERGED ""
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "empty headRefOid"
}

test_check_done_refuses_when_pr_state_not_merged() {
  # Not in the issue's enumerated list, but the script encodes this and
  # leaving it untested invites silent regression. The state-mismatch
  # message is what surfaces a non-merged PR to the caller.
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  mock_gh OPEN deadbeef
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "is in state 'OPEN', not MERGED"
}

# --- branch / HEAD refusals -------------------------------------------

test_check_done_refuses_on_detached_head() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet --detach HEAD
  capture "$SAFE_GIT" check done
  assert_fails_with "detached HEAD"
}

test_check_done_refuses_on_main() {
  make_repo_with_remote
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "current branch is main"
}

test_check_done_refuses_on_master() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b master
  capture "$SAFE_GIT" check done
  assert_fails_with "current branch is master"
}

# --- partial-HEAD refusals --------------------------------------------

test_check_done_refuses_mid_rebase_merge() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  fake_partial_state "$REPO_DIR" rebase-merge
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "rebase in progress"
}

test_check_done_refuses_mid_rebase_apply() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  fake_partial_state "$REPO_DIR" rebase-apply
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "rebase in progress"
}

test_check_done_refuses_mid_merge() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  fake_partial_state "$REPO_DIR" merge
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "merge in progress"
}

test_check_done_refuses_mid_cherry_pick() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  fake_partial_state "$REPO_DIR" cherry-pick
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "cherry-pick in progress"
}

test_check_done_refuses_mid_revert() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  fake_partial_state "$REPO_DIR" revert
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "revert in progress"
}

test_check_done_refuses_mid_bisect() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  fake_partial_state "$REPO_DIR" bisect
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "bisect in progress"
}

# --- arg parsing ------------------------------------------------------

test_check_done_refuses_on_unknown_flag() {
  make_repo_with_remote
  prep_feature_in_main_worktree feature
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check done --bogus
  assert_fails_with "unknown option for check done"
}

# --- linked-worktree teardown failure ---------------------------------

test_check_done_refuses_when_main_worktree_is_invalid() {
  make_repo_with_remote
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  # Mock `git worktree list --porcelain` to claim the main worktree
  # lives at /no/such/path; resolution must fail and teardown must abort
  # before calling worktree remove or branch -D.
  mock_git_worktree_list_bogus /no/such/main/worktree
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "could not resolve main worktree"
  # WT_DIR still on disk, branch still present.
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_ok
}

test_check_done_submodule_linked_uses_actual_main_checkout() {
  make_main_worktree_layout submodule
  trace_git_metadata_operations
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  mkdir -p "$COMMON_DIR/safe-git/worktrees"
  echo metadata > "$COMMON_DIR/safe-git/worktrees/feature.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_file_absent "$WT_DIR"
  assert_file_absent "$TEST_TMP/metadata-operations"
  assert_file_present "$REPO_DIR/.git"
  assert_file_present "$COMMON_DIR/config"
  assert_file_absent "$COMMON_DIR/safe-git/worktrees/feature.md"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_fails
  assert_eq main "$(git -C "$REPO_DIR" branch --show-current)" main_branch
}

test_check_done_submodule_per_worktree_config_uses_actual_checkout() {
  make_main_worktree_layout submodule-worktree-config
  trace_git_metadata_operations
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_ok
  assert_file_absent "$WT_DIR"
  assert_file_absent "$TEST_TMP/metadata-operations"
  assert_file_present "$COMMON_DIR/config.worktree"
  assert_eq main "$(git -C "$REPO_DIR" branch --show-current)" main_branch
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/feature
  assert_fails
}

assert_no_main_teardown_preserves_state() {
  prep_feature_in_linked_worktree feature
  mock_gh MERGED "$FEATURE_SHA"
  mkdir -p "$COMMON_DIR/safe-git/worktrees"
  echo metadata > "$COMMON_DIR/safe-git/worktrees/feature.md"
  cp "$COMMON_DIR/config" "$TEST_TMP/config-before"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check done
  assert_fails_with "could not resolve main worktree"
  assert_file_present "$WT_DIR/.git"
  assert_file_present "$COMMON_DIR/safe-git/worktrees/feature.md"
  assert_eq "$FEATURE_SHA" "$(git rev-parse refs/heads/feature)" retained_feature
  capture cmp "$TEST_TMP/config-before" "$COMMON_DIR/config"
  assert_ok
}

test_check_done_bare_linked_refuses_without_main_checkout() {
  make_main_worktree_layout bare
  cd "$REPO_DIR"
  capture "$SAFE_GIT" worktree start "$TEST_TMP/bare-child" -b refused --base main --purpose "bare directory" --no-fetch
  assert_fails_with "not inside a git repository"
  assert_file_absent "$TEST_TMP/bare-child"
  capture git rev-parse --verify --quiet refs/heads/refused
  assert_fails
  assert_no_main_teardown_preserves_state
}

test_check_done_separate_linked_refuses_without_main_checkout() {
  make_main_worktree_layout separate
  assert_no_main_teardown_preserves_state
}
