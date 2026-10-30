#!/usr/bin/env perl
# platform: host
# No test may actuate a real OS wake-lock.
#
# WHY THIS FILE EXISTS, AND WHY THE RULE IT ENFORCES IS NOT THE OBVIOUS ONE.
#
# bp-keepawake.pl's spawn() already refuses when $0 ends in ".t", and the comment
# there says a test therefore cannot leak an immortal helper. That is true only
# for a test that calls the perl directly. IT IS FALSE FOR A SUBPROCESS: a test
# that shells out to `perl butler-continuity.pl arm` hands the decision to a process
# whose own $0 is a .pl, and the guard never fires.
#
# That hole was live and costing real processes. t/runstate-pause-holds-lease.t
# ran `bp-runstate.pl pause`, which calls BpKeepAwake::apply with production
# seams; every run of it started a real keep-awake.ps1 on the host. It looked
# clean only because apply() used to return before the helper had written its pid
# file, so the assertion "a pause never fabricates a lease" was reading an empty
# directory a second too early. Making apply() claim the pid file up front — which
# it had to, to stop a fifteen-helper storm — is what exposed it.
#
# The repo has paid for this class twice already: 52 orphaned helpers holding
# 2.7 GB (2026-08-13), and 53 whose -PidFile pointed into File::Temp fixture
# directories (2026-08-14), which forced a machine restart. CLAUDE.md states the
# rule for launcher.pl; this is the same rule one level over, for a whole family
# of scripts, enforced instead of remembered.
#
# THE RULE. Any .t that so much as NAMES the old continuity CLI, bp-runstate.pl or
# the old continuity gate must set CCPRAXIS_NO_WAKELOCK=1 — the supported opt-out,
# and the only one that survives exec into a child process.
#
# Deliberately blunt: it matches a mention, not an invocation. Distinguishing
# "runs it" from "mentions it in a comment" means parsing perl in a regex, and
# the two false positives that costs are one line each, while the false NEGATIVE
# costs a process that outlives the suite. The asymmetry decides it.
#
# PACKAGE 16 POST-FIX-BATCH STRENGTHENING (Decision 80, blueprint
# hook-continuity-remake). F4 made the flattened stop-gate.sh and
# arm-on-entry.sh hooks (BpHook/StopGate.pm and BpHook/ArmOnEntry.pm) ensure
# the real wake-lock refresher (BpContinuityLease::converge ->
# BpContinuityLease::_spawn_daemon -> keep-awake.ps1) is running -- so those
# four names, and the module that actually holds the lease, join the
# ACTUATORS list below. 25 tests plus GuardHarness.pm had set
# CCPRAXIS_NO_WAKELOCK=1 at BEGIN and then wiped every CCPRAXIS_* variable
# before running a hook, so the wipe silently threw the opt-out away too --
# the sweep that exposed it started REAL BpContinuityLease daemons. Check 2
# below catches that class directly (any CCPRAXIS_* env wipe must keep
# CCPRAXIS_NO_WAKELOCK in the SAME expression), independent of whether the
# file mentions an actuator at all -- a wipe is a hazard on its own, because
# the next line added to the file might be the one that actually runs a hook.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $T = $Bin;

# This file is the lint, not a subject of it: several fixtures below (see
# "NON-VACUITY FIXTURES") deliberately embed bad-sample source text that
# WOULD trip the very checks this file performs, on purpose, to prove the
# checks actually fire. Scanning this file's own source would then flag
# itself for reasons that have nothing to do with this file's own hygiene.
# Excluded from BOTH sweeps below, by basename, rather than relying on the
# fragment-building trick alone (still used for the ACTUATORS needles
# themselves, matching the house style) to survive future fixtures.
my ($SELF) = __FILE__ =~ m{([^/\\]+)$};

