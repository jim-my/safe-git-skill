#!/usr/bin/env bash
# shellcheck disable=SC2034 # Values are used by tests that source this file.
# Fixture helpers for the safe-git test harness.
#
# Each test runs in its own subshell; `make_test_env` builds an isolated
# tempdir and a hermetic PATH (sandbox-bin + mock-bin). Tests install
# command mocks into MOCK_BIN; gh is intentionally absent unless mocked.

# Resolve the safe-git binary path from this file's location:
# .../safe-git/test/lib/fixtures.sh -> .../safe-git/bin/safe-git
SAFE_GIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SAFE_GIT="$SAFE_GIT_ROOT/bin/safe-git"
HOOKS_DIR="$SAFE_GIT_ROOT/hooks"

# Tools the harness needs available on PATH inside tests. `gh` is
# deliberately omitted — tests that need it install a mock.
SANDBOX_TOOLS=(
  bash sh env git mktemp rm cat head sed awk grep wc tr od printf
  mkdir cp mv ls dirname find readlink chmod ln basename id tee
  uname touch test true false sort uniq diff stat sleep date which tar
  command type pwd cd cmp
)

make_test_env() {
  TEST_TMP="$(mktemp -d -t safegit-test.XXXXXX)"
  MOCK_BIN="$TEST_TMP/mock-bin"
  SANDBOX_BIN="$TEST_TMP/sandbox-bin"
  mkdir -p "$MOCK_BIN" "$SANDBOX_BIN"

  # Save the inherited PATH so we can resolve real tool locations.
  REAL_PATH="$PATH"

  local bin real
  for bin in "${SANDBOX_TOOLS[@]}"; do
    if real="$(PATH="$REAL_PATH" command -v "$bin" 2>/dev/null)"; then
      # `command -v` for shell builtins (cd, command, type, pwd) returns
      # the builtin name itself. Skip those — bash provides them anyway.
      if [[ "$real" == /* ]]; then
        ln -sf "$real" "$SANDBOX_BIN/$bin"
      fi
    fi
  done

  PATH="$MOCK_BIN:$SANDBOX_BIN"
  export PATH

  # Hermetic HOME so user gitconfig/aliases don't leak in.
  export HOME="$TEST_TMP/home"
  export CODEX_HOME="$TEST_TMP/codex"
  mkdir -p "$HOME"
  cat >"$HOME/.gitconfig" <<'EOF'
[user]
  name = Test
  email = test@example.com
[init]
  defaultBranch = main
[commit]
  gpgsign = false
[advice]
  detachedHead = false
EOF

  # Neutralise env that would override config or repo resolution. The
  # GIT_DIR / GIT_WORK_TREE pair would leak the runner's cwd; the
  # GIT_CONFIG* / XDG_CONFIG_HOME / GIT_TEMPLATE_DIR set would steer
  # config reads away from our hermetic $HOME/.gitconfig.
  # Repo-resolution vars come from the shared strip, not a hand-kept list
  # (#1721): of the nine names this tree used to unset, only FIVE were in the
  # shared 18 (GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_COMMON_DIR,
  # GIT_CONFIG), leaving 13 uncovered — and they are not harmless: a leaked
  # GIT_OBJECT_DIRECTORY alone takes this suite from 99 passed to 19 passed /
  # 80 failed. The four names kept below are config hermeticity, outside the
  # shared repo-resolution set, so they stay explicit.
  # shellcheck source=../../lib/gitenv.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../lib/gitenv.sh"
  scrub_git_env
  unset GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_TEMPLATE_DIR XDG_CONFIG_HOME
}

cleanup_test_env() {
  if [[ -n "${TEST_TMP:-}" && -d "$TEST_TMP" ]]; then
    rm -rf "$TEST_TMP"
  fi
}

# Build a bare "remote" repo and a clone of it.
# After: REMOTE_DIR, REPO_DIR set; REPO_DIR has origin/main with one commit
# and origin/HEAD pointing at origin/main.
make_repo_with_remote() {
  # Honour pre-set REPO_DIR / REMOTE_DIR so callers can place the main
  # worktree at e.g. "$TEST_TMP/with space/repo" to exercise spaced-
  # path handling.
  REMOTE_DIR="${REMOTE_DIR:-$TEST_TMP/remote.git}"
  REPO_DIR="${REPO_DIR:-$TEST_TMP/repo}"
  # Defensive guard: a typo or copy-paste that lands either path
  # outside TEST_TMP would `git init` against a real path on the host.
  local _path
  for _path in "$REPO_DIR" "$REMOTE_DIR"; do
    case "$_path" in
      "$TEST_TMP"/*) ;;
      *) printf 'make_repo_with_remote: %s must be under TEST_TMP (%s)\n' \
              "$_path" "$TEST_TMP" >&2
         return 1 ;;
    esac
  done
  mkdir -p "$(dirname "$REMOTE_DIR")" "$(dirname "$REPO_DIR")"

  git init --bare --initial-branch=main "$REMOTE_DIR" >/dev/null

  local seed="$TEST_TMP/seed"
  git init --initial-branch=main "$seed" >/dev/null
  (
    cd "$seed" || exit 1
    echo seed > README.md
    git add README.md
    git commit --quiet -m "initial"
    git remote add origin "$REMOTE_DIR"
    git push --quiet -u origin main
  ) || return 1
  rm -rf "$seed"

  git clone --quiet "$REMOTE_DIR" "$REPO_DIR"
  (
    cd "$REPO_DIR" || exit 1
    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  )
}

# Add a linked worktree at WT_DIR=$TEST_TMP/wt-<branch>, on a new branch
# off origin/main.
make_linked_worktree() {
  local branch="$1"
  WT_DIR="$TEST_TMP/wt-$branch"
  (
    cd "$REPO_DIR" || exit 1
    # --no-track keeps the branch upstream-less by default; tests that
    # want tracking use checkout_linked_worktree_tracking instead. This
    # gives every test a known starting point: branch has no @{u}.
    git worktree add --quiet --no-track -b "$branch" "$WT_DIR" origin/main
  )
}

# Install a passing `gh` mock.
#   mock_gh <state> <headRefOid>
# `gh pr view --json state,headRefOid --template '{{.state}} {{.headRefOid}}'`
# prints "<state> <oid>".
mock_gh() {
  local state="$1" oid="${2:-}"
  cat >"$MOCK_BIN/gh" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "pr" && "\$2" == "view" ]]; then
  printf '%s %s' "$state" "$oid"
  exit 0
fi
echo "mock-gh: unsupported invocation: \$*" >&2
exit 1
EOF
  chmod +x "$MOCK_BIN/gh"
}

# Install a `gh` mock whose `pr view` exits non-zero.
mock_gh_failing() {
  cat >"$MOCK_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  echo "mock-gh: simulated failure" >&2
  exit 1
fi
echo "mock-gh: unsupported invocation: $*" >&2
exit 1
EOF
  chmod +x "$MOCK_BIN/gh"
}

# Install a `skillbin` mock whose `g-review-receipt find-current` exits with
# the given code (0 = push-eligible receipt for the pushed SHA, non-zero =
# missing/ineligible). Drives the pre-push receipt gate without depending on
# g-review-receipt internals.
mock_skillbin_receipt_check() {
  local rc="$1"
  cat >"$MOCK_BIN/skillbin" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "g-review-receipt" && "\$2" == "find-current" ]]; then
  exit $rc
fi
echo "mock-skillbin: unsupported invocation: \$*" >&2
exit 1
EOF
  chmod +x "$MOCK_BIN/skillbin"
}

# Write a ticket evidence file under <repo>/.plans/ for ticket <id>. Content
# is irrelevant here — the gate delegates judgment to the receipt check (mocked).
seed_ticket_evidence() {
  local repo="$1" id="$2"
  mkdir -p "$repo/.plans"
  printf 'evidence\n' >"$repo/.plans/ticket-$id-evidence.md"
}

# Build a pre-push stdin line whose pushed local_sha is REPO_DIR's current HEAD.
# <dest> is the destination branch; <localref> defaults to refs/heads/<dest>
# (pass `HEAD` to exercise `git push -u origin HEAD`).
head_push_line() {
  local dest="$1" localref="${2:-refs/heads/$1}" sha
  sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
  printf '%s %s refs/heads/%s %s' "$localref" "$sha" "$dest" "$sha"
}

# Install a passing receipt-checker that records its argv so hook wiring can
# assert the exact pushed-SHA and --for-push bindings reach g-review-receipt.
mock_skillbin_capture_receipt_check() {
  cat >"$MOCK_BIN/skillbin" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "g-review-receipt" && "$2" == "find-current" ]]; then
  printf 'argv=%s\npwd=%s\n' "$*" "$PWD" >"$MOCK_VERIFY_LOG"
  exit 0
fi
echo "mock-skillbin: unsupported invocation: $*" >&2
exit 1
EOF
  chmod +x "$MOCK_BIN/skillbin"
}

# Wrap `git` to fail loudly on any `git fetch ...` invocation. All
# other invocations pass through. Used to verify --no-fetch behaviour:
# without --no-fetch, safe-git's fetch_remotes call is intercepted and
# the script exits non-zero; with --no-fetch, the wrapper never runs.
mock_git_fail_on_fetch() {
  local real_git
  # Plain `readlink` (no -f) for BSD/macOS portability — the sandbox
  # symlinks already store an absolute target, so canonicalisation
  # would be a no-op.
  real_git="$(readlink "$SANDBOX_BIN/git")"
  cat >"$MOCK_BIN/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "fetch" ]]; then
  echo "mock-git: fetch is not allowed in this test" >&2
  exit 77
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$MOCK_BIN/git"
}

# Wrap `git` to make `git worktree list --porcelain` return a bogus
# main-worktree path. All other `git` invocations pass through to the
# real binary that sandbox-bin links to.
mock_git_worktree_list_bogus() {
  local bogus="$1"
  local real_git
  # Plain `readlink` (no -f) for BSD/macOS portability — the sandbox
  # symlinks already store an absolute target, so canonicalisation
  # would be a no-op.
  real_git="$(readlink "$SANDBOX_BIN/git")"
  cat >"$MOCK_BIN/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "worktree" && "\$2" == "list" && "\$3" == "--porcelain" ]]; then
  if [[ "\${4:-}" == -z ]]; then
    printf 'worktree %s\0HEAD 0000000000000000000000000000000000000000\0branch refs/heads/x\0\0' "$bogus"
  else
    printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\nbranch refs/heads/x\n\n' "$bogus"
  fi
  exit 0
fi
exec "$real_git" "\$@"
EOF
  chmod +x "$MOCK_BIN/git"
}

# Push origin/<branch> seeded from origin/main. Branch must not exist on
# origin yet. No local branch is created.
push_remote_branch_from_main() {
  local branch="$1"
  (
    cd "$REPO_DIR" || exit 1
    git push --quiet origin "origin/main:refs/heads/$branch"
  )
}

# Create a linked worktree at WT_DIR=$TEST_TMP/wt-<branch> with a local
# branch tracking origin/<branch>. origin/<branch> must already exist.
checkout_linked_worktree_tracking() {
  local branch="$1"
  WT_DIR="$TEST_TMP/wt-$branch"
  (
    cd "$REPO_DIR" || exit 1
    git worktree add --quiet --track -b "$branch" "$WT_DIR" "origin/$branch"
  )
}

# Advance origin/<branch> by one new commit. Mutates the bare remote
# via a throwaway clone; the local repo does NOT auto-fetch.
advance_remote_branch() {
  local branch="$1" tag="${2:-advance}"
  local tmp="$TEST_TMP/advance-$branch-$$"
  git clone --quiet --branch "$branch" "$REMOTE_DIR" "$tmp"
  (
    cd "$tmp" || exit 1
    printf '%s\n' "$tag" >>advance.txt
    git add advance.txt
    git commit --quiet -m "$tag"
    git push --quiet origin "$branch"
  ) || return 1
  rm -rf "$tmp"
}

# Add a second remote pointing at a fresh bare repo with `<branch>`
# pre-created. Local `feature` will not yet have an upstream.
add_second_remote_with_branch() {
  local remote_name="$1" branch="$2"
  local bare="$TEST_TMP/${remote_name}.git"
  git init --bare --initial-branch=main "$bare" >/dev/null

  # Seed a commit and a same-named branch on the second remote.
  local seed="$TEST_TMP/${remote_name}-seed"
  git init --initial-branch=main "$seed" >/dev/null
  (
    cd "$seed" || exit 1
    echo "$remote_name" >README.md
    git add README.md
    git commit --quiet -m "$remote_name initial"
    git remote add origin "$bare"
    git push --quiet -u origin "main:refs/heads/$branch"
  ) || return 1
  rm -rf "$seed"

  (
    cd "$REPO_DIR" || exit 1
    git remote add "$remote_name" "$bare"
    git fetch --quiet "$remote_name"
  )
}

# Manufacture a partial-HEAD state inside a repo. <kind> is one of:
#   rebase-merge | rebase-apply | merge | cherry-pick | revert | bisect
# Writes the marker that safe-git's check_clean_state inspects.
fake_partial_state() {
  local repo="$1" kind="$2"
  local git_dir
  # Resolve to an absolute path inside the same subshell — git_dir from
  # `git rev-parse --git-dir` is otherwise relative to the cd'd repo
  # and breaks once we return to the caller's cwd.
  git_dir="$( cd "$repo" && cd "$(git rev-parse --git-dir)" && pwd )" || return 1
  case "$kind" in
    rebase-merge) mkdir -p "$git_dir/rebase-merge" ;;
    rebase-apply) mkdir -p "$git_dir/rebase-apply" ;;
    merge)        : >"$git_dir/MERGE_HEAD" ;;
    cherry-pick)  : >"$git_dir/CHERRY_PICK_HEAD" ;;
    revert)       : >"$git_dir/REVERT_HEAD" ;;
    bisect)       : >"$git_dir/BISECT_LOG" ;;
    *) printf 'fake_partial_state: unknown kind %s\n' "$kind" >&2; return 1 ;;
  esac
}

# Build the real Git layouts from #2056 on top of the usual remote fixture.
# REPO_DIR is the main checkout (or the bare directory); COMMON_DIR is metadata.
make_main_worktree_layout() {
  local layout="$1"
  make_repo_with_remote
  case "$layout" in
    submodule|submodule-worktree-config)
      local super="$TEST_TMP/super"
      git init --quiet "$super"
      git -C "$super" -c protocol.file.allow=always submodule add --quiet "$REMOTE_DIR" sub
      git -C "$super" commit --quiet -am "add submodule"
      REPO_DIR="$super/sub"
      ;;
    separate)
      git clone --quiet --separate-git-dir="$TEST_TMP/separate.git" "$REMOTE_DIR" "$TEST_TMP/separate"
      REPO_DIR="$TEST_TMP/separate"
      ;;
    bare)
      git clone --quiet --bare "$REMOTE_DIR" "$TEST_TMP/bare.git"
      REPO_DIR="$TEST_TMP/bare.git"
      git -C "$REPO_DIR" fetch --quiet origin main:refs/remotes/origin/main
      ;;
    *) fail_test "unknown main worktree layout: $layout" ;;
  esac
  COMMON_DIR="$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir)"
  if [[ "$layout" == submodule-worktree-config ]]; then
    local core_wt
    core_wt="$(git -C "$REPO_DIR" config core.worktree)"
    git -C "$REPO_DIR" config extensions.worktreeConfig true
    git config -f "$COMMON_DIR/config.worktree" core.worktree "$core_wt"
    git config -f "$COMMON_DIR/config" --unset core.worktree
  fi
}

# Record mutating Git commands invoked from metadata, without changing Git's result.
trace_git_metadata_operations() {
  local real_git
  real_git="$(readlink "$SANDBOX_BIN/git")"
  cat > "$MOCK_BIN/git" <<EOF_TRACE
#!/usr/bin/env bash
if [[ "\$PWD" == "$COMMON_DIR" ]]; then
  case "\${1:-}" in
    checkout|merge|worktree|branch) printf '%s\\n' "\$*" >> "$TEST_TMP/metadata-operations" ;;
  esac
fi
exec "$real_git" "\$@"
EOF_TRACE
  chmod +x "$MOCK_BIN/git"
}
