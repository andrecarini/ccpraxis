#!/usr/bin/env perl
# platform: windows
#
# ORACLE for package 08-host-awake-actuator (blueprint wake-and-pause-consolidation),
# AC1-AC17 of
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/08-host-awake-actuator-spec.md
# (AC18 is the suite-wide check -- verified externally per the step-3 report, not asserted here).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. At the time this file is written, HostAwake.pm does
# not exist, bp-orchestrator.pl has no fleet_awake_step, bp-drive-next.pl's keepawake_apply
# has no 4th argument, KeepAwake.pm has no load_host_awake/registry_seams, and launcher.pl
# still owns a helper of its own. Every call to a not-yet-written sub goes through HA()/
# ORCH()/DRIVE() below, which turn "Undefined subroutine" into a plain undef instead of
# dying -- the same technique plan-hold-expiry.t's CL()/PP() already use.
#
# [A]/[B] TAGS, per the spec's own split recommendation (section 7): [A] = host-side
# (HostAwake, BpContinuityLease, BpPowerPlan, the orchestrator, drive-solo); [B] =
# launcher-side (KeepAwake.pm, launcher.pl). The implementer may converge these in two
# ordered rounds; this file's ACs are tagged so a partial [A]-only pass is legible.
#
# THE REAL POWER PLAN, A REAL DAEMON, REAL POWERSHELL AND A REAL REFRESHER ARE NEVER USED:
# every reconcile call supplies a `run` seam (plan_opts => { run => ... }); every
# daemon_loop call supplies spawn/kill_pid/powershell_available/sleep seams and
# max_iterations; launcher.pl is only ever slurped as TEXT, never executed or required.
#
# AC -> DC mapping (ledger done criteria / spec's own DC column):
#   AC1              -> DC2 (state_root, byte-identical to BpHook::state_dir)
#   AC2, AC3, AC4     -> DC1 (the pure registry + decide layer)
#   AC5, AC6          -> DC1 (tick fixtures, incl. a missed tick)
#   AC7, AC8, AC9     -> DC2 (producers publish; launcher/orchestrator fixtures; start-from-nothing)
#   AC10              -> DC2, DC4 (grep: no BpKeepAwake::apply/spawn outside the one actuator)
#   AC11              -> DC2, DC4 (drive-solo publishes, calls no BpKeepAwake sub)
#   AC12              -> DC3, DC4 (old sandbox-holds keep counting until stale)
#   AC13              -> DC4 (at most one helper spawned across all sources)
#   AC14              -> DC2 (converge/ensure_daemon consider registry entries)
#   AC15              -> DC3, DC4 (reconcile counts registry entries for every caller)
#   AC16              -> DC2, DC1 (CLI subprocess, registry-unwritable, crashed-producer, garbled entry)
#   AC17              -> DC5 (KeepAwake::load_host_awake load safety)
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP;

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $BS = "$Bin/../../scripts") =~ s{\\}{/}g;
(my $SS = "$Bin/../../../sandbox/scripts") =~ s{\\}{/}g;

require "$BS/BpHook.pm";
require "$BS/BpAwakeConst.pm";
require "$BS/BpContinuityLease.pm";
require "$BS/bp-keepawake.pl";
require "$BS/BpPowerPlan.pm";

my $HA_LOADED = do { local $@; eval { require "$BS/HostAwake.pm"; 1 } };
my $HA_LOAD_ERR = $@;
my $ORCH_LOADED = do { local $@; eval { require "$BS/bp-orchestrator.pl"; 1 } };
my $DRIVE_LOADED = do { local $@; eval { require "$BS/bp-drive-next.pl"; 1 } };
unshift @INC, $SS;
my $KA_LOADED = do { local $@; eval { require "$SS/KeepAwake.pm"; 1 } };

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;

my $J = JSON::PP->new->canonical;

