#!/usr/bin/env bash
# lib.sh — shared helpers for butler hooks.
#
# Scoping mechanism: every hook calls bp_hook_gate first. The env contract
# (BP_LEDGER etc.) is exported only by bp-launch.sh into coordinator processes,
# so in the orchestrator's interactive session — and in any unrelated session —
# these hooks exit 0 immediately and cost nothing.

bp_hook_gate() {
  [ -n "${BP_LEDGER:-}" ] || exit 0
  [ -n "${BP_DIR:-}" ] || exit 0
  [ -n "${BP_PROJECT_ROOT:-}" ] || exit 0
}

bp_hook_require_jq() {
  # Fail-closed: enforcement hooks must not silently degrade.
  command -v jq >/dev/null 2>&1 || {
    echo "butler hook: jq is required but missing — blocking to avoid unenforced operation. Install jq in the container." >&2
    exit 2
  }
}

# bp_json_get PAYLOAD KEY [KEY...] -- echo the first non-empty scalar found at
# any of the dot-separated KEY paths in PAYLOAD (a JSON object). Prints nothing
# when no path resolves. Returns 2, printing nothing, when NEITHER jq nor
# perl+JSON::PP is available -- callers MUST treat that as fail-closed.
#
# WHY THIS EXISTS. jq is in the container but NOT on the Windows host (Git for
# Windows ships none), and this repo's premise is that a fresh clone runs with
# no toolchain installs -- everything is Perl, which ships with Git for Windows,
# macOS and Linux alike. The two DELIBERATELY UNGATED guards
# (guard-blueprint-write.sh, guard-git-mutations.sh -- they apply in ANY session,
# not just a bp-launch.sh coordinator) used to `command -v jq || exit 2`, so on
# the host they blocked EVERY Edit/Write and EVERY Bash call, in every session,
# forever. A guard that cannot run on the host is not a guard, it is an outage.
#
# jq stays PREFERRED when present, so container behaviour is unchanged.
#
# The payload reaches perl on stdin, never argv: a Write tool_input can be
# megabytes and would blow ARG_MAX.
bp_json_get() {
  local payload="$1"; shift
  [ "$#" -gt 0 ] || return 2

  if command -v jq >/dev/null 2>&1; then
    local expr="" k
    for k in "$@"; do
      [ -z "$expr" ] || expr="$expr // "
      expr="$expr.$k"
    done
    # rc deliberately UNCHECKED, matching the pre-existing `jq ... 2>/dev/null`
    # callers: malformed JSON yielded empty (allow) before and still does, so
    # this refactor cannot change what the container decides.
    jq -r "($expr) // empty" <<<"$payload" 2>/dev/null
    return 0
  fi

  if command -v perl >/dev/null 2>&1; then
    local out rc
    out=$(perl -MJSON::PP -e '
      binmode(STDIN, ":raw"); binmode(STDOUT, ":raw");
      my $raw = do { local $/; <STDIN> };
      my $doc = eval { JSON::PP->new->utf8->decode($raw) };
      exit 0 unless ref $doc eq "HASH";          # malformed -> empty, as jq
      for my $path (@ARGV) {
        my $v = $doc;
        for my $k (split /\./, $path) {
          $v = (ref $v eq "HASH") ? $v->{$k} : undef;
          last unless defined $v;
        }
        next if !defined $v || ref $v || $v eq "";
        utf8::encode($v);                        # chars back to UTF-8 bytes
        print $v;
        last;
      }
    ' -- "$@" <<<"$payload" 2>/dev/null)
    rc=$?
    # rc IS checked here (unlike the jq branch): the perl program exits 0 on
    # every data outcome including malformed JSON, so a non-zero rc means the
    # interpreter itself failed -- JSON::PP absent, perl broken -- which is the
    # "no parser" case and must fail closed, not silently allow.
    [ "$rc" -eq 0 ] || return 2
    printf '%s' "$out"
    return 0
  fi

  return 2
}

# match_any REL_PATH PATTERNS — colon-separated bash-glob patterns,
# '*' crosses '/', trailing '/' means prefix.
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

marker_path() { printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.active-worker"; }

ledger_lock() { printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.ledger.lock"; }

# --- graceful-stop gate (Decision #10/#18, package A4) -----------------------

# bp_active_stop_signal — which fleet stop signal (if any) is in force for THIS
# coordinator, by precedence (most directive first): a graceful-shutdown-all wins
# over a per-package force-stop wins over a usage/telemetry pause. Echoes one of
# "shutdown" | "forcestop" | "paused" | "" (empty = no stop in progress).
# I/O helper (reads runs/); keep the decision in bp_gate_verdict pure.
bp_active_stop_signal() {
  local runs="$BP_DIR/runs"
  if [ -f "$runs/.shutdown" ]; then printf '%s\n' shutdown; return 0; fi
  if [ -f "$runs/${BP_PACKAGE:-pkg}.force-stop" ]; then printf '%s\n' forcestop; return 0; fi
  if [ -f "$runs/.paused" ]; then printf '%s\n' paused; return 0; fi
  printf '%s\n' ""
}

# bp_gate_verdict TOOL PATHCLASS SIGNAL_ACTIVE -> echoes "allow" | "deny"
# Pure decision (no I/O — unit-tested as the allow-park/deny-work matrix). When a
# fleet stop signal is active, deny NEW work so the coordinator funnels to a clean
# park; always allow the ledger park-write and non-mutating tools (Decision #10).
#   TOOL          : Task | Edit | Write | MultiEdit | NotebookEdit | Bash | <read tools>
#   PATHCLASS     : for edit tools, "ledger" (BP_DIR/tmp park-write) | "worksite"
#                   (project files = new work); "-"/"" for non-path tools
#   SIGNAL_ACTIVE : 1 if any stop signal is in force, else 0
bp_gate_verdict() {
  local tool="$1" pclass="$2" sig="$3"
  [ "$sig" = 1 ] || { printf '%s\n' allow; return 0; }
  case "$tool" in
    Task)
      printf '%s\n' deny ;;                       # no new workers while stopping
    Edit|Write|MultiEdit|NotebookEdit)
      case "$pclass" in
        ledger) printf '%s\n' allow ;;            # the park-write is always permitted
        *)      printf '%s\n' deny ;;             # edits into the worksite are new work
      esac ;;
    *)
      printf '%s\n' allow ;;                       # Bash / read tools: finalize & park
  esac
}

