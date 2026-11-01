# shellcheck shell=bash
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
  # The recorded base is pinned to the immutable commit SHA so cleanup's
  # rev-list range cannot resolve a symbolic base (e.g. HEAD) to the
  # feature branch's own tip.
  main_sha="$(git -C "$REPO_DIR" rev-parse origin/main)"
  [[ "$metadata" == *"- Base: $main_sha"* ]] || fail_test "metadata missing pinned base"
  [[ "$metadata" == *"- Issue: #204"* ]] || fail_test "metadata missing issue"
  work_id="$(sed -n 's/^- Work ID: //p' "$metadata_path")"
  [[ "$work_id" =~ ^[0-9a-f]{32}$ ]] || fail_test "metadata missing valid Work ID"
  cd "$TEST_TMP/issue-204" || return
  capture "$SAFE_GIT" worktree plan-id
  assert_ok
  assert_stdout_contains "g-review-work-id: $work_id"
  cd "$REPO_DIR" || return
  [[ "$metadata" == *"- Title: safe-git: worktree desc"* ]] || fail_test "metadata missing title"
  [[ "$metadata" == *"Record what this worktree is for."* ]] || fail_test "metadata missing purpose"
  [[ "$metadata" == *"## Activity Log"* ]] || fail_test "metadata missing activity log"
  [[ "$metadata" == *"Created worktree from origin/main."* ]] || fail_test "metadata missing creation log entry"
}

test_worktree_plan_id_binds_legacy_metadata_once() {
  make_repo_with_remote
  cd "$REPO_DIR" || return
  capture "$SAFE_GIT" worktree start "$TEST_TMP/legacy-plan" \
    -b feature/legacy-plan --base origin/main --purpose "Test legacy plan binding."
  assert_ok
  metadata_path="$REPO_DIR/.git/safe-git/worktrees/feature/legacy-plan.md"
  sed '/^- Work ID: /d' "$metadata_path" > "$TEST_TMP/legacy-metadata"
  cp "$TEST_TMP/legacy-metadata" "$metadata_path"

  cd "$TEST_TMP/legacy-plan" || return
  capture "$SAFE_GIT" worktree plan-id
  assert_fails_with "no valid Work ID"
  capture "$SAFE_GIT" worktree plan-id --bind
  assert_ok
  first_id="${STDOUT#g-review-work-id: }"
  [[ "$first_id" =~ ^[0-9a-f]{32}$ ]] || fail_test "legacy binding did not mint an ID"
  capture "$SAFE_GIT" worktree plan-id --bind
  assert_ok
  assert_eq "g-review-work-id: $first_id" "$STDOUT" "plan ID is stable"

  sed 's/^- Work ID: /- Work ID: invalid/' "$metadata_path" > "$TEST_TMP/invalid-metadata"
  cp "$TEST_TMP/invalid-metadata" "$metadata_path"
  capture "$SAFE_GIT" worktree plan-id --bind
  assert_fails_with "no valid Work ID"
}

