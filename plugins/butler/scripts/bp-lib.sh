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
# runs/registry.json: {"packages": {"<pkg>": {session_id,pid,model,
#                      attempt,launched_at,last_launch_kind}}}
# runtime-only (s02): the package's authoritative lifecycle field lives in
# the ledger frontmatter, not here.

registry_path() { printf '%s\n' "$(bp_dir "$1")/runs/registry.json"; }

registry_init() {
  local reg; reg=$(registry_path "$1")
  mkdir -p "$(dirname "$reg")"
  [ -s "$reg" ] || echo '{"packages":{}}' > "$reg"
}

# a01: single source of truth for the registry lock timeout is BpWrite (Perl side,
# bp-write-guard.pl); this derives from it once per shell process (cached in
# ${_BP_REGISTRY_LOCK_TIMEOUT:-}, lazily -- no top-level assignment, so sourcing
# this file has zero top-level statements/side effects), rather than hardcoding
# the literal a second time and risking cross-language drift.
#
# fixbatch step7 / MINOR 7: MUST be invoked as a plain statement (never inside a
# `$(...)` command substitution) -- command substitution always forks a subshell,
# and the `_BP_REGISTRY_LOCK_TIMEOUT=...` assignment below would land in THAT
# subshell and vanish the instant it exits, defeating the cache every single call
# (measured: ~85ms/call, all of it perl startup). Callers read the global directly
# after calling this with no output captured.
_bp_registry_lock_timeout() {
  if [ -z "${_BP_REGISTRY_LOCK_TIMEOUT:-}" ]; then
    local libdir; libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _BP_REGISTRY_LOCK_TIMEOUT="$(perl "$libdir/bp-write-guard.pl" --lock-timeout 2>/dev/null)"
    [[ "$_BP_REGISTRY_LOCK_TIMEOUT" =~ ^[0-9]+$ ]] || _BP_REGISTRY_LOCK_TIMEOUT=10
  fi
}

