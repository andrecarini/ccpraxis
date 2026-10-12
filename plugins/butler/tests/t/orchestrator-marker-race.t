#!/usr/bin/env perl
# platform: any
# Package 12 (orchestrator-liveness-false-dead), specs/12-orchestrator-liveness-false-dead-spec.md.
#
# Covers DC1, DC2, DC4, DC6 (section 4, File A) for almanac bug 20261002-135309-f98d
# (TOCTOU false-dead): BpOrch::acquire_marker truncates the marker BEFORE taking its
# flock, so a losing second start can wipe a still-running first orchestrator's pid;
# BpLifecycle::reconcile_one then judges liveness by pid alone and unlinks a marker
# whose flock is still genuinely held.
#
# WRITTEN AGAINST SPEC ONLY -- bp-orchestrator.pl's acquire_marker still truncates
# before flock, and bp-lifecycle.pl has no marker_probe sub and no marker_lock field
# at the time this file is written. Every assertion is expected to fail against an
# absence/wrong-shape of implementation, never against a Perl exception in THIS file
# -- risky calls to not-yet-existing subs are wrapped in eval so "Undefined
# subroutine" is a caught, reported failure for THAT assertion only.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Fcntl qw(:flock);

# ---------------------------------------------------------------------------
# AC-12 seam: install the CORE::GLOBAL::flock override BEFORE requiring the
# two scripts under test, so the override is visible at their compile time
# (a named-builtin override only takes effect for callers compiled AFTER it
# is installed). $HOOK is undef by default, so every OTHER AC in this file
# (which never sets it) passes every flock call straight through unchanged.
# ---------------------------------------------------------------------------
our $HOOK;
BEGIN {
    *CORE::GLOBAL::flock = sub (*$) {
        my ($fh, $op) = @_;
        $HOOK->($fh, $op) if $HOOK;
        return CORE::flock($fh, $op);
    };
}

# Env pinning (spec section 4) -- BEFORE requiring anything that might touch HOME.
my $ENV_TMP = tempdir(CLEANUP => 1);
$ENV{HOME}               = $ENV_TMP;
$ENV{USERPROFILE}        = $ENV_TMP;
$ENV{ALMANAC_HOME}       = $ENV_TMP;
$ENV{CLAUDE_CONFIG_DIR}  = $ENV_TMP;
$ENV{BUTLER_STATE_DIR}   = $ENV_TMP;
$ENV{CCPRAXIS_DATA_DIR}  = $ENV_TMP;
$ENV{CLAUDE_PROJECT_DIR} = $ENV_TMP;

(my $DIR = dirname(abs_path(do { (my $f = __FILE__) =~ s{\\}{/}g; $f }))) =~ s{\\}{/}g;
my $SCRIPTS    = "$DIR/../../scripts";
my $ORCH       = "$SCRIPTS/bp-orchestrator.pl";
my $LIFECYCLE  = "$SCRIPTS/bp-lifecycle.pl";
my $SL_PM      = "$DIR/../../../almanac/scripts/Almanac/SessionLive.pm";

ok(-f $ORCH,      'precondition: bp-orchestrator.pl exists') or BAIL_OUT('nothing to test');
ok(-f $LIFECYCLE, 'precondition: bp-lifecycle.pl exists')    or BAIL_OUT('nothing to test');
ok(-f $SL_PM,     'precondition: Almanac/SessionLive.pm exists') or BAIL_OUT('nothing to test');

require $ORCH;        # package BpOrch
require $LIFECYCLE;   # package BpLifecycle
{
    no warnings 'once';
    require $SL_PM;   # package Almanac::SessionLive
}

# --------------------------------------------------------------- fixtures ---

sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub blueprint_md {
    my (%o) = @_;
    my $status = $o{status} // 'running';
    my $rows   = '';
    for my $p (@{ $o{packages} || [] }) {
        $rows .= "| $p->{pkg} | thing | — | sonnet | $p->{table} |\n";
    }
    return <<"MD";
# Test Blueprint

```
blueprint: $o{name}
created: 2026-01-01
last_updated: 2026-01-01T00:00Z
status: $status        # drafting | audited | running | done | archived
```

## Objective

Test fixture.

## Package status

| pkg | deliverable | depends_on | model | status |
|-----|-------------|------------|-------|--------|
$rows
## Harvest log

## Incidents

MD
}

