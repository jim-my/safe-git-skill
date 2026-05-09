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
    cd "$repo"
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
