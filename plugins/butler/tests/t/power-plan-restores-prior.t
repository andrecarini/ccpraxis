#!/usr/bin/env perl
# platform: any
#
# ORACLE for blueprint package 03-plan-restores-prior (wake-and-pause-consolidation), derived
# ONLY from
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/03-plan-restores-prior-spec.md
# (AC1-AC18). NOT derived from any implementation: at the time this file is written,
# BpPowerPlan::decide()/reconcile() still implement "nothing held means Balanced" (host-wake-and-
# suspend Decision 14) with no switch record and no migration marker, and
# switch_record_path/migration_marker_path/plan_lock_path/this_host/read_switch_record/
# write_switch_record/remove_switch_record/write_migration_marker do not exist at all. Every call
# to one of those not-yet-written subs goes through PP() below, which turns "Undefined
# subroutine" into a plain undef instead of dying -- the same idiom power-plan-follows-arming.t's
# PP() and plan-hold-expiry.t's PP()/CL() already use for their own not-yet-written subs. State
# file PATHS used by this file's fixtures are taken from the spec's literal file table (2.1), not
# from reading the implementation.
#
# Decision 4 (wake-and-pause-consolidation): reconcile undoes only its own switch, so "nothing
# held means Balanced" no longer holds. Decision 9: record-less Continuous work (left by pre-03
# code) is restored to Balanced once. Decision 15: that migration happens at most once per
# machine, tracked by a marker.
#
# THE REAL POWER PLAN IS NEVER TOUCHED: every path to powercfg goes through the in-process `run`
# seam (reconcile's `run` option). This file never sets CCPRAXIS_POWERCFG to anything but a fake,
# and never calls reconcile without an explicit `run`.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP ();
use Fcntl qw(:flock);
use Time::HiRes qw(sleep time);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";
require "$S/BpPowerPlan.pm";
require "$S/BpPowerJournal.pm";

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;

# ---------------------------------------------------------------------------
# PP(name, @args) -- call BpPowerPlan::<name> without ever crashing this file
# when the sub does not exist yet. Same idiom as power-plan-follows-arming.t.
# ---------------------------------------------------------------------------
sub PP {
    my ($name, @args) = @_;
    my $code;
    { no strict 'refs'; $code = \&{"BpPowerPlan::$name"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? (wantarray ? @ret : $ret[0]) : undef;
}
sub explain_undef { return 'PP() returned undef -- the named sub does not exist yet / is not yet correct' }

# ---------------------------------------------------------------------------
# generic fixtures, same shape as plan-hold-expiry.t's fresh_group.
# ---------------------------------------------------------------------------
sub fresh_group {
    my $t = tempdir(CLEANUP => 1);
    (my $home = "$t/home") =~ s{\\}{/}g;
    (my $legacy = "$t/legacy") =~ s{\\}{/}g;
    make_path($home, $legacy);
    $ENV{BUTLER_STATE_DIR} = $home;
    $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
    my $root = BpContinuityLease::store_root_for($legacy);
    return ($home, $legacy, $root);
}

sub arm_one {
    my ($sid) = @_;
    my $t = tempdir(CLEANUP => 1);
    (my $tp = "$t/transcript.jsonl") =~ s{\\}{/}g;
    open(my $fh, '>', $tp) or die "open $tp: $!";
    print {$fh} "{}\n";
    close $fh;
    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $tp), "setup: BpHook::arm($sid) succeeds");
    return;
}

