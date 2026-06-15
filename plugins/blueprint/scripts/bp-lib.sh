#!/usr/bin/env bash
# bp-lib.sh — shared helpers for the blueprint (authoring) plugin.
# HOST-SAFE SUBSET: bash + coreutils + awk only. No jq, no flock, no
# process machinery — authoring runs on the host (where jq may be absent) as
# well as in the sandbox. The execution-side helpers live in the butler plugin.
#
# SUBSET/SUPERSET RELATIONSHIP: This file contains the 7 shared base helpers
# (bp_project_root, bp_data_dir, bp_dir, bp_ledger, fm_get, iso_now,
# file_age_min). Its counterpart at plugins/butler/scripts/bp-lib.sh is a
# SUPERSET — it contains these same 7 base helpers verbatim, plus sandbox-only
# execution helpers (pid_alive, match_any, registry_*, count_running_global,
# require_cmd, bp_require_sandbox). Keep the SHARED BASE byte-identical between
# the two copies; butler adds on top.

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