# --- mechanical repeat-command guard (b10) -----------------------------------
#
# Five pure helpers backing repeat-guard.sh. All are sourceable with no
# filesystem or clock access apart from bp_repeat_state_path (env-vars only)
# and bp_repeat_hash (needs jq). See
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b10-repeat-command-guard-spec.md
# §2.3 for the exact contracts these implement.

# bp_repeat_verdict RUNLEN FIRED THRESHOLD ACTION -> echoes "fire" | "pass"
# PURE — no I/O. Any unparseable/missing argument -> pass (fail-open bias).
bp_repeat_verdict() {
  local runlen="$1" fired="$2" thresh="$3" action="$4"

  case "$runlen" in
    ''|*[!0-9]*) printf '%s\n' pass; return 0 ;;
  esac
  case "$thresh" in
    ''|*[!0-9]*) printf '%s\n' pass; return 0 ;;
  esac

  case "$action" in
    off)
      printf '%s\n' pass
      ;;
    deny)
      # deny is sticky: fires on every call past threshold, ignoring FIRED.
      if [ "$runlen" -ge "$thresh" ]; then printf '%s\n' fire; else printf '%s\n' pass; fi
      ;;
    nudge)
      case "$fired" in
        0|1) ;;
        *) printf '%s\n' pass; return 0 ;;
      esac
      if [ "$runlen" -ge "$thresh" ]; then
        if [ "$fired" = 1 ]; then printf '%s\n' pass; else printf '%s\n' fire; fi
      else
        printf '%s\n' pass
      fi
      ;;
    *)
      # unrecognised action -> disabled (a typo must never produce a block)
      printf '%s\n' pass
      ;;
  esac
}

