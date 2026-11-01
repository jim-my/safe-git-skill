# shellcheck shell=bash
# Tests for `safe-git check plan-done`.
#
# Helper: bring REPO_DIR onto a feature branch with NO commits beyond
# its base (branch points at origin/main). plan-done only tears down a
# branch that sits exactly at its recorded base, so success tests start
# from this state.
prep_plan_branch_in_main_worktree() {
  local branch="${1:-plan-feature}"
  (
    cd "$REPO_DIR"
    git checkout --quiet -b "$branch"
  )
}

# Write worktree metadata with a Base line for <branch> in REPO_DIR.
seed_plan_metadata() {
  local branch="$1" base="${2:-origin/main}" source="${3:-}" issue="${4:-1}" path="${5:-$REPO_DIR}"
  local metadata_path="$REPO_DIR/.git/safe-git/worktrees/$branch.md"
  mkdir -p "$(dirname "$metadata_path")"
  if [[ -n "$source" ]]; then
    printf -- '- Branch: %s\n- Path: %s\n- Base: %s\n- Ticket Source: %s\n- Issue: %s\n' "$branch" "$path" "$base" "$source" "$issue" \
      >"$metadata_path"
  else
    printf -- '- Branch: %s\n- Path: %s\n- Base: %s\n' "$branch" "$path" "$base" \
      >"$metadata_path"
  fi
}

# Seed metadata, the worktree evidence file (with a plan_only Phase 2
# checkpoint), and its source-qualified bundle archive in the main checkout —
# the full state a plan-only stop produces before teardown. <worktree_dir> is
# where the plan-only branch is checked out ($WT_DIR for a linked worktree,
# $REPO_DIR for the main worktree).
seed_full_plan_state() {
  local worktree_dir="$1" branch="${2:-plan-feature}" source="${3:-github}" issue="${4:-1}"
  seed_plan_metadata "$branch" "" "$source" "$issue" "$worktree_dir"
  mkdir -p "$worktree_dir/.plans" "$REPO_DIR/.plans/ticket-$source-$issue/.plans"
  cat >"$worktree_dir/.plans/ticket-$issue-evidence.md" <<EOF
ticket-checkpoint v1
phase: 2 plan
status: plan_only
plan_review: clean
exit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review
EOF
  cp "$worktree_dir/.plans/ticket-$issue-evidence.md" \
    "$REPO_DIR/.plans/ticket-$source-$issue/.plans/ticket-$issue-evidence.md"
}

install_git_failure_mock() {
  local args_pattern="$1" fail_limit="${2:-999}" fail_start="${3:-1}"
  export REAL_GIT="$SANDBOX_BIN/git"
  export FAIL_GIT_ARGS="$args_pattern"
  export FAIL_GIT_LIMIT="$fail_limit"
  export FAIL_GIT_START="$fail_start"
  export FAIL_GIT_COUNT_FILE="$TEST_TMP/git-failure-count"
  cat >"$MOCK_BIN/git" <<'SH'
#!/usr/bin/env bash
set -u
if [[ " $* " == *"$FAIL_GIT_ARGS"* ]]; then
  count=0
  [[ ! -f "$FAIL_GIT_COUNT_FILE" ]] || count="$(cat "$FAIL_GIT_COUNT_FILE")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$FAIL_GIT_COUNT_FILE"
  if [[ "$count" -ge "$FAIL_GIT_START" \
      && "$count" -lt $((FAIL_GIT_START + FAIL_GIT_LIMIT)) ]]; then
    exit 2
  fi
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$MOCK_BIN/git"
}

remove_git_failure_mock() {
  rm -f "$MOCK_BIN/git"
  unset REAL_GIT FAIL_GIT_ARGS FAIL_GIT_LIMIT FAIL_GIT_START FAIL_GIT_COUNT_FILE
}

# --- success cases -----------------------------------------------------

test_check_plan_done_main_worktree_success() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  prep_plan_branch_in_main_worktree plan-feature
  seed_full_plan_state "$REPO_DIR"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only branch plan-feature deleted"
  # Branch is gone.
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
  # We are back on main.
  capture git -C "$REPO_DIR" branch --show-current
  assert_ok
  assert_eq main "$STDOUT" current_branch
  assert_file_absent "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
}

test_check_plan_done_linked_worktree_success() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only worktree $WT_DIR and branch plan-feature removed"
  # Linked worktree directory is gone.
  assert_file_absent "$WT_DIR"
  # Branch is gone.
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
  assert_file_absent "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
}

test_check_plan_done_resume_removes_partial_linked_teardown() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  git -C "$REPO_DIR" worktree remove "$WT_DIR"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_ok
  assert_stdout_contains "plan-only teardown for plan-feature reconciled"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
  assert_file_absent "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
}

