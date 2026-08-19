#!/usr/bin/env perl
# 142-reporter-registration.t — g03-reporter-stop-gate, PILLAR 1: registration,
# and its disjointness from the driver's own trigger.
#
# Spec: specs/g03-reporter-stop-gate-spec.md §1.2 (Decision 2 -> DC1), §2.1
# (mark-wakeup.sh registration block), §4 AC1/AC7.
#
# THE CLAIM UNDER TEST. A reporter session registers on the EXACT Bash command
# `bp-watch.pl --arm ... --blueprint <bp>` (Mode B) -- never on any looser
# signal, never on a Read/Grep about bp-watch.pl, never on a Bash command that
# merely NAMES the string without executing it. This is provably disjoint from
# the driver's own `bp-watch.pl --arm --package <bp>/<pkg>` shape because
# bp-watch.pl's own arg parser refuses --package and --blueprint together --
# asserted directly in section B below, since the whole disjointness argument
# depends on that refusal actually existing on disk, not merely being asserted
# in prose.
#
# NON-VACUITY. Every positive fixture (C) is paired with a same-shaped negative
# (D/E/F/G) so a marker written by an over-broad implementation (e.g. "contains
# bp-watch.pl anywhere") is caught, not just a marker written by a correct one.
# AC1's own text calls this out by name ("pair the positive and negative
# fixtures in the same test").
#
# Runs standalone: perl plugins/butler/tests/t/142-reporter-registration.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $WATCH = "$Bin/../../scripts/bp-watch.pl";

ok(-f $MARK,  'A1: mark-wakeup.sh exists') or BAIL_OUT('hook missing');
ok(-f $WATCH, 'A2: bp-watch.pl exists')    or BAIL_OUT('script missing');

# ---------------------------------------------------------------------------
# B. THE DISJOINTNESS PREMISE ITSELF. The whole registration design (spec
#    §1.2) rests on bp-watch.pl refusing --package and --blueprint together.
#    If this refusal is ever removed, the driver's own invocation could
#    accidentally satisfy BOTH surfaces' trigger regex at once -- so this is
#    asserted here as ground truth, not assumed.
# ---------------------------------------------------------------------------
{
    my $data = tempdir(CLEANUP => 1);
    my $out = `perl "$WATCH" --arm --package x/p1 --blueprint x --max-seconds 5 --data "$data" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 64, 'B1 PREMISE: bp-watch.pl refuses --package and --blueprint together (usage '
              . 'error, exit 64) -- this is what makes --blueprint a reporter-EXCLUSIVE '
              . 'signal; without this refusal, the registration design in this file has '
              . 'no foundation');
    like($out, qr/exactly one of --package or --blueprint/i,
       'B2: ...and says so, so the refusal is not a coincidental exit code');
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub run_mark {
    my ($payload, %opt) = @_;
    my $rdir = $opt{rdir};
    my $env  = '';
    $env .= "CCPRAXIS_REPORTER_ACTIVE_DIR='$rdir' " if defined $rdir;
    my $out = `${env}bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub new_project {
    my (%opt) = @_;
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data");
    make_path("$root/.ccpraxis-local-data/.drive-solo") if $opt{drive_solo};
    return $root;
}

# Reporter's exact Mode-B shape, per reporter/SKILL.md:191. Built with a real
# JSON encoder (not string interpolation) so $cmd's embedded quotes are
# escaped exactly as the real harness escapes them -- see driver correction,
# implementer-step4 follow-up: a hand-interpolated payload left the quotes
# unescaped, producing a malformed document that no properly-escaped payload
# would ever be.
sub reporter_arm_payload {
    my ($cwd, $sid) = @_;
    $sid //= 'sess-reporter';
    my $cmd = q{perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-watch.pl --arm --blueprint bp-x }
            . q{--pid-file bp-x/runs/.orchestrator --max-seconds 1800};
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
}

# Driver's own shape, per drive-solo/SKILL.md:120 -- --package, never --blueprint.
sub driver_arm_payload {
    my ($cwd, $sid) = @_;
    $sid //= 'sess-driver';
    my $cmd = q{perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-watch.pl --arm --package bp-x/p1 }
            . q{--max-seconds 1800};
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
}

sub marker_path { my ($rdir, $sid) = @_; return "$rdir/$sid"; }

# ===========================================================================
# C/D. AC1 -- the paired positive/negative fixture, same shape apart from the
#      one flag that must matter.
# ===========================================================================
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);

    my ($rc, $out) = run_mark(reporter_arm_payload($root, 'sess-c'), rdir => $rdir);
    is($rc, 0, 'C1 (-> DC1): mark-wakeup.sh never blocks on registration -- exit 0');
    ok(-f marker_path($rdir, 'sess-c'),
       'C2 CANONICAL (-> AC1 positive): a Bash command matching bp-watch.pl --arm '
     . '...--blueprint... writes a reporter registration marker keyed by session_id');
    my $content = '';
    if (open my $fh, '<', marker_path($rdir, 'sess-c')) {
        local $/; $content = <$fh>;
    }
    like($content, qr/\Q$root\E[\/\\]\.ccpraxis-local-data/,
       'C3: the marker holds the RESOLVED data dir, not merely a boolean/empty marker');
}
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);

    my ($rc, $out) = run_mark(driver_arm_payload($root, 'sess-d'), rdir => $rdir);
    is($rc, 0, 'D1: mark-wakeup.sh never blocks on the driver-shaped payload either');
    ok(!-f marker_path($rdir, 'sess-d'),
       'D2 CANONICAL (-> AC1 negative, disjointness): the SAME command with --package '
     . 'instead of --blueprint (the driver'."'".'s own shape) writes NO reporter marker -- '
     . 'a naive "grep for bp-watch.pl" implementation would fail this specifically because '
     . 'it does not distinguish --package from --blueprint');
}