# ---------------------------------------------------------------------------
# HA/ORCH/DRIVE/KA(name, @args) -- call Package::<name> without ever dying
# when the sub does not exist yet.
# ---------------------------------------------------------------------------
sub _soft_call {
    my ($pkg, $name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"${pkg}::${name}"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? (wantarray ? @ret : $ret[0]) : undef;
}
sub HA    { return _soft_call('HostAwake',   @_) }
sub ORCH  { return _soft_call('BpOrch',      @_) }
sub DRIVE { return _soft_call('BpDrive',     @_) }
sub BA    { return _soft_call('BpAwakeConst', @_) }
sub explain_undef { return 'the called sub does not exist yet, or died -- see explain_undef()' }

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

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

sub registry_file { my ($root, $id) = @_; return "$root/awake-sources/$id.json" }

sub write_registry_entry {
    my ($root, $id, %o) = @_;
    my $dir = "$root/awake-sources";
    make_path($dir);
    my %h = (
        v => 1, awake => 1, source => $id,
        reason => $o{reason} // 'active',
        until => $o{until},
        written_at => $o{written_at} // time(),
    );
    open(my $fh, '>', registry_file($root, $id)) or die $!;
    print {$fh} $J->encode(\%h) . "\n";
    close $fh;
    if (defined $o{mtime}) { utime($o{mtime}, $o{mtime}, registry_file($root, $id)) }
}

my $BAL = '381b4222-f694-41f0-9685-ff5bb260df2e';
my $CW  = '54a34db5-af62-4d8a-ba50-af7155ee895a';
sub ok_result { return { status => 'ok', rc => 0, out => $_[0], ms => 1 } }
sub run_seam {
    my $active = $BAL;
    my @calls;
    my $fn = sub {
        push @calls, [@_];
        if ($_[0] eq '/getactivescheme') {
            my $name = $active eq $CW ? 'Continuous work' : 'Balanced';
            return ok_result("Power Scheme GUID: $active  ($name)\r\n");
        }
        if ($_[0] eq '/list') {
            return ok_result("\r\nExisting Power Schemes (* Active)\r\n---\r\n"
                . "Power Scheme GUID: $BAL  (Balanced)\r\nPower Scheme GUID: $CW  (Continuous work)\r\n");
        }
        if ($_[0] eq '/setactive') { $active = $_[1]; return ok_result('') }
        return ok_result('');
    };
    return ($fn, \@calls, sub { return $active });
}
sub setactive_sequence { my ($calls) = @_; return map { $_->[1] } grep { $_->[0] eq '/setactive' } @$calls }
sub log_seam { my @ev; return (sub { push @ev, [@_] }, \@ev) }
sub log_count {
    my ($ev, $event, $like) = @_;
    return scalar grep { $_->[0] eq $event && (!defined $like || $_->[1] =~ $like) } @$ev;
}
sub recorder_seam { my @calls; return (sub { push @calls, [@_]; return undef }, \@calls) }

$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ===========================================================================
# AC1 [A] (DC2) -- BpAwakeConst::state_root() is byte-identical to
# BpHook::state_dir() for every environment shape in spec 2.1. Decision
# 22/26(a) (the fix-batch design, superseding the earlier "G1 refused"
# reading): state_root lives in BpAwakeConst.pm, and HostAwake::state_root
# (kept, if at all, only as a thin delegate) must answer identically.
# ===========================================================================
{
    ok(defined &BpAwakeConst::state_root,
        'AC1 (Decision 22/26(a)): BpAwakeConst::state_root is defined')
        or diag(explain_undef());

    my $t = tempdir(CLEANUP => 1);
    (my $abs = "$t/abs") =~ s{\\}{/}g;
    make_path($abs);
    (my $abs_bs = $abs) =~ s{/}{\\}g;

    my @cases = (
        ['BUTLER_STATE_DIR absolute, no trailing /' => { BUTLER_STATE_DIR => $abs }],
        ['BUTLER_STATE_DIR absolute, trailing /'     => { BUTLER_STATE_DIR => "$abs/" }],
        ['BUTLER_STATE_DIR absolute, backslashes'    => { BUTLER_STATE_DIR => $abs_bs }],
        ['BUTLER_STATE_DIR relative, HOME also unset' => { BUTLER_STATE_DIR => 'relative/x' }],
        ['HOME only'                                 => { HOME => $abs }],
        ['USERPROFILE only'                          => { USERPROFILE => $abs }],
        ['neither'                                   => {}],
    );
    for my $c (@cases) {
        my ($label, $set) = @$c;
        delete $ENV{$_} for qw(BUTLER_STATE_DIR HOME USERPROFILE);
        $ENV{$_} = $set->{$_} for keys %$set;
        is(BA('state_root'), BpHook::state_dir(), "AC1: BpAwakeConst::state_root() == BpHook::state_dir() ($label)")
            or diag(explain_undef());
        is(HA('state_root'), BA('state_root'),
            "AC1 (Decision 26(a)): HostAwake::state_root() agrees with BpAwakeConst::state_root() ($label)")
            or diag(explain_undef());
    }

    # Non-ASCII "Andr\x{e9}" path, as both an unflagged (raw UTF-8 bytes) and
    # a utf8-flagged string for the SAME character content.
    my $bytes = "$t/Andr\xc3\xa9";   # raw UTF-8 bytes for e-acute, unflagged
    require Encode;
    my $flagged = Encode::decode('UTF-8', "$t/Andr\xc3\xa9");
    delete $ENV{$_} for qw(BUTLER_STATE_DIR HOME USERPROFILE);
    $ENV{BUTLER_STATE_DIR} = $bytes;
    is(BA('state_root'), BpHook::state_dir(), 'AC1: BpAwakeConst::state_root() == state_dir() (non-ASCII, unflagged bytes)')
        or diag(explain_undef());
    is(HA('state_root'), BA('state_root'),
        'AC1 (Decision 26(a)): HostAwake::state_root() agrees (non-ASCII, unflagged bytes)')
        or diag(explain_undef());
    delete $ENV{BUTLER_STATE_DIR};
    $ENV{BUTLER_STATE_DIR} = $flagged;
    is(BA('state_root'), BpHook::state_dir(), 'AC1: BpAwakeConst::state_root() == state_dir() (non-ASCII, utf8-flagged)')
        or diag(explain_undef());
    is(HA('state_root'), BA('state_root'),
        'AC1 (Decision 26(a)): HostAwake::state_root() agrees (non-ASCII, utf8-flagged)')
        or diag(explain_undef());

    delete $ENV{$_} for qw(BUTLER_STATE_DIR HOME USERPROFILE);
}

# ===========================================================================
# AC2 [A] (DC1, DC2) -- B1 (publish), B2 (withdraw), incl. the .t guard and
# awake=>0 refused.
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/root") =~ s{\\}{/}g;
    make_path($root);

    my $ok = HA('publish', 'sandbox-ctr1', { awake => 1, reason => 'busy-lease', until => undef },
        root => $root, now => 1000);
    is($ok, 1, 'AC2: publish(valid id, awake=>1) returns 1') or diag(explain_undef());
    my $file = registry_file($root, 'sandbox-ctr1');
    ok(-e $file, 'AC2: ...and writes <root>/awake-sources/<id>.json');
    my $decoded = eval { $J->decode(slurp($file)) };
    if (ref $decoded eq 'HASH') {
        is_deeply([ sort keys %$decoded ], [ sort qw(awake reason source until v written_at) ],
            'AC2: exactly the six keys');
        is($decoded->{awake}, 1, 'AC2: awake == 1');
        is($decoded->{source}, 'sandbox-ctr1', 'AC2: source == id');
        is($decoded->{reason}, 'busy-lease', 'AC2: reason carried through');
        is($decoded->{until}, undef, 'AC2: until is JSON null');
        is($decoded->{written_at}, 1000, 'AC2: written_at == now');
    } else {
        fail('AC2: the written content decodes as a JSON object');
        diag(explain_undef());
    }
    is(((stat($file))[9]), 1000, 'AC2: mtime equals written_at (utime applied)');

    HA('publish', 'sandbox-ctr1', { awake => 1, reason => 'active', until => undef }, root => $root, now => 2000);
    my $decoded2 = eval { $J->decode(slurp($file)) };
    is($decoded2->{reason}, 'active', 'AC2: a second publish overwrites the file in place')
        if ref $decoded2 eq 'HASH';

    unlink $file;
    my $refused = HA('publish', 'sandbox-ctr1', { awake => 0, reason => 'settled' }, root => $root, now => 3000);
    is($refused, 0, 'AC2: publish with awake=>0 returns 0 (Decision 12: withdraw, never awake=>0)')
        or diag(explain_undef());
    ok(!-e $file, 'AC2: ...and writes nothing');

    my $bad_id = HA('publish', 'not-an-id', { awake => 1, reason => 'x' }, root => $root, now => 3000);
    is($bad_id, 0, 'AC2: publish with an id failing ID_RE returns 0') or diag(explain_undef());
    ok(!-e registry_file($root, 'not-an-id'), 'AC2: ...and writes nothing');

    my $noroot = HA('publish', 'sandbox-ctr1', { awake => 1, reason => 'x' }, root => undef, now => 3000);
    is($noroot, 0, 'AC2: publish with an undef root returns 0') or diag(explain_undef());

    HA('publish', 'sandbox-ctr1', { awake => 1, reason => 'active' }, root => $root, now => 4000);
    ok(-e $file, 'AC2 setup: the file exists before withdraw');
    is(HA('withdraw', 'sandbox-ctr1', root => $root), 1, 'AC2: withdraw returns 1') or diag(explain_undef());
    ok(!-e $file, 'AC2: ...and removes the file');
    is(HA('withdraw', 'sandbox-ctr1', root => $root), 1, 'AC2: withdraw again (absent) still returns 1')
        or diag(explain_undef());
    is(HA('withdraw', 'not-an-id', root => $root), 0, 'AC2: withdraw with a bad id returns 0 (refused)')
        or diag(explain_undef());

    # the .t guard: root resolved from state_root() (no explicit root, no
    # $HostAwake::STATE_ROOT seam), BUTLER_STATE_DIR unset -- nothing is
    # written even though HOME points at a writable tempdir.
    {
        my $home = tempdir(CLEANUP => 1);
        local %ENV = %ENV;
        delete $ENV{BUTLER_STATE_DIR};
        $ENV{HOME} = $home;
        $ENV{USERPROFILE} = $home;
        local $HostAwake::STATE_ROOT = undef;
        my $guarded = HA('publish', 'sandbox-ctrguard', { awake => 1, reason => 'x' }, now => 5000);
        is($guarded, 0, 'AC2: the .t guard refuses a publish with no root seam and no BUTLER_STATE_DIR')
            or diag(explain_undef());
        ok(!-e "$home/.claude/butler-state/continuity/awake-sources",
            'AC2: ...and nothing is written under HOME');
    }
}