test_worktree_start_reused_branch_gets_new_plan_id() {
  make_repo_with_remote
  cd "$REPO_DIR" || return
  capture "$SAFE_GIT" worktree start "$TEST_TMP/first-work" \
    -b feature/reused-plan --base origin/main --purpose "First incarnation."
  assert_ok
  metadata_path="$REPO_DIR/.git/safe-git/worktrees/feature/reused-plan.md"
  first_id="$(sed -n 's/^- Work ID: //p' "$metadata_path")"
  git worktree remove "$TEST_TMP/first-work" || return
  git branch -D feature/reused-plan >/dev/null || return
  rm "$metadata_path"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/second-work" \
    -b feature/reused-plan --base origin/main --purpose "Second incarnation."
  assert_ok
  second_id="$(sed -n 's/^- Work ID: //p' "$metadata_path")"
  [[ "$second_id" =~ ^[0-9a-f]{32}$ ]] || fail_test "reused branch has no ID"
  [[ "$first_id" != "$second_id" ]] || fail_test "reused branch retained its old plan ID"
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

test_worktree_start_refuses_nested_path_outside_dot_worktrees() {
  make_repo_with_remote
  cd "$REPO_DIR"

  capture "$SAFE_GIT" worktree start "$REPO_DIR/nested-work" \
    -b feature/nested-work \
    --base origin/main \
    --purpose "Nested path should be rejected."

  assert_fails_with ".worktrees/<task>"
  assert_file_absent "$REPO_DIR/nested-work"
}

test_worktree_start_allows_nested_dot_worktrees_path() {
  make_repo_with_remote
  cd "$REPO_DIR"

  capture "$SAFE_GIT" worktree start "$REPO_DIR/.worktrees/allowed-work" \
    -b feature/allowed-work \
    --base origin/main \
    --purpose "Nested .worktrees path should be allowed."

  assert_ok
  assert_stdout_contains "worktree $REPO_DIR/.worktrees/allowed-work created"
  assert_eq "" "$(git -C "$REPO_DIR/.worktrees/allowed-work" status --porcelain)" "new worktree status"
}

test_worktree_start_handles_large_worktree_list_without_pipefail() {
  make_repo_with_remote
  cd "$REPO_DIR"

  local real_git
  real_git="$(readlink "$SANDBOX_BIN/git")"
  cat >"$MOCK_BIN/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "worktree" && "\$2" == "list" && "\$3" == "--porcelain" ]]; then
  sep='\\n'
  [[ "\${4:-}" == -z ]] && sep='\\0'
  printf "worktree %s\${sep}HEAD 0000000000000000000000000000000000000000\${sep}branch refs/heads/main\${sep}\${sep}" "$REPO_DIR"
  for ((i = 0; i < 2000; i++)); do
    printf "worktree %s/fake-%s\${sep}HEAD 0000000000000000000000000000000000000000\${sep}branch refs/heads/fake-%s\${sep}\${sep}" "$TEST_TMP" "\$i" "\$i"
  done
  exit 0
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$MOCK_BIN/git"

  capture "$SAFE_GIT" worktree start "$REPO_DIR/.worktrees/many-existing" \
    -b feature/many-existing \
    --base origin/main \
    --purpose "Large worktree list should not trip pipefail." \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $REPO_DIR/.worktrees/many-existing created"
}

test_worktree_start_applies_rule_to_resolved_symlink_path() {
  make_repo_with_remote
  cd "$REPO_DIR"
  ln -s "$REPO_DIR" "$TEST_TMP/main-link"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/main-link/nested-via-link" \
    -b feature/nested-via-link \
    --base origin/main \
    --purpose "Symlink into main should be rejected."

  assert_fails_with ".worktrees/<task>"
  assert_file_absent "$REPO_DIR/nested-via-link"
}

test_worktree_start_allows_symlink_path_resolving_outside_main() {
  make_repo_with_remote
  cd "$REPO_DIR"
  mkdir -p "$TEST_TMP/outside-worktrees"
  ln -s "$TEST_TMP/outside-worktrees" "$REPO_DIR/outside-link"

  capture "$SAFE_GIT" worktree start "$REPO_DIR/outside-link/allowed-via-link" \
    -b feature/allowed-via-link \
    --base origin/main \
    --purpose "Symlink out of main should be allowed."

  assert_ok
  assert_stdout_contains "worktree $REPO_DIR/outside-link/allowed-via-link created"
  assert_eq "" "$(git -C "$TEST_TMP/outside-worktrees/allowed-via-link" status --porcelain)" "new worktree status"
  cd "$TEST_TMP/outside-worktrees/allowed-via-link" || return
  capture "$SAFE_GIT" worktree plan-id
  assert_ok
  assert_stdout_contains "g-review-work-id: "
}

test_worktree_start_normalizes_dot_worktrees_path_from_subdirectory() {
  make_repo_with_remote
  mkdir -p "$REPO_DIR/subdir"
  cd "$REPO_DIR/subdir"

  capture "$SAFE_GIT" worktree start .worktrees/subdir-work \
    -b feature/subdir-work \
    --base origin/main \
    --purpose "Canonical .worktrees/<slug> should work from a subdirectory." \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $REPO_DIR/.worktrees/subdir-work created"
  assert_eq "" "$(git -C "$REPO_DIR/.worktrees/subdir-work" status --porcelain)" "new worktree status"
}

test_worktree_adopt_normalizes_dot_worktrees_path_from_subdirectory() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/adopt-subdir origin/main
  mkdir -p "$REPO_DIR/subdir"
  cd "$REPO_DIR/subdir"

  capture "$SAFE_GIT" worktree adopt .worktrees/adopt-subdir \
    --purpose "Canonical .worktrees/<slug> adopt should work from a subdirectory." \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $REPO_DIR/.worktrees/adopt-subdir created for existing branch feature/adopt-subdir"
  assert_eq "main" "$(git -C "$REPO_DIR" branch --show-current)" "main worktree branch"
  assert_eq "feature/adopt-subdir" "$(git -C "$REPO_DIR/.worktrees/adopt-subdir" branch --show-current)" "linked worktree branch"
}

