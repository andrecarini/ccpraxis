#!/usr/bin/env bash
# Long-running empirical test: spin up claude in a container with the
# current bind-mount architecture, drive it with periodic keystrokes via
# a socat pty bridge for 8 minutes, sample state every 15 s, and confirm
# claude stayed alive + processing throughout. This is the closest
# reproduction of the user-observed "freeze after ~60s" symptom, scaled
# up to catch slower-onset variants.
#
# USAGE:
#   bash tests/manual/longrun-freeze-check.sh [PROJECT_DIR]
#
#   PROJECT_DIR — optional path to a project directory whose .claude-data/
#   and .claude-data/.claude.json the test will bind into the container,
#   exactly as the launcher does in production. Defaults to a fresh scratch
#   project created under $HOME/.cache/sandbox-tests/ (and removed on exit).
#
# The mount shape mirrors the launcher exactly:
#   .claude-data/            → /root/.claude            (bulk RW bind)
#   .claude-data/.claude.json → /root/.claude.json      (single-file RW bind)
#
# DURATION env var (default 480 s) controls how long the test runs.
# Output (per-sample log + final PASS/FAIL) goes to stdout; redirect as
# needed. Exit code: 0 = PASS, 1 = FAIL.
#
# NOTE: This test is MANUAL and DESTRUCTIVE — it creates a real container
# against your local runtime. It never removes project data, but the
# temporary scratch project (if created) is cleaned up on exit. The
# container is always removed on exit.

set -u
export MSYS2_ARG_CONV_EXCL='*'

DURATION=${DURATION:-480}
INTERVAL=15

# ── Runtime detection (mirrors launcher.pl _detect_container_cli) ────────────
# On Windows probe .exe names first to avoid extensionless-shim hijacks.
_is_windows() { [[ "$(uname -s)" =~ ^(MSYS|MINGW|CYGWIN) ]] || [[ "${OS:-}" == "Windows_NT" ]]; }

detect_runtime() {
    local candidates
    if _is_windows; then
        candidates=(docker.exe docker podman.exe podman)
    else
        candidates=(docker podman)
    fi
    for rt in "${candidates[@]}"; do
        if command -v "$rt" > /dev/null 2>&1; then
            echo "$rt"
            return 0
        fi
    done
    return 1
}

RUNTIME=$(detect_runtime) || {
    echo "ERROR: no container runtime found (docker / podman)." >&2
    echo "Start Docker Desktop or run 'podman machine start', then retry." >&2
    exit 1
}

# ── Project dir & mount paths ────────────────────────────────────────────────
SCRATCH_CREATED=0
PROJECT_DIR="${1:-}"

if [ -z "$PROJECT_DIR" ]; then
    BASE="${HOME:-$USERPROFILE}/.cache/sandbox-tests"
    mkdir -p "$BASE"
    PROJECT_DIR=$(mktemp -d "$BASE/longrun-XXXXXX")
    SCRATCH_CREATED=1
    echo "Created scratch project: $PROJECT_DIR"
fi

# Ensure .claude-data/ and the single-file bind target exist so podman
# doesn't auto-create a directory instead of a file bind.
mkdir -p "$PROJECT_DIR/.claude-data"
if [ ! -f "$PROJECT_DIR/.claude-data/.claude.json" ]; then
    echo '{}' > "$PROJECT_DIR/.claude-data/.claude.json"
fi

TC="claude-longrun-$$"

cleanup() {
    "$RUNTIME" rm -f "$TC" > /dev/null 2>&1 || true
    if [ "$SCRATCH_CREATED" -eq 1 ] && [ -n "$PROJECT_DIR" ]; then
        rm -rf "$PROJECT_DIR"
        echo "Removed scratch project: $PROJECT_DIR"
    fi
}
trap cleanup EXIT INT TERM

echo "=== Long-running claude freeze check ==="
echo "Runtime:   $RUNTIME"
echo "Container: $TC"
echo "Project:   $PROJECT_DIR"
echo "Duration:  ${DURATION}s"
echo "Started:   $(date)"
echo

# ── Create the container with the launcher's real mount shape ────────────────
"$RUNTIME" run -dit --name "$TC" \
    -v "${PROJECT_DIR}/.claude-data:/root/.claude" \
    -v "${PROJECT_DIR}/.claude-data/.claude.json:/root/.claude.json" \
    -e CLAUDE_SANDBOX=1 \
    --entrypoint /bin/bash \
    claude-sandbox:latest -c "sleep $((DURATION + 120))" > /dev/null

echo "Container started."