sub ledger_md {
    my (%o) = @_;
    return <<"MD";
---
package: $o{pkg}
blueprint: $o{blueprint}
status: $o{status}
last_updated: 2026-01-01T00:00Z
---

# Package $o{pkg}

## Next action

None.
MD
}

# Builds $root/.ccpraxis-local-data/blueprints/fx/{blueprint.md, packages/01-a.md
# (status done), runs/} -- the layout spec section 4 File A names, under a root
# meant to be passed to bp-lifecycle.pl as --data-dir "$root/.ccpraxis-local-data".
sub make_fixture {
    my ($root) = @_;
    my $dir = "$root/.ccpraxis-local-data/blueprints/fx";
    make_path("$dir/packages");
    write_file("$dir/blueprint.md", blueprint_md(name => 'fx', status => 'running',
        packages => [ { pkg => '01-a', table => 'done' } ]));
    write_file("$dir/packages/01-a.md", ledger_md(pkg => '01-a', blueprint => 'fx', status => 'done'));
    make_path("$dir/runs");
    return $dir;
}

# Reconcile runs as a SUBPROCESS, stdout captured through a real temp file
# (never an in-memory handle -- Git-for-Windows perl fails that, project
# CLAUDE.md). Always adds --json.
sub run_lifecycle {
    my (@args) = @_;
    my ($tfh, $tmp) = File::Temp::tempfile();
    close $tfh;
    open(my $saved, '>&', \*STDOUT) or die "dup: $!";
    open(STDOUT, '>', $tmp) or die "redirect: $!";
    my $rc = system($^X, $LIFECYCLE, @args, '--json');
    open(STDOUT, '>&', $saved);
    close $saved;
    my $out = slurp($tmp) // '';
    unlink $tmp;
    require JSON::PP;
    my $data = eval { JSON::PP->new->decode($out) };
    $data = [ {} ] unless ref($data) eq 'ARRAY';
    return ($rc >> 8, $data, $out);
}

# =============================================================================
# AC-1, AC-2, AC-4 (+AC-11), AC-5, AC-6, AC-7, AC-8 -- one continuous flow on
# the SAME marker, exactly as spec section 4 File A chains them ("$A still
# held", "from AC-1/2 setup", "After AC-4's sequence").
# =============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_fixture($root);
    my $mk   = "$dir/runs/.orchestrator";
    my $data_dir = "$root/.ccpraxis-local-data";

    # --- AC-1 ---------------------------------------------------------------
    my $A = BpOrch::acquire_marker($mk);
    ok(defined $A, 'AC-1: first acquire_marker returns a defined handle');
    is(slurp($mk), "$$\n", 'AC-1: marker content is "$$\\n" after the first acquire');

    my $second = BpOrch::acquire_marker($mk);   # second OFD, same process
    ok(!defined $second, 'AC-1: a second acquire_marker (same process, second OFD) returns undef (loses the flock)');
    is(slurp($mk), "$$\n",
        'AC-1: FAILS ON CURRENT CODE -- the losing acquire must not truncate the still-held marker (content stays "$$\\n", not "")');

    # --- AC-2: a REAL child perl process, deterministic because $A holds throughout ---
    my ($cfh, $child_script) = File::Temp::tempfile(SUFFIX => '.pl');
    (my $orch_for_child = $ORCH) =~ s{\\}{/}g;
    print {$cfh} <<"CHILD";