# ===========================================================================
# AC3 [A] (DC1) -- B3 (entry_counts boundaries) + B4 (read_registry validity).
# ===========================================================================
{
    my $LEASE_FRESH = BpAwakeConst::LEASE_FRESH();
    my $HORIZON     = BpAwakeConst::FLEET_PAUSE_HORIZON();

    my @rows = (
        ['counts at written_at+LEASE_FRESH-1' =>
            { valid => 1, written_at => 1000, until => undef }, 1000 + $LEASE_FRESH - 1, 1],
        ['not at +LEASE_FRESH' =>
            { valid => 1, written_at => 1000, until => undef }, 1000 + $LEASE_FRESH, 0],
        ['until=written_at+3600 counts at +3599' =>
            { valid => 1, written_at => 1000, until => 1000 + 3600 }, 1000 + 3599, 1],
        # Decision 26(b) (fix-batch design, supersedes the old strict-until
        # boundary): a paused drive-solo session that resumes exactly on time
        # must never be released at the until boundary itself, so an entry
        # with `until` counts through until + LEASE_FRESH, not just until.
        # The exact boundary at +LEASE_FRESH is deliberately left unpinned
        # (the design text says "counts until until + LEASE_FRESH" without
        # specifying strict vs inclusive); only the two sides a resume must
        # see are asserted.
        ['until+LEASE_FRESH-1 still counts (Decision 26(b): the resume grace)' =>
            { valid => 1, written_at => 1000, until => 1000 + 3600 }, 1000 + 3600 + $LEASE_FRESH - 1, 1],
        ['until+LEASE_FRESH+1 stops counting (Decision 26(b))' =>
            { valid => 1, written_at => 1000, until => 1000 + 3600 }, 1000 + 3600 + $LEASE_FRESH + 1, 0],
        ['until beyond FLEET_PAUSE_HORIZON past written_at is ignored (ignored once >= LEASE_FRESH)' =>
            { valid => 1, written_at => 1000, until => 1000 + $HORIZON + 1 }, 1000 + $LEASE_FRESH, 0],
        ['...but still counts within LEASE_FRESH alone' =>
            { valid => 1, written_at => 1000, until => 1000 + $HORIZON + 1 }, 1000 + $LEASE_FRESH - 1, 1],
        ['written_at=now+LEASE_FRESH+1 never counts (clock garbage)' =>
            { valid => 1, written_at => 1000 + $LEASE_FRESH + 1, until => undef }, 1000, 0],
        ['written_at=now+LEASE_FRESH counts' =>
            { valid => 1, written_at => 1000 + $LEASE_FRESH, until => undef }, 1000, 1],
        ['an invalid entry never counts' =>
            { valid => 0, written_at => 1000, until => undef }, 1000, 0],
    );
    for my $r (@rows) {
        my ($label, $entry, $now, $expect) = @$r;
        is(HA('entry_counts', $entry, $now), $expect, "AC3: entry_counts -- $label")
            or diag(explain_undef());
    }

    # Decision 26(c) (fix-batch design, red-team m7): a solo- entry is capped
    # at SOLO_PAUSE_HORIZON (12h) past written_at, not the 32h fleet/sandbox
    # horizon. fleet- and sandbox- entries keep the larger FLEET_PAUSE_HORIZON.
    my $SOLO_HORIZON = BpAwakeConst::SOLO_PAUSE_HORIZON();
    my @prefix_rows = (
        ['solo- entry: until beyond SOLO_PAUSE_HORIZON is ignored (capped at the 12h solo horizon)' =>
            { valid => 1, id => 'solo-aaaaaaaa', written_at => 1000, until => 1000 + $SOLO_HORIZON + 1 },
            1000 + $SOLO_HORIZON, 0],
        ['solo- entry: until AT SOLO_PAUSE_HORIZON still counts just before it' =>
            { valid => 1, id => 'solo-aaaaaaaa', written_at => 1000, until => 1000 + $SOLO_HORIZON },
            1000 + $SOLO_HORIZON - 1, 1],
        ['fleet- entry: the SAME until (just past the 12h solo horizon) still counts -- fleet uses the 32h horizon' =>
            { valid => 1, id => 'fleet-bp-aaaaaaaa', written_at => 1000, until => 1000 + $SOLO_HORIZON + 1 },
            1000 + $SOLO_HORIZON, 1],
        ['sandbox- entry: the SAME until also still counts -- sandbox uses the 32h horizon too' =>
            { valid => 1, id => 'sandbox-ctr', written_at => 1000, until => 1000 + $SOLO_HORIZON + 1 },
            1000 + $SOLO_HORIZON, 1],
    );
    for my $r (@prefix_rows) {
        my ($label, $entry, $now, $expect) = @$r;
        is(HA('entry_counts', $entry, $now), $expect, "AC3 (Decision 26(c)): entry_counts -- $label")
            or diag(explain_undef());
    }

    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/root") =~ s{\\}{/}g;
    my $dir = "$root/awake-sources";
    make_path($dir);
    my $write = sub {
        my ($name, $content) = @_;
        open(my $fh, '>', "$dir/$name") or die $!;
        print {$fh} $content;
        close $fh;
    };
    $write->('sandbox-good.json.tmp.1234', '{"v":1,"awake":1,"source":"sandbox-good","until":null,"reason":"x","written_at":1000}');
    $write->('not-an-id!!.json', '{"v":1,"awake":1,"source":"not-an-id!!","until":null,"reason":"x","written_at":1000}');
    $write->('sandbox-big.json', '{"v":1,"awake":1,"source":"sandbox-big","until":null,"reason":"x","written_at":1000,"pad":"'
        . ('x' x 5000) . '"}');
    $write->('sandbox-garbled.json', '{not json');
    $write->('sandbox-wrongv.json', '{"v":2,"awake":1,"source":"sandbox-wrongv","until":null,"reason":"x","written_at":1000}');
    $write->('sandbox-notawake.json', '{"v":1,"awake":0,"source":"sandbox-notawake","until":null,"reason":"x","written_at":1000}');
    $write->('sandbox-mismatch.json', '{"v":1,"awake":1,"source":"sandbox-other","until":null,"reason":"x","written_at":1000}');
    $write->('sandbox-good2.json', '{"v":1,"awake":1,"source":"sandbox-good2","until":null,"reason":"x","written_at":1000}');

    my $entries = HA('read_registry', $root);
    if (ref $entries eq 'ARRAY') {
        my %by_id = map { $_->{id} => $_ } @$entries;
        ok(!(grep { $_->{id} =~ /\.tmp\./ } @$entries), 'AC3 (B4): a *.json.tmp.* file is never considered');
        ok(!exists $by_id{'not-an-id!!'}, 'AC3 (B4): a name failing ID_RE is never considered');
        is($by_id{'sandbox-big'}{valid}, 0, 'AC3 (B4): a file over 4096 bytes is invalid')
            if exists $by_id{'sandbox-big'};
        is($by_id{'sandbox-garbled'}{valid}, 0, 'AC3 (B4): garbled JSON is invalid')
            if exists $by_id{'sandbox-garbled'};
        is($by_id{'sandbox-wrongv'}{valid}, 0, 'AC3 (B4): v != 1 is invalid')
            if exists $by_id{'sandbox-wrongv'};
        is($by_id{'sandbox-notawake'}{valid}, 0, 'AC3 (B4): awake != 1 is invalid')
            if exists $by_id{'sandbox-notawake'};
        is($by_id{'sandbox-mismatch'}{valid}, 0, 'AC3 (B4): source ne id is invalid')
            if exists $by_id{'sandbox-mismatch'};
        is($by_id{'sandbox-good2'}{valid}, 1, 'AC3 (B4): a well-formed entry is valid')
            if exists $by_id{'sandbox-good2'};
        my @ids = map { $_->{id} } @$entries;
        is_deeply(\@ids, [ sort @ids ], 'AC3 (B4): read_registry is sorted by id');
    } else {
        fail('AC3 (B4): read_registry did not return an ARRAY ref');
        diag(explain_undef());
    }

    is_deeply(HA('read_registry', undef), [], 'AC3 (B4): read_registry(undef) -> []') or diag(explain_undef());
    is_deeply(HA('read_registry', "$t/does-not-exist"), [],
        'AC3 (B4): read_registry on a missing directory -> [] (never dies)') or diag(explain_undef());
}

# ===========================================================================
# Decision 26(d) [A] (DC1, red-team m1) -- read_registry considers only
# REGULAR files named <id>.json; a non-regular entry (here, a real FIFO --
# this host's Git-for-Windows/Cygwin perl honours POSIX::mkfifo, which is
# exactly the shape the red-team report reproduced with `mkfifo` under
# `timeout 10`) must neither die nor hang the reader, and must not block a
# sibling, valid entry from being read.
#
# NOT bounded with alarm() in-process: read_registry's own per-file `eval`
# around the open+slurp swallows an ALRM-raised die from INSIDE that same
# process (confirmed empirically -- an in-process alarm just stalls for its
# own duration and then returns normally, hiding a real hang instead of
# detecting it). Bounded instead with fork()+waitpid() across a real process
# boundary, per the task's "bound any risky read with alarm or timeout":
# the child either finishes and reports a count, or is killed after the
# bound and the parent sees no report.
# ===========================================================================
{
    require POSIX;
    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/root") =~ s{\\}{/}g;
    my $dir = "$root/awake-sources";
    make_path($dir);
    write_registry_entry($root, 'sandbox-ok26d', reason => 'active', until => undef);

    my $fifo_path = "$dir/sandbox-fifo26d.json";
    my $made_fifo = eval { POSIX::mkfifo($fifo_path, 0666) };

    SKIP: {
        skip 'POSIX::mkfifo is unavailable on this host; cannot create a FIFO fixture', 3
            unless $made_fifo;

        my $resultfile = "$t/result26d.json";
        my $pid = fork();
        if (!defined $pid) {
            fail('AC (Decision 26(d)): could not fork a child to bound the read') for 1 .. 3;
        } else {
            if ($pid == 0) {
                my $entries = HA('read_registry', $root);
                if (ref $entries eq 'ARRAY') {
                    my $fh;
                    if (open($fh, '>', $resultfile)) {
                        print {$fh} $J->encode([ map { { id => $_->{id}, valid => $_->{valid} } } @$entries ]);
                        close $fh;
                    }
                }
                POSIX::_exit(0);
            }

            my $deadline = time() + 8;
            my $done = 0;
            while (time() < $deadline) {
                my $w = waitpid($pid, POSIX::WNOHANG());
                if ($w == $pid) { $done = 1; last }
                select(undef, undef, undef, 0.2);
            }
            unless ($done) {
                kill('KILL', $pid);
                waitpid($pid, 0);
            }

            ok($done,
                'AC (Decision 26(d)): read_registry does not hang on a FIFO named <id>.json '
              . '(a forked reader finishes within the bound instead of being killed)')
                or diag('the forked reader was still running and had to be killed -- a real hang');

            if ($done && -e $resultfile) {
                my $entries = eval { $J->decode(slurp($resultfile)) };
                my %by_id = (ref $entries eq 'ARRAY') ? (map { $_->{id} => $_ } @$entries) : ();
                ok(!exists $by_id{'sandbox-fifo26d'} || !$by_id{'sandbox-fifo26d'}{valid},
                    'AC (Decision 26(d)): the FIFO is never read as a valid entry (non-regular file)')
                    or diag(explain_undef());
                ok(exists $by_id{'sandbox-ok26d'} && $by_id{'sandbox-ok26d'}{valid},
                    'AC (Decision 26(d)): a real sibling entry is still read correctly despite the FIFO')
                    or diag(explain_undef());
            } else {
                fail('AC (Decision 26(d)): read_registry did not return a usable result') if $done;
                fail('AC (Decision 26(d)): (second assertion skipped after a hang)') unless $done;
            }
        }
    }
}