sub slurp {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub jsonl_lines {
    my ($path) = @_;
    my $raw = slurp($path);
    return () unless defined $raw && length $raw;
    return split /\n/, $raw;
}
sub decode_or_undef {
    my ($line) = @_;
    my $d = eval { JSON::PP->new->utf8->decode($line) };
    return $@ ? undef : $d;
}
sub plan_records {
    my ($legacy) = @_;
    my @out;
    for my $line (jsonl_lines("$legacy/power-journal.jsonl")) {
        my $d = decode_or_undef($line);
        push @out, $d if ref $d eq 'HASH' && defined $d->{kind} && $d->{kind} eq 'plan';
    }
    return @out;
}

# state-file paths (spec 2.1's literal file table), via the new public subs
# when they exist, else the spec's own literal names.
sub record_path { my ($root) = @_; my $p = PP('switch_record_path', $root); return defined $p ? $p : "$root/power-plan-switch.json" }
sub marker_path { my ($root) = @_; my $p = PP('migration_marker_path', $root); return defined $p ? $p : "$root/power-plan-migrated.json" }
sub lock_path   { my ($root) = @_; my $p = PP('plan_lock_path', $root); return defined $p ? $p : "$root/power-plan.lock" }

# write_record_fixture($root, $guid, $name, %over) -- writes a valid switch
# record file DIRECTLY (bypassing write_switch_record, which does not exist
# yet), per the spec's own literal JSON shape (2.1).
sub write_record_fixture {
    my ($root, $guid, $name, %over) = @_;
    make_path($root);
    my $host = PP('this_host');
    my %rec = (guid => lc($guid), host => (defined $host ? $host : ''), name => $name, v => 1, written_at => time(), %over);
    open(my $fh, '>', record_path($root)) or die "open " . record_path($root) . ": $!";
    print {$fh} JSON::PP->new->canonical->encode(\%rec) . "\n";
    close $fh;
    return;
}
sub write_marker_fixture {
    my ($root, %over) = @_;
    make_path($root);
    my $host = PP('this_host');
    my %rec = (host => (defined $host ? $host : ''), v => 1, why => 'migration', written_at => time(), %over);
    open(my $fh, '>', marker_path($root)) or die "open " . marker_path($root) . ": $!";
    print {$fh} JSON::PP->new->canonical->encode(\%rec) . "\n";
    close $fh;
    return;
}

# ---------------------------------------------------------------------------
# powercfg fixture byte-shapes (same CRLF/parens shape every sibling test uses).
# ---------------------------------------------------------------------------
our $BAL_GUID = '381b4222-f694-41f0-9685-ff5bb260df2e';
our $CW_NAME  = 'Continuous work';
our $CW_GUID  = '54a34db5-af62-4d8a-ba50-af7155ee895a';
our $X_GUID   = 'aaaaaaaa-bbbb-cccc-dddd-000000000003';
our $X_NAME   = 'Third Plan';
our $Y_GUID   = 'aaaaaaaa-bbbb-cccc-dddd-000000000004';
our $Y_NAME   = 'Fourth Plan';

sub ga_bytes { my ($guid, $name) = @_; return "Power Scheme GUID: $guid  ($name)\r\n" }
sub list_bytes {
    my (@entries) = @_;
    my $body = '';
    for my $e (@entries) {
        $body .= "Power Scheme GUID: $e->{guid}  ($e->{name})" . ($e->{active} ? ' *' : '') . "\r\n";
    }
    return "\r\nExisting Power Schemes (* Active)\r\n-----------------------------------\r\n$body";
}
sub ok_result  { my ($out) = @_; return { status => 'ok', rc => 0, out => (defined $out ? $out : ''), ms => 1 } }
sub rc1_result { my ($out) = @_; return { status => 'ok', rc => 1, out => (defined $out ? $out : ''), ms => 1 } }

# ---------------------------------------------------------------------------
# make_run_seam(%o) -- a STATEFUL in-process fake for reconcile's `run` seam
# (same idiom as plan-hold-expiry.t's run_seam). $o{start} is the initial
# active guid; $o{names} maps guid => name for /getactivescheme answers;
# $o{list} is a coderef returning a result hash for /list. The returned
# $fail hashref can be mutated by the caller at any point (fail->{setactive}
# = rc1_result('') etc.) to inject a failing step; delete the key to go back
# to the normal behavior. Every call (including ones the test makes directly
# through $run->(...) to simulate a hand change) is recorded in @calls.
# ---------------------------------------------------------------------------
sub make_run_seam {
    my (%o) = @_;
    my $active = $o{start};
    my %names  = %{ $o{names} || {} };
    my $list_cb = $o{list};
    my $fail = {};
    my @calls;
    my $fn = sub {
        my @args = @_;
        push @calls, [@args];
        my $verb = defined $args[0] ? $args[0] : '';
        if ($verb eq '/getactivescheme') {
            return $fail->{getactivescheme} if exists $fail->{getactivescheme};
            my $name = $names{$active};
            $name = 'x' unless defined $name;
            return ok_result(ga_bytes($active, $name));
        }
        if ($verb eq '/list') {
            return $fail->{list} if exists $fail->{list};
            return $list_cb->() if ref $list_cb eq 'CODE';
            return ok_result('');
        }
        if ($verb eq '/setactive') {
            return $fail->{setactive} if exists $fail->{setactive};
            $active = $args[1];
            return ok_result('');
        }
        return ok_result('');
    };
    return ($fn, \@calls, sub { $active }, $fail);
}

ok(1, 'sanity: harness loaded');

# ===========================================================================
# AC1 (DC1) -- held from X, Balanced+CW+X listed: setactive sequence [cw];
# read_switch_record gives guid X; the marker exists. Released: sequence
# [cw, X]; no Balanced guid anywhere; the record is absent; the last plan
# record is action set, result ok, found CW, wanted X, basis record.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac1sess');

    my ($run, $calls) = make_run_seam(
        start => $X_GUID,
        names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME, $X_GUID => $X_NAME },
        list  => sub { ok_result(list_bytes(
            { guid => $X_GUID,   name => $X_NAME, active => 1 },
            { guid => $BAL_GUID, name => 'Balanced' },
            { guid => $CW_GUID,  name => $CW_NAME },
        )) },
    );
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');

    my @seq = map { $_->[1] } grep { $_->[0] eq '/setactive' } @$calls;
    is_deeply(\@seq, [$CW_GUID], 'AC1: held switch /setactive sequence is [cw]') or diag(explain_undef());

    my $rec = PP('read_switch_record', $root);
    is((ref $rec eq 'HASH' ? lc($rec->{guid}) : undef), $X_GUID, 'AC1: read_switch_record gives guid X')
        or diag(explain_undef());
    ok(-e marker_path($root), 'AC1: the migration marker exists after the first held switch') or diag(explain_undef());

    BpHook::disarm('ac1sess', actor => 'agent', reason => 'ac1 release');
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');

    @seq = map { $_->[1] } grep { $_->[0] eq '/setactive' } @$calls;
    is_deeply(\@seq, [$CW_GUID, $X_GUID], 'AC1: after release the sequence is [cw, X]') or diag(explain_undef());
    ok(!(grep { $_ eq $BAL_GUID } @seq), 'AC1: Balanced never appears in any /setactive call');
    ok(!-e record_path($root), 'AC1: the switch record is absent after the restore') or diag(explain_undef());

    my @recs = plan_records($legacy);
    my $last = $recs[-1];
    if (ref $last eq 'HASH') {
        is($last->{action}, 'set', 'AC1: last plan record action is set');
        is($last->{result}, 'ok', 'AC1: last plan record result is ok');
        is($last->{found_guid}, $CW_GUID, 'AC1: last plan record found is CW');
        is($last->{wanted_guid}, $X_GUID, 'AC1: last plan record wanted is X');
        is($last->{wanted_basis}, 'record', 'AC1: last plan record basis is record');
    } else {
        fail('AC1: no plan record was written for the restore');
        diag(explain_undef());
    }
}

# ===========================================================================
# AC2 (DC2) -- unheld on X, no record, run twice (no marker, then marker
# present): zero /setactive, zero /list, outcome correct, basis left, zero
# plan records, either way.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    for my $variant (qw(no-marker with-marker)) {
        write_marker_fixture($root) if $variant eq 'with-marker';
        my ($run, $calls) = make_run_seam(start => $X_GUID, names => { $BAL_GUID => 'Balanced', $X_GUID => $X_NAME });
        my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
        is(scalar(grep { $_->[0] eq '/setactive' } @$calls), 0, "AC2 ($variant): zero /setactive calls");
        is(scalar(grep { $_->[0] eq '/list' } @$calls), 0, "AC2 ($variant): zero /list calls");
        is((ref $o eq 'HASH' ? $o->{outcome} : undef), 'correct', "AC2 ($variant): outcome is correct") or diag(explain_undef());
        is((ref $o eq 'HASH' ? $o->{wanted_basis} : undef), 'left', "AC2 ($variant): basis is left") or diag(explain_undef());
        is(scalar(plan_records($legacy)), 0, "AC2 ($variant): zero plan records");
    }
}