# bp_repeat_runlen HASH NOW WINDOW_SECONDS (window lines on STDIN) -> "RUNLEN FIRED"
# PURE apart from reading stdin — no filesystem, no clock (NOW is a parameter).
# Walks stdin lines newest -> oldest starting from a virtual new entry
# (NOW, HASH, 0). Invalid lines (not matching TS\tHASH\t[01]) are skipped
# without breaking the run. A hash mismatch or a staleness gap (when
# WINDOW_SECONDS > 0) stops the walk.
bp_repeat_runlen() {
  local hash="$1" now="$2" winsecs="$3"
  local runlen=1 fired=0 prevts="$now"
  local -a lines=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    lines+=("$line")
  done
  local re=$'^([0-9]+)\t([^\t]+)\t([01])$'
  local i ts h f
  for (( i=${#lines[@]}-1; i>=0; i-- )); do
    line="${lines[$i]}"
    if [[ "$line" =~ $re ]]; then
      ts="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"; f="${BASH_REMATCH[3]}"
      [ "$h" = "$hash" ] || break
      if [ "$winsecs" -gt 0 ] 2>/dev/null; then
        if (( prevts - ts > winsecs )); then
          break
        fi
      fi
      runlen=$(( runlen + 1 ))
      [ "$f" = 1 ] && fired=1
      prevts="$ts"
    fi
  done
  printf '%s %s\n' "$runlen" "$fired"
}

# bp_repeat_hash (payload on STDIN) -> echoes a hash token, or nothing on failure
# Deterministic, no filesystem writes, but needs jq. Applies the RULING-2(a)
# canonicalisation program (sorted keys, compact, whitespace-scrubbed strings),
# then digests with sha1sum (else cksum). Falls back once to a key-order-only
# canonicalisation if the primary jq program fails (older jq lacking walk/gsub).
bp_repeat_hash() {
  local payload
  payload=$(cat 2>/dev/null) || return 1
  [ -n "$payload" ] || return 1

  local out
  out=$(jq -S -c '
    def scrub: walk(
      if type == "string"
      then (if length > 2048
            then (.[0:2048] | gsub("[[:space:]]+"; " ")) + "#" + (length|tostring)
            else (gsub("[[:space:]]+"; " ") | sub("^ "; "") | sub(" $"; "")) end)
      else . end);
    [ (.tool_name // ""), ((.tool_input // {}) | scrub) ]
  ' <<<"$payload" 2>/dev/null)

  if [ -z "$out" ]; then
    out=$(jq -S -c '[.tool_name // "", .tool_input // {}]' <<<"$payload" 2>/dev/null)
  fi
  [ -n "$out" ] || return 1

  local digest=""
  if command -v sha1sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$out" | sha1sum 2>/dev/null)
    digest="${digest%% *}"
  elif command -v cksum >/dev/null 2>&1; then
    digest=$(printf '%s' "$out" | cksum 2>/dev/null)
    digest="${digest%% *}"
  fi
  [ -n "$digest" ] || return 1

  digest=$(printf '%s' "$digest" | tr -cd 'A-Za-z0-9')
  [ -n "$digest" ] || return 1

  printf '%s\n' "$digest"
}

# bp_repeat_session_token RAW -> echoes sanitised token, or "nosid"
# PURE. Replaces every char outside [A-Za-z0-9_-] with '_', truncates to 16.
bp_repeat_session_token() {
  local raw="$1"
  local token
  token=$(printf '%s' "$raw" | tr -c 'A-Za-z0-9_-' '_')
  token="${token:0:16}"
  if [ -z "$token" ]; then
    printf '%s\n' nosid
  else
    printf '%s\n' "$token"
  fi
}

# bp_repeat_state_path TOKEN -> echoes "$BP_DIR/runs/${BP_PACKAGE:-pkg}.repeat-<TOKEN>.log"
# PURE — reads only env vars.
bp_repeat_state_path() {
  local token="$1"
  printf '%s\n' "$BP_DIR/runs/${BP_PACKAGE:-pkg}.repeat-${token}.log"
}

# bp_repeat_config_int RAW DEFAULT MIN -> echoes RAW if a decimal integer >= MIN, else DEFAULT
# PURE.
bp_repeat_config_int() {
  local raw="$1" def="$2" min="$3"
  case "$raw" in
    ''|*[!0-9]*) printf '%s\n' "$def"; return 0 ;;
  esac
  if [ "$raw" -ge "$min" ] 2>/dev/null; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "$def"
  fi
}

# bp_repeat_action_of RAW -> echoes "nudge" | "deny" | "off"
# PURE. Unset/empty -> nudge (default). Any other unrecognised value -> off
# (an unrecognised action disables the guard; a typo must never produce a block).
bp_repeat_action_of() {
  local raw="$1"
  case "$raw" in
    ''|nudge) printf '%s\n' nudge ;;
    deny)     printf '%s\n' deny ;;
    off)      printf '%s\n' off ;;
    *)        printf '%s\n' off ;;
  esac
}

# ---------------------------------------------------------------------------
# Path walking and drive-solo session scoping.
# ---------------------------------------------------------------------------

# bp_find_data_dir CWD -> echoes the .ccpraxis-local-data path, or nothing (rc 1).
#
# ⚠ TERMINATION IS THE WHOLE POINT OF THIS FUNCTION. It replaces two hand-rolled
# copies of
#
#     while [ -n "$d" ] && [ "$d" != "/" ]; do ... d=$(dirname "$d"); done
#
# which DID NOT TERMINATE on Windows. Claude Code puts a drive-letter cwd in the
# hook payload ("C:/Development/indocs"), and dirname walks that to "C:" and then
# returns "C:" forever — a fixed point that is neither empty nor "/". Any session
# whose cwd had no .ccpraxis-local-data ancestor therefore spun here until the
# hook timeout: 30s on every Stop, and — because mark-wakeup.sh is PreToolUse on
# Bash and Task — 15s on EVERY tool call, in EVERY unrelated project on the
# machine. Reported as an agent hanging at "running stop hooks… 1/2 · 56s".
#
# Two independent stops, because one is a promise and two is a guarantee:
#   * the loop ends at a FIXED POINT (d == prev), which covers "/", "C:", ".",
#     "//server" and anything else dirname converges on, and
#   * a hard depth cap, so even a pathological dirname cannot spin.
bp_find_data_dir() {
  local start="${1:-}" d prev n
  if [ -n "${CCPRAXIS_DATA_DIR:-}" ]; then
    printf '%s' "$CCPRAXIS_DATA_DIR"
    return 0
  fi
  [ -n "$start" ] || return 1
  d=$start; prev=''; n=0
  while [ -n "$d" ] && [ "$d" != "$prev" ] && [ "$n" -lt 64 ]; do
    if [ -d "$d/.ccpraxis-local-data" ]; then
      printf '%s' "$d/.ccpraxis-local-data"
      return 0
    fi
    prev=$d
    d=$(dirname "$d" 2>/dev/null) || return 1
    n=$((n + 1))
  done
  return 1
}

# bp_registry_root -> echoes the base path every machine-level registry
# (drive-solo, reporter, continuity) resolves under: override, else $HOME,
# else $USERPROFILE, else UNRESOLVABLE (rc 1, nothing on stdout). $PWD is
# never a fallback here — a registry keyed on the current directory is not a
# registry, because a hook's cwd is not stable across a session (separate
# process spawns; a driver may `cd` mid-run). This is the ONLY place this
# order is spelled out; every registry-specific resolver below (and
# bp_continuity_active_dir) calls this rather than restating it.
# d04-registry-path-one-rule: extracted verbatim from
# bp_continuity_active_dir's own inline HOME/USERPROFILE fallback (g01),
# not reinvented.
bp_registry_root() {
  local base="${HOME:-}"
  [ -n "$base" ] || base="${USERPROFILE:-}"
  [ -n "$base" ] || return 1
  printf '%s' "$base"
  return 0
}

# bp_drive_active_dir -> echoes the machine-level registry of ACTIVE drive-solo
# driver sessions. One file per session, named by session_id.
#
# WHY A REGISTRY, replacing "is there a .drive-solo/order.json above my cwd".
# That question is wrong twice over. It says YES for every session in a tree
# that has ever run drive-solo — order.json was never deleted when a run
# finished, so two settled runs on this machine armed the Stop gate for every
# future session in those trees, forever. And it says yes for sessions that are
# not the driver at all: a second terminal in the same project inherited the
# gate. The registry answers the question actually being asked — "is THIS
# session driving?" — and answers it in one stat().
#
# d04-registry-path-one-rule: dropped the old inline HOME-or-cwd fallback in
# favor of bp_registry_root (override -> HOME -> USERPROFILE -> rc 1, no
# current-directory guess).
bp_drive_active_dir() {
  if [ -n "${CCPRAXIS_DRIVE_ACTIVE_DIR:-}" ]; then
    printf '%s' "$CCPRAXIS_DRIVE_ACTIVE_DIR"
    return 0
  fi
  local base
  base=$(bp_registry_root) || return 1
  printf '%s' "$base/.claude/ccpraxis/.drive-solo-active"
  return 0
}

# bp_reporter_active_dir -> echoes the machine-level registry of ACTIVE
# reporter sessions. Mirrors bp_drive_active_dir exactly; own override var.
# d04-registry-path-one-rule: NEW -- the reporter registry previously had no
# shared resolver at all, just three literal inline HOME-or-cwd copies
# (mark-wakeup.sh's write site, gate-drive-loop.sh's two read sites).
bp_reporter_active_dir() {
  if [ -n "${CCPRAXIS_REPORTER_ACTIVE_DIR:-}" ]; then
    printf '%s' "$CCPRAXIS_REPORTER_ACTIVE_DIR"
    return 0
  fi
  local base
  base=$(bp_registry_root) || return 1
  printf '%s' "$base/.claude/ccpraxis/.reporter-active"
  return 0
}

# bp_drive_any_active -> rc 0 if ANY driver session is registered.
# The cheap pre-check: when nothing is driving anywhere (the overwhelmingly
# common case) a hook can return before parsing its payload, so an unrelated
# session pays two stats and spawns nothing at all.
# bp_drive_ttl_hours -> the staleness limit, sanitised.
bp_drive_ttl_hours() {
  local h="${CCPRAXIS_DRIVE_TTL_H:-12}"
  case "$h" in ''|*[!0-9]*) h=12 ;; esac
  [ "$h" -gt 0 ] 2>/dev/null || h=12
  printf '%s' "$h"
}

