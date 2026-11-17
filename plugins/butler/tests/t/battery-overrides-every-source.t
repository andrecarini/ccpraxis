#!/usr/bin/env perl
# platform: host
#
# ORACLE for package 09-battery-for-every-source (blueprint
# wake-and-pause-consolidation), AC1-AC14 of
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/
# 09-battery-for-every-source-spec.md. AC14 (the suite-wide check) is
# verified externally per the step-3 report, not asserted here -- the same
# split host-awake-actuator.t's own header uses for its AC18.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION OF THIS PACKAGE'S WRITE SET. At the
# time this file is written, BpAcWatch::read_state/battery_verdict/host_step,
# HostAwake::host_ac_dir/battery_releases/battery_step, and
# BpPowerJournal::awake_record do not exist; HostAwake::gather/decide know
# nothing about battery; BpPowerPlan::reconcile never asks battery_releases.
# Every call into a not-yet-written sub goes through SC() below, which turns
# "Undefined subroutine" into a plain undef instead of dying, so a missing
# sub makes assertions FAIL for a missing-behavior reason, never a compile
# error. The existing subs this file ALSO calls (BpHook::arm, BpAcWatch::
# observe, BpContinuityLease::daemon_loop, BpPowerPlan::reconcile/
# write_switch_record/set_sandbox_hold, BpPowerJournal::append_record/
# build_timeline/_summary_for) are 08/03/05/11-era contracts this package
# does not change except as named in the spec, and are called directly.
#
# NO REAL POWERCFG, PROBE, POWERSHELL, HELPER OR DAEMON IS EVER USED: every
# reconcile call supplies a `run` seam; every daemon_loop call supplies
# spawn/kill_pid/powershell_available/sleep seams and max_iterations; the
# host AC state is seeded by writing JSON directly, never via a real probe.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP;

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $BS = "$Bin/../../scripts") =~ s{\\}{/}g;

require "$BS/BpHook.pm";
require "$BS/BpAwakeConst.pm";
require "$BS/BpContinuityLease.pm";
require "$BS/bp-keepawake.pl";
require "$BS/BpPowerPlan.pm";
require "$BS/BpPowerJournal.pm";
require "$BS/BpAcWatch.pm";
my $HA_LOADED = do { local $@; eval { require "$BS/HostAwake.pm"; 1 } };
my $HA_LOAD_ERR = $@;

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;

my $J = JSON::PP->new->canonical;

