#!/usr/bin/env bash
# guard-almanac-write.sh — bug reports may only be written by almanac-bug.pl.
#
# The report state machine (open -> reviewing -> taken -> resolved|declined)
# freezes a report's body once ccpraxis picks it up, so a filer cannot rewrite
# history under a reviewer mid-read. That guarantee is worth nothing if an agent
# can just Edit the file, so this denies Edit/Write/MultiEdit/NotebookEdit
# against the reports directory and points at the verb instead. Same pattern as
# butler's guard-blueprint-write.sh, which protects blueprint.md the same way.
#
# NOT bp_hook_gate'd, deliberately. That helper requires BP_LEDGER/BP_DIR/
# BP_PROJECT_ROOT, which only bp-launch.sh exports — so a gated hook is inert
# in exactly the sessions that file bug reports: an ordinary agent working in
# some unrelated project. Shipped via this plugin's hooks.json rather than a
# host settings file, so any project with almanac enabled gets it.
#
# Reading is untouched. Fails OPEN on anything unexpected: a guard that wedges
# an unrelated project's session is worse than an unguarded edit, and the
# frozen-body sha256 catches an out-of-band write regardless (`almanac-bug.pl
# verify`) — that layer does not depend on prevention.
set -u
PAYLOAD=$(cat 2>/dev/null) || exit 0
[ -n "$PAYLOAD" ] || exit 0

# Core-perl JSON read; jq is absent on the Windows host by house rule.
FIELDS=$(printf '%s' "$PAYLOAD" | perl -MJSON::PP -0777 -ne '
    my $j = eval { JSON::PP->new->decode($_) } or exit 0;
    my $t = $j->{tool_name} // "";
    exit 0 unless $t =~ /^(Edit|Write|MultiEdit|NotebookEdit)$/;
    my $ti = $j->{tool_input} // {};
    my $p  = $ti->{file_path} // $ti->{notebook_path} // "";
    exit 0 unless length $p;
    $p =~ s{\\}{/}g;   # ONE escaped backslash: the JSON already decoded \\ to \
    print "$t\n$p\n";
' 2>/dev/null) || exit 0
[ -n "$FIELDS" ] || exit 0

TOOL=$(printf '%s' "$FIELDS" | sed -n '1p')
FPATH=$(printf '%s' "$FIELDS" | sed -n '2p')
[ -n "$FPATH" ] || exit 0

case "$FPATH" in
  */.ccpraxis-local-data/bug-reports/*) ;;
  *) exit 0 ;;
esac

ID=$(basename "$FPATH" .md)
cat >&2 <<EOF
BLOCKED: $TOOL on a bug report. These are written only through almanac-bug.pl.

  $FPATH

A report's body is FROZEN once it leaves 'open' — that is what lets a reviewer
read it without the filer rewriting it underneath them, and what makes 'taken'
mean something. A direct edit would bypass both the state machine and the
sha256 recorded at freeze time.

  While still open, revise it:
    perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl update $ID --body -

  Already reviewing/taken? It is deliberately immutable. File a follow-up:
    perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl file --title "..." --body -

  Check state:  almanac-bug.pl list        (this project)
                almanac-bug.pl verify      (digests still intact?)
EOF
exit 2