# bp_drive_any_active -> rc 0 if ANY driver session is registered, AFTER reaping
# expired markers.
#
# THE REAP HAS TO LIVE HERE, not in the per-session TTL check. That check only
# ever runs for the session whose id MATCHES a marker — and a dead driver never
# comes back to match its own, so its marker was immortal. Measured before this:
# three markers 55h old survived three consecutive stops by another session and
# were still there afterwards.
#
# It never hung anything (an unmatched marker is only read by the session that
# owns it), but it defeated the entire point of the design: one leaked marker
# keeps this function true forever, so every session on the machine goes on to
# parse its payload and spawn a JSON reader on every stop instead of returning
# after two stats. A registry that only grows is a slow reintroduction of the
# bug this replaced.
#
# Pure stat + rm, no subprocess, over a directory that holds one entry per
# CONCURRENT driver — single digits in the worst realistic case.
bp_drive_any_active() {
  local dir now ttl mt f live=1
  dir=$(bp_drive_active_dir) || return 1
  [ -d "$dir" ] || return 1

  now=$(date +%s 2>/dev/null || echo 0)
  ttl=$(bp_drive_ttl_hours)

  # Positional params are function-scoped in bash, so this cannot disturb the
  # calling hook. "${1:-}" rather than "$1": every hook runs under `set -u`,
  # and with nullglob enabled anywhere in the environment an unmatched glob
  # leaves $1 UNSET, which under set -u is a fatal "unbound variable" — the
  # hook would die instead of returning "nothing active". Verified: with
  # `shopt -s nullglob; set -u`, the bare "$1" form aborts.
  set -- "$dir"/*
  [ -e "${1:-}" ] || return 1

  live=0
  for f in "$@"; do
    [ -f "$f" ] || continue
    if [ "$now" -gt 0 ]; then
      mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
      if [ "$mt" -gt 0 ] && [ $(( (now - mt) / 3600 )) -ge "$ttl" ]; then
        rm -f "$f" 2>/dev/null
        continue
      fi
    fi
    live=$((live + 1))
  done

  [ "$live" -gt 0 ] || return 1
  return 0
}

# bp_drive_marker SESSION_ID -> echoes the marker path for that session.
# Session ids come from the hook payload, so refuse anything with a path
# separator or traversal in it rather than letting it address another directory.
bp_drive_marker() {
  local sid="${1:-}" dir
  [ -n "$sid" ] || return 1
  case "$sid" in
    */*|*\*|.|..|*..*) return 1 ;;
  esac
  dir=$(bp_drive_active_dir) || return 1
  printf '%s/%s' "$dir" "$sid"
  return 0
}

