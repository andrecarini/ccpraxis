#!/usr/bin/env bash
# bp-fast-store.sh -- pnpm store-dir + virtual-store-dir on container-native storage
# (blueprint sandbox-butler-overhaul, Decision #18, supersedes #6).
set -euo pipefail

# NOTE: resolved with parameter expansion, NOT `dirname` -- steps 1..5 of the
# pipeline (spec 3.1) must run using bash BUILTINS ONLY so that a test can set
# PATH to an empty directory and still deterministically reach the pnpm check.
_src="${BASH_SOURCE[0]}"
case "$_src" in */*) _dir="${_src%/*}" ;; *) _dir="." ;; esac
SCRIPT_DIR=$(CDPATH= cd -- "$_dir" && pwd -P)
# shellcheck source=bp-lib.sh
source "$SCRIPT_DIR/bp-lib.sh"      # defines require_cmd; no side effects, no externals
# NOTE: bp_project_root is NEVER called (it reads BP_PROJECT_ROOT then git -- see 2.10),
# and bp_require_sandbox is deliberately not called either (see 2.9).

WORKSPACE_MARKER='# bp-fast-store: container-native pnpm store (managed lines below; keep pnpm-workspace.yaml gitignored)'
GI_HEADER='# Added by bp-fast-store.sh (container-native pnpm store/virtual-store; container-specific paths, never commit)'
BP_RATIONALE='container-native pnpm store via gitignored pnpm-workspace.yaml (bp-fast-store.sh); the /root store and virtual-store are wiped on container rebuild, so node_modules must be re-materialized or its symlink tree dangles'

# --------------------------------------------------------------- helpers ----

usage() {                     # printf only: reachable with an empty PATH (2.2)
  printf '%s\n' \
'usage: bp-fast-store.sh [--project DIR] [--native-root DIR] [--store DIR] [--virtual-store DIR]' \
'' \
"Point pnpm's storeDir + virtualStoreDir at container-native storage (the overlay" \
'FS) instead of the slow 9p/WSL2 bind mount, via a gitignored project pnpm-workspace.yaml.' \
'NOTE: pnpm 10+ silently IGNORES kebab-case store-dir/virtual-store-dir written to' \
'.npmrc (confirmed broken, spec b38-node-pnpm-toolchain 1.3) -- the camelCase keys must' \
'live in pnpm-workspace.yaml, which pnpm actually honours.' \
'' \
'  --project DIR          project dir to configure               (default: the current directory)' \
'  --native-root DIR      parent of the derived native dirs      (default: /root)' \
'  --store DIR            pnpm storeDir, global CAS               (default: <native-root>/.pnpm-store)' \
'  --virtual-store DIR    pnpm virtualStoreDir, per project       (default: <native-root>/<slug>-vstore)' \
'  -h, --help             this help' \
'' \
'Writes <project>/pnpm-workspace.yaml, ensures the .gitignore entries, creates the native' \
'dirs, and prints ONE /backpack:add line on stdout (all progress goes to stderr). It never' \
"runs pnpm install -- that is the backpack item's job on the next container rebuild."
}

say() { printf 'bp-fast-store: %s\n' "$1" >&2; }

die_usage() {                 # specific line first, then the usage block (2.8)
  say "$1"
  usage >&2
  exit 2
}

# _rstrip VALUE -> RSTRIPPED (trailing whitespace removed; builtin regex only).
RSTRIPPED=''
_rstrip() {
  if [[ $1 =~ ^(.*[^[:space:]])[[:space:]]*$ ]]; then
    RSTRIPPED=${BASH_REMATCH[1]}
  else
    RSTRIPPED=''
  fi
}

# normalize PATH -> lexically normalized absolute path (2.3 step 4). No
# filesystem access, no external command.
normalize() {
  local p=$1 rest comp out=''
  case $p in /*) ;; *) p="$PROJECT/$p" ;; esac
  rest=$p
  while [ -n "$rest" ]; do
    comp=${rest%%/*}
    if [ "$comp" = "$rest" ]; then rest=''; else rest=${rest#*/}; fi
    case $comp in
      ''|.)  ;;
      ..)    out=${out%/*} ;;
      *)     out="$out/$comp" ;;
    esac
  done
  [ -n "$out" ] || out='/'
  printf '%s\n' "$out"
}

# check_safe PATH -- exit 2 on any character that would expand inside the
# double-quoted install/verify strings, or on a control character (2.4).
check_safe() {
  case $1 in
    *'"'*|*'$'*|*'`'*|*'\'*|*[[:cntrl:]]*)
      die_usage "path contains shell-unsafe characters (double-quote, dollar, backtick, backslash or control): $1"
      ;;
  esac
}

# shq VALUE -> single-quoted VALUE; interior ' becomes '\'' (2.7).
shq() {
  local s=${1//\'/\'\\\'\'}
  printf "'%s'" "$s"
}

TMPFILE=''
_cleanup() { if [ -n "$TMPFILE" ] && [ -e "$TMPFILE" ]; then rm -f -- "$TMPFILE" || true; fi; return 0; }
# EXIT alone would leak the temp file on Ctrl-C, so the signals are covered too
# (each handler re-exits, otherwise the interrupted script would just resume).
trap _cleanup EXIT
trap '_cleanup; exit 6' INT TERM HUP

# safe_target PATH -- true when PATH is either absent or a plain regular file.
# The single rule behind every write this script performs: it never writes
# THROUGH a symlink (that would truncate a file outside the project) and never
# writes INTO a directory (`mv -f` would silently succeed and leave pnpm
# unconfigured). Checked with -L first, since -f follows the link.
safe_target() {
  [ ! -L "$1" ] || return 1
  if [ -e "$1" ] && [ ! -f "$1" ]; then return 1; fi
  return 0
}

# write_atomic DEST CONTENT -- temp file inside <PROJECT> then mv (2.5 step 5).
write_atomic() {
  local dest=$1 content=$2
  if ! safe_target "$dest"; then     # directory / symlink / device: refuse (2.8)
    say "failed to write $dest"
    exit 6
  fi
  local tmp="$PROJECT/.bp-fast-store.tmp.$$"
  if ! safe_target "$tmp"; then      # never adopt a pre-planted temp path
    say "failed to write $dest"
    exit 6
  fi
  TMPFILE=$tmp                       # tracked from here on: _cleanup owns it
  # NOTE: 2>/dev/null comes FIRST -- redirections are applied left to right, and
  # a bare `> "$TMPFILE"` that itself fails reports on the stderr in force at
  # that moment, which would leak a raw `line N:` bash error past 2.8.
  if ! printf '%s' "$content" 2>/dev/null > "$TMPFILE"; then
    say "failed to write $dest"
    exit 6
  fi
  # mv carries the TEMP file's umask mode onto the destination, so an existing
  # mode (a 0600 .npmrc holding a registry _authToken -- see 2.5's own example)
  # has to be replicated first or every run world-readables the credentials.
  if [ -f "$dest" ] && ! chmod --reference="$dest" -- "$TMPFILE" 2>/dev/null; then
    say "failed to write $dest"
    exit 6
  fi
  if ! mv -f -- "$TMPFILE" "$dest" 2>/dev/null; then
    say "failed to write $dest"
    exit 6
  fi
  TMPFILE=''
}

# read_lines FILE -> LINES[] (a final line without a trailing newline counts).
LINES=()
read_lines() {
  local line
  LINES=()
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    LINES+=("$line")
  done < "$1"
  return 0
}

# ----------------------------------------------------- 1. parse arguments ----

# Flag PRESENCE is tracked separately from flag VALUE: `--project ''` must NOT
# be read as "no --project" (that fell back to $PWD and silently configured the
# caller's current directory), and an empty native path must not fall back to a
# default that puts the store back on the slow bind mount.
PROJECT_IN=''
PROJECT_SET=0
NATIVE_ROOT=/root
NATIVE_ROOT_SET=0
STORE_IN=''
STORE_SET=0
VSTORE_IN=''
VSTORE_SET=0

while [ $# -gt 0 ]; do
  case $1 in
    -h|--help)          usage; exit 0 ;;
    --project=*)        PROJECT_IN=${1#*=};  PROJECT_SET=1 ;;
    --native-root=*)    NATIVE_ROOT=${1#*=}; NATIVE_ROOT_SET=1 ;;
    --store=*)          STORE_IN=${1#*=};    STORE_SET=1 ;;
    --virtual-store=*)  VSTORE_IN=${1#*=};   VSTORE_SET=1 ;;
    --project|--native-root|--store|--virtual-store)
      [ $# -ge 2 ] || die_usage "option $1 requires a value"
      case $1 in
        --project)        PROJECT_IN=$2;  PROJECT_SET=1 ;;
        --native-root)    NATIVE_ROOT=$2; NATIVE_ROOT_SET=1 ;;
        --store)          STORE_IN=$2;    STORE_SET=1 ;;
        --virtual-store)  VSTORE_IN=$2;   VSTORE_SET=1 ;;
      esac
      shift
      ;;
    -*) die_usage "unknown option: $1" ;;
    *)  die_usage "unexpected argument: $1" ;;
  esac
  shift
done

# An empty native path has no sane interpretation, so it is a usage error (2).
# An empty --project is NOT: it is a path that does not exist, and step 2 below
# reports it as such (exit 6) instead of falling back to the current directory.
if [ "$NATIVE_ROOT_SET" = 1 ] && [ -z "$NATIVE_ROOT" ]; then
  die_usage 'option --native-root requires a non-empty value'
fi
if [ "$STORE_SET" = 1 ] && [ -z "$STORE_IN" ]; then
  die_usage 'option --store requires a non-empty value'
fi
if [ "$VSTORE_SET" = 1 ] && [ -z "$VSTORE_IN" ]; then
  die_usage 'option --virtual-store requires a non-empty value'
fi

# ------------------------------------------------ 2. resolve the project ----

if [ "$PROJECT_SET" = 0 ]; then
  PROJECT_IN=$(pwd -P)                # the builtin, never the PWD env var (2.10)
fi
if [ ! -d "$PROJECT_IN" ]; then
  say "project dir does not exist or is not a directory: $PROJECT_IN"
  exit 6
fi
PROJECT=$(CDPATH= cd -- "$PROJECT_IN" 2>/dev/null && pwd -P) || {
  say "project dir does not exist or is not a directory: $PROJECT_IN"
  exit 6
}
if [ -z "$PROJECT" ]; then
  say "project dir does not exist or is not a directory: $PROJECT_IN"
  exit 6
fi

# ------------------------------------------- 3. slug + native derivations ----

SLUG=${PROJECT##*/}
SLUG=${SLUG,,}
SLUG=${SLUG//[^a-z0-9]/-}
while [[ $SLUG == *--* ]]; do SLUG=${SLUG//--/-}; done
while [ -n "$SLUG" ] && [ "${SLUG:0:1}" = '-' ]; do SLUG=${SLUG#-}; done
while [ -n "$SLUG" ] && [ "${SLUG: -1}" = '-' ]; do SLUG=${SLUG%-}; done
SLUG=${SLUG:0:40}
while [ -n "$SLUG" ] && [ "${SLUG: -1}" = '-' ]; do SLUG=${SLUG%-}; done
[ -n "$SLUG" ] || SLUG=project

NATIVE_ROOT=$(normalize "$NATIVE_ROOT")
if [ "$STORE_SET" = 1 ];  then STORE=$(normalize "$STORE_IN");   else STORE="$NATIVE_ROOT/.pnpm-store"; fi
if [ "$VSTORE_SET" = 1 ]; then VSTORE=$(normalize "$VSTORE_IN"); else VSTORE="$NATIVE_ROOT/$SLUG-vstore"; fi

# --------------------------------------------------- 4. path safety guard ----

check_safe "$PROJECT"
check_safe "$STORE"
check_safe "$VSTORE"
if [ "$STORE" = "$VSTORE" ]; then
  die_usage "--store and --virtual-store must be different paths: $STORE"
fi

# ------------------------------------------------------- 5. pnpm required ----
# `command -v` only: pnpm itself is NEVER executed (2.9).

if ! require_cmd pnpm; then
  say 'pnpm is required (it is what reads the .npmrc this script writes); install pnpm, then re-run.'
  exit 3
fi

# ------------------------------------- 6. native dirs + writability probes ----

ensure_native() {              # ensure_native DIR LABEL
  local d=$1 label=$2 probe
  if ! mkdir -p -- "$d" 2>/dev/null; then
    say "cannot create native $label dir: $d"
    exit 5
  fi
  probe="$d/.bp-fast-store-probe"
  # Same rule as write_atomic: a pre-planted symlink here would have the probe
  # truncate its target outside the store. 2>/dev/null first (see write_atomic).
  if ! safe_target "$probe" || ! : 2>/dev/null > "$probe"; then
    say "native $label dir is not writable: $d"
    exit 5
  fi
  rm -f -- "$probe" 2>/dev/null || true
}

ensure_native "$STORE" store
ensure_native "$VSTORE" virtual-store

# ------------------------------------------- 7. write pnpm-workspace.yaml ----
# camelCase storeDir/virtualStoreDir keys -- pnpm 10+ silently IGNORES the
# kebab-case store-dir/virtual-store-dir keys in .npmrc (confirmed broken,
# spec 1.3), so those are never written here, to .npmrc or anywhere else.

WORKSPACE="$PROJECT/pnpm-workspace.yaml"
WORKSPACE_STATE=created
[ -f "$WORKSPACE" ] && WORKSPACE_STATE=updated

read_lines "$WORKSPACE"
KEEP=()
for _line in ${LINES[@]+"${LINES[@]}"}; do
  _rstrip "$_line"
  [ "$RSTRIPPED" = "$WORKSPACE_MARKER" ] && continue
  [[ $_line =~ ^[[:space:]]*(storeDir|virtualStoreDir)[[:space:]]*: ]] && continue
  KEEP+=("$_line")
done
# strip trailing blank lines from the preserved prefix (2.5 step 3)
while [ ${#KEEP[@]} -gt 0 ]; do
  _rstrip "${KEEP[$(( ${#KEEP[@]} - 1 ))]}"
  [ -z "$RSTRIPPED" ] || break
  unset 'KEEP[${#KEEP[@]}-1]'
done

WORKSPACE_CONTENT=''
if [ ${#KEEP[@]} -gt 0 ]; then
  for _line in "${KEEP[@]}"; do WORKSPACE_CONTENT+="$_line"$'\n'; done
  WORKSPACE_CONTENT+=$'\n'
fi
WORKSPACE_CONTENT+="$WORKSPACE_MARKER"$'\n'"storeDir: $STORE"$'\n'"virtualStoreDir: $VSTORE"$'\n'

write_atomic "$WORKSPACE" "$WORKSPACE_CONTENT"

# --------------------------------------------------- 8. update .gitignore ----

GITIGNORE="$PROJECT/.gitignore"
CANDIDATES=('pnpm-workspace.yaml' 'node_modules/')
case $STORE in "$PROJECT"/*) CANDIDATES+=("${STORE#"$PROJECT"/}/") ;; esac
case $VSTORE in "$PROJECT"/*) CANDIDATES+=("${VSTORE#"$PROJECT"/}/") ;; esac

read_lines "$GITIGNORE"
EXISTING=()
for _line in ${LINES[@]+"${LINES[@]}"}; do
  _rstrip "$_line"
  EXISTING+=("$RSTRIPPED")
done

MISSING=()
HEADER_PRESENT=0
for _e in ${EXISTING[@]+"${EXISTING[@]}"}; do
  [ "$_e" = "$GI_HEADER" ] && HEADER_PRESENT=1
done
for _c in "${CANDIDATES[@]}"; do
  _found=0
  for _e in ${EXISTING[@]+"${EXISTING[@]}"}; do
    if [ "$_e" = "$_c" ] || [ "$_e" = "${_c%/}" ]; then _found=1; break; fi
  done
  # ...and against what this run has ALREADY decided to append, otherwise a
  # --store of <project>/node_modules appends `node_modules/` twice in one pass.
  if [ "$_found" = 0 ]; then
    for _m in ${MISSING[@]+"${MISSING[@]}"}; do
      if [ "$_m" = "$_c" ] || [ "$_m" = "${_c%/}" ]; then _found=1; break; fi
    done
  fi
  [ "$_found" = 1 ] || MISSING+=("$_c")
done

GI_ADDED=${#MISSING[@]}
if [ "$GI_ADDED" -gt 0 ]; then
  GI_CONTENT=''
  if [ ${#EXISTING[@]} -gt 0 ]; then
    for _line in ${LINES[@]+"${LINES[@]}"}; do GI_CONTENT+="$_line"$'\n'; done
    GI_CONTENT+=$'\n'
  fi
  [ "$HEADER_PRESENT" = 1 ] || GI_CONTENT+="$GI_HEADER"$'\n'
  for _c in "${MISSING[@]}"; do GI_CONTENT+="$_c"$'\n'; done
  write_atomic "$GITIGNORE" "$GI_CONTENT"
fi

# ---------------------------------- progress (stderr) + 9. the one product ----

say "project        $PROJECT"
say "store-dir      $STORE"
say "virtual-store  $VSTORE"
say ".npmrc         $NPMRC_STATE"
if [ "$GI_ADDED" = 1 ]; then
  say ".gitignore     +1 entry"
else
  say ".gitignore     +$GI_ADDED entries"
fi
say 'native dirs ready (wiped on container rebuild; the line printed on stdout re-materializes them)'
say 'run the line printed on stdout to declare the rebuild re-install'

BP_NAME="pnpm-install-$SLUG"
BP_INSTALL="cd \"$PROJECT\" && pnpm install --frozen-lockfile"
# Verify BEHAVIOUR, not presence (b38 D6). The previous form was
#   test -d node_modules && test -d $VSTORE && test -n "$(ls -A $VSTORE)"
# which only proves some directories exist. That is exactly the defect this
# package exists to fix: b06 shipped `done` writing store-dir/virtual-store-dir
# into .npmrc, which pnpm 10+ silently ignores, and a presence check could never
# have caught it. So ask pnpm ITSELF where its store is and confirm the answer
# lands under the configured native path, then confirm a real node_modules entry
# actually resolves into the configured virtual store. Both fail against the old
# broken implementation, because pnpm would report the default
# ~/.local/share/pnpm/store instead.
BP_VERIFY="cd \"$PROJECT\" && test -d node_modules && pnpm store path 2>/dev/null | grep -q \"^$STORE\" && test -n \"\$(find node_modules -mindepth 1 -maxdepth 1 -type l -exec readlink -f {} + 2>/dev/null | grep \"^$VSTORE\" | head -1)\""

printf '/backpack:add --category %s --name %s --install %s --verify %s --rationale %s\n' \
  "$(shq 'project-setup')" "$(shq "$BP_NAME")" "$(shq "$BP_INSTALL")" \
  "$(shq "$BP_VERIFY")" "$(shq "$BP_RATIONALE")"

exit 0
