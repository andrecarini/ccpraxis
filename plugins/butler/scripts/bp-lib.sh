#!/usr/bin/env bash
# bp-lib.sh — butler's copy of the shared base helpers PLUS sandbox-only execution helpers.
# Sourced by scripts/ and hooks/. Must stay dependency-light: bash, coreutils, jq, flock.
#
# SUBSET/SUPERSET RELATIONSHIP: The 7 shared base helpers (bp_project_root,
# bp_data_dir, bp_dir, bp_ledger, fm_get, iso_now, file_age_min) at the top of
# this file are kept byte-identical with the counterpart at
# plugins/blueprint/scripts/bp-lib.sh (the host-safe authoring subset). Butler
# adds sandbox-only execution helpers on top (pid_alive, match_any, registry_*,
# count_running_global, require_cmd, bp_require_sandbox) that must NOT be copied
# to the blueprint side (host lacks jq/flock; authoring must stay host-safe).

# ---------------------------------------------------------------- roots ----

bp_project_root() {
  # Priority: explicit env > git toplevel > walk-up for data dir > cwd.
  if [ -n "${BP_PROJECT_ROOT:-}" ]; then printf '%s\n' "$BP_PROJECT_ROOT"; return 0; fi
  local r
  if r=$(git rev-parse --show-toplevel 2>/dev/null); then printf '%s\n' "$r"; return 0; fi
  local d="$PWD"
  while [ "$d" != "/" ]; do
    if [ -d "$d/.ccpraxis-local-data" ]; then printf '%s\n' "$d"; return 0; fi
    d=$(dirname "$d")
  done
  printf '%s\n' "$PWD"
}

bp_data_dir() {
  printf '%s\n' "${CCPRAXIS_DATA_DIR:-$(bp_project_root)/.ccpraxis-local-data}"
}

bp_dir()    { printf '%s\n' "$(bp_data_dir)/blueprints/$1"; }                 # $1=blueprint name
bp_ledger() { printf '%s\n' "$(bp_dir "$1")/packages/$2.md"; }                # $2=package stem (e.g. 01-auth)

# ----------------------------------------------------------- frontmatter ----

# fm_get FILE KEY -> value of "KEY: value" inside the first --- ... --- block.
fm_get() {
  awk -v key="$2" '
    BEGIN { infm=0 }
    /^---[[:space:]]*$/ { infm++; if (infm==2) exit; next }
    infm==1 {
      if (index($0, key ":") == 1) {
        sub("^" key ":[[:space:]]*", "", $0); print; exit
      }
    }' "$1"
}

iso_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

file_age_min() {  # minutes since last mtime of $1
  local now mt
  now=$(date +%s); mt=$(stat -c %Y "$1" 2>/dev/null || echo "$now")
  echo $(( (now - mt) / 60 ))
}
# ---------------------- butler-only: sandbox execution helpers ---------------

pid_alive() {
  [ -n "${1:-}" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  # A zombie (defunct) still answers `kill -0` but is doing no work. In a
  # container whose pid 1 doesn't reap (the sandbox heartbeat loop), an exited
  # or crashed detached coordinator lingers as state 'Z'. Treat it as dead so
  # it neither inflates the BP_MAX_PARALLEL count (blocking new launches) nor
  # masks a crashed coordinator from the resume sweep. /proc is always present
  # on the Linux sandbox; on a /proc-less OS we fall back to the kill -0 result.
  if [ -r "/proc/$1/stat" ]; then
    [ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" = "Z" ] && return 1
  fi
  return 0
}

# ----------------------------------------------------- pattern matching ----

# match_any REL_PATH PATTERNS  (PATTERNS colon-separated, bash [[ == ]] glob
# semantics, '*' crosses '/', trailing '/' means prefix match)
match_any() {
  local p="$1" pats="$2" pat
  [ -n "$pats" ] || return 1
  local IFS=':'
  # shellcheck disable=SC2086
  for pat in $pats; do
    [ -n "$pat" ] || continue
    case "$pat" in
      */) if [[ "$p" == "$pat"* || "$p/" == "$pat" ]]; then return 0; fi ;;
      *)  # shellcheck disable=SC2053
          if [[ "$p" == $pat ]]; then return 0; fi ;;
    esac
  done
  return 1
}

# -------------------------------------------------------------- registry ----
# runs/registry.json: {"packages": {"<pkg>": {session_id,pid,status,model,
#                      attempt,launched_at,last_launch_kind}}}

registry_path() { printf '%s\n' "$(bp_dir "$1")/runs/registry.json"; }

registry_init() {
  local reg; reg=$(registry_path "$1")
  mkdir -p "$(dirname "$reg")"
  [ -s "$reg" ] || echo '{"packages":{}}' > "$reg"
}

# registry_merge BLUEPRINT PKG JSON_OBJECT — shallow-merges fields into pkg entry.
registry_merge() {
  local bp="$1" pkg="$2" obj="$3"
  registry_init "$bp"
  local reg lock; reg=$(registry_path "$bp"); lock="${reg%.json}.lock"
  (
    flock -w 10 9 || { echo "bp-lib: registry lock timeout" >&2; exit 1; }
    local tmp; tmp=$(mktemp)
    jq --arg pkg "$pkg" --argjson obj "$obj" \
       '.packages[$pkg] = ((.packages[$pkg] // {}) + $obj)' "$reg" > "$tmp" \
      && mv "$tmp" "$reg"
  ) 9>"$lock"
}

registry_get() {  # BLUEPRINT PKG FIELD -> value or empty
  local reg; reg=$(registry_path "$1")
  [ -s "$reg" ] || { echo ""; return 0; }
  jq -r --arg pkg "$2" --arg f "$3" '.packages[$pkg][$f] // empty' "$reg"
}

# count running coordinators across ALL blueprints (live pid only)
count_running_global() {
  local data n=0 reg pkg pid
  data=$(bp_data_dir)
  for reg in "$data"/blueprints/*/runs/registry.json; do
    [ -s "$reg" ] || continue
    while IFS=$'\t' read -r pkg pid; do
      if pid_alive "$pid"; then n=$((n+1)); fi
    done < <(jq -r '.packages | to_entries[] | [.key, (.value.pid // "" | tostring)] | @tsv' "$reg")
  done
  echo "$n"
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { echo "butler: missing required command: $c" >&2; return 1; }
  done
}

# bp_require_sandbox — butler coordinators are detached Linux headless `claude -p`
# processes (setsid/nohup/flock); they only work inside the rootless-Podman
# sandbox. Refuse on the host deterministically rather than fail obscurely.
# IS_SANDBOX=1 is set by the sandbox Containerfile (and is what lets Claude Code
# run --dangerously-skip-permissions as container root), so it is the canonical
# in-sandbox marker. Override with BP_ALLOW_HOST=1 only if you know what you're doing.
bp_require_sandbox() {
  [ "${BP_ALLOW_HOST:-}" = "1" ] && return 0
  if [ "${IS_SANDBOX:-}" != "1" ]; then
    echo "butler: refusing to launch outside the sandbox." >&2
    echo "  Butler runs detached headless coordinators (setsid/nohup/flock + 'claude -p')," >&2
    echo "  which only work inside the rootless-Podman sandbox container." >&2
    echo "  Author blueprints on the host with the 'blueprint' plugin (/blueprint:create)," >&2
    echo "  then run them from inside 'claude-sandbox'. (Set BP_ALLOW_HOST=1 to override.)" >&2
    exit 4
  fi
}