# ===========================================================================
# E. AC7 part 1 -- tool_name != Bash. The string is present in the payload
#    (as a Read tool's description of what it read) but the tool itself is
#    not Bash, so the outer gate on $TOOL must exclude it regardless of the
#    grep's own reach.
# ===========================================================================
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-e', cwd => $root, tool_name => 'Read',
        tool_input    => { file_path => 'reporter/SKILL.md' },
        tool_response => { content => '...bp-watch.pl --arm --blueprint $0...' },
    });
    my ($rc) = run_mark($payload, rdir => $rdir);
    is($rc, 0, 'E1: mark-wakeup.sh never blocks on a Read event');
    ok(!-f marker_path($rdir, 'sess-e'),
       'E2 CANONICAL (-> AC7 part 1, DC6): a session that merely READS reporter/SKILL.md '
     . '(tool_name=Read, containing the literal arm string in tool_response) does NOT '
     . 'register -- reading about arming is not arming');
}

# ===========================================================================
# F. AC7 part 2 -- a Bash command that NAMES bp-watch.pl in an echo/grep
#    rather than executing it. (fixbatch step7 / F4 correction: section H
#    below no longer claims the driver's own regex is working "prior art"
#    for this -- verified live, it is NOT. The reporter's own heuristic,
#    fixed by F1/F5-F8, is what actually solves this for the reporter path.)
# ===========================================================================
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my $cmd  = q{echo "run bp-watch.pl --arm --blueprint later"};
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-f1', cwd => $root, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
    my ($rc) = run_mark($payload, rdir => $rdir);
    is($rc, 0, 'F1: mark-wakeup.sh never blocks on the echoed command');
    ok(!-f marker_path($rdir, 'sess-f1'),
       'F2 CANONICAL (-> AC7 part 2, DC6): a Bash command that ECHOES the arm string '
     . '(never executes it) does NOT register a reporter session');
}
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my $cmd  = q{grep -l "bp-watch.pl --arm --blueprint" plugins/butler/skills/reporter/SKILL.md};
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-f2', cwd => $root, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
    my ($rc) = run_mark($payload, rdir => $rdir);
    is($rc, 0, 'F3: mark-wakeup.sh never blocks on the grepping command');
    ok(!-f marker_path($rdir, 'sess-f2'),
       'F4: a Bash command that GREPS FOR the arm string (never executes it) does NOT '
     . 'register a reporter session either -- both echo and grep are named explicitly '
     . 'in AC7');
}

