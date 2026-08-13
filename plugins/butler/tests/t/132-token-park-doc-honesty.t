#!/usr/bin/env perl
# e04-honest-terminal-reporting, AC5 (-> DC5): three documentation surfaces
# still describe the RETIRED pause-token terminal-relogin-park behavior, even
# though bp-usage-gate.pl/bp-token-keeper.pl/bp-drive-next.pl's own
# _token_recover already implement recover-or-genuinely-terminal-stop (dated
# 2026-08-12, MEASURED by the architect). This is itself a Pattern-1 instance:
# a report that was once true and is no longer earned. Spec §2.5/§3(5)/§4 AC5.
#
# NO CODE CHANGE IS EXPECTED UNDER THIS CRITERION (spec §7 edge cases 5/6) --
# these are pure text/doc assertions. Each is confirmed live, right now,
# against the current tree while writing this test:
#   - plugins/butler/skills/drive-solo/SKILL.md:51 still reads "TERMINAL
#     relogin park: tell the user to /login ... NOT an auto-resume."
#   - bp-drive-next.pl's $HELP_TEXT (the in-file heredoc, NOT the top-of-file
#     doc comment block, which is already correct) still shows
#     {"action":"pause","until_epoch":null,"reason":"token"} TERMINAL relogin
#     park (:943) and "pause-token -> pause reason=token, until_epoch=null
#     (hard-stop relogin)" (:954); it also has no "in-flight" line at all.
#   - bp-usage-gate.pl's header comment (:49) and its --help heredoc (:251)
#     both still show pause-token/until_epoch=null/"(hard-stop relogin)".
#
# VACUITY GUARDS:
#   - every "must no longer say X" assertion (`unlike`) is paired with a "must
#     now say Y" assertion (`like`) in the SAME block -- an `unlike` alone
#     would pass trivially if the surface were simply emptied out or the CLI
#     crashed before printing anything (the exact vacuity landmine this
#     dispatch was warned about). The `like`/exit-code checks below make that
#     impossible: a crashing/empty --help would fail the `like` half.
#   - `bp-drive-next.pl --help` and `bp-usage-gate.pl --help` are captured via
#     the real CLI entrypoints (BpDrive::run/BpUsageGate::run), not by
#     grepping the heredoc source text -- so a fix that edits the heredoc but
#     leaves a stray earlier `return` (never reaching the print) is caught.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempfile);
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }
my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");

my $DRIVE_NEXT_SCRIPT = "$BUTLER/scripts/bp-drive-next.pl";
my $USAGE_GATE_SCRIPT = "$BUTLER/scripts/bp-usage-gate.pl";
my $SKILL_MD           = "$BUTLER/skills/drive-solo/SKILL.md";

require $DRIVE_NEXT_SCRIPT;
require $USAGE_GATE_SCRIPT;

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or die "read $p: $!"; local $/; my $c = <$fh>; close $fh; $c }

