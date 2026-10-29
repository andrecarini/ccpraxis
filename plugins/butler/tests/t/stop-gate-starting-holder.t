#!/usr/bin/env perl
# platform: any
# The Stop gate never asks the agent to hold its own holder.
#
# Bug report 20261027-201709-afa0 (acxpraxis, 2026-10-27): after
# `butler-hold --token T <ids>` was started in the background, the next Stop
# listed the holder's own task id among the running work and suggested a hold
# that included it; butler-hold refuses that ("a holder cannot hold itself").
# Measured from that session's transcript: the holder started at 18:02:10.97,
# the gate fired at 18:02:14.78 naming it, and the holder's record (what G8
# reads) appeared at 18:02:21. The holder excluded itself only once that
# record existed, so every Stop inside the startup window hit the bug.
#
# AC1  holder_launches finds background Bash calls that are exactly one
#      butler-hold invocation, from toolUseResult or the result text, and
#      nothing else (chained, foreground, other commands)
# AC2  starting_holder: running + launched within the window, only
# AC3  running_work never lists a butler-hold task
# AC4  the real gate lets the stop through while a holder is starting
# AC5  past the window it denies, and the suggested hold omits the holder
#
# Every state root is a fresh temp dir; HOME/USERPROFILE are decoys.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP ();
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep);

(my $BUTLER = "$Bin/../..") =~ s{\\}{/}g;
my $HOOK = "$BUTLER/hooks/stop-gate.sh";
require "$BUTLER/scripts/BpHook.pm";

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
my $TMP = tempdir(CLEANUP => 1); $TMP =~ s{\\}{/}g;
my $HOME = "$TMP/decoy-home";
my $PROJECT = "$TMP/project";
make_path($HOME, $PROJECT);
$ENV{HOME} = $ENV{USERPROFILE} = $HOME;
delete $ENV{BUTLER_STATE_DIR};

my $BASH = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve bash') unless length $BASH;

my $J = JSON::PP->new->utf8->canonical;
sub iso { my @t = gmtime($_[0]); sprintf('%04d-%02d-%02dT%02d:%02d:%02d.123Z', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]) }

# A Bash call and its result, as Claude Code writes them to the transcript.
sub bash_pair {
    my (%a) = @_;
    my $use = { type => 'assistant', timestamp => iso($a{at}), message => { role => 'assistant', content => [
        { type => 'tool_use', id => $a{tuid}, name => 'Bash',
          input => { command => $a{cmd}, ($a{bg} ? (run_in_background => JSON::PP::true()) : ()) } } ] } };
    my $text = $a{bg} ? "Command running in background with ID: $a{task}. Output is being written to: x/$a{task}.output"
                      : 'held';
    my $res = { type => 'user', timestamp => iso($a{at}), message => { role => 'user', content => [
        { type => 'tool_result', tool_use_id => $a{tuid},
          content => ($a{array} ? [ { type => 'text', text => $text } ] : $text) } ] },
        ($a{bg} && !$a{no_tur} ? (toolUseResult => { backgroundTaskId => $a{task}, stdout => '', stderr => '' }) : ()) };
    return $J->encode($use) . "\n" . $J->encode($res) . "\n";
}

sub transcript {
    my ($name, $holder_at) = @_;
    my $tp = "$PROJECT/$name.jsonl";
    open my $fh, '>:raw', $tp or die $!;
    print $fh $J->encode({ type => 'user', message => { role => 'user', content => 'go' } }), "\n";
    print $fh bash_pair(tuid => 'tu1', at => time() - 30, bg => 1, task => 'bwork1', cmd => 'npm run build');
    print $fh bash_pair(tuid => 'tu2', at => time() - 20, bg => 1, task => 'bchain1', cmd => 'butler-hold a1 && sleep 999');
    print $fh bash_pair(tuid => 'tu3', at => time() - 20, bg => 0, task => 'none', cmd => 'butler-hold a1');
    print $fh bash_pair(tuid => 'tu4', at => time() - 25, bg => 1, task => 'btext1', no_tur => 1, array => 1,
                        cmd => 'perl /x/butler-hold.pl a9');
    print $fh bash_pair(tuid => 'tu5', at => $holder_at, bg => 1, task => 'bholder1',
                        cmd => 'butler-hold --token abcd1234 a0123456789abcdef bwork1');
    close $fh;
    return $tp;
}