# ===========================================================================
# AC3 (DC3) -- unheld on CW, no record, no marker: one /setactive to
# Balanced, zero /list, the marker is written, basis migration. Then the
# operator hand-sets CW again with the marker present: 3 more reconciles
# make zero further /setactive, each outcome correct.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my ($run, $calls) = make_run_seam(start => $CW_GUID, names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME });

    my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    my @sc = grep { $_->[0] eq '/setactive' } @$calls;
    is(scalar(@sc), 1, 'AC3: exactly one /setactive call') or diag(explain_undef());
    is(($sc[0][1] // ''), $BAL_GUID, 'AC3: ...to Balanced') if @sc;
    is(scalar(grep { $_->[0] eq '/list' } @$calls), 0, 'AC3: zero /list calls');
    ok(-e marker_path($root), 'AC3: the migration marker exists') or diag(explain_undef());
    my @recs = plan_records($legacy);
    is((ref $recs[0] eq 'HASH' ? $recs[0]{wanted_basis} : undef), 'migration', 'AC3: plan record basis is migration')
        or diag(explain_undef());

    $run->('/setactive', $CW_GUID); # the operator's own hand change, not through reconcile
    my $before = scalar(@$calls);
    for my $i (1 .. 3) {
        my $o2 = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
        is((ref $o2 eq 'HASH' ? $o2->{outcome} : undef), 'correct', "AC3: hand-chosen CW reconcile #$i is correct")
            or diag(explain_undef());
    }
    my @sc_after = grep { $_->[0] eq '/setactive' } @{$calls}[$before .. $#$calls];
    is(scalar(@sc_after), 0, 'AC3: no further /setactive once CW is hand-chosen with the marker present')
        or diag(explain_undef());
}

# ===========================================================================
# AC3b (DC3) -- same as AC3 but /setactive fails: error/setactive-failed,
# the marker is NOT written. The next healthy reconcile performs the
# migration and writes the marker.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my ($run, $calls, undef, $fail) = make_run_seam(start => $CW_GUID, names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME });
    $fail->{setactive} = rc1_result('');

    my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is((ref $o eq 'HASH' ? $o->{outcome} : undef), 'error', 'AC3b: outcome is error') or diag(explain_undef());
    is((ref $o eq 'HASH' ? $o->{reason} : undef), 'setactive-failed', 'AC3b: reason is setactive-failed') or diag(explain_undef());
    ok(!-e marker_path($root), 'AC3b: the marker does not exist after a failed migration');

    delete $fail->{setactive};
    my $o2 = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is((ref $o2 eq 'HASH' ? $o2->{outcome} : undef), 'corrected', 'AC3b: the next healthy reconcile performs the migration')
        or diag(explain_undef());
    ok(-e marker_path($root), 'AC3b: ...and writes the marker') or diag(explain_undef());
}

# ===========================================================================
# AC4 (DC4) -- held from X (writes record X), released with /list = Balanced
# + CW only (X not listed): one /setactive <balanced>; record absent; plan
# record basis record-missing, result ok.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac4sess');
    my ($run1, $calls1) = make_run_seam(
        start => $X_GUID,
        names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME, $X_GUID => $X_NAME },
        list  => sub { ok_result(list_bytes(
            { guid => $X_GUID, name => $X_NAME, active => 1 }, { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME },
        )) },
    );
    BpPowerPlan::reconcile($legacy, run => $run1, why => 'manual'); # held switch: writes record X

    BpHook::disarm('ac4sess', actor => 'agent', reason => 'ac4 release');
    my ($run2, $calls2) = make_run_seam(
        start => $CW_GUID,
        names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME, $X_GUID => $X_NAME },
        list  => sub { ok_result(list_bytes({ guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME, active => 1 })) },
    );
    my $o = BpPowerPlan::reconcile($legacy, run => $run2, why => 'manual');
    my @sc = grep { $_->[0] eq '/setactive' } @$calls2;
    is(scalar(@sc), 1, 'AC4: exactly one /setactive call on release') or diag(explain_undef());
    is(($sc[0][1] // ''), $BAL_GUID, 'AC4: ...to Balanced') if @sc;
    ok(!-e record_path($root), 'AC4: the record is absent after the restore') or diag(explain_undef());
    my @recs = plan_records($legacy);
    if (@recs) {
        is($recs[-1]{wanted_basis}, 'record-missing', 'AC4: plan record basis is record-missing');
        is($recs[-1]{result}, 'ok', 'AC4: plan record result is ok');
    } else {
        fail('AC4: no plan record written'); diag(explain_undef());
    }
}

# ===========================================================================
# AC5 (DC5) -- held from X (record X). The operator hand-switches to Y
# (listed) and reconcile is called held twice: each call makes exactly one
# /setactive <cw>, and the record's raw bytes are unchanged across both.
# Released afterward, the restore goes to X.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac5sess');
    my $names = { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME, $X_GUID => $X_NAME, $Y_GUID => $Y_NAME };
    my $list_cb = sub { ok_result(list_bytes(
        { guid => $X_GUID, name => $X_NAME }, { guid => $Y_GUID, name => $Y_NAME },
        { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME },
    )) };
    my ($run, $calls) = make_run_seam(start => $X_GUID, names => $names, list => $list_cb);
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual'); # first held switch writes record X
    my $bytes_after_first = slurp(record_path($root));
    ok(defined $bytes_after_first && length $bytes_after_first, 'AC5 setup: the record exists after the first held switch')
        or diag(explain_undef());

    for my $i (1, 2) {
        $run->('/setactive', $Y_GUID); # the operator's own hand change, between reconciles
        my $before = scalar(@$calls);
        BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
        my @sc = grep { $_->[0] eq '/setactive' } @{$calls}[$before .. $#$calls];
        is(scalar(@sc), 1, "AC5: held reconcile #$i makes exactly one /setactive call") or diag(explain_undef());
        is(($sc[0][1] // ''), $CW_GUID, "AC5: ...to cw") if @sc;
    }
    my $bytes_after_both = slurp(record_path($root));
    is($bytes_after_both, $bytes_after_first, 'AC5: the record\'s raw bytes are unchanged across both held reconciles')
        or diag(explain_undef());

    BpHook::disarm('ac5sess', actor => 'agent', reason => 'ac5 release');
    my $before_release = scalar(@$calls);
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    my @sc_release = grep { $_->[0] eq '/setactive' } @{$calls}[$before_release .. $#$calls];
    is(scalar(@sc_release) ? $sc_release[0][1] : undef, $X_GUID, 'AC5: on release the restore goes to X')
        or diag(explain_undef());
}

# ===========================================================================
# AC6 (DC6) -- the edits to power-plan-follows-arming.t, plan-restored-on-
# last-off.t and power-plan-sandbox-hold.t are verified by RUNNING those
# files (unmodified test logic, modified assertions), never by assertions
# added here. See the step-3 report for how that was checked.
# ===========================================================================
note('AC6: verified externally by running the edited test_paths files (see report)');

# ===========================================================================
# AC7 (DC1-DC5) -- decide() table: one call per row H3, H4, H5, U1-U8 (U8
# split by guid vs by name), asserting action, wanted_guid, wanted_basis,
# record_op and marker_op exactly as spec 2.3 states.
# ===========================================================================
{
    my $list_balcw  = [ { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME } ];
    my $list_with_x = [ { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME }, { guid => $X_GUID, name => $X_NAME } ];
    my $d;

    # H3 -- active already in S (by name): action none.
    $d = PP('decide', armed => 1, active => $CW_GUID, active_name => $CW_NAME, list => $list_balcw,
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID);
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'none', 'AC7 H3: action is none') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $CW_GUID, 'AC7 H3: wanted_guid is cw (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'name', 'AC7 H3: wanted_basis is name (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'none', 'AC7 H3: record_op is none') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'none', 'AC7 H3: marker_op is none') or diag(explain_undef());

    # H4 -- active not in S, no record: set to cw, write record + marker.
    $d = PP('decide', armed => 1, active => $X_GUID, active_name => $X_NAME, list => $list_balcw,
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID, record => undef);
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'set', 'AC7 H4: action is set') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $CW_GUID, 'AC7 H4: wanted_guid is cw') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'name', 'AC7 H4: wanted_basis is name (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'write', 'AC7 H4: record_op is write') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'write', 'AC7 H4: marker_op is write') or diag(explain_undef());

    # H5 -- active not in S, record defined: set to cw, record kept as-is, marker write.
    $d = PP('decide', armed => 1, active => $X_GUID, active_name => $X_NAME, list => $list_balcw,
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID,
            record => { guid => $X_GUID, name => $X_NAME });
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'set', 'AC7 H5: action is set') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $CW_GUID, 'AC7 H5: wanted_guid is cw (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'name', 'AC7 H5: wanted_basis is name (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'none', 'AC7 H5: record_op is none (kept)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'write', 'AC7 H5: marker_op is write') or diag(explain_undef());

    # U1 -- unheld, record X, active == record.guid: none, remove, basis record.
    $d = PP('decide', armed => 0, active => $X_GUID, active_name => $X_NAME,
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID,
            record => { guid => $X_GUID, name => $X_NAME });
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'none', 'AC7 U1: action is none') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $X_GUID, 'AC7 U1: wanted_guid is X (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'record', 'AC7 U1: basis is record') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'remove', 'AC7 U1: record_op is remove') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'none', 'AC7 U1: marker_op is none') or diag(explain_undef());

    # U2 -- unheld, record X, active != record.guid, !is_cw: none, remove, basis record-superseded.
    $d = PP('decide', armed => 0, active => $BAL_GUID, active_name => 'Balanced',
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID,
            record => { guid => $X_GUID, name => $X_NAME });
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'none', 'AC7 U2: action is none') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $BAL_GUID, 'AC7 U2: wanted_guid is active (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'record-superseded', 'AC7 U2: basis is record-superseded')
        or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'remove', 'AC7 U2: record_op is remove') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'none', 'AC7 U2: marker_op is none (m4)') or diag(explain_undef());

    # U3 -- unheld, record X, active != record.guid, is_cw, list undef: error list-failed.
    $d = PP('decide', armed => 0, active => $CW_GUID, active_name => $CW_NAME,
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID,
            record => { guid => $X_GUID, name => $X_NAME }, list => undef);
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'error', 'AC7 U3: action is error') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), 'none', 'AC7 U3: wanted_guid is none (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'none', 'AC7 U3: wanted_basis is none (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{error} : undef), 'list-failed', 'AC7 U3: error is list-failed') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'none', 'AC7 U3: record_op is none') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'none', 'AC7 U3: marker_op is none') or diag(explain_undef());

    # U4 -- unheld, record X, active != record.guid, is_cw, record.guid present in list: set X, remove, basis record.
    $d = PP('decide', armed => 0, active => $CW_GUID, active_name => $CW_NAME,
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID,
            record => { guid => $X_GUID, name => $X_NAME }, list => $list_with_x);
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'set', 'AC7 U4: action is set') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $X_GUID, 'AC7 U4: wanted_guid is X') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'record', 'AC7 U4: basis is record') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'remove', 'AC7 U4: record_op is remove') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'none', 'AC7 U4: marker_op is none (m4)') or diag(explain_undef());

    # U5 -- unheld, record X, active != record.guid, is_cw, record.guid absent from non-empty list: set balanced, basis record-missing.
    $d = PP('decide', armed => 0, active => $CW_GUID, active_name => $CW_NAME,
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID,
            record => { guid => $X_GUID, name => $X_NAME }, list => $list_balcw);
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'set', 'AC7 U5: action is set') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $BAL_GUID, 'AC7 U5: wanted_guid is balanced') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'record-missing', 'AC7 U5: basis is record-missing')
        or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'remove', 'AC7 U5: record_op is remove') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'none', 'AC7 U5: marker_op is none (m4)') or diag(explain_undef());

    # U6 -- unheld, no record, !is_cw: none, basis left.
    $d = PP('decide', armed => 0, active => $BAL_GUID, active_name => 'Balanced',
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID, record => undef);
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'none', 'AC7 U6: action is none') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $BAL_GUID, 'AC7 U6: wanted_guid is active (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'left', 'AC7 U6: basis is left') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'none', 'AC7 U6: record_op is none (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'none', 'AC7 U6: marker_op is none (m4)') or diag(explain_undef());

    # U7 -- unheld, no record, is_cw, migrated true: none, basis left. (m4: must
    # not write the marker or touch the record -- record_op/marker_op none.)
    $d = PP('decide', armed => 0, active => $CW_GUID, active_name => $CW_NAME,
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID, record => undef, migrated => 1);
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'none', 'AC7 U7: action is none') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $CW_GUID, 'AC7 U7: wanted_guid is active (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'left', 'AC7 U7: basis is left') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'none', 'AC7 U7: record_op is none -- must not touch the record (m4)')
        or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'none', 'AC7 U7: marker_op is none -- must not write the marker (m4)')
        or diag(explain_undef());

    # U8a -- unheld, no record, is_cw via stored guid (active_name unrelated), migrated false.
    $d = PP('decide', armed => 0, active => $CW_GUID, active_name => 'x',
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID, record => undef, migrated => 0);
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'set', 'AC7 U8a: action is set (chosen by stored guid)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $BAL_GUID, 'AC7 U8a: wanted_guid is balanced') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'migration', 'AC7 U8a: basis is migration') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'none', 'AC7 U8a: record_op is none (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'write', 'AC7 U8a: marker_op is write') or diag(explain_undef());

    # U8b -- unheld, no record, is_cw via name (unrelated guid), migrated false.
    my $other_guid = 'bbbbbbbb-2222-3333-4444-555555555555';
    $d = PP('decide', armed => 0, active => $other_guid, active_name => $CW_NAME,
            cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID, record => undef, migrated => 0);
    is((ref $d eq 'HASH' ? $d->{action} : undef), 'set', 'AC7 U8b: action is set (chosen by name)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_guid} : undef), $BAL_GUID, 'AC7 U8b: wanted_guid is balanced (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{wanted_basis} : undef), 'migration', 'AC7 U8b: basis is migration') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{record_op} : undef), 'none', 'AC7 U8b: record_op is none (m4)') or diag(explain_undef());
    is((ref $d eq 'HASH' ? $d->{marker_op} : undef), 'write', 'AC7 U8b: marker_op is write') or diag(explain_undef());
}

