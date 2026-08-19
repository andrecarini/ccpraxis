#!/usr/bin/env perl
# 164-driver-arm-noise-stripping.t — d03-one-shell-noise-stripper.
#
# Spec: specs/d03-one-shell-noise-stripper-spec.md §3 (observable behaviors),
# §4 AC3-AC9, AC12. Package: packages/d03-one-shell-noise-stripper.md DC2,
# DC3, DC5. Closes almanac report 20260814-093113-34a0.
#
# THE CLAIM UNDER TEST. mark-wakeup.sh's DRIVER-arm matcher -- historically
# `grep -Eq 'bp-drive-next\.pl[^"]*(next|record-order|park)'` run against the
# RAW JSON PAYLOAD, with no stripping and no reader-segment check at all --
# must now tell a genuine `bp-drive-next.pl next|record-order|park` INVOCATION
# apart from a mere MENTION of one (echoed, commented-out, single-quoted,
# heredoc-embedded, or bare/unquoted). Exercised exclusively by invoking
# mark-wakeup.sh as a subprocess with a real JSON::PP-encoded payload on
# stdin, scoped via CCPRAXIS_DRIVE_ACTIVE_DIR into a throwaway tempdir --
# never by asserting bp_strip_shell_noise / bp_wakeup_arm_check exist or by
# calling them directly (spec §3's own header rule).
#
# NON-VACUITY. Every "must NOT arm" fixture (AC3, AC5-AC7) is paired with the
# "must STILL arm" fixtures of AC4 and AC8 in the SAME file, so an
# over-tightened matcher that stops arming genuine invocations entirely is
# caught here, not just an under-tightened one that never closes the mention
# holes. Per the package ledger's own criterion 3 ("do not tighten the
# matcher into missing a real invocation"), a false NEGATIVE on any AC8
# fixture is treated as more serious than a false positive elsewhere in this
# file.
#
# Runs standalone: perl plugins/butler/tests/t/164-driver-arm-noise-stripping.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use JSON::PP;

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";

ok(-f $MARK, 'A1: mark-wakeup.sh exists') or BAIL_OUT('hook missing');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# new_project: a project root carrying .ccpraxis-local-data/.drive-solo, so
# the driver-arm block's outer gate ([ -n "$DATA" ] && [ -d "$DATA/.drive-solo" ])
# is satisfied and every fixture below actually reaches the matcher under test.
sub new_project {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data/.drive-solo");
    return $root;
}

sub driver_payload {
    my ($cwd, $sid, $cmd) = @_;
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
}

