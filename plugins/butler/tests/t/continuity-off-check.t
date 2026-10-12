#!/usr/bin/env perl
# platform: any
# NEW oracle for blueprint where-things-go, package 03-thread-sessions:
# ContinuityOffCheck's extension to write `almanac-thread` / `almanac-todo`
# tickets (Decision 18 F6/F7), covering AC13 of
# specs/03-thread-sessions-spec.md section 4 (behaviour 13; @THREAD_GATED
# parity with almanac-thread.pl's own gated-verb list; BpHook's
# _normalize_ticket_name accepting the two new names and still rejecting
# others). AC14 (the PRE-EXISTING ContinuityOffCheck behaviour staying
# green) lives in the sibling fork-guard.t / continuity-command-verbs.t --
# not repeated here.
#
# HOUSE PATTERN for not-yet-built code: at the time this file is written,
# BpHook::_normalize_ticket_name's whitelist has no 'almanac-thread' or
# 'almanac-todo' entry, and ContinuityOffCheck::run writes no ticket for
# either name -- every assertion below is expected to fail for exactly that
# reason.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Glob qw(bsd_glob);
use JSON::PP ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

(my $BUTLER_DIR = dirname(__FILE__) . '/../..') =~ s{\\}{/}g;
(my $ALMANAC_DIR = "$BUTLER_DIR/../almanac") =~ s{\\}{/}g;
my $THREAD_PL = "$ALMANAC_DIR/scripts/almanac-thread.pl";
ok(-f $THREAD_PL, 'precondition: almanac-thread.pl exists') or BAIL_OUT('almanac-thread.pl missing');

sub _payload_bash {
    my (%o) = @_;
    my $p = { hook_event_name => 'PreToolUse', tool_name => 'Bash', tool_input => { command => $o{cmd} } };
    $p->{session_id}  = $o{session_id}  if exists $o{session_id};
    $p->{agent_id}    = $o{agent_id}    if exists $o{agent_id};
    $p->{tool_use_id} = $o{tool_use_id} if exists $o{tool_use_id};
    $p->{cwd}         = $o{cwd}         if exists $o{cwd};
    return $p;
}
sub tw      { my ($p, %env) = @_; return GuardHarness::run_module('ContinuityOffCheck', $p, env => \%env) }
sub tickets { my ($st) = @_; return sort(bsd_glob("$st/tickets/*/*.json")) }

# ---------------------------------------------------------------------------
# @THREAD_GATED parity with almanac-thread.pl's own gated-verb list (spec
# 2.7). almanac-thread.pl's source is read only for its OWN %VERBS keys
# (never its logic), as almanac-skills.t and similar siblings already do for
# other scripts' vocabularies.
# ---------------------------------------------------------------------------
{
    my @expect_gated = qw(create archive archive-if-done add edit move reorder status
                           add-packages event attach detach switch take-over);
    my $gated_ref = eval {
        local @INC = ("$ALMANAC_DIR/scripts", "$BUTLER_DIR/scripts", @INC);
        require "$BUTLER_DIR/scripts/BpHook/ContinuityOffCheck.pm" unless grep { m{(?:^|/)ContinuityOffCheck\.pm$} } keys %INC;
        no strict 'refs';
        \@BpHook::ContinuityOffCheck::THREAD_GATED;
    };
    ok(ref($gated_ref) eq 'ARRAY' && @$gated_ref,
        '@BpHook::ContinuityOffCheck::THREAD_GATED exists and is non-empty')
        or diag('not present yet -- package 03 has not added it');
    is_deeply([ sort @{ $gated_ref || [] } ], [ sort @expect_gated ],
        'AC13: @THREAD_GATED equals the spec 2.7 gated-verb list exactly') if ref($gated_ref) eq 'ARRAY';
}

# ---------------------------------------------------------------------------
# _normalize_ticket_name accepts the two new names, still rejects an unknown.
# ---------------------------------------------------------------------------
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $p = { session_id => 'NORM1', tool_use_id => 'T1', hook_event_name => 'PreToolUse',
              tool_name => 'Bash', tool_input => { command => 'noop' } };
    is(BpHook::write_ticket($p, 'almanac-thread', ['attach', 't']), 1,
        'AC13: write_ticket("almanac-thread", ...) -> 1 (name is normalized/accepted)');
    my $t1 = BpHook::take_ticket('almanac-thread', ['attach', 't']);
    is(ref($t1) eq 'HASH' ? $t1->{session_id} : undef, 'NORM1', 'AC13: ...and take_ticket reclaims it, session NORM1');

    is(BpHook::write_ticket($p, 'almanac-todo', ['promote', 'X', '--thread', 't']), 1,
        'AC13: write_ticket("almanac-todo", ...) -> 1 (name is normalized/accepted)');
    my $t2 = BpHook::take_ticket('almanac-todo', ['promote', 'X', '--thread', 't']);
    is(ref($t2) eq 'HASH' ? $t2->{session_id} : undef, 'NORM1', 'AC13: ...and take_ticket reclaims it too');

    is(BpHook::write_ticket($p, 'bp-unknown-name', ['x']), 0,
        'AC13: write_ticket of an unrelated unknown name still -> 0 (not broadened indiscriminately)');
}

