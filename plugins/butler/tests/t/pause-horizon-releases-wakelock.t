#!/usr/bin/env perl
# platform: any
# Oracle for pause_keepawake_phase() in bp-drive-next.pl: how far ahead a usage
# pause may resume and still justify holding the machine awake for it.
#
# THE DEFECT, measured on the host 2026-09-18. Holding the wake-lock across a
# pause is a promise about resuming -- the machine has to still be awake when the
# usage window reopens, which is why 'pause-pending' is one of the two phases
# should_be_on() holds for. That is sound for the FIVE-HOUR window, which cannot
# reopen more than five hours out. It is not sound for the SEVEN-DAY window: the
# governor returned
#   {"action":"pause","reason":"usage","until_epoch":1790013600}
# with seven_day at 86%, resetting 2026-09-21T18:00Z -- 88 hours away. The old
# unconditional mapping would have held a laptop awake from Friday morning to
# Monday evening waiting for it.
#
# THE ACTION MUST NOT CHANGE. This decides only whether the machine is held
# awake. Anything consuming the director's JSON -- stop-gate.sh,
# the watchdog logic, the reporter -- must see byte-identical output either way, so
# AC-4 pins that rather than trusting it.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 } # package 16 post-fix-batch (Decision 80): this file names a wake-lock actuator, in prose or a path check, never a real invocation -- the guard is the cheap side of test-wakelock-hygiene.t's deliberate over-matching.
# Both the horizon constant and the BpKeepAwake::apply override are referenced
# exactly once, which is what 'once' warns about; here that is the intent.
no warnings 'once';
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);

my $SCRIPT = "$Bin/../../scripts/bp-drive-next.pl";
my $LOADED = do { local $@; eval { require $SCRIPT }; !$@ };
ok($LOADED, 'bp-drive-next.pl loads') or diag($@);

my $NOW = 1_830_297_600;
my $J   = JSON::PP->new->canonical;
my $H   = $BpDrive::KEEPAWAKE_PAUSE_HORIZON_SECONDS;

# AC-1: the horizon constant is what the comment claims
is($H, 6 * 3600, 'AC-1: horizon is six hours');

# AC-2: the pure decision
{
    is(BpDrive::pause_keepawake_phase('usage', $NOW + 60,      $NOW), 'pause-pending',
        'AC-2: a pause a minute away holds the lock');
    is(BpDrive::pause_keepawake_phase('usage', $NOW + 5*3600,  $NOW), 'pause-pending',
        'AC-2: the five-hour window still holds -- the case the hold exists for');
    is(BpDrive::pause_keepawake_phase('usage', $NOW + 88*3600, $NOW), 'settled',
        'AC-2: the measured 88-hour seven-day pause releases');

    # Strictly greater-than: a pause landing exactly ON the horizon holds.
    is(BpDrive::pause_keepawake_phase('usage', $NOW + $H,      $NOW), 'pause-pending',
        'AC-2: exactly on the horizon holds (boundary is >, not >=)');
    is(BpDrive::pause_keepawake_phase('usage', $NOW + $H + 1,  $NOW), 'settled',
        'AC-2: one second past the horizon releases');
}

# AC-3: the two fail-safe directions, both deliberate
{
    is(BpDrive::pause_keepawake_phase('usage', undef, $NOW), 'pause-pending',
        'AC-3: undefined until_epoch keeps the OLD behaviour and holds');
    is(BpDrive::pause_keepawake_phase('token-refresh', $NOW + 60, $NOW), 'settled',
        'AC-3: a non-usage pause never holds');
    is(BpDrive::pause_keepawake_phase(undef, $NOW + 60, $NOW), 'settled',
        'AC-3: an undefined reason never holds');

    # A pause already in the past is not "far away" -- it is due.
    is(BpDrive::pause_keepawake_phase('usage', $NOW - 3600, $NOW), 'pause-pending',
        'AC-3: an overdue pause holds rather than releasing');
}

# AC-4/AC-5: end to end -- the phase actually reaches BpKeepAwake, and the
# emitted action is unchanged across the horizon.
sub make_bp_dir {
    my ($data, $name, $pkgs) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");
    my $md = "# $name\n\nstatus: audited\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    $md .= "| $_->{key} | thing | -- | sonnet | $_->{status} |\n" for @$pkgs;
    open my $bfh, '>:raw', "$bp/blueprint.md" or die $!;
    print $bfh $md;
    close $bfh;
    for my $p (@$pkgs) {
        open my $lfh, '>:raw', "$bp/packages/$p->{key}.md" or die $!;
        print $lfh "---\npackage: $p->{key}\nblueprint: $name\nstatus: $p->{status}\n"
                 . "model: sonnet\nmax_turns: 80\nwrite_set: ws/$p->{key}/\n"
                 . "test_paths: ws/$p->{key}/\nlast_updated: 2028-01-01T00:00:00Z\n---\n";
        close $lfh;
    }
}

# Capture the phase handed to the shared wake-lock module.
our @PHASES;
{
    no warnings 'redefine';
    *BpKeepAwake::apply = sub { push @PHASES, $_[0]; return };
}