# The scripts that can reach BpKeepAwake::apply / BpContinuityLease::ensure_daemon
# from a subprocess. Add to this list when another one learns to hold the lease.
# bp-runstate.pl DROPPED (package 03-retire-runstate, spec §2.9's entry for
# this file): the script is deleted, so it can no longer reach anything as a
# subprocess; the rule and its other two actuators stay unchanged.
my $OLD_CONTINUITY_CLI  = 'bp-continuity' . '.pl';
my $OLD_CONTINUITY_GATE = 'gate-continuity' . '.sh';

# Package 16 post-fix-batch (Decision 80) additions. Every needle is built
# from split fragments -- never one contiguous literal token anywhere in
# this file -- exactly like the two needles above, so this file's own prose
# (which has to be able to talk about these names) cannot self-trip the
# sweep even where the basename exclusion above did not exist.
my $STOP_GATE_BARE      = 'stop' . '-gate';       # no extension: GuardHarness's own hook-name argument form
my $ARM_ON_ENTRY_BARE   = 'arm-on' . '-entry';     # ditto
my $STOP_GATE_SH        = $STOP_GATE_BARE . '.sh';
my $ARM_ON_ENTRY_SH     = $ARM_ON_ENTRY_BARE . '.sh';
my $STOP_GATE_MOD       = 'Stop' . 'Gate';         # BpHook::StopGate / StopGate.pm, either way
my $ARM_ON_ENTRY_MOD    = 'Arm' . 'OnEntry';       # BpHook::ArmOnEntry / ArmOnEntry.pm, either way
my $LEASE_MOD           = 'BpContinuity' . 'Lease';

