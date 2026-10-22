#!/usr/bin/env perl
# platform: any
# The Stop gate's break-glass pair (bug 20261021-202419-bf19, operator
# decision 2026-10-21).
#
# A session armed with continuity lost its shell: a PreToolUse hook pointed at
# a deleted script, so every Bash and PowerShell call failed before running.
# Every way past the gate (butler-hold, butler-continuity off/silence) is a
# shell command, so the gate refused more than a hundred stops in a row until
# a human noticed. The fix is two last resorts:
#
#   REFUSAL CAP   $REFUSAL_CAP consecutive refusals with no tool call
#                 succeeding in between, and the gate lets the stop through,
#                 logging why. Judged from the transcript bytes appended since
#                 the previous refusal; inert when there is no transcript.
#   BREAK GLASS   a silence or off request written as a file with the Write
#                 tool, carrying the token the last refusal printed. Offered in
#                 the refusal text only once the shell has visibly failed.
#
# In-process: BpHook::StopGate::run against a temp state dir, a temp data dir
# and synthetic transcripts. Never touches the real ~/.claude.
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
make_path($ENV{HOME});

require "$S/BpHook.pm";
require "$S/BpHook/StopGate.pm";

my $CAP  = $BpHook::StopGate::REFUSAL_CAP;
my $HINT = $BpHook::StopGate::BREAK_GLASS_HINT_AT;
ok($CAP >= 2,   "the refusal cap is a real number of refusals ($CAP)");
ok($HINT < $CAP, "the break-glass hint ($HINT) comes before the cap ($CAP)");

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
    my ($ok, $tool) = @_;
    $tool //= 'Bash';
    my $id = 'toolu_' . (++$SEQ);
    my $j = JSON::PP->new->canonical;
    return (
        $j->encode({ type => 'assistant', message => { role => 'assistant',
            content => [ { type => 'tool_use', id => $id, name => $tool, input => {} } ] } }),
        $j->encode({ type => 'user', message => { role => 'user',
            content => [ { type => 'tool_result', tool_use_id => $id,
                           ($ok ? () : (is_error => JSON::PP::true())), content => 'x' } ] } }),
    );
}

# A fresh world: state dir, data dir, transcript, an armed session.
sub world {
    my (%o) = @_;
    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/state") =~ s{\\}{/}g;
    my $data = "$t/project/.ccpraxis-local-data";
    make_path($data) unless $o{no_data_dir};
    my $tp = "$t/transcript.jsonl";
    spew_append($tp, '{"type":"user","message":{"role":"user","content":"start"}}');
    my $sid = 'bg-' . (++$SEQ);
    my $w = { root => $root, data => $data, tp => $tp, sid => $sid, no_data => $o{no_data_dir} };
    with_env($w, sub { BpHook::arm($sid, role => 'manual', by => 'arm-on-entry') or die 'arm failed' })
        unless $o{unarmed};
    return $w;
}

sub with_env {
    my ($w, $code) = @_;
    local $ENV{BUTLER_STATE_DIR}  = $w->{root};
    local $ENV{CCPRAXIS_DATA_DIR} = $w->{data};
    delete local $ENV{CCPRAXIS_DATA_DIR} if $w->{no_data};
    return $code->();
}

