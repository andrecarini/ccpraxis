#!/usr/bin/env perl
# platform: any
# What the Stop gate's idle refusal says about its two last resorts, and that
# break-glass works whenever its file is valid (bugs 20261105-212229-7709 and
# 20261105-212239-5c1d).
#
# Session 3f77dfd2, 2026-11-05: off-confirm was denied by Claude Code's
# auto-mode classifier, so the judged disarm could not run. The refusal then
# (a) promised "after 5 refusals in a row with no tool call succeeding, the
# gate lets the stop through by itself", leaving out that the cap also needs
# the session's last shell call to have failed (operator ruling 2026-10-23),
# and (b) offered break-glass only under "No shell command can run?", which
# the agent read as forbidding it while its shell still worked.
#
# Operator rulings 2026-11-05: break-glass is the exit when there is a TOOLING
# DEFECT that blocks a legitimate stop -- a disarm command refused by the
# harness or a permission check, a broken shell, a gate that cannot see a
# reaped holder. It is not another way to stop finished work (that is off,
# then off-confirm) and not a way past a disarm judge that ruled against
# stopping. Its bug report is the record of that defect. And break-glass is
# always honoured: the streak and the failed-shell condition decide only when
# the gate ADVERTISES it, never whether a valid file works.
#
# WD1  the offer is framed around a tooling defect, names the harness or
#      permission-check refusal, and rules out finished work and a judge's no
# WD2  the cap line states its real condition, and only when it can fire
# WD3  a healthy session still never sees either line
# WD4  every line fits the 160-character budget; the idle text stays within
#      stop-gate.sh's 13 lines even with a refused file named
# BG1  a valid file on the very first refusal, before any streak, is honoured
# BG2  so is one after a successful shell call (nothing has visibly failed)
#
# In-process: BpHook::StopGate::run against temp state and data dirs and
# synthetic transcripts. Never touches the real ~/.claude.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_|BUTLER_)/ } keys %ENV;
my $HOME_TMP = tempdir(CLEANUP => 1);
$ENV{HOME} = $ENV{USERPROFILE} = "$HOME_TMP/decoy-home";
$ENV{ALMANAC_HOME} = $ENV{HOME};
make_path($ENV{HOME});

require "$S/BpHook.pm";
require "$S/BpHook/StopGate.pm";

my $CAP = do { no warnings q{once}; $BpHook::StopGate::REFUSAL_CAP };

sub slurp {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub spew_append {
    my ($p, @lines) = @_;
    open(my $fh, '>>:raw', $p) or die "append $p: $!";
    print {$fh} map { "$_\n" } @lines;
    close $fh;
}

my $SEQ = 0;
sub shell_call {
    my ($ok) = @_;
    my $id = 'toolu_' . (++$SEQ);
    my $j = JSON::PP->new->canonical;
    return (
        $j->encode({ type => 'assistant', message => { role => 'assistant',
            content => [ { type => 'tool_use', id => $id, name => 'Bash', input => {} } ] } }),
        $j->encode({ type => 'user', message => { role => 'user',
            content => [ { type => 'tool_result', tool_use_id => $id,
                           ($ok ? () : (is_error => JSON::PP::true())), content => 'x' } ] } }),
    );
}

sub world {
    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/state") =~ s{\\}{/}g;
    my $data = "$t/project/.ccpraxis-local-data";
    make_path($data);
    my $tp = "$t/transcript.jsonl";
    spew_append($tp, '{"type":"user","message":{"role":"user","content":"start"}}');
    my $sid = 'wd-' . (++$SEQ);
    my $w = { root => $root, data => $data, tp => $tp, sid => $sid };
    with_env($w, sub { BpHook::arm($sid, role => 'manual', by => 'arm-on-entry', goal => 'wording test goal') or die 'arm failed' });
    return $w;
}

sub with_env {
    my ($w, $code) = @_;
    local $ENV{BUTLER_STATE_DIR}  = $w->{root};
    local $ENV{CCPRAXIS_DATA_DIR} = $w->{data};
    return $code->();
}

sub stop {
    my ($w) = @_;
    my %p = (session_id => $w->{sid}, hook_event_name => 'Stop',
             stop_hook_active => JSON::PP::false(), cwd => $w->{root}, transcript_path => $w->{tp});
    my (undef, $epath) = tempfile();
    open(my $saved, '>&', \*STDERR) or die;
    close STDERR;
    open(STDERR, '>', $epath) or die;
    my $rc = with_env($w, sub { eval { BpHook::StopGate::run(\%p) } });
    close STDERR;
    open(STDERR, '>&', $saved) or die;
    my $err = slurp($epath);
    unlink $epath;
    return { rc => (defined $rc && $rc == 2 ? 2 : 0), err => $err };
}

sub token_of { my ($r) = @_; return $r->{err} =~ /Stop token: ([0-9a-f]{8})/ ? $1 : undef }
sub armed    { my ($w) = @_; return with_env($w, sub { BpHook::is_armed($w->{sid}) }) }

sub write_glass {
    my ($w, %f) = @_;
    my $dir = "$w->{data}/butler-break-glass";
    make_path($dir);
    open(my $fh, '>:raw', "$dir/$w->{sid}.json") or die;
    print {$fh} (defined $f{raw} ? $f{raw} : JSON::PP->new->encode({ %f }));
    close $fh;
}

sub reports {
    my ($w) = @_;
    my $dir = "$w->{data}/bug-reports";
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\.md\z/ } readdir($dh);
    closedir $dh;
    return @f;
}