test_check_plan_done_resume_refuses_symlinked_primary_after_partial_teardown() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  git -C "$REPO_DIR" worktree remove "$WT_DIR"
  local archive="$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  mv "$archive" "$REPO_DIR/evidence-backing"
  ln -s "$REPO_DIR/evidence-backing" "$archive"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "archived plan evidence"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
  assert_file_present "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
}

test_check_plan_done_resume_refuses_symlinked_sibling_after_partial_teardown() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  git -C "$REPO_DIR" worktree remove "$WT_DIR"
  printf 'review\n' >"$REPO_DIR/review-backing"
  ln -s "$REPO_DIR/review-backing" \
    "$REPO_DIR/.plans/ticket-github-1/.plans/review.log"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "archived plan tree contains a non-regular entry"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
  assert_file_present "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
}

test_check_plan_done_resume_refuses_symlinked_archive_bundle_after_partial_teardown() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  git -C "$REPO_DIR" worktree remove "$WT_DIR"
  mv "$REPO_DIR/.plans/ticket-github-1" "$REPO_DIR/archive-backing"
  ln -s "$REPO_DIR/archive-backing" "$REPO_DIR/.plans/ticket-github-1"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "archived plan tree contains a non-regular entry"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
  assert_file_present "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
}

test_check_plan_done_resume_refuses_symlinked_metadata_file() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  printf 'unmerged\n' >"$WT_DIR/unmerged.txt"
  git -C "$WT_DIR" add unmerged.txt
  git -C "$WT_DIR" commit --quiet -m unmerged
  local forged_base metadata_path
  forged_base="$(git -C "$WT_DIR" rev-parse HEAD)"
  metadata_path="$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
  rm "$metadata_path"
  printf -- '- Branch: plan-feature\n- Path: %s\n- Base: %s\n- Ticket Source: github\n- Issue: 1\n' \
    "$WT_DIR" "$forged_base" >"$REPO_DIR/forged-metadata"
  ln -s "$REPO_DIR/forged-metadata" "$metadata_path"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "metadata authority contains a non-regular entry"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_refuses_symlinked_metadata_parent() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  local branch=bug/plan-feature
  WT_DIR="$TEST_TMP/wt-bug-plan-feature"
  git -C "$REPO_DIR" worktree add --quiet --no-track -b "$branch" "$WT_DIR" origin/main
  seed_full_plan_state "$WT_DIR" "$branch"
  printf 'unmerged\n' >"$WT_DIR/unmerged.txt"
  git -C "$WT_DIR" add unmerged.txt
  git -C "$WT_DIR" commit --quiet -m unmerged
  local forged_base metadata_dir
  forged_base="$(git -C "$WT_DIR" rev-parse HEAD)"
  metadata_dir="$REPO_DIR/.git/safe-git/worktrees/bug"
  rm -f "$metadata_dir/plan-feature.md"
  rm -d "$metadata_dir"
  mkdir "$REPO_DIR/forged-metadata-parent"
  printf -- '- Branch: %s\n- Path: %s\n- Base: %s\n- Ticket Source: github\n- Issue: 1\n' \
    "$branch" "$WT_DIR" "$forged_base" \
    >"$REPO_DIR/forged-metadata-parent/plan-feature.md"
  ln -s "$REPO_DIR/forged-metadata-parent" "$metadata_dir"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch "$branch"
  assert_fails_with "metadata authority contains a non-regular entry"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$branch"
  assert_ok
}

