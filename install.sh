#!/bin/bash
set -e

SKILL_DIR="$HOME/.claude/skills/safe-git"

echo "Installing safe-git skill..."

mkdir -p "$SKILL_DIR"

# Symlink SKILL.md into Claude skills directory
ln -sf "$(pwd)/SKILL.md" "$SKILL_DIR/SKILL.md"

echo "Installed: $SKILL_DIR/SKILL.md -> $(pwd)/SKILL.md"
echo ""
echo "To install hooks in a repo, copy from $(pwd)/hooks/:"
echo "  cp $(pwd)/hooks/pre-commit <your-repo>/.git/hooks/pre-commit"
echo "  cp $(pwd)/hooks/pre-push <your-repo>/.git/hooks/pre-push"
echo "  chmod +x <your-repo>/.git/hooks/pre-commit <your-repo>/.git/hooks/pre-push"