use strict; use warnings;
require "$orch_for_child";
exit(defined BpOrch::acquire_marker(\$ARGV[0]) ? 0 : 3);
CHILD
    close $cfh;
    my $child_rc = system($^X, $child_script, $mk);
    unlink $child_script;
    is($child_rc >> 8, 3, 'AC-2: a child process losing the flock exits 3 (acquire_marker returned undef)');
    is(slurp($mk), "$$\n", 'AC-2: marker content is still "$$\\n" after the losing child process');

    # --- AC-4: the f98d sequence end to end -- subprocess reconcile while $A holds ---
    my ($rc4, $data4) = run_lifecycle('reconcile', '--blueprint', 'fx',
        '--data-dir', $data_dir, '--no-archive');
    ok(-e $mk, 'AC-4: marker still exists after reconcile (f98d sequence)');
    is(slurp($mk), "$$\n", 'AC-4: marker content is still "$$\\n" after reconcile');
    is($data4->[0]{live}, 1, 'AC-4: JSON reports live == 1');
    is($data4->[0]{marker_lock}, 'held', 'AC-4: JSON reports marker_lock eq "held"');
    ok(!(grep { $_->{kind} eq 'stale_marker' } @{ $data4->[0]{actions} || [] }),
        'AC-4: no action of kind stale_marker');
    is(eval { Almanac::SessionLive::orchestrator_live(root => $root, blueprint => 'fx') }, 1,
        'AC-4: Almanac::SessionLive::orchestrator_live(root,blueprint) == 1') or diag("err: $@");

    # --- AC-11: inherited sweep behavior -- reconcile never unlinks/truncates a live marker ---
    is(eval { BpOrch::orchestrator_marker_live("$dir/runs") }, 1,
        'AC-11: BpOrch::orchestrator_marker_live("$bpdir/runs") == 1 after AC-4\'s sequence') or diag("err: $@");

    # --- AC-5: pid-less locked marker (DC2 in isolation) -- $A still held throughout ---
    for my $variant ( ['empty', ''], ['zero-pid', "4194304\n"], ['garbage', 'garbage'] ) {
        my ($label, $content) = @$variant;
        write_file($mk, $content);   # overwrite via a SEPARATE handle; $A's lock is untouched
        my ($rc5, $data5) = run_lifecycle('reconcile', '--blueprint', 'fx',
            '--data-dir', $data_dir, '--no-archive');
        ok(-e $mk, "AC-5 ($label): marker still exists after reconcile");
        is($data5->[0]{live}, 1, "AC-5 ($label): JSON reports live == 1");
        is($data5->[0]{marker_lock}, 'held', "AC-5 ($label): JSON reports marker_lock eq \"held\"");
        ok(!(grep { $_->{kind} eq 'stale_marker' } @{ $data5->[0]{actions} || [] }),
            "AC-5 ($label): no action of kind stale_marker -- FAILS ON CURRENT CODE (unlinked)");
    }

    # --- AC-6: release $A (no unlink), leave a crashed-run marker behind ---
    flock($A, LOCK_UN);
    close $A;
    write_file($mk, "4194304\n");   # a pid that cannot be alive (above Linux pid_max)
    my ($rc6, $data6) = run_lifecycle('reconcile', '--blueprint', 'fx',
        '--data-dir', $data_dir, '--no-archive');
    ok(!-e $mk, 'AC-6: an unlocked dead-pid marker IS removed');
    ok((grep { $_->{kind} eq 'stale_marker' && $_->{applied} } @{ $data6->[0]{actions} || [] }),
        'AC-6: a stale_marker action with applied == 1 is reported');
    is($data6->[0]{marker_lock}, 'free', 'AC-6: marker_lock eq "free"');
    is($data6->[0]{live}, 0, 'AC-6: live == 0');

    # --- AC-7: unlocked marker holding a live pid is kept ---
    write_file($mk, "$$\n");   # our own pid is alive
    my ($rc7, $data7) = run_lifecycle('reconcile', '--blueprint', 'fx',
        '--data-dir', $data_dir, '--no-archive');
    ok(-e $mk, 'AC-7: a live-pid unlocked marker is kept');
    is($data7->[0]{live}, 1, 'AC-7: live == 1');
    is($data7->[0]{marker_lock}, 'free', 'AC-7: marker_lock eq "free"');

    # --- AC-8: --dry-run on an unlocked dead-pid marker leaves no lock behind ---
    write_file($mk, "4194304\n");
    my ($rc8, $data8) = run_lifecycle('reconcile', '--blueprint', 'fx',
        '--data-dir', $data_dir, '--no-archive', '--dry-run');
    ok(-e $mk, 'AC-8: --dry-run keeps the marker');
    ok((grep { $_->{kind} eq 'stale_marker' && !$_->{applied} } @{ $data8->[0]{actions} || [] }),
        'AC-8: a stale_marker action with applied == 0 is reported');
    my $post_dry = BpOrch::acquire_marker($mk);
    ok(defined $post_dry, 'AC-8: acquire_marker succeeds afterward -- --dry-run left no lock behind');
    flock($post_dry, LOCK_UN) if $post_dry;
    close $post_dry if $post_dry;
}