sub bgt { my ($id, $type, $st) = @_; { id => $id, type => $type, status => $st // 'running', description => "t $id" } }
my @BG = (bgt('a0123456789abcdef', 'subagent'), bgt('bwork1', 'shell'), bgt('bchain1', 'shell'),
          bgt('btext1', 'shell', 'completed'), bgt('bholder1', 'shell'));

# --- AC1 ---------------------------------------------------------------------------------------------
{
    my $tp = transcript('ac1', time() - 2);
    my $l = BpHook::holder_launches({ transcript_path => $tp });
    is_deeply([sort keys %$l], [qw(bholder1 btext1)],
              'AC1 sole background butler-hold calls only (not chained, not foreground, not other commands)');
    ok(defined $l->{bholder1} && abs($l->{bholder1} - (time() - 2)) <= 2, 'AC1 launch time read from the transcript');
    ok(exists $l->{btext1}, 'AC1 id found in the result text when toolUseResult is absent');
    is_deeply(BpHook::holder_launches({ transcript_path => "$PROJECT/missing.jsonl" }), {}, 'AC1 no transcript: none');
    is_deeply(BpHook::holder_launches({}), {}, 'AC1 no transcript path: none');
}

# --- AC2 ---------------------------------------------------------------------------------------------
{
    my $l = { bholder1 => time() - 3 };
    is(BpHook::starting_holder({ background_tasks => \@BG }, $l), 'bholder1', 'AC2 running and fresh: a starting holder');
    is(BpHook::starting_holder({ background_tasks => \@BG }, { bholder1 => time() - $BpHook::HOLDER_START_SECONDS - 5 }),
       undef, 'AC2 past the window: no longer trusted');
    is(BpHook::starting_holder({ background_tasks => [ bgt('bholder1', 'shell', 'completed') ] }, $l),
       undef, 'AC2 a finished holder task is not starting');
    is(BpHook::starting_holder({ background_tasks => \@BG }, { bholder1 => undef }), undef, 'AC2 no timestamp: not trusted');
    is(BpHook::starting_holder({ background_tasks => \@BG }, {}), undef, 'AC2 no launches: none');
}

# --- gate harness ------------------------------------------------------------------------------------
my $sidn = 0;
sub new_session {
    my $root = tempdir(DIR => $TMP, CLEANUP => 1); $root =~ s{\\}{/}g;
    my $sid = sprintf('sgsh-%04x-%08x', ++$sidn, int(rand(0xffffffff)));
    local $ENV{BUTLER_STATE_DIR} = $root;
    BpHook::arm($sid, role => 'manual', by => 'arm-on-entry') or die "arm failed";
    return ($root, $sid);
}

sub run_gate {
    my ($root, $payload) = @_;
    my ($pfh, $pp) = tempfile(DIR => $TMP); print $pfh $J->encode($payload); close $pfh;
    my (undef, $op) = tempfile(DIR => $TMP);
    my (undef, $ep) = tempfile(DIR => $TMP);
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {
        $ENV{BUTLER_STATE_DIR} = $root;
        open(STDIN, '<', $pp) or _exit(126);
        open(STDOUT, '>', $op) or _exit(126);
        open(STDERR, '>', $ep) or _exit(126);
        { no warnings 'exec'; exec($BASH, $HOOK) }
        _exit(127);
    }
    my ($rc, $deadline) = (undef, time() + 20);
    while (time() < $deadline) {
        if (waitpid($pid, WNOHANG) == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    my $err = do { local $/; open my $fh, '<:raw', $ep; <$fh> } // '';
    return ($rc, $err);
}

sub payload {
    my ($sid, $tp) = @_;
    return { session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false(),
             transcript_path => $tp, cwd => $PROJECT, background_tasks => \@BG };
}

# --- AC3 ---------------------------------------------------------------------------------------------
{
    my ($root, $sid) = new_session();
    my $tp = transcript('ac3', time() - 2);
    local $ENV{BUTLER_STATE_DIR} = $root;
    my $l = BpHook::holder_launches({ transcript_path => $tp });
    my @ids = map { $_->{id} } BpHook::running_work($sid, payload($sid, $tp), $l);
    is_deeply(\@ids, [qw(a0123456789abcdef bwork1 bchain1)],
              'AC3 running work keeps real work (even a chained butler-hold) and drops the holder task');
}

# --- AC4 ---------------------------------------------------------------------------------------------
{
    my ($root, $sid) = new_session();
    my $tp = transcript('ac4', time() - 3);
    my ($rc, $err) = run_gate($root, payload($sid, $tp));
    is($rc, 0, 'AC4 a holder started 3 s ago lets the stop through') or diag($err);
    unlike($err, qr/Stop token/, 'AC4 and nothing is asked of the agent');
    my $log = do { local $/; open my $fh, '<:raw', "$root/continuity/reasons.log"; <$fh> } // '';
    like($log, qr/\tgate\tholder-starting\t.*\tbholder1$/m, 'AC4 the pass is logged with the holder id');
}

# --- AC5 ---------------------------------------------------------------------------------------------
{
    my ($root, $sid) = new_session();
    my $tp = transcript('ac5', time() - $BpHook::HOLDER_START_SECONDS - 60);
    my ($rc, $err) = run_gate($root, payload($sid, $tp));
    is($rc, 2, 'AC5 a holder that never became within the window: the gate denies');
    my ($hold) = $err =~ /^\s*(butler-hold --token \S+ .*)$/m;
    ok(defined $hold, 'AC5 a hold is suggested') or diag($err);
    unlike($hold // '', qr/\bbholder1\b/, 'AC5 THE BUG: the suggested hold never names the holder itself');
    like($hold // '', qr/\ba0123456789abcdef\b.*\bbwork1\b/, 'AC5 it names the real running work');
    unlike($err, qr/still running: [^\n]*bholder1/, 'AC5 the holder is not listed as running work');
}

done_testing();