# ===========================================================================
# Triage item 3 (step 6 reviewer m1) -- an active plan that IS Continuous
# work itself (by the stored GUID, or by a name that matches the Continuous-
# work name even on a renamed/duplicate plan) is never recorded as "the plan
# to restore", even when the S-set /list's name matches produced does not
# happen to contain it.
# ===========================================================================
{
    # 3a: active IS the stored CW guid, but has been renamed so it is not in
    # S by name; a different plan in /list happens to carry the CW name.
    my $dup_guid = 'cccccccc-1111-2222-3333-444444444444';
    my $list_3a = [ { guid => $dup_guid, name => $CW_NAME }, { guid => $CW_GUID, name => 'Renamed CW' } ];
    my $d3a = PP('decide', armed => 1, active => $CW_GUID, active_name => 'Renamed CW', list => $list_3a,
                 cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID, record => undef);
    is((ref $d3a eq 'HASH' ? $d3a->{record_op} : undef), 'none',
        'triage-3a: active is the stored CW guid (renamed) -- never recorded as the prior plan')
        or diag(explain_undef());

    # 3b: active is a duplicate/renamed plan whose OWN name is the CW name,
    # even though its entry is absent from /list (so the name-matched S-set
    # does not happen to include it).
    my $other_guid = 'dddddddd-5555-6666-7777-888888888888';
    my $list_3b = [ { guid => $dup_guid, name => $CW_NAME } ];
    my $d3b = PP('decide', armed => 1, active => $other_guid, active_name => $CW_NAME, list => $list_3b,
                 cw_name => $CW_NAME, cw_guid => $CW_GUID, balanced_guid => $BAL_GUID, record => undef);
    is((ref $d3b eq 'HASH' ? $d3b->{record_op} : undef), 'none',
        'triage-3b: active carries the CW name itself (duplicate/renamed) -- never recorded as the prior plan')
        or diag(explain_undef());
}