# ---------------------------------------------------------------------------
# g01-explicit-continuity-arming: a THIRD, INDEPENDENT registry, sibling to
# .drive-solo-active/.reporter-active — explicit arm/disarm for a session
# doing unattended work with no blueprint, no drive-solo, no reporter. See
# specs/g01-explicit-continuity-arming-spec.md SS2.3.
# ---------------------------------------------------------------------------

# bp_continuity_active_dir -> echoes the machine-level registry of ARMED
# continuity sessions. One flat dir; primary markers named by session id,
# companions dot-suffixed (see bp_continuity_marker).
#
# ── THE SINGLE PATH-RESOLUTION RULE (fix-batch F1, spec SS2.6/AC-13) ────────
# Three components resolve this same registry path: this function (bash,
# gate-continuity.sh's caller), bp-continuity.pl's continuity_active_dir
# (perl, the arm/disarm/status CLI), and scripts/statusline.pl's own inline
# copy (perl, standalone, cannot require this file). They previously diverged
# on what "$HOME is unset" means (`$PWD`, `$USERPROFILE`, and `.`
# respectively) — three plausible-but-different guesses that could silently
# disagree about whether a session is watched, which is the worst possible
# failure for a feature whose entire point is "know that you are being
# watched". ALL THREE now follow this exact order and must not drift again:
#   1. CCPRAXIS_CONTINUITY_ACTIVE_DIR, if set and non-empty — wins outright.
#   2. else $HOME, if set and non-empty.
#   3. else $USERPROFILE (the Windows fallback), if set and non-empty.
#   4. else: NO resolvable directory. This function returns 1 with NOTHING
#      on stdout — it refuses to guess (no $PWD, no '.'). The two WRITE
#      paths (bp-continuity.pl arm/disarm/status) must fail LOUDLY on this
#      (STATUS: error, exit 1) rather than silently write/read a marker
#      under an unpredictable path. The two READ paths that must never hard
#      -fail a Stop/statusline (this function's callers in
#      bp_continuity_marker/bp_continuity_any_active, and
#      scripts/statusline.pl's badge) instead FAIL SAFE: "unresolvable"
#      means "treat as nothing armed" (gate never blocks; badge never shows
#      WATCHED). This is not a fourth divergent guess — it is consistent
#      with rule 4's write-side refusal: if the directory could never be
#      resolved, arm() could never have written a marker there either, so
#      there is never a live marker for these fail-safe reads to miss.
bp_continuity_active_dir() {
  if [ -n "${CCPRAXIS_CONTINUITY_ACTIVE_DIR:-}" ]; then
    printf '%s' "$CCPRAXIS_CONTINUITY_ACTIVE_DIR"
    return 0
  fi
  local base
  base=$(bp_registry_root) || return 1
  printf '%s' "$base/.claude/ccpraxis/.continuity-active"
  return 0
}