my $CAP_LINE = "After $CAP refusals in a row with no tool call succeeding, and the last shell call failed, "
             . "the gate lets the stop through by itself.";

# ===========================================================================
# WD1 / WD2 -- after a failed shell call.
# ===========================================================================
{
    my $w = world();
    stop($w);
    spew_append($w->{tp}, shell_call(0));
    my $r = stop($w);
    is($r->{rc}, 2, 'WD setup: refused');
    my $e = $r->{err};
    like($e, qr/^Tooling defect blocking a legitimate stop\? Break-glass is the exit for that: create this file with the Write tool:$/m,
        'WD1: the offer opens on a tooling defect that blocks a legitimate stop');
    like($e, qr/^  For a defect such as a broken shell, or off-confirm \(or emergency-stop\) refused by the harness or a permission check\.$/m,
        'WD1: it names a disarm refused by the harness or a permission check, not only a broken shell');
    like($e, qr/^  Not for finished work \(use off, then off-confirm\), nor a way past a disarm judge that refused\. /m,
        'WD1: it rules out finished work and a judge that said no');
    like($e, qr/ It turns continuity off and files a bug report on the defect\.$/m,
        'WD1: it still says it only turns continuity off and files a bug report, recording the defect');
    unlike($e, qr/No shell command can run\?/, 'WD1: the old "No shell command can run?" framing is gone');
    unlike($e, qr/only when all work is done/, 'WD1: and so is "only when all work is done", which read as "finished work"');
    like($e, qr/^\Q$CAP_LINE\E$/m, 'WD2: the cap line states both conditions, including the failed last shell call');
}

# WD2 -- a streak with no failed shell call offers the file but not the cap.
{
    my $w = world();
    spew_append($w->{tp}, shell_call(1));
    stop($w);
    my $r = stop($w);
    like($r->{err}, qr/Break-glass is the exit for that/, 'WD2 setup: the second refusal in a row offers break-glass');
    unlike($r->{err}, qr/lets the stop through by itself/,
        'WD2: but the cap is not advertised while the last shell call succeeded: it would never fire');
}

# WD3 -- a healthy first refusal shows neither.
{
    my $w = world();
    spew_append($w->{tp}, shell_call(1));
    my $r = stop($w);
    unlike($r->{err}, qr/Break-glass|Write tool|lets the stop through/, 'WD3: a healthy first refusal advertises neither last resort');
}

# WD4 -- budgets, with a refused file named as well (the longest idle text).
{
    my $w = world();
    stop($w);
    spew_append($w->{tp}, shell_call(0));
    write_glass($w, raw => '{not json');
    my $r = stop($w);
    my @lines = split /\n/, $r->{err};
    like($r->{err}, qr/The break-glass file was not used/, 'WD4 setup: a refused file is named');
    like($r->{err}, qr/^\Q$CAP_LINE\E$/m, 'WD4 setup: and the cap line is shown');
    cmp_ok(scalar(@lines), '<=', 13, 'WD4: the idle text stays within stop-gate.sh\'s 13-line budget (' . scalar(@lines) . ')');
    my @long = grep { length($_) > 160 } @lines;
    is_deeply(\@long, [], 'WD4: every line is at most 160 characters');
}

# ===========================================================================
# BG -- break-glass is honoured whenever the file is valid.
# ===========================================================================
{
    my $w = world();
    my $r1 = stop($w);
    my $t = token_of($r1);
    ok(defined $t, 'BG1 setup: the very first refusal minted a token');
    unlike($r1->{err}, qr/Break-glass/, 'BG1 setup: and did not advertise break-glass');
    my @before = reports($w);
    write_glass($w, token => $t, action => 'off', reason => 'off-confirm denied by the classifier');
    is(stop($w)->{rc}, 0, 'BG1: a valid file after the first refusal, before any streak, lets the stop through');
    ok(!armed($w), 'BG1: and turns continuity off');
    is(scalar(reports($w)), scalar(@before) + 1, 'BG1: and files its bug report');
}
{
    my $w = world();
    spew_append($w->{tp}, shell_call(1));
    my $t = token_of(stop($w));
    write_glass($w, token => $t, action => 'off', reason => 'permission check refused the disarm');
    is(stop($w)->{rc}, 0, 'BG2: honoured after a successful shell call too: advertising is gated, acceptance is not');
    ok(!armed($w), 'BG2: continuity off');
}

done_testing();