# ===========================================================================
# AC8 (DC1) -- U1: unheld, record X, active X: zero /setactive, record
# removed, exactly one plan record (action none, basis record), without
# journal_noop.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    write_record_fixture($root, $X_GUID, $X_NAME);
    my ($run, $calls) = make_run_seam(start => $X_GUID, names => { $BAL_GUID => 'Balanced', $X_GUID => $X_NAME });
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is(scalar(grep { $_->[0] eq '/setactive' } @$calls), 0, 'AC8: zero /setactive calls (U1)');
    ok(!-e record_path($root), 'AC8: the record is removed (U1)') or diag(explain_undef());
    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC8: exactly one plan record without journal_noop') or diag(explain_undef());
    if (@recs) {
        is($recs[0]{action}, 'none', 'AC8: action is none');
        is($recs[0]{wanted_basis}, 'record', 'AC8: basis is record');
    }
}

# ===========================================================================
# AC9 (DC1, DC2) -- U2: unheld, record X, active Balanced: zero /setactive,
# zero /list, record removed, one plan record with basis record-superseded.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    write_record_fixture($root, $X_GUID, $X_NAME);
    my ($run, $calls) = make_run_seam(start => $BAL_GUID, names => { $BAL_GUID => 'Balanced', $X_GUID => $X_NAME });
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is(scalar(grep { $_->[0] eq '/setactive' } @$calls), 0, 'AC9: zero /setactive (U2)');
    is(scalar(grep { $_->[0] eq '/list' } @$calls), 0, 'AC9: zero /list (U2)');
    ok(!-e record_path($root), 'AC9: the record is removed (U2)') or diag(explain_undef());
    my @recs = plan_records($legacy);
    is((ref $recs[0] eq 'HASH' ? $recs[0]{wanted_basis} : undef), 'record-superseded', 'AC9: basis is record-superseded')
        or diag(explain_undef());
}