test_worktree_start_refuses_when_called_from_linked_worktree() {
  make_repo_with_remote
  make_linked_worktree "feature/start-from-linked"
  cd "$WT_DIR"

  capture "$SAFE_GIT" worktree start "$WT_DIR/nested-child" \
    -b feature/nested-child \
    --base origin/main \
    --purpose "Starting from a linked worktree should be rejected." \
    --no-fetch

  assert_fails_with "current checkout is already a linked worktree"
  assert_file_absent "$WT_DIR/nested-child"
}

test_worktree_start_allows_submodule_main_checkout() {
  make_repo_with_remote
  cd "$REPO_DIR"

  local real_git
  real_git="$(readlink "$SANDBOX_BIN/git")"
  cat >"$MOCK_BIN/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "rev-parse" && "\$2" == "--show-superproject-working-tree" ]]; then
  printf '%s\n' "$TEST_TMP/superproject"
  exit 0
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$MOCK_BIN/git"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/submodule-main-work" \
    -b feature/submodule-main-work \
    --base origin/main \
    --purpose "Submodule main checkout should be allowed." \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $TEST_TMP/submodule-main-work created"
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

  cd "$TEST_TMP/existing-work" || return
  capture "$SAFE_GIT" worktree plan-id
  assert_ok
  first_id="${STDOUT#g-review-work-id: }"
  [[ "$first_id" =~ ^[0-9a-f]{32}$ ]] || fail_test "adopt did not mint a valid plan ID"

  git -C "$REPO_DIR" worktree remove "$TEST_TMP/existing-work" || return
  git -C "$REPO_DIR" branch -D feature/existing >/dev/null || return
  rm "$metadata_path"
  cd "$REPO_DIR" || return
  git checkout --quiet -b feature/existing origin/main
  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/existing-work-again" \
    --purpose "Adopt reused branch name." --no-fetch
  assert_ok
  cd "$TEST_TMP/existing-work-again" || return
  capture "$SAFE_GIT" worktree plan-id
  assert_ok
  second_id="${STDOUT#g-review-work-id: }"
  [[ "$second_id" =~ ^[0-9a-f]{32}$ ]] || fail_test "second adopt did not mint a valid plan ID"
  [[ "$first_id" != "$second_id" ]] || fail_test "reused adopted branch retained its old plan ID"
}

test_worktree_adopt_refuses_nested_path_outside_dot_worktrees_before_side_effects() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/nested-adopt origin/main

  capture "$SAFE_GIT" worktree adopt "$REPO_DIR/nested-adopt" \
    --purpose "Nested adopt path should be rejected." \
    --no-fetch

  assert_fails_with ".worktrees/<task>"
  assert_file_absent "$REPO_DIR/nested-adopt"
  assert_eq "feature/nested-adopt" "$(git -C "$REPO_DIR" branch --show-current)" "main worktree branch after rejected adopt"
}

