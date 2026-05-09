#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/SKILL.md" ]] || { echo "Error: SKILL.md not found in $SCRIPT_DIR" >&2; exit 1; }

AGENTS_SKILL_DIR="$HOME/.agents/skills/safe-git"
CLAUDE_SKILL_DIR="$HOME/.claude/skills/safe-git"
CODEX_SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/skills/safe-git"
LOCAL_BIN="$HOME/.local/bin/safe-git"

install_link() {
  local target="$1"
  local link_path="$2"

  if [[ "$target" == "$link_path" ]]; then
    echo "Installed: $link_path"
    return
  fi

  if [[ -e "$link_path" && ! -L "$link_path" ]]; then
    echo "Error: $link_path exists and is not a symlink" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$link_path")"
  ln -sfn "$target" "$link_path"
  echo "Installed: $link_path -> $target"
}

echo "Installing safe-git skill..."

if mkdir -p "$(dirname "$AGENTS_SKILL_DIR")" 2>/dev/null && [[ -L "$AGENTS_SKILL_DIR" || -w "$(dirname "$AGENTS_SKILL_DIR")" || -w "$AGENTS_SKILL_DIR" ]]; then
  install_link "$SCRIPT_DIR" "$AGENTS_SKILL_DIR"
  skill_target="$AGENTS_SKILL_DIR"
else
  echo "Skipping $AGENTS_SKILL_DIR; parent directory is not writable."
  skill_target="$SCRIPT_DIR"
fi
install_link "$skill_target" "$CLAUDE_SKILL_DIR"
install_link "$skill_target" "$CODEX_SKILL_DIR"
install_link "$skill_target/bin/safe-git" "$LOCAL_BIN"
echo ""
echo "To install hooks in a repo, copy from $SCRIPT_DIR/hooks/:"
echo "  cp $SCRIPT_DIR/hooks/pre-commit <your-repo>/.git/hooks/pre-commit"
echo "  cp $SCRIPT_DIR/hooks/pre-push <your-repo>/.git/hooks/pre-push"
echo "  chmod +x <your-repo>/.git/hooks/pre-commit <your-repo>/.git/hooks/pre-push"