# =============================================================================
# AC-3 -- a separate fixture: a pre-existing UNLOCKED marker with junk content.
# =============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_fixture($root);
    my $mk   = "$dir/runs/.orchestrator";
    write_file($mk, "4194304\nJUNK\n");

    my $h = BpOrch::acquire_marker($mk);
    ok(defined $h, 'AC-3: acquire_marker on a pre-existing unlocked marker of junk content returns a handle');
    is(slurp($mk), "$$\n", 'AC-3: content is exactly "$$\\n" afterward');
    flock($h, LOCK_UN) if $h;
    close $h if $h;
}

# =============================================================================
# AC-9 -- marker_probe unit (BpLifecycle::marker_probe), in-process.
# =============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_fixture($root);
    my $mk   = "$dir/runs/.orchestrator";   # does not exist yet

    my ($state_absent, $err_absent) = eval { BpLifecycle::marker_probe($mk) };
    is($state_absent, 'absent', 'AC-9: marker_probe on an absent path gives "absent"') or diag("err: $@");

    write_file($mk, "1\n");
    my ($state_free) = eval { BpLifecycle::marker_probe($mk) };
    is($state_free, 'free', 'AC-9: marker_probe on an unlocked file gives "free"') or diag("err: $@");
    {
        open(my $t1, '+<', $mk) or die "open: $!";
        ok(flock($t1, LOCK_EX | LOCK_NB), 'AC-9: after a "free" probe, a fresh EX lock succeeds -- the probe held nothing');
        flock($t1, LOCK_UN);
        close $t1;
    }

    open(my $holder, '+<', $mk) or die "open: $!";
    flock($holder, LOCK_EX) or die "flock: $!";
    my ($state_held) = eval { BpLifecycle::marker_probe($mk) };
    is($state_held, 'held', 'AC-9: marker_probe with another OFD holding EX gives "held"') or diag("err: $@");
    flock($holder, LOCK_UN);
    close $holder;
    {
        open(my $t2, '+<', $mk) or die "open: $!";
        ok(flock($t2, LOCK_EX | LOCK_NB), 'AC-9: after the holder releases, a fresh EX lock succeeds -- the probe held nothing');
        flock($t2, LOCK_UN);
        close $t2;
    }
}

# =============================================================================
# AC-10 -- error path (in-process): marker_probe forced to 'error' must not
# unlink the marker or clear a terminal package's registry pid.
# =============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_fixture($root);
    my $mk   = "$dir/runs/.orchestrator";
    write_file($mk, "4194304\n");   # unlocked, dead pid
    require JSON::PP;
    write_file("$dir/runs/registry.json",
        JSON::PP->new->canonical->pretty->encode({ packages => { '01-a' => { status => 'done', pid => 99999 } } }));

    no warnings 'once', 'redefine';
    local *BpLifecycle::marker_probe = sub { return ('error', 'flock: simulated') };
    my $r = eval { BpLifecycle::reconcile_one($dir, {}) };
    ok(defined $r, 'AC-10: reconcile_one returns a result hash') or diag("died: $@");
  SKIP: {
        skip 'AC-10: reconcile_one died', 8 unless defined $r;
        ok(-e $mk, 'AC-10: marker still exists (an error probe must never unlink)');
        is($r->{marker_lock}, 'error', 'AC-10: marker_lock eq "error"');
        is($r->{live}, 0, 'AC-10: live == 0');
        my @skipped = grep { $_->{kind} eq 'skipped' } @{ $r->{actions} || [] };
        is(scalar(@skipped), 1, 'AC-10: exactly one skipped action');
        ok(scalar(@{ $r->{errors} || [] }) > 0, 'AC-10: errors is non-empty');
        my $reg = JSON::PP->new->decode(slurp("$dir/runs/registry.json") // '{}');
        ok(exists $reg->{packages}{'01-a'}{pid},
            'AC-10: the TERMINAL package\'s registry pid is still present (not cleared) -- FAILS ON CURRENT CODE');
        ok(!(grep { $_->{kind} eq 'stale_marker' } @{ $r->{actions} || [] }),
            'AC-10: no stale_marker action -- FAILS ON CURRENT CODE');
        ok(!(grep { $_->{kind} eq 'stale_pid' } @{ $r->{actions} || [] }),
            'AC-10: no stale_pid action -- FAILS ON CURRENT CODE');
    }
}

