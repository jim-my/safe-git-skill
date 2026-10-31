#!/usr/bin/env bash
# Tests for fixture isolation from the caller's repository.

test_missing_fixture_repo_cannot_add_remote_to_caller() {
  make_repo_with_remote
  local caller_repo="$REPO_DIR" before after status=0
  cd "$caller_repo" || return 1
  before="$(git remote -v)"

  REPO_DIR="$TEST_TMP/removed-repo"
  add_second_remote_with_branch leaked feature || status=$?

  after="$(git remote -v)"
  assert_eq "$before" "$after" "caller remotes after missing fixture repo"
  [[ $status -ne 0 ]] || fail_test "fixture helper succeeded without its repo"
}

test_missing_partial_state_repo_does_not_target_root() {
  local mkdir_log="$TEST_TMP/mkdir-args" status=0
  export mkdir_log
  cat >"$MOCK_BIN/mkdir" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$mkdir_log"
exit 88
EOF
  chmod +x "$MOCK_BIN/mkdir"
  hash -r

  fake_partial_state "$TEST_TMP/removed-repo" rebase-merge || status=$?

  [[ $status -ne 0 ]] || fail_test "partial-state helper succeeded without its repo"
  assert_file_absent "$mkdir_log"
}
