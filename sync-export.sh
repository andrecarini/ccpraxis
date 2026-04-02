#!/bin/bash
# Detect sync status between live ~/.claude/ config and the export repo.
# Outputs JSON describing each file's state — merge decisions are left to the AI.
set -e

EXPORT_DIR="${CLAUDE_EXPORT_DIR:-$HOME/.claude/claude-code-config}"
CLAUDE_DIR="$HOME/.claude"

# Files to sync (relative to their root dirs)
FILES="statusline.pl CLAUDE.md sync-export.sh sensitive-check.sh"
SKILL_FILES="skills/refresh/SKILL.md skills/backup/SKILL.md"

check_file() {
  local name="$1"
  local live="$CLAUDE_DIR/$name"
  local export="$EXPORT_DIR/$name"

  if [ ! -f "$live" ] && [ ! -f "$export" ]; then
    return
  fi

  if [ ! -f "$live" ]; then
    echo "{\"file\":\"$name\",\"status\":\"export_only\"}"
    return
  fi

  if [ ! -f "$export" ]; then
    echo "{\"file\":\"$name\",\"status\":\"live_only\"}"
    return
  fi

  if diff -q "$live" "$export" >/dev/null 2>&1; then
    echo "{\"file\":\"$name\",\"status\":\"identical\"}"
  else
    echo "{\"file\":\"$name\",\"status\":\"conflict\"}"
  fi
}

echo "["
FIRST=1
for f in $FILES $SKILL_FILES; do
  RESULT=$(check_file "$f")
  if [ -n "$RESULT" ]; then
    [ "$FIRST" -eq 1 ] && FIRST=0 || echo ","
    echo "$RESULT"
  fi
done

# Settings is always one-way (live → export, sanitized)
echo ","
SETTINGS_EXPORT="$EXPORT_DIR/settings.json"
if [ -f "$SETTINGS_EXPORT" ]; then
  SANITIZED=$(perl -MJSON::PP -e '
    my $raw = do { local $/; open my $f, "<", $ARGV[0] or die; <$f> };
    my $src = decode_json($raw);
    my $out = {
      env                   => $src->{env},
      alwaysThinkingEnabled => $src->{alwaysThinkingEnabled},
      effortLevel           => $src->{effortLevel},
      statusLine            => $src->{statusLine},
    };
    $out->{permissions} = { allow => ["Read"], deny => [], ask => [], defaultMode => "default" };
    print JSON::PP->new->pretty->canonical->encode($out);
  ' "$CLAUDE_DIR/settings.json")

  EXISTING=$(cat "$SETTINGS_EXPORT")
  if [ "$SANITIZED" = "$EXISTING" ]; then
    echo "{\"file\":\"settings.json\",\"status\":\"identical\",\"note\":\"one-way sanitized\"}"
  else
    echo "{\"file\":\"settings.json\",\"status\":\"settings_changed\",\"note\":\"one-way sanitized\"}"
  fi
else
  echo "{\"file\":\"settings.json\",\"status\":\"live_only\",\"note\":\"one-way sanitized\"}"
fi

echo "]"