test_worktree_start_installs_managed_hooks_into_shared_dir() {
  make_repo_with_remote
  cd "$REPO_DIR"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/hooked-work" \
    -b feature/hooked-work \
    --base origin/main \
    --purpose "Hooks should deploy into the shared hooks dir." \
    --no-fetch

  assert_ok
  # Shared hooks dir (git-common-dir/hooks) covers main + all worktrees.
  assert_file_present "$REPO_DIR/.git/hooks/pre-push"
  assert_file_present "$REPO_DIR/.git/hooks/pre-commit"
  [[ -x "$REPO_DIR/.git/hooks/pre-push" ]] || fail_test "pre-push not executable"
  grep -q "safe-git-managed-hook" "$REPO_DIR/.git/hooks/pre-push" \
    || fail_test "installed pre-push missing marker"
}

test_worktree_adopt_installs_managed_hooks_into_shared_dir() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/adopt-hooked origin/main

  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/adopt-hooked-work" \
    --purpose "Adopt should also deploy the managed hooks." \
    --no-fetch

  assert_ok
  assert_file_present "$REPO_DIR/.git/hooks/pre-push"
  assert_file_present "$REPO_DIR/.git/hooks/pre-commit"
  grep -q "safe-git-managed-hook" "$REPO_DIR/.git/hooks/pre-push" \
    || fail_test "adopt-installed pre-push missing marker"
}

# Any core.hooksPath (the repo redirects hooks) -> skip auto-install with a note;
# only the default layout is auto-installed. Covers the absolute-outside case.
test_worktree_start_skips_install_for_absolute_hookspath() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git config core.hooksPath "$TEST_TMP/custom-hooks"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/hookspath-work" \
    -b feature/hookspath-work \
    --base origin/main \
    --purpose "core.hooksPath set -> skip auto-install." \
    --no-fetch

  assert_ok
  assert_stderr_contains "core.hooksPath is set"
  assert_file_absent "$TEST_TMP/custom-hooks/pre-push"
  assert_file_absent "$REPO_DIR/.git/hooks/pre-push"
}

# Regression: an ABSOLUTE core.hooksPath that points inside the checkout must not
# install there (would dirty the worktree / risk committing the guard hooks).
test_worktree_start_skips_install_for_absolute_hookspath_inside_worktree() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git config core.hooksPath "$TEST_TMP/inside-work/.githooks"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/inside-work" \
    -b feature/inside-work \
    --base origin/main \
    --purpose "Absolute core.hooksPath inside the worktree must not dirty it." \
    --no-fetch

  assert_ok
  assert_stderr_contains "core.hooksPath is set"
  assert_file_absent "$TEST_TMP/inside-work/.githooks/pre-push"
  assert_eq "" "$(git -C "$TEST_TMP/inside-work" status --porcelain)" "worktree clean after skip"
}

test_worktree_start_skips_hooks_for_relative_hookspath() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git config core.hooksPath .githooks

  capture "$SAFE_GIT" worktree start "$TEST_TMP/rel-hookspath-work" \
    -b feature/rel-hookspath-work \
    --base origin/main \
    --purpose "Relative core.hooksPath must not pollute the worktree." \
    --no-fetch

  assert_ok
  assert_stderr_contains "core.hooksPath is set"
  assert_file_absent "$TEST_TMP/rel-hookspath-work/.githooks/pre-push"
  assert_eq "" "$(git -C "$TEST_TMP/rel-hookspath-work" status --porcelain)" "worktree clean after skip"
}

