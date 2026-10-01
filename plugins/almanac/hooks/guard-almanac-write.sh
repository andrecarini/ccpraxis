#!/usr/bin/env bash
# guard-almanac-write.sh — every almanac-owned store is script-owned.
#
# TWO THINGS THIS HOOK PROTECTS, BY PATH SHAPE, NOT BY AN ENUMERATED LIST:
#
#   1. bug reports          <project>/.ccpraxis-local-data/bug-reports/<id>.md
#   2. almanac record stores <project>/.ccpraxis-local-data/almanac/<type>/...
#                             <home>/.claude/claude-code-vault/almanac/<type>/...
#
# Both have a state machine or a compare-and-swap lock that a direct Edit/Write
# would bypass outright, so this denies Edit/Write/MultiEdit/NotebookEdit
# against either shape and points at the script that owns it instead. Bug
# reports freeze once picked up (open -> triaging -> taken -> resolved |
# declined); stores are protected by Almanac::Lock plus a sealed digest, and
# almanac-bug.pl verify reports either kind of out-of-band write.
#
# NOT bp_hook_gate'd, deliberately. That helper requires BP_LEDGER/BP_DIR/
# BP_PROJECT_ROOT, which only bp-launch.sh exports — so a gated hook is inert
# in exactly the sessions that hit this most: an ordinary agent working in
# some unrelated project. Shipped via this plugin's hooks.json rather than a
# host settings file, so any project with almanac enabled gets it.
#
# Reading is untouched. Fails OPEN on anything unexpected — empty/broken
# input, a payload with no path, a perl that dies at startup — because a
# guard that wedges an unrelated project's session is worse than an
# unguarded edit; the sealed digest (almanac-bug.pl verify) still detects the
# out-of-band write regardless. That layer does not depend on prevention.
#
# COST DISCIPLINE (DC6, budget 50ms median). Every Edit/Write in every
# session pays for this hook, so it is built in two stages: a bash-only
# prefilter that spawns NOTHING (no cat, no perl, no jq) for the overwhelming
# majority of edits that touch neither root, and a single perl process (core
# JSON::PP only) for the rest. harness-facts (g) measured a bash spawn at
# ~30.6ms and one perl parse at a further ~46-47ms — paying the perl cost on
# every call would blow the budget outright, which is why the prefilter must
# complete with no process spawned at all.
#
# FIX-BATCH (post-review 09): the perl->bash field separator is \x1f, not a
# tab -- tab is IFS *whitespace*, so `IFS=$'\t' read` collapsed empty fields
# (every bug denial's TYPE is empty) and shifted every field after it. \x1f
# is never IFS whitespace, so an empty field stays a real, distinct field.
# The classifier is also segment-based now (not one big regex against the
# joined path), so it can: (a) resolve a relative path against the payload's
# own `cwd` before classifying; (b) strip a Windows trailing dot/space from
# any non-`.`/`..` segment, matching what CreateFileW itself does; (c) treat
# an 8.3 short-name segment (`CCPRAX~1`) as equal to the long literal it is
# a legal abbreviation of, using the same basis test
# BpHook::WriteGuards::_seg_eq_base uses (first up-to-6 alphanumerics of the
# long name, folded) -- no filesystem access, so this holds even for a path
# that is never opened.
set -u

# Stage 0: read the payload with a bash BUILTIN — no cat, no $(...), no pipe,
# no external command. -N is the buffered form, required on a non-tty. Any
# read status (timeout, short read, EOF) is tolerated; an empty payload just
# fails open below.
IFS= read -r -N 8388608 -t 10 P
[ -n "${P:-}" ] || exit 0

# Stage 1: the prefilter. A case-insensitive bash builtin match for either
# root's literal substring, OR the 8.3 short-name PREFIX either store
# segment can shorten to (S2, post-review 09 -- corrected). `.ccpraxis-local-
# data` -> `CCPRAX~n`, `claude-code-vault` -> `CLAUDE~n` (Windows 8.3 names
# take the first up-to-6 alphanumerics of the long name, then `~`, then a
# digit). A bare `~` was tried first and rejected: ANDR~1 (the shortened
# form of this very host's own username) is itself `~digit`, and it sits in
# the path of every session scratchpad and %TEMP% file, so that trigger
# spawned perl on ordinary, harmless paths and lost the zero-spawn-on-a-miss
# property for a common case. A short name on some OTHER ancestor segment
# (ANDR~1 on the way to a claude-code-vault that is spelled out in full)
# still matches via the plain literal substring above -- only the STORE
# segment's OWN shortening needs its own trigger. None present -> exit 0, no
# process spawned.
shopt -s nocasematch
case "$P" in
  *ccpraxis-local-data*|*claude-code-vault*|*'ccprax~'*|*'claude~'*) ;;
  *) exit 0 ;;
