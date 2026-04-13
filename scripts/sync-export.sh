#!/bin/bash
# Detect sync status between live ~/.claude/ config and the export repo.
# Outputs JSON describing each file's state — merge decisions are left to the AI.
#
# Most files are symlinked by install.sh, so only repo-owned files are tracked here.
# Settings is the only file that needs merging (permissions stay machine-local).
set -e

EXPORT_DIR="${CLAUDE_EXPORT_DIR:-$HOME/.claude/claude-code-config}"
CLAUDE_DIR="$HOME/.claude"

# Detect Windows (MINGW/MSYS/Cygwin — no real symlinks)
is_windows() {
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0;; *) return 1;; esac
}

# Compare file or directory content
content_matches() {
  local a="$1" b="$2"
  if [ -d "$a" ] && [ -d "$b" ]; then
    diff -rq "$a" "$b" >/dev/null 2>&1
  elif [ -f "$a" ] && [ -f "$b" ]; then
    diff -q "$a" "$b" >/dev/null 2>&1
  else
    return 1
  fi
}

# Repo-owned files (these are the source of truth, not copied)
REPO_FILES="global-config/CLAUDE.md global-config/settings.json"
SCRIPT_FILES="scripts/statusline.pl scripts/merge-settings.pl scripts/sync-export.sh scripts/sensitive-check.sh"
# Skills are discovered dynamically
SKILL_FILES=""
for skill_dir in "$EXPORT_DIR"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  name="$(basename "$skill_dir")"
  SKILL_FILES="$SKILL_FILES skills/$name/SKILL.md"
done
CONTAINER_FILES="container-config/Dockerfile container-config/bin/claude-sandbox.sh container-config/bin/claude-sandbox.ps1 container-config/claude.json container-config/CLAUDE.md container-config/settings.json"

# Check symlinks (Unix) or content-matched copies (Windows)
check_symlink() {
  local name="$1"
  local link="$CLAUDE_DIR/$name"
  # Map to repo source path
  local target
  case "$name" in
    CLAUDE.md) target="$EXPORT_DIR/global-config/CLAUDE.md" ;;
    *)         target="$EXPORT_DIR/$name" ;;
  esac

  if [ -L "$link" ]; then
    echo "{\"file\":\"$name\",\"status\":\"linked\"}"
  elif [ -f "$link" ] || [ -d "$link" ]; then
    if is_windows; then
      if content_matches "$link" "$target"; then
        echo "{\"file\":\"$name\",\"status\":\"linked\",\"note\":\"copy matches repo\"}"
      else
        echo "{\"file\":\"$name\",\"status\":\"not_linked\",\"note\":\"copy differs from repo\"}"
      fi
    else
      echo "{\"file\":\"$name\",\"status\":\"not_linked\",\"note\":\"exists but should be symlink\"}"
    fi
  else
    echo "{\"file\":\"$name\",\"status\":\"missing\",\"note\":\"missing from ~/.claude/\"}"
  fi
}

# Check repo files exist
check_repo_file() {
  local name="$1"
  local path="$EXPORT_DIR/$name"

  if [ ! -f "$path" ]; then
    echo "{\"file\":\"$name\",\"status\":\"missing\",\"note\":\"missing from repo\"}"
  else
    echo "{\"file\":\"$name\",\"status\":\"tracked\"}"
  fi
}

echo "["
FIRST=1

# Check symlinked items — CLAUDE.md + all skills
SYMLINKED_ITEMS="CLAUDE.md"
for skill_dir in "$EXPORT_DIR"/skills/*/; do
  [ -d "$skill_dir" ] || continue
  SYMLINKED_ITEMS="$SYMLINKED_ITEMS skills/$(basename "$skill_dir")"
done
for name in $SYMLINKED_ITEMS; do
  RESULT=$(check_symlink "$name")
  [ "$FIRST" -eq 1 ] && FIRST=0 || echo ","
  echo "$RESULT"
done

# Check repo files exist
for f in $REPO_FILES $SCRIPT_FILES $SKILL_FILES $CONTAINER_FILES; do
  RESULT=$(check_repo_file "$f")
  [ "$FIRST" -eq 1 ] && FIRST=0 || echo ","
  echo "$RESULT"
done

# Settings merge check — full semantic comparison
echo ","
SETTINGS_LIVE="$CLAUDE_DIR/settings.json"
SETTINGS_EXPORT="$EXPORT_DIR/global-config/settings.json"
if [ -f "$SETTINGS_LIVE" ] && [ -f "$SETTINGS_EXPORT" ]; then
  if perl "$EXPORT_DIR/scripts/json-diff.pl" "$SETTINGS_LIVE" "$SETTINGS_EXPORT" >/dev/null 2>&1; then
    DIFF="identical"
  else
    DIFF="settings_changed"
  fi
  echo "{\"file\":\"settings.json\",\"status\":\"$DIFF\",\"note\":\"full semantic comparison\"}"
elif [ -f "$SETTINGS_LIVE" ]; then
  echo "{\"file\":\"settings.json\",\"status\":\"settings_changed\",\"note\":\"missing from repo\"}"
else
  echo "{\"file\":\"settings.json\",\"status\":\"settings_changed\",\"note\":\"missing from live\"}"
fi

# Container settings — detect shared-key divergence from global-config
echo ","
SETTINGS_CONTAINER="$EXPORT_DIR/container-config/settings.json"
if [ -f "$SETTINGS_CONTAINER" ] && [ -f "$SETTINGS_EXPORT" ]; then
  if perl "$EXPORT_DIR/scripts/json-diff.pl" "$SETTINGS_CONTAINER" "$SETTINGS_EXPORT" >/dev/null 2>&1; then
    DIFF="identical"
  else
    DIFF="container_settings_diverged"
  fi
  echo "{\"file\":\"container-config/settings.json\",\"status\":\"$DIFF\",\"note\":\"shared keys vs global-config\"}"
elif [ -f "$SETTINGS_CONTAINER" ]; then
  echo "{\"file\":\"container-config/settings.json\",\"status\":\"tracked\",\"note\":\"no global-config to compare\"}"
fi

# Marketplace comparison — known_marketplaces.json
echo ","
MARKETPLACE_LIVE="$CLAUDE_DIR/plugins/known_marketplaces.json"
MARKETPLACE_EXPORT="$EXPORT_DIR/global-config/known_marketplaces.json"
if [ -f "$MARKETPLACE_LIVE" ] && [ -f "$MARKETPLACE_EXPORT" ]; then
  if perl "$EXPORT_DIR/scripts/json-diff.pl" --deep-exclude installLocation "$MARKETPLACE_LIVE" "$MARKETPLACE_EXPORT" >/dev/null 2>&1; then
    DIFF="identical"
  else
    DIFF="marketplace_changed"
  fi
  echo "{\"file\":\"known_marketplaces.json\",\"status\":\"$DIFF\",\"note\":\"marketplace selection\"}"
elif [ -f "$MARKETPLACE_LIVE" ]; then
  echo "{\"file\":\"known_marketplaces.json\",\"status\":\"live_only\",\"note\":\"not yet exported to repo\"}"
elif [ -f "$MARKETPLACE_EXPORT" ]; then
  echo "{\"file\":\"known_marketplaces.json\",\"status\":\"export_only\",\"note\":\"missing from live\"}"
else
  echo "{\"file\":\"known_marketplaces.json\",\"status\":\"missing\",\"note\":\"no marketplace data\"}"
fi

echo "]"