test_check_plan_done_resume_refuses_symlinked_metadata_authority_parent() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  printf 'unmerged\n' >"$WT_DIR/unmerged.txt"
  git -C "$WT_DIR" add unmerged.txt
  git -C "$WT_DIR" commit --quiet -m unmerged
  mv "$REPO_DIR/.git/safe-git" "$REPO_DIR/metadata-backing"
  ln -s "$REPO_DIR/metadata-backing" "$REPO_DIR/.git/safe-git"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "metadata authority parent"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_refuses_status_probe_failure() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  install_git_failure_mock ' status --porcelain '
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "could not inspect worktree"
  remove_git_failure_mock
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_refuses_operation_state_probe_failure() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  install_git_failure_mock ' rev-parse --git-dir '
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "could not resolve Git operation state"
  remove_git_failure_mock
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_refuses_operational_branch_probe_failure() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  printf 'unmerged\n' >"$WT_DIR/unmerged.txt"
  git -C "$WT_DIR" add unmerged.txt
  git -C "$WT_DIR" commit --quiet -m unmerged
  install_git_failure_mock ' show-ref --verify --quiet refs/heads/plan-feature ' 1
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "could not determine whether branch plan-feature exists"
  remove_git_failure_mock
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_refuses_branch_sha_probe_failure() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  install_git_failure_mock ' rev-parse --verify refs/heads/plan-feature^{commit} '
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "could not resolve branch plan-feature"
  remove_git_failure_mock
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_malformed_checkpoint_authority() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  local exit_line='exit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review'
  local malformed
  local -a malformed_records=(
    $'ticket-checkpoint v1\nplan_review: clean\nphase: 2 plan\nstatus: plan_only\n'"$exit_line"$'\n'
    $'ticket-checkpoint v1\nphase: 2 forged\nstatus: plan_only forged\nplan_review: clean forged\n'"$exit_line"$'\n'
    $'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\n'
    $'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nstatus: plan_only\nplan_review: clean\n'"$exit_line"$'\n'
  )
  for malformed in "${malformed_records[@]}"; do
    printf '%s' "$malformed" >"$WT_DIR/.plans/ticket-1-evidence.md"
    cp "$WT_DIR/.plans/ticket-1-evidence.md" \
      "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
    cd "$WT_DIR"
    capture "$SAFE_GIT" check plan-done
    assert_fails_with "Phase 2 status is invalid"
    assert_file_present "$WT_DIR"
    capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
    assert_ok
  done
}

test_check_plan_done_resume_refuses_malformed_checkpoint_authority() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  git -C "$REPO_DIR" worktree remove "$WT_DIR"
  local archive="$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$archive"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "not a reviewed plan-only stop"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
  assert_file_present "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
}

test_check_plan_done_refuses_traversal_ticket_metadata() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  sed -i 's/^- Issue: .*/- Issue: x\/..\/..\/victim/' \
    "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "invalid ticket id or source"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_refuses_invalid_persisted_ticket_identity() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  sed -i 's/^- Ticket Source: .*/- Ticket Source: ..\/outside/' \
    "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "no valid ticket source"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_late_metadata_root_failure_never_deletes_outside_file() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  local test_tmp_name branch
  test_tmp_name="$(basename "$TEST_TMP")"
  branch="tmp/$test_tmp_name/outside"
  WT_DIR="$TEST_TMP/wt-late-metadata"
  git -C "$REPO_DIR" worktree add --quiet --no-track -b "$branch" "$WT_DIR" origin/main
  seed_full_plan_state "$WT_DIR" "$branch"
  local outside_file="$TEST_TMP/outside.md"
  printf 'must survive\n' >"$outside_file"
  install_git_failure_mock ' rev-parse --git-common-dir ' 1 8
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "could not remove worktree metadata"
  remove_git_failure_mock
  assert_file_present "$outside_file"
}

test_check_plan_done_resume_removes_intact_spaced_linked_worktree() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  WT_DIR="$TEST_TMP/wt with space"
  git -C "$REPO_DIR" worktree add --quiet --no-track -b plan-feature "$WT_DIR" origin/main
  seed_full_plan_state "$WT_DIR"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_ok
  assert_stdout_contains "plan-only teardown for plan-feature reconciled"
  assert_file_absent "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
}

test_check_plan_done_resume_cancellation_terminates_children_and_cleans_compare_dir() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"

  local python3_path ps_path rm_path pid_file compare_dir_file safe_git_pid rc i
  python3_path="$(PATH="$REAL_PATH" command -v python3)"
  ps_path="$(PATH="$REAL_PATH" command -v ps)"
  rm_path="$(PATH="$REAL_PATH" command -v rm)"
  [[ -x "$python3_path" ]] || fail_test "python3 is required for isolated cancellation fixture"
  [[ -x "$ps_path" ]] || fail_test "ps is required for cancellation liveness checks"
  [[ -x "$rm_path" ]] || fail_test "rm is required for isolated cancellation fixture"
  pid_file="$TEST_TMP/tar-pids"
  compare_dir_file="$TEST_TMP/compare-dir"
  export SAFE_GIT_TEST_TAR_PIDS="$pid_file"
  export SAFE_GIT_TEST_COMPARE_DIR="$compare_dir_file"
  export SAFE_GIT_TEST_REAL_RM="$rm_path"
  cat >"$MOCK_BIN/tar" <<'EOF'
#!/usr/bin/env bash
archive=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -cf && $# -ge 2 ]]; then
    archive="$2"
    break
  fi
  shift
done
[[ -n "$archive" ]] || exit 91
dirname "$archive" >"$SAFE_GIT_TEST_COMPARE_DIR"
sleep 300 &
sleep_pid=$!
printf '%s\n%s\n' "$$" "$sleep_pid" >"$SAFE_GIT_TEST_TAR_PIDS"
wait "$sleep_pid"
EOF
  chmod +x "$MOCK_BIN/tar"
  cat >"$MOCK_BIN/rm" <<'EOF'