test_worktree_start_upgrades_legacy_safe_git_hook() {
  make_repo_with_remote
  cd "$REPO_DIR"
  mkdir -p "$REPO_DIR/.git/hooks"
  # Pre-marker legacy safe-git pre-push (old README copy): blocks main/master,
  # no marker, no receipt gate. Must be recognized and upgraded, not skipped.
  printf '#!/bin/bash\necho "ERROR: Pushing to main/master is blocked." >&2\nexit 0\n' \
    >"$REPO_DIR/.git/hooks/pre-push"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/legacy-upgrade-work" \
    -b feature/legacy-upgrade-work \
    --base origin/main \
    --purpose "Legacy safe-git hook must upgrade to the marked gate." \
    --no-fetch

  assert_ok
  grep -q "safe-git-managed-hook" "$REPO_DIR/.git/hooks/pre-push" \
    || fail_test "legacy hook not upgraded to marked version"
  grep -q "g-review-receipt find-current" "$REPO_DIR/.git/hooks/pre-push" \
    || fail_test "upgraded hook missing receipt gate"
}

test_worktree_start_skips_install_for_global_hookspath() {
  make_repo_with_remote
  cd "$REPO_DIR"
  # A global (non-local) core.hooksPath governs many repos; installing into it
  # would wire the gates into every repo using it.
  git config --global core.hooksPath "$TEST_TMP/global-hooks"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/global-hookspath-work" \
    -b feature/global-hookspath-work \
    --base origin/main \
    --purpose "Global core.hooksPath must not receive safe-git hooks." \
    --no-fetch

  assert_ok
  assert_stderr_contains "core.hooksPath is set"
  assert_file_absent "$TEST_TMP/global-hooks/pre-push"
  assert_file_absent "$REPO_DIR/.git/hooks/pre-push"
}

test_worktree_start_resolves_self_without_readlink_dash_f() {
  make_repo_with_remote
  cd "$REPO_DIR"
  # Simulate BSD/macOS readlink: no `-f` support. Plain readlink still works.
  local real_readlink
  real_readlink="$(readlink "$SANDBOX_BIN/readlink" 2>/dev/null || command -v readlink)"
  cat >"$MOCK_BIN/readlink" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-f" ]]; then echo "readlink: illegal option -- f" >&2; exit 1; fi
exec "$real_readlink" "\$@"
EOF
  chmod +x "$MOCK_BIN/readlink"
  # Invoke safe-git through an install-style symlink, the normal deploy path.
  ln -s "$SAFE_GIT" "$TEST_TMP/safe-git-link"

  capture "$TEST_TMP/safe-git-link" worktree start "$TEST_TMP/bsd-readlink-work" \
    -b feature/bsd-readlink-work \
    --base origin/main \
    --purpose "Resolve self through a symlink without readlink -f." \
    --no-fetch

  assert_ok
  assert_file_present "$REPO_DIR/.git/hooks/pre-push"
  grep -q "safe-git-managed-hook" "$REPO_DIR/.git/hooks/pre-push" \
    || fail_test "symlink-invoked install missing marker"
}

test_worktree_start_does_not_clobber_foreign_hook() {
  make_repo_with_remote
  cd "$REPO_DIR"
  mkdir -p "$REPO_DIR/.git/hooks"
  printf '#!/bin/bash\n# someone-elses-hook\nexit 0\n' >"$REPO_DIR/.git/hooks/pre-push"

  capture "$SAFE_GIT" worktree start "$TEST_TMP/foreign-hook-work" \
    -b feature/foreign-hook-work \
    --base origin/main \
    --purpose "A pre-existing non-safe-git hook must be left untouched." \
    --no-fetch

  assert_ok
  assert_stderr_contains "existing non-safe-git pre-push hook left untouched"
  grep -q "someone-elses-hook" "$REPO_DIR/.git/hooks/pre-push" \
    || fail_test "foreign pre-push was clobbered"
}

