# Tests for `safe-git worktree start`.

test_worktree_start_creates_worktree_with_description_file() {
  make_repo_with_remote
  cd "$REPO_DIR"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/issue-204" \
    -b issue-204-safe-git-worktree-desc \
    --base origin/main \
    --issue "#204" \
    --title "safe-git: worktree desc" \
    --purpose "Record what this worktree is for."

  assert_ok
  metadata_path="$REPO_DIR/.git/safe-git/worktrees/issue-204-safe-git-worktree-desc.md"
  assert_stdout_contains "worktree $TEST_TMP/issue-204 created"
  assert_stdout_contains "description recorded at $metadata_path"
  assert_file_present "$metadata_path"
  assert_file_absent "$TEST_TMP/issue-204/.safe-git"
  assert_eq "" "$(git -C "$TEST_TMP/issue-204" status --porcelain)" "new worktree status"

  metadata="$(cat "$metadata_path")"
  [[ "$metadata" == *"# Worktree"* ]] || fail_test "metadata missing heading"
  [[ "$metadata" == *"- Branch: issue-204-safe-git-worktree-desc"* ]] || fail_test "metadata missing branch"
  [[ "$metadata" == *"- Base: origin/main"* ]] || fail_test "metadata missing base"
  [[ "$metadata" == *"- Issue: #204"* ]] || fail_test "metadata missing issue"
  [[ "$metadata" == *"- Title: safe-git: worktree desc"* ]] || fail_test "metadata missing title"
  [[ "$metadata" == *"Record what this worktree is for."* ]] || fail_test "metadata missing purpose"
  [[ "$metadata" == *"## Activity Log"* ]] || fail_test "metadata missing activity log"
  [[ "$metadata" == *"Created worktree from origin/main."* ]] || fail_test "metadata missing creation log entry"
}

test_worktree_start_requires_purpose() {
  make_repo_with_remote
  cd "$REPO_DIR"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/no-purpose" \
    -b no-purpose \
    --base origin/main

  assert_fails_with "--purpose is required"
  assert_file_absent "$TEST_TMP/no-purpose"
}

test_worktree_start_keeps_slash_branch_metadata_distinct() {
  make_repo_with_remote
  cd "$REPO_DIR"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/slash-branch" \
    -b users/issue-204 \
    --base origin/main \
    --purpose "Record a slash branch."

  assert_ok
  assert_file_present "$REPO_DIR/.git/safe-git/worktrees/users/issue-204.md"
  assert_file_absent "$REPO_DIR/.git/safe-git/worktrees/users__issue-204.md"
}

test_worktree_adopt_moves_current_branch_to_linked_worktree() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/existing origin/main

  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/existing-work" \
    --purpose "Move already-started branch work out of main." \
    --issue "#207" \
    --title "safe-git: branch to worktree" \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $TEST_TMP/existing-work created for existing branch feature/existing"
  assert_eq "main" "$(git -C "$REPO_DIR" branch --show-current)" "main worktree branch"
  assert_eq "feature/existing" "$(git -C "$TEST_TMP/existing-work" branch --show-current)" "linked worktree branch"

  metadata_path="$REPO_DIR/.git/safe-git/worktrees/feature/existing.md"
  assert_file_present "$metadata_path"
  metadata="$(cat "$metadata_path")"
  [[ "$metadata" == *"- Branch: feature/existing"* ]] || fail_test "metadata missing branch"
  [[ "$metadata" == *"- Base: existing branch"* ]] || fail_test "metadata missing existing-branch base"
  [[ "$metadata" == *"- Issue: #207"* ]] || fail_test "metadata missing issue"
  [[ "$metadata" == *"Move already-started branch work out of main."* ]] || fail_test "metadata missing purpose"
  [[ "$metadata" == *"Moved existing branch from main worktree."* ]] || fail_test "metadata missing move log entry"
}

test_worktree_adopt_refuses_when_branch_is_already_in_linked_worktree() {
  make_repo_with_remote
  make_linked_worktree "feature/already-worktree"
  cd "$WT_DIR"

  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/unused" \
    --purpose "Already isolated." \
    --no-fetch

  assert_fails_with "current checkout is already a linked worktree"
  assert_file_absent "$TEST_TMP/unused"
}

test_worktree_adopt_with_explicit_base() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/explicit-base origin/main

  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/explicit" \
    --base origin/main \
    --purpose "Explicit base." \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $TEST_TMP/explicit created for existing branch feature/explicit-base"
  assert_eq "main" "$(git -C "$REPO_DIR" branch --show-current)" "main worktree branch"
  assert_eq "feature/explicit-base" "$(git -C "$TEST_TMP/explicit" branch --show-current)" "linked worktree branch"
}

test_worktree_adopt_refuses_missing_base() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/missing-base origin/main

  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/missing" \
    --base origin/nonexistent \
    --purpose "Missing base." \
    --no-fetch

  assert_fails_with "base ref origin/nonexistent does not exist"
  assert_file_absent "$TEST_TMP/missing"
}

test_worktree_adopt_with_base_when_origin_head_unset() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/no-head origin/main
  # Unset origin/HEAD so default_branch_name falls back to "main"
  git symbolic-ref --delete refs/remotes/origin/HEAD

  # With explicit --base it should succeed even without origin/HEAD
  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/nohead" \
    --base origin/main \
    --purpose "origin/HEAD unset scenario." \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $TEST_TMP/nohead created for existing branch feature/no-head"
  assert_eq "main" "$(git -C "$REPO_DIR" branch --show-current)" "main worktree branch"
  assert_eq "feature/no-head" "$(git -C "$TEST_TMP/nohead" branch --show-current)" "linked worktree branch"
}

test_worktree_adopt_with_fully_qualified_ref() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/full-qual origin/main

  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/fully-qual" \
    --base refs/remotes/origin/main \
    --purpose "Fully qualified ref." \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $TEST_TMP/fully-qual created for existing branch feature/full-qual"
  assert_eq "main" "$(git -C "$REPO_DIR" branch --show-current)" "main worktree branch"
  assert_eq "feature/full-qual" "$(git -C "$TEST_TMP/fully-qual" branch --show-current)" "linked worktree branch"
}

test_worktree_adopt_with_bare_branch_name_base() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/bare-base origin/main

  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/bare-base" \
    --base main \
    --purpose "Bare branch name as base." \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $TEST_TMP/bare-base created for existing branch feature/bare-base"
  assert_eq "main" "$(git -C "$REPO_DIR" branch --show-current)" "main worktree branch"
  assert_eq "feature/bare-base" "$(git -C "$TEST_TMP/bare-base" branch --show-current)" "linked worktree branch"
}