# Generic capture_run for a `Module::run(\@argv, \%opts)` CLI entrypoint,
# mirroring t/17/t/18's own house convention (fd-backed temp files -- scalar
# filehandle capture dies on Git-for-Windows perl).
sub capture_cli {
    my ($fn, $argv, $opts) = @_;
    my ($ofh, $opath) = tempfile('t131-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('t131-errXXXXXX', TMPDIR => 1); close $efh;
    open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDOUT, '>:raw', $opath or do { open STDOUT, '>&', $oldout; die "reopen STDOUT: $!" };
    open STDERR, '>:raw', $epath or do { open STDERR, '>&', $olderr; die "reopen STDERR: $!" };
    $| = 1;
    my $rc  = eval { $fn->($argv, $opts // {}) };
    my $err = $@;
    open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
    open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
    my $out = do { open my $r, '<:raw', $opath or die; local $/; my $x = <$r>; close $r; defined $x ? $x : '' };
    unlink $opath, $epath;
    die $err if $err;
    return ($rc, $out);
}

# ═══════════════════════════════════════════════════════════════════════════
# 1. drive-solo/SKILL.md dispatch table
# ═══════════════════════════════════════════════════════════════════════════
{
    my $md = slurp($SKILL_MD);
    unlike($md, qr/TERMINAL relogin park.*NOT an auto-resume/s,
        'AC5/SKILL: no longer describes a TERMINAL relogin-park pause row '
      . '(fails today: SKILL.md:51 reads exactly this)');
    like($md, qr/token-refresh-failed/,
        'AC5/SKILL: describes the actual genuinely-terminal action, stop/token-refresh-failed (spec §2.5.1)');
    # Non-vacuity: a bare qr/\bstop\b/ against the whole file matches unrelated
    # prose ("Non-zero exit -> stop", "run settled; stop") even TODAY, so it
    # would pass without pinning anything. Require the `stop` DISPATCH-TABLE
    # ROW itself, tied to reason=token, in one pattern.
    like($md, qr/`stop`.{0,80}reason=`token-refresh-failed`|reason=`token-refresh-failed`.{0,80}`stop`/s,
        'AC5/SKILL: the dispatch table has a `stop`/`reason=token-refresh-failed` ROW '
      . '(fails today: no such row exists -- only the retired `pause`/reason=`token` row does)');
}

# ═══════════════════════════════════════════════════════════════════════════
# 2. bp-drive-next.pl --help (the in-file $HELP_TEXT heredoc, live CLI output)
# ═══════════════════════════════════════════════════════════════════════════
{
    my ($rc, $out) = capture_cli(\&BpDrive::run, ['--help']);
    is($rc, 0, 'AC5/drive-next --help: exits 0');
    ok(length($out) > 0, 'AC5/drive-next --help: prints non-empty output (guards the unlike checks below against a silent/crashed CLI)')
        or diag("rc=$rc");
    unlike($out, qr/TERMINAL relogin park/,
        'AC5/drive-next --help: no longer shows the retired TERMINAL relogin park action line '
      . '(fails today: $HELP_TEXT:943 shows exactly this)');
    unlike($out, qr/hard-stop relogin/,
        'AC5/drive-next --help: no longer describes pause-token as a hard-stop relogin '
      . '(fails today: $HELP_TEXT:954 shows exactly this)');
    like($out, qr/token-refresh-failed/,
        'AC5/drive-next --help: describes the real stop/token-refresh-failed terminal action');
    like($out, qr/in-flight/,
        'AC5/drive-next --help: lists the in-flight action (present in code and the top-of-file doc block, '
      . 'absent from $HELP_TEXT today)');
}

# ═══════════════════════════════════════════════════════════════════════════
# 3. bp-usage-gate.pl --help (live CLI output) + its own header comment
# ═══════════════════════════════════════════════════════════════════════════
{
    my ($rc, $out) = capture_cli(\&BpUsageGate::run, ['--help']);
    is($rc, 0, 'AC5/usage-gate --help: exits 0');
    ok(length($out) > 0, 'AC5/usage-gate --help: prints non-empty output')
        or diag("rc=$rc");
    unlike($out, qr/hard-stop relogin/,
        'AC5/usage-gate --help: no longer describes pause-token as a hard-stop relogin '
      . '(fails today: --help heredoc:251 shows exactly this)');
    unlike($out, qr/until_epoch=null\s+reason="token"/,
        'AC5/usage-gate --help: pause-token row no longer claims until_epoch=null '
      . '(fails today: it does, even though verdict_decision has computed a real epoch since 2026-08-12)');
    like($out, qr/pause-token/,
        'AC5/usage-gate --help: still documents the pause-token action name (sanity: CLI actually printed the verdict block)');
}
{
    my $src = slurp($USAGE_GATE_SCRIPT);
    # Header comment block (source-level doc, not emitted by any CLI call).
    my ($header) = $src =~ /(#\s*GOVERNOR VERDICT CONSUMED.*?\n\n)/s;
    ok(defined $header, 'AC5/usage-gate header: the GOVERNOR VERDICT CONSUMED comment block is present (sanity)')
        or diag('block not found -- test anchor drifted, re-grep the file');
    if (defined $header) {
        unlike($header, qr/"pause-token","until_epoch":null/,
            'AC5/usage-gate header comment: no longer documents pause-token with a literal null until_epoch '
          . '(fails today: header line ~49 shows exactly this)');
    }
}

done_testing();
