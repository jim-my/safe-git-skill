#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/SKILL.md" ]] || { echo "Error: SKILL.md not found in $SCRIPT_DIR" >&2; exit 1; }

SKILL_DIR="$HOME/.claude/skills/safe-git"

echo "Installing safe-git skill..."

mkdir -p "$SKILL_DIR"

# Symlink SKILL.md into Claude skills directory
ln -sf "$SCRIPT_DIR/SKILL.md" "$SKILL_DIR/SKILL.md"

echo "Installed: $SKILL_DIR/SKILL.md -> $SCRIPT_DIR/SKILL.md"
echo ""
echo "To install hooks in a repo, copy from $SCRIPT_DIR/hooks/:"
echo "  cp $SCRIPT_DIR/hooks/pre-commit <your-repo>/.git/hooks/pre-commit"
echo "  cp $SCRIPT_DIR/hooks/pre-push <your-repo>/.git/hooks/pre-push"
echo "  chmod +x <your-repo>/.git/hooks/pre-commit <your-repo>/.git/hooks/pre-push"