# bp_continuity_ttl_hours -> the staleness limit, sanitised exactly like
# bp_drive_ttl_hours.
bp_continuity_ttl_hours() {
  local h="${CCPRAXIS_CONTINUITY_TTL_H:-12}"
  case "$h" in ''|*[!0-9]*) h=12 ;; esac
  [ "$h" -gt 0 ] 2>/dev/null || h=12
  printf '%s' "$h"
}

# bp_continuity_marker SESSION_ID -> echoes the primary marker path.
# Refuses everything bp_drive_marker refuses, PLUS a literal '.' anywhere in
# the id — companions are dot-suffixed off the primary marker's own path, so
# a dotted session id would be indistinguishable from a companion file by
# bp_continuity_any_active's own basename-has-no-dot sweep discrimination.
# PLUS (fix-batch F3): a literal '\' anywhere in the id. On this project's
# Windows/Git-for-Windows host, both bash coreutils and this host's Perl
# treat '\' inside a path string as a directory separator, not a literal
# character — an id like 'evilsub\evilfile' resolves ONE LEVEL NESTED under
# the registry root, which bp_continuity_any_active's top-level-only `"$dir"/*`
# sweep never descends into: a marker placed that way would be PERMANENTLY
# INVISIBLE to the owner-independent reap, exactly the "arming is bounded"
# guarantee (done-criterion 2) this package exists to provide. Matches
# scripts/statusline.pl's own read-side sid check, which already excluded
# '\' for the same reason (red-team MEDIUM-1).
bp_continuity_marker() {
  local sid="${1:-}" dir
  [ -n "$sid" ] || return 1
  case "$sid" in
    */*|*\\*|*\**|.|..|*..*|*.*) return 1 ;;
  esac
  dir=$(bp_continuity_active_dir) || return 1
  printf '%s/%s' "$dir" "$sid"
  return 0
}

# bp_continuity_any_active -> rc 0 iff >=1 LIVE marker after reaping every
# expired primary marker (and its companions), INLINE, regardless of which
# session is doing the sweeping.
#
# THIS IS THE REAP POINT — owner-independent by construction. Mirrors
# bp_drive_any_active's own reasoning (lib.sh:395-412 above) for the identical
# historical defect: a per-session TTL check that only ever runs for the
# session whose id matches a marker leaves a dead session's marker immortal,
# because that session never returns to reap its own. Sweeping the WHOLE
# directory on every caller's behalf, unconditionally, is what closes it.
bp_continuity_any_active() {
  local dir now ttl mt f base live=1
  dir=$(bp_continuity_active_dir) || return 1
  [ -d "$dir" ] || return 1

  now=$(date +%s 2>/dev/null || echo 0)
  ttl=$(bp_continuity_ttl_hours)

  # See bp_drive_any_active's own comment on "${1:-}" under set -u + nullglob.
  set -- "$dir"/*
  [ -e "${1:-}" ] || return 1

  live=0
  for f in "$@"; do
    [ -f "$f" ] || continue
    base=$(basename "$f")
    case "$base" in *.*) continue ;; esac   # companion file, not a primary marker
    if [ "$now" -gt 0 ]; then
      mt=$(stat -c %Y "$f" 2>/dev/null || echo 0)
      if [ "$mt" -gt 0 ] && [ $(( (now - mt) / 3600 )) -ge "$ttl" ]; then
        rm -f "$f" "$f.wakeup-pending" "$f.stop-blocks" "$f.stop-ok" 2>/dev/null
        continue
      fi
    fi
    live=$((live + 1))
  done

  [ "$live" -gt 0 ] || return 1
  return 0
}
