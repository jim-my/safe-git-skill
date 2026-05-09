#!/usr/bin/env bash
# Test runner for the safe-git regression suite.
#
# Discovers every test/*_test.sh file, sources it, runs each `test_*`
# function in its own subshell with an isolated tempdir + hermetic PATH.
# Reports per-test pass/fail and a final tally; non-zero exit on any
# failure.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$ROOT/test"

# shellcheck source=lib/assert.sh
source "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/fixtures.sh
source "$TEST_DIR/lib/fixtures.sh"

PASS=0
FAIL=0
FAILURES=()

list_test_funcs() {
  local file="$1"
  bash <<EOF 2>/dev/null
set -uo pipefail
source '$TEST_DIR/lib/assert.sh'
source '$TEST_DIR/lib/fixtures.sh'
source '$file'
compgen -A function | grep '^test_' || true
EOF
}

run_test_func() {
  local file="$1" fn="$2"
  local tmp_out
  tmp_out="$(mktemp)"
  bash >"$tmp_out" 2>&1 <<EOF
set -uo pipefail
source '$TEST_DIR/lib/assert.sh'
source '$TEST_DIR/lib/fixtures.sh'
source '$file'
make_test_env
trap cleanup_test_env EXIT
$fn
EOF
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    rm -f "$tmp_out"
    return 0
  fi
  cat "$tmp_out" >&2
  rm -f "$tmp_out"
  return 1
}

run_file() {
  local file="$1"
  local short
  short="$(basename "$file")"
  printf '\n%s\n' "$short"

  local funcs
  funcs="$(list_test_funcs "$file")"
  if [[ -z "$funcs" ]]; then
    printf '  (no tests found)\n'
    return
  fi

  local fn
  while IFS= read -r fn; do
    [[ -n "$fn" ]] || continue
    printf '  %-60s ' "$fn"
    if run_test_func "$file" "$fn"; then
      printf 'OK\n'
      PASS=$((PASS+1))
    else
      printf 'FAIL\n'
      FAIL=$((FAIL+1))
      FAILURES+=("$short::$fn")
    fi
  done <<<"$funcs"
}

main() {
  local files=()
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$TEST_DIR" -maxdepth 1 -name '*_test.sh' -type f | sort)

  if [[ ${#files[@]} -eq 0 ]]; then
    printf 'no test files found in %s\n' "$TEST_DIR" >&2
    exit 2
  fi

  local f
  for f in "${files[@]}"; do
    run_file "$f"
  done

  printf '\n----\n%d passed, %d failed\n' "$PASS" "$FAIL"
  if [[ $FAIL -gt 0 ]]; then
    printf '\nFailures:\n'
    local fail
    for fail in "${FAILURES[@]}"; do
      printf '  %s\n' "$fail"
    done
    exit 1
  fi
}

main "$@"