# run_mark_driver: pipe PAYLOAD into mark-wakeup.sh via a real subprocess,
# scoping the driver marker dir with CCPRAXIS_DRIVE_ACTIVE_DIR (never the
# real, live, cross-project default) and optionally overriding HOOK_DIR's
# sibling bp-lib.sh location (opt{no_lib} => a scoped copy of hooks/ with
# bp-lib.sh absent, for the degradation fixtures).
sub run_mark_driver {
    my ($payload, %opt) = @_;
    my $dact = $opt{dact} // tempdir(CLEANUP => 1);
    my $mark = $opt{mark_path} // $MARK;
    my $out = `CCPRAXIS_DRIVE_ACTIVE_DIR='$dact' bash "$mark" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out, $dact);
}

sub marker_path { my ($dact, $sid) = @_; return "$dact/$sid"; }

# scoped_hooks_dir_without_bplib: a private COPY of the hooks/ directory
# (mark-wakeup.sh, lib.sh, and every sibling *.sh mark-wakeup.sh's own
# HOOK_DIR-relative sourcing might reach) plus its sibling scripts/ directory
# WITHOUT bp-lib.sh, so the hook runs with bp-lib.sh genuinely unreadable --
# not merely renamed in the real, shared install, which every other suite
# in this repo also reads from concurrently.
my $SCOPED_NO_LIB;
sub scoped_hooks_dir_without_bplib {
    return $SCOPED_NO_LIB if $SCOPED_NO_LIB;
    my $root = tempdir(CLEANUP => 1);
    my $hooks_dst = "$root/hooks";
    my $scripts_dst = "$root/scripts";
    make_path($hooks_dst);
    make_path($scripts_dst);
    opendir(my $dh, $HOOKS) or die "opendir $HOOKS: $!";
    for my $f (readdir $dh) {
        next if $f =~ /^\.\.?$/;
        my $src = "$HOOKS/$f";
        next unless -f $src;
        copy($src, "$hooks_dst/$f") or die "copy $src: $!";
    }
    closedir $dh;
    # scripts/ deliberately left EMPTY of bp-lib.sh -- [ -r ... ] must see it
    # as missing, not merely fail to read a stale copy.
    $SCOPED_NO_LIB = "$hooks_dst/mark-wakeup.sh";
    return $SCOPED_NO_LIB;
}

# ===========================================================================
# AC3 (-> DC2). The report's own headline case: echo "run bp-drive-next.pl
# next later" must NOT arm. This is t/142 section H, flipped -- see that
# file's own H2 for the deliberate inversion; this fixture independently
# re-proves the same behavior via a fresh file per the spec's ruling that
# new driver-arm coverage lives here, not stuffed into t/142.
# ===========================================================================
{
    my $root = new_project();
    my $cmd  = q{echo "run bp-drive-next.pl next later"};
    my $payload = driver_payload($root, 'sess-ac3', $cmd);
    my ($rc, $out, $dact) = run_mark_driver($payload);
    is($rc, 0, 'AC3a: mark-wakeup.sh never blocks on the double-quoted echoed command');
    ok(!-f marker_path($dact, 'sess-ac3'),
       'AC3b (-> DC2, ledger headline finding): a DOUBLE-QUOTED echo of '
     . '"bp-drive-next.pl next" (never executed) does NOT register a driver session');
}

# ===========================================================================
# AC4 (-> DC2, DC3). Non-vacuity for AC3: the EXACT invocation shape already
# pinned by t/142 H3 must still arm through the new code path.
# ===========================================================================
{
    my $root = new_project();
    my $cmd  = q{perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-drive-next.pl next};
    my $payload = driver_payload($root, 'sess-ac4', $cmd);
    my ($rc, $out, $dact) = run_mark_driver($payload);
    is($rc, 0, 'AC4a: mark-wakeup.sh never blocks on a genuine invocation');
    ok(-f marker_path($dact, 'sess-ac4'),
       'AC4b (-> DC2, DC3 non-vacuity): a genuine, quoted-path bp-drive-next.pl next '
     . 'invocation STILL writes the driver marker -- a matcher that never arms anything '
     . 'would pass AC3 trivially; this proves the mechanism still works');
}

# ===========================================================================
# AC5 (-> DC2, DC3, DC5). A bash comment mentioning the invocation.
# ===========================================================================
{
    my $root = new_project();
    my $cmd  = "# reminder: run bp-drive-next.pl next later\nls";
    my $payload = driver_payload($root, 'sess-ac5', $cmd);
    my ($rc, $out, $dact) = run_mark_driver($payload);
    is($rc, 0, 'AC5a: mark-wakeup.sh never blocks on the commented-out command');
    ok(!-f marker_path($dact, 'sess-ac5'),
       'AC5b: a bash COMMENT naming the invocation, never executed, does NOT register a '
     . 'driver session');
}

# ===========================================================================
# AC6 (-> DC2, DC3, DC5). A single-quoted echo mentioning the invocation.
# ===========================================================================
{
    my $root = new_project();
    my $cmd  = q{echo 'run bp-drive-next.pl next later'};
    my $payload = driver_payload($root, 'sess-ac6', $cmd);
    my ($rc, $out, $dact) = run_mark_driver($payload);
    is($rc, 0, 'AC6a: mark-wakeup.sh never blocks on the single-quoted echoed command');
    ok(!-f marker_path($dact, 'sess-ac6'),
       'AC6b: a SINGLE-quoted echo of the invocation does NOT register a driver session');
}

# ===========================================================================
# AC7 (-> DC2, DC3, DC5). Bare, unquoted mention -- closed by the
# reader-segment veto, not by stripping (there is nothing quoted to strip).
# ===========================================================================
{
    my $root = new_project();
    my $cmd  = q{grep -r bp-drive-next.pl next foo};
    my $payload = driver_payload($root, 'sess-ac7', $cmd);
    my ($rc, $out, $dact) = run_mark_driver($payload);
    is($rc, 0, 'AC7a: mark-wakeup.sh never blocks on the bare unquoted grep');
    ok(!-f marker_path($dact, 'sess-ac7'),
       'AC7b: a BARE, unquoted grep mentioning "bp-drive-next.pl next" does NOT register '
     . 'a driver session -- closed by the reader-segment veto since stripping alone '
     . 'cannot touch unquoted text');
}

# ===========================================================================
# AC3/comment: heredoc-body mention. Named in spec §3 observable #3 alongside
# the comment/single-quote shapes; given its own fixture here since AC5/AC6
# each cover only one of the three enumerated mention-shapes.
# ===========================================================================
{
    my $root = new_project();
    my $cmd  = "cat <<EOF\nbp-drive-next.pl next\nEOF";
    my $payload = driver_payload($root, 'sess-heredoc', $cmd);
    my ($rc, $out, $dact) = run_mark_driver($payload);
    is($rc, 0, 'AC-heredoc-a: mark-wakeup.sh never blocks on the heredoc-body command');
    ok(!-f marker_path($dact, 'sess-heredoc'),
       'AC-heredoc-b (spec §3 observable #3): a HEREDOC BODY naming the invocation, '
     . 'never executed as a command, does NOT register a driver session');
}

# ===========================================================================
# AC8 (-> DC3, "must still arm"). Every shape the spec enumerates, each
# independently, each expected to arm. Per criterion 3's own bias, a missed
# real invocation here is the serious failure -- covered generously.
# ===========================================================================
{
    my @shapes = (
        ['AC8a bare relative path',
         q{perl plugins/butler/scripts/bp-drive-next.pl next}],
        ['AC8b absolute path',
         q{perl /abs/path/plugins/butler/scripts/bp-drive-next.pl next}],
        ['AC8c cd-prefixed',
         q{cd /some/project && perl plugins/butler/scripts/bp-drive-next.pl next}],
        ['AC8d extra flags',
         q{perl plugins/butler/scripts/bp-drive-next.pl next --scope pkg}],
        ['AC8e piped',
         q{perl plugins/butler/scripts/bp-drive-next.pl next | tee /tmp/log}],
        ['AC8f record-order subcommand',
         q{perl plugins/butler/scripts/bp-drive-next.pl record-order}],
        ['AC8g park subcommand',
         q{perl plugins/butler/scripts/bp-drive-next.pl park}],
    );
    my $n = 0;
    for my $shape (@shapes) {
        my ($label, $cmd) = @$shape;
        $n++;
        my $root = new_project();
        my $sid  = "sess-ac8-$n";
        my $payload = driver_payload($root, $sid, $cmd);
        my ($rc, $out, $dact) = run_mark_driver($payload);
        is($rc, 0, "$label: mark-wakeup.sh never blocks");
        ok(-f marker_path($dact, $sid),
           "$label (-> AC8, DC3 false-negative guard): this genuine shape STILL arms a "
         . "driver session -- '$cmd'");
    }
}

# ===========================================================================
# FIX1 (fixbatch step7, redteam-step6.md CRITICAL-1) -- an early, harmless
# MENTION segment must never veto a LATER, genuine invocation segment in the
# same compound command. Regression fixture for the leftmost-match-anchor
# bug; must ARM in every case below (a false negative here is the serious
# failure per criterion 3).
# ===========================================================================
{
    my @shapes = (
        ['FIX1a semicolon',
         q{grep bp-drive-next.pl README.md; perl plugins/butler/scripts/bp-drive-next.pl next}],
        ['FIX1b pipe',
         q{cat notes.txt | grep bp-drive-next.pl; perl plugins/butler/scripts/bp-drive-next.pl next}],
        ['FIX1c background-amp',
         q{grep bp-drive-next.pl README.md & perl plugins/butler/scripts/bp-drive-next.pl next}],
        ['FIX1d newline',
         "grep bp-drive-next.pl README.md\nperl plugins/butler/scripts/bp-drive-next.pl next"],
        ['FIX1e record-order after mention',
         q{grep bp-drive-next.pl README.md; perl plugins/butler/scripts/bp-drive-next.pl record-order}],
        ['FIX1f park after mention',
         q{grep bp-drive-next.pl README.md; perl plugins/butler/scripts/bp-drive-next.pl park}],
    );
    my $n = 0;
    for my $shape (@shapes) {
        my ($label, $cmd) = @$shape;
        $n++;
        my $root = new_project();
        my $sid  = "sess-fix1-$n";
        my $payload = driver_payload($root, $sid, $cmd);
        my ($rc, $out, $dact) = run_mark_driver($payload);
        is($rc, 0, "$label: mark-wakeup.sh never blocks");
        ok(-f marker_path($dact, $sid),
           "$label (-> FIX1, CRITICAL-1 regression guard): a genuine invocation segment "
         . "AFTER an unrelated reader-mention segment in the same compound command STILL "
         . "arms -- '$cmd'");
    }
}

# ===========================================================================
# FIX2 (fixbatch step7, redteam-step6.md CRITICAL-2) -- command/process
# substitution genuinely executes regardless of the outer reader word. All
# three shapes below must ARM.
# ===========================================================================
{
    my @shapes = (
        ['FIX2a dollar-paren unquoted',
         q{echo $(perl plugins/butler/scripts/bp-drive-next.pl next)}],
        ['FIX2b dollar-paren double-quoted',
         q{printf "%s" "$(perl plugins/butler/scripts/bp-drive-next.pl next)"}],
        ['FIX2c process substitution',
         q{cat <(perl plugins/butler/scripts/bp-drive-next.pl next)}],
    );
    my $n = 0;
    for my $shape (@shapes) {
        my ($label, $cmd) = @$shape;
        $n++;
        my $root = new_project();
        my $sid  = "sess-fix2-$n";
        my $payload = driver_payload($root, $sid, $cmd);
        my ($rc, $out, $dact) = run_mark_driver($payload);
        is($rc, 0, "$label: mark-wakeup.sh never blocks");
        ok(-f marker_path($dact, $sid),
           "$label (-> FIX2, CRITICAL-2 regression guard): a genuine invocation wrapped in "
         . "command/process substitution after a reader word STILL arms -- '$cmd'");
    }
}

# ===========================================================================
# FIX3 (fixbatch step7, redteam HIGH) -- a large command must not blow the
# hook's own 15s external timeout and must still ARM. Built via a real Bash
# comment padding (never executed) followed by the genuine invocation, so a
# correct implementation both (a) completes well inside the timeout and (b)
# still arms.
# ===========================================================================
{
    my $root = new_project();
    my $padding = ('#' . ('x' x 78) . "\n") x 700;  # ~63KB of comment lines
    my $cmd = $padding . 'perl plugins/butler/scripts/bp-drive-next.pl next';
    my $sid = 'sess-fix3-large';
    my $payload = driver_payload($root, $sid, $cmd);
    my $t0 = time();
    my ($rc, $out, $dact) = run_mark_driver($payload);
    my $elapsed = time() - $t0;
    is($rc, 0, 'FIX3a: mark-wakeup.sh never blocks on a large command');
    ok(-f marker_path($dact, $sid),
       "FIX3b (-> FIX3, HIGH regression guard): a ~63KB command with a genuine invocation "
     . "at the end STILL arms");
    ok($elapsed < 15,
       "FIX3c (-> FIX3, HIGH regression guard): completed in ${elapsed}s, well inside the "
     . "hook's own 15s external timeout");
}

# ===========================================================================
# AC9 -- spec observable #5: a non-Bash tool whose payload text happens to
# contain the driver invocation string must not arm (the outer $TOOL = Bash
# gate excludes it before the matcher ever runs). Listed for completeness,
# same as the spec's own framing.
# ===========================================================================
{
    my $root = new_project();
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-nonbash', cwd => $root, tool_name => 'Read',
        tool_input    => { file_path => 'drive-solo/SKILL.md' },
        tool_response => { content => '...perl bp-drive-next.pl next...' },
    });
    my ($rc, $out, $dact) = run_mark_driver($payload);
    is($rc, 0, 'AC9a: mark-wakeup.sh never blocks on a Read event');
    ok(!-f marker_path($dact, 'sess-nonbash'),
       'AC9b (spec §3 observable #5): a Read event whose payload merely CONTAINS the '
     . 'driver invocation string does NOT register a driver session -- the outer '
     . 'tool_name=Bash gate excludes it before the matcher runs');
}

# ===========================================================================
# Degradation path 1 (-> DC3, spec §5, §3 observable #7): bp-lib.sh
# unreadable/missing. Must fail toward ARMING, never toward silence or a
# crash. Exercised against the genuine AC4 shape (a real invocation) in a
# scoped copy of hooks/ whose sibling scripts/bp-lib.sh does not exist.
# ===========================================================================
{
    my $scoped_mark = scoped_hooks_dir_without_bplib();
    ok(!-f "$scoped_mark/../scripts/bp-lib.sh",
       'DEGRADE1 precondition: the scoped hooks copy genuinely has no sibling bp-lib.sh');
    my $root = new_project();
    my $cmd  = q{perl plugins/butler/scripts/bp-drive-next.pl next};
    my $payload = driver_payload($root, 'sess-degrade1', $cmd);
    my ($rc, $out, $dact) = run_mark_driver($payload, mark_path => $scoped_mark);
    is($rc, 0,
       'DEGRADE1a (-> spec §3 observable #7): mark-wakeup.sh still exits 0 with '
     . 'bp-lib.sh unreadable');
    ok(-f marker_path($dact, 'sess-degrade1'),
       'DEGRADE1b (-> DC3, spec §5): with bp-lib.sh missing, a genuine invocation STILL '
     . 'arms via the unstripped-command fallback -- degradation is fail-open toward '
     . 'ARMING, never toward silence');
}

# ===========================================================================
# Degradation path 2 (-> DC3, spec §5): tool_input.command absent/
# unextractable on a Bash-tool payload (malformed JSON shape). DCMD ends up
# empty; bp_wakeup_arm_check returns 0 on empty input, mirroring the
# reporter arm's own existing precedent -- documented as an accepted edge
# case (not a fail-toward-arming case, since there is no command to have
# armed on in the first place), but must not crash or block regardless.
# ===========================================================================
{
    my $root = new_project();
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-degrade2', cwd => $root, tool_name => 'Bash',
        tool_input => { },   # no "command" key at all
    });
    my ($rc, $out, $dact) = run_mark_driver($payload);
    is($rc, 0,
       'DEGRADE2a (-> spec §3 observable #7, §5): mark-wakeup.sh still exits 0 with an '
     . 'unextractable tool_input.command');
    ok(!-f marker_path($dact, 'sess-degrade2'),
       'DEGRADE2b (-> DC3, spec §5): a Bash payload with no extractable command writes no '
     . 'marker under any name -- this never crashes or blocks the hook');
}

# ===========================================================================
# AC1/AC2 -- structural checks. AC1 legitimately has no runtime observable
# (it is a claim about how many places on disk define the stripping state
# machine), so it is written as a source-level grep here rather than forced
# into a behavioral shape it does not have.
# ===========================================================================
{
    my $BUTLER = "$Bin/../..";
    my @hits;
    my @dirs = ("$BUTLER/scripts", "$BUTLER/hooks");
    for my $dir (@dirs) {
        opendir(my $dh, $dir) or next;
        for my $f (readdir $dh) {
            next if $f =~ /^\.\.?$/;
            my $path = "$dir/$f";
            next unless -f $path;
            open(my $fh, '<', $path) or next;
            local $/;
            my $text = <$fh>;
            close $fh;
            push @hits, $path if $text =~ /state eq "heredoc"/;
        }
    }
    is(scalar(@hits), 1,
       'AC1 (-> DC1, structural, source-level not behavioral): the stripping state '
     . "machine's distinguishing text (state eq \"heredoc\") is found in exactly ONE "
     . 'file under plugins/butler/{scripts,hooks} -- '
     . (scalar(@hits) ? join(', ', @hits) : '(none found)'));
    ok((grep { $_ eq "$BUTLER/scripts/bp-lib.sh" } @hits),
       'AC1 detail: that one definition lives in bp-lib.sh, the shared helper');
    ok(!(grep { $_ eq "$MARK" } @hits),
       'AC1 detail: mark-wakeup.sh no longer carries its own inline copy');
}
{
    open(my $fh, '<', $MARK) or die "open $MARK: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    like($text,
         qr/\[\s*-r\s+"\$HOOK_DIR\/\.\.\/scripts\/bp-lib\.sh"\s*\]\s*&&\s*source\s+"\$HOOK_DIR\/\.\.\/scripts\/bp-lib\.sh"/,
         'AC2 (-> DC1, structural but load-bearing for AC1 at runtime): mark-wakeup.sh '
       . 'contains the conditional-source line, mirroring guard-validation-interlock.sh');
}

# ===========================================================================
# AC10 -- structural, text-presence only (a comment has no runtime
# observable). Mirrors the reporter arm's own comment shape.
# ===========================================================================
{
    open(my $fh, '<', $MARK) or die "open $MARK: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    like($text, qr/ACCIDENT/,
       'AC10a (-> DC4, structural, not runtime-observable): mark-wakeup.sh carries a '
     . 'comment naming the ACCIDENT-not-ADVERSARY threat model adjacent to the driver-arm '
     . 'block');
    like($text, qr/\$\(\.\.\.\)/,
       'AC10b (-> DC4, structural): ...and names the unresolved $(...) / backtick / '
     . 'variable-expansion residual');
}

done_testing();