# =============================================================================
# AC-12 -- interleaving seams via CORE::GLOBAL::flock.
# =============================================================================
{
    # --- (a) acquire-side: a racer unlinks the marker between sysopen and flock ---
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_fixture($root);
    my $mk   = "$dir/runs/.orchestrator";

    my $acquire_hook_calls = 0;
    local $HOOK = sub {
        my ($fh, $op) = @_;
        $acquire_hook_calls++;
        unlink $mk if $acquire_hook_calls == 1;
    };
    my $result = eval { BpOrch::acquire_marker($mk) };
    local $HOOK = undef;

  SKIP: {
        skip 'AC-12a: CORE::GLOBAL::flock override had no observable effect on this perl', 3
            unless $acquire_hook_calls > 0;
        ok(defined $result, 'AC-12a: acquire_marker still returns a defined handle despite the mid-flight unlink')
            or diag("err: $@");
      SKIP: {
            skip 'AC-12a: acquire_marker died or returned undef', 2 unless defined $result;
            my @fh_stat   = stat($result);
            my @path_stat = stat($mk);
            is_deeply([ @path_stat[0,1] ], [ @fh_stat[0,1] ],
                'AC-12a: the path\'s (dev,ino) equals the held handle\'s (dev,ino) -- FAILS ON CURRENT CODE (no verify-after-flock retry)');
            is(slurp($mk), "$$\n", 'AC-12a: marker content is "$$\\n"');
            flock($result, LOCK_UN);
            close $result;
        }
    }
}
{
    # --- (b) removal-side: a racer takes LOCK_EX on the marker right as the
    # removal step tries to take it. ---
    my $root = tempdir(CLEANUP => 1);
    my $dir  = make_fixture($root);
    my $mk   = "$dir/runs/.orchestrator";
    write_file($mk, "4194304\n");   # unlocked, dead pid

    my $removal_hook_calls = 0;
    my $racer_fh;
    local $HOOK = sub {
        my ($fh, $op) = @_;
        return unless (caller(1))[0] eq 'BpLifecycle';
        return unless $op & LOCK_EX;
        $removal_hook_calls++;
        if ($removal_hook_calls == 1) {
            open($racer_fh, '+<', $mk) or die "racer open: $!";
            CORE::flock($racer_fh, LOCK_EX) or die "racer flock: $!";
        }
    };
    my $r = eval { BpLifecycle::reconcile_one($dir, {}) };
    local $HOOK = undef;
    flock($racer_fh, LOCK_UN) if $racer_fh;
    close $racer_fh if $racer_fh;

  SKIP: {
        skip 'AC-12b: CORE::GLOBAL::flock override had no observable effect on this perl (also expected pre-implementation, since current reconcile_one never calls flock at all)', 4
            unless $removal_hook_calls > 0;
        ok(defined $r, 'AC-12b: reconcile_one returns a result hash') or diag("died: $@");
      SKIP: {
            skip 'AC-12b: reconcile_one died', 3 unless defined $r;
            ok(-e $mk, 'AC-12b: marker still exists (the racer\'s EX wins, removal refuses)');
            is($r->{live}, 1, 'AC-12b: live == 1');
            is($r->{marker_lock}, 'held', 'AC-12b: marker_lock eq "held"');
        }
    }
}

done_testing();
