#!/usr/bin/env perl
# platform: any
# The power plan follows a SANDBOXED run too (Decision 14).
#
# Bug report 20261031-225231-6764: on 2026-10-31 the acxpraxis fleet ran in its sandbox, its
# launcher held the wake-lock, and the plan stayed Balanced. reconcile() counted only
# BpContinuityLease::live_arms on the host, and a sandboxed run arms inside its container, which
# the host never reads. Decision 14 says the plan is Continuous work while "at least one run [is]
# armed (whatever the wake-lock lease counts as active)".
#
# The launcher now records a hold with `bp-power-plan reconcile --hold <container>` on every
# wake-lock tick and removes it with `--release`; reconcile counts fresh holds as arms.
#
# AC1  set_sandbox_hold / sandbox_holds: on, off, stale after the window, bad names refused
# AC2  reconcile with no host arm but a fresh hold wants Continuous work; a stale one releases:
#      with no switch record and no migration marker, Decision 9 restores Balanced once
# AC3  the CLI's --hold / --release write and remove the hold, and reject bad usage
# AC4  the launcher calls it on hold, release, refresh and exit
#
# powercfg is never run: reconcile gets an in-process `run` seam, and the CLI runs under
# CCPRAXIS_NO_WAKELOCK, where powercfg_argv refuses.
#
# Decision 4 (wake-and-pause-consolidation): reconcile undoes only its own switch, so "nothing
# held means Balanced" no longer holds; Decision 9: record-less Continuous work is restored to
# Balanced once (package 03-plan-restores-prior). The AC2 second block below was edited to cite
# this.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";
require "$S/BpPowerPlan.pm";

my $BAL = '381b4222-f694-41f0-9685-ff5bb260df2e';
my $CW  = '54a34db5-af62-4d8a-ba50-af7155ee895a';

sub fresh_group {
    my $t = tempdir(CLEANUP => 1);
    (my $home = "$t/home") =~ s{\\}{/}g;
    (my $legacy = "$t/legacy") =~ s{\\}{/}g;
    make_path($home, $legacy);
    $ENV{BUTLER_STATE_DIR} = $home;
    $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
    return ($home, $legacy, BpContinuityLease::store_root_for($legacy));
}
sub ok_result { return { status => 'ok', rc => 0, out => $_[0], ms => 1 } }
sub run_seam {
    my ($active) = @_;
    my @calls;
    my $fn = sub {
        push @calls, [@_];
        return ok_result("Power Scheme GUID: $active  (x)\r\n") if $_[0] eq '/getactivescheme';
        return ok_result("\r\nExisting Power Schemes (* Active)\r\n---\r\n"
            . "Power Scheme GUID: $BAL  (Balanced)\r\nPower Scheme GUID: $CW  (Continuous work)\r\n") if $_[0] eq '/list';
        return ok_result('');
    };
    return ($fn, \@calls);
}
sub setactive_to { my ($calls) = @_; my @s = grep { $_->[0] eq '/setactive' } @$calls; return @s ? $s[-1][1] : undef }

# --- AC1 ---------------------------------------------------------------------------------------------
{
    my (undef, undef, $root) = fresh_group();
    ok(defined $root && length $root, 'precondition: a store root');
    is_deeply(BpPowerPlan::sandbox_holds($root), [], 'no holds at first');
    ok(BpPowerPlan::set_sandbox_hold($root, 'claude-acx-20f6a746', 1), 'a hold is recorded');
    is_deeply(BpPowerPlan::sandbox_holds($root), ['claude-acx-20f6a746'], 'and counted');
    my $f = BpPowerPlan::sandbox_hold_dir($root) . '/claude-acx-20f6a746';
    my $old = time() - $BpPowerPlan::SANDBOX_HOLD_FRESH_SECONDS - 5;
    utime($old, $old, $f);
    is_deeply(BpPowerPlan::sandbox_holds($root), [], 'a hold older than the window no longer counts (a dead launcher)');
    ok(BpPowerPlan::set_sandbox_hold($root, 'claude-acx-20f6a746', 1), 'a refresh touches it again');
    is_deeply(BpPowerPlan::sandbox_holds($root), ['claude-acx-20f6a746'], 'and it counts again');
    ok(BpPowerPlan::set_sandbox_hold($root, 'claude-acx-20f6a746', 0), 'a release removes it');
    ok(!-e $f, 'the file is gone');
    for my $bad ('../x', 'a/b', '', '.hidden', 'x' x 200) {
        ok(!BpPowerPlan::set_sandbox_hold($root, $bad, 1), "a bad hold name is refused: '" . substr($bad, 0, 12) . "'");
    }
}