# ---------------------------------------------------------------------------
# SC(pkg, name, @args) -- call Package::<name> without ever dying when the
# sub (or the whole module) does not exist yet. Same idiom as
# host-awake-actuator.t's HA()/ORCH()/DRIVE() and power-journal.t's PZ().
# ---------------------------------------------------------------------------
sub SC {
    my ($pkg, $name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"${pkg}::${name}"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? (wantarray ? @ret : $ret[0]) : undef;
}
sub AW { return SC('BpAcWatch',     @_) }
sub HA { return SC('HostAwake',     @_) }
sub PJ { return SC('BpPowerJournal', @_) }
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

# host_ac_state_path($root) -- the file BpAcWatch's own helpers resolve to
# under HostAwake::host_ac_dir($root) . '/.drive-solo/ac-state.json' (spec
# 2.2 item 1). Computed WITHOUT calling HostAwake::host_ac_dir (not yet
# written), so a missing host_ac_dir never masks this file's own seeding.
sub host_ac_state_path { my ($root) = @_; return "$root/host-ac/.drive-solo/ac-state.json" }
sub host_ac_log_path   { my ($root) = @_; return "$root/host-ac/.drive-solo/ac-cycle.log" }

sub write_host_ac_state {
    my ($root, $h) = @_;
    my $p = host_ac_state_path($root);
    (my $dir = $p) =~ s{/[^/]+$}{};
    make_path($dir);
    open(my $fh, '>:raw', $p) or die $!;
    print {$fh} $J->encode($h);
    close $fh;
}

sub read_host_ac_log_events {
    my ($root) = @_;
    my $p = host_ac_log_path($root);
    return () unless -f $p;
    open my $fh, '<:raw', $p or return ();
    local $/;
    my $c = <$fh>;
    close $fh;
    return () unless defined $c && length $c;
    my @lines = split /\n/, $c;
    pop @lines while @lines && $lines[-1] eq '';
    return map { (split /\s+/, $_, 4)[2] } @lines;
}

my $BAL = '381b4222-f694-41f0-9685-ff5bb260df2e';
my $CW  = '54a34db5-af62-4d8a-ba50-af7155ee895a';
my $X   = 'a1a1a1a1-b2b2-c3c3-d4d4-e5e5e5e5e5e5';
sub ok_result { return { status => 'ok', rc => 0, out => $_[0], ms => 1 } }

# run_seam3() -- a powercfg fake over THREE plans (Balanced, Continuous
# work, and a third "Power saver" plan X), spec 09's own fixture note
# (section 4: "/list holds Balanced, CW and a third plan X").
sub run_seam3 {
    my ($start) = @_;
    my $active = $start // $CW;
    my @calls;
    my $fn = sub {
        push @calls, [@_];
        if ($_[0] eq '/getactivescheme') {
            my $name = $active eq $CW ? 'Continuous work' : $active eq $X ? 'Power saver' : 'Balanced';
            return ok_result("Power Scheme GUID: $active  ($name)\r\n");
        }
        if ($_[0] eq '/list') {
            return ok_result("\r\nExisting Power Schemes (* Active)\r\n---\r\n"
                . "Power Scheme GUID: $BAL  (Balanced)\r\n"
                . "Power Scheme GUID: $CW  (Continuous work)\r\n"
                . "Power Scheme GUID: $X  (Power saver)\r\n");
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
sub log_index_of {
    my ($ev, $event) = @_;
    for my $i (0 .. $#$ev) { return $i if $ev->[$i][0] eq $event }
    return undef;
}
sub recorder_seam { my @calls; return (sub { push @calls, [@_]; return undef }, \@calls) }

sub jsonl_lines {
    my ($path) = @_;
    my $raw = slurp($path);
    return () unless length $raw;
    my @l = split /\n/, $raw;
    pop @l while @l && $l[-1] eq '';
    return @l;
}
sub decode_or_undef { my ($l) = @_; my $d = eval { $J->decode($l) }; return $@ ? undef : $d }

# write_pl_and_run($code, %envset) -- writes $code to a scratch .pl file
# (never .t, so no test file ever trips an unrelated .t guard by accident)
# and runs it as a REAL separate `perl` process, with %envset applied to
# %ENV for the duration of the call (a key set to undef is DELETED, never
# left at whatever this process happened to have). Used by the fix-batch
# blocks below (Decisions 29(a) and 30) to exercise the per-process cache
# and the real `$0` check across an actual process boundary -- the only way
# to tell "this process's own cache/counter" apart from "the next one" is to
# actually start a next one. Every caller passes BUTLER_STATE_DIR explicitly
# (set or deleted) so no subprocess ever falls through to a real HOME.
sub write_pl_and_run {
    my ($code, %envset) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.pl');
    print {$fh} $code;
    close $fh;
    my %saved = %ENV;
    for my $k (keys %envset) {
        if (defined $envset{$k}) { $ENV{$k} = $envset{$k} } else { delete $ENV{$k} }
    }
    my $out = `"$^X" "$path" 2>&1`;
    %ENV = %saved;
    unlink $path;
    return $out;
}

sub dir_entries {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @n = grep { !/^\.\.?$/ } readdir($dh);
    closedir $dh;
    return @n;
}

$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ===========================================================================
# AC1 -- B1: the battery_verdict table, every row, plus a non-HASH state.
# ===========================================================================
{
    my $now = time();
    my @rows = (
        ['expired, probed_at=now-60'   => { phase => 'expired', probed_at => $now - 60 },   'release', 'expired'],
        ['expired, probed_at=now-1801' => { phase => 'expired', probed_at => $now - 1801 }, 'hold',    'stale'],
        ['expired, probed_at=now+5'    => { phase => 'expired', probed_at => $now + 5 },    'hold',    'stale'],
        ['grace'                       => { phase => 'grace',   probed_at => $now - 10 },   'hold',    'grace'],
        ['ac'                          => { phase => 'ac',      probed_at => $now - 10 },   'hold',    'ac'],
        ['reconnected'                 => { phase => 'reconnected', probed_at => $now - 10 }, 'hold',  'reconnected'],
        ['monitoring, fresh'           => { phase => 'monitoring', probed_at => $now - 10 }, 'release', 'expired'],
        ['standing-down, fresh'        => { phase => 'standing-down', probed_at => $now - 10 }, 'release', 'expired'],
        ['bogus phase, V1 unknown-phase' => { phase => 'bogus', probed_at => $now - 10 },   'hold',    'unknown-phase'],
    );
    for my $r (@rows) {
        my ($label, $st, $want_v, $want_b) = @$r;
        my $v = AW('battery_verdict', $st, $now);
        if (ref $v eq 'HASH') {
            is($v->{verdict}, $want_v, "AC1: battery_verdict -- $label (verdict)") or diag(explain_undef());
            is($v->{basis}, $want_b, "AC1: battery_verdict -- $label (basis)") or diag(explain_undef());
        } else {
            fail("AC1: battery_verdict -- $label returned a non-HASH");
            diag(explain_undef());
        }
    }
    my $nonhash = AW('battery_verdict', 'not a hash', $now);
    if (ref $nonhash eq 'HASH') {
        is($nonhash->{verdict}, 'hold', 'AC1: battery_verdict(non-HASH) -- verdict hold') or diag(explain_undef());
        is($nonhash->{basis}, 'unknown-phase', 'AC1: battery_verdict(non-HASH) -- basis unknown-phase')
            or diag(explain_undef());
    } else {
        fail('AC1: battery_verdict(non-HASH) returned a non-HASH');
        diag(explain_undef());
    }
    is(AW('battery_verdict', undef, $now), undef, 'AC1 precondition: AW() turns a dying call into undef, never a crash')
        if !defined &BpAcWatch::battery_verdict;
}

# ===========================================================================
# AC2 -- B2-B7 through BpAcWatch::host_step with probe/now.
# ===========================================================================
{
    # B2: fresh dir, probe dc -> phase grace, hold, transitions
    # [AC-LOSS-DETECTED, GRACE-START].
    {
        my $t = tempdir(CLEANUP => 1);
        (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
        my $now = time();
        my $v = AW('host_step', $hdir, now => $now, probe => sub { 'dc' });
        if (ref $v eq 'HASH') {
            is($v->{phase}, 'grace', 'AC2 (B2): host_step from nothing with probe dc -> phase grace')
                or diag(explain_undef());
            is($v->{verdict}, 'hold', 'AC2 (B2): ...and verdict hold') or diag(explain_undef());
            is_deeply($v->{transitions}, ['AC-LOSS-DETECTED', 'GRACE-START'],
                'AC2 (B2): transitions are [AC-LOSS-DETECTED, GRACE-START]') or diag(explain_undef());
        } else {
            fail('AC2 (B2): host_step returned a non-HASH');
            diag(explain_undef());
        }
    }

    # B3: grace state with dc_since/grace_until in the past, probe dc ->
    # phase expired, release, transitions [GRACE-EXPIRED].
    {
        my $t = tempdir(CLEANUP => 1);
        (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
        my $now = time();
        write_host_ac_state($t, {
            v => 1, phase => 'grace', source => 'dc', probed_at => $now - 60,
            dc_since => $now - 400, grace_until => $now - 100,
        });
        my $v = AW('host_step', $hdir, now => $now, probe => sub { 'dc' });
        if (ref $v eq 'HASH') {
            is($v->{phase}, 'expired', 'AC2 (B3): past grace_until with dc -> phase expired') or diag(explain_undef());
            is($v->{verdict}, 'release', 'AC2 (B3): ...and verdict release') or diag(explain_undef());
            is_deeply($v->{transitions}, ['GRACE-EXPIRED'], 'AC2 (B3): transitions are [GRACE-EXPIRED]')
                or diag(explain_undef());
        } else {
            fail('AC2 (B3): host_step returned a non-HASH');
            diag(explain_undef());
        }
    }

    # B4: from fresh expired, probe ac -> ends at phase ac, verdict hold.
    # AC-RECONNECT-DETECTED then RESUME src=host-awake basis=ac. A
    # CLAUDE_PROJECT_DIR-derived drive-solo marker+state is byte-unchanged.
    {
        my $t = tempdir(CLEANUP => 1);
        (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
        my $now = time();
        write_host_ac_state($t, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
            dc_since => $now - 400, grace_until => $now - 100 });

        my $proj = tempdir(CLEANUP => 1);
        (my $proj_data = "$proj/.ccpraxis-local-data/.drive-solo") =~ s{\\}{/}g;
        make_path($proj_data);
        open(my $mfh, '>', "$proj_data/ac-standdown.json") or die $!;
        print {$mfh} '{"v":1,"since":0,"since_iso":"-","reason":"x","inflight":[]}';
        close $mfh;
        open(my $sfh, '>', "$proj_data/ac-state.json") or die $!;
        print {$sfh} '{"v":1,"phase":"standing-down","source":"dc","probed_at":1}';
        close $sfh;
        my $marker_before = slurp("$proj_data/ac-standdown.json");
        my $state_before  = slurp("$proj_data/ac-state.json");
        local $ENV{CLAUDE_PROJECT_DIR} = $proj;

        my $v = AW('host_step', $hdir, now => $now, probe => sub { 'ac' });
        if (ref $v eq 'HASH') {
            is($v->{phase}, 'ac', 'AC2 (B4): from fresh expired with probe ac -> phase ac') or diag(explain_undef());
            is($v->{verdict}, 'hold', 'AC2 (B4): ...and verdict hold') or diag(explain_undef());
            my @ev = read_host_ac_log_events($hdir =~ m{^(.*)/host-ac$} ? "$1" : $hdir);
            # read_host_ac_log_events expects a store ROOT (it appends
            # /host-ac/.drive-solo itself via host_ac_log_path); $hdir here
            # IS already the host-ac dir, so read the log directly instead.
            my $logp = "$hdir/.drive-solo/ac-cycle.log";
            my @lines = -f $logp ? do { open(my $fh, '<:raw', $logp); local $/; my $c = <$fh>; close $fh;
                my @l = split /\n/, $c; pop @l while @l && $l[-1] eq ''; @l } : ();
            my @events = map { (split /\s+/, $_, 4)[2] } @lines;
            my ($ri) = grep { $events[$_] eq 'AC-RECONNECT-DETECTED' } 0 .. $#events;
            my ($si) = grep { $events[$_] eq 'RESUME' } 0 .. $#events;
            ok(defined $ri && defined $si && $ri < $si,
                'AC2 (B4): AC-RECONNECT-DETECTED precedes RESUME in the host-ac log')
                or diag('events: ' . join(',', @events));
            ok((grep { /^\S+\s+\S+\s+RESUME\b/ && /src=host-awake/ && /basis=ac/ } @lines),
                'AC2 (B4): the RESUME line carries src=host-awake and basis=ac') or diag(join("\n", @lines));
        } else {
            fail('AC2 (B4): host_step returned a non-HASH');
            diag(explain_undef());
        }
        is(slurp("$proj_data/ac-standdown.json"), $marker_before,
            'AC2 (B4): the project drive-solo marker is byte-unchanged (host_step never touches it)');
        is(slurp("$proj_data/ac-state.json"), $state_before,
            'AC2 (B4): the project drive-solo state is byte-unchanged (host_step never mirrors into it)');
    }

    # B5: unknown readings never start or expire grace.
    {
        my $t = tempdir(CLEANUP => 1);
        (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
        my $now = time();
        write_host_ac_state($t, { v => 1, phase => 'grace', source => 'dc', probed_at => $now - 60,
            dc_since => $now - 400, grace_until => $now - 1 });
        my $v = AW('host_step', $hdir, now => $now, probe => sub { 'unknown' });
        is(ref $v eq 'HASH' ? $v->{phase} : undef, 'grace',
            'AC2 (B5): grace past grace_until with an unknown reading stays grace') or diag(explain_undef());
        is(ref $v eq 'HASH' ? $v->{verdict} : undef, 'hold',
            'AC2 (B5): ...and verdict stays hold') or diag(explain_undef());
    }

    # B6: from fresh expired, nine consecutive unknown readings stay
    # release; the tenth gives hold, WATCH-ERROR basis=probe-failed and
    # RESUME basis=probe-failed, phase ac. now advances by 60 per call.
    {
        my $t = tempdir(CLEANUP => 1);
        (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
        my $now = time();
        write_host_ac_state($t, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
            dc_since => $now - 400, grace_until => $now - 100 });
        my $v;
        for my $i (1 .. 9) {
            $v = AW('host_step', $hdir, now => $now + 60 * $i, probe => sub { 'unknown' });
            is(ref $v eq 'HASH' ? $v->{verdict} : undef, 'release',
                "AC2 (B6): unknown reading #$i stays release") or diag(explain_undef());
        }
        $v = AW('host_step', $hdir, now => $now + 60 * 10, probe => sub { 'unknown' });
        if (ref $v eq 'HASH') {
            is($v->{verdict}, 'hold', 'AC2 (B6): the 10th consecutive unknown reading gives hold')
                or diag(explain_undef());
            is($v->{phase}, 'ac', 'AC2 (B6): ...and leaves phase ac') or diag(explain_undef());
        } else {
            fail('AC2 (B6): the 10th host_step call returned a non-HASH');
            diag(explain_undef());
        }
        my $logp = "$hdir/.drive-solo/ac-cycle.log";
        my $logtext = slurp($logp);
        ok(($logtext =~ /WATCH-ERROR\b.*basis=probe-failed/ || $logtext =~ /basis=probe-failed.*WATCH-ERROR/),
            'AC2 (B6): the log carries a WATCH-ERROR basis=probe-failed line') or diag($logtext);
        ok(($logtext =~ /RESUME\b.*basis=probe-failed/),
            'AC2 (B6): the log carries a RESUME basis=probe-failed line') or diag($logtext);
    }

    # B7: expired with probed_at older than AC_STALE and probe dc ->
    # WATCH-ERROR basis=stale-reset, then AC-LOSS-DETECTED, GRACE-START;
    # phase grace, verdict hold.
    {
        my $t = tempdir(CLEANUP => 1);
        (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
        my $now = time();
        my $stale = BpAwakeConst::AC_STALE();
        write_host_ac_state($t, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - $stale - 5,
            dc_since => $now - $stale - 300, grace_until => $now - $stale - 1 });
        my $v = AW('host_step', $hdir, now => $now, probe => sub { 'dc' });
        if (ref $v eq 'HASH') {
            is($v->{phase}, 'grace', 'AC2 (B7): a stale expired state with probe dc restarts grace') or diag(explain_undef());
            is($v->{verdict}, 'hold', 'AC2 (B7): ...and verdict hold (grace restarts)') or diag(explain_undef());
        } else {
            fail('AC2 (B7): host_step returned a non-HASH');
            diag(explain_undef());
        }
        my $logtext = slurp("$hdir/.drive-solo/ac-cycle.log");
        my $wi = index($logtext, 'basis=stale-reset');
        my $ai = index($logtext, 'AC-LOSS-DETECTED');
        my $gi = index($logtext, 'GRACE-START');
        ok($wi >= 0, 'AC2 (B7): the log carries WATCH-ERROR basis=stale-reset') or diag($logtext);
        ok($wi >= 0 && $ai > $wi && $gi > $ai,
            'AC2 (B7): the order is stale-reset, then AC-LOSS-DETECTED, then GRACE-START') or diag($logtext);
    }
}

# ===========================================================================
# AC3 -- B8: decide() D0 rows, the "nothing holds" rows, and D1-D4 unchanged
# with battery absent or hold. Every result has battery 0/1 as specified.
# ===========================================================================
{
    my @cases = (
        ['D0: battery release, arms>0' =>
            { battery => 'release', arms => 1, counting => [], fresh_holds => 0, pending => 1 },
            { mode => 'hold', lock => 0, plan_hold => 0, why => 'refresher-hold-tick', battery => 1 }],
        ['D0: battery release, counting>0' =>
            { battery => 'release', arms => 0, counting => ['sandbox-x'], fresh_holds => 0, pending => 1 },
            { mode => 'hold', lock => 0, plan_hold => 0, why => 'refresher-hold-tick', battery => 1 }],
        ['D0: battery release, fresh_holds>0' =>
            { battery => 'release', arms => 0, counting => [], fresh_holds => 1, pending => 1 },
            { mode => 'hold', lock => 0, plan_hold => 0, why => 'refresher-hold-tick', battery => 1 }],
        ['battery release, nothing holding, pending' =>
            { battery => 'release', arms => 0, counting => [], fresh_holds => 0, pending => 1 },
            { mode => 'hold', lock => 0, plan_hold => 0, why => 'refresher-hold-tick', battery => 0 }],
        ['battery release, nothing holding, not pending' =>
            { battery => 'release', arms => 0, counting => [], fresh_holds => 0, pending => 0 },
            { mode => 'idle', lock => 0, plan_hold => 0, why => 'refresher-exit', battery => 0 }],
        ['battery hold, arm -> D1 unchanged' =>
            { battery => 'hold', arms => 1, counting => [], fresh_holds => 0, pending => 1 },
            { mode => 'arm', lock => 1, plan_hold => 1, why => 'refresher-tick', battery => 0 }],
        ['battery absent, arm -> D1 unchanged' =>
            { arms => 1, counting => [], fresh_holds => 0, pending => 1 },
            { mode => 'arm', lock => 1, plan_hold => 1, why => 'refresher-tick', battery => 0 }],
        ['battery absent, counting -> D2 unchanged' =>
            { arms => 0, counting => ['sandbox-x'], fresh_holds => 0, pending => 1 },
            { mode => 'source', lock => 1, plan_hold => 1, why => 'refresher-source-tick', battery => 0 }],
        ['battery hold, nothing -> D4 unchanged' =>
            { battery => 'hold', arms => 0, counting => [], fresh_holds => 0, pending => 0 },
            { mode => 'idle', lock => 0, plan_hold => 0, why => 'refresher-exit', battery => 0 }],
    );
    for my $c (@cases) {
        my ($label, $in, $want) = @$c;
        my $d = HA('decide', $in);
        if (ref $d eq 'HASH') {
            is($d->{mode}, $want->{mode}, "AC3: decide -- $label (mode)") or diag(explain_undef());
            is($d->{lock}, $want->{lock}, "AC3: decide -- $label (lock)");
            is($d->{plan_hold}, $want->{plan_hold}, "AC3: decide -- $label (plan_hold)");
            is($d->{why}, $want->{why}, "AC3: decide -- $label (why)");
            is($d->{battery}, $want->{battery}, "AC3: decide -- $label (battery)") or diag(explain_undef());
        } else {
            fail("AC3: decide -- $label returned a non-HASH");
            diag(explain_undef());
        }
    }
}

# ===========================================================================
# AC4 -- B9 (nothing could hold) plus gather with an arm and ac_probe on
# seeded past-grace/in-grace host state.
# ===========================================================================
{
    # B9: nothing that could hold -> battery hold/not-needed, host-ac absent.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        my $in = HA('gather', $legacy, arms => 0);
        if (ref $in eq 'HASH') {
            is($in->{battery}, 'hold', 'AC4 (B9): gather with nothing that could hold -> battery hold')
                or diag(explain_undef());
            is($in->{battery_basis}, 'not-needed', 'AC4 (B9): ...basis not-needed') or diag(explain_undef());
        } else {
            fail('AC4 (B9): gather returned a non-HASH');
            diag(explain_undef());
        }
        ok(!-e "$root/host-ac", 'AC4 (B9): <root>/host-ac does not exist afterwards');
    }

    # gather with an arm and ac_probe => dc on seeded past-grace state ->
    # battery release / basis expired.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        my $now = time();
        write_host_ac_state($root, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
            dc_since => $now - 400, grace_until => $now - 100 });
        my $in = HA('gather', $legacy, arms => 1, ac_probe => sub { 'dc' }, now => $now);
        if (ref $in eq 'HASH') {
            is($in->{battery}, 'release', 'AC4: gather with arm + past-grace state -> battery release')
                or diag(explain_undef());
            is($in->{battery_basis}, 'expired', 'AC4: ...basis expired') or diag(explain_undef());
        } else {
            fail('AC4: gather returned a non-HASH (past-grace case)');
            diag(explain_undef());
        }
    }

    # gather with an arm and ac_probe on seeded in-grace state -> hold/grace.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        my $now = time();
        write_host_ac_state($root, { v => 1, phase => 'grace', source => 'dc', probed_at => $now - 10,
            dc_since => $now - 50, grace_until => $now + 250 });
        my $in = HA('gather', $legacy, arms => 1, ac_probe => sub { 'dc' }, now => $now);
        if (ref $in eq 'HASH') {
            is($in->{battery}, 'hold', 'AC4: gather with arm + in-grace state -> battery hold')
                or diag(explain_undef());
            is($in->{battery_basis}, 'grace', 'AC4: ...basis grace') or diag(explain_undef());
        } else {
            fail('AC4: gather returned a non-HASH (in-grace case)');
            diag(explain_undef());
        }
    }
}

# ===========================================================================
# AC5 -- DC1. B10: battery past grace, one sandbox entry, one host arm, a
# live helper pid file. max_iterations => 1.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    ok(BpHook::arm('ha-ac5', role => 'manual', by => 'on'), 'AC5 setup: a host arm exists');
    write_registry_entry($root, 'sandbox-ac5', reason => 'busy-lease', until => undef);
    my $now = time();
    write_host_ac_state($root, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
        dc_since => $now - 400, grace_until => $now - 100 });
    BpPowerPlan::write_switch_record($root, $X, 'Power saver');
    open(my $pfh, '>', "$legacy/keepawake.pid") or die $!;
    print {$pfh} "4321\n";
    close $pfh;

    my ($run, $calls) = run_seam3($CW);
    my @seq; # unified ordering of LOG and KILL events
    my @ev_lines;
    my $log_cb = sub { push @seq, ['LOG', $_[0]]; push @ev_lines, [@_] };
    my @kill_rec;
    my $kill_seam = sub { push @seq, ['KILL', @_]; push @kill_rec, [@_] };

    BpContinuityLease::daemon_loop($legacy,
        tick => 1, max_iterations => 1, journal => 0,
        spawn => sub { die "AC5: must not spawn while battery overrides every source\n" },
        powershell_available => sub { 1 },
        kill_pid => $kill_seam, owner_winpid => undef,
        sleep => sub { }, log => $log_cb,
        plan_opts => { run => $run },
    );

    is(log_count(\@ev_lines, 'HOLD-TICK'), 1, 'AC5: exactly one HOLD-TICK is logged') or diag(explain_undef());
    is(log_count(\@ev_lines, 'TICK'), 0, 'AC5: no plain TICK is logged') or diag(explain_undef());
    is(log_count(\@ev_lines, 'SOURCE-TICK'), 0, 'AC5: no SOURCE-TICK is logged') or diag(explain_undef());
    ok(scalar(@kill_rec) >= 1, 'AC5: the kill seam is called at least once (the live helper is stopped)')
        or diag(explain_undef());
    my ($kill_i) = grep { $seq[$_][0] eq 'KILL' } 0 .. $#seq;
    my ($rel_i)  = grep { $seq[$_][0] eq 'LOG' && $seq[$_][1] eq 'RELEASE' } 0 .. $#seq;
    ok(defined $kill_i && defined $rel_i && $kill_i < $rel_i,
        'AC5: the kill seam call is recorded before the RELEASE log event') or diag(explain_undef());
    is((setactive_sequence($calls))[-1] // '', $X, 'AC5: the last /setactive restores plan X') or diag(explain_undef());

    my @jlines = jsonl_lines("$legacy/power-journal.jsonl");
    my @awake_recs = grep { ref $_ eq 'HASH' && ($_->{kind} // '') eq 'awake' }
        map { decode_or_undef($_) } @jlines;
    ok(scalar(@awake_recs) >= 1, 'AC5: the journal gains at least one awake record') or diag(explain_undef());
    if (@awake_recs) {
        my $r = $awake_recs[0];
        is($r->{reason}, 'battery', 'AC5: the awake record reason is battery');
        is($r->{state}, 'released', 'AC5: the awake record state is released');
        is($r->{arms}, 1, 'AC5: the awake record arms is 1');
        ok((grep { /sandbox-ac5/ } @{ $r->{sources} // [] }),
            'AC5: the awake record sources names the sandbox entry');
    }
    my @plan_recs = grep { ref $_ eq 'HASH' && ($_->{kind} // '') eq 'plan' } map { decode_or_undef($_) } @jlines;
    ok((grep { ($_->{override} // '') eq 'battery' } @plan_recs),
        'AC5: the journal gains a plan record with override battery') or diag(explain_undef());

    BpHook::disarm('ha-ac5') if defined &BpHook::disarm;
    ok(-e registry_file($root, 'sandbox-ac5'), 'AC5: the sandbox registry entry still exists (not pruned)');
}

# ===========================================================================
# AC6 -- DC2. B11: the same fixture with max_iterations => 2 and the probe
# file switched to ac inside the sleep seam. Tick 2: TICK, one spawn total,
# /setactive sequence [X, CW], awake states [released, held].
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    ok(BpHook::arm('ha-ac6', role => 'manual', by => 'on'), 'AC6 setup: a host arm exists');
    write_registry_entry($root, 'sandbox-ac6', reason => 'busy-lease', until => undef);
    my $now = time();
    write_host_ac_state($root, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
        dc_since => $now - 400, grace_until => $now - 100 });
    BpPowerPlan::write_switch_record($root, $X, 'Power saver');

    my ($pfh2, $probe_path) = tempfile();
    print {$pfh2} "dc\n";
    close $pfh2;
    local $ENV{CCPRAXIS_AC_PROBE_FILE} = $probe_path;
    local $ENV{CCPRAXIS_AC_TICK_SECONDS} = 0.01;

    my ($run, $calls) = run_seam3($CW);
    my @sp_rec;
    my $spawn_seam = sub { push @sp_rec, [@_]; return 9101 };
    my ($log, $ev) = log_seam();
    my $sleep_seam = sub {
        open(my $wfh, '>', $probe_path) or die $!;
        print {$wfh} "ac\n";
        close $wfh;
    };
    BpContinuityLease::daemon_loop($legacy,
        tick => 1, max_iterations => 2, journal => 0,
        spawn => $spawn_seam, powershell_available => sub { 1 },
        kill_pid => sub { }, owner_winpid => undef,
        sleep => $sleep_seam, log => $log,
        plan_opts => { run => $run },
    );

    is(log_count($ev, 'TICK'), 1, 'AC6: TICK is logged on tick 2 once power is back') or diag(explain_undef());
    is(scalar(@sp_rec), 1, 'AC6: exactly one spawn across both ticks') or diag(explain_undef());
    is_deeply([ (setactive_sequence($calls))[0, -1] ], [ $X, $CW ],
        'AC6: the /setactive sequence starts with X (restored) and ends with CW (re-armed)')
        or diag(explain_undef());

    my @jlines = jsonl_lines("$legacy/power-journal.jsonl");
    my @awake_states = map { $_->{state} } grep { ref $_ eq 'HASH' && ($_->{kind} // '') eq 'awake' }
        map { decode_or_undef($_) } @jlines;
    is_deeply(\@awake_states, [ 'released', 'held' ], 'AC6: the journal awake states are [released, held]')
        or diag(explain_undef());
}

# ===========================================================================
# AC7 -- DC3. B12: within grace: TICK 1, HOLD-TICK 0, spawn 1, last
# /setactive = CW, zero awake records. A second row starts with no state
# file and probe dc, and is likewise held (still armed, not an override).
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    ok(BpHook::arm('ha-ac7', role => 'manual', by => 'on'), 'AC7 setup: a host arm exists');
    my $now = time();
    write_host_ac_state($root, { v => 1, phase => 'grace', source => 'dc', probed_at => $now - 10,
        dc_since => $now - 50, grace_until => $now + 250 });

    my ($pfh3, $probe_path) = tempfile();
    print {$pfh3} "dc\n";
    close $pfh3;
    local $ENV{CCPRAXIS_AC_PROBE_FILE} = $probe_path;
    local $ENV{CCPRAXIS_AC_TICK_SECONDS} = 0.01;

    my ($run, $calls) = run_seam3($BAL);
    my @sp_rec;
    my $spawn_seam = sub { push @sp_rec, [@_]; return 9201 };
    my ($log, $ev) = log_seam();
    BpContinuityLease::daemon_loop($legacy,
        tick => 1, max_iterations => 1, journal => 0,
        spawn => $spawn_seam, powershell_available => sub { 1 },
        kill_pid => sub { }, owner_winpid => undef,
        sleep => sub { }, log => $log,
        plan_opts => { run => $run },
    );
    is(log_count($ev, 'TICK'), 1, 'AC7: within grace, TICK is logged') or diag(explain_undef());
    is(log_count($ev, 'HOLD-TICK'), 0, 'AC7: within grace, no HOLD-TICK is logged') or diag(explain_undef());
    is(scalar(@sp_rec), 1, 'AC7: the helper is still spawned') or diag(explain_undef());
    is((setactive_sequence($calls))[-1] // '', $CW, 'AC7: the plan ends on Continuous work') or diag(explain_undef());
    my @jlines = jsonl_lines("$legacy/power-journal.jsonl");
    my @awake_recs = grep { ref $_ eq 'HASH' && ($_->{kind} // '') eq 'awake' } map { decode_or_undef($_) } @jlines;
    is(scalar(@awake_recs), 0, 'AC7: zero awake records are written while within grace') or diag(explain_undef());
    BpHook::disarm('ha-ac7') if defined &BpHook::disarm;

    # second row: no host-ac state file at all, probe dc -> likewise held
    # (an armed session with no battery override is unaffected by an absent
    # host-ac state -- it defaults to phase ac via the defaults).
    {
        my (undef, $legacy2, $root2) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        ok(BpHook::arm('ha-ac7b', role => 'manual', by => 'on'), 'AC7(2nd row) setup: a host arm exists');
        my ($pfh4, $probe_path2) = tempfile();
        print {$pfh4} "dc\n";
        close $pfh4;
        local $ENV{CCPRAXIS_AC_PROBE_FILE} = $probe_path2;
        local $ENV{CCPRAXIS_AC_TICK_SECONDS} = 0.01;
        my ($run2, $calls2) = run_seam3($BAL);
        my @sp_rec2;
        my ($log2, $ev2) = log_seam();
        BpContinuityLease::daemon_loop($legacy2,
            tick => 1, max_iterations => 1, journal => 0,
            spawn => sub { push @sp_rec2, [@_]; return 9202 }, powershell_available => sub { 1 },
            kill_pid => sub { }, owner_winpid => undef,
            sleep => sub { }, log => $log2,
            plan_opts => { run => $run2 },
        );
        is(log_count($ev2, 'TICK'), 1, 'AC7(2nd row): no host-ac state file, probe dc -- still a plain TICK')
            or diag(explain_undef());
        is((setactive_sequence($calls2))[-1] // '', $CW, 'AC7(2nd row): the plan still ends on Continuous work')
            or diag(explain_undef());
        BpHook::disarm('ha-ac7b') if defined &BpHook::disarm;
    }
}

# ===========================================================================
# AC8 -- B13 through BpPowerPlan::reconcile for why in
# refresher-hold-tick/cli/ac-loss. The old hold file is created by the CLI
# subprocess (as host-awake-actuator.t AC15).
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    ok(BpHook::arm('ha-ac8', role => 'manual', by => 'on'), 'AC8 setup: a host arm exists');
    write_registry_entry($root, 'sandbox-ac8', reason => 'busy-lease', until => undef);
    BpPowerPlan::write_switch_record($root, $X, 'Power saver');

    local %ENV = (%ENV, BUTLER_STATE_DIR => $ENV{BUTLER_STATE_DIR},
        CCPRAXIS_CONTINUITY_ACTIVE_DIR => $legacy, CCPRAXIS_NO_WAKELOCK => 1);
    my $cli = "$BS/bp-power-plan.pl";
    `"$^X" "$cli" reconcile --why cli-hold --hold claude-ac8cli 2>&1`;

    my $now = time();
    write_host_ac_state($root, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
        dc_since => $now - 400, grace_until => $now - 100 });

    for my $why (qw(refresher-hold-tick cli ac-loss)) {
        # Re-seed the switch record each iteration: a successful restore
        # consumes it (record_op => 'remove', package 03 behaviour), so
        # without reseeding only the first iteration would still have a
        # record naming X to restore to.
        BpPowerPlan::write_switch_record($root, $X, 'Power saver');
        my ($run, $calls) = run_seam3($CW);
        my $o = BpPowerPlan::reconcile($legacy, run => $run, why => $why);
        is(ref $o eq 'HASH' ? $o->{armed} : undef, 0,
            "AC8: reconcile(why=$why) with battery past grace counts armed=0 (every source overridden)")
            or diag(explain_undef());
        is((setactive_sequence($calls))[-1] // '', $X,
            "AC8: reconcile(why=$why) restores plan X") or diag(explain_undef());
        my @jlines = jsonl_lines("$legacy/power-journal.jsonl");
        my @plan_recs = grep { ref $_ eq 'HASH' && ($_->{kind} // '') eq 'plan' } map { decode_or_undef($_) } @jlines;
        ok((grep { ($_->{override} // '') eq 'battery' } @plan_recs),
            "AC8: reconcile(why=$why) writes a plan record with override battery") or diag(explain_undef());
    }

    # host state ac: armed 3 (arm, the CLI hold, the registry entry), CW,
    # no override key on the new record.
    write_host_ac_state($root, { v => 1, phase => 'ac', source => 'ac', probed_at => $now });
    my ($run2, $calls2) = run_seam3($BAL);
    my $o2 = BpPowerPlan::reconcile($legacy, run => $run2, why => 'manual');
    is(ref $o2 eq 'HASH' ? $o2->{armed} : undef, 3, 'AC8: host state ac -- armed is 3') or diag(explain_undef());
    is((setactive_sequence($calls2))[-1] // '', $CW, 'AC8: host state ac -- the plan is Continuous work')
        or diag(explain_undef());
    my @jlines2 = jsonl_lines("$legacy/power-journal.jsonl");
    my $last_plan = (reverse grep { ref $_ eq 'HASH' && ($_->{kind} // '') eq 'plan' }
        map { decode_or_undef($_) } @jlines2)[0];
    ok(ref $last_plan eq 'HASH' && !exists $last_plan->{override},
        'AC8: host state ac -- the latest plan record has no override key') or diag(explain_undef());

    `"$^X" "$cli" reconcile --why cli-release --release claude-ac8cli 2>&1`;
    BpHook::disarm('ha-ac8') if defined &BpHook::disarm;
}

# ===========================================================================
# AC9 -- 2.3 shapes: awake_record's exact keys; build_timeline gives kind
# awake for an awake record (not a note) and a plan entry with override only
# when present; the _summary_for strings.
# ===========================================================================
{
    my $now = 1_900_000_000;
    my $rec = PJ('awake_record',
        now => $now, state => 'released', basis => 'expired', phase => 'expired',
        power_source => 'dc', on_battery_since => $now - 400, grace_until => $now - 100,
        arms => 1, sources => ['sandbox-x'], fresh_holds => 0,
    );
    if (ref $rec eq 'HASH') {
        is_deeply([ sort keys %$rec ],
            [ sort qw(v kind ts utc local pid reason state basis phase power_source
                      on_battery_since grace_until arms sources fresh_holds) ],
            'AC9: awake_record has exactly the keys named in 2.3') or diag(explain_undef());
        is($rec->{kind}, 'awake', 'AC9: kind is awake');
        is($rec->{reason}, 'battery', 'AC9: reason is battery');
        is($rec->{state}, 'released', 'AC9: state carried through');
        is($rec->{ts}, $now, 'AC9: ts == int(now)');
        is($rec->{arms}, 1, 'AC9: arms coerced to an integer');
        is_deeply($rec->{sources}, ['sandbox-x'], 'AC9: sources carried through as an array');
    } else {
        fail('AC9: awake_record returned a non-HASH');
        diag(explain_undef());
    }

    # an invalid state value falls back to 'held' (2.3's "else held").
    my $rec_bad = PJ('awake_record', now => $now, state => 'bogus', arms => 0, sources => [], fresh_holds => 0);
    is(ref $rec_bad eq 'HASH' ? $rec_bad->{state} : undef, 'held',
        'AC9: an invalid state value falls back to held') or diag(explain_undef());

    # build_timeline: an awake-kind journal line becomes its own kind=>awake
    # timeline entry, never "unknown kind: awake".
    my $awake_line = { v => 1, kind => 'awake', ts => $now, reason => 'battery', state => 'released',
        basis => 'expired', phase => 'expired', power_source => 'dc', arms => 1, sources => ['sandbox-x'],
        fresh_holds => 0 };
    my $entries = PJ('build_timeline', journal_lines => [ $awake_line ], events => [], transcript => undef,
        since_ms => ($now - 60) * 1000, until_ms => ($now + 60) * 1000);
    if (ref $entries eq 'ARRAY') {
        my @awakes = grep { ($_->{kind} // '') eq 'awake' } @$entries;
        is(scalar(@awakes), 1, 'AC9: build_timeline produces exactly one kind=>awake entry') or diag(explain_undef());
        ok(!(grep { ($_->{kind} // '') eq 'note' && ($_->{note} // '') =~ /awake/ } @$entries),
            'AC9: no "unknown kind: awake" note is produced') or diag(explain_undef());
    } else {
        fail('AC9: build_timeline returned a non-ARRAY for the awake fixture');
        diag(explain_undef());
    }

    # build_timeline: a plan record's override key is copied only when
    # defined.
    my $plan_with = { v => 1, kind => 'plan', ts => $now, why => 'refresher-hold-tick', armed => 0, arm_ids => [],
        found_guid => $CW, found_name => 'Continuous work', wanted_guid => $X, wanted_name => 'Power saver',
        wanted_basis => 'record', action => 'set', result => 'ok', override => 'battery' };
    my $plan_without = { %$plan_with, ts => $now + 1 };
    delete $plan_without->{override};
    my $entries2 = PJ('build_timeline', journal_lines => [ $plan_with, $plan_without ], events => [],
        transcript => undef, since_ms => ($now - 60) * 1000, until_ms => ($now + 60) * 1000);
    if (ref $entries2 eq 'ARRAY') {
        my @plans = grep { ($_->{kind} // '') eq 'plan' } @$entries2;
        my ($with) = grep { ($_->{t_ms} // -1) == $now * 1000 } @plans;
        my ($without) = grep { ($_->{t_ms} // -1) == ($now + 1) * 1000 } @plans;
        is($with->{override} // 'MISSING', 'battery', 'AC9: a plan entry copies override when present') if $with;
        ok(!exists $without->{override}, 'AC9: a plan entry has no override key when absent') if $without;
        fail('AC9: expected two plan timeline entries') unless $with && $without;
    } else {
        fail('AC9: build_timeline returned a non-ARRAY for the plan-override fixture');
        diag(explain_undef());
    }

    my $summary = PJ('_summary_for', { kind => 'awake', reason => 'battery', state => 'released',
        basis => 'expired', arms => 1, sources => ['sandbox-x', 'solo-aaaaaaaa'] });
    is($summary, 'reason=battery state=released basis=expired arms=1 sources=sandbox-x,solo-aaaaaaaa',
        'AC9: _summary_for(awake) renders the exact expected string') or diag(explain_undef());
    my $summary_nosrc = PJ('_summary_for', { kind => 'awake', reason => 'battery', state => 'held',
        basis => 'ac', arms => 0, sources => [] });
    is($summary_nosrc, 'reason=battery state=held basis=ac arms=0 sources=-',
        'AC9: _summary_for(awake) renders sources=- when empty') or diag(explain_undef());

    my $plan_summary = PJ('_summary_for', { kind => 'plan', why => 'refresher-hold-tick', action => 'set',
        result => 'ok', found_guid => $CW, wanted_guid => $X, wanted_basis => 'record', override => 'battery' });
    like($plan_summary // '', qr/\bbasis=record\b.*\boverride=battery\b/,
        'AC9: _summary_for(plan) appends override= right after the basis= part') or diag($plan_summary // '<undef>');
}

# ===========================================================================
# AC10 -- DC4. B14 through monitor_loop with arms/sources/reconcile/out/
# probe seams, tick => 0. Static: BpAcWatch.pm has neither "switched to
# Balanced" nor "already Balanced".
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $data = "$t/data") =~ s{\\}{/}g;
    make_path("$data/.drive-solo");
    open(my $sfh, '>', "$data/.drive-solo/ac-state.json") or die $!;
    print {$sfh} '{"v":1,"phase":"standing-down","source":"dc","probed_at":' . time() . '}';
    close $sfh;

    my $reconcile_calls = 0;
    my @out_lines;
    BpAcWatch::monitor_loop($data,
        probe => sub { 'ac' }, now => sub { time() }, sleep => sub { },
        arms => sub { [] }, sources => sub { [ 'sandbox-ctr', 'solo-abcd1234' ] },
        wakelock_state => sub { 'released' },
        reconcile => sub { $reconcile_calls++; { outcome => 'corrected', wanted_name => 'Power saver' } },
        out => sub { push @out_lines, $_[0] },
        tick => 0,
    );

    my $logtext = slurp("$data/.drive-solo/ac-cycle.log");
    ok(($logtext =~ /STANDDOWN-VERIFY\b.*\bsources=2\b/ && $logtext =~ /source_ids=sandbox-ctr,solo-abcd1234/)
        || ($logtext =~ /sources=2/ && $logtext =~ /source_ids=sandbox-ctr,solo-abcd1234/),
        'AC10: STANDDOWN-VERIFY carries sources=2 and source_ids=sandbox-ctr,solo-abcd1234') or diag($logtext);
    ok((grep { /POWER-PLAN\b.*reason=restored_Power_saver/ } split /\n/, $logtext),
        'AC10: a fake reconcile(outcome corrected, wanted_name Power saver) logs reason=restored_Power_saver')
        or diag($logtext);
    like($out_lines[0] // '', qr/the host may sleep: battery overrides 2 awake source\(s\): sandbox-ctr,solo-abcd1234/,
        'AC10: the out line names the 2 battery-overridden sources') or diag($out_lines[0] // '<none>');

    # with no holders, the out line is byte-identical to today.
    my $t2 = tempdir(CLEANUP => 1);
    (my $data2 = "$t2/data") =~ s{\\}{/}g;
    make_path("$data2/.drive-solo");
    open(my $sfh2, '>', "$data2/.drive-solo/ac-state.json") or die $!;
    print {$sfh2} '{"v":1,"phase":"standing-down","source":"dc","probed_at":' . time() . '}';
    close $sfh2;
    my @out2;
    BpAcWatch::monitor_loop($data2,
        probe => sub { 'ac' }, now => sub { time() }, sleep => sub { },
        arms => sub { [] }, sources => sub { [] }, wakelock_state => sub { 'released' },
        reconcile => sub { { outcome => 'correct' } }, out => sub { push @out2, $_[0] }, tick => 0,
    );
    like($out2[0] // '', qr/the host may sleep;?\s*$/, 'AC10: with no holders the out line is unchanged')
        or diag($out2[0] // '<none>');
    unlike($out2[0] // '', qr/battery overrides/, 'AC10: ...and never mentions "battery overrides"');

    # with one host arm and one source, the line names both and counts 2.
    my $t3 = tempdir(CLEANUP => 1);
    (my $data3 = "$t3/data") =~ s{\\}{/}g;
    make_path("$data3/.drive-solo");
    open(my $sfh3, '>', "$data3/.drive-solo/ac-state.json") or die $!;
    print {$sfh3} '{"v":1,"phase":"standing-down","source":"dc","probed_at":' . time() . '}';
    close $sfh3;
    my @out3;
    BpAcWatch::monitor_loop($data3,
        probe => sub { 'ac' }, now => sub { time() }, sleep => sub { },
        arms => sub { ['abcdef12'] }, sources => sub { ['sandbox-ctr'] }, wakelock_state => sub { 'held' },
        reconcile => sub { { outcome => 'correct' } }, out => sub { push @out3, $_[0] }, tick => 0,
    );
    like($out3[0] // '', qr/battery overrides 2 awake source\(s\): arm:abcdef12,sandbox-ctr/,
        'AC10: an arm id is prefixed arm: and counted alongside a source id') or diag($out3[0] // '<none>');

    my $SRC = slurp("$BS/BpAcWatch.pm");
    unlike($SRC, qr/switched to Balanced/, 'AC10: BpAcWatch.pm no longer contains "switched to Balanced"');
    unlike($SRC, qr/already Balanced/, 'AC10: BpAcWatch.pm no longer contains "already Balanced"');
}

# ===========================================================================
# AC11 -- DC4. B15: BpAcWatch::_default_sources() under a fixture registry
# returns the counting ids; [] with BUTLER_STATE_DIR unset.
# ===========================================================================
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    write_registry_entry($root, 'sandbox-ac11', reason => 'busy-lease', until => undef);
    write_registry_entry($root, 'solo-ac11aaaaaaaa', reason => 'pause-pending', until => time() + 3600);
    my $old = time() - BpAwakeConst::LEASE_FRESH() - 5;
    write_registry_entry($root, 'sandbox-ac11stale', reason => 'active', until => undef,
        written_at => $old, mtime => $old);

    my $ids = AW('_default_sources');
    if (ref $ids eq 'ARRAY') {
        is_deeply([ sort @$ids ], [ sort qw(sandbox-ac11 solo-ac11aaaaaaaa) ],
            'AC11: _default_sources() returns the counting ids, ignoring the stale one') or diag(explain_undef());
    } else {
        fail('AC11: _default_sources() did not return an ARRAY');
        diag(explain_undef());
    }

    delete local $ENV{BUTLER_STATE_DIR};
    my $ids2 = AW('_default_sources');
    is_deeply($ids2, [], 'AC11: _default_sources() returns [] under the .t guard with BUTLER_STATE_DIR unset')
        or diag(explain_undef());
}

# ===========================================================================
# AC12 -- Fail-open and mixed version.
# ===========================================================================
{
    # (a) battery_releases is 0 for a missing state, a garbled state, and an
    # undef root.
    {
        my $t = tempdir(CLEANUP => 1);
        (my $root = "$t/root") =~ s{\\}{/}g;
        is(HA('battery_releases', $root, time()), 0, 'AC12(a): battery_releases is 0 for a missing host-ac state')
            or diag(explain_undef());

        my $p = host_ac_state_path($root);
        (my $dir = $p) =~ s{/[^/]+$}{};
        make_path($dir);
        open(my $fh, '>', $p) or die $!;
        print {$fh} '{not json';
        close $fh;
        is(HA('battery_releases', $root, time()), 0, 'AC12(a): battery_releases is 0 for a garbled host-ac state')
            or diag(explain_undef());

        is(HA('battery_releases', undef, time()), 0, 'AC12(a): battery_releases is 0 for an undef root')
            or diag(explain_undef());
    }

    # (b) a regular file planted at <root>/host-ac: gather returns hold; the
    # daemon tick with an arm still logs TICK (no die).
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        ok(BpHook::arm('ha-ac12b', role => 'manual', by => 'on'), 'AC12(b) setup: a host arm exists');
        open(my $fh, '>', "$root/host-ac") or die $!;
        close $fh;

        my $in = HA('gather', $legacy, arms => 1);
        is(ref $in eq 'HASH' ? $in->{battery} : undef, 'hold',
            'AC12(b): gather with a regular file at <root>/host-ac returns battery hold') or diag(explain_undef());

        my ($run, $calls) = run_seam3($BAL);
        my ($log, $ev) = log_seam();
        my $rc = eval {
            BpContinuityLease::daemon_loop($legacy,
                tick => 1, max_iterations => 1, journal => 0,
                spawn => sub { 9301 }, powershell_available => sub { 1 },
                kill_pid => sub { }, owner_winpid => undef,
                sleep => sub { }, log => $log,
                plan_opts => { run => $run },
            );
            1;
        };
        ok($rc, 'AC12(b): daemon_loop does not die with a regular file at <root>/host-ac') or diag($@);
        is(log_count($ev, 'TICK'), 1, 'AC12(b): the tick still logs TICK despite the planted file')
            or diag(explain_undef());
        BpHook::disarm('ha-ac12b') if defined &BpHook::disarm;
    }

    # (c) HostAwake::battery_releases dies: reconcile counts the arm and
    # keeps CW.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        ok(BpHook::arm('ha-ac12c', role => 'manual', by => 'on'), 'AC12(c) setup: a host arm exists');
        my ($run, $calls) = run_seam3($BAL);
        my $o;
        { no warnings 'redefine';
          local *HostAwake::battery_releases = sub { die "fixture: battery_releases must not break reconcile\n" }
              if $HA_LOADED;
          $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
        }
        is(ref $o eq 'HASH' ? $o->{armed} : undef, 1,
            'AC12(c): a dying HostAwake::battery_releases leaves armed=1 (fail-open)') or diag(explain_undef());
        is((setactive_sequence($calls))[-1] // '', $CW, 'AC12(c): ...and the plan stays Continuous work')
            or diag(explain_undef());
        BpHook::disarm('ha-ac12c') if defined &BpHook::disarm;
    }

    # (d) a HostAwake without battery_step: gather returns hold/error; the
    # tick holds.
    {
        my (undef, $legacy, $root) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        ok(BpHook::arm('ha-ac12d', role => 'manual', by => 'on'), 'AC12(d) setup: a host arm exists');
        write_registry_entry($root, 'sandbox-ac12d', reason => 'busy-lease', until => undef);

        my $in;
        { no warnings 'redefine';
          local *HostAwake::battery_step = sub { die "fixture: battery_step must not break gather\n" }
              if $HA_LOADED;
          $in = HA('gather', $legacy, arms => 1);
        }
        if (ref $in eq 'HASH') {
            is($in->{battery}, 'hold', 'AC12(d): a dying battery_step leaves gather battery=>hold')
                or diag(explain_undef());
            is($in->{battery_basis}, 'error', 'AC12(d): ...basis=>error') or diag(explain_undef());
        } else {
            fail('AC12(d): gather returned a non-HASH');
            diag(explain_undef());
        }

        my ($run, $calls) = run_seam3($BAL);
        my ($log, $ev) = log_seam();
        { no warnings 'redefine';
          local *HostAwake::battery_step = sub { die "fixture: battery_step must not break the tick\n" }
              if $HA_LOADED;
          BpContinuityLease::daemon_loop($legacy,
              tick => 1, max_iterations => 1, journal => 0,
              spawn => sub { 9401 }, powershell_available => sub { 1 },
              kill_pid => sub { }, owner_winpid => undef,
              sleep => sub { }, log => $log,
              plan_opts => { run => $run },
          );
        }
        is(log_count($ev, 'TICK'), 1, 'AC12(d): the tick still logs TICK (arm wins) with battery_step dying')
            or diag(explain_undef());
        BpHook::disarm('ha-ac12d') if defined &BpHook::disarm;
    }
}

# ===========================================================================
# AC13 -- Load safety. HostAwake.pm has no file-scope require/use of
# BpAcWatch or BpPowerJournal (static scan outside sub bodies). KeepAwake::
# load_host_awake on the real tree gives (1, undef). ac-watch.t AC-11's
# forbidden strings are absent from BpAcWatch.pm.
# ===========================================================================
{
    my $src = slurp("$BS/HostAwake.pm");
    ok(length($src), 'AC13 precondition: HostAwake.pm is readable');
    my @lines = split /\n/, $src;
    my $depth = 0;
    my @violations;
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        if ($depth == 0 && $line =~ /^\s*(?:require|use)\b.*\b(BpAcWatch|BpPowerJournal)\b/) {
            push @violations, "line " . ($i + 1) . ": $line";
        }
        my $opens  = () = $line =~ /\{/g;
        my $closes = () = $line =~ /\}/g;
        $depth += $opens - $closes;
        $depth = 0 if $depth < 0;
    }
    is_deeply(\@violations, [],
        'AC13: HostAwake.pm has no file-scope require/use of BpAcWatch or BpPowerJournal')
        or diag(join("\n", @violations));

    (my $SS = "$Bin/../../../sandbox/scripts") =~ s{\\}{/}g;
    unshift @INC, $SS;
    eval { require "$SS/KeepAwake.pm" };
    my ($ok, $why) = SC('KeepAwake', 'load_host_awake', "$BS/HostAwake.pm");
    is($ok, 1, 'AC13: KeepAwake::load_host_awake against the real tree gives ok=1') or diag(explain_undef());
    is($why, undef, 'AC13: ...and no reason') or diag(explain_undef());

    my $awsrc = slurp("$BS/BpAcWatch.pm");
    unlike($awsrc, qr/BpKeepAwake::(?:apply|spawn)|keep-awake\.ps1|SetThreadExecutionState|PowerRequest/,
        'AC13: BpAcWatch.pm still contains no wake-lock actuator call (ac-watch.t AC-11\'s forbidden strings)');
    unlike($awsrc, qr/schtasks|ScheduledTask/i, 'AC13: BpAcWatch.pm still contains no scheduled-task call');
}

# ===========================================================================
# FIX29a -- Decision 29(a): the last-announced battery verdict (and the
# unknown-probe count) live in the host-ac state/registry, not in a
# per-process cache, so a refresher restart or a second process never
# duplicates a "released" record or loses a "held" one, and a failed journal
# append never permanently drops the edge.
# ===========================================================================

# FIX29a-1: a refresher restart mid-outage (two SEPARATE real processes
# observing the same already-released disk state) must journal the released
# edge only ONCE in total, not once per process.
{
    my (undef, $legacy, $root) = fresh_group();
    my $now = time();
    write_host_ac_state($root, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
        dc_since => $now - 400, grace_until => $now - 100 });

    my $code1 = <<"PERL";
use strict; use warnings;
require "$BS/BpAwakeConst.pm";
require "$BS/BpPowerJournal.pm";
require "$BS/BpAcWatch.pm";
require "$BS/HostAwake.pm";
my \$v = HostAwake::battery_step("$legacy", "$root", now => $now, probe => sub { 'dc' });
print "journaled=\$v->{journaled} verdict=\$v->{verdict}\\n";
PERL
    my $out1 = write_pl_and_run($code1, BUTLER_STATE_DIR => undef);
    like($out1, qr/journaled=1\s+verdict=release/,
        'FIX29a-1 setup: subprocess 1 journals the first released edge') or diag($out1);

    my $now2 = $now + 70;
    my $code2 = <<"PERL";
use strict; use warnings;
require "$BS/BpAwakeConst.pm";
require "$BS/BpPowerJournal.pm";
require "$BS/BpAcWatch.pm";
require "$BS/HostAwake.pm";
my \$v = HostAwake::battery_step("$legacy", "$root", now => $now2, probe => sub { 'dc' });
print "journaled=\$v->{journaled} verdict=\$v->{verdict}\\n";
PERL
    my $out2 = write_pl_and_run($code2, BUTLER_STATE_DIR => undef);

    my @jlines = jsonl_lines("$legacy/power-journal.jsonl");
    my @released = grep { ref $_ eq 'HASH' && ($_->{kind} // '') eq 'awake' && ($_->{state} // '') eq 'released' }
        map { decode_or_undef($_) } @jlines;
    is(scalar(@released), 1,
        'FIX29a-1 (Decision 29a): a refresher restart mid-outage (fresh process, same released disk '
        . 'state) journals NO second released record') or diag("out2=$out2\njlines=" . join("\n", @jlines));
}

# FIX29a-2: the daemon idle-exits while released, then AC returns and a
# FRESH process observes it -- the held edge must still be journaled, not
# lost because the new process's cache starts at "hold" too.
{
    my (undef, $legacy, $root) = fresh_group();
    my $now = time();
    write_host_ac_state($root, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
        dc_since => $now - 400, grace_until => $now - 100 });

    my $code1 = <<"PERL";
use strict; use warnings;
require "$BS/BpAwakeConst.pm";
require "$BS/BpPowerJournal.pm";
require "$BS/BpAcWatch.pm";
require "$BS/HostAwake.pm";
my \$v = HostAwake::battery_step("$legacy", "$root", now => $now, probe => sub { 'dc' });
print "journaled=\$v->{journaled} verdict=\$v->{verdict}\\n";
PERL
    write_pl_and_run($code1, BUTLER_STATE_DIR => undef); # process exits here (idle-exit)

    my $now2 = $now + 70;
    my $code2 = <<"PERL";
use strict; use warnings;
require "$BS/BpAwakeConst.pm";
require "$BS/BpPowerJournal.pm";
require "$BS/BpAcWatch.pm";
require "$BS/HostAwake.pm";
my \$v = HostAwake::battery_step("$legacy", "$root", now => $now2, probe => sub { 'ac' });
print "journaled=\$v->{journaled} verdict=\$v->{verdict} phase=\$v->{phase}\\n";
PERL
    my $out2 = write_pl_and_run($code2, BUTLER_STATE_DIR => undef);

    my @jlines = jsonl_lines("$legacy/power-journal.jsonl");
    my @states = map { $_->{state} }
        grep { ref $_ eq 'HASH' && ($_->{kind} // '') eq 'awake' } map { decode_or_undef($_) } @jlines;
    ok((grep { $_ eq 'held' } @states),
        'FIX29a-2 (Decision 29a): AC returning in a FRESH process after an idle-exit during the '
        . 'outage still writes a held record (the edge is not lost)') or diag("out2=$out2\nstates=" . join(',', @states));
}

# FIX29a-3: a failed journal append must leave the announced verdict
# unchanged, so the very next tick retries rather than silently dropping the
# edge forever. In-process (no subprocess needed): the seam here is
# BpPowerJournal::append_record's own open failure, forced by planting a
# DIRECTORY at the journal path so its sysopen() fails outright.
{
    my (undef, $legacy, $root) = fresh_group();
    my $now = time();
    write_host_ac_state($root, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
        dc_since => $now - 400, grace_until => $now - 100 });

    make_path("$legacy/power-journal.jsonl");
    my $v1 = HA('battery_step', $legacy, $root, now => $now, probe => sub { 'dc' });
    is(ref $v1 eq 'HASH' ? $v1->{journaled} : undef, 0,
        'FIX29a-3 setup: the append fails (a directory sits at the journal path) so journaled is 0')
        or diag(explain_undef());

    rmdir "$legacy/power-journal.jsonl" or die "rmdir: $!";
    my $v2 = HA('battery_step', $legacy, $root, now => $now + 1, probe => sub { 'dc' });
    is(ref $v2 eq 'HASH' ? $v2->{journaled} : undef, 1,
        'FIX29a-3 (Decision 29a): a failed journal append leaves the announced verdict unchanged, '
        . 'so the very next tick retries and journals the still-pending released edge')
        or diag(explain_undef());
}

# FIX29a-4: the unknown-probe count must survive a process change -- ten
# CONSECUTIVE unknown readings, split five-and-five across two real
# processes, still trip the fail-open hold on the tenth.
{
    my $t = tempdir(CLEANUP => 1);
    (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
    my $now = time();
    write_host_ac_state($t, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - 60,
        dc_since => $now - 400, grace_until => $now - 100 });

    my $code_a = <<"PERL";
use strict; use warnings;
require "$BS/BpAwakeConst.pm";
require "$BS/BpAcWatch.pm";
for my \$i (1 .. 5) {
    my \$v = BpAcWatch::host_step("$hdir", now => ($now + 60 * \$i), probe => sub { 'unknown' });
    print "call=\$i verdict=\$v->{verdict}\\n";
}
PERL
    my $out_a = write_pl_and_run($code_a, BUTLER_STATE_DIR => undef);
    unlike($out_a, qr/verdict=hold/,
        'FIX29a-4 setup: the first 5 consecutive unknown probes (process A) all stay release') or diag($out_a);

    my $code_b = <<"PERL";
use strict; use warnings;
require "$BS/BpAwakeConst.pm";
require "$BS/BpAcWatch.pm";
for my \$i (6 .. 10) {
    my \$v = BpAcWatch::host_step("$hdir", now => ($now + 60 * \$i), probe => sub { 'unknown' });
    print "call=\$i verdict=\$v->{verdict}\\n";
}
PERL
    my $out_b = write_pl_and_run($code_b, BUTLER_STATE_DIR => undef);
    like($out_b, qr/call=10 verdict=hold/,
        'FIX29a-4 (Decision 29a): the unknown-probe count survives a process change -- the 10th '
        . 'CONSECUTIVE unknown reading, split 5-and-5 across two processes, still trips the fail-open hold')
        or diag("out_a=$out_a\nout_b=$out_b");
}

# ===========================================================================
# FIX29b -- Decision 29(b): a non-interpretable host-ac state (an unknown
# phase, or grace with a null grace_until) is reset to ac by host_step, not
# left disabling the override forever, with exactly one log line.
# Probe 'unknown' isolates the reset itself from any further observe()
# transition: from phase ac, an unknown reading is a no-op either way.
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
    my $now = time();
    write_host_ac_state($t, { v => 1, phase => 'paused', source => 'dc', probed_at => $now - 10 });

    my $v = AW('host_step', $hdir, now => $now, probe => sub { 'unknown' });
    is(ref $v eq 'HASH' ? $v->{phase} : undef, 'ac',
        'FIX29b(A) (Decision 29b): an unrecognised phase is reset to ac by host_step, not left stuck')
        or diag(explain_undef());
    my $logtext = slurp("$hdir/.drive-solo/ac-cycle.log");
    my @lines = grep { length } split /\n/, $logtext;
    is(scalar(@lines), 1, 'FIX29b(A): exactly one log line records the reset') or diag($logtext);
}
{
    my $t = tempdir(CLEANUP => 1);
    (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
    my $now = time();
    write_host_ac_state($t, { v => 1, phase => 'grace', source => 'dc', probed_at => $now - 10,
        dc_since => $now - 50, grace_until => undef });

    my $v = AW('host_step', $hdir, now => $now, probe => sub { 'unknown' });
    is(ref $v eq 'HASH' ? $v->{phase} : undef, 'ac',
        'FIX29b(B) (Decision 29b): grace with grace_until null is reset to ac by host_step, not left '
        . 'extending grace forever') or diag(explain_undef());
    my $logtext = slurp("$hdir/.drive-solo/ac-cycle.log");
    my @lines = grep { length } split /\n/, $logtext;
    is(scalar(@lines), 1, 'FIX29b(B): exactly one log line records the reset') or diag($logtext);
}

# ===========================================================================
# FIX29c -- Decision 29(c): the stale-reset/transition log line is written
# only when the state write actually succeeded. The seam is a direct
# override of BpAcWatch::_write_state (the same local-glob idiom AC12(c)/(d)
# already use on HostAwake's subs), unconditionally failing it -- the
# cleanest stand-in for "an unwritable state path" on a host where chmod and
# rename-over-read-only do not reliably fail.
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $hdir = "$t/host-ac") =~ s{\\}{/}g;
    my $now = time();
    my $stale = BpAwakeConst::AC_STALE();
    write_host_ac_state($t, { v => 1, phase => 'expired', source => 'dc', probed_at => $now - $stale - 5,
        dc_since => $now - $stale - 300, grace_until => $now - $stale - 1 });

    { no warnings 'redefine';
      local *BpAcWatch::_write_state = sub { return 0 };
      for my $i (1 .. 3) {
          AW('host_step', $hdir, now => $now + 60 * $i, probe => sub { 'unknown' });
      }
    }
    my $logtext = slurp("$hdir/.drive-solo/ac-cycle.log");
    my $count = () = ($logtext =~ /basis=stale-reset/g);
    is($count, 0,
        'FIX29c (Decision 29c): with an unwritable state path, the stale-reset log line is NOT '
        . 'written on every tick (it is logged only after _write_state actually succeeds)')
        or diag($logtext);
}

# ===========================================================================
# FIX30 -- Decision 30: HostAwake::publish refuses to write to the default
# state root under CCPRAXIS_NO_WAKELOCK, in addition to the existing
# direct-.t guard, so a subprocess spawned by a test harness (whose own $0
# is never a .t) cannot leak a registry entry into a real HOME.
# ===========================================================================
{
    my $decoy = tempdir(CLEANUP => 1);
    (my $decoy_home = $decoy) =~ s{\\}{/}g;
    my $target = "$decoy_home/.claude/butler-state/continuity/awake-sources";

    my $code = <<"PERL";
use strict; use warnings;
require "$BS/BpAwakeConst.pm";
require "$BS/HostAwake.pm";
my \$rc = HostAwake::publish('sandbox-fix30', { awake => 1, reason => 'active' });
print "publish=\$rc\\n";
PERL

    my $out1 = write_pl_and_run($code,
        HOME => $decoy_home, USERPROFILE => $decoy_home,
        CCPRAXIS_NO_WAKELOCK => 1, BUTLER_STATE_DIR => undef);
    like($out1, qr/publish=0/,
        'FIX30 (Decision 30): HostAwake::publish returns 0 under CCPRAXIS_NO_WAKELOCK with no explicit '
        . 'root and no BUTLER_STATE_DIR, even though $0 (a scratch .pl) is not a .t') or diag($out1);
    ok(!(dir_entries($target)),
        "FIX30: ...and writes nothing into the decoy's awake-sources dir ($target)")
        or diag('entries: ' . join(',', dir_entries($target)));

    my $out2 = write_pl_and_run($code,
        HOME => $decoy_home, USERPROFILE => $decoy_home,
        CCPRAXIS_NO_WAKELOCK => undef, BUTLER_STATE_DIR => undef);
    like($out2, qr/publish=1/,
        'FIX30: ...and WITHOUT CCPRAXIS_NO_WAKELOCK (same decoy), the same call does publish') or diag($out2);
    ok(-f "$target/sandbox-fix30.json",
        'FIX30: ...writing the entry file into the decoy path this time') or diag($out2);
}

done_testing();