#!/usr/bin/env bash
case "${*: -1}" in
  *safe-git-plan-compare.*) sleep 0.5 ;;
esac
exec "$SAFE_GIT_TEST_REAL_RM" "$@"
EOF
  chmod +x "$MOCK_BIN/rm"

  cd "$REPO_DIR"
  TMPDIR="$TEST_TMP" "$python3_path" -c 'import os, sys; os.setsid(); os.execve(sys.argv[1], sys.argv[1:], os.environ)' \
    "$SAFE_GIT" check plan-done --resume-branch plan-feature \
    >"$TEST_TMP/safe-git.out" 2>"$TEST_TMP/safe-git.err" &
  safe_git_pid=$!
  for ((i = 0; i < 100; i++)); do
    [[ -s "$pid_file" && -s "$compare_dir_file" ]] && break
    sleep 0.05
  done
  if [[ ! -s "$pid_file" || ! -s "$compare_dir_file" ]]; then
    kill -TERM -- "-$safe_git_pid" 2>/dev/null || true
    wait "$safe_git_pid" 2>/dev/null || true
    fail_test "cancellation fixture did not reach the production tar child"
  fi

  kill -TERM "$safe_git_pid"
  wait "$safe_git_pid" 2>/dev/null
  rc=$?
  assert_eq 143 "$rc" cancelled_safe_git_exit_code

  local child_pid child_stat
  while IFS= read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    for ((i = 0; i < 100; i++)); do
      child_stat="$($ps_path -o stat= -p "$child_pid" 2>/dev/null | awk '{print $1}')"
      case "$child_stat" in
        "" | Z*) break ;;
      esac
      sleep 0.05
    done
    case "$child_stat" in
      "" | Z*) ;;
      *)
        kill -TERM -- "-$safe_git_pid" 2>/dev/null || true
        sleep 0.1
        kill -KILL -- "-$safe_git_pid" 2>/dev/null || true
        fail_test "safe-git cancellation left child $child_pid live (stat=$child_stat)"
        ;;
    esac
  done <"$pid_file"
  assert_file_absent "$(cat "$compare_dir_file")"
}

test_check_plan_done_usage_documents_resume_option() {
  capture "$SAFE_GIT"
  assert_fails
  assert_stdout_contains "safe-git check plan-done [--resume-branch <branch> --ticket-source <github|local> --ticket-id <id>]"
  assert_stdout_contains "--resume-branch <branch>"
  assert_stdout_contains "--ticket-source <source>"
  assert_stdout_contains "--ticket-id <id>"
}

test_check_plan_done_resume_rejects_ref_like_branch_forms() {
  make_repo_with_remote
  git -C "$REPO_DIR" branch refs/heads/plan-feature origin/main
  git -C "$REPO_DIR" branch heads/plan-feature origin/main
  git -C "$REPO_DIR" checkout -qb previous-branch origin/main
  git -C "$REPO_DIR" checkout -q main
  cd "$REPO_DIR"
  local branch
  for branch in refs/heads/plan-feature heads/plan-feature; do
    capture "$SAFE_GIT" check plan-done --resume-branch "$branch"
    assert_fails_with "invalid --resume-branch value"
    capture git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$branch"
    assert_ok
  done
  capture "$SAFE_GIT" check plan-done --resume-branch '@{-1}'
  assert_fails_with "invalid --resume-branch value"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/previous-branch
  assert_ok
}

test_check_plan_done_resume_accepts_already_complete_teardown() {
  make_repo_with_remote
  mkdir -p "$REPO_DIR/.plans/ticket-github-1/.plans"
  cat >"$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md" <<'EOF'
ticket-checkpoint v1
phase: 2 plan
status: plan_only
plan_review: clean
exit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review
EOF
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature \
    --ticket-source github --ticket-id 1
  assert_ok
  assert_stdout_contains "plan-only teardown for plan-feature was already complete"
}

test_check_plan_done_resume_refuses_already_complete_without_archive() {
  make_repo_with_remote
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature \
    --ticket-source github --ticket-id 1
  assert_fails_with "main plan archive root"
}

test_check_plan_done_resume_refuses_already_complete_without_ticket_identity() {
  make_repo_with_remote
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "completed resume requires --ticket-source and --ticket-id"
}