# ===========================================================================
# F5-F8 (fixbatch step7 / F1, HIGH). redteam-step6.md HIGH-1: the FIRST
# shipped heuristic (a bare double-quote parity count) rejected only the
# double-quoted echo/grep shapes above and was defeated by a bash comment, a
# single-quoted string, or a heredoc body -- three DIFFERENT ways of getting
# the literal text into the command without ever executing it, verified live
# against the shipped hook. Each fixture below is exactly one of those three
# reproductions, plus the unquoted-reader residual named in the same finding.
# ===========================================================================
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my $cmd  = "# reminder: do not forget to run bp-watch.pl --arm --blueprint bp-x "
             . "--pid-file /tmp/p --max-seconds 1800\nls";
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-f5', cwd => $root, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
    my ($rc) = run_mark($payload, rdir => $rdir);
    is($rc, 0, 'F5a: mark-wakeup.sh never blocks on the commented-out command');
    ok(!-f marker_path($rdir, 'sess-f5'),
       'F5b (redteam-step6.md HIGH-1 repro #1): a bash COMMENT naming the arm string, '
     . 'never executed, does NOT register a reporter session');
}
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my $cmd  = q{grep -l 'bp-watch.pl --arm --blueprint' plugins/butler/skills/reporter/SKILL.md};
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-f6', cwd => $root, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
    my ($rc) = run_mark($payload, rdir => $rdir);
    is($rc, 0, 'F6a: mark-wakeup.sh never blocks on the single-quoted grepping command');
    ok(!-f marker_path($rdir, 'sess-f6'),
       'F6b (redteam-step6.md HIGH-1 repro #2): a SINGLE-quoted grep for the arm string '
     . 'does NOT register a reporter session (the original heuristic counted only literal '
     . '" characters, so this shape was invisible to it)');
}
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my $cmd  = "cat <<EOF\nbp-watch.pl --arm --blueprint bp-x\nEOF";
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-f7', cwd => $root, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
    my ($rc) = run_mark($payload, rdir => $rdir);
    is($rc, 0, 'F7a: mark-wakeup.sh never blocks on the heredoc-body command');
    ok(!-f marker_path($rdir, 'sess-f7'),
       'F7b (redteam-step6.md HIGH-1 repro #3): a HEREDOC BODY naming the arm string, '
     . 'never executed as a command, does NOT register a reporter session');
}
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my $cmd  = q{grep -r bp-watch.pl --arm --blueprint foo};
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-f8', cwd => $root, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
    my ($rc) = run_mark($payload, rdir => $rdir);
    is($rc, 0, 'F8a: mark-wakeup.sh never blocks on the unquoted grepping command');
    ok(!-f marker_path($rdir, 'sess-f8'),
       'F8b (fixbatch step7 / F1 residual, closed): an UNQUOTED grep for the arm string '
     . '(no quoting at all for the filter to strip) does NOT register a reporter session '
     . '-- the command SEGMENT containing the match begins with a non-executing reader '
     . '(grep), which the fix rejects even with nothing quoted');
}

# ===========================================================================
# G. Same class as E, using the Grep tool directly (the most literal reading
#    of "greps for bp-watch.pl" from the package ledger's own criterion 6).
# ===========================================================================
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-g', cwd => $root, tool_name => 'Grep',
        tool_input => { pattern => 'bp-watch.pl --arm --blueprint' },
    });
    my ($rc) = run_mark($payload, rdir => $rdir);
    is($rc, 0, 'G1: mark-wakeup.sh never blocks on a Grep event');
    ok(!-f marker_path($rdir, 'sess-g'),
       'G2: a session that GREPS for the arm string via the Grep tool does NOT register');
}