# --- AC2 ---------------------------------------------------------------------------------------------
{
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    BpPowerPlan::set_sandbox_hold($root, 'claude-acx-20f6a746', 1);
    my ($run, $calls) = run_seam($BAL);
    my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'sandbox-hold');
    is(ref $o, 'HASH', 'reconcile answers');
    is($o->{armed}, 1, 'THE BUG: a fresh sandbox hold counts as an arm');
    is_deeply($o->{arm_ids}, ['sandbox:claude-acx-20f6a746'], 'named as a sandbox hold');
    is(setactive_to($calls), $CW, 'and the plan is switched to Continuous work');
}
{
    # Decision 4 (wake-and-pause-consolidation): reconcile undoes only its own switch, so
    # "nothing held means Balanced" no longer holds; Decision 9: record-less Continuous work is
    # restored to Balanced once. This seam names every plan "(x)" (see run_seam above), so CW is
    # recognised by the stored guid, which is exactly the is_cw guid clause -- with no switch
    # record and no migration marker, this is a record-less migration, not a name/stock match.
    my (undef, $legacy, $root) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    BpPowerPlan::set_sandbox_hold($root, 'claude-acx-20f6a746', 1);
    my $f = BpPowerPlan::sandbox_hold_dir($root) . '/claude-acx-20f6a746';
    my $old = time() - $BpPowerPlan::SANDBOX_HOLD_FRESH_SECONDS - 5;
    utime($old, $old, $f);
    my ($run, $calls) = run_seam($CW);
    my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is($o->{armed}, 0, 'a stale hold does not count');
    is(setactive_to($calls), $BAL,
        'so the plan goes back to Balanced (Decision 9: no switch record, no migration marker)');
}
{
    my (undef, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    my ($run, $calls) = run_seam($BAL);
    my $o = BpPowerPlan::reconcile($legacy, run => $run, why => 'manual');
    is($o->{armed}, 0, 'no hold and no arm: nothing armed (unchanged)');
    is(setactive_to($calls), undef, 'already Balanced: no switch');
}

# --- AC3 ---------------------------------------------------------------------------------------------
{
    my ($home, $legacy, $root) = fresh_group();
    local %ENV = (%ENV, BUTLER_STATE_DIR => $home, CCPRAXIS_CONTINUITY_ACTIVE_DIR => $legacy, CCPRAXIS_NO_WAKELOCK => 1);
    my $cli = "$S/bp-power-plan.pl";
    my $f = BpPowerPlan::sandbox_hold_dir($root) . '/claude-acx-20f6a746';
    my $out = `"$^X" "$cli" reconcile --why sandbox-hold --hold claude-acx-20f6a746 2>&1`;
    is($? >> 8, 0, 'CLI --hold exits 0') or diag($out);
    ok(-e $f, 'CLI --hold records the hold');
    $out = `"$^X" "$cli" reconcile --why sandbox-release --release claude-acx-20f6a746 2>&1`;
    is($? >> 8, 0, 'CLI --release exits 0') or diag($out);
    ok(!-e $f, 'CLI --release removes it');
    `"$^X" "$cli" reconcile --hold ../escape 2>&1`;
    is($? >> 8, 2, 'a bad hold name is a usage error');
    `"$^X" "$cli" reconcile --hold a --release b 2>&1`;
    is($? >> 8, 2, '--hold and --release together are a usage error');
    `"$^X" "$cli" reconcile --hold 2>&1`;
    is($? >> 8, 2, '--hold with no name is a usage error');
}

# --- AC4 ---------------------------------------------------------------------------------------------
# package 08 (host-awake-actuator), spec 6.3: AC4 is INVERTED. The launcher no
# longer calls bp-power-plan or owns a helper of its own: it publishes an
# intent into HostAwake's registry (one source among several) and the
# continuity refresher is the single actuator that converges the helper AND
# the plan by level, every tick. AC1-AC3 above are unchanged -- old,
# unrestarted launchers still use the CLI and `reconcile` still counts their
# holds (Decision 7).
{
    my $src = do { open my $fh, '<:raw', "$Bin/../../../sandbox/scripts/launcher.pl" or die $!; local $/; <$fh> };
    unlike($src, qr/sub\s+_power_plan_hold\b/,
        'AC4: launcher.pl no longer defines _power_plan_hold');
    unlike($src, qr/_power_plan_hold\s*\(/,
        'AC4: launcher.pl no longer calls _power_plan_hold( anywhere');
    unlike($src, qr/bp-power-plan/,
        'AC4: launcher.pl no longer names bp-power-plan at all (CLI or script)');
    unlike($src, qr/\bplan_told\b/,
        'AC4: launcher.pl no longer declares or reads $plan_told');
    # _keepawake_release_global now only releases the holder (eval { $KEEPAWAKE->release if $KEEPAWAKE };),
    # with no separate plan call of its own.
    my ($rel_sub) = $src =~ /(sub _keepawake_release_global \{.*?\n\})/s;
    ok(defined $rel_sub, 'AC4: sub _keepawake_release_global is extractable')
        or diag('could not extract sub _keepawake_release_global from launcher.pl');
    if (defined $rel_sub) {
        like($rel_sub, qr/eval\s*\{\s*\$KEEPAWAKE->release\s+if\s+\$KEEPAWAKE;?\s*\};?/,
            'AC4: _keepawake_release_global only releases the holder ($KEEPAWAKE->release inside eval)');
        unlike($rel_sub, qr/_power_plan_hold/,
            'AC4: _keepawake_release_global makes no separate plan call of its own');
    }
}

done_testing();