sub run_pause {
    my ($until) = @_;
    @PHASES = ();
    my $data = tempdir(CLEANUP => 1);
    make_bp_dir($data, 'bp-x', [{ key => 'p1', status => 'pending' }]);
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    open my $oh, '>:raw', "$dsdir/order.json" or die $!;
    print $oh $J->encode({ order => ['bp-x'], recorded_at => $NOW });
    close $oh;

    my ($ofh, $opath) = tempfile('pausehz-XXXXXX', TMPDIR => 1);
    close $ofh;
    open my $oldout, '>&STDOUT' or die $!;
    open STDOUT, '>:raw', $opath or die $!;
    $| = 1;
    eval {
        BpDrive::run(['next', '--scope', 'all'], {
            data_dir => $data,
            now      => sub { $NOW },
            verdict  => sub { { action => 'pause-usage', until_epoch => $until } },
            spawn    => sub { },
            kill_pid => sub { },
            powershell_available => sub { 0 },
        });
    };
    my $err = $@;
    open STDOUT, '>&', $oldout or die $!;
    close $oldout;
    my $out = do { open my $r, '<:raw', $opath or die $!; local $/; my $x = <$r>; close $r; $x // '' };
    unlink $opath;
    die $err if $err;
    chomp $out;
    my @lines = grep { /\S/ } split /\n/, $out;
    my $log = -f "$dsdir/run.md"
            ? do { open my $r, '<', "$dsdir/run.md" or die $!; local $/; <$r> } : '';
    return (eval { $J->decode($lines[-1] // '') }, $log);
}

{
    my ($near_act, $near_log) = run_pause($NOW + 3600);
    is($near_act->{action}, 'pause', 'AC-4: near pause emits a pause action');
    is_deeply(\@PHASES, ['pause-pending'], 'AC-4: near pause hands BpKeepAwake pause-pending');
    unlike($near_log, qr/PAUSE-BEYOND-HORIZON/, 'AC-4: near pause logs no horizon release');

    # AC-8 (package 10 / never-halt, Decision 47): the "far" case moved from
    # 88h to 9h. 88h now crosses the NEW 12h long-pause threshold (package
    # 10) and stops being a plain `pause` at all -- see the dedicated
    # pause-long block below. 9h stays comfortably under 12h while still
    # being past this file's own 6h wake-lock horizon, so it is the value
    # that actually isolates "the 6h wake-lock horizon still works" from
    # "the 12h long-pause threshold also fired" -- the two could no longer
    # be told apart at 88h once pause-long exists. The 6h-horizon CONTRACT
    # itself (only the wake-lock changes, never the pause action's keys) is
    # unchanged; only the probe value moved.
    my ($far_act, $far_log) = run_pause($NOW + 9 * 3600);
    is($far_act->{action}, 'pause',
        'AC-8: a 9h pause still emits a plain pause action (past the 6h horizon, short of the 12h long-pause threshold)');
    is_deeply(\@PHASES, ['settled'], 'AC-8: a 9h pause hands BpKeepAwake settled');
    like($far_log, qr/PAUSE-BEYOND-HORIZON/, 'AC-8: a 9h pause records why the lock went');
    unlike($far_log, qr/PAUSE-LONG/,
        'AC-8: a 9h pause never logs PAUSE-LONG (it is under the 12h long-pause threshold)');

    # THE CONTRACT: only the wake-lock changes, never the action. Same reason,
    # same shape; the epoch differs only because the inputs did.
    is($far_act->{reason}, $near_act->{reason}, 'AC-8: reason unchanged across the 6h horizon');
    is_deeply([sort keys %$far_act], [sort keys %$near_act],
        'AC-8: the action JSON has identical keys either side of the 6h horizon');
    is($far_act->{until_epoch}, $NOW + 9 * 3600,
        'AC-8: until_epoch is still reported in full -- the run resumes, it is just not held awake');
}

# ── AC-5/B1/B2 (package 10 / never-halt, Decision 47): an 88h usage pause now
# crosses the 12h long-pause threshold -- it is no longer a plain `pause` at
# all. The wake-lock is released the same way (`settled`) that the 6h horizon
# already gave any far-out pause; what changes is the ACTION itself.
# ===========================================================================
{
    my ($far_act, $far_log) = run_pause($NOW + 88 * 3600);
    is($far_act->{action}, 'pause-long',
        '(pkg10) AC-5: an 88h usage pause emits pause-long, not plain pause');
    is_deeply(\@PHASES, ['settled'],
        '(pkg10) AC-5/B2: the wake-lock module receives exactly settled for the long pause');
    like($far_log, qr/PAUSE-LONG/,
        '(pkg10) AC-5/B2: run.md gains a line matching PAUSE-LONG for the long pause');
    unlike($far_log, qr/PAUSE-BEYOND-HORIZON/,
        '(pkg10) AC-5/B2: no PAUSE-BEYOND-HORIZON line is written on the long-pause path');
    is($far_act->{reason}, 'usage', '(pkg10) AC-5: reason is usage');
    is($far_act->{until_epoch}, $NOW + 88 * 3600,
        '(pkg10) AC-5: until_epoch is still reported in full on the long-pause action');
    ok(exists $far_act->{until_iso}, '(pkg10) AC-5: the pause-long action carries an until_iso field');
}

done_testing();
