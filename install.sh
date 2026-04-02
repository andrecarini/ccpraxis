#!/bin/bash
# Install Claude Code config to ~/.claude/
# Works on Linux, macOS, and Windows (Git Bash).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"

mkdir -p "$CLAUDE_DIR/skills/refresh" "$CLAUDE_DIR/skills/backup"

# Scripts (no sensitive data)
for f in statusline.pl sync-export.sh sensitive-check.sh; do
    cp "$SCRIPT_DIR/$f" "$CLAUDE_DIR/$f"
    echo "  Installed $f"
done

# Skills (slash commands)
for f in skills/refresh/SKILL.md skills/backup/SKILL.md; do
    cp "$SCRIPT_DIR/$f" "$CLAUDE_DIR/$f"
    echo "  Installed $f"
done

# Global CLAUDE.md
cp "$SCRIPT_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
echo "  Installed CLAUDE.md"

# Settings — don't overwrite (user has machine-specific permissions/plugins)
if [ -f "$CLAUDE_DIR/settings.json" ]; then
    echo "  settings.json exists — skipping (review manually)"
else
    cp "$SCRIPT_DIR/settings.json" "$CLAUDE_DIR/settings.json"
    echo "  Installed settings.json"
fi

echo ""
echo "Done. Restart Claude Code to pick up changes."