# ===========================================================================
# H. fixbatch step7 / F4 CORRECTION. The ORIGINAL H2 claimed "the DRIVER's
#    existing regex already avoids this exact false positive today", but
#    asserted it against "$ds/.wakeup-pending" -- a path bp_drive_marker()
#    (lib.sh) never writes to under ANY outcome of this fixture (that file is
#    written only by the separate backgrounded-Bash wake-up path, further
#    down in mark-wakeup.sh, which this fixture never reaches). The assertion
#    was vacuously true under both a correct and a broken regex, disclosed
#    candidly in the commit message for 3f03a25 -- fixed here by pointing at
#    the REAL marker path ("$dact/sess-h", where bp_drive_active_dir()
#    resolves to $CCPRAXIS_DRIVE_ACTIVE_DIR per the SAFETY NOTE below).
#
#    Doing so surfaces what the vacuous assertion was hiding: the DRIVER's
#    own arm regex (`mark-wakeup.sh`, `bp-drive-next\.pl[^"]*(next|...)`,
#    untouched by this package -- see dispatch's "Explicitly NOT in this
#    batch") has NO quote-parity check at all. Against this EXACT fixture's
#    JSON encoding (`"command":"echo \"run bp-drive-next.pl next later\""`),
#    the escaped quote characters land OUTSIDE the span between
#    "bp-drive-next.pl" and "next" -- there is no interior quote for
#    `[^"]*` to be stopped by -- so the regex DOES match, and the driver
#    marker IS written. Verified live, not assumed: this is redteam-step6.md
#    LOW-2's finding ("the driver's own arm has the same false positive...
#    out of this package's scope"), previously undetected by H2 because H2
#    asserted against the wrong file. The premise "prior art already solves
#    this" was FALSE for the driver; only the reporter's OWN heuristic (F5-F8
#    above) is fixed by this package. H2 below now asserts the TRUE,
#    verified behavior instead of repeating the false claim.
#
# 2026-08-19 d03-one-shell-noise-stripper CLOSES THE GAP THIS BLOCK RECORDS.
# Almanac report 20260814-093113-34a0 named this exact weakness (the driver
# arm grepping the raw JSON payload, no quote-parity check at all) as its
# sharpest finding and brought it in scope. d03 routes the driver arm through
# the same extract -> bp_strip_shell_noise -> match -> reader-segment-veto
# path the reporter arm already used, so this fixture -- an ECHOED, never
# executed, mention of bp-drive-next.pl -- must now NOT register a driver
# session. H2 below is therefore INVERTED on purpose: `ok(-f ...)` becomes
# `ok(!-f ...)`. This is the fix working, not a change made to satisfy a
# failing test -- the paragraphs above this note stay exactly as they were
# written, because they are an honest, dated record of a real, then-out-of-
# scope bug, and a future reader should still be able to see that the bug
# was real before it was closed. H3, directly below, is UNCHANGED: a genuine
# invocation must still arm, now via the new code path.
#
# SAFETY NOTE (fixture construction, not an assertion change): this fixture
# deliberately trips the DRIVER's own arm regex, which -- unlike every other
# fixture in this file, which stays on the reporter path via run_mark's
# CCPRAXIS_REPORTER_ACTIVE_DIR scoping -- writes through bp_drive_marker(),
# whose directory is controlled by CCPRAXIS_DRIVE_ACTIVE_DIR, defaulting to
# the REAL, live, cross-project marker dir
# (~/.claude/ccpraxis/.drive-solo-active) when unset. This is scoped to a
# tempdir here for the same reason every other fixture in this suite is
# sandboxed: this file must never write into real driver state (see this
# package's own dispatch constraints).
# ===========================================================================
{
    my $root = new_project(drive_solo => 1);
    my $dact = tempdir(CLEANUP => 1);
    my $cmd  = q{echo "run bp-drive-next.pl next later"};
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-h', cwd => $root, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
    my $out = `CCPRAXIS_DRIVE_ACTIVE_DIR='$dact' bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    is($? >> 8, 0, 'H1: driver arm never blocks on the echoed command either (registering '
                 . 'never blocks anything -- see this file'."'".'s own header)');
    ok(!-f "$dact/sess-h",
       'H2 INVERTED (d03-one-shell-noise-stripper, closing almanac report '
     . '20260814-093113-34a0): this assertion REPLACES the prior '
     . '"H2 CORRECTED" assertion, which pinned the DRIVER'."'".'s then-existing arm regex '
     . 'having NO quote-parity check and DOING register on this echoed command. d03 '
     . 'brought that KNOWN, verified, previously-out-of-scope weakness (redteam-step6.md '
     . 'LOW-2) in scope and fixed it -- the driver arm now extracts tool_input.command, '
     . 'strips it via the shared bp_strip_shell_noise, and applies the same reader-segment '
     . 'veto the reporter arm already used, so this ECHOED, never-executed mention of '
     . 'bp-drive-next.pl no longer registers a driver session. The inversion below is the '
     . 'fix working as designed, not a change made to satisfy a failing test.');
}
# ---------------------------------------------------------------------------
# H3. Confirms H2's positive result is not an accident of that ONE echoed
#     shape: a GENUINE, unambiguous bp-drive-next.pl invocation, in the SAME
#     session/dact scoping, ALSO writes the marker at $dact/<session_id> --
#     the mechanism H2 observed firing on an echoed command is the same
#     mechanism a real invocation is supposed to trigger, not a coincidence
#     of this one fixture's bytes.
# ---------------------------------------------------------------------------
{
    my $root = new_project(drive_solo => 1);
    my $dact = tempdir(CLEANUP => 1);
    my $cmd  = q{perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-drive-next.pl next};
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-h3', cwd => $root, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
    my $out = `CCPRAXIS_DRIVE_ACTIVE_DIR='$dact' bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    is($? >> 8, 0, 'H3a: driver arm never blocks on a genuine invocation');
    ok(-f "$dact/sess-h3",
       'H3b: a REAL bp-drive-next.pl next invocation, in the identical dact-scoped '
     . 'fixture shape as H2, ALSO writes the marker at $dact/<session_id> -- the same '
     . 'code path H2 observed firing on an echoed command is genuinely the driver'."'".'s '
     . 'real registration mechanism, not a fixture artifact');
}