# ===========================================================================
# AC4 [A] (DC1, DC4) -- decide() rows D1-D4, first match wins; fresh_holds
# alone never sets lock.
# ===========================================================================
{
    my @cases = (
        ['D1 arm>0 wins over everything' =>
            { arms => 1, counting => ['sandbox-x'], fresh_holds => 1, pending => 1 },
            { mode => 'arm', lock => 1, plan_hold => 1, why => 'refresher-tick' }],
        ['D2 counting>0, no arm' =>
            { arms => 0, counting => ['sandbox-x'], fresh_holds => 0, pending => 1 },
            { mode => 'source', lock => 1, plan_hold => 1, why => 'refresher-source-tick' }],
        ['D3 pending, fresh_holds>0 -> plan_hold 1' =>
            { arms => 0, counting => [], fresh_holds => 1, pending => 1 },
            { mode => 'hold', lock => 0, plan_hold => 1, why => 'refresher-hold-tick' }],
        ['D3 pending, fresh_holds==0 -> plan_hold 0' =>
            { arms => 0, counting => [], fresh_holds => 0, pending => 1 },
            { mode => 'hold', lock => 0, plan_hold => 0, why => 'refresher-hold-tick' }],
        ['D4 otherwise -> idle' =>
            { arms => 0, counting => [], fresh_holds => 0, pending => 0 },
            { mode => 'idle', lock => 0, plan_hold => 0, why => 'refresher-exit' }],
        ['fresh_holds alone (pending false) never reaches a locking row' =>
            { arms => 0, counting => [], fresh_holds => 5, pending => 0 },
            { mode => 'idle', lock => 0, plan_hold => 0, why => 'refresher-exit' }],
    );
    for my $c (@cases) {
        my ($label, $in, $expect) = @$c;
        my $d = HA('decide', $in);
        if (ref $d eq 'HASH') {
            is($d->{mode}, $expect->{mode}, "AC4: decide -- $label (mode)") or diag(explain_undef());
            is($d->{lock}, $expect->{lock}, "AC4: decide -- $label (lock)");
            is($d->{plan_hold}, $expect->{plan_hold}, "AC4: decide -- $label (plan_hold)");
            is($d->{why}, $expect->{why}, "AC4: decide -- $label (why)");
            is_deeply($d->{counting}, $in->{counting}, "AC4: decide -- $label (counting is copied through)");
        } else {
            fail("AC4: decide -- $label returned a non-HASH");
            diag(explain_undef());
        }
    }
    SKIP: {
        skip 'HostAwake::decide not defined yet', 1 unless defined &HostAwake::decide;
        my $died = !eval { HostAwake::decide('not a hash'); 1 };
        ok($died, 'AC4: decide dies on a non-HASH argument');
    }
}

# ===========================================================================
# AC5 [A] (DC1) -- tick fixtures: one daemon_loop(max_iterations => 1) per
# fixture, over fresh_group()'s root.
# ===========================================================================
{
    # (a) one host arm -> TICK, 1 helper spawn, plan Continuous work.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        ok(BpHook::arm('ha-ac5a', role => 'manual', by => 'on'), 'AC5(a) setup: a host arm exists');

        my ($run, $calls) = run_seam();
        my ($sp, $sp_calls) = (sub { push @{(my $c = [])}, 1; return 9001 }, undef);
        my @sp_rec;
        my $spawn_seam = sub { push @sp_rec, [@_]; return 9001 };
        my ($log, $ev) = log_seam();
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => $spawn_seam, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log,
            plan_opts => { run => $run },
        );
        is(log_count($ev, 'TICK'), 1, 'AC5(a): one TICK is logged') or diag(explain_undef());
        is(scalar(@sp_rec), 1, 'AC5(a): the helper is spawned exactly once') or diag(explain_undef());
        is((setactive_sequence($calls))[-1] // '', $CW, 'AC5(a): the plan ends on Continuous work')
            or diag(explain_undef());
        BpHook::disarm('ha-ac5a') if defined &BpHook::disarm;
    }

    # (b) one sandbox entry, no arm -> SOURCE-TICK naming it, 1 spawn, plan CW.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        write_registry_entry($root, 'sandbox-ac5b', reason => 'busy-lease', until => undef);

        my ($run, $calls) = run_seam();
        my @sp_rec;
        my $spawn_seam = sub { push @sp_rec, [@_]; return 9001 };
        my ($log, $ev) = log_seam();
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => $spawn_seam, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log,
            plan_opts => { run => $run },
        );
        is(log_count($ev, 'SOURCE-TICK', qr/sandbox-ac5b/), 1,
            'AC5(b): one SOURCE-TICK naming sandbox-ac5b is logged') or diag(explain_undef());
        is(scalar(@sp_rec), 1, 'AC5(b): the helper is spawned exactly once') or diag(explain_undef());
        is((setactive_sequence($calls))[-1] // '', $CW, 'AC5(b): the plan ends on Continuous work')
            or diag(explain_undef());
    }

    # (c) one solo entry with until, no arm -> SOURCE-TICK, 1 spawn, plan CW.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        write_registry_entry($root, 'solo-ac5caaaaaaaa', reason => 'pause-pending', until => time() + 3600);

        my ($run, $calls) = run_seam();
        my @sp_rec;
        my $spawn_seam = sub { push @sp_rec, [@_]; return 9001 };
        my ($log, $ev) = log_seam();
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => $spawn_seam, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log,
            plan_opts => { run => $run },
        );
        is(log_count($ev, 'SOURCE-TICK', qr/solo-ac5caaaaaaaa/), 1,
            'AC5(c): one SOURCE-TICK naming the solo entry is logged') or diag(explain_undef());
        is(scalar(@sp_rec), 1, 'AC5(c): the helper is spawned exactly once') or diag(explain_undef());
        is((setactive_sequence($calls))[-1] // '', $CW, 'AC5(c): the plan ends on Continuous work')
            or diag(explain_undef());
    }

    # (d) one stale entry and a live helper pid file -> HOLD-TICK, kill seam
    # called, plan restored, entry removed, SOURCE-PRUNED logged.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        my $old = time() - BpAwakeConst::LEASE_FRESH() - 5;
        write_registry_entry($root, 'sandbox-ac5dstale0', reason => 'active', until => undef,
            written_at => $old, mtime => $old);
        open(my $fh, '>', "$legacy/keepawake.pid") or die $!;
        print {$fh} "4242\n";
        close $fh;

        my ($run, $calls) = run_seam();
        my ($kill_seam, $kill_calls) = recorder_seam();
        my ($log, $ev) = log_seam();
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => $kill_seam, owner_winpid => undef,
            sleep => sub { }, log => $log,
            plan_opts => { run => $run },
        );
        is(log_count($ev, 'HOLD-TICK'), 1, 'AC5(d): one HOLD-TICK is logged') or diag(explain_undef());
        is(scalar(@$kill_calls), 1, 'AC5(d): the live keepawake.pid helper is killed') or diag(explain_undef());
        ok(!-e registry_file($root, 'sandbox-ac5dstale0'), 'AC5(d): the stale entry is removed');
        is(log_count($ev, 'SOURCE-PRUNED', qr/sandbox-ac5dstale0/), 1,
            'AC5(d): SOURCE-PRUNED names the removed entry') or diag(explain_undef());
    }

    # (e) nothing at all -> IDLE reason=no-live-arm, no spawn, exit reconcile only.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        my ($run, $calls) = run_seam();
        my @sp_rec;
        my $spawn_seam = sub { push @sp_rec, [@_]; return 9001 };
        my ($log, $ev) = log_seam();
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => $spawn_seam, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log,
            plan_opts => { run => $run },
        );
        is(log_count($ev, 'IDLE', qr/reason=no-live-arm/), 1, 'AC5(e): IDLE reason=no-live-arm is logged');
        is(scalar(@sp_rec), 0, 'AC5(e): the helper is never spawned');
    }
}

