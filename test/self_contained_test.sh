#!/usr/bin/env bash
# The package must work from a plain copy of this directory, so nothing it runs or
# documents may reach outside it. lib/gitenv.sh is left out of the path scan: it is
# a byte copy of a shared library whose `..` paths are relative to its caller.
#
# Each detector takes a package root and leaves its matches in HITS. grep exit 2 or
# higher fails the test, so an unreadable path or bad pattern cannot pass as "no hits".

_collect() {
  local out rc=0
  out="$(grep -HnE "$@")" || rc=$?
  [ "$rc" -le 1 ] || fail_test "grep could not scan: $*"
  HITS+="$out"
}

_drop_comment_lines() {
  HITS="$(printf '%s\n' "$HITS" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
}

_find_paths_leaving_package() {
  HITS=""
  _collect '\.\./\.\.' "$1"/bin/* "$1"/hooks/*
  _collect '\.\./' "$1/install.sh"
  _drop_comment_lines
}

_find_symlinks() {
  HITS="$(find "$1" -type l)"
}

_find_skillbin_calls_outside_receipt_gate() {
  HITS=""
  _collect '(^[[:space:]]*|\$\(|&&[[:space:]]*|\|\|[[:space:]]*|;[[:space:]]*)skillbin [a-z]' \
    "$1"/bin/* "$1"/hooks/* "$1/install.sh"
  HITS="$(printf '%s\n' "$HITS" | grep -v 'skillbin g-review-receipt' || true)"
}

_find_parent_repo_doc_references() {
  HITS=""
  _collect 'dotfiles|agent-skills/|\]\(\.\./' -r --include='*.md' "$1"
}

test_package_passes_every_detector() {
  local detector
  for detector in _find_paths_leaving_package _find_symlinks \
    _find_skillbin_calls_outside_receipt_gate _find_parent_repo_doc_references; do
    "$detector" "$SAFE_GIT_ROOT"
    assert_eq "" "$HITS" "$detector"
  done
}

_planted_copy() {
  PLANTED="$TEST_TMP/planted"
  cp -R "$SAFE_GIT_ROOT" "$PLANTED"
}

_assert_detector_fires() {
  "$1" "$PLANTED"
  [ -n "$HITS" ] || fail_test "$1 missed the planted violation"
}

test_detectors_catch_planted_outside_paths() {
  _planted_copy
  printf 'x="$SAFE_GIT_BIN_DIR/../.."\n' >>"$PLANTED/bin/safe-git"
  _assert_detector_fires _find_paths_leaving_package
  rm -rf "$PLANTED"
  _planted_copy
  printf 'y="$SCRIPT_DIR/../bin/x"\n' >>"$PLANTED/install.sh"
  _assert_detector_fires _find_paths_leaving_package
}

test_detector_ignores_only_full_line_comments() {
  _planted_copy
  printf '# see ../../elsewhere\n' >>"$PLANTED/bin/safe-git"
  _find_paths_leaving_package "$PLANTED"
  assert_eq "" "$HITS" comment_line
  printf 'x="${y#p}/../../other"\n' >>"$PLANTED/bin/safe-git"
  _assert_detector_fires _find_paths_leaving_package
}

test_detector_catches_planted_symlink() {
  _planted_copy
  ln -s /etc/hosts "$PLANTED/bin/outside"
  _assert_detector_fires _find_symlinks
}

test_detector_catches_planted_skillbin_call() {
  _planted_copy
  printf 'x="$(skillbin new-helper)"\n' >>"$PLANTED/bin/safe-git"
  _assert_detector_fires _find_skillbin_calls_outside_receipt_gate
}

test_detector_catches_planted_doc_reference() {
  _planted_copy
  printf 'See the dotfiles repo.\n' >>"$PLANTED/SKILL.md"
  _assert_detector_fires _find_parent_repo_doc_references
}

test_detector_fails_when_it_cannot_scan() {
  capture bash -c "source '$SAFE_GIT_ROOT/test/lib/assert.sh'; source '$SAFE_GIT_ROOT/test/self_contained_test.sh'; _find_paths_leaving_package '$TEST_TMP/missing'"
  assert_fails_with "could not scan"
}

test_copied_package_runs_alone() {
  make_repo_with_remote
  local copy="$TEST_TMP/copied-package"
  cp -R "$SAFE_GIT_ROOT" "$copy"
  [ ! -e "$SANDBOX_BIN/skillbin" ] || fail_test "sandbox PATH must not provide skillbin"
  cd "$REPO_DIR" || return
  capture "$copy/bin/safe-git" worktree start .worktrees/task -b feature --base origin/main --purpose "copied package" --no-fetch
  assert_ok
  assert_file_present "$REPO_DIR/.worktrees/task/.git"
  cd "$REPO_DIR/.worktrees/task" || return
  capture "$copy/bin/safe-git" check start --no-fetch
  assert_ok
}