# stop($w, %payload_extra) -> { rc, err }. One Stop through the real module.
sub stop {
    my ($w, %extra) = @_;
    my %p = (session_id => $w->{sid}, hook_event_name => 'Stop',
             stop_hook_active => JSON::PP::false(), cwd => $w->{root});
    $p{transcript_path} = $w->{tp} unless $extra{no_transcript};
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
sub reasons  { my ($w) = @_; return slurp("$w->{root}/continuity/reasons.log") }

sub write_glass {
    my ($w, %f) = @_;
    my $dir = $w->{no_data} ? "$w->{root}/continuity/break-glass" : "$w->{data}/butler-break-glass";
    make_path($dir);
    my $path = "$dir/$w->{sid}.json";
    open(my $fh, '>:raw', $path) or die;
    print {$fh} (ref $f{raw} ? '' : defined $f{raw} ? $f{raw} : JSON::PP->new->encode({ %f }));
    close $fh;
    return $path;
}

# ===========================================================================
# CAP -- a shell that fails on every call: refused CAP-1 times, then let go.
# ===========================================================================
{
    my $w = world();
    my @rc;
    for my $i (1 .. $CAP) {
        my $r = stop($w);
        push @rc, $r->{rc};
        spew_append($w->{tp}, shell_call(0));       # the next turn's shell call fails too
    }
    is_deeply([ @rc[0 .. $CAP - 2] ], [ (2) x ($CAP - 1) ],
        "CAP: the first " . ($CAP - 1) . " stops with nothing succeeding are refused");
    is($rc[-1], 0, "CAP: stop $CAP in a row is let through -- the loop ends without a human");
    like(reasons($w), qr/\trefusal-cap\t.*$CAP consecutive refusals/,
        'CAP: the reasons log says the cap fired and why');
    ok(armed($w), 'CAP: the cap lets ONE stop through; it does not disarm the session');
    ok(!-e "$w->{root}/continuity/stop-refusals/$w->{sid}", 'CAP: the streak is reset after firing');
    is(stop($w)->{rc}, 2, 'CAP: the very next stop is refused again -- a fresh streak, not a permanent bypass');
}

# ===========================================================================
# RESET -- a tool call that succeeds in between means the session is not
# stuck, so the streak starts over. Positive control for CAP.
# ===========================================================================
{
    my $w = world();
    stop($w) for 1 .. $CAP - 2;
    spew_append($w->{tp}, shell_call(1, 'Read'));
    my @after = map { my $r = stop($w); spew_append($w->{tp}, shell_call(0)); $r->{rc} } 1 .. $CAP - 1;
    is_deeply(\@after, [ (2) x ($CAP - 1) ],
        'RESET: one successful tool call restarts the count -- ' . ($CAP - 1) . ' more refusals before the cap');
    is(stop($w)->{rc}, 0, 'RESET: and the cap still fires once the streak really reaches it');
}

# ===========================================================================
# INERT -- no transcript, no cap and no hint: "stuck" cannot be told from
# "busy", and the gate must not guess.
# ===========================================================================
{
    my $w = world();
    my @rc = map { stop($w, no_transcript => 1)->{rc} } 1 .. $CAP + 3;
    is_deeply(\@rc, [ (2) x ($CAP + 3) ], 'INERT: without a transcript every stop is refused, past the cap');
    unlike(stop($w, no_transcript => 1)->{err}, qr/break-glass|Write tool/i,
        'INERT: and the break-glass escape is never offered');
}

# ===========================================================================
# HINT -- the Write-tool escape appears only once the shell has visibly failed.
# ===========================================================================
{
    my $w = world();
    my $r1 = stop($w);
    is($r1->{rc}, 2, 'HINT setup: first stop refused');
    unlike($r1->{err}, qr/Write tool/, 'HINT: a first refusal does not offer the break-glass file');

    spew_append($w->{tp}, shell_call(0, 'PowerShell'));
    my $r2 = stop($w);
    my $t2 = token_of($r2);
    like($r2->{err}, qr/Last resort: create this file with the Write tool/,
        'HINT: after a failed shell call, the refusal offers the break-glass file');
    my $want = BpHook::StopGate::_display_path("$w->{data}/butler-break-glass/$w->{sid}.json");
    like($r2->{err}, qr/\Q$want\E/, 'HINT: it names the project data-dir path');
    like($r2->{err}, qr/"token":"\Q$t2\E"/, 'HINT: with the current token filled in');
}

# A healthy session that keeps working between stops never sees the hint.
{
    my $w = world();
    my $saw = 0;
    for (1 .. 4) {
        $saw++ if stop($w)->{err} =~ /Write tool/;
        spew_append($w->{tp}, shell_call(1));
    }
    is($saw, 0, 'HINT: a session whose shell works never sees the break-glass offer');
}

# ===========================================================================
# GLASS -- the file itself.
# ===========================================================================
{
    my $w = world();
    my $t = token_of(stop($w));
    ok(defined $t, 'GLASS setup: a refusal minted a token');
    my $f = write_glass($w, token => $t, action => 'silence', reason => 'shell is broken, talking to operator');
    is(stop($w)->{rc}, 0, 'GLASS silence: a valid file lets the stop through');
    ok(!-e $f, 'GLASS silence: the file is consumed');
    ok(armed($w), 'GLASS silence: continuity stays on');
    like(reasons($w), qr/\tbreak-glass-silence\t.*shell is broken/, 'GLASS silence: logged with its reason');
    is(stop($w)->{rc}, 2, 'GLASS silence: one stop only -- the next is refused again');
}
{
    my $w = world();
    my $t = token_of(stop($w));
    write_glass($w, token => $t, action => 'off', reason => 'all work done here');
    is(stop($w)->{rc}, 0, 'GLASS off: a valid file lets the stop through');
    ok(!armed($w), 'GLASS off: and continuity is off');
    like(slurp("$w->{root}/continuity/off/$w->{sid}"), qr/break-glass: all work done here/,
        'GLASS off: the off record carries the reason');
}
{
    my $w = world(no_data_dir => 1);
    my $r = stop($w);
    my $t = token_of($r);
    my $f = write_glass($w, token => $t, action => 'silence', reason => 'no data dir here');
    is(stop($w)->{rc}, 0, 'GLASS fallback: without a project data dir the state-dir path works');
    ok(!-e $f, 'GLASS fallback: and is consumed');
}

# Refusals: each is consumed, refused, and says why in the next refusal.
for my $case (
    [ 'wrong token',      sub { (token => 'deadbeef', action => 'silence', reason => 'two words') },
      qr/token is not the one the last refusal printed/ ],
    [ 'unknown action',   sub { (token => $_[0], action => 'leave', reason => 'two words') },
      qr/action must be "silence" or "off"/ ],
    [ 'one-word reason',  sub { (token => $_[0], action => 'silence', reason => 'because') },
      qr/reason must be at least two words/ ],
    [ 'not JSON',         sub { (raw => '{not json') },
      qr/not a JSON object/ ],
) {
    my ($label, $fields, $why) = @$case;
    my $w = world();
    my $t = token_of(stop($w));
    my $f = write_glass($w, $fields->($t));
    my $r = stop($w);
    is($r->{rc}, 2, "GLASS refused ($label): the stop is refused");
    ok(!-e $f, "GLASS refused ($label): the file is consumed anyway, so it cannot act later");
    like($r->{err}, $why, "GLASS refused ($label): the refusal says why the file was not used");
    ok(armed($w), "GLASS refused ($label): continuity is untouched");
}

# A stale file must not act on a later turn: the token it carries is dead.
{
    my $w = world();
    my $old = token_of(stop($w));
    stop($w);                                    # a newer refusal; $old is revoked
    write_glass($w, token => $old, action => 'off', reason => 'stale request here');
    is(stop($w)->{rc}, 2, 'GLASS stale: a file naming an older token is refused');
    ok(armed($w), 'GLASS stale: and does not disarm');
}

# An unarmed session: the file is cleaned up and nothing else happens.
{
    my $w = world(unarmed => 1);
    my $f = write_glass($w, token => 'deadbeef', action => 'off', reason => 'not armed at all');
    is(stop($w)->{rc}, 0, 'GLASS unarmed: an unarmed session is allowed as always');
    ok(!-e $f, 'GLASS unarmed: and a leftover file is removed');
}

# ===========================================================================
# ROTATED / TRUNCATED -- the streak's byte offset belongs to one transcript
# file. A different transcript (a resumed or relocated session) or one cut
# shorter than the offset starts a fresh streak; scanning the wrong bytes
# must never be what tips the gate over the cap.
# ===========================================================================
{
    my $w = world();
    stop($w) for 1 .. $CAP - 1;                  # one refusal short of the cap
    my $other = "$w->{tp}.rotated.jsonl";
    spew_append($other, ('{"type":"user","message":{"role":"user","content":"padding"}}') x 50);
    ok(-s $other > -s $w->{tp}, 'ROTATED setup: the other transcript is longer than the stored offset');
    $w->{tp} = $other;
    is(stop($w)->{rc}, 2, 'ROTATED: a stop under another transcript path starts a fresh streak, not the capped one');
    my $rec = JSON::PP->new->utf8->decode(slurp("$w->{root}/continuity/stop-refusals/$w->{sid}"));
    is($rec->{count}, 1, 'ROTATED: the streak record restarted at 1');
    is($rec->{transcript}, $other, 'ROTATED: and now names the transcript it measured');
}
{
    my $w = world();
    stop($w) for 1 .. $CAP - 1;
    open(my $fh, '>:raw', $w->{tp}) or die;      # truncated below the stored offset
    close $fh;
    is(stop($w)->{rc}, 2, 'TRUNCATED: a transcript shorter than the stored offset starts a fresh streak');
}

# ===========================================================================
# GC -- a session that ends mid-streak leaves its streak record and a
# state-dir break-glass file behind; gc_sessions removes them with the rest
# of that session's state once its transcript is gone.
# ===========================================================================
{
    my $w = world(no_data_dir => 1);
    with_env($w, sub { BpHook::arm($w->{sid}, role => 'manual', by => 'on', transcript_path => $w->{tp}) });
    stop($w);
    my $streak = "$w->{root}/continuity/stop-refusals/$w->{sid}";
    ok(-e $streak, 'GC setup: a refusal left a streak record');
    my $glass = write_glass($w, token => 'deadbeef', action => 'off', reason => 'never read back');
    unlink $w->{tp} or die "unlink transcript: $!";
    my $n = with_env($w, sub { BpHook::gc_sessions() });
    is($n, 1, 'GC: the session whose transcript is gone is collected');
    ok(!-e $streak, 'GC: its stop-refusals record is removed');
    ok(!-e $glass,  'GC: its state-dir break-glass file is removed');
}

done_testing();