# GuardHarness::run_wrapper/run_module take the BARE hook name (no .sh/.pm
# suffix -- _hook_path()/the "BpHook::$module::run" string add that back),
# so `run_wrapper('arm-on-entry', ...)` (cutover-hardening.t's own F4/F2
# fixtures) would slip past every needle above except this one. Anchored to
# the call syntax itself, not a bare mention, specifically so it does NOT
# also match `by => 'arm-on-entry'` -- BpHook::arm()'s ordinary metadata
# value, used in dozens of tests that never touch a real hook at all (see
# the "arm() metadata is not a mention" fixture below).
my $GUARDHARNESS_CALL = qr/
    (?:run_wrapper|run_module) \s* \( \s* ['"]
    (?: \Q$STOP_GATE_BARE\E | \Q$ARM_ON_ENTRY_BARE\E
      | \Q$STOP_GATE_MOD\E  | \Q$ARM_ON_ENTRY_MOD\E )
/x;

my $ACTUATORS = qr/(?:
      \Q$OLD_CONTINUITY_CLI\E
    | \Q$OLD_CONTINUITY_GATE\E
    | \Q$STOP_GATE_SH\E
    | \Q$ARM_ON_ENTRY_SH\E
    | \Q$STOP_GATE_MOD\E
    | \Q$ARM_ON_ENTRY_MOD\E
    | \Q$LEASE_MOD\E
    | $GUARDHARNESS_CALL
)/x;

# A POSITIVE setting, not a mention. `delete $ENV{CCPRAXIS_NO_WAKELOCK}` is a
# legitimate thing for a test of the lease itself to do, and it is the opposite
# of a guard — so matching the bare name would bless exactly the file most able
# to do damage.
my $GUARD = qr/CCPRAXIS_NO_WAKELOCK(?:\}\s*=\s*1|\s*=\s*['"]?1)/;

# ---------------------------------------------------------------------------
# CHECK 2's detector, factored out so the non-vacuity fixtures below can
# exercise it directly instead of only through a real file on disk.
#
# A "wipe line" is one that (a) touches %ENV/$ENV in bulk (grep/delete over
# `keys %ENV`, or building a filtered copy of it) and (b) anchors a regex
# alternation at the CCPRAXIS_ prefix -- `/^CCPRAXIS_/`, `/^(?:BP_|CCPRAXIS_|
# CLAUDE_)/`, `/^(BP_|CCPRAXIS_)/`, any of that shape. Such a line is an
# offender unless CCPRAXIS_NO_WAKELOCK also appears on it, keeping (or
# explicitly re-adding) the one variable that must survive every wipe.
#
# Line-based, not a single whole-source regex: every real instance in this
# tree (checked against the full test suite while writing this) is a single
# perl statement on one line, and per-line is what lets an offender be
# reported with a line number instead of just a filename.
# ---------------------------------------------------------------------------
my $CCPRAXIS_PREFIX_ANCHOR = qr/\^[A-Za-z_|:?()]*CCPRAXIS_/;

sub find_unguarded_wipes {
    my ($src) = @_;
    my @lines = split /\n/, $src;
    my @hits;
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        next unless $line =~ /ENV/;
        next unless $line =~ $CCPRAXIS_PREFIX_ANCHOR;
        next if $line =~ /CCPRAXIS_NO_WAKELOCK/;
        push @hits, $i + 1;
    }
    return @hits;
}

my @files = sort glob("$T/*.t");
ok(scalar @files, 'found the butler test files') or BAIL_OUT('no .t files');

my (@drivers, @unguarded);
for my $f (@files) {
    my ($base) = $f =~ m{([^/\\]+)$};
    next if $base eq $SELF;
    open my $fh, '<:raw', $f or die "read $f: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    next unless $src =~ $ACTUATORS;
    push @drivers, $base;
    push @unguarded, $base unless $src =~ $GUARD;
}

ok(scalar @drivers,
   'at least one test drives a wake-lock actuator (if this ever fails, the '
 . 'ACTUATORS pattern has drifted from the filenames and this file is guarding nothing)');

is(scalar @unguarded, 0,
   'every test that names a wake-lock actuator sets CCPRAXIS_NO_WAKELOCK=1')
    or diag("unguarded: @unguarded\n"
          . "Add near the top, above the first `use` that matters:\n"
          . "  BEGIN { \$ENV{CCPRAXIS_NO_WAKELOCK} = 1 }\n");

# ---------------------------------------------------------------------------
# CHECK 2 -- run against every t/*.t AND every tests/lib/*.pm (Decision 80:
# "25 tests plus GuardHarness.pm"; GuardHarness lives in tests/lib/, not
# tests/t/, so the sweep has to reach both directories or it would have
# missed the exact file the incident named).
# ---------------------------------------------------------------------------
my @wipe_scan_files = (@files, sort glob("$T/../lib/*.pm"));
my @wipe_offenders;
for my $f (@wipe_scan_files) {
    my ($base) = $f =~ m{([^/\\]+)$};
    next if $base eq $SELF;
    open my $fh, '<:raw', $f or die "read $f: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    for my $lineno (find_unguarded_wipes($src)) {
        push @wipe_offenders, "$base:$lineno";
    }
}

is(scalar @wipe_offenders, 0,
   'no test or tests/lib/*.pm wipes CCPRAXIS_* without also keeping CCPRAXIS_NO_WAKELOCK '
 . 'in the same expression')
    or diag("offenders: @wipe_offenders\n"
          . "Fix the wipe itself, keeping the exclusion in the SAME expression, e.g.:\n"
          . "  delete \$ENV{\$_} for grep { !/^CCPRAXIS_NO_WAKELOCK\$/ && "
          . "/^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;\n");

# ---------------------------------------------------------------------------
# NON-VACUITY FIXTURES -- both new checks proven to actually fire on a bad
# sample and stay quiet on a good one, in-process, without relying on any
# real file in the tree happening to be in the right state right now.
# ---------------------------------------------------------------------------

# -- check 1 (actuator mention -> must set the guard) --
{
    my $bad = "use strict;\nGuardHarness::run_module('StopGate', \$payload);\n";
    ok($bad =~ $ACTUATORS, 'fixture C1-bad: run_module(\'StopGate\', ...) is recognized as an actuator mention');
    ok(!($bad =~ $GUARD), 'fixture C1-bad: ...and, as written, carries no CCPRAXIS_NO_WAKELOCK guard -- exactly what the sweep above must flag');

    my $good = "BEGIN { \$ENV{CCPRAXIS_NO_WAKELOCK} = 1 }\nGuardHarness::run_module('StopGate', \$payload);\n";
    ok($good =~ $ACTUATORS, 'fixture C1-good: still recognized as an actuator mention');
    ok($good =~ $GUARD, 'fixture C1-good: ...and now carries the guard, so the sweep must NOT flag it');

    # The hyphenated, no-extension GuardHarness call form (cutover-hardening.t's
    # own F2/F4 fixtures use exactly this: run_wrapper('arm-on-entry', ...)).
    my $wrapper_call = "GuardHarness::run_wrapper('arm-on-entry', \$payload);\n";
    ok($wrapper_call =~ $ACTUATORS,
       'fixture C1-wrapper: run_wrapper(\'arm-on-entry\', ...) is recognized as an actuator mention');

    # The load-bearing negative: BpHook::arm()'s ordinary `by => 'arm-on-entry'`
    # metadata, used across dozens of tests that never run a real hook, must
    # NOT be swept in -- only the GuardHarness call syntax above is specific
    # enough to mean "this actually drives the hook".
    my $metadata_only = "BpHook::arm(\$sid, role => 'driver', by => 'arm-on-entry');\n";
    ok(!($metadata_only =~ $ACTUATORS),
       'fixture C1-metadata: bare by => \'arm-on-entry\' metadata alone is NOT an actuator mention '
     . '(would otherwise sweep in every test that calls BpHook::arm)');
}

# -- check 2 (CCPRAXIS_* wipe -> must keep CCPRAXIS_NO_WAKELOCK) --
{
    my $bad = "delete \$ENV{\$_} for grep { /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;\n";
    my @bad_hits = find_unguarded_wipes($bad);
    is(scalar @bad_hits, 1, 'fixture C2-bad: a CCPRAXIS_* wipe with no exclusion is flagged') or diag("hits: @bad_hits");

    my $good = "delete \$ENV{\$_} for grep { !/^CCPRAXIS_NO_WAKELOCK\$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;\n";
    is(scalar(find_unguarded_wipes($good)), 0, 'fixture C2-good: the same wipe, with the exclusion kept, is not flagged');

    # A wipe that only ever touches BP_ (never CCPRAXIS_ at all) is not this
    # class of bug -- CCPRAXIS_NO_WAKELOCK was never at risk from it, so it
    # must not be swept in just because the word ENV appears nearby.
    my $bp_only = "delete \$ENV{\$_} for grep { !/^BP_/ } keys %ENV;\n";
    is(scalar(find_unguarded_wipes($bp_only)), 0, 'fixture C2-bp-only: a BP_-only wipe (no CCPRAXIS_ prefix at all) is not flagged');

    # The variant that uses a plain (non-`?:`) alternation group -- seen in
    # the tree as `!/^(BP_|CCPRAXIS_)/` -- must be caught the same way.
    my $bad_plain_group = "my \%c = grep { /^(BP_|CCPRAXIS_)/ } keys %ENV;\n";
    is(scalar(find_unguarded_wipes($bad_plain_group)), 1,
       'fixture C2-plain-group: a plain (non-"?:") CCPRAXIS_ alternation group is caught too');
}

# The opt-out has to still be honoured at BOTH actuation points, or the line
# above is enforcing a variable nobody reads. Asserted against the source
# because "did not start an OS process" has no in-process observable.
for my $pair (['bp-keepawake.pl',      'spawn'],
              [$LEASE_MOD . '.pm',     'ensure_daemon']) {
    my ($file, $what) = @$pair;
    open my $fh, '<:raw', "$T/../../scripts/$file" or die "read $file: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    like($src, qr/CCPRAXIS_NO_WAKELOCK/,
         "$file still honours CCPRAXIS_NO_WAKELOCK (the guard $what depends on)");
}

done_testing();