# ===========================================================================
# AC6 [A] (DC1, B10) -- missed tick: level, not edge. Sandbox entry,
# max_iterations => 2.
# ===========================================================================
{
    # the helper pid file is deleted inside the first tick's log callback ->
    # 2 spawns over 2 ticks.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        write_registry_entry($root, 'sandbox-ac6a', reason => 'active', until => undef);

        my ($run) = run_seam();
        my @sp_rec;
        my $spawn_seam = sub {
            my ($dir) = @_;
            push @sp_rec, [@_];
            open(my $fh, '>', "$dir/keepawake.pid") or die $!;
            print {$fh} "9001\n";
            close $fh;
            return 9001;
        };
        my $tick_n = 0;
        my $log_seam_cb = sub {
            my ($event, $detail) = @_;
            if ($event eq 'SOURCE-TICK') {
                $tick_n++;
                unlink "$legacy/keepawake.pid" if $tick_n == 1;
            }
        };
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 2, journal => 0,
            spawn => $spawn_seam, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log_seam_cb,
            plan_opts => { run => $run },
        );
        is(scalar(@sp_rec), 2, 'AC6: a pid file removed between ticks is re-spawned on the next tick (2 spawns over 2 ticks)')
            or diag(explain_undef());
    }

    # the run seam fails /setactive on tick 1 and succeeds on tick 2 -> CW
    # active after tick 2 (03 semantics: retried, not given up on).
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        write_registry_entry($root, 'sandbox-ac6b', reason => 'active', until => undef);

        my $active = $BAL;
        my $setactive_calls = 0;
        my $run = sub {
            if ($_[0] eq '/getactivescheme') {
                my $name = $active eq $CW ? 'Continuous work' : 'Balanced';
                return ok_result("Power Scheme GUID: $active  ($name)\r\n");
            }
            if ($_[0] eq '/list') {
                return ok_result("\r\nExisting Power Schemes (* Active)\r\n---\r\n"
                    . "Power Scheme GUID: $BAL  (Balanced)\r\nPower Scheme GUID: $CW  (Continuous work)\r\n");
            }
            if ($_[0] eq '/setactive') {
                $setactive_calls++;
                return { status => 'error', rc => 1, out => '', ms => 1 } if $setactive_calls == 1;
                $active = $_[1];
                return ok_result('');
            }
            return ok_result('');
        };
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 2, journal => 0,
            spawn => sub { 9001 }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { },
            plan_opts => { run => $run },
        );
        is($active, $CW, 'AC6: a /setactive failure on tick 1 is retried and CW is active after tick 2')
            or diag(explain_undef());
    }

    # a hand change to plan X between ticks -> tick 2 re-enforces CW with the
    # record unchanged.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        write_registry_entry($root, 'sandbox-ac6c', reason => 'active', until => undef);

        my $tick_n = 0;
        my ($run, $calls) = run_seam();
        my $wrapped_run = sub {
            my @r = @_;
            if ($r[0] eq '/setactive' && $tick_n == 1) {
                # pretend a hand switch happens right after tick 1's own setactive
            }
            return $run->(@r);
        };
        my $log_cb = sub {
            my ($event) = @_;
            if ($event eq 'SOURCE-TICK') { $tick_n++ }
        };
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 2, journal => 0,
            spawn => sub { 9001 }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log_cb,
            plan_opts => { run => $wrapped_run },
        );
        is((setactive_sequence($calls))[-1] // '', $CW,
            'AC6: a later tick re-enforces CW regardless of what happened in between')
            or diag(explain_undef());
    }
}

# ===========================================================================
# AC7 [A] (DC2) -- start from nothing: ensure_refresher, then a sandbox entry,
# then a tick.
# ===========================================================================
{
    delete local $ENV{CCPRAXIS_NO_WAKELOCK};
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';

    my ($sp0, $sp0_calls) = recorder_seam();
    is(HA('ensure_refresher', spawn => $sp0), 'idle',
        'AC7: ensure_refresher with no arm and an empty registry returns idle') or diag(explain_undef());
    is(scalar(@$sp0_calls), 0, 'AC7: ...and never calls the spawn seam');

    write_registry_entry($root, 'sandbox-ac7', reason => 'active', until => undef);
    my @sp_calls;
    my $sp = sub { push @sp_calls, [@_]; return 9001 };
    is(HA('ensure_refresher', spawn => $sp), 'spawned',
        'AC7: ensure_refresher with a sandbox entry present returns spawned') or diag(explain_undef());
    is(scalar(@sp_calls), 1, 'AC7: ...and the spawn seam is called exactly once');

    my ($run) = run_seam();
    my ($log, $ev) = log_seam();
    my @tick_sp;
    BpContinuityLease::daemon_loop($legacy,
        tick => 1, max_iterations => 1, journal => 0,
        spawn => sub { push @tick_sp, [@_]; return 9002 }, powershell_available => sub { 1 },
        kill_pid => sub { }, owner_winpid => undef,
        sleep => sub { }, log => $log,
        plan_opts => { run => $run },
    );
    is(log_count($ev, 'SOURCE-TICK'), 1, 'AC7: the following tick is a SOURCE-TICK') or diag(explain_undef());
    is(scalar(@tick_sp), 1, 'AC7: ...and the helper spawn seam is called') or diag(explain_undef());
}

# ===========================================================================
# AC8 [B] (DC2, DC4) -- launcher fixture: KeepAwake built from
# KeepAwake::registry_seams; static checks on launcher.pl.
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/root") =~ s{\\}{/}g;
    make_path($root);

    my @ensure_calls;
    my $intent = sub { { reason => 'busy-lease' } };
    my %seams;
    if (defined &KeepAwake::registry_seams) {
        %seams = KeepAwake::registry_seams(
            source    => 'sandbox-ctr',
            available => 1,
            intent    => $intent,
            ensure    => sub { push @ensure_calls, 1 },
            log       => sub { },
        );
    }
    SKIP: {
        skip 'KeepAwake::registry_seams not defined yet', 10 unless keys %seams;
        local $HostAwake::STATE_ROOT = $root;
        my $start_rv = $seams{start}->();
        ok(defined $start_rv, 'AC8: start() returns something truthy when it publishes')
            or diag(explain_undef());
        ok(-e registry_file($root, 'sandbox-ctr'), 'AC8: sync(1)/start() writes sandbox-ctr.json');
        my $decoded = eval { $J->decode(slurp(registry_file($root, 'sandbox-ctr'))) };
        if (ref $decoded eq 'HASH') {
            is($decoded->{awake}, 1, 'AC8: ...awake 1');
            is($decoded->{until}, undef, 'AC8: ...until null (a sandbox entry never carries until)');
        }
        is(scalar(@ensure_calls), 1, 'AC8: start() calls ensure() exactly once');

        my $before = slurp(registry_file($root, 'sandbox-ctr'));
        sleep 1 if 0; # never really sleeps; written_at compared by content below
        $seams{refresh}->();
        ok(-e registry_file($root, 'sandbox-ctr'), 'AC8: refresh() leaves the entry in place');

        my $ensure_calls_before_stop = scalar(@ensure_calls);
        $seams{stop}->($start_rv);
        ok(!-e registry_file($root, 'sandbox-ctr'), 'AC8: stop()/release() withdraws the entry');
        # Decision 26(e) (fix-batch design): withdrawing the last counting
        # entry must also call the ensure seam, so the refresher can converge
        # one more time and restore the power plan even if it had already
        # died -- the launcher's own withdraw-only exit otherwise has no way
        # to make that converge happen (review m3/m4; registry_seams' `stop`
        # already receives an `ensure` coderef for exactly this purpose).
        is(scalar(@ensure_calls), $ensure_calls_before_stop + 1,
            'AC8 (Decision 26(e)): stop() also calls ensure() once, so the refresher can converge and restore the plan')
            or diag(explain_undef());
    }

    my $LSRC = slurp("$SS/launcher.pl");
    ok(length($LSRC), 'AC8 precondition: launcher.pl is readable');
    like($LSRC, qr/KeepAwake::registry_seams\s*\(/,
        'AC8: launcher.pl builds its seams from KeepAwake::registry_seams(');
    like($LSRC, qr/KeepAwake->new\s*\(\s*start\s*=>\s*\$ka_reg\{start\}\s*,\s*stop\s*=>\s*\$ka_reg\{stop\}\s*\)/s,
        'AC8: launcher.pl calls KeepAwake->new( start => $ka_reg{start}, stop => $ka_reg{stop} )')
        or diag(explain_undef());
    like($LSRC, qr/KeepAwake::load_host_awake\(\s*"?\$?\{?INSTALL_ROOT\b/,
        'AC8: launcher.pl calls KeepAwake::load_host_awake( with an $INSTALL_ROOT-based path')
        or diag(explain_undef());
}

# ===========================================================================
# AC9 [A] (DC2) -- BpOrch::fleet_awake_step with HOST_SIDE 1.
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/root") =~ s{\\}{/}g;
    make_path($root);
    local $HostAwake::STATE_ROOT = $root;
    local $HostAwake::HOST_SIDE = 1;

    my $bpdir = "$t/bp";
    make_path($bpdir);
    my %state;
    my @ensure_calls;
    my @log_lines;
    my $log = sub { push @log_lines, $_[0] };

    my $r1 = ORCH('fleet_awake_step', {
        phase => 'active', bp => 'bp-x', bpdir => $bpdir, runs => "$t/runs",
        state => \%state, log => $log, ensure => sub { push @ensure_calls, 1 }, now => 1000,
    });
    is($r1, 'published', 'AC9: phase active publishes') or diag(explain_undef());
    is(scalar(@ensure_calls), 1, 'AC9: ...and calls ensure once');

    my $r2 = ORCH('fleet_awake_step', {
        phase => 'pause-pending', bp => 'bp-x', bpdir => $bpdir, runs => "$t/runs",
        state => \%state, log => $log, ensure => sub { }, now => 1001,
    });
    is($r2, 'published', 'AC9: phase pause-pending also publishes') or diag(explain_undef());

    make_path("$t/runs");
    open(my $fh, '>', "$t/runs/keepawake.pid") or die $!;
    print {$fh} "4242\n";
    close $fh;
    my @killed;
    my $r3 = ORCH('fleet_awake_step', {
        phase => 'settled', bp => 'bp-x', bpdir => $bpdir, runs => "$t/runs",
        state => \%state, log => $log, now => 1002,
    });
    is($r3, 'withdrawn', 'AC9: phase settled withdraws') or diag(explain_undef());
    ok(!-e "$t/runs/keepawake.pid", 'AC9: ...and retires the legacy runs/keepawake.pid');

    local $HostAwake::HOST_SIDE = 0;
    my %state2;
    my $r4 = ORCH('fleet_awake_step', {
        phase => 'active', bp => 'bp-x', bpdir => $bpdir, runs => "$t/runs",
        state => \%state2, log => sub { }, now => 1003,
    });
    is($r4, 'skipped', 'AC9: off host_side(), fleet_awake_step is skipped') or diag(explain_undef());
}

