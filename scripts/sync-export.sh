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
CONTAINER_FILES="container-config/Dockerfile container-config/claude-sandbox.sh container-config/claude-sandbox.cmd container-config/CLAUDE.md container-config/settings.json"

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

# Settings merge check — compare everything except permissions
echo ","
SETTINGS_LIVE="$CLAUDE_DIR/settings.json"
SETTINGS_EXPORT="$EXPORT_DIR/global-config/settings.json"
if [ -f "$SETTINGS_LIVE" ] && [ -f "$SETTINGS_EXPORT" ]; then
  DIFF=$(perl -MJSON::PP -e '
    my $read_json = sub {
      open my $f, "<", $_[0] or die; local $/; decode_json(<$f>);
    };
    my $live = $read_json->($ARGV[0]);
    my $repo = $read_json->($ARGV[1]);

    delete $live->{permissions};
    delete $repo->{permissions};

    my $codec = JSON::PP->new->canonical;
    print $codec->encode($live) eq $codec->encode($repo) ? "identical" : "settings_changed";
  ' "$SETTINGS_LIVE" "$SETTINGS_EXPORT")
  echo "{\"file\":\"settings.json\",\"status\":\"$DIFF\",\"note\":\"merge (permissions excluded)\"}"
elif [ -f "$SETTINGS_LIVE" ]; then
  echo "{\"file\":\"settings.json\",\"status\":\"settings_changed\",\"note\":\"missing from repo\"}"
else
  echo "{\"file\":\"settings.json\",\"status\":\"settings_changed\",\"note\":\"missing from live\"}"
fi

echo "]"