test_check_plan_done_resume_refuses_dirty_intact_worktree() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  printf 'dirty\n' >"$WT_DIR/untracked.txt"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "is dirty. Commit, push, or stash before teardown."
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_refuses_in_progress_operation() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  fake_partial_state "$WT_DIR" cherry-pick
  assert_eq "" "$(git -C "$WT_DIR" status --porcelain)" clean_status_precondition
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "cherry-pick in progress"
  assert_file_present "$WT_DIR"
  assert_file_present "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_refuses_unarchived_ignored_evidence() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  printf 'newer evidence\n' >>"$WT_DIR/.plans/ticket-1-evidence.md"
  assert_eq "" "$(git -C "$WT_DIR" status --porcelain)" ignored_evidence_precondition
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "surviving worktree .plans differs from archive"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_refuses_unarchived_ignored_sibling() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  printf 'new log\n' >"$WT_DIR/.plans/review.log"
  assert_eq "" "$(git -C "$WT_DIR" status --porcelain)" ignored_log_precondition
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "surviving worktree .plans differs from archive"
  assert_file_present "$WT_DIR/.plans/review.log"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_resume_finishes_main_worktree_teardown() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  prep_plan_branch_in_main_worktree plan-feature
  seed_full_plan_state "$REPO_DIR"
  mkdir -p "$REPO_DIR/.plans/.plan-only-cleanup-state-github-1"
  printf 'started\n' >"$REPO_DIR/.plans/.plan-only-cleanup-state-github-1/teardown"
  git -C "$REPO_DIR" checkout --quiet main
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_ok
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
}

test_check_plan_done_resume_refuses_dirty_main_ticket_worktree() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  prep_plan_branch_in_main_worktree plan-feature
  seed_full_plan_state "$REPO_DIR"
  printf 'dirty\n' >"$REPO_DIR/untracked.txt"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --resume-branch plan-feature
  assert_fails_with "is dirty. Commit, push, or stash before teardown."
  capture git -C "$REPO_DIR" branch --show-current
  assert_ok
  assert_eq plan-feature "$STDOUT" current_branch_after_dirty_resume
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_linked_worktree_leaves_main_untouched() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  # A dirty main checkout must NOT block plan-only cleanup: nothing was
  # merged, so plan-done never touches the default branch. (check_done
  # would refuse here because it fast-forwards main.)
  ( cd "$REPO_DIR" && echo main-dirty >main-untracked.txt )
  local main_head
  main_head="$(cd "$REPO_DIR" && git rev-parse HEAD)"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only worktree $WT_DIR and branch plan-feature removed"
  capture git -C "$REPO_DIR" rev-parse HEAD
  assert_ok
  assert_eq "$main_head" "$STDOUT" main_head_untouched
}

# --- dirty refusals ----------------------------------------------------

