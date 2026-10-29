#!/bin/bash
# claude-sandbox.sh — thin shim. All launcher logic lives in
# ~/.claude/ccpraxis/plugins/sandbox/scripts/launcher.pl. This file only
# locates perl + the script, then exec's it with passthrough args.
set -e

# Hard-disable MSYS2 argument-path conversion for the launcher process tree.
# MSYS2 silently mangles `podman -v HOST:CONTAINER` mount specs (splits on
# `:`, runs each side through POSIX→Windows conversion, re-joins with `;`)
# — podman then bind-mounts a `;C`-suffixed path, breaking onboarding /
# CLAUDE.md / settings.json mounts. The launcher.pl also sets this internally,
# but doing it here means the guarantee survives even if someone edits the
# perl side. See global CLAUDE.md "MSYS2 path-conversion mangles `:`-separated
# args" for the full failure mode.
export MSYS2_ARG_CONV_EXCL='*'

PERL_LAUNCHER="${HOME}/.claude/ccpraxis/plugins/sandbox/scripts/launcher.pl"
if [ ! -f "$PERL_LAUNCHER" ]; then
  echo "ERROR: launcher.pl not found at $PERL_LAUNCHER" >&2
  echo "       Re-run the ccpraxis installer (perl ~/.claude/ccpraxis/install.pl --confirm)." >&2
  exit 1
fi

exec perl "$PERL_LAUNCHER" "$@"