test_worktree_adopt_allows_nested_dot_worktrees_path() {
  make_repo_with_remote
  cd "$REPO_DIR"
  git checkout --quiet -b feature/allowed-adopt origin/main

  capture "$SAFE_GIT" worktree adopt "$REPO_DIR/.worktrees/allowed-adopt" \
    --purpose "Nested .worktrees adopt path should be allowed." \
    --no-fetch

  assert_ok
  assert_stdout_contains "worktree $REPO_DIR/.worktrees/allowed-adopt created for existing branch feature/allowed-adopt"
  assert_eq "main" "$(git -C "$REPO_DIR" branch --show-current)" "main worktree branch"
  assert_eq "feature/allowed-adopt" "$(git -C "$REPO_DIR/.worktrees/allowed-adopt" branch --show-current)" "linked worktree branch"
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

test_worktree_adopt_restores_checkout_when_target_is_occupied() {
  make_repo_with_remote
  cd "$REPO_DIR" || return 1
  git checkout --quiet --no-track -b feature/occupied origin/main
  local feature_sha target="$TEST_TMP/occupied"
  feature_sha="$(git rev-parse HEAD)"
  mkdir "$target"
  echo keep > "$target/keep.txt"
  advance_remote_branch main
  git fetch --quiet origin

  capture "$SAFE_GIT" worktree adopt "$target" --purpose "Occupied target recovery." --no-fetch

  assert_fails
  assert_eq feature/occupied "$(git branch --show-current)" "checkout after failed adoption"
  assert_eq "$feature_sha" "$(git rev-parse HEAD)" "feature tip after failed adoption"
  assert_eq keep "$(cat "$target/keep.txt")" "occupied target contents"
  assert_eq "$(git rev-parse origin/main)" "$(git rev-parse main)" "completed default fast-forward"
  assert_file_absent "$REPO_DIR/.git/safe-git/worktrees/feature/occupied.md"
  assert_stderr_contains "restored checkout to feature/occupied"
}

test_worktree_adopt_restores_checkout_when_default_cannot_fast_forward() {
  make_repo_with_remote
  cd "$REPO_DIR" || return 1
  echo local > local.txt
  git add local.txt
  git commit --quiet -m "local default change"
  local main_sha feature_sha
  main_sha="$(git rev-parse HEAD)"
  git checkout --quiet --no-track -b feature/divergent-default origin/main
  feature_sha="$(git rev-parse HEAD)"
  advance_remote_branch main
  git fetch --quiet origin

  capture "$SAFE_GIT" worktree adopt "$TEST_TMP/adopted" --purpose "Divergent default recovery." --no-fetch

  assert_fails
  assert_eq feature/divergent-default "$(git branch --show-current)" "checkout after failed fast-forward"
  assert_eq "$feature_sha" "$(git rev-parse HEAD)" "feature tip after failed fast-forward"
  assert_eq "$main_sha" "$(git rev-parse main)" "divergent default tip"
  assert_file_absent "$TEST_TMP/adopted"
  assert_stderr_contains "could not fast-forward main"
  assert_stderr_contains "restored checkout to feature/divergent-default"
}

test_worktree_adopt_preserves_edit_when_restoration_would_overwrite_it() {
  make_repo_with_remote
  cd "$REPO_DIR" || return 1
  git checkout --quiet --no-track -b feature/conflicting-edit origin/main
  echo feature > README.md
  git add README.md
  git commit --quiet -m "feature readme"
  local feature_sha target="$TEST_TMP/occupied"
  feature_sha="$(git rev-parse HEAD)"
  mkdir "$target"
  echo keep > "$target/keep.txt"
  # A hook can introduce edits after adoption's initial cleanliness check.
  cat > .git/hooks/post-checkout <<'EOF'
#!/usr/bin/env bash
if [[ "$(git branch --show-current)" == main ]]; then
  echo "edit created after checkout" > README.md
fi
EOF
  chmod +x .git/hooks/post-checkout

  capture "$SAFE_GIT" worktree adopt "$target" --purpose "Preserve conflicting edit." --no-fetch

  assert_fails
  assert_eq "edit created after checkout" "$(cat README.md)" "edit after refused restoration"
  assert_eq main "$(git branch --show-current)" "checkout after conflicting edit"
  assert_eq "$feature_sha" "$(git rev-parse refs/heads/feature/conflicting-edit)" "retained feature branch"
  assert_eq keep "$(cat "$target/keep.txt")" "retained occupied target"
  assert_stderr_contains "could not restore checkout to feature/conflicting-edit"
  assert_stderr_contains "git checkout feature/conflicting-edit"
}

test_worktree_adopt_reports_failed_checkout_restoration() {
  make_repo_with_remote
  cd "$REPO_DIR" || return 1
  git checkout --quiet --no-track -b feature/restore-refused origin/main
  local feature_sha real_git target="$TEST_TMP/occupied"
  feature_sha="$(git rev-parse HEAD)"
  mkdir "$target"
  echo keep > "$target/keep.txt"
  real_git="$(readlink "$SANDBOX_BIN/git")"
  cat > "$MOCK_BIN/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == checkout && "\${2:-}" == feature/restore-refused ]]; then
  echo "simulated checkout refusal" >&2
  exit 77
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$MOCK_BIN/git"

  capture "$SAFE_GIT" worktree adopt "$target" --purpose "Restoration refusal." --no-fetch

  assert_fails_with "could not restore checkout to feature/restore-refused"
  assert_stderr_contains "inspect git status"
  assert_stderr_contains "git checkout feature/restore-refused"
  assert_eq "$feature_sha" "$(git rev-parse refs/heads/feature/restore-refused)" "retained feature branch"
  assert_eq keep "$(cat "$target/keep.txt")" "retained occupied target"
  assert_eq main "$(git branch --show-current)" "checkout after refused restoration"
}

test_worktree_start_records_ticket_source() {
  make_repo_with_remote
  cd "$REPO_DIR"
  capture "$SAFE_GIT" worktree start "$TEST_TMP/src-ticket" \
    -b feature/src --purpose "Record source." \
    --issue 42 --ticket-source github --no-fetch
  assert_ok
  metadata_path="$REPO_DIR/.git/safe-git/worktrees/feature/src.md"
  metadata="$(cat "$metadata_path")"
  [[ "$metadata" == *"- Ticket Source: github"* ]] || fail_test "metadata missing ticket source"
}

test_worktree_start_rejects_invalid_ticket_source() {
  make_repo_with_remote
  cd "$REPO_DIR"
  capture "$SAFE_GIT" worktree start "$TEST_TMP/bad-src" \
    -b feature/bad-src --purpose "Bad source." --ticket-source bogus --no-fetch
  assert_fails_with "--ticket-source must be github or local"
  assert_file_absent "$TEST_TMP/bad-src"
}

test_worktree_start_reroots_separate_git_dir_checkout() {
  make_main_worktree_layout separate
  mkdir -p "$REPO_DIR/nested"
  cd "$REPO_DIR/nested"
  capture "$SAFE_GIT" worktree start .worktrees/task -b feature --base origin/main --purpose "separate checkout" --no-fetch
  assert_ok
  assert_file_present "$REPO_DIR/.worktrees/task/.git"
  assert_file_absent "$REPO_DIR/nested/.worktrees"
  assert_file_absent "$COMMON_DIR/.worktrees"
}

test_worktree_start_refuses_nested_submodule_path() {
  make_main_worktree_layout submodule
  cd "$REPO_DIR"
  capture "$SAFE_GIT" worktree start nested-task -b feature --base origin/main --purpose "protect submodule checkout" --no-fetch
  assert_fails_with "worktree path resolves inside the main checkout"
  assert_file_absent "$REPO_DIR/nested-task"
  assert_file_absent "$COMMON_DIR/safe-git/worktrees/feature.md"
  capture git rev-parse --verify --quiet refs/heads/feature
  assert_fails
}

test_worktree_start_refuses_without_bundled_resolver() {
  make_repo_with_remote
  local partial="$TEST_TMP/partial-package"
  mkdir -p "$partial/bin"
  cp "$SAFE_GIT" "$partial/bin/safe-git"
  cp -R "$SAFE_GIT_ROOT/lib" "$SAFE_GIT_ROOT/hooks" "$partial/"
  cd "$REPO_DIR"
  capture "$partial/bin/safe-git" worktree start .worktrees/task -b feature --base origin/main --purpose "missing resolver" --no-fetch
  assert_fails_with "could not resolve main worktree"
  assert_file_absent "$REPO_DIR/.worktrees/task"
  capture git rev-parse --verify --quiet refs/heads/feature
  assert_fails
}

test_standalone_install_needs_no_skillbin() {
  make_repo_with_remote
  capture bash "$SAFE_GIT_ROOT/install.sh"
  assert_ok
  assert_file_present "$TEST_TMP/codex/skills/safe-git"
  PATH="$HOME/.local/bin:$PATH"
  export PATH
  cd "$REPO_DIR"
  capture safe-git worktree start .worktrees/task -b feature --base origin/main --purpose "standalone install" --no-fetch
  assert_ok
  assert_file_absent "$HOME/.local/bin/skillbin"
  capture "$SAFE_GIT_ROOT/bin/resolve-main-worktree"
  assert_ok
  assert_eq "$REPO_DIR" "$STDOUT" bundled_resolver_path
  assert_file_present "$REPO_DIR/.worktrees/task/.git"
}

test_worktree_start_refuses_newline_targets_before_creation() {
  make_repo_with_remote
  cd "$REPO_DIR" || return
  mkdir -p .worktrees
  cat >"$MOCK_BIN/realpath" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$MOCK_BIN/realpath"
  local target before
  before="$(git worktree list --porcelain)"
  for target in \
    "$TEST_TMP/outside"$'\n'"worktree" \
    "$REPO_DIR/.worktrees/x"$'\n'"z/../../escape" \
    "$TEST_TMP/trailing"$'\n' \
    ".worktrees/relative"$'\n'"worktree"; do
    capture "$SAFE_GIT" worktree start "$target" -b feature/newline-target \
      --base origin/main --purpose "Newline targets must be refused." --no-fetch
    assert_fails_with "worktree paths containing newlines are not supported"
    assert_eq "$before" "$(git worktree list --porcelain)" "worktree list after refusal"
    git show-ref --verify --quiet refs/heads/feature/newline-target \
      && fail_test "refused target created a branch"
    assert_file_absent "$REPO_DIR/escape"
    assert_file_absent "$target"
  done
}

test_worktree_adopt_refuses_newline_targets_before_checkout() {
  make_repo_with_remote
  cd "$REPO_DIR" || return
  git checkout -b feature/newline-adopt >/dev/null 2>&1 || return
  git push -u origin feature/newline-adopt >/dev/null 2>&1 || return
  mkdir -p .worktrees
  cat >"$MOCK_BIN/realpath" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$MOCK_BIN/realpath"
  local target before
  before="$(git worktree list --porcelain)"
  for target in \
    "$TEST_TMP/outside"$'\n'"worktree" \
    "$REPO_DIR/.worktrees/x"$'\n'"z/../../escape" \
    "$TEST_TMP/trailing"$'\n' \
    ".worktrees/relative"$'\n'"worktree"; do
    capture "$SAFE_GIT" worktree adopt "$target" \
      --purpose "Newline targets must be refused." --no-fetch
    assert_fails_with "worktree paths containing newlines are not supported"
    assert_eq "feature/newline-adopt" "$(git branch --show-current)" "branch after refusal"
    assert_eq "$before" "$(git worktree list --porcelain)" "worktree list after refusal"
    assert_file_absent "$REPO_DIR/escape"
    assert_file_absent "$target"
  done
}