# ── Spawn claude inside the container attached to a pty managed by socat ─────
# /tmp/cl-pty is the master side — write to it to send keystrokes to claude.
"$RUNTIME" exec -d "$TC" bash -c '
    rm -f /tmp/cl-pty /tmp/cl-out
    socat -d -d \
        "PTY,raw,echo=0,link=/tmp/cl-pty" \
        "EXEC:claude --dangerously-skip-permissions,pty,raw,echo=0,stderr" \
        > /tmp/cl-out 2>&1 &
    echo $! > /tmp/cl-socat.pid
'

# Give claude time to start up
sleep 12

INITIAL_ATIME=$("$RUNTIME" exec "$TC" sh -c 'stat -L -c %X /tmp/cl-pty 2>/dev/null || echo 0')
echo "Initial pty atime: $INITIAL_ATIME"
echo

DEADLINE=$(( $(date +%s) + DURATION ))
ITER=0
INITIAL_CT=
LAST_CT=
ALIVE_SAMPLES=0
DEAD_SAMPLES=0
CT_PROGRESS=0   # samples where ictxsw advanced vs the previous sample

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
    ITER=$(( ITER + 1 ))
    TS=$(date +%H:%M:%S)

    # Probe claude state. nonvoluntary_ctxt_switches grows whenever claude
    # does any work (read, write, syscall, etc.) — more reliable than pty
    # atime since the slave side may not update atime consistently.
    STATE=$("$RUNTIME" exec "$TC" sh -c '
        PID=$(pgrep -x claude | head -1)
        if [ -z "$PID" ]; then echo "DEAD"; exit; fi
        WCHAN=$(cat /proc/$PID/wchan 2>/dev/null || echo unknown)
        CT=$(awk "/^nonvoluntary_ctxt_switches:/{print \$2}" /proc/$PID/status 2>/dev/null || echo 0)
        echo "ALIVE wchan=$WCHAN ictxsw=$CT"
    ' 2>&1)

    echo "[$TS iter=$ITER] $STATE"

    if [[ "$STATE" == DEAD* ]]; then
        DEAD_SAMPLES=$(( DEAD_SAMPLES + 1 ))
    else
        ALIVE_SAMPLES=$(( ALIVE_SAMPLES + 1 ))
        CUR_CT=$(echo "$STATE" | sed -n 's/.*ictxsw=\([0-9]*\).*/\1/p')
        [ -z "$INITIAL_CT" ] && INITIAL_CT=$CUR_CT
        if [ -n "$CUR_CT" ] && [ -n "$LAST_CT" ] && [ "$CUR_CT" -gt "$LAST_CT" ]; then
            CT_PROGRESS=$(( CT_PROGRESS + 1 ))
        fi
        LAST_CT=$CUR_CT
    fi

    # Send a benign keystroke every 60 s so claude has something to react
    # to. Even if it discards the input, the read-side wakeup increments
    # ictxsw — proving claude is alive and processing.
    if [ $(( ITER % 4 )) -eq 0 ]; then
        "$RUNTIME" exec "$TC" sh -c "printf 'h\n' > /tmp/cl-pty" 2>/dev/null || true
        echo "  -> sent keystroke"
    fi

    sleep $INTERVAL
done

CT_DELTA=0
[ -n "$INITIAL_CT" ] && [ -n "$LAST_CT" ] && CT_DELTA=$(( LAST_CT - INITIAL_CT ))

echo
echo "=== Summary ==="
echo "Alive samples:    $ALIVE_SAMPLES"
echo "Dead samples:     $DEAD_SAMPLES"
echo "Initial ictxsw:   $INITIAL_CT"
echo "Final ictxsw:     $LAST_CT  (delta: $CT_DELTA)"
echo "Samples with progress: $CT_PROGRESS / $ALIVE_SAMPLES"
echo "Finished:         $(date)"

if [ "$DEAD_SAMPLES" -gt 0 ]; then
    echo
    echo "VERDICT: FAIL — claude died at some point"
    exit 1
fi
# Threshold: at least 3 samples must show progress (claude was working
# beyond just sitting idle in epoll). Lower bar than "responsive every
# sample" because claude idles between keystrokes — but a frozen claude
# wouldn't progress at all.
if [ "$CT_PROGRESS" -lt 3 ]; then
    echo
    echo "VERDICT: FAIL — claude alive but ictxsw barely advanced (likely wedged)"
    exit 1
fi
echo
echo "VERDICT: PASS — claude stayed alive AND active (ictxsw grew $CT_DELTA over $ALIVE_SAMPLES samples)"
exit 0