# ---------------------------------------------------------------------------
# behaviour 13: direct almanac-thread.pl and the almanac.pl dispatcher form
# each write one ticket for the exact gated-verb argv; list/show write none;
# a subagent payload's ticket carries its agent_id.
# ---------------------------------------------------------------------------
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $ST = BpHook::state_dir();
    my $cmd = qq{perl "$THREAD_PL" attach t};
    my $res = tw(_payload_bash(cmd => $cmd, session_id => 'DIRECT1', tool_use_id => 'T1', cwd => '/proj'));
    is($res->{rc}, 0, 'AC13: direct almanac-thread.pl attach t -> ContinuityOffCheck rc 0');
    my @tf = tickets($ST);
    is(scalar(@tf), 1, 'AC13: exactly one ticket file (direct shape)');
    my $t = BpHook::take_ticket('almanac-thread', ['attach', 't']);
    is(ref($t) eq 'HASH' ? $t->{session_id} : 'unreachable', 'DIRECT1', 'AC13: ticket session_id is DIRECT1');
}
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $ST = BpHook::state_dir();
    my $cmd = q{perl "/x/plugins/almanac/scripts/almanac.pl" thread attach t};
    my $res = tw(_payload_bash(cmd => $cmd, session_id => 'DISP1', agent_id => 'AG1', tool_use_id => 'T1', cwd => '/proj'));
    is($res->{rc}, 0, 'AC13: dispatcher almanac.pl thread attach t -> rc 0');
    my @tf = tickets($ST);
    is(scalar(@tf), 1, 'AC13: exactly one ticket file (dispatcher shape)');
    my $t = BpHook::take_ticket('almanac-thread', ['attach', 't']);
    is(ref($t) eq 'HASH' ? $t->{session_id} : 'unreachable', 'DISP1', 'AC13: session_id DISP1 (dispatcher shape)');
    is(ref($t) eq 'HASH' ? $t->{agent_id}   : 'unreachable', 'AG1',   'AC13: agent_id AG1 carried through (dispatcher shape)');
}
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $ST = BpHook::state_dir();
    my $cmd = qq{perl "$ALMANAC_DIR/scripts/almanac-todo.pl" promote X --thread t};
    my $res = tw(_payload_bash(cmd => $cmd, session_id => 'TODO1', tool_use_id => 'T1', cwd => '/proj'));
    is($res->{rc}, 0, 'AC13: direct almanac-todo.pl promote X --thread t -> rc 0');
    my $t = BpHook::take_ticket('almanac-todo', ['promote', 'X', '--thread', 't']);
    is(ref($t) eq 'HASH' ? $t->{session_id} : 'unreachable', 'TODO1', 'AC13: almanac-todo ticket session_id TODO1');
}
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $ST = BpHook::state_dir();
    my $cmd = q{perl "/x/plugins/almanac/scripts/almanac.pl" todo promote X --thread t};
    my $res = tw(_payload_bash(cmd => $cmd, session_id => 'TODO2', tool_use_id => 'T1', cwd => '/proj'));
    is($res->{rc}, 0, 'AC13: dispatcher almanac.pl todo promote X --thread t -> rc 0');
    my $t = BpHook::take_ticket('almanac-todo', ['promote', 'X', '--thread', 't']);
    is(ref($t) eq 'HASH' ? $t->{session_id} : 'unreachable', 'TODO2', 'AC13: dispatcher-form almanac-todo ticket session_id TODO2');
}
{
    local %ENV = %ENV;
    GuardHarness::fresh_state();
    my $ST = BpHook::state_dir();
    for my $cmd (
        qq{perl "$THREAD_PL" list},
        qq{perl "$THREAD_PL" show t},
        qq{perl "$ALMANAC_DIR/scripts/almanac-todo.pl" create --title "x"},
    ) {
        tw(_payload_bash(cmd => $cmd, session_id => 'UNG1', tool_use_id => 'T1', cwd => '/proj'));
    }
    my @tf = tickets($ST);
    is(scalar(@tf), 0, 'AC13: list / show / todo create (ungated) write no ticket');
}

# ---- hygiene: this file never touched the real ~/.claude/butler-state -----
{
    ok(1, 'AC15 hygiene: GuardHarness enforces this via its own END-block check');
}

done_testing();
