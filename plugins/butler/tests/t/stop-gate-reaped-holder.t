#!/usr/bin/env perl
# platform: any
# The Stop gate and Claude Code's low-memory reaper (bug 20261105-143727-3d66).
#
# Session 3f77dfd2, 2026-11-05: the reaper killed an armed session's
# background butler-hold and the wait it held, and told the agent "do not
# start it again on your own". Every remaining step needed the operator, so
# the session could not hold again, and the gate refused every stop because
# continuity was on and no holder ran. The harness records such a kill in the
# transcript as a task-notification with <status>killed</status> and "stopped
# because the system is running low on memory".
#
# The fix (G8c): when the session's most recent holder, or a task it held, was
# reaped like that, the gate lets the turn end with continuity LEFT ON, logs
# `holder-reaped` (reasons.log and hook-errors.log), and remembers that reap so
# it is acted on once. The session then idles and resumes when woken.
#
# RP1  a reaped holder lets the stop through; continuity stays armed; logged
# RP2  a reaped held task (named in the holder's own command) counts too
# RP3  the holder record alone (launch outside the transcript window) counts
# RP4  one reap is acted on once: the next stop is refused again
# ST1  stale: a reap from before the holder started does not count
# ST2  stale: a reap from before the last refusal does not count
# ST3  stale: a holder started after the reap supersedes it
# NR1  a kill that was not the low-memory reaper (TaskStop) does not count
# NR2  a reap of a task the holder never held does not count
# NR3  a notification quoted inside a tool result does not count
# NR4  no transcript: inert
# CAP  the refusal cap is unchanged: fires at REFUSAL_CAP only after a failed
#      shell call, never for text-only stops
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
my $J   = JSON::PP->new->canonical;

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

sub iso {
    my @t = gmtime($_[0]);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02d.123Z', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]);
}

my $SEQ = 0;

# A background Bash launch and its result, as Claude Code writes them.
sub bg_launch {
    my (%a) = @_;
    my $id = 'toolu_l' . (++$SEQ);
    return (
        $J->encode({ type => 'assistant', timestamp => iso($a{at}), message => { role => 'assistant',
            content => [ { type => 'tool_use', id => $id, name => 'Bash',
                           input => { command => $a{cmd}, run_in_background => JSON::PP::true() } } ] } }),
        $J->encode({ type => 'user', timestamp => iso($a{at}), message => { role => 'user',
            content => [ { type => 'tool_result', tool_use_id => $id,
                           content => "Command running in background with ID: $a{task}. Output is being written to: x/$a{task}.output" } ] },
            toolUseResult => { backgroundTaskId => $a{task}, stdout => '', stderr => '' } }),
    );
}

sub shell_call {
    my ($ok) = @_;
    my $id = 'toolu_s' . (++$SEQ);
    return (
        $J->encode({ type => 'assistant', message => { role => 'assistant',
            content => [ { type => 'tool_use', id => $id, name => 'Bash', input => {} } ] } }),
        $J->encode({ type => 'user', message => { role => 'user',
            content => [ { type => 'tool_result', tool_use_id => $id,
                           ($ok ? () : (is_error => JSON::PP::true())), content => 'x' } ] } }),
    );
}

# The notification text, byte for byte the shape session 3f77dfd2 recorded.
sub notification_text {
    my (%a) = @_;
    my $status  = $a{status} // 'killed';
    my $summary = $a{summary}
        // "Background command \"Hold on the cheap wait\" was stopped because the system is running low on memory";
    return "<task-notification>\n<task-id>$a{task}</task-id>\n<tool-use-id>toolu_x</tool-use-id>\n"
         . "<output-file>C:\\x\\$a{task}.output</output-file>\n<status>$status</status>\n"
         . "<summary>$summary</summary>\n"
         . "<note>This is not a failure of the command. Do not start it again on your own.</note>\n"
         . "</task-notification>";
}

# The user record the harness writes for it (the queue-operation twin too).
sub reap_notice {
    my (%a) = @_;
    my $text = notification_text(%a);
    return (
        $J->encode({ type => 'queue-operation', operation => 'enqueue', timestamp => iso($a{at}), content => $text }),
        $J->encode({ type => 'user', timestamp => iso($a{at}), message => { role => 'user', content => $text },
                     origin => { kind => 'task-notification' }, promptSource => 'system' }),
    );
}

sub world {
    my (%o) = @_;
    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/state") =~ s{\\}{/}g;
    my $data = "$t/project/.ccpraxis-local-data";
    make_path($data);
    my $tp = "$t/transcript.jsonl";
    spew_append($tp, '{"type":"user","message":{"role":"user","content":"start"}}');
    my $sid = 'rp-' . (++$SEQ);
    my $w = { root => $root, data => $data, tp => $tp, sid => $sid };
    with_env($w, sub { BpHook::arm($sid, role => 'manual', by => 'arm-on-entry') or die 'arm failed' });
    return $w;
}

