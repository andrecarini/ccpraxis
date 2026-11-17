#!/usr/bin/env bash
# guard-git-mutations.sh -- denies git working-tree/history mutations (stash,
# checkout/switch/restore/reset/clean). Logic in
# BpHook/Guards/GuardGitMutations.pm; contract in docs/hook-architecture.md.
# The text prefilter lists every letter case of "git": macOS and Windows
# resolve a command name case-insensitively, so "GIT stash" runs git there,
# and a case-sensitive "git" prefilter let it pass before perl ever looked.
d=${BASH_SOURCE[0]%/*} ; [ -f "$d/run-hook.sh" ] || d=${d%/*}
[ -f "$d/run-hook.sh" ] || exit 0
g=text:git,text:Git,text:gIt,text:giT,text:GIt,text:GiT,text:gIT,text:GIT
for a in "$@"; do
  if [ "$a" = "--only-during-butler-run" ]; then
    exec bash "$d/run-hook.sh" Guards::GuardGitMutations --pre "$g" --pre ledger,armed -- "$@"
  fi
done
exec bash "$d/run-hook.sh" Guards::GuardGitMutations --pre "$g" -- "$@"
