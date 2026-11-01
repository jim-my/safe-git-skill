#!/usr/bin/env bash
# Install this repo's committed HEAD the way a stranger would and exercise it:
# a fresh clone, a fake HOME, and no skillbin on PATH.
#
# Usage: scripts/smoke-from-clone.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "smoke: FAIL: $*" >&2; exit 1; }
expect_ok() { "$@" >"$TMP/out" 2>&1 || { cat "$TMP/out" >&2; fail "expected success: $*"; }; }
# The message pins the refusal to the guard, so an unrelated git error cannot pass.
expect_refused() {
  local message="$1"; shift
  if "$@" >"$TMP/out" 2>&1; then fail "expected refusal: $*"; fi
  grep -q "$message" "$TMP/out" || { cat "$TMP/out" >&2; fail "refused without '$message': $*"; }
}

for var in $(compgen -e | grep '^GIT_' || true); do unset "$var"; done
unset CODEX_HOME XDG_CONFIG_HOME
export GIT_CONFIG_NOSYSTEM=1

CLEAN_PATH=""
IFS=: read -ra PATH_DIRS <<<"$PATH"
for dir in "${PATH_DIRS[@]}"; do
  [ -x "$dir/skillbin" ] || CLEAN_PATH="$CLEAN_PATH${CLEAN_PATH:+:}$dir"
done
export PATH="$CLEAN_PATH"
export HOME="$TMP/home"
mkdir -p "$HOME"
command -v skillbin >/dev/null && fail "skillbin is still on PATH"
git config --global user.email smoke@example.com
git config --global user.name smoke
git config --global init.defaultBranch main

git clone -q "$ROOT" "$TMP/skill"
[ "$(git -C "$TMP/skill" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse HEAD)" ] \
  || fail "the clone is not this repo's HEAD"
expect_ok "$TMP/skill/install.sh"
SAFE_GIT="$HOME/.local/bin/safe-git"
[ -x "$SAFE_GIT" ] || fail "install.sh did not link $SAFE_GIT"
export PATH="$HOME/.local/bin:$PATH"

git init -q --bare "$TMP/origin.git"
git init -q "$TMP/repo"
cd "$TMP/repo"
printf '.worktrees/\n' >.gitignore
git add .gitignore
git commit -qm base
git remote add origin "$TMP/origin.git"
git push -q origin main

expect_refused "main worktree" safe-git check start
expect_ok safe-git worktree start .worktrees/task -b feature --base origin/main --purpose smoke
BASE="$(git rev-parse origin/main)"

echo change >main.txt
git add main.txt
expect_refused "Direct commit to main" git commit -m "commit on main"
git reset -q
rm main.txt
git commit -q --allow-empty --no-verify -m "bypass to prove pre-push"
expect_refused "Pushing to main" git push origin main
[ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$BASE" ] || fail "origin main moved"
git reset -q --hard "$BASE"

cd .worktrees/task
expect_ok safe-git check start
echo change >feature.txt
git add feature.txt
expect_ok git commit -m "commit on feature"
expect_ok git push origin feature

echo "smoke: OK at $(git -C "$ROOT" rev-parse --short HEAD)"