sub with_env {
    my ($w, $code) = @_;
    local $ENV{BUTLER_STATE_DIR}  = $w->{root};
    local $ENV{CCPRAXIS_DATA_DIR} = $w->{data};
    return $code->();
}

# A holder record exactly as butler-hold writes it, for a process that is gone.
sub holder_record {
    my ($w, %r) = @_;
    my $dir = "$w->{root}/continuity/holder";
    make_path($dir);
    open(my $fh, '>:raw', "$dir/$w->{sid}.json") or die;
    print {$fh} $J->encode({ session_id => $w->{sid}, token => 'deadbeef', pid => 999999, fp => 'f' x 40,
        items => $r{items}, held => $r{items}, ext_seq => 0, outputs => {},
        started_at => $r{started_at}, deadline => $r{started_at} + 3000,
        transcript_path => $w->{tp}, (defined $r{self_task} ? (self_task => $r{self_task}) : ()) });
    close $fh;
}

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

sub armed   { my ($w) = @_; return with_env($w, sub { BpHook::is_armed($w->{sid}) }) }
sub reasons { my ($w) = @_; return slurp("$w->{root}/continuity/reasons.log") }

my $now = time();
my $HOLD_CMD = 'butler-hold --token abcd1234 bwait1';

# The incident: a background wait, a holder on it, both reaped.
sub reaped_world {
    my (%o) = @_;
    my $w = world();
    spew_append($w->{tp}, bg_launch(at => $now - 600, task => 'bwait1', cmd => 'sleep 3000'));
    spew_append($w->{tp}, bg_launch(at => $now - 590, task => 'bhold1', cmd => $HOLD_CMD));
    holder_record($w, items => ['bwait1'], started_at => $now - 588, self_task => 'bhold1');
    spew_append($w->{tp}, reap_notice(at => $now - 60, task => $_)) for @{ $o{reaped} // ['bwait1', 'bhold1'] };
    return $w;
}

# ===========================================================================
# RP1 -- the incident itself.
# ===========================================================================
{
    my $w = reaped_world();
    my $r = stop($w);
    is($r->{rc}, 0, 'RP1: a holder reaped by the low-memory reaper lets the stop through');
    ok(armed($w), 'RP1: and continuity is LEFT ON, so the session idles and resumes when woken');
    like(reasons($w), qr/\tholder-reaped\t.*bhold1/, 'RP1: reasons.log has a holder-reaped line naming the reaped task');
    like($r->{err}, qr/^stop-gate: holder-reaped: /m, 'RP1: and a hook-errors.log line (the gate warn)');
    unlike($r->{err}, qr/Stop token:/, 'RP1: no refusal text is printed');
    ok(!-e "$w->{root}/continuity/off/$w->{sid}", 'RP1: no off record is written');

    # RP4 -- acted on once.
    my $r2 = stop($w);
    is($r2->{rc}, 2, 'RP4: the next stop is refused again: one reap lets one stop through');
    my @lines = grep { /\tholder-reaped\t/ } split /\n/, reasons($w);
    is(scalar(@lines), 1, 'RP4: and only one holder-reaped line was logged');
}

# RP2 -- only the held wait was reaped; it is named in the holder's command.
{
    my $w = world();
    spew_append($w->{tp}, bg_launch(at => $now - 600, task => 'bwait1', cmd => 'sleep 3000'));
    spew_append($w->{tp}, bg_launch(at => $now - 590, task => 'bhold1', cmd => $HOLD_CMD));
    spew_append($w->{tp}, reap_notice(at => $now - 60, task => 'bwait1'));
    is(stop($w)->{rc}, 0, 'RP2: a reaped task the latest holder waited on lets the stop through (no holder record needed)');
    ok(armed($w), 'RP2: continuity stays on');
}

# RP3 -- the launch fell out of the scanned window; the holder record names it.
{
    my $w = world();
    holder_record($w, items => ['bwait1'], started_at => $now - 588, self_task => 'bhold1');
    spew_append($w->{tp}, reap_notice(at => $now - 60, task => 'bhold1'));
    is(stop($w)->{rc}, 0, 'RP3: the holder record\'s own task, reaped after it started, counts');
    ok(armed($w), 'RP3: continuity stays on');
}

# ===========================================================================
# ST -- stale reaps.
# ===========================================================================
{
    my $w = world();
    spew_append($w->{tp}, reap_notice(at => $now - 900, task => 'bhold1'));
    holder_record($w, items => ['bwait1'], started_at => $now - 600, self_task => 'bhold1');
    is(stop($w)->{rc}, 2, 'ST1: a reap from before the holder record started does not count');
    ok(armed($w), 'ST1: continuity on');
    unlike(reasons($w), qr/\tholder-reaped\t/, 'ST1: nothing logged as holder-reaped');
}
{
    my $w = reaped_world();
    # The last refusal was recorded after the reap was already in the transcript.
    my $dir = "$w->{root}/continuity/stop-refusals";
    make_path($dir);
    open(my $fh, '>:raw', "$dir/$w->{sid}") or die;
    print {$fh} JSON::PP->new->utf8->canonical->encode(
        { count => 1, offset => -s $w->{tp}, shell_failed => 0, transcript => $w->{tp} }), "\n";
    close $fh;
    is(stop($w)->{rc}, 2, 'ST2: a reap from before the last refusal does not count');
    unlike(reasons($w), qr/\tholder-reaped\t/, 'ST2: nothing logged as holder-reaped');
}
{
    my $w = world();
    spew_append($w->{tp}, bg_launch(at => $now - 600, task => 'bhold1', cmd => $HOLD_CMD));
    spew_append($w->{tp}, reap_notice(at => $now - 300, task => 'bhold1'));
    spew_append($w->{tp}, bg_launch(at => $now - 200, task => 'bhold2', cmd => 'butler-hold --token 1234abcd bwait2'));
    is(stop($w)->{rc}, 2, 'ST3: a holder started after the reap supersedes it (that holder finished normally)');
}

# ===========================================================================
# NR -- not a low-memory reap of this session's holder.
# ===========================================================================
{
    my $w = world();
    spew_append($w->{tp}, bg_launch(at => $now - 600, task => 'bhold1', cmd => $HOLD_CMD));
    spew_append($w->{tp}, reap_notice(at => $now - 60, task => 'bhold1',
        summary => 'Background command "Hold on the cheap wait" was stopped'));
    is(stop($w)->{rc}, 2, 'NR1: a kill without the low-memory note (a TaskStop, say) does not count');
}
{
    my $w = world();
    spew_append($w->{tp}, bg_launch(at => $now - 600, task => 'bhold1', cmd => $HOLD_CMD));
    spew_append($w->{tp}, reap_notice(at => $now - 60, task => 'bother9'));
    is(stop($w)->{rc}, 2, 'NR2: a reap of a task the holder never held does not count');
}
{
    my $w = world();
    spew_append($w->{tp}, bg_launch(at => $now - 600, task => 'bhold1', cmd => $HOLD_CMD));
    my $id = 'toolu_q' . (++$SEQ);
    spew_append($w->{tp},
        $J->encode({ type => 'assistant', message => { role => 'assistant',
            content => [ { type => 'tool_use', id => $id, name => 'Bash', input => { command => 'cat t.jsonl' } } ] } }),
        $J->encode({ type => 'user', timestamp => iso($now - 30), message => { role => 'user',
            content => [ { type => 'tool_result', tool_use_id => $id, content => notification_text(task => 'bhold1') } ] } }));
    is(stop($w)->{rc}, 2, 'NR3: a notification merely quoted inside a tool result does not count');
}
{
    my $w = reaped_world();
    is(stop($w, no_transcript => 1)->{rc}, 2, 'NR4: without a transcript the gate cannot see a reap and refuses as before');
}

# ===========================================================================
# CAP -- unchanged by the new branch.
# ===========================================================================
{
    my $w = world();
    my @rc;
    for (1 .. $CAP) {
        push @rc, stop($w)->{rc};
        spew_append($w->{tp}, shell_call(0));
    }
    is_deeply([ @rc[0 .. $CAP - 2] ], [ (2) x ($CAP - 1) ], 'CAP: the first ' . ($CAP - 1) . ' stops are refused');
    is($rc[-1], 0, "CAP: stop $CAP in a row, last shell call failed, is let through");
    like(reasons($w), qr/\trefusal-cap\t/, 'CAP: logged as refusal-cap, not holder-reaped');
    unlike(reasons($w), qr/\tholder-reaped\t/, 'CAP: the reap branch never fired');
    ok(armed($w), 'CAP: continuity stays on');
}
{
    my $w = world();
    spew_append($w->{tp}, shell_call(1));
    my @rc = map { stop($w)->{rc} } 1 .. $CAP + 2;
    is_deeply(\@rc, [ (2) x ($CAP + 2) ], 'CAP: text-only stops after a successful shell call never reach the cap');
}

done_testing();