# ===========================================================================
# AC10 (DC4) -- U3: unheld, record X, active CW, /list rc=1: error/list-
# failed/detail rc=1, record unchanged. Then /list ok but unparseable:
# detail unparseable, record still unchanged.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    write_record_fixture($root, $X_GUID, $X_NAME);
    my ($run, $calls, undef, $fail) = make_run_seam(start => $CW_GUID, names => { $CW_GUID => $CW_NAME, $X_GUID => $X_NAME });
    $fail->{list} = rc1_result('');
    my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is((ref $o eq 'HASH' ? $o->{outcome} : undef), 'error', 'AC10: outcome error (U3, rc=1)') or diag(explain_undef());
    is((ref $o eq 'HASH' ? $o->{reason} : undef), 'list-failed', 'AC10: reason list-failed') or diag(explain_undef());
    is((ref $o eq 'HASH' ? $o->{detail} : undef), 'rc=1', 'AC10: detail rc=1') or diag(explain_undef());
    my $bytes_before = slurp(record_path($root));

    $fail->{list} = ok_result("no guid here at all\r\n");
    my $o2 = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is((ref $o2 eq 'HASH' ? $o2->{detail} : undef), 'unparseable', 'AC10: detail unparseable') or diag(explain_undef());
    is(slurp(record_path($root)), $bytes_before, 'AC10: the record is unchanged across both failures')
        or diag(explain_undef());
}

# ===========================================================================
# AC11 (DC1) -- a restore whose /setactive fails: setactive-failed, the
# record still names X. The next healthy reconcile restores X and removes
# the record.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    write_record_fixture($root, $X_GUID, $X_NAME);
    my ($run, $calls, undef, $fail) = make_run_seam(
        start => $CW_GUID, names => { $BAL_GUID => 'Balanced', $X_GUID => $X_NAME, $CW_GUID => $CW_NAME },
        list  => sub { ok_result(list_bytes({ guid => $X_GUID, name => $X_NAME }, { guid => $CW_GUID, name => $CW_NAME })) },
    );
    $fail->{setactive} = rc1_result('');
    my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is((ref $o eq 'HASH' ? $o->{outcome} : undef), 'error', 'AC11: outcome error (failed restore)') or diag(explain_undef());
    is((ref $o eq 'HASH' ? $o->{reason} : undef), 'setactive-failed', 'AC11: reason setactive-failed') or diag(explain_undef());
    my $rec = PP('read_switch_record', $root);
    is((ref $rec eq 'HASH' ? lc($rec->{guid}) : undef), $X_GUID, 'AC11: the record still names X') or diag(explain_undef());

    delete $fail->{setactive};
    my $o2 = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is((ref $o2 eq 'HASH' ? $o2->{outcome} : undef), 'corrected', 'AC11: the next healthy reconcile restores X')
        or diag(explain_undef());
    ok(!-e record_path($root), 'AC11: ...and removes the record') or diag(explain_undef());
}

# ===========================================================================
# AC12 (DC3) -- a garbled record is treated as absent: unheld on CW, no
# marker, behaves as U8 (Balanced + marker written), the garbled file still
# exists. Held from X with a garbled record: read_switch_record gives X
# after H4 overwrites it.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    make_path($root);
    open(my $fh, '>', record_path($root)) or die "open: $!";
    print {$fh} "not json";
    close $fh;
    my ($run, $calls) = make_run_seam(start => $CW_GUID, names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME });
    my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is((ref $o eq 'HASH' ? $o->{wanted_basis} : undef), 'migration', 'AC12: a garbled record is treated as absent (U8, migration)')
        or diag(explain_undef());
    ok(-e marker_path($root), 'AC12: the marker is written') or diag(explain_undef());
    is(slurp(record_path($root)), 'not json', 'AC12: the garbled file still exists, byte-for-byte');
}
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac12held');
    make_path($root);
    open(my $fh, '>', record_path($root)) or die "open: $!";
    print {$fh} "not json";
    close $fh;
    my ($run, $calls) = make_run_seam(
        start => $X_GUID, names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME, $X_GUID => $X_NAME },
        list  => sub { ok_result(list_bytes(
            { guid => $X_GUID, name => $X_NAME }, { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME },
        )) },
    );
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    my $rec = PP('read_switch_record', $root);
    is((ref $rec eq 'HASH' ? lc($rec->{guid}) : undef), $X_GUID, 'AC12: held from X overwrites the garbled record (H4)')
        or diag(explain_undef());
}

# ===========================================================================
# AC13 (DC2, DC3) -- a foreign-host record is treated as absent: unheld on
# CW, marker present: zero /setactive (U7). Skipped if this_host() is empty
# or not yet implemented.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $this_host = PP('this_host');
    SKIP: {
        skip "AC13: this_host() is '' or not implemented yet", 1 unless defined $this_host && length $this_host;
        write_record_fixture($root, $X_GUID, $X_NAME, host => 'not-this-host-zz');
        write_marker_fixture($root, host => $this_host);
        my $bytes_before = slurp(record_path($root));
        my ($run, $calls) = make_run_seam(start => $CW_GUID, names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME });
        BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
        is(scalar(grep { $_->[0] eq '/setactive' } @$calls), 0, 'AC13: a foreign record is treated as absent (U7, marker present)')
            or diag(explain_undef());
        # m5: the foreign record itself must SURVIVE an unheld reconcile -- no
        # reader deletes it; only an H4 write (behaviour 13) ever replaces it.
        ok(-e record_path($root), 'AC13: the foreign-host record file still exists after the reconcile (m5)')
            or diag(explain_undef());
        is(slurp(record_path($root)), $bytes_before,
            'AC13: ...and its bytes are byte-for-byte unchanged (m5)') or diag(explain_undef());
    }
}

