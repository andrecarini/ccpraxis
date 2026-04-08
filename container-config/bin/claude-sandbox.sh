#!/bin/bash
set -e

PROJECT_PATH="${1:-$(pwd)}"
PROJECT_PATH="$(cd "$PROJECT_PATH" && pwd)"  # absolute path
PROJECT_NAME="$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')"
CLAUDE_HOST_CONFIG="$HOME/.claude"
CONTAINER_CONFIG="$CLAUDE_HOST_CONFIG/claude-code-config/container-config"
LAUNCHER_DIR="$PROJECT_PATH/.claude-data/.launcher"

# --- Auto-setup if needed ---

if [ ! -d "$PROJECT_PATH/.claude-data" ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════╗"
  echo "║  First-time setup needed for this project.       ║"
  echo "║  Launching Claude to configure interactively...  ║"
  echo "║  Run /sandbox when Claude starts.                ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  cd "$PROJECT_PATH"
  claude
  if [ ! -d "$PROJECT_PATH/.claude-data" ]; then
    echo "Setup was not completed (.claude-data not found). Aborting."
    exit 1
  fi
fi

# --- Ensure launcher metadata dir exists ---
mkdir -p "$LAUNCHER_DIR"

# --- Get host Claude Code version ---
HOST_VERSION="$(claude --version 2>/dev/null | awk '{print $1}')"

# --- Build image if needed ---
dockerfile_hash() {
  md5sum "$CONTAINER_CONFIG/Dockerfile" | cut -c1-32
}

launcher_hash() {
  cat "$CONTAINER_CONFIG/bin/claude-sandbox.sh" "$CONTAINER_CONFIG/bin/claude-sandbox.ps1" 2>/dev/null | md5sum | cut -c1-32
}

build_image() {
  echo "Building claude-sandbox image with Claude Code v${HOST_VERSION}..."
  docker build \
    --build-arg "CLAUDE_VERSION=${HOST_VERSION}" \
    -t "claude-sandbox:${HOST_VERSION}" \
    -t "claude-sandbox:latest" \
    "$CONTAINER_CONFIG"
  # Save hash so we detect Dockerfile changes later
  dockerfile_hash > "$LAUNCHER_DIR/dockerfile-hash"
}

if ! docker image inspect claude-sandbox:latest > /dev/null 2>&1; then
  build_image
fi

# --- Generate container name ---
if [ -f "$LAUNCHER_DIR/container-name" ]; then
  CONTAINER_NAME="$(cat "$LAUNCHER_DIR/container-name")"
else
  # Short hash of absolute project path to avoid collisions
  PATH_HASH="$(echo -n "$PROJECT_PATH" | md5sum | cut -c1-8)"
  CONTAINER_NAME="claude-${PROJECT_NAME}-${PATH_HASH}"
  echo "$CONTAINER_NAME" > "$LAUNCHER_DIR/container-name"
fi

# --- Staleness check ---
STALE_REASONS=""

if [ -f "$LAUNCHER_DIR/claude-version" ]; then
  CONTAINER_VERSION="$(cat "$LAUNCHER_DIR/claude-version")"
  if [ "$HOST_VERSION" != "$CONTAINER_VERSION" ]; then
    STALE_REASONS="${STALE_REASONS}  - Claude Code version mismatch: container has v${CONTAINER_VERSION}, host has v${HOST_VERSION}\n"
  fi
fi

if [ -f "$LAUNCHER_DIR/container-created" ]; then
  CREATED="$(cat "$LAUNCHER_DIR/container-created")"
  CREATED_TS="$(date -d "$CREATED" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "$CREATED" +%s 2>/dev/null || echo 0)"
  NOW_TS="$(date +%s)"
  AGE_DAYS=$(( (NOW_TS - CREATED_TS) / 86400 ))
  if [ "$AGE_DAYS" -gt 7 ]; then
    STALE_REASONS="${STALE_REASONS}  - Container is ${AGE_DAYS} days old (base OS packages may be outdated)\n"
  fi
fi

CURRENT_DF_HASH="$(dockerfile_hash)"
if [ -f "$LAUNCHER_DIR/dockerfile-hash" ]; then
  SAVED_HASH="$(cat "$LAUNCHER_DIR/dockerfile-hash")"
  if [ "$SAVED_HASH" != "$CURRENT_DF_HASH" ]; then
    STALE_REASONS="${STALE_REASONS}  - Dockerfile has changed since last build\n"
  fi
else
  STALE_REASONS="${STALE_REASONS}  - Dockerfile has changed since last build\n"
fi

CURRENT_LAUNCHER_HASH="$(launcher_hash)"
if [ -f "$LAUNCHER_DIR/launcher-hash" ]; then
  SAVED_LAUNCHER_HASH="$(cat "$LAUNCHER_DIR/launcher-hash")"
  if [ "$SAVED_LAUNCHER_HASH" != "$CURRENT_LAUNCHER_HASH" ]; then
    STALE_REASONS="${STALE_REASONS}  - Launcher scripts have changed since container was created\n"
  fi
else
  STALE_REASONS="${STALE_REASONS}  - Launcher scripts have changed since container was created\n"
fi

if [ -n "$STALE_REASONS" ]; then
  echo ""
  echo "⚠️  Container may be stale:"
  echo -e "$STALE_REASONS"
  echo "Options:"
  echo "  [r] Rebuild — fresh container with Claude Code v${HOST_VERSION}"
  echo "  [c] Continue as-is"
  echo ""
  read -r -p "Choice [r/c]: " CHOICE
  if [ "$CHOICE" = "r" ] || [ "$CHOICE" = "R" ]; then
    # Remove old container if it exists
    docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    build_image
    # Clear container name so a new one is created below
    rm -f "$LAUNCHER_DIR/container-name"
    PATH_HASH="$(echo -n "$PROJECT_PATH" | md5sum | cut -c1-8)"
    CONTAINER_NAME="claude-${PROJECT_NAME}-${PATH_HASH}"
    echo "$CONTAINER_NAME" > "$LAUNCHER_DIR/container-name"
  fi
fi

# --- Discover all available skills ---
declare -A AVAIL_SKILLS  # name -> path
declare -A AVAIL_SOURCE  # name -> source label
declare -a AVAIL_ORDER   # insertion order

# Custom skills (non-host-only)
for skill in "$CLAUDE_HOST_CONFIG/claude-code-config/skills/"*/; do
  [ -d "$skill" ] || continue
  name="$(basename "$skill")"
  if ! grep -q 'host-only: true' "$skill/SKILL.md" 2>/dev/null; then
    AVAIL_SKILLS["$name"]="$skill"
    AVAIL_SOURCE["$name"]="custom"
    AVAIL_ORDER+=("$name")
  fi
done

# Plugin skills
INSTALLED_PLUGINS="$CLAUDE_HOST_CONFIG/plugins/installed_plugins.json"
if [ -f "$INSTALLED_PLUGINS" ]; then
  while IFS=$'\t' read -r pname ppath; do
    for skill_dir in "$ppath/skills"/*/; do
      [ -d "$skill_dir" ] || continue
      name="$(basename "$skill_dir")"
      AVAIL_SKILLS["$name"]="$skill_dir"
      AVAIL_SOURCE["$name"]="plugin:$pname"
      # Only add to order if not already there (dedup)
      if ! printf '%s\n' "${AVAIL_ORDER[@]}" | grep -qx "$name"; then
        AVAIL_ORDER+=("$name")
      fi
    done
  done < <(perl -MJSON::PP -0777 -ne '
    my $d = decode_json($_);
    for my $key (sort keys %{$d->{plugins}}) {
      my $p = $d->{plugins}{$key}[-1]{installPath} // next;
      $p =~ s|\\|/|g; $p =~ s|^([A-Z]):|/\l$1|;
      my ($label) = $key =~ /^([^@]+)/;
      print "$label\t$p\n";
    }
  ' "$INSTALLED_PLUGINS")
fi

# --- Skill selection (saved per project) ---
SELECTION_FILE="$LAUNCHER_DIR/selected-skills.json"
NEED_PROMPT=true
declare -a SELECTED_NAMES

if [ -f "$SELECTION_FILE" ]; then
  # Check for new skills since last selection
  KNOWN=$(perl -MJSON::PP -0777 -ne 'my $d=decode_json($_); print join("\n", @{$d->{known}})' "$SELECTION_FILE")
  NEW_SKILLS=()
  for name in "${AVAIL_ORDER[@]}"; do
    if ! echo "$KNOWN" | grep -qx "$name"; then
      NEW_SKILLS+=("$name")
    fi
  done
  if [ ${#NEW_SKILLS[@]} -eq 0 ]; then
    # No new skills — use saved selection
    while IFS= read -r s; do SELECTED_NAMES+=("$s"); done < <(
      perl -MJSON::PP -0777 -ne 'my $d=decode_json($_); print join("\n", @{$d->{selected}})' "$SELECTION_FILE"
    )
    NEED_PROMPT=false
  else
    echo ""
    echo "New skills available: ${NEW_SKILLS[*]}"
    # Pre-select previously selected
    while IFS= read -r s; do SELECTED_NAMES+=("$s"); done < <(
      perl -MJSON::PP -0777 -ne 'my $d=decode_json($_); print join("\n", @{$d->{selected}})' "$SELECTION_FILE"
    )
  fi
fi

if $NEED_PROMPT && [ ${#AVAIL_ORDER[@]} -gt 0 ]; then
  echo ""
  echo "Available skills for this sandbox:"
  for i in "${!AVAIL_ORDER[@]}"; do
    name="${AVAIL_ORDER[$i]}"
    src="${AVAIL_SOURCE[$name]}"
    marker=" "
    for s in "${SELECTED_NAMES[@]}"; do [ "$s" = "$name" ] && marker="x" && break; done
    printf "  [%s] %d. %s (%s)\n" "$marker" "$((i+1))" "$name" "$src"
  done
  echo ""
  read -r -p "Toggle by number (comma-separated), 'a' for all, Enter to confirm: " INPUT
  if [ "$INPUT" = "a" ]; then
    SELECTED_NAMES=("${AVAIL_ORDER[@]}")
  elif [ -n "$INPUT" ]; then
    IFS=',' read -ra NUMS <<< "$INPUT"
    for num in "${NUMS[@]}"; do
      num="$(echo "$num" | tr -d ' ')"
      [[ "$num" =~ ^[0-9]+$ ]] || continue
      idx=$((num - 1))
      [ "$idx" -ge 0 ] && [ "$idx" -lt ${#AVAIL_ORDER[@]} ] || continue
      name="${AVAIL_ORDER[$idx]}"
      # Toggle
      found=false
      new_selected=()
      for s in "${SELECTED_NAMES[@]}"; do
        if [ "$s" = "$name" ]; then found=true; else new_selected+=("$s"); fi
      done
      if $found; then
        SELECTED_NAMES=("${new_selected[@]}")
      else
        SELECTED_NAMES+=("$name")
      fi
    done
  fi
  # Save selection as JSON
  perl -MJSON::PP -e '
    my @sel = @ARGV[0 .. $ARGV[0]-1+$ARGV[0]]; shift @sel;
    # Actually, re-parse from args
  ' -- # Too complex inline, use a simpler approach
  printf '{"selected":[' > "$SELECTION_FILE"
  first=true
  for s in "${SELECTED_NAMES[@]}"; do
    $first || printf ',' >> "$SELECTION_FILE"
    printf '"%s"' "$s" >> "$SELECTION_FILE"
    first=false
  done
  printf '],"known":[' >> "$SELECTION_FILE"
  first=true
  for s in "${AVAIL_ORDER[@]}"; do
    $first || printf ',' >> "$SELECTION_FILE"
    printf '"%s"' "$s" >> "$SELECTION_FILE"
    first=false
  done
  printf ']}\n' >> "$SELECTION_FILE"
fi

# --- Build skill mounts from selection ---
SKILL_MOUNTS=()
for name in "${SELECTED_NAMES[@]}"; do
  path="${AVAIL_SKILLS[$name]}"
  [ -n "$path" ] && SKILL_MOUNTS+=(-v "$path:/home/claude/.claude/skills/$name:ro")
done

# --- Extra env for deploy key ---
EXTRA_ENV=()
if [ -f "$PROJECT_PATH/deploy_key" ]; then
  EXTRA_ENV+=(-e 'GIT_SSH_COMMAND=ssh -i /project/deploy_key -o StrictHostKeyChecking=no')
fi

# --- PAT auth support ---
EXTRA_MOUNTS=()
if [ -f "$PROJECT_PATH/.claude-data/git-askpass.sh" ]; then
  EXTRA_MOUNTS+=(-v "$PROJECT_PATH/.claude-data/git-askpass.sh:/home/claude/.claude/git-askpass.sh:ro")
  EXTRA_ENV+=(-e "GIT_ASKPASS=/home/claude/.claude/git-askpass.sh")
  EXTRA_MOUNTS+=(-v "$PROJECT_PATH/.claude-data/git-pat:/home/claude/.claude/git-pat:ro")
fi

# --- Fix ownership for UID consistency (dev container creates root-owned files) ---
CLAUDE_UID=1000
HAS_WRONG="$(docker run --rm -u root --entrypoint /bin/bash \
  -v "$PROJECT_PATH:/data" \
  claude-sandbox:latest -c "find /data -maxdepth 2 -not -user $CLAUDE_UID -not -path '/data/.git/*' -print -quit 2>/dev/null" 2>/dev/null)"
if [ -n "$HAS_WRONG" ]; then
  echo "Fixing project ownership (setting to UID $CLAUDE_UID)..."
  docker run --rm -u root --entrypoint /bin/bash \
    -v "$PROJECT_PATH:/data" \
    claude-sandbox:latest -c "find /data -not -user $CLAUDE_UID -not -path '/data/.git/*' -print0 2>/dev/null | xargs -0 -r chown $CLAUDE_UID:$CLAUDE_UID" 2>/dev/null || true
fi

# --- Ensure writable claude.json in project ---
if [ ! -f "$PROJECT_PATH/.claude-data/.claude.json" ] && [ -f "$CONTAINER_CONFIG/claude.json" ]; then
  cp "$CONTAINER_CONFIG/claude.json" "$PROJECT_PATH/.claude-data/.claude.json"
fi

# --- Launch or reattach ---
if docker inspect "$CONTAINER_NAME" > /dev/null 2>&1; then
  # Container exists — reattach
  echo "Reattaching to existing container: $CONTAINER_NAME"
  docker start -ai "$CONTAINER_NAME"
else
  # Create new container
  echo "Creating new container: $CONTAINER_NAME"

  # Save metadata
  echo "$HOST_VERSION" > "$LAUNCHER_DIR/claude-version"
  date -u +"%Y-%m-%dT%H:%M:%S" > "$LAUNCHER_DIR/container-created"
  launcher_hash > "$LAUNCHER_DIR/launcher-hash"

  docker create -it \
    --name "$CONTAINER_NAME" \
    --hostname "claude-sandbox" \
    -p 9000-9009:9000-9009 \
    "${EXTRA_ENV[@]}" \
    -v "$PROJECT_PATH:/project" \
    -v "$PROJECT_PATH/.claude-data:/home/claude/.claude" \
    -v "$LAUNCHER_DIR:/home/claude/.claude/.launcher:ro" \
    -v "$PROJECT_PATH/.claude-data/.claude.json:/home/claude/.claude.json" \
    -v "$CLAUDE_HOST_CONFIG/.credentials.json:/home/claude/.claude/.credentials.json" \
    -v "$CONTAINER_CONFIG/CLAUDE.md:/home/claude/.claude/CLAUDE.md:ro" \
    -v "$CONTAINER_CONFIG/settings.json:/home/claude/.claude/settings.json:ro" \
    -v "$CLAUDE_HOST_CONFIG/claude-code-config/scripts/statusline.pl:/home/claude/.claude/statusline.pl:ro" \
    "${SKILL_MOUNTS[@]}" \
    "${EXTRA_MOUNTS[@]}" \
    claude-sandbox:latest

  docker start -ai "$CONTAINER_NAME"
fi