# registry_merge BLUEPRINT PKG JSON_OBJECT — shallow-merges fields into pkg entry.
# Returns the subshell's own exit status (a01 behavior 32): a lock-timeout or a
# failed jq/mv is no longer swallowed -- it propagates out of registry_merge itself,
# not only onto its subshell's own (unobserved) exit. (fixbatch step7 / MINOR 8: the
# trailing `return $?` below is a deliberate no-op left in place -- a bash function
# already returns its last command's exit status, so behavior 32 was already true
# the moment `( … ) 9>"$lock"` became the last statement; the explicit `return $?`
# documents that intent for the next reader rather than changing anything.)
registry_merge() {
  local bp="$1" pkg="$2" obj="$3"
  registry_init "$bp"
  local reg lock to; reg=$(registry_path "$bp"); lock="${reg%.json}.lock"
  _bp_registry_lock_timeout
  to="$_BP_REGISTRY_LOCK_TIMEOUT"
  (
    flock -w "$to" 9 || { echo "bp-lib: registry lock timeout" >&2; exit 1; }
    local tmp; tmp=$(mktemp)
    jq --arg pkg "$pkg" --argjson obj "$obj" \
       '.packages[$pkg] = ((.packages[$pkg] // {}) + $obj)' "$reg" > "$tmp" \
      && mv "$tmp" "$reg"
  ) 9>"$lock"
  return $?
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

# bp_strip_shell_noise -- reads a raw shell command on STDIN, echoes it back
# with every single-quoted span, double-quoted span, '#'-comment (only when
# '#' starts a new word -- preceded by whitespace, a command separator, or
# the start of the string, exactly like bash's own lexer), and heredoc body
# replaced by same-length whitespace. A substring/regex match run against the
# RESULT only ever sees text bash would actually treat as live, unquoted,
# un-commented command text -- never text sitting inert inside a string,
# comment, or heredoc body.
#
# fixbatch step7 / w03 F2. BYTE-IDENTICAL algorithm to the one
# mark-wakeup.sh authored first (fixbatch step7 / g03 F1, verified live
# against three independent bypass techniques: a bash comment, a
# single-quoted string, a heredoc body). Lifted here so a THIRD copy of this
# logic is never written: hooks/guard-validation-interlock.sh is the second
# consumer of this one implementation.
#
# 2026-08-19 d03-one-shell-noise-stripper (almanac report 20260814-093113-34a0):
# mark-wakeup.sh's own inline copy is GONE. This sentence used to claim it was
# "deliberately left as-is rather than refactored to call this" because "only
# a genuinely NEW caller needs to reuse rather than reinvent" -- that claim is
# now FALSE and would contradict the code next to it if left standing. Both of
# mark-wakeup.sh's arms (the reporter-arm block and the driver-arm block) now
# call this function via a conditional source of this file, mirroring
# guard-validation-interlock.sh:70-74. This is the third and last treatment of
# one problem collapsing to one implementation, not two independent copies
# plus a shared one.
#
# NOT a shell parser: command substitution ($(...)), variable expansion, and
# backtick spans are not resolved, so text built through one of those still
# slips past filtering -- an accepted, documented residual, same direction
# every caller of this helper already accepts for its own analogous gap.
#
# Returns EMPTY (not the original text) if perl is unavailable or the input
# was empty -- callers MUST treat empty as "could not determine" and choose
# their own fail-open/fail-safe fallback; this helper does not decide that
# for them.
bp_strip_shell_noise() {
  perl -0777 -ne '
      my $s = $_;
      my @c = split //, $s, -1;
      my $n = scalar @c;
      my $filtered = "";
      my $state = "none";      # none | squote | dquote | comment | heredoc
      my $hd = ""; my $hd_tabs = 0; my $hd_pending = 0; my $line = "";
      my $i = 0;
      while ($i < $n) {
        my $ch = $c[$i];
        if ($state eq "heredoc") {
          if ($ch eq "\n") {
            my $chk = $line; $chk =~ s/^\t+// if $hd_tabs;
            $state = "none" if $chk eq $hd;
            $filtered .= (" " x length($line))."\n"; $line = "";
          } else { $line .= $ch }
          $i++; next;
        }
        if ($state eq "comment") {
          $filtered .= ($ch eq "\n" ? "\n" : " ");
          $state = "none" if $ch eq "\n";
          $i++; next;
        }
        if ($state eq "squote") {
          $state = "none" if $ch eq "\x27";
          $filtered .= ($ch eq "\n" ? "\n" : " ");
          $i++; next;
        }
        if ($state eq "dquote") {
          if ($ch eq "\\" && $i+1 < $n) { $filtered .= "  "; $i += 2; next }
          $state = "none" if $ch eq q{"};
          $filtered .= ($ch eq "\n" ? "\n" : " ");
          $i++; next;
        }
        if ($hd_pending && $ch eq "\n") {
          $filtered .= "\n"; $i++; $state = "heredoc"; $hd_pending = 0; $line = ""; next;
        }
        if ($ch eq "\x27") { $state = "squote"; $filtered .= " "; $i++; next }
        if ($ch eq q{"})   { $state = "dquote"; $filtered .= " "; $i++; next }
        if ($ch eq "\\" && $i+1 < $n) { $filtered .= "  "; $i += 2; next }
        if ($ch eq "#") {
          my $p = $filtered; $p =~ s/[ \t]+$//;
          my $last = length($p) ? substr($p, -1) : "";
          if ($last eq "" || $last =~ /[;&|(\n]/) {
            $state = "comment"; $filtered .= " "; $i++; next;
          }
          $filtered .= "#"; $i++; next;
        }
        if ($ch eq "<" && $i+1 < $n && $c[$i+1] eq "<") {
          my $j = $i+2; my $tabs = 0;
          if ($j < $n && $c[$j] eq "-") { $tabs = 1; $j++ }
          $j++ while ($j < $n && $c[$j] =~ /[ \t]/);
          my $q = "";
          if ($j < $n && ($c[$j] eq "\x27" || $c[$j] eq q{"})) { $q = $c[$j]; $j++ }
          my $delim = "";
          $delim .= $c[$j++] while ($j < $n && $c[$j] =~ /[A-Za-z0-9_]/);
          $j++ if (length($q) && $j < $n && $c[$j] eq $q);
          if (length($delim)) {
            $filtered .= (" " x ($j - $i)); $i = $j;
            $hd = $delim; $hd_tabs = $tabs; $hd_pending = 1;
            next;
          }
        }
        $filtered .= $ch; $i++;
      }
      print $filtered;
  ' 2>/dev/null
}

# bp_clear_stale_shutdown RUNS_DIR — remove a leftover terminal .shutdown marker.
# The container heartbeat (B6) writes runs/.shutdown to wind a run down when the
# host manager goes away (e.g. the host slept and the run was reaped). It is
# terminal — the orchestrator that honored it has exited — and nothing else clears
# it. An explicit (re)dispatch means the user wants to run, so a .shutdown found at
# start-up is STALE: left in place it makes the freshly-launched orchestrator hit
# the shutdown gate on tick 1 and wind down without launching anything. Clear it.
# Caller must already have established that no live orchestrator holds the marker
# (so we never yank the signal out from under a run that is honoring it). A genuine
# shutdown is re-signalled by the heartbeat if the manager is actually gone; the
# usage .paused marker is intentionally left alone (auto-resume honors its window).
bp_clear_stale_shutdown() {
  local runs="$1"
  if [ -e "$runs/.shutdown" ]; then
    rm -f "$runs/.shutdown"
    echo "bp-orchestrate: cleared a stale .shutdown marker (prior graceful-reap)"
  fi
  return 0
}

# registry_get BLUEPRINT PKG FIELD -> value or empty; refuses FIELD=status
# (s02-registry-runtime-only, DC3: runs/registry.json is runtime-only -- see
# BpState for package status. Moved to the end of the file, well clear of
# registry_merge's jq filter body, so this function's own "status" literal
# cannot be mistaken by a source scan for a status write inside that filter.)
registry_get() {
  local field="$3"
  if [ "$field" = "status" ]; then
    echo "bp-lib: registry_get: 'status' is not a registry field (runs/registry.json is runtime-only; see BpState for package status)" >&2
    return 1
  fi
  local reg; reg=$(registry_path "$1")
  [ -s "$reg" ] || { echo ""; return 0; }
  jq -r --arg pkg "$2" --arg f "$field" '.packages[$pkg][$f] // empty' "$reg"
}