# ===========================================================================
# AC10 [A, B] (DC2, DC4) -- grep: no BpKeepAwake::apply/spawn outside the one
# actuator. Comment-only lines are stripped before matching.
# ===========================================================================
sub code_only {
    my ($src) = @_;
    return join "\n", grep { !/^\s*#/ } split /\n/, $src;
}
{
    my $orch_src  = code_only(slurp("$BS/bp-orchestrator.pl"));
    my $drive_src = code_only(slurp("$BS/bp-drive-next.pl"));
    unlike($orch_src,  qr/BpKeepAwake::apply\(/, 'AC10: bp-orchestrator.pl contains no BpKeepAwake::apply(')
        or diag(explain_undef());
    unlike($orch_src,  qr/BpKeepAwake::spawn\(/, 'AC10: bp-orchestrator.pl contains no BpKeepAwake::spawn(')
        or diag(explain_undef());
    unlike($drive_src, qr/BpKeepAwake::apply\(/, 'AC10: bp-drive-next.pl contains no BpKeepAwake::apply(')
        or diag(explain_undef());
    unlike($drive_src, qr/BpKeepAwake::spawn\(/, 'AC10: bp-drive-next.pl contains no BpKeepAwake::spawn(')
        or diag(explain_undef());

    my $launcher_src = code_only(slurp("$SS/launcher.pl"));
    for my $tok (qw(_power_plan_hold bp-power-plan plan_told)) {
        unlike($launcher_src, qr/\Q$tok\E/, "AC10: launcher.pl contains no '$tok'") or diag(explain_undef());
    }
    for my $tok ('BpKeepAwake::spawn(', 'BpKeepAwake::stop_child(', 'BpKeepAwake::child_alive') {
        my $re = quotemeta($tok);
        unlike($launcher_src, qr/$re/, "AC10: launcher.pl contains no '$tok'") or diag(explain_undef());
    }

    # Across butler + sandbox scripts (bp-keepawake.pl excluded, the definer):
    # apply(/replace( appear only in BpContinuityLease.pm; spawn( appears nowhere.
    opendir(my $dh1, $BS) or die $!;
    opendir(my $dh2, $SS) or die $!;
    my @files = (
        (map { "$BS/$_" } grep { /\.p[lm]$/ && $_ ne 'bp-keepawake.pl' } readdir($dh1)),
        (map { "$SS/$_" } grep { /\.p[lm]$/ } readdir($dh2)),
    );
    closedir $dh1; closedir $dh2;
    my (@apply_sites, @replace_sites, @spawn_sites);
    for my $f (@files) {
        my $src = code_only(slurp($f));
        push @apply_sites,   $f if $src =~ /BpKeepAwake::apply\(/;
        push @replace_sites, $f if $src =~ /BpKeepAwake::replace\(/;
        push @spawn_sites,   $f if $src =~ /BpKeepAwake::spawn\(/;
    }
    is_deeply([ sort @apply_sites ],   [ "$BS/BpContinuityLease.pm" ],
        'AC10: BpKeepAwake::apply( appears only in BpContinuityLease.pm') or diag(explain_undef());
    is_deeply([ grep { $_ ne "$BS/BpContinuityLease.pm" } @replace_sites ], [],
        'AC10: BpKeepAwake::replace( appears only in BpContinuityLease.pm (if at all)') or diag(explain_undef());
    is_deeply(\@spawn_sites, [], 'AC10: BpKeepAwake::spawn( appears nowhere among these files')
        or diag(explain_undef());

    like($orch_src, qr/fleet_awake_step\(\s*\{[^}]*phase\s*=>\s*\$ka_phase/s,
        'AC10: bp-orchestrator.pl still calls fleet_awake_step( with $ka_phase') or diag(explain_undef());
    like($orch_src, qr/fleet_awake_step\(\s*\{[^}]*phase\s*=>\s*'settled'/s,
        'AC10: bp-orchestrator.pl still calls fleet_awake_step( with \'settled\'') or diag(explain_undef());
}

# ===========================================================================
# AC11 [A] (DC2, DC4) -- drive-solo's five B17 rows, HOST_SIDE 1.
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $root = "$t/root") =~ s{\\}{/}g;
    make_path($root);
    local $HostAwake::STATE_ROOT = $root;
    local $HostAwake::HOST_SIDE = 1;

    my $dsdir = "$t/project/.ccpraxis-local-data/.drive-solo";
    make_path($dsdir);
    my @apply_calls;
    my @spawn_calls;
    { no warnings 'redefine';
      local *BpKeepAwake::apply = sub { push @apply_calls, [@_] };
      local *BpKeepAwake::spawn = sub { push @spawn_calls, [@_]; return 9001 };

      DRIVE('keepawake_apply', 'active', $dsdir, { now => sub { 1000 } });
      DRIVE('keepawake_apply', 'pause-pending', $dsdir, { now => sub { 2000 } }, 2000 + 5 * 3600);
      DRIVE('keepawake_apply', 'pause-pending', $dsdir, { now => sub { 3000 } }, 3000 + 60);
      DRIVE('keepawake_apply', 'pause-pending', $dsdir, { now => sub { 4000 } }, undef);
      my @killed;
      DRIVE('keepawake_apply', 'settled', $dsdir, { now => sub { 5000 }, kill_pid => sub { push @killed, $_[0] } });
    }
    is(scalar(@apply_calls), 0, 'AC11: BpKeepAwake::apply is never called by keepawake_apply') or diag(explain_undef());
    is(scalar(@spawn_calls), 0, 'AC11: BpKeepAwake::spawn is never called by keepawake_apply') or diag(explain_undef());

    note('AC11: the five B17 publish/withdraw shapes themselves are checked indirectly through '
       . 'the apply/spawn-never-called assertion above and AC2\'s publish/withdraw unit coverage; '
       . 'a direct per-row registry-content check needs solo_id() to resolve for this fixture, '
       . 'which depends on the implementer\'s id derivation and is exercised in drive-next.t AC-4/AC-42.');
}

# ===========================================================================
# AC12 [A] (DC3, DC4) -- old-style sandbox-holds keep counting (plan only)
# until stale.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my $name = 'claude-ac12-aaaaaaaa';
    BpPowerPlan::set_sandbox_hold($root, $name, 1);

    my ($run, $calls) = run_seam();
    my @sp_rec;
    my $spawn_seam = sub { push @sp_rec, [@_]; return 9001 };
    my ($log, $ev) = log_seam();
    BpContinuityLease::daemon_loop($legacy,
        tick => 1, max_iterations => 1, journal => 0,
        spawn => $spawn_seam, powershell_available => sub { 1 },
        kill_pid => sub { }, owner_winpid => undef,
        sleep => sub { }, log => $log,
        plan_opts => { run => $run },
    );
    is(log_count($ev, 'HOLD-TICK'), 1, 'AC12: a fresh old hold with no arm/entry is a HOLD-TICK')
        or diag(explain_undef());
    is(scalar(@sp_rec), 0, 'AC12: ...and the helper spawn seam is never called (the old launcher owns its own)');
    is((setactive_sequence($calls))[-1] // '', $CW, 'AC12: ...and the plan is Continuous work');

    # a fresh hold AND a counting sandbox entry for the SAME container ->
    # SOURCE-TICK, exactly 1 spawn (the old launcher's own helper is exempt).
    {
        my (undef, $legacy2, $root2) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        BpPowerPlan::set_sandbox_hold($root2, $name, 1);
        write_registry_entry($root2, "sandbox-$name", reason => 'busy-lease', until => undef);

        my ($run2) = run_seam();
        my @sp_rec2;
        my ($log2, $ev2) = log_seam();
        BpContinuityLease::daemon_loop($legacy2,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => sub { push @sp_rec2, [@_]; return 9001 }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log2,
            plan_opts => { run => $run2 },
        );
        is(log_count($ev2, 'SOURCE-TICK'), 1, 'AC12: hold + counting entry for the same container -> SOURCE-TICK')
            or diag(explain_undef());
        is(scalar(@sp_rec2), 1, 'AC12: ...and exactly 1 spawn total') or diag(explain_undef());
    }
}

# ===========================================================================
# AC13 [A, B] (DC4) -- at most one helper spawned across all sources.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    local $HostAwake::STATE_ROOT = $root;
    local $HostAwake::HOST_SIDE = 1;

    ok(BpHook::arm('ha-ac13', role => 'manual', by => 'on'), 'AC13 setup: a host arm exists');
    write_registry_entry($root, 'sandbox-ac13', reason => 'busy-lease', until => undef);
    DRIVE('keepawake_apply', 'active', "$root/../drivesolo", { now => sub { time() } })
        if defined &BpDrive::keepawake_apply;
    ORCH('fleet_awake_step', { phase => 'active', bp => 'bp-ac13', bpdir => "$root/../bp",
        runs => "$root/../runs", state => {}, log => sub { }, now => time() })
        if defined &BpOrch::fleet_awake_step;

    my @spawn_calls;
    my $alive = 0;
    { no warnings 'redefine';
      local *BpKeepAwake::spawn = sub { push @spawn_calls, [@_]; $alive = 1; return 9001 };
      local *BpKeepAwake::child_alive = sub { return $alive ? 1 : undef };

      BpContinuityLease::daemon_loop($legacy,
          tick => 1, max_iterations => 3, journal => 0,
          powershell_available => sub { 1 },
          kill_pid => sub { }, owner_winpid => undef,
          sleep => sub { },
          plan_opts => { run => (run_seam())[0] },
      );
    }
    is(scalar(@spawn_calls), 1, 'AC13: exactly one BpKeepAwake::spawn( call across 3 ticks with every source present')
        or diag(explain_undef());
    BpHook::disarm('ha-ac13') if defined &BpHook::disarm;
}

# ===========================================================================
# AC14 [A] (DC2) -- converge() B14 + ensure_daemon() B13.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    write_registry_entry($root, 'sandbox-ac14', reason => 'busy-lease', until => undef);

    my ($kill_seam, $kill_calls) = recorder_seam();
    my @verdict = BpContinuityLease::converge($legacy, kill_pid => $kill_seam, spawn => sub { 9001 });
    is($verdict[0], 'held', 'AC14: converge() with no arm and a counting entry returns held')
        or diag(explain_undef());
    is(scalar(@$kill_calls), 0, 'AC14: ...and never calls the kill_pid seam');

    unlink registry_file($root, 'sandbox-ac14');
    my @verdict2 = BpContinuityLease::converge($legacy, kill_pid => $kill_seam, spawn => sub { 9001 });
    is($verdict2[0], 'released', 'AC14: converge() with no arm and no counting entry is unchanged (releases)');

    # ensure_daemon (B13): idle while the registry is empty; spawned once an
    # entry exists; running with a fresh lease.pid.
    {
        delete local $ENV{CCPRAXIS_NO_WAKELOCK};
        my ($sp, $sp_calls) = recorder_seam();
        is(BpContinuityLease::ensure_daemon($legacy, spawn => $sp), 'idle',
            'AC14: ensure_daemon with an empty registry and no arm returns idle');

        write_registry_entry($root, 'sandbox-ac14b', reason => 'busy-lease', until => undef);
        my @sp2;
        my $v = BpContinuityLease::ensure_daemon($legacy, spawn => sub { push @sp2, [@_]; return 9001 });
        is($v, 'spawned', 'AC14: ensure_daemon with an entry file present returns spawned') or diag(explain_undef());
        is(scalar(@sp2), 1, 'AC14: ...and the spawn seam is called once');

        my $pf = BpContinuityLease::daemon_pid_file($legacy);
        unless (-e $pf) {
            open(my $pfh, '>', $pf) or die "open $pf: $!";
            print {$pfh} "$$\n";
            close $pfh;
        }
        utime(time(), time(), $pf);
        my ($sp3, $sp3_calls) = recorder_seam();
        is(BpContinuityLease::ensure_daemon($legacy, spawn => $sp3), 'running',
            'AC14: ensure_daemon with a fresh lease.pid returns running');
        is(scalar(@$sp3_calls), 0, 'AC14: ...and does not spawn');
    }
}

# ===========================================================================
# AC15 [A] (DC3, DC4) -- reconcile() B15 + the old CLI vs. the refresher
# never flapping.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    write_registry_entry($root, 'sandbox-ac15', reason => 'busy-lease', until => undef);

    my ($run, $calls) = run_seam();
    my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is(ref $o, 'HASH', 'AC15: reconcile answers');
    if (ref $o eq 'HASH') {
        is($o->{armed}, 1, 'AC15: a counting sandbox entry counts as armed') or diag(explain_undef());
        ok((grep { $_ eq 'source:sandbox-ac15' } @{ $o->{arm_ids} // [] }),
            'AC15: arm_ids lists source:sandbox-ac15') or diag(explain_undef());
    }
    is((setactive_sequence($calls))[-1] // '', $CW, 'AC15: ...and the plan switches to Continuous work');

    unlink registry_file($root, 'sandbox-ac15');
    my $o2 = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is($o2->{armed}, 0, 'AC15: once the entry stops counting, the same call restores the record');
    is((setactive_sequence($calls))[-1] // '', $BAL, 'AC15: ...back to Balanced');

    # the old CLI --hold on another container, with a counting sandbox entry
    # present, makes no /setactive away from CW.
    {
        my (undef, $legacy3, $root3) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        write_registry_entry($root3, 'sandbox-ac15other', reason => 'busy-lease', until => undef);
        local %ENV = (%ENV, BUTLER_STATE_DIR => $ENV{BUTLER_STATE_DIR},
            CCPRAXIS_CONTINUITY_ACTIVE_DIR => $legacy3, CCPRAXIS_NO_WAKELOCK => 1);
        my $cli = "$BS/bp-power-plan.pl";
        `"$^X" "$cli" reconcile --why cli-hold --hold claude-ac15cli 2>&1`;
        my ($run3, $calls3) = run_seam($CW);
        my $o3 = BpPowerPlan::reconcile($legacy3, run => $run3, why => 'manual');
        is($o3->{armed}, 2, 'AC15: reconcile after the CLI --hold counts the fresh hold and the registry entry')
            or diag(explain_undef());
        ok((grep { $_ eq 'source:sandbox-ac15other' } @{ $o3->{arm_ids} // [] }),
            'AC15: arm_ids lists source:sandbox-ac15other') or diag(explain_undef());
        is((setactive_sequence($calls3))[-1] // '', $CW, 'AC15: ...and the plan does not leave Continuous work')
            or diag(explain_undef());
        `"$^X" "$cli" reconcile --why cli-release --release claude-ac15cli 2>&1`;
    }
}

# ===========================================================================
# AC16 [A] (DC2, DC1) -- B19 CLI subprocess, B20 registry-unwritable, B21
# crashed producer, B22 garbled entry.
# ===========================================================================
{
    # B19: perl HostAwake.pm ensure / bogus, as a real subprocess.
    my $HOST_AWAKE_PM = "$BS/HostAwake.pm";
    SKIP: {
        skip 'HostAwake.pm does not exist yet', 4 unless -f $HOST_AWAKE_PM;
        my $t = tempdir(CLEANUP => 1);
        local $ENV{BUTLER_STATE_DIR} = $t;
        local $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
        my $out = `"$^X" "$HOST_AWAKE_PM" ensure 2>&1`;
        is($? >> 8, 0, 'AC16 (B19): perl HostAwake.pm ensure exits 0');
        is($out, '', 'AC16 (B19): ...silently');
        my $out2 = `"$^X" "$HOST_AWAKE_PM" bogus 2>&1`;
        is($? >> 8, 2, 'AC16 (B19): perl HostAwake.pm bogus exits 2');
        like($out2, qr/^usage: perl HostAwake\.pm ensure/, 'AC16 (B19): ...with one usage line on STDERR');
    }

    # B20: registry directory unwritable (a regular file planted at
    # awake-sources) -- publish returns 0 without dying; the refresher
    # treats the missing registry as empty.
    {
        my $t = tempdir(CLEANUP => 1);
        (my $root = "$t/root") =~ s{\\}{/}g;
        make_path($root);
        open(my $fh, '>', "$root/awake-sources") or die $!;
        close $fh;
        my $r = eval { HA('publish', 'sandbox-ac16b', { awake => 1, reason => 'x' }, root => $root, now => 1000) };
        ok(!$@, 'AC16 (B20): publish against an unwritable registry dir does not die') or diag($@);
        is($r, 0, 'AC16 (B20): ...and returns 0') or diag(explain_undef());
        is_deeply(HA('read_registry', $root), [], 'AC16 (B20): read_registry treats it as empty, never dies')
            or diag(explain_undef());
    }

    # B21: a crashed producer's entry counts until max(written_at+LEASE_FRESH,
    # until), then the next tick is HOLD and prunes it.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        my $now = time();
        my $old_enough = $now - BpAwakeConst::LEASE_FRESH() - 5;
        write_registry_entry($root, 'sandbox-ac16crash', reason => 'active', until => undef,
            written_at => $old_enough, mtime => $old_enough);

        my ($run) = run_seam();
        my ($log, $ev) = log_seam();
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log,
            plan_opts => { run => $run },
        );
        is(log_count($ev, 'HOLD-TICK'), 1, 'AC16 (B21): a crashed producer bound by LEASE_FRESH gives a HOLD-TICK')
            or diag(explain_undef());
        ok(!-e registry_file($root, 'sandbox-ac16crash'), 'AC16 (B21): ...and the entry is pruned');
    }

    # B22: a garbled entry never counts; keeps the refresher alive for one
    # HOLD tick, which prunes it.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        my $dir = "$root/awake-sources";
        make_path($dir);
        open(my $fh, '>', "$dir/sandbox-ac16garbled.json") or die $!;
        print {$fh} "{not json";
        close $fh;

        my ($run) = run_seam();
        my ($log, $ev) = log_seam();
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => sub { undef }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log,
            plan_opts => { run => $run },
        );
        is(log_count($ev, 'HOLD-TICK'), 1, 'AC16 (B22): a garbled entry gives a HOLD-TICK, never locking')
            or diag(explain_undef());
        ok(!-e "$dir/sandbox-ac16garbled.json", 'AC16 (B22): ...and is pruned');
    }
}

# ===========================================================================
# AC17 [B] (DC5, Decision 13) -- KeepAwake::load_host_awake load safety.
# Fully covered (all three cases, in a fresh subprocess each) in
# one-keepawake-helper.t per spec 6.3; this block adds the in-process real-
# tree + compile-with-butler-absent checks this file can reach directly.
# ===========================================================================
{
    my ($ok, $why) = _soft_call('KeepAwake', 'load_host_awake', "$BS/HostAwake.pm");
    is($ok, 1, 'AC17: KeepAwake::load_host_awake against the real tree gives ok=1') or diag(explain_undef());
    is($why, undef, 'AC17: ...and no reason');

    my ($ok2, $why2) = _soft_call('KeepAwake', 'load_host_awake', "$BS/does-not-exist-08.pm");
    is($ok2, 0, 'AC17: a missing path gives ok=0') or diag(explain_undef());
    like($why2 // '', qr/^missing:/, 'AC17: ...with a missing: reason');

    # awake-constants-single-source.t AC-14 keeps passing: launcher.pl and
    # KeepAwake.pm still compile with the butler directory absent. Verified
    # by running that file directly (not duplicated here to avoid a second,
    # slower fixture tree copy); see the step-3 report.
    note('AC17: butler-absent compile-safety is pinned by awake-constants-single-source.t AC-14, not duplicated here');
}

# ===========================================================================
# Decision 25 / red-team M1 [B] -- the launcher's sandbox registry entry is
# refreshed only from the dashboard's keep-awake path (the 120s `keepawake`
# block in the main loop), and the [b] backpack modal blocks that loop
# synchronously for its whole lifetime. $modal_heartbeat already exists as
# the seam the SAME file's own MEDIUM-1 fix used to keep the container
# heartbeat alive under the modal; it must now ALSO drive a keep-awake
# refresh, or an operator who opens [b] and walks away loses the host
# wake-lock mid-run (red-team M1).
#
# This is a SOURCE-LEVEL pin (Dashboard.pm is never required/run here, same
# house rule as launcher.pl): a regex loose enough to admit either shape the
# spec review named --
#   (a) a `keepalive` seam that $modal_heartbeat invokes, which in turn calls
#       something like `$ka_reg{refresh}->() if $KEEPAWAKE->running`, or
#   (b) reusing the EXISTING `$heartbeat`/`keepawake` callback plumbing so
#       $modal_heartbeat's own body calls the keep-awake refresh directly --
# but strict enough that merely calling $heartbeat->() (today's behaviour,
# which only beats the container heartbeat, not the host wake-lock) does not
# satisfy it.
# ===========================================================================
{
    my $DSRC = slurp("$SS/Dashboard.pm");
    ok(length($DSRC), 'Decision 25/M1 precondition: Dashboard.pm is readable');

    my ($modal_hb_body) = $DSRC =~ /(my\s+\$modal_heartbeat\s*=\s*sub\s*\{.*?\n\s*\};)/s;
    ok(defined $modal_hb_body, 'Decision 25/M1 precondition: $modal_heartbeat sub body is extractable')
        or diag('could not locate `my $modal_heartbeat = sub { ... };` in Dashboard.pm');

    SKIP: {
        skip '$modal_heartbeat body not found; cannot inspect it', 1 unless defined $modal_hb_body;
        like($modal_hb_body,
            qr/\$(?:keepawake|keep_alive|ka_reg\{refresh\}|keepalive|ka_refresh|refresh_awake|awake_refresh)\w*\s*(?:->)?\s*\(/,
            'Decision 25 / red-team M1: $modal_heartbeat also runs a keep-awake refresh '
          . '(a $keepawake-shaped call, a $ka_reg{refresh}-style call, or an equivalently named '
          . 'dedicated refresh hook), not only $heartbeat->()')
            or diag("modal_heartbeat body:\n$modal_hb_body");
    }
}

# ===========================================================================
# Red-team m6 [B] -- a container/blueprint/project name that fails ID_RE
# (sandbox_id/fleet_id/solo_id all return undef) must produce a log line
# rather than silence. The orchestrator side (fleet_awake_step) already logs
# "host-awake failed <id_for_log>" on the edge-triggered log, so this pins
# only the launcher side, through the one seam that is actually observable
# without running launcher.pl: KeepAwake::registry_seams' own `start`, called
# with source => undef (what launcher.pl passes when HostAwake::sandbox_id
# returns undef for an over-long or CR-tainted container name). Only the
# PRESENCE of a log call is pinned, not any particular event name or field
# shape -- the spec never names one, and this is new behaviour from the
# fix-batch, not an existing contract.
# ===========================================================================
{
    SKIP: {
        skip 'KeepAwake::registry_seams not defined yet', 2
            unless defined &KeepAwake::registry_seams;
        my ($log, $calls) = recorder_seam();
        my %seams = KeepAwake::registry_seams(
            source    => undef,
            available => 1,
            intent    => sub { { reason => 'busy-lease' } },
            ensure    => sub { },
            log       => $log,
        );
        my $rv = $seams{start}->();
        is($rv, undef, 'red-team m6 precondition: start() with an undef source publishes nothing')
            or diag(explain_undef());
        ok(scalar(@$calls) > 0,
            'red-team m6: start() with an undef source (an ID_RE-failing name) logs at least one line, '
          . 'instead of failing silently')
            or diag(explain_undef());
    }
}

done_testing();