# ===========================================================================
# AC14 (robustness, all DCs) -- the plan lock: an in-process flock held by
# the test itself makes a concurrent reconcile(lock_timeout=>1) return
# skipped/plan-locked, with zero seam calls, no journal file, elapsed < 5s.
# After close(), the same call is no longer skipped.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    make_path($root);
    my $lp = lock_path($root);
    open(my $lockfh, '>>', $lp) or die "open $lp: $!";
    ok(flock($lockfh, LOCK_EX), 'AC14 setup: the test itself holds the plan lock');

    my ($run, $calls) = make_run_seam(start => $BAL_GUID, names => { $BAL_GUID => 'Balanced' });
    my $t0 = time();
    my $o = BpPowerPlan::reconcile($legacy, run => $run, lock_timeout => 1, why => 'manual');
    my $elapsed = time() - $t0;
    is((ref $o eq 'HASH' ? $o->{outcome} : undef), 'skipped', 'AC14: reconcile returns skipped while the lock is held')
        or diag(explain_undef());
    is((ref $o eq 'HASH' ? $o->{reason} : undef), 'plan-locked', 'AC14: reason is plan-locked') or diag(explain_undef());
    is(scalar(@$calls), 0, 'AC14: zero seam calls while locked') or diag(explain_undef());
    # Triage item 5 (step 6 reviewer m3, accepted as a fix in BpPowerPlan's
    # OWN journal rather than BpContinuityLease.pm's PLAN log, which is
    # outside this package's write set): a skipped/plan-locked outcome that
    # is genuinely contended by another holder is now journaled, so it can
    # be told apart from "nothing to do". This supersedes spec 2.4 step 1's
    # "writes no journal" for this one case.
    my @locked_recs = plan_records($legacy);
    is(scalar(@locked_recs), 1, 'AC14: exactly one plan record is journaled for the genuinely-contended skip (triage item 5)')
        or diag(explain_undef());
    is((ref $locked_recs[0] eq 'HASH' ? $locked_recs[0]{error} : undef), 'plan-locked',
        'AC14: ...identified by error plan-locked (triage item 5)') or diag(explain_undef());
    ok($elapsed < 5, "AC14: elapsed (${elapsed}s) is under 5s");

    close($lockfh);
    my $o2 = BpPowerPlan::reconcile($legacy, run => $run, lock_timeout => 1, why => 'manual');
    isnt((ref $o2 eq 'HASH' ? $o2->{outcome} : undef), 'skipped', 'AC14: after close, the same call is not skipped')
        or diag(explain_undef());
}

# ===========================================================================
# AC15 (robustness) -- a die from the `run` seam propagates (unchanged), and
# a following reconcile is not blocked by the lock.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $dying_run = sub { die "fixture: run seam dies\n" };
    eval { BpPowerPlan::reconcile($legacy, run => $dying_run, why => 'manual') };
    like($@, qr/fixture: run seam dies/, 'AC15: a dying run seam propagates out of reconcile');

    my ($run2, $calls2) = make_run_seam(start => $BAL_GUID, names => { $BAL_GUID => 'Balanced' });
    my $o = BpPowerPlan::reconcile($legacy, run => $run2, lock_timeout => 1, why => 'manual');
    isnt((ref $o eq 'HASH' ? $o->{outcome} : undef), 'skipped', 'AC15: a following reconcile is not blocked by the lock after a die')
        or diag(explain_undef());
}

# ===========================================================================
# AC16 (DC4) -- BpPowerJournal::_summary_for's plan branch appends
# ` basis=<wanted_basis>` right after `wanted=<guid>`.
# ===========================================================================
{
    my $summary = eval { BpPowerJournal::_summary_for({
        kind => 'plan', why => 'w', action => 'set', result => 'ok',
        found_guid => 'f', wanted_guid => 'g', wanted_basis => 'record-missing',
    }) };
    like(($summary // ''), qr/wanted=g basis=record-missing/,
        'AC16: _summary_for appends basis=<wanted_basis> right after wanted=<guid>') or diag($@ || explain_undef());
}

# ===========================================================================
# AC17 (DC1) -- switch record format: one line ending in \n, decoding to
# exactly {guid,host,name,v,written_at}, v==1, guid lowercase, written_at
# within 5s of now. No *.tmp.* file remains in the root.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac17sess');
    my ($run, $calls) = make_run_seam(
        start => $BAL_GUID, names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME },
        list  => sub { ok_result(list_bytes({ guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME })) },
    );
    my $before = time();
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    my $raw = slurp(record_path($root));
    if (defined $raw) {
        like($raw, qr/\n\z/, 'AC17: the record file ends in \n');
        (my $line = $raw) =~ s/\n\z//;
        unlike($line, qr/\n/, 'AC17: exactly one line');
        my $d = eval { JSON::PP->new->utf8->decode($line) };
        ok((ref $d eq 'HASH'), 'AC17: the line decodes as a JSON object') or diag($@);
        if (ref $d eq 'HASH') {
            is_deeply([ sort keys %$d ], [ sort qw(guid host name v written_at) ],
                'AC17: keys are exactly guid,host,name,v,written_at');
            is($d->{v}, 1, 'AC17: v is 1');
            is($d->{guid}, lc($d->{guid}), 'AC17: guid is lowercase');
            ok(defined $d->{written_at} && $d->{written_at} =~ /\A\d+\z/ && abs($d->{written_at} - $before) <= 5,
                'AC17: written_at is an integer within 5s of now');
        }
    } else {
        fail('AC17: no record file was written');
        diag(explain_undef());
    }
    if (opendir(my $dh, $root)) {
        my @tmp = grep { /\.tmp\./ } readdir($dh);
        closedir $dh;
        is_deeply(\@tmp, [], 'AC17: no *.tmp.* file remains in the root');
    } else {
        pass('AC17: the root does not even exist yet, so no tmp file can remain either');
    }
}

# ===========================================================================
# AC18 (DC1) -- sandbox-hold variant of DC1: set_sandbox_hold (fresh) from X,
# reconcile, then age the hold past SANDBOX_HOLD_FRESH_SECONDS and reconcile
# again: the restore goes to X.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $hold_name = 'claude-ac18-aaaaaaaa';
    BpPowerPlan::set_sandbox_hold($root, $hold_name, 1);
    my ($run, $calls) = make_run_seam(
        start => $X_GUID, names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME, $X_GUID => $X_NAME },
        list  => sub { ok_result(list_bytes(
            { guid => $X_GUID, name => $X_NAME }, { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME },
        )) },
    );
    BpPowerPlan::reconcile($legacy, run => $run, why => 'sandbox-hold');
    my $f = BpPowerPlan::sandbox_hold_dir($root) . "/$hold_name";
    my $old = time() - $BpPowerPlan::SANDBOX_HOLD_FRESH_SECONDS - 5;
    utime($old, $old, $f);
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    my @sc = grep { $_->[0] eq '/setactive' } @$calls;
    is((@sc ? $sc[-1][1] : undef), $X_GUID, 'AC18: once the sandbox hold goes stale, the restore goes to X')
        or diag(explain_undef());
}