esac

# Stage 2: the slow path. One perl process, core JSON::PP only. It prints
# exactly one line, "DENY<0x1f>...", on a match, and nothing otherwise —
# including on a decode failure, an unrecognised tool, an empty path, or a
# perl that fails to start at all (a broken PERL5OPT). Its stderr is
# discarded; a crash here must never look like a deny.
OUT=$(printf "%s" "$P" | perl -MJSON::PP -e '
    local $/;
    my $raw = <STDIN>;
    my $j = eval { JSON::PP->new->decode($raw) };
    exit 0 unless $j;
    my $t = $j->{tool_name} // "";
    exit 0 unless $t =~ /^(Edit|Write|MultiEdit|NotebookEdit)$/;
    my $ti = $j->{tool_input} // {};
    my $p = $ti->{file_path} // $ti->{notebook_path} // "";
    exit 0 unless length $p;

    # S3 (relative paths): resolve against the payloads own cwd BEFORE
    # normalising, when the path is neither rooted (/, \) nor drive-qualified
    # (X:...).
    (my $check = $p) =~ s{\\}{/}g;
    unless ($check =~ m{^/} || $check =~ m{^[A-Za-z]:}) {
        my $cwd = $j->{cwd} // "";
        if (length $cwd) {
            (my $cwdc = $cwd) =~ s{\\}{/}g;
            $cwdc =~ s{/+\z}{};
            $p = "$cwdc/$p";
        }
    }

    # normalize_segments($raw_path) -> ($drive, $prefix, @segments)
    #
    # \ -> /; a run of / collapses to one, except a leading // which is kept
    # as //; ./ segments vanish; a trailing dot/space run on any segment
    # OTHER than "." or ".." is stripped first (S1 -- what CreateFileW does,
    # so the guard sees the same name the filesystem will); ../ segments are
    # then resolved lexically against whatever real segment precedes them.
    sub normalize_segments {
        my ($raw_p) = @_;
        (my $q = $raw_p) =~ s{\\}{/}g;
        my $lead2 = ($q =~ m{^//}) ? 1 : 0;
        my $drive = "";
        if ($q =~ s{^([A-Za-z]:)}{}) { $drive = $1; }
        my $rooted = ($q =~ m{^/}) ? 1 : 0;
        (my $body = $q) =~ s{^/+}{};
        $body =~ s{/+}{/}g;
        my @raw_parts = split(m{/}, $body);
        my @out;
        for my $seg (@raw_parts) {
            next if $seg eq "";
            if ($seg ne "." && $seg ne "..") {
                $seg =~ s/[. ]+\z//;
                next if $seg eq "";
            }
            if ($seg eq ".") {
                next;
            } elsif ($seg eq "..") {
                if (@out && $out[-1] ne "..") { pop @out } else { push @out, $seg }
            } else {
                push @out, $seg;
            }
        }
        my $prefix = $lead2 ? "//" : ($rooted ? "/" : "");
        return ($drive, $prefix, @out);
    }

    # seg_match($segment, $literal_target) -> 0|1 -- exact (case-insensitive)
    # match, OR an 8.3 short-name basis match (S2): a short segment matches
    # iff its stem (before ~N) equals the first up-to-6 alphanumeric
    # characters of the target, both folded and stripped of everything else.
    # Pure string comparison -- no filesystem access, so this holds for a
    # path that is never opened.
    sub seg_match {
        my ($seg, $target) = @_;
        return 1 if lc($seg) eq lc($target);
        if ($seg =~ /^[^~\/]{1,6}~[0-9]+(?:\.[^.\/]{0,3})?\z/) {
            (my $stem = $seg) =~ s/~.*\z//s;
            my $stem_f = lc($stem);  $stem_f  =~ s/[^a-z0-9]//g;
            my $basis_f = lc($target); $basis_f =~ s/[^a-z0-9]//g;
            my $want = (length($basis_f) >= 6) ? substr($basis_f, 0, 6) : $basis_f;
            return (length($stem_f) && $stem_f eq $want) ? 1 : 0;
        }
        return 0;
    }

    sub match_seq {
        my ($segs, $i, @targets) = @_;
        for my $k (0 .. $#targets) {
            return 0 unless defined $segs->[$i + $k];
            return 0 unless seg_match($segs->[$i + $k], $targets[$k]);
        }
        return 1;
    }

    my ($drive, $prefix, @segs) = normalize_segments($p);
    my $norm = "$drive$prefix" . join("/", @segs);
    exit 0 unless @segs;

    my ($kind, $rest_start);
    for my $i (0 .. $#segs) {
        last if $i + 2 > $#segs;   # need the 2-segment prefix plus >=1 more
        if (match_seq(\@segs, $i, ".ccpraxis-local-data", "bug-reports")) {
            $kind = "bug"; $rest_start = $i + 2; last;
        }
    }
    if (!defined $kind) {
        for my $i (0 .. $#segs) {
            last if $i + 2 > $#segs;
            if (match_seq(\@segs, $i, ".ccpraxis-local-data", "almanac")) {
                $kind = "store"; $rest_start = $i + 2; last;
            }
        }
    }
    if (!defined $kind) {
        for my $i (0 .. $#segs) {
            last if $i + 3 > $#segs;
            if (match_seq(\@segs, $i, ".claude", "claude-code-vault", "almanac")) {
                $kind = "store"; $rest_start = $i + 3; last;
            }
        }
    }
    exit 0 unless defined $kind;

    my @rest = @segs[$rest_start .. $#segs];
    my $type = "";
    if ($kind eq "store" && @rest >= 2) {
        $type = $rest[0];
    }
    my $base = $segs[-1];
    my $id = "";
    if ($base =~ /^(.+)\.md\z/i) {
        $id = $1;
    }

    print "DENY\x1f$kind\x1f$t\x1f$type\x1f$id\x1f$norm\n";
' 2>/dev/null)

case "$OUT" in
  DENY$'\x1f'*) ;;
  *) exit 0 ;;
esac

IFS=$'\x1f' read -r _TAG KIND TOOL TYPE ID NPATH <<< "$OUT"

if [ "$KIND" = "bug" ]; then
  cat >&2 <<EOF
BLOCKED: $TOOL on a bug report. These are written only through almanac-bug.pl.

  $NPATH

A report's body is FROZEN once it leaves 'open' — that is what lets a reviewer read it without the filer rewriting it underneath them, and what makes 'taken' mean something. A direct edit would bypass both the state machine and the sha256 recorded at freeze time.

  While still open, revise it:
    perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl update $ID --body -

  Already triaging/taken? It is deliberately immutable. File a follow-up:
    perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl file --title "..." --body -

  Check state:  almanac-bug.pl list        (this project)
                almanac-bug.pl verify      (digests still intact?)
EOF
  exit 2
fi

# kind == store — the verb map, keyed by lc(type). ${TYPE,,} is a bash
# builtin (no extra process on the deny path, unlike a printf|tr pipeline).
TYPE_LC=${TYPE,,}
case "$TYPE_LC" in
  todo)        SCRIPT="almanac-todo.pl";     VERBS="create | edit | complete | reopen | delete" ;;
  note)        SCRIPT="almanac-note.pl";     VERBS="create | edit | promote | delete" ;;
  task)        SCRIPT="almanac-task.pl";     VERBS="add | edit | status | move-first | move-last | reorder" ;;
  task-focus)  SCRIPT="almanac-task.pl";     VERBS="focus | unfocus" ;;
  decision)    SCRIPT="almanac-decision.pl"; VERBS="file | answer" ;;
  "")
    SCRIPT="almanac-<type>.pl"
    VERBS="(the script for the store you meant)"
    ;;
  *)
    SCRIPT="almanac-$TYPE_LC.pl"
    VERBS="(no verb map for this type -- the script that owns '$TYPE_LC' by naming convention; run it without arguments for its verbs)"
    ;;
esac

if [ -n "$TYPE" ]; then
  TYPE_LINE="  store type: $TYPE"
else
  TYPE_LINE="  store type: (none -- a file directly under the almanac root)"
fi

{
  echo "BLOCKED: $TOOL on an almanac record store. Almanac records are written only through their scripts."
  echo
  echo "  $NPATH"
  echo
  echo "$TYPE_LINE"
  if [ -n "$ID" ]; then
    echo "  record id:  $ID"
  fi
  echo "  use:        perl <ccpraxis>/plugins/almanac/scripts/$SCRIPT  $VERBS"
  echo
  echo "A direct edit bypasses the store's lock, its compare-and-swap and its seal. Any write that did not go"
  echo "through the script is reported by:  perl <ccpraxis>/plugins/almanac/scripts/almanac-bug.pl verify"
} >&2

exit 2