test_check_plan_done_refuses_on_unstaged_dirty_tree() {
  make_repo_with_remote
  prep_plan_branch_in_main_worktree plan-feature
  seed_plan_metadata plan-feature
  ( cd "$REPO_DIR" && echo dirty >>README.md )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "working tree is dirty"
  # Branch must still exist.
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_on_staged_dirty_tree() {
  make_repo_with_remote
  prep_plan_branch_in_main_worktree plan-feature
  seed_plan_metadata plan-feature
  ( cd "$REPO_DIR" && echo dirty >>README.md && git add README.md )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "working tree is dirty"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_on_untracked_dirty_tree() {
  make_repo_with_remote
  prep_plan_branch_in_main_worktree plan-feature
  seed_plan_metadata plan-feature
  ( cd "$REPO_DIR" && echo new >untracked.txt )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "working tree is dirty"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_linked_worktree_refuses_dirty_tree() {
  # The linked path must not drop check_worktree_clean just because the
  # main-worktree dirty gate is absent — a dirty linked worktree would
  # otherwise be torn down by `git worktree remove`.
  make_repo_with_remote
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature
  ( cd "$WT_DIR" && echo dirty >>README.md )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "working tree is dirty"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

# --- commits-beyond-base refusal ---------------------------------------

test_check_plan_done_refuses_commits_beyond_base() {
  make_repo_with_remote
  prep_plan_branch_in_main_worktree plan-feature
  seed_plan_metadata plan-feature
  (
    cd "$REPO_DIR"
    echo work >work.txt
    git add work.txt
    git commit --quiet -m "plan work"
  )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "differs from recorded base"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
  assert_file_present "$REPO_DIR/.git/safe-git/worktrees/plan-feature.md"
}

test_check_plan_done_refuses_reset_behind_base() {
  # A two-dot rev-list count only proves HEAD has no commits beyond base;
  # a branch reset behind its base (git reset --hard <base>^) counts 0
  # yet has drifted. Exact SHA equality must refuse it.
  make_repo_with_remote
  (
    cd "$REPO_DIR"
    echo second >second.txt
    git add second.txt
    git commit --quiet -m "second"
  )
  prep_plan_branch_in_main_worktree plan-feature
  seed_plan_metadata plan-feature
  local base_sha
  base_sha="$(cd "$REPO_DIR" && git rev-parse origin/main)"
  (
    cd "$REPO_DIR"
    git reset --quiet --hard "$base_sha~1"
  )
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "differs from recorded base"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_commits_beyond_pinned_base_after_head_base() {
  # worktree start --base HEAD records the resolved commit SHA, not the
  # literal HEAD — otherwise plan-done's rev-list <base>..HEAD would be
  # HEAD..HEAD (0) at cleanup time and delete commits made on the branch.
  make_repo_with_remote
  cd "$REPO_DIR"
  capture "$SAFE_GIT" worktree start "$TEST_TMP/wt-head-base" \
    -b plan-feature --base HEAD --purpose "plan-only with HEAD base"
  assert_ok
  WT_DIR="$TEST_TMP/wt-head-base"
  (
    cd "$WT_DIR"
    echo work >work.txt
    git add work.txt
    git commit --quiet -m "plan work"
  )
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "differs from recorded base"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

# --- branch / HEAD refusals -------------------------------------------

test_check_plan_done_refuses_on_main() {
  make_repo_with_remote
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "current branch is main"
}

test_check_plan_done_refuses_on_detached_head() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet --detach HEAD
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "detached HEAD"
}

# --- metadata refusals -------------------------------------------------

test_check_plan_done_refuses_unarchived_evidence() {
  # .plans/ is gitignored, so check_worktree_clean never sees a ticket
  # evidence file and git worktree remove would delete it. plan-done must
  # refuse when the worktree holds unarchived plan evidence.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github
  mkdir -p "$WT_DIR/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "no byte-identical archive"
  assert_file_present "$WT_DIR"
  assert_file_present "$WT_DIR/.plans/ticket-1-evidence.md"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_archived_evidence_allows_teardown() {
  # The ticket flow archives the .plans/ tree to the source-qualified bundle
  # before teardown; the byte-identical archived evidence must not block.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only worktree $WT_DIR and branch plan-feature removed"
  assert_file_present "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
}

test_check_plan_done_refuses_symlinked_evidence() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  local backing="$WT_DIR/.plans/evidence-backing"
  mv "$WT_DIR/.plans/ticket-1-evidence.md" "$backing"
  rm "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  ln -s "$backing" "$WT_DIR/.plans/ticket-1-evidence.md"
  ln -s "$backing" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "is not a regular non-symlink file"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_symlinked_main_archive_root() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  mv "$REPO_DIR/.plans" "$REPO_DIR/archive-root-backing"
  ln -s "$REPO_DIR/archive-root-backing" "$REPO_DIR/.plans"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "has no byte-identical archive"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_unarchived_ignored_sibling_directly() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  printf 'not archived\n' >"$WT_DIR/.plans/review.log"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "worktree .plans differs from archive"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_symlinked_sibling_artifact() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  local backing="$WT_DIR/.plans/review-backing"
  printf 'review\n' >"$backing"
  ln -s "$backing" "$WT_DIR/.plans/review.log"
  ln -s "$backing" "$REPO_DIR/.plans/ticket-github-1/.plans/review.log"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "worktree .plans differs from archive"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_bundle_shaped_symlink_marker() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_full_plan_state "$WT_DIR"
  local sibling="$WT_DIR/.plans/ticket-github-2"
  mkdir -p "$sibling/.plans"
  printf 'only copy\n' >"$sibling/valuable.log"
  ln -s "$WT_DIR/.plans/ticket-1-evidence.md" \
    "$sibling/.plans/ticket-2-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "worktree .plans differs from archive"
  assert_file_present "$WT_DIR"
  assert_file_present "$sibling/valuable.log"
  capture git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_stale_archive() {
  # The archive must be byte-identical to the current evidence; a stale
  # bundle must refuse teardown.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\ncurrent\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  printf 'stale\n' >"$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "no byte-identical archive"
  assert_file_present "$WT_DIR"
  assert_file_present "$WT_DIR/.plans/ticket-1-evidence.md"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_wrong_source_archive() {
  # A wildcard over the source segment would accept the opposite source's
  # bundle when a local and GitHub ticket share an id with byte-identical
  # evidence. The guard must bind to this ticket's recorded source.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-local-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-local-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "no byte-identical archive"
  assert_file_present "$WT_DIR"
  assert_file_present "$WT_DIR/.plans/ticket-1-evidence.md"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_main_worktree_archived_evidence_allows_teardown() {
  # When the plan-only branch is checked out in the MAIN worktree, the bundle
  # archive sits in the same .plans/ as the evidence. The guard validates only
  # the metadata-bound evidence and its exact bundle path.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  prep_plan_branch_in_main_worktree plan-feature
  seed_plan_metadata plan-feature "" github
  mkdir -p "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$REPO_DIR/.plans/ticket-1-evidence.md"
  cp "$REPO_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only branch plan-feature deleted"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
}

test_check_plan_done_kebab_local_ticket_evidence_not_skipped() {
  # A kebab-case local ticket id (e.g. local:fix-login) yields an unqualified
  # evidence name with multiple hyphens (ticket-fix-login-evidence.md). The
  # guard validates only the metadata-bound evidence and its bundle archive.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" local fix-login
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-local-fix-login/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-fix-login-evidence.md"
  cp "$WT_DIR/.plans/ticket-fix-login-evidence.md" "$REPO_DIR/.plans/ticket-local-fix-login/.plans/ticket-fix-login-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only worktree $WT_DIR and branch plan-feature removed"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
}

test_check_plan_done_kebab_local_ticket_unarchived_refuses() {
  # Without the bundle archive, the kebab-case local evidence must refuse
  # teardown.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" local fix-login
  mkdir -p "$WT_DIR/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-fix-login-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "no byte-identical archive"
  assert_file_present "$WT_DIR"
  assert_file_present "$WT_DIR/.plans/ticket-fix-login-evidence.md"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_local_id_starting_github_unarchived_refuses() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" local "github-fix"
  mkdir -p "$WT_DIR/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-github-fix-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "no byte-identical archive"
  assert_file_present "$WT_DIR"
  assert_file_present "$WT_DIR/.plans/ticket-github-fix-evidence.md"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_local_id_starting_github_is_real_evidence() {
  # A local ticket id beginning with "github" (local:github-fix) yields
  # unqualified evidence ticket-github-fix-evidence.md. The guard binds to the
  # recorded source, so it requires the local bundle archive.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" local "github-fix"
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-local-github-fix/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-github-fix-evidence.md"
  cp "$WT_DIR/.plans/ticket-github-fix-evidence.md" "$REPO_DIR/.plans/ticket-local-github-fix/.plans/ticket-github-fix-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only worktree $WT_DIR and branch plan-feature removed"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
}

test_check_plan_done_refuses_missing_expected_evidence() {
  # A zero-match scan (invoked before Phase 2 wrote the evidence, or written
  # under the wrong name) must refuse teardown: the plan deliverable is the
  # whole point of a plan-only stop.
  make_repo_with_remote
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 42
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "expected plan evidence"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_non_plan_only_checkpoint() {
  # plan-done must only tear down a genuine plan_only stop. Evidence whose
  # Phase 2 checkpoint is done (a ticket that should proceed to execution)
  # must refuse, even with a byte-identical archive present.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: done\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "not plan_only"
  assert_file_present "$WT_DIR"
  assert_file_present "$WT_DIR/.plans/ticket-1-evidence.md"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_uses_last_phase2_status() {
  # The evidence is append-only: a plan_only stop's render-checkpoint appends
  # after the earlier phase-2 done exit. plan-done must use the LAST phase-2
  # status (plan_only), not the first (done).
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: done\n\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >>"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only worktree $WT_DIR and branch plan-feature removed"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
}

test_check_plan_done_normalizes_prefixed_issue_id() {
  # The documented worktree start form --issue "#204" records the leading #;
  # plan-done must normalize it so the evidence/bundle paths use ticket-204,
  # not ticket-#204.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github "#204"
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-204/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-204-evidence.md"
  cp "$WT_DIR/.plans/ticket-204-evidence.md" "$REPO_DIR/.plans/ticket-github-204/.plans/ticket-204-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only worktree $WT_DIR and branch plan-feature removed"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
}

test_check_plan_done_ignores_prose_phase_lines() {
  # The Phase-2 status parser must read complete ticket-checkpoint v1 records,
  # not arbitrary phase:/status: lines that may appear in plan prose (e.g. a
  # YAML snippet being discussed). Evidence with no real plan_only checkpoint
  # must refuse even if prose mentions the pair.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf '# notes\nphase: 2 and status: plan_only in a YAML snippet\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "not plan_only"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_prose_does_not_override_done_checkpoint() {
  # A genuine Phase-2 done checkpoint followed by ordinary prose containing
  # separate phase: 2 / status: plan_only lines must still refuse: the parser
  # stops at the record boundary (blank line) and never lets prose override
  # the typed stop status.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: done\n\nprose with phase: 2 and status: plan_only lines\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "not plan_only"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_yaml_style_prose_does_not_override() {
  # Even a YAML-style snippet with phase: 2 and status: plan_only on their own
  # lines after a done checkpoint must not override the typed status: the
  # record ends at the first non-field line (blank line).
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: done\n\nphase: 2\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "not plan_only"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_no_blank_yaml_does_not_override() {
  # cmd_render_checkpoint emits no blank separator, so YAML-style phase: 2 /
  # status: plan_only lines immediately after a done checkpoint (no blank
  # line) must still not override the typed status: the status is captured
  # once per block from the phase/status adjacency, and later phase/status
  # lines in the same block are ignored.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: done\nphase: 2\nstatus: plan_only\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "not plan_only"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_missing_plan_deliverable() {
  # A minimal plan_only stub with no plan_review field (plan authoring skipped
  # or evidence overwritten) must refuse teardown even with a byte-identical
  # archive: the guard requires a reviewed plan deliverable, not just the stop
  # token.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "Phase 2 status is invalid"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_prose_plan_review_after_exit_does_not_apply() {
  # cmd_render_checkpoint ends its field sequence with exit:. A plan_only
  # checkpoint that omits plan_review, followed immediately (no blank) by
  # prose containing plan_review: clean, must still refuse — the parser stops
  # reading plan_review at the exit: field boundary.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$WT_DIR/.plans" "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nexit: plan gate done\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "Phase 2 status is invalid"
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_main_worktree_ignores_other_ticket_archives() {
  # When the plan-only branch is checked out in the main worktree, .plans/ may
  # hold bundles for OTHER tickets. The guard validates only THIS ticket's
  # metadata-bound evidence and its exact bundle path.
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  prep_plan_branch_in_main_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$REPO_DIR/.plans/ticket-github-1/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$REPO_DIR/.plans/ticket-1-evidence.md"
  cp "$REPO_DIR/.plans/ticket-1-evidence.md" "$REPO_DIR/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  # Another ticket's bundle must not block this cleanup.
  mkdir -p "$REPO_DIR/.plans/ticket-github-2/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$REPO_DIR/.plans/ticket-github-2/.plans/ticket-2-evidence.md"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_ok
  assert_stdout_contains "plan-only branch plan-feature deleted"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_fails
}

test_check_plan_done_refuses_missing_metadata() {
  make_repo_with_remote
  prep_plan_branch_in_main_worktree plan-feature
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "metadata authority"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

test_check_plan_done_refuses_adopt_literal_base() {
  make_repo_with_remote
  prep_plan_branch_in_main_worktree plan-feature
  # `worktree adopt` records the literal `existing branch` as Base; there
  # is no ref to verify against, so plan-done must refuse.
  seed_plan_metadata plan-feature "existing branch"
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "no usable Base ref"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}

# --- arg parsing -------------------------------------------------------

test_check_plan_done_refuses_on_unknown_flag() {
  make_repo_with_remote
  prep_plan_branch_in_main_worktree plan-feature
  cd "$REPO_DIR"
  capture "$SAFE_GIT" check plan-done --bogus
  assert_fails_with "unknown option for check plan-done"
}

# --- linked-worktree teardown failure ----------------------------------

test_check_plan_done_refuses_when_main_worktree_is_invalid() {
  make_repo_with_remote
  ( cd "$REPO_DIR" && echo "/.plans/" >>.gitignore && git add .gitignore && git commit --quiet -m "ignore plans" && git push --quiet origin main )
  make_linked_worktree plan-feature
  seed_plan_metadata plan-feature "" github 1
  mkdir -p "$WT_DIR/.plans"
  printf 'ticket-checkpoint v1\nphase: 2 plan\nstatus: plan_only\nplan_review: clean\nexit: evidence artifact has goal, verifiable steps, execution contract, and clean plan review\n' >"$WT_DIR/.plans/ticket-1-evidence.md"
  # The evidence bundle must exist for the guard to reach teardown. Point
  # main_worktree_path at a real dir containing the byte-identical bundle
  # but that is NOT a git repository; resolution must refuse it before
  # the archive check or teardown can proceed.
  BOGUS="$TEST_TMP/bogus-main"
  mkdir -p "$BOGUS/.plans/ticket-github-1/.plans"
  cp "$WT_DIR/.plans/ticket-1-evidence.md" "$BOGUS/.plans/ticket-github-1/.plans/ticket-1-evidence.md"
  mock_git_worktree_list_bogus "$BOGUS"
  cd "$WT_DIR"
  capture "$SAFE_GIT" check plan-done
  assert_fails_with "could not resolve main worktree"
  # WT_DIR still on disk, branch still present.
  assert_file_present "$WT_DIR"
  capture git -C "$REPO_DIR" rev-parse --verify --quiet refs/heads/plan-feature
  assert_ok
}