# ===========================================================================
# Triage item 1 (step 6 reviewer M1 / redteam F3) -- the plan lock is
# re-entrant WITHIN ONE PROCESS: a nested reconcile() call made from inside
# the run seam of an outer, in-flight reconcile (exactly what a signal-exit
# restore does when it fires mid-tick) completes instead of waiting out the
# lock timeout and returning skipped/plan-locked.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $depth = 0;
    my ($nested_outcome, $nested_elapsed);
    my ($inner, $inner_calls) = make_run_seam(start => $BAL_GUID, names => { $BAL_GUID => 'Balanced' });
    my $wrapped;
    $wrapped = sub {
        my @args = @_;
        if (!$depth && defined $args[0] && $args[0] eq '/getactivescheme') {
            $depth = 1;
            my $t0 = time();
            $nested_outcome = BpPowerPlan::reconcile($legacy, run => $wrapped, lock_timeout => 1, why => 'manual');
            $nested_elapsed = time() - $t0;
        }
        return $inner->(@args);
    };
    my $o = BpPowerPlan::reconcile($legacy, run => $wrapped, why => 'manual');
    isnt((ref $nested_outcome eq 'HASH' ? $nested_outcome->{outcome} : undef), 'skipped',
        'triage-1: a same-process nested reconcile is not skipped/plan-locked') or diag(explain_undef());
    my $els = defined $nested_elapsed ? $nested_elapsed : -1;
    ok($els >= 0 && $els < 0.5,
        "triage-1: ...and completes near-instantly (${els}s), not after waiting out the lock timeout")
        or diag(explain_undef());
    is((ref $o eq 'HASH' ? $o->{outcome} : undef), 'correct', 'triage-1: the outer reconcile itself still completes normally')
        or diag(explain_undef());
}

# ===========================================================================
# Triage item 2 (step 6 redteam F1, overriding spec section 5's acceptance
# that this is "rare" and tolerable for the whole root -- the triage narrows
# it to the one file) -- when the switch record cannot be written (its path
# is occupied by a directory), the migration marker must NOT be written
# either, so a later unheld reconcile on Continuous work with no readable
# record still performs the Decision 9 migration restore to Balanced.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    make_path($root);
    mkdir(record_path($root)) or die "mkdir " . record_path($root) . ": $!";
    arm_one('triage2sess');
    my ($run, $calls) = make_run_seam(
        start => $X_GUID, names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME, $X_GUID => $X_NAME },
        list  => sub { ok_result(list_bytes(
            { guid => $X_GUID, name => $X_NAME, active => 1 }, { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME },
        )) },
    );
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual'); # held: switches to CW; record write fails (directory)
    ok(!-e marker_path($root),
        'triage-2: the migration marker is NOT written when the switch record write failed') or diag(explain_undef());

    BpHook::disarm('triage2sess', actor => 'agent', reason => 'triage-2 release');
    my $before = scalar(@$calls);
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual'); # unheld: CW active, no readable record, no marker
    my @sc = grep { $_->[0] eq '/setactive' } @{$calls}[$before .. $#$calls];
    is(scalar(@sc) ? $sc[-1][1] : undef, $BAL_GUID,
        'triage-2: ...so the next unheld reconcile still performs the Decision 9 migration to Balanced')
        or diag(explain_undef());
}

# ===========================================================================
# Triage item 4 (step 6 reviewer m2) -- the journal keeps record-write-
# failed even when /setactive ALSO fails, not only on the success path.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    make_path($root);
    mkdir(record_path($root)) or die "mkdir " . record_path($root) . ": $!";
    arm_one('triage4sess');
    my ($run, $calls, undef, $fail) = make_run_seam(
        start => $X_GUID, names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME, $X_GUID => $X_NAME },
        list  => sub { ok_result(list_bytes(
            { guid => $X_GUID, name => $X_NAME, active => 1 }, { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME },
        )) },
    );
    $fail->{setactive} = rc1_result('');
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    my @recs = plan_records($legacy);
    my $last = $recs[-1];
    is((ref $last eq 'HASH' ? $last->{error} : undef), 'setactive-failed',
        'triage-4 setup: the held switch itself failed too (setactive-failed)') or diag(explain_undef());
    like((ref $last eq 'HASH' ? ($last->{detail} // '') : ''), qr/record-write-failed/,
        'triage-4: the journal keeps record-write-failed even when /setactive also fails')
        or diag(explain_undef());
}

# ===========================================================================
# Triage item 6 (step 6 redteam F8) -- a non-ASCII plan name round-trips
# byte-exact through the switch record and the restore/journal, instead of
# being replaced byte-by-byte with '?' via _ascii_sanitize.
# ===========================================================================
{
    my ($home, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('triage6sess');
    my $x_name_utf8 = "\xc3\x89quilibr\xc3\xa9"; # "\xc9quilibr\xe9" (French "Balanced"), raw UTF-8 bytes
    my ($run, $calls) = make_run_seam(
        start => $X_GUID,
        names => { $BAL_GUID => 'Balanced', $CW_GUID => $CW_NAME, $X_GUID => $x_name_utf8 },
        list  => sub { ok_result(list_bytes(
            { guid => $X_GUID, name => $x_name_utf8, active => 1 }, { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID, name => $CW_NAME },
        )) },
    );
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual'); # held switch, writes record X
    my $rec_raw = slurp(record_path($root));
    ok(defined $rec_raw && index($rec_raw, $x_name_utf8) >= 0,
        'triage-6: the switch record stores the plan name byte-exact (no ascii sanitization)')
        or diag(explain_undef());

    BpHook::disarm('triage6sess', actor => 'agent', reason => 'triage-6 release');
    BpPowerPlan::reconcile($legacy, run => $run, why => 'manual'); # unheld: restores X
    my $journal_raw = slurp("$legacy/power-journal.jsonl");
    ok(defined $journal_raw && index($journal_raw, $x_name_utf8) >= 0,
        'triage-6: the journal carries the plan name byte-exact (found_name or wanted_name)')
        or diag(explain_undef());
}

done_testing();
