#!/usr/bin/env perl
# platform: any
# The continuity state guard: an agent that hand-edits its armed record, or
# appends a forged human line to its own transcript so that a later
# butler-continuity off reads as operator-typed (red-team M1 of
# judged-continuity-disarm/02), is refused and pointed at butler-continuity
# and butler-hold. Guidance for a cooperating agent, not a security
# boundary (operator ruling 2026-10-23), so only the plain shapes are
# pinned here: edit tools aimed at the state dir or the transcript, and a
# Bash command that names one of them and writes. Reads, the Stop gate's
# break-glass file, and everything else pass.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use HostCaps qw(tempdir_args);
use GuardHarness;

my $T = tempdir(tempdir_args(), CLEANUP => 1);
$T =~ s{\\}{/}g;
my $BSD   = "$T/state";
my $STATE = "$BSD/continuity";
my $SID   = 'sess-guard-cs-1';
my $TP    = "$T/projects/proj/$SID.jsonl";
my $PROJ  = "$T/proj";

sub run_guard {
    my ($tool, $ti) = @_;
    my $p = {
        session_id      => $SID,
        transcript_path => $TP,
        cwd             => $PROJ,
        hook_event_name => 'PreToolUse',
        tool_name       => $tool,
        tool_input      => $ti,
    };
    return GuardHarness::run_module('Guards::GuardContinuityState', $p,
        env => { BUTLER_STATE_DIR => $BSD });
}

sub denied {
    my ($res, $name) = @_;
    is($res->{rc}, 2, "$name: denied");
    my @lines = grep { length } split /\r?\n/, $res->{err};
    cmp_ok(scalar(@lines), '<=', 2, "$name: at most 2 lines");
    cmp_ok(length($_), '<=', 160, "$name: line within 160 chars") for @lines;
    like($res->{err}, qr/butler-continuity and butler-hold/, "$name: names the CLI");
    is($res->{out}, '', "$name: nothing on stdout");
}

sub allowed {
    my ($res, $name) = @_;
    is($res->{rc}, 0, "$name: allowed");
    is($res->{err}, '', "$name: silent");
}

# Edit tools.
denied(run_guard('Write', { file_path => "$STATE/armed/$SID", content => '{}' }),
    'Write to state/continuity/armed/<sid>');
denied(run_guard('Edit', { file_path => $TP, old_string => 'a', new_string => 'b' }),
    'Edit of the session transcript');
(my $tp_back = $TP) =~ tr{/}{\\};
denied(run_guard('MultiEdit', { file_path => $tp_back, edits => [] }),
    'MultiEdit of the transcript spelled with backslashes');
allowed(run_guard('Write', { file_path => "$STATE/break-glass/$SID.json", content => '{}' }),
    'Write of the Stop gate break-glass file');
allowed(run_guard('Write', { file_path => "$PROJ/notes.md", content => 'x' }),
    'Write elsewhere');
allowed(run_guard('Write', { file_path => "$T/projects/proj/other-session.jsonl", content => 'x' }),
    'Write of a different transcript');

# Bash.
denied(run_guard('Bash', { command => "rm $STATE/armed/x" }),
    'Bash rm under the state dir');
denied(run_guard('Bash', { command => qq{echo '{"type":"user"}' >> "$TP"} }),
    'Bash append to the transcript');
denied(run_guard('Bash', { command => "sed -i 's/a/b/' ~/.claude/butler-state/continuity/armed/$SID" }),
    'Bash sed -i on the literal butler-state/continuity path');
denied(run_guard('Bash', { command => "cd ~/.claude/projects/proj && printf x >> $SID.jsonl" }),
    'Bash append naming the transcript basename only');
allowed(run_guard('Bash', { command => "cat $STATE/armed/$SID" }),
    'Bash cat of the armed record');
allowed(run_guard('Bash', { command => "tail -n 5 $TP 2>/dev/null" }),
    'Bash tail of the transcript');
allowed(run_guard('Bash', { command => "grep -c 'a>b' $TP && perl -ne 'print if 1' $TP | wc -l" }),
    'Bash grep and perl -ne reads of the transcript');
allowed(run_guard('Bash', { command => "rm -rf $PROJ/build > /tmp/log" }),
    'Bash command naming neither location');
allowed(run_guard('Bash', { command => "butler-continuity off --reason 'all done' --token abc" }),
    'the CLI itself');
allowed(run_guard('Bash', { command => "echo '{}' > $STATE/break-glass/$SID.json" }),
    'Bash write of the break-glass file');

# Other tools never deny.
allowed(run_guard('Read', { file_path => $TP }), 'Read of the transcript');

# Through the real wrapper: the --pre clause lets a state-dir payload reach
# perl, and the deny still comes out.
{
    my $p = { session_id => $SID, transcript_path => $TP, cwd => $PROJ, hook_event_name => 'PreToolUse',
              tool_name => 'Bash', tool_input => { command => "rm -f $STATE/armed/$SID" } };
    my $res = GuardHarness::run_wrapper("$Bin/../../hooks/guard-continuity-state.sh", $p,
        env => { BUTLER_STATE_DIR => $BSD });
    is($res->{rc}, 2, 'wrapper: rm of the armed record is denied end to end');
    like($res->{err}, qr/CONTINUITY-STATE-GUARD/, 'wrapper: the deny text reaches stderr');
}

done_testing();