# ===========================================================================
# I. SID sanitization -- same discipline bp_drive_marker already applies.
#    An invalid session_id must never produce a marker under any name.
# ===========================================================================
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my ($rc) = run_mark(reporter_arm_payload($root, 'sess/evil'), rdir => $rdir);
    is($rc, 0, 'I1: mark-wakeup.sh never blocks even with a hostile session_id');
    opendir(my $dh, $rdir) or die $!;
    my @entries = grep { !/^\.\.?$/ } readdir $dh;
    closedir $dh;
    is(scalar(@entries), 0,
       'I2 CANONICAL: a session_id containing a path separator ("sess/evil") writes NO '
     . 'marker under any filename -- the same sid-sanitization discipline that already '
     . 'guards the driver'."'".'s own marker, applied here');
}

# ===========================================================================
# J. LOAD-BEARING ORDERING (spec §2.1's own explicit note): registration must
#    NOT depend on .drive-solo existing. A project where drive-solo has never
#    run (the overwhelming common case for a reporter-only project) must
#    still register a reporter session.
# ===========================================================================
{
    my $root = new_project();   # deliberately NOT drive_solo => 1
    ok(!-d "$root/.ccpraxis-local-data/.drive-solo",
       'K0 precondition: this project has no .drive-solo directory at all');
    my $rdir = tempdir(CLEANUP => 1);
    my ($rc) = run_mark(reporter_arm_payload($root, 'sess-k'), rdir => $rdir);
    is($rc, 0, 'K1: mark-wakeup.sh never blocks');
    ok(-f marker_path($rdir, 'sess-k'),
       'K2 CANONICAL (-> spec §2.1 ordering note): registration succeeds in a project '
     . 'that has NEVER run drive-solo -- the existing driver early-exit '
     . '([ -d "$DATA/.drive-solo" ] || exit 0) must not swallow this before the new '
     . 'block runs. A implementation that inserts the reporter block AFTER that early-exit '
     . 'would fail this specific assertion.');
}

done_testing();
