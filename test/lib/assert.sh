# Assertion helpers for the safe-git test harness.
#
# Convention:
#   - `capture <cmd...>` runs the command and stashes STDOUT/STDERR/EXIT.
#   - `assert_*` helpers exit 99 on failure; the runner subshell catches it.
#   - Reaching the end of a test_* function = pass.

capture() {
  # The runner heredoc sets `-uo pipefail` but not `-e`, so the captured
  # command's non-zero exit is already harmless. No need to toggle `set
  # -e` here — and toggling it (set +e ... set -e) would silently turn
  # it ON for the rest of the test, since it wasn't on to begin with.
  local out_file err_file
  out_file="$(mktemp)"
  err_file="$(mktemp)"
  "$@" >"$out_file" 2>"$err_file"
  EXIT=$?
  STDOUT="$(cat "$out_file")"
  STDERR="$(cat "$err_file")"
  rm -f "$out_file" "$err_file"
}

fail_test() {
  printf '  ASSERTION FAILED: %s\n' "$*" >&2
  if [[ -n "${STDOUT:-}" ]]; then
    printf '  --- stdout ---\n%s\n' "$STDOUT" >&2
  fi
  if [[ -n "${STDERR:-}" ]]; then
    printf '  --- stderr ---\n%s\n' "$STDERR" >&2
  fi
  exit 99
}

assert_ok() {
  if [[ "${EXIT:-1}" -ne 0 ]]; then
    fail_test "expected exit 0, got ${EXIT:-unset}"
  fi
}

assert_fails() {
  if [[ "${EXIT:-0}" -eq 0 ]]; then
    fail_test "expected non-zero exit, got 0"
  fi
}

assert_fails_with() {
  local needle="$1"
  assert_fails
  if [[ "$STDERR" != *"$needle"* ]]; then
    fail_test "expected stderr to contain: $needle"
  fi
}

assert_stdout_contains() {
  local needle="$1"
  if [[ "$STDOUT" != *"$needle"* ]]; then
    fail_test "expected stdout to contain: $needle"
  fi
}

assert_stderr_contains() {
  local needle="$1"
  if [[ "$STDERR" != *"$needle"* ]]; then
    fail_test "expected stderr to contain: $needle"
  fi
}

assert_stderr_not_contains() {
  local needle="$1"
  if [[ "$STDERR" == *"$needle"* ]]; then
    fail_test "expected stderr not to contain: $needle"
  fi
}

assert_eq() {
  local expected="$1" actual="$2" label="${3:-values}"
  if [[ "$expected" != "$actual" ]]; then
    fail_test "$label: expected '$expected', got '$actual'"
  fi
}

assert_file_absent() {
  local path="$1"
  if [[ -e "$path" ]]; then
    fail_test "expected $path to not exist"
  fi
}

assert_file_present() {
  local path="$1"
  if [[ ! -e "$path" ]]; then
    fail_test "expected $path to exist"
  fi
}
