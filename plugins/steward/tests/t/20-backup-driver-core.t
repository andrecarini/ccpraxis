#!/usr/bin/env perl
# 20-backup-driver-core.t -- oracle for blueprint backup-driver, package
# 01-driver-skeleton (scripts/backup.pl + scripts/backup/Run.pm).
#
# Spec: .ccpraxis-local-data/blueprints/backup-driver/specs/01-driver-skeleton-spec.md
#
# This test is written BLIND to any implementation: only the spec, StewardTest,
# and the t/13-install-config-backup.t spawner precedent were read. Do not read
# scripts/backup.pl or scripts/backup/Run.pm while editing this file.
#
# AC -> test name mapping (grep for "AC<n>:" to find every assertion for a
# given criterion; the full table also lives in the accompanying report):
#   AC1  (amended -- floor, not exact enum shape/order/count)
#   AC2  Backup::Run::validate_decision accept/reject cases
#   AC3  no decision-kind literal appears in scripts/backup.pl
#   AC4  mint_token / parse_token grammar + round-trip
#   AC5  malformed resume token refused, no phase re-run
#   AC6  unknown resume token refused, no phase re-run
#   AC7  a replayed (already-consumed) token is refused
#   AC8  bare `run` against a paused run is refused (token_missing)
#   AC9  run-state file shape after the first pause
#   AC10 default run-state location (HOME/USERPROFILE-anchored)
#   AC11 a corrupt state file is refused and left untouched
#   AC12 needs_decision output shape + resume_token grammar
#   AC13 resume completes; stub_a's body runs exactly once
#   AC14 answers reach the resumed phase (ctx->{answers}, ctx->{note})
#   AC15 kill between phases: no double-run of the already-complete phase
#   AC16 answer_unknown_id does not consume the token
#   AC17 answer_unknown_choice / answer_missing
#   AC18 --answer without --resume, and an unknown subcommand, are usage errors
#   AC19 perl -c is clean on all three files
#   AC20 every one of the 14 kinds is constructible via validate_decision
#   AC21 (added by coordinator) invalid decision kind -> decision_invalid, nothing pending
#   AC22 (added by coordinator) a failed phase does not abort the run -> complete_with_failures
#   AC23 (added by coordinator) a died phase DOES abort the run -> phase_died (contrast w/ AC22)
#   AC24 (added by coordinator) --restart: new run_id, --restart+--resume is usage, escape hatch
#        past state_corrupt
#   AC25 (added by coordinator) a changed phase set on resume -> state_phase_drift
#   AC26 (added by coordinator) --help exits 0, prints usage, creates no state file
#   AC27 (coordinator ruling R1, BLOCKER) bare run vs a TERMINAL state starts fresh; AC8 must not regress
#   AC28 (coordinator ruling R2) complete must be earned -- a pending/running phase is internal
#   AC29 (coordinator ruling R3) phase_index is untrusted input -- range-validated on read
#   AC30 (coordinator ruling R4) an uncaught die still yields one JSON object on stdout, exit 1
#   AC31 (coordinator ruling R5) a phase writing to STDOUT cannot corrupt the driver's own JSON
#   AC32 (coordinator ruling R6) running-reentry clears an answer; paused-reentry preserves it
#   AC33 (coordinator ruling R7) --restart renames the discarded state instead of destroying it
#
# Plus one test explicitly requested outside the AC table: discover_phases
# must not treat a file literally named Run.pm as a phase module.
#
# AC21-AC26 were added after the coordinator reviewed the initial 20-AC oracle
# and closed the gap flagged in the original report: spec section 3 Behaviors
# 12/13/14/16/17/18 (decision_invalid, complete_with_failures, phase_died,
# --restart, state_phase_drift, --help) had no corresponding numbered AC in
# spec section 4.
#
# AC27-AC33 were added after the implementation went 199/199 green and
# bp-redteam / bp-reviewer / the coordinator found a BLOCKER and six MAJORs
# not expressible from AC1-AC26 alone (see spec section 8, coordinator
# rulings R1-R7, which supersede anything earlier in the spec that
# conflicts). See the accompanying report for the full history.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use JSON::PP;
use StewardTest qw(ok is like unlike diag done_testing temproot make_machine write_text read_text path_exists);

my $SCRIPT = "$Bin/../../../../scripts/backup.pl";
my $RUNPM  = "$Bin/../../../../scripts/backup/Run.pm";

ok(-f $SCRIPT, 'scripts/backup.pl exists on disk')
    or diag('scripts/backup.pl is absent -- every behavioral test below will fail for this reason');
ok(-f $RUNPM, 'scripts/backup/Run.pm exists on disk')
    or diag('scripts/backup/Run.pm is absent -- every Run.pm-contract test below will fail for this reason');

# ---------------------------------------------------------------------------
# The 14 decision kinds, per spec S2.1. Hard-coded here deliberately: this is
# the ORACLE's own list of what the spec requires to exist, not a copy of the
# implementation's array. Per the AMENDED AC1 (coordinator ruling), we assert
# a FLOOR against @Backup::Run::DECISION_KINDS -- never its count or order.
# ---------------------------------------------------------------------------
my @REQUIRED_KINDS = qw(
    dirty_worktree
    remote_merge_conflict
    clone_live_divergence
    readme_drift
    settings_key
    marketplace_key
    file_conflict
    container_settings_key
    sensitive_finding
    push_confirmation
    vault_conflict
    project_registration
    plugin_install
    step_failure
);

# ---------------------------------------------------------------------------
# Load Run.pm once, tolerating its absence so the rest of the file can report
# every planned assertion as a named failure instead of dying.
# ---------------------------------------------------------------------------
my $RUNPM_OK = 0;
{
    local $@;
    $RUNPM_OK = eval { require $RUNPM; 1 };
    diag("Run.pm did not load cleanly: " . ($@ || 'unknown error')) unless $RUNPM_OK;
}

# =====================================================================
# AC1 (AMENDED) -- floor assertions on the decision-kind enum
# =====================================================================
if ($RUNPM_OK) {
    no warnings 'once';   # @Backup::Run::DECISION_KINDS is loaded at runtime via require
    my %present = map { $_ => 1 } @Backup::Run::DECISION_KINDS;
    for my $k (@REQUIRED_KINDS) {
        ok($present{$k}, "AC1: \@Backup::Run::DECISION_KINDS contains '$k'");
    }
    for my $k (@REQUIRED_KINDS) {
        ok(Backup::Run::is_decision_kind($k), "AC1: is_decision_kind('$k') is true");
    }
    ok(!Backup::Run::is_decision_kind('not_a_kind'), "AC1: is_decision_kind('not_a_kind') is false");
    ok(!Backup::Run::is_decision_kind(''),           "AC1: is_decision_kind('') is false");
    ok(!Backup::Run::is_decision_kind(undef),        "AC1: is_decision_kind(undef) is false");
}
else {
    for my $k (@REQUIRED_KINDS) {
        ok(0, "AC1: \@Backup::Run::DECISION_KINDS contains '$k' (Run.pm not loaded)");
    }
    for my $k (@REQUIRED_KINDS) {
        ok(0, "AC1: is_decision_kind('$k') is true (Run.pm not loaded)");
    }
    ok(0, "AC1: is_decision_kind('not_a_kind') is false (Run.pm not loaded)");
    ok(0, "AC1: is_decision_kind('') is false (Run.pm not loaded)");
    ok(0, "AC1: is_decision_kind(undef) is false (Run.pm not loaded)");
}

# =====================================================================
# AC2 -- Backup::Run::validate_decision accept/reject cases
# =====================================================================
sub base_decision {
    return {
        id      => 'stub.check',
        kind    => 'step_failure',
        phase   => 'stub',
        title   => 'Proceed?',
        choices => [ { id => 'yes', label => 'Yes' }, { id => 'no', label => 'No' } ],
    };
}

if ($RUNPM_OK) {
    my ($ok0) = Backup::Run::validate_decision(base_decision());
    ok($ok0, 'AC2: a well-formed decision record is accepted');

    {
        my $d = base_decision();
        $d->{kind} = 'not_a_kind';
        my ($ok2, $reason) = Backup::Run::validate_decision($d);
        ok(!$ok2, 'AC2: an unknown kind is rejected');
        like($reason // '', qr/kind/i, 'AC2: the rejection reason names the kind field');
    }
    {
        my $d = base_decision();
        delete $d->{title};
        my ($ok2, $reason) = Backup::Run::validate_decision($d);
        ok(!$ok2, 'AC2: a missing title is rejected');
        like($reason // '', qr/title/i, 'AC2: the rejection reason names the title field');
    }
    {
        my $d = base_decision();
        $d->{id} = 'other.check';   # phase is still 'stub'
        my ($ok2, $reason) = Backup::Run::validate_decision($d);
        ok(!$ok2, 'AC2: an id not prefixed with its phase is rejected');
        like($reason // '', qr/id|phase|prefix/i, 'AC2: the rejection reason names the id/phase mismatch');
    }
    {
        my $d = base_decision();
        $d->{choices} = [ { id => 'yes', label => 'Yes' } ];
        my ($ok2, $reason) = Backup::Run::validate_decision($d);
        ok(!$ok2, 'AC2: fewer than 2 choices is rejected');
        like($reason // '', qr/choice/i, 'AC2: the rejection reason names the choices field');
    }
    {
        my $d = base_decision();
        $d->{choices} = [ { id => 'yes', label => 'Yes' }, { id => 'yes', label => 'Yes again' } ];
        my ($ok2, $reason) = Backup::Run::validate_decision($d);
        ok(!$ok2, 'AC2: a duplicate choice id is rejected');
        like($reason // '', qr/choice|duplicate/i, 'AC2: the rejection reason names the duplicate choice');
    }
}
else {
    ok(0, "AC2: $_ (Run.pm not loaded)") for (
        'a well-formed decision record is accepted',
        'an unknown kind is rejected',
        'the rejection reason names the kind field',
        'a missing title is rejected',
        'the rejection reason names the title field',
        'an id not prefixed with its phase is rejected',
        'the rejection reason names the id/phase mismatch',
        'fewer than 2 choices is rejected',
        'the rejection reason names the choices field',
        'a duplicate choice id is rejected',
        'the rejection reason names the duplicate choice',
    );
}

# =====================================================================
# AC3 -- no decision-kind string literal outside Run.pm's declaration
# =====================================================================
if (-f $SCRIPT) {
    my $src = read_text($SCRIPT) // '';
    for my $k (@REQUIRED_KINDS) {
        unlike($src, qr/\Q$k\E/, "AC3: scripts/backup.pl does not contain the kind literal '$k'");
    }
}
else {
    ok(0, "AC3: scripts/backup.pl does not contain the kind literal '$_' (backup.pl not found)") for @REQUIRED_KINDS;
}

# =====================================================================
# AC4 -- mint_token / parse_token grammar + round-trip
# =====================================================================
if ($RUNPM_OK) {
    my $tok = Backup::Run::mint_token('0123456789abcdef', 1);
    like($tok // '', qr/^bkp1\.[0-9a-f]{16}\.1$/, 'AC4: mint_token produces the bkp1.<16hex>.<seq> grammar');

    my ($rid, $seq) = Backup::Run::parse_token($tok // '');
    is($rid, '0123456789abcdef', 'AC4: parse_token round-trips the run_id');
    is($seq, 1, 'AC4: parse_token round-trips the seq');

    for my $bad ('x', 'bkp1.ZZZ.1', 'bkp2.0123456789abcdef.1', 'bkp1.0123456789abcdef.0') {
        my @r = Backup::Run::parse_token($bad);
        is(scalar(@r), 0, "AC4: parse_token('$bad') returns empty for a malformed token");
    }
}
else {
    ok(0, "AC4: $_ (Run.pm not loaded)") for (
        'mint_token produces the bkp1.<16hex>.<seq> grammar',
        'parse_token round-trips the run_id',
        'parse_token round-trips the seq',
        "parse_token('x') returns empty for a malformed token",
        "parse_token('bkp1.ZZZ.1') returns empty for a malformed token",
        "parse_token('bkp2.0123456789abcdef.1') returns empty for a malformed token",
        "parse_token('bkp1.0123456789abcdef.0') returns empty for a malformed token",
    );
}

# =====================================================================
# AC20 -- every one of the 14 kinds is constructible
# =====================================================================
if ($RUNPM_OK) {
    for my $k (@REQUIRED_KINDS) {
        my $d = {
            id      => "stub.$k.check",
            kind    => $k,
            phase   => 'stub',
            title   => "Minimal $k decision",
            choices => [ { id => 'a', label => 'A' }, { id => 'b', label => 'B' } ],
        };
        my ($ok2, $reason) = Backup::Run::validate_decision($d);
        ok($ok2, "AC20: a minimal decision record carrying kind '$k' is accepted")
            or diag("reason: " . ($reason // '(none given)'));
    }
}
else {
    ok(0, "AC20: a minimal decision record carrying kind '$_' is accepted (Run.pm not loaded)") for @REQUIRED_KINDS;
}

# =====================================================================
# Scaffolding for the behavioral (spawn backup.pl) tests below.
# =====================================================================

# run_vs (StewardTest) is hard-wired to vault-sync.pl and cannot run
# backup.pl (see the report / coordinator ruling 3). This local spawner
# follows the t/13-install-config-backup.t precedent of defining its own,
# but additionally captures stdout SEPARATE from stderr: stdout must stay
# parseable JSON (spec S2.6), and stderr is captured via a real File::Temp
# FILE -- never an in-memory scalar (documented Git-for-Windows landmine:
# reopening STDOUT/STDERR onto a scalar fails with "Bad file descriptor").
sub _spawn {
    my ($env_overrides, @args) = @_;

    my %env = %$env_overrides;
    local @ENV{ keys %env } = values %env;

    my ($efh, $ename) = tempfile(UNLINK => 1);
    close $efh;

    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $ename) or die "cannot redirect STDERR to $ename: $!";

    my $out  = '';
    my $exit = -1;
    my $pid  = open(my $fh, '-|', $^X, $SCRIPT, @args);
    if ($pid) {
        local $/;
        $out = <$fh>;
        $out = '' unless defined $out;
        close $fh;
        $exit = $? >> 8;
    }

    open(STDERR, '>&', $saved_stderr) or warn "cannot restore STDERR: $!";
    close $saved_stderr;

    my $err = read_text($ename);
    $err = '' unless defined $err;
    unlink $ename;

    my $json = eval { decode_json($out) };
    return { out => $out, err => $err, exit => $exit, json => $json };
}

# Build a scratch scenario: a fresh temp root, a BACKUP_PHASE_DIR populated
# with the given "<Filename>.pm => <source text>" pairs, a BACKUP_RUN_STATE
# path, and a BACKUP_TEST_LOG path.
sub new_scenario {
    my (%files) = @_;
    my $root = temproot();
    my $pdir = "$root/phases";
    for my $fname (keys %files) {
        write_text("$pdir/$fname", $files{$fname});
    }
    make_path($pdir) unless -d $pdir;
    return {
        root       => $root,
        phase_dir  => $pdir,
        state_path => "$root/state/run.json",
        log_path   => "$root/log.txt",
    };
}

sub run_backup_raw {
    my ($scn, @args) = @_;
    my %env = (
        BACKUP_PHASE_DIR        => $scn->{phase_dir},
        BACKUP_RUN_STATE        => $scn->{state_path},
        BACKUP_TEST_LOG         => $scn->{log_path},
        BACKUP_TEST_KILL_MARKER => ($scn->{kill_marker} // ''),
    );
    return _spawn(\%env, @args);
}

sub run_backup {
    my ($scn, @args) = @_;
    return run_backup_raw($scn, 'run', @args);
}

sub read_state {
    my ($path) = @_;
    my $raw = read_text($path);
    return undef unless defined $raw;
    return eval { decode_json($raw) };
}

sub log_line_count {
    my ($log_path) = @_;
    my $raw = read_text($log_path);
    return 0 unless defined $raw;
    my @lines = grep { length $_ } split /\n/, $raw;
    return scalar @lines;
}

sub log_counts {
    my ($log_path) = @_;
    my %counts;
    my $raw = read_text($log_path);
    return %counts unless defined $raw;
    for my $line (split /\n/, $raw) {
        next unless length $line;
        $counts{$line}++;
    }
    return %counts;
}

# ---------------------------------------------------------------------------
# Stub phase module source. Each stub's run_phase appends its own name to
# $ENV{BACKUP_TEST_LOG} as its FIRST action (spec S4 harness paragraph) --
# this is the execution counter that AC13/AC15 depend on.
# ---------------------------------------------------------------------------

my $LOG_HELPER = <<'PERL';
sub _log {
    my ($name) = @_;
    my $log = $ENV{BACKUP_TEST_LOG};
    return unless defined $log && length $log;
    open my $fh, '>>:raw', $log or die "cannot append to $log: $!";
    print {$fh} "$name\n";
    close $fh;
}
PERL

my $STUB_A_SRC = <<PERL;
package Backup::Phase::StubA;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_a', order => 100, resumable => 1, title => 'Stub A' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_a');
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

my $STUB_B_SRC = <<PERL;
package Backup::Phase::StubB;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_b', order => 200, resumable => 1, title => 'Stub B' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_b');
    my \$answer = \$ctx->{answers}{'stub_b.q1'};
    if (!defined \$answer) {
        return { status => 'needs_decision', decisions => [ \$ctx->{decision}->(
            id      => 'stub_b.q1',
            kind    => 'step_failure',
            title   => 'Continue stub_b?',
            choices => [ { id => 'yes', label => 'Yes' }, { id => 'no', label => 'No' } ],
        ) ] };
    }
    \$ctx->{note}->('received_answer', \$answer);
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

my $STUB_B_KILLER_SRC = <<PERL;
package Backup::Phase::StubB;
use strict;
use warnings;
use POSIX ();

sub phase_spec {
    return { name => 'stub_b', order => 200, resumable => 1, title => 'Stub B (killer)' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_b');
    my \$marker = \$ENV{BACKUP_TEST_KILL_MARKER};
    if (defined \$marker && length \$marker && !-e \$marker) {
        open my \$mfh, '>', \$marker or die "cannot write marker \$marker: \$!";
        close \$mfh;
        POSIX::_exit(137);
    }
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

my $STUB_TWO_SRC = <<PERL;
package Backup::Phase::StubTwo;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_two', order => 100, resumable => 1, title => 'Stub Two' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_two');
    unless (exists \$ctx->{answers}{'stub_two.q1'} && exists \$ctx->{answers}{'stub_two.q2'}) {
        return { status => 'needs_decision', decisions => [
            \$ctx->{decision}->(
                id => 'stub_two.q1', kind => 'step_failure', title => 'First?',
                choices => [ { id => 'yes', label => 'Yes' }, { id => 'no', label => 'No' } ],
            ),
            \$ctx->{decision}->(
                id => 'stub_two.q2', kind => 'step_failure', title => 'Second?',
                choices => [ { id => 'yes', label => 'Yes' }, { id => 'no', label => 'No' } ],
            ),
        ] };
    }
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

# Deliberately lacks phase_spec/run_phase. If discover_phases ever treated a
# file literally named Run.pm as a phase candidate, requiring this file would
# succeed but the subsequent ->can() checks would fail it as
# phase_load_failed -- exactly what would happen with the REAL
# scripts/backup/Run.pm sitting in the same directory in production. A run
# that completes cleanly with this file present proves the filename skip.
my $RUNPM_GUARD_SRC = <<'PERL';
package NotARealPhaseModule;
use strict;
use warnings;
1;
PERL

# =====================================================================
my $STUB_AFTER_SRC = <<PERL;
package Backup::Phase::StubAfter;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_after', order => 200, resumable => 1, title => 'Stub After' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_after');
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

my $STUB_NEVER_SRC = <<PERL;
package Backup::Phase::StubNever;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_never', order => 200, resumable => 1, title => 'Stub Never' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_never');
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

my $STUB_FAIL_SRC = <<PERL;
package Backup::Phase::StubFail;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_fail', order => 100, resumable => 1, title => 'Stub Fail' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_fail');
    return { status => 'failed', error => 'synthetic failure for AC22' };
}

$LOG_HELPER

1;
PERL

my $STUB_DIE_SRC = <<PERL;
package Backup::Phase::StubDie;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_die', order => 100, resumable => 1, title => 'Stub Die' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_die');
    die "synthetic die text for AC23\n";
}

$LOG_HELPER

1;
PERL

# Deliberately returns a MANUALLY-BUILT decision hashref (bypassing
# $ctx->{decision}, which the spec says dies on invalid input) so this
# exercises the ENGINE's own validation of an invalid kind (S2.1: "the engine
# refuses the decision"), not the constructor helper's die path.
my $STUB_BADKIND_SRC = <<PERL;
package Backup::Phase::StubBadKind;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_badkind', order => 100, resumable => 1, title => 'Stub Bad Kind' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_badkind');
    return { status => 'needs_decision', decisions => [ {
        id      => 'stub_badkind.q1',
        kind    => 'not_a_kind',
        phase   => 'stub_badkind',
        title   => 'Should never be presented',
        choices => [ { id => 'yes', label => 'Yes' }, { id => 'no', label => 'No' } ],
    } ] };
}

$LOG_HELPER

1;
PERL

my $STUB_C_SRC = <<PERL;
package Backup::Phase::StubC;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_c', order => 200, resumable => 1, title => 'Stub C' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_c');
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

# More precisely targets R4's "three unguarded write_run_state calls in and
# after the phase loop" than a bad initial state path can: this stub lets the
# RUN-START write succeed normally, then sabotages the state directory (turns
# it into a plain file) from INSIDE the phase, immediately before returning
# "complete" -- forcing the engine's OWN post-phase-completion write (the one
# that records this phase as done and advances phase_index) to fail.
my $STUB_SABOTAGE_SRC = <<PERL;
package Backup::Phase::StubSabotage;
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(remove_tree);

sub phase_spec {
    return { name => 'stub_sabotage', order => 100, resumable => 1, title => 'Stub Sabotage' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_sabotage');
    my \$state_path = \$ENV{BACKUP_RUN_STATE};
    if (defined \$state_path && length \$state_path) {
        my \$state_dir = dirname(\$state_path);
        remove_tree(\$state_dir);
        open my \$fh, '>', \$state_dir or die "cannot sabotage \$state_dir: \$!";
        close \$fh;
    }
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

my $STUB_PRINTER_SRC = <<PERL;
package Backup::Phase::StubPrinter;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_printer', order => 100, resumable => 1, title => 'Stub Printer' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_printer');
    print STDOUT "JUNK A PHASE SHOULD NEVER BE ABLE TO PUT ON THE DRIVER STDOUT\\n";
    print STDOUT "{\\"not\\":\\"the real json\\"}\\n";
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

# R6 (running half): pauses once for consent, then on the resume that
# CONSUMES the answer, dies mid-execution right after receiving it (the
# exact R6 bug scenario: answer accepted, then killed before finishing). A
# bare re-invocation must NOT silently reuse the stale answer.
my $STUB_R6_SRC = <<PERL;
package Backup::Phase::StubR6;
use strict;
use warnings;
use POSIX ();

sub phase_spec {
    return { name => 'stub_r6', order => 100, resumable => 1, title => 'Stub R6' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_r6');

    unless (defined \$ctx->{answers}{'stub_r6.confirm'}) {
        return { status => 'needs_decision', decisions => [ \$ctx->{decision}->(
            id      => 'stub_r6.confirm',
            kind    => 'push_confirmation',
            title   => 'Confirm the push?',
            choices => [ { id => 'yes', label => 'Yes' }, { id => 'no', label => 'No' } ],
        ) ] };
    }

    my \$marker = \$ENV{BACKUP_TEST_KILL_MARKER};
    if (defined \$marker && length \$marker && !-e \$marker) {
        open my \$mfh, '>', \$marker or die "cannot write marker \$marker: \$!";
        close \$mfh;
        POSIX::_exit(137);
    }

    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

# R6 (paused half, contrast): pauses TWICE for two separate decisions with no
# kill in between. Proves the FIRST answer survives being paused a second
# time for the SECOND decision -- the asymmetry with StubR6 above.
my $STUB_R6B_SRC = <<PERL;
package Backup::Phase::StubR6B;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_r6b', order => 100, resumable => 1, title => 'Stub R6B' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_r6b');

    unless (defined \$ctx->{answers}{'stub_r6b.q1'}) {
        return { status => 'needs_decision', decisions => [ \$ctx->{decision}->(
            id => 'stub_r6b.q1', kind => 'step_failure', title => 'First?',
            choices => [ { id => 'yes', label => 'Yes' }, { id => 'no', label => 'No' } ],
        ) ] };
    }
    unless (defined \$ctx->{answers}{'stub_r6b.q2'}) {
        return { status => 'needs_decision', decisions => [ \$ctx->{decision}->(
            id => 'stub_r6b.q2', kind => 'step_failure', title => 'Second?',
            choices => [ { id => 'yes', label => 'Yes' }, { id => 'no', label => 'No' } ],
        ) ] };
    }

    \$ctx->{note}->('q1_survived_second_pause', defined(\$ctx->{answers}{'stub_r6b.q1'}) ? 'yes' : 'no');
    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

# Hand-crafts a run-state file to simulate an internal inconsistency (R2) or
# an untrusted/out-of-range phase_index (R3) -- conditions a correctly
# functioning engine would never produce on its own, so they must be forced
# by writing the state file directly, exactly as the AC11 corrupt-JSON test
# does for state_corrupt.
sub craft_state_json {
    my (%o) = @_;
    my $phase_index   = $o{phase_index}   // '0';
    my $status        = $o{status}        // 'running';
    my $stub_a_status = $o{stub_a_status} // 'pending';
    my $stub_b_status = $o{stub_b_status} // 'pending';
    return <<STATEJSON;
{
  "format": 1,
  "run_id": "00112233445566ff",
  "started_at": 1,
  "updated_at": 1,
  "status": "$status",
  "phase_order": ["stub_a", "stub_b"],
  "phase_index": $phase_index,
  "phases": {
    "stub_a": { "status": "$stub_a_status", "items": {}, "scratch": {} },
    "stub_b": { "status": "$stub_b_status", "items": {}, "scratch": {} }
  },
  "token_seq": 0,
  "consumed_seq": 0,
  "pending": null,
  "answers": {},
  "notes": []
}
STATEJSON
}

# Base scenario: stub_a (completes) + stub_b (pauses for one decision).
# Exercises AC5, AC6, AC7, AC8, AC9, AC12, AC13, AC14, AC16, AC17 (part 1).
# =====================================================================
{
    my $scn_base = new_scenario('StubA.pm' => $STUB_A_SRC, 'StubB.pm' => $STUB_B_SRC);

    # ---- AC12 + AC9: fresh run, first phase pauses ----
    my $r1 = run_backup($scn_base, '--json');
    is($r1->{exit}, 10, 'AC12: a fresh run that pauses exits 10') or diag($r1->{out} . $r1->{err});
    is($r1->{json}{status}, 'needs_decision', 'AC12: status == "needs_decision"');
    is($r1->{json}{phase}, 'stub_b', 'AC12: phase == "stub_b"');
    ok(ref($r1->{json}{decisions}) eq 'ARRAY' && scalar(@{ $r1->{json}{decisions} }) > 0,
        'AC12: decisions is a non-empty array')
        or diag($r1->{out});

    if ($RUNPM_OK && ref($r1->{json}{decisions}) eq 'ARRAY') {
        for my $i (0 .. $#{ $r1->{json}{decisions} }) {
            my ($ok2, $reason) = Backup::Run::validate_decision($r1->{json}{decisions}[$i]);
            ok($ok2, "AC12: decisions[$i] passes validate_decision") or diag("reason: " . ($reason // ''));
        }
    }
    else {
        ok(0, 'AC12: decisions[0] passes validate_decision (Run.pm not loaded or decisions missing)');
    }

    my $token1 = $r1->{json}{resume_token};
    like($token1 // '', qr/^bkp1\.[0-9a-f]{16}\.1$/, 'AC12: resume_token matches the bkp1.<16hex>.<seq> grammar');

    my $state1 = read_state($scn_base->{state_path});
    ok(defined $state1, 'AC9: the run-state file exists and parses as JSON') or diag("path: $scn_base->{state_path}");
    if (defined $state1) {
        is($state1->{format}, 1, 'AC9: state format == 1');
        like($state1->{run_id} // '', qr/^[0-9a-f]{16}$/, 'AC9: state run_id is 16 lowercase hex chars');
        is($state1->{status}, 'paused', 'AC9: state status == "paused"');
        is(join(',', @{ $state1->{phase_order} // [] }), 'stub_a,stub_b',
            'AC9: phase_order == [stub_a, stub_b] in order');
        is($state1->{token_seq}, 1, 'AC9: token_seq == 1');
        is($state1->{consumed_seq}, 0, 'AC9: consumed_seq == 0');
        is($state1->{pending}{decisions}[0]{id}, 'stub_b.q1', 'AC9: pending.decisions[0].id == the emitted decision id');
    }
    else {
        ok(0, "AC9: $_") for (
            'state format == 1', 'state run_id is 16 lowercase hex chars', 'state status == "paused"',
            'phase_order == [stub_a, stub_b] in order', 'token_seq == 1', 'consumed_seq == 0',
            'pending.decisions[0].id == the emitted decision id',
        );
    }

    my $lines_after_pause = log_line_count($scn_base->{log_path});
    is($lines_after_pause, 2, '(setup) exactly stub_a and stub_b ran once each during the initial pause');

    # ---- AC5: malformed token ----
    my $r_malformed = run_backup($scn_base, '--json', '--resume', 'not-a-token', '--answer', 'stub_b.q1=yes');
    is($r_malformed->{exit}, 3, 'AC5: a malformed resume token is refused (exit 3)');
    is($r_malformed->{json}{status}, 'error', 'AC5: malformed-token refusal status == "error"');
    is($r_malformed->{json}{error}{code}, 'token_malformed', 'AC5: malformed-token refusal code == "token_malformed"');
    is(log_line_count($scn_base->{log_path}), $lines_after_pause, 'AC5: no phase body ran (log unchanged)');

    # ---- AC6: unknown token (valid grammar, wrong run_id) ----
    my $unknown_token = 'bkp1.' . ('0' x 16) . '.1';
    my $r_unknown = run_backup($scn_base, '--json', '--resume', $unknown_token, '--answer', 'stub_b.q1=yes');
    is($r_unknown->{exit}, 3, 'AC6: an unknown resume token is refused (exit 3)');
    is($r_unknown->{json}{error}{code}, 'token_unknown', 'AC6: unknown-token refusal code == "token_unknown"');
    is(log_line_count($scn_base->{log_path}), $lines_after_pause, 'AC6: no phase body ran (log unchanged)');

    # ---- AC8: bare `run` against a paused run, no --resume ----
    my $r_missing = run_backup($scn_base, '--json');
    is($r_missing->{exit}, 3, 'AC8: `run` against a paused run with no --resume is refused (exit 3)');
    is($r_missing->{json}{error}{code}, 'token_missing', 'AC8: refusal code == "token_missing"');
    is(log_line_count($scn_base->{log_path}), $lines_after_pause,
        'AC8: no phase body ran and no phase was re-run from the top (log unchanged)');

    # ---- AC16 (part 1): answer names an id that is not pending ----
    my $r_badid = run_backup($scn_base, '--json', '--resume', $token1, '--answer', 'stub_b.nosuch=yes');
    is($r_badid->{exit}, 4, 'AC16: an unknown answer id is refused (exit 4)');
    is($r_badid->{json}{error}{code}, 'answer_unknown_id', 'AC16: refusal code == "answer_unknown_id"');
    like($r_badid->{json}{error}{message} // '', qr/\Qstub_b.nosuch\E/,
        'AC16: the message names the offending id (stub_b.nosuch)');
    like($r_badid->{json}{error}{message} // '', qr/\Qstub_b.q1\E/,
        'AC16: the message lists the valid pending id (stub_b.q1)');
    my $state_after_badid = read_state($scn_base->{state_path});
    if (defined $state_after_badid) {
        is($state_after_badid->{consumed_seq}, 0, 'AC16: consumed_seq is still 0 after the refused answer');
    }
    else {
        ok(0, 'AC16: consumed_seq is still 0 after the refused answer');
    }
    is(log_line_count($scn_base->{log_path}), $lines_after_pause, 'AC16: no phase body ran for the refused answer');

    # ---- AC17 (part 1): answer names a choice that does not exist ----
    my $r_badchoice = run_backup($scn_base, '--json', '--resume', $token1, '--answer', 'stub_b.q1=maybe');
    is($r_badchoice->{exit}, 4, 'AC17: an unknown answer choice is refused (exit 4)');
    is($r_badchoice->{json}{error}{code}, 'answer_unknown_choice', 'AC17: refusal code == "answer_unknown_choice"');
    like($r_badchoice->{json}{error}{message} // '', qr/\byes\b/, 'AC17: the message names the valid choice "yes"');
    like($r_badchoice->{json}{error}{message} // '', qr/\bno\b/, 'AC17: the message names the valid choice "no"');

    # ---- AC16 (part 2): the SAME token still works after the refused answers ----
    my $r_final = run_backup($scn_base, '--json', '--resume', $token1, '--answer', 'stub_b.q1=yes');
    is($r_final->{exit}, 0, 'AC16: re-issuing the correct answer with the SAME token succeeds')
        or diag($r_final->{out} . $r_final->{err});

    # ---- AC13: resume continues; stub_a's body does not run a second time ----
    is($r_final->{json}{status}, 'complete', 'AC13: the resumed run completes (status == "complete")');
    my %counts_final = log_counts($scn_base->{log_path});
    is($counts_final{stub_a} // 0, 1, 'AC13: the phase log contains stub_a exactly once across both invocations');
    is($counts_final{stub_b} // 0, 2, 'AC13: the phase log contains stub_b exactly twice (once per entry)');

    my $state_final = read_state($scn_base->{state_path});
    if (defined $state_final) {
        is($state_final->{consumed_seq}, 1, 'AC13: consumed_seq == 1 after the successful resume');
        is($state_final->{pending}, undef, 'AC13: pending == null after the successful resume');
        is($state_final->{answers}{'stub_b.q1'}, 'yes', 'AC13: answers == {"stub_b.q1":"yes"}');
    }
    else {
        ok(0, "AC13: $_") for ('consumed_seq == 1 after the successful resume',
            'pending == null after the successful resume', 'answers == {"stub_b.q1":"yes"}');
    }

    # ---- AC14: $ctx->{answers} actually reached the resumed phase ----
    my $found_note = 0;
    for my $n (@{ $r_final->{json}{notes} // [] }) {
        $found_note = 1 if ($n->{key} // '') eq 'received_answer' && ($n->{value} // '') eq 'yes';
    }
    ok($found_note, 'AC14: the completion notes contain the answer the resumed phase received (received_answer=yes)')
        or diag($r_final->{out});

    # ---- AC7: replaying the exact command from AC13's final resume ----
    my %counts_before_replay = log_counts($scn_base->{log_path});
    my $r_replay = run_backup($scn_base, '--json', '--resume', $token1, '--answer', 'stub_b.q1=yes');
    is($r_replay->{exit}, 3, 'AC7: replaying an already-consumed token is refused (exit 3)');
    is($r_replay->{json}{status}, 'error', 'AC7: replay refusal status == "error"');
    is($r_replay->{json}{error}{code}, 'token_replayed', 'AC7: replay refusal code == "token_replayed"');
    my %counts_after_replay = log_counts($scn_base->{log_path});
    is($counts_after_replay{stub_a} // 0, $counts_before_replay{stub_a} // 0, 'AC7: replay does not re-run stub_a');
    is($counts_after_replay{stub_b} // 0, $counts_before_replay{stub_b} // 0, 'AC7: replay does not re-run stub_b');
}

# =====================================================================
# AC17 (part 2): a pending decision left unanswered (needs 2 decisions)
# =====================================================================
{
    my $scn = new_scenario('StubTwo.pm' => $STUB_TWO_SRC);

    my $r1 = run_backup($scn, '--json');
    is($r1->{exit}, 10, '(setup) a phase with two pending decisions pauses (exit 10)') or diag($r1->{out});
    my $token = $r1->{json}{resume_token};
    ok(defined $token, '(setup) a resume token was minted for the two-decision pause') or diag($r1->{out});

    my $r2 = run_backup($scn, '--json', '--resume', ($token // ''), '--answer', 'stub_two.q1=yes');
    is($r2->{exit}, 4, 'AC17: an unanswered pending decision yields exit 4');
    is($r2->{json}{error}{code}, 'answer_missing', 'AC17: unanswered-decision refusal code == "answer_missing"');
    like($r2->{json}{error}{message} // '', qr/\Qstub_two.q2\E/,
        'AC17: the message names the unanswered id (stub_two.q2)');
}

# =====================================================================
# AC15 -- killed between phases
# =====================================================================
{
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC, 'StubB.pm' => $STUB_B_KILLER_SRC);
    $scn->{kill_marker} = "$scn->{root}/kill-marker";

    my $r1 = run_backup($scn, '--json');
    is($r1->{exit}, 137, 'AC15: the first invocation exits 137 (the deterministic SIGKILL stand-in)');
    is($r1->{out}, '', 'AC15: the first invocation writes no JSON to stdout');

    my $state_after_kill = read_state($scn->{state_path});
    ok(defined $state_after_kill, 'AC15: the state file exists after the kill');
    if (defined $state_after_kill) {
        is($state_after_kill->{phases}{stub_a}{status}, 'complete',
            'AC15: state shows stub_a already complete before the kill');
    }
    else {
        ok(0, 'AC15: state shows stub_a already complete before the kill');
    }

    my $r2 = run_backup($scn, '--json');
    is($r2->{exit}, 0, 'AC15: re-invoking with no token completes the run') or diag($r2->{out} . $r2->{err});
    is($r2->{json}{status}, 'complete', 'AC15: re-invoking with no token completes the run (status complete)');

    my %counts = log_counts($scn->{log_path});
    is($counts{stub_a} // 0, 1, 'AC15: the phase log contains stub_a exactly once across both invocations');
}

# =====================================================================
# AC10 -- default run-state location (HOME/USERPROFILE-anchored)
# =====================================================================
{
    my $root = temproot();
    my $home = make_machine($root, 'home10');
    my $pdir = "$root/empty-phases";
    make_path($pdir);

    my $r = _spawn(
        {
            BACKUP_PHASE_DIR        => $pdir,
            BACKUP_RUN_STATE        => '',
            BACKUP_TEST_LOG         => "$root/log10.txt",
            BACKUP_TEST_KILL_MARKER => '',
            HOME                    => $home,
            USERPROFILE             => $home,
        },
        'run', '--json'
    );
    is($r->{exit}, 0, 'AC10: a run with BACKUP_RUN_STATE unset and HOME/USERPROFILE redirected completes')
        or diag($r->{out} . $r->{err});
    ok(path_exists("$home/.claude/.backup-driver/run.json"),
        'AC10: the state file is created at <HOME>/.claude/.backup-driver/run.json');
    ok(!path_exists("$home/.claude/ccpraxis"),
        'AC10: nothing is created under <HOME>/.claude/ccpraxis');
}

# =====================================================================
# AC11 -- a corrupt state file is refused and left untouched
# =====================================================================
{
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC);
    write_text($scn->{state_path}, "not json");
    my $before = read_text($scn->{state_path});

    my $r = run_backup($scn, '--json');
    is($r->{exit}, 1, 'AC11: a corrupt state file yields exit 1');
    is($r->{json}{status}, 'error', 'AC11: corrupt-state refusal status == "error"');
    is($r->{json}{error}{code}, 'state_corrupt', 'AC11: corrupt-state refusal code == "state_corrupt"');

    my $after = read_text($scn->{state_path});
    is($after, $before, 'AC11: the corrupt file bytes are unchanged');
    is(log_line_count($scn->{log_path}), 0, 'AC11: the phase log gains no lines (no phase body ran)');
}

# =====================================================================
# AC18 -- usage errors: --answer without --resume, and an unknown subcommand
# =====================================================================
{
    my $scn = new_scenario();

    my $r_noresume = run_backup($scn, '--json', '--answer', 'x.y=z');
    is($r_noresume->{exit}, 2, 'AC18: --answer without --resume yields exit 2');
    is($r_noresume->{json}{status}, 'error', 'AC18: --answer-without---resume status == "error"');
    is($r_noresume->{json}{error}{code}, 'usage', 'AC18: --answer-without---resume code == "usage"');

    my $r_badcmd = run_backup_raw($scn, 'not-a-real-subcommand');
    is($r_badcmd->{exit}, 2, 'AC18: an unknown subcommand yields exit 2');
    is($r_badcmd->{json}{status}, 'error', 'AC18: unknown-subcommand status == "error"');
    is($r_badcmd->{json}{error}{code}, 'usage', 'AC18: unknown-subcommand code == "usage"');
}

# =====================================================================
# =====================================================================
# AC21 <- Behavior 12: a phase emits an invalid decision kind
# =====================================================================
{
    my $scn = new_scenario('StubBadKind.pm' => $STUB_BADKIND_SRC);
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 1, 'AC21: a phase emitting kind => not_a_kind yields exit 1');
    is($r->{json}{status}, 'error', 'AC21: invalid-kind refusal status == "error"');
    is($r->{json}{error}{code}, 'decision_invalid', 'AC21: invalid-kind refusal code == "decision_invalid"');
    like($r->{json}{error}{message} // '', qr/\Qnot_a_kind\E/, 'AC21: the message names the offending kind (not_a_kind)');
    like($r->{json}{error}{message} // '', qr/\Qstub_badkind\E/, 'AC21: the message names the emitting phase (stub_badkind)');

    my $state = read_state($scn->{state_path});
    if (defined $state) {
        is($state->{pending}, undef, 'AC21: nothing is written to pending for a decision that failed validation');
    }
    else {
        ok(0, 'AC21: nothing is written to pending for a decision that failed validation');
    }
}

# =====================================================================
# AC22 <- Behavior 13: a phase returning failed does NOT abort the run
# =====================================================================
{
    my $scn = new_scenario('StubFail.pm' => $STUB_FAIL_SRC, 'StubAfter.pm' => $STUB_AFTER_SRC);
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 20, 'AC22: a run with one failed phase exits 20 (complete_with_failures)');
    is($r->{json}{status}, 'complete_with_failures', 'AC22: status == "complete_with_failures"');

    my %counts = log_counts($scn->{log_path});
    ok(($counts{stub_fail} // 0) >= 1, 'AC22: the failed phase body ran');
    ok(($counts{stub_after} // 0) >= 1, 'AC22: the NEXT phase still executed after the failure (does not abort)');

    if (ref($r->{json}{phases}) eq 'ARRAY') {
        my ($failed_entry) = grep { ($_->{name} // '') eq 'stub_fail' } @{ $r->{json}{phases} };
        ok(defined $failed_entry, 'AC22: the phases list contains an entry for stub_fail');
        is($failed_entry->{status}, 'failed', 'AC22: stub_fail is recorded with status "failed"') if defined $failed_entry;
        like($failed_entry->{error} // '', qr/\Qsynthetic failure for AC22\E/,
            'AC22: the failed phase carries its error text in the output') if defined $failed_entry;
    }
    else {
        ok(0, 'AC22: the phases list contains an entry for stub_fail');
        ok(0, 'AC22: stub_fail is recorded with status "failed"');
        ok(0, 'AC22: the failed phase carries its error text in the output');
    }
}

# =====================================================================
# AC23 <- Behavior 14: a phase that DIES aborts the run (contrast with AC22)
# =====================================================================
{
    my $scn = new_scenario('StubDie.pm' => $STUB_DIE_SRC, 'StubNever.pm' => $STUB_NEVER_SRC);
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 1, 'AC23: a phase that dies yields exit 1 (phase_died)');
    is($r->{json}{status}, 'error', 'AC23: died-phase refusal status == "error"');
    is($r->{json}{error}{code}, 'phase_died', 'AC23: died-phase refusal code == "phase_died"');
    like($r->{json}{error}{message} // '', qr/\Qstub_die\E/, 'AC23: the message names the phase (stub_die)');
    like($r->{json}{error}{message} // '', qr/\Qsynthetic die text for AC23\E/,
        'AC23: the message contains the die text');

    my %counts = log_counts($scn->{log_path});
    ok(!($counts{stub_never} // 0),
        'AC23: THE ASYMMETRY WITH AC22 -- the next phase does NOT run after a die (a died phase aborts the whole run)');

    my $state = read_state($scn->{state_path});
    is($state->{phases}{stub_die}{status}, 'failed', 'AC23: the died phase is recorded "failed" on disk')
        if defined $state;
    ok(0, 'AC23: the died phase is recorded "failed" on disk') unless defined $state;
}

# =====================================================================
# AC24 <- Behavior 16 + S2.5: --restart mints a new run and re-runs every
# phase; --restart combined with --resume is usage; --restart is the
# escape hatch past a corrupt state file.
# =====================================================================
{
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC, 'StubB.pm' => $STUB_B_SRC);

    my $r1 = run_backup($scn, '--json');
    my $state1 = read_state($scn->{state_path});
    my $run_id1 = defined $state1 ? $state1->{run_id} : undef;
    my %counts_before_restart = log_counts($scn->{log_path});

    my $r2 = run_backup($scn, '--json', '--restart');
    my $state2 = read_state($scn->{state_path});
    ok((defined $state2 && defined $run_id1 && $state2->{run_id} ne $run_id1),
        'AC24: --restart mints a NEW run_id, different from the discarded run')
        or diag('run_id1: ' . ($run_id1 // 'undef') . ', run_id2: '
            . (defined $state2 ? ($state2->{run_id} // 'undef') : 'undef (no state)'));
    is($state2->{consumed_seq}, 0, 'AC24: --restart resets consumed_seq to 0') if defined $state2;
    ok(0, 'AC24: --restart resets consumed_seq to 0') unless defined $state2;

    my %counts_after_restart = log_counts($scn->{log_path});
    ok(($counts_after_restart{stub_a} // 0) > ($counts_before_restart{stub_a} // 0),
        'AC24: --restart re-executes stub_a (an already-complete phase runs again)');
    ok(($counts_after_restart{stub_b} // 0) > ($counts_before_restart{stub_b} // 0),
        'AC24: --restart re-executes stub_b');

    my $r3 = run_backup($scn, '--json', '--restart', '--resume', 'bkp1.' . ('0' x 16) . '.1');
    is($r3->{exit}, 2, 'AC24: --restart combined with --resume is refused (exit 2, usage)');
    is($r3->{json}{status}, 'error', 'AC24: --restart+--resume refusal status == "error"');
    is($r3->{json}{error}{code}, 'usage', 'AC24: --restart+--resume refusal code == "usage"');

    # --restart is the escape hatch past a corrupt state file (spec S2.5).
    my $scn_corrupt = new_scenario('StubA.pm' => $STUB_A_SRC);
    write_text($scn_corrupt->{state_path}, "not json");
    my $r4 = run_backup($scn_corrupt, '--json', '--restart');
    is($r4->{exit}, 0, 'AC24: --restart succeeds past a corrupt state file (a fresh run is started)')
        or diag($r4->{out} . $r4->{err});
    is($r4->{json}{status}, 'complete', 'AC24: --restart-past-corruption run completes (status "complete")');
    my $state4 = read_state($scn_corrupt->{state_path});
    ok(defined $state4, 'AC24: the state file is valid JSON again after --restart overwrote the corrupt one');
}

# =====================================================================
# AC25 <- Behavior 17: a resume whose discovered phase set differs from
# the frozen phase_order yields state_phase_drift.
# =====================================================================
{
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC, 'StubB.pm' => $STUB_B_SRC);
    my $r1 = run_backup($scn, '--json');
    my $token = $r1->{json}{resume_token};

    # Same state/log paths, but a DIFFERENT phase directory: stub_b is
    # swapped out for stub_c, so the discovered phase set no longer matches
    # the phase_order frozen at run start.
    my $drift_dir = "$scn->{root}/phases-drift";
    write_text("$drift_dir/StubA.pm", $STUB_A_SRC);
    write_text("$drift_dir/StubC.pm", $STUB_C_SRC);
    my $scn_drift = { %$scn, phase_dir => $drift_dir };

    my $lines_before_drift = log_line_count($scn->{log_path});
    my $r2 = run_backup($scn_drift, '--json', '--resume', ($token // ''), '--answer', 'stub_b.q1=yes');
    is($r2->{exit}, 1, 'AC25: a resume against a changed phase set yields exit 1');
    is($r2->{json}{status}, 'error', 'AC25: phase-set-drift refusal status == "error"');
    is($r2->{json}{error}{code}, 'state_phase_drift', 'AC25: phase-set-drift refusal code == "state_phase_drift"');
    is(log_line_count($scn->{log_path}), $lines_before_drift, 'AC25: no phase body ran for the drifted resume');
}

# =====================================================================
# AC26 <- Behavior 18: --help exits 0, prints usage, creates NO state file.
# =====================================================================
{
    my $root = temproot();
    my $pdir = "$root/phases";
    make_path($pdir);
    my $scn = {
        root       => $root,
        phase_dir  => $pdir,
        state_path => "$root/does/not/exist/run.json",
        log_path   => "$root/log-help.txt",
    };

    my $r = run_backup_raw($scn, '--help');
    is($r->{exit}, 0, 'AC26: --help exits 0');
    ok(length($r->{out}) > 0, 'AC26: --help prints usage to stdout');
    ok(!path_exists($scn->{state_path}),
        'AC26: --help creates no state file, even when BACKUP_RUN_STATE points under a nonexistent directory');
}

# =====================================================================
# AC27 <- R1 (the blocker): a bare `run` against a TERMINAL state starts a
# FRESH run. Must NOT regress AC8: a bare `run` against a PAUSED run stays
# refused with token_missing -- R1 applies only to terminal runs.
# =====================================================================
{
    # ---- complete ----
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC);
    my $r1 = run_backup($scn, '--json');
    is($r1->{json}{status}, 'complete', '(setup) AC27: a single always-complete phase terminates "complete"');
    my $state1  = read_state($scn->{state_path});
    my $run_id1 = defined $state1 ? $state1->{run_id} : undef;
    my %counts_before = log_counts($scn->{log_path});

    my $r2 = run_backup($scn, '--json');
    is($r2->{exit}, 0, 'AC27: a bare run against a COMPLETE state still exits 0 (the fresh run also completes)');
    my $state2 = read_state($scn->{state_path});
    ok((defined $state2 && defined $run_id1 && $state2->{run_id} ne $run_id1),
        'AC27: a bare run against a COMPLETE state starts a fresh run (new run_id)')
        or diag('run_id1: ' . ($run_id1 // 'undef') . ', run_id2: '
            . (defined $state2 ? ($state2->{run_id} // 'undef') : 'undef (no state)'));
    my %counts_after = log_counts($scn->{log_path});
    ok(($counts_after{stub_a} // 0) > ($counts_before{stub_a} // 0),
        'AC27: the fresh run RE-EXECUTES the phase body (the assertion that actually catches the blocker)');

    # ---- complete_with_failures ----
    my $scn_f  = new_scenario('StubFail.pm' => $STUB_FAIL_SRC);
    my $rf1    = run_backup($scn_f, '--json');
    is($rf1->{json}{status}, 'complete_with_failures',
        '(setup) AC27: a single always-failing phase terminates "complete_with_failures"');
    my $statef1  = read_state($scn_f->{state_path});
    my $run_idf1 = defined $statef1 ? $statef1->{run_id} : undef;
    my %counts_before_f = log_counts($scn_f->{log_path});

    my $rf2 = run_backup($scn_f, '--json');
    is($rf2->{json}{status}, 'complete_with_failures',
        'AC27: a bare run against a COMPLETE_WITH_FAILURES state also starts fresh (status unchanged by design)');
    my $statef2 = read_state($scn_f->{state_path});
    ok((defined $statef2 && defined $run_idf1 && $statef2->{run_id} ne $run_idf1),
        'AC27: a bare run against a COMPLETE_WITH_FAILURES state starts a fresh run (new run_id)');
    my %counts_after_f = log_counts($scn_f->{log_path});
    ok(($counts_after_f{stub_fail} // 0) > ($counts_before_f{stub_fail} // 0),
        'AC27: the fresh run re-executes the failing phase body too');

    # ---- must NOT regress: bare run against a PAUSED run stays refused ----
    my $scn_p = new_scenario('StubA.pm' => $STUB_A_SRC, 'StubB.pm' => $STUB_B_SRC);
    my $rp1   = run_backup($scn_p, '--json');
    is($rp1->{json}{status}, 'needs_decision', '(setup) AC27: stub_b pauses, so this run is UNFINISHED, not terminal');
    my $rp2 = run_backup($scn_p, '--json');
    is($rp2->{exit}, 3, 'AC27: R1 must NOT regress AC8 -- a bare run against a PAUSED run is still refused (exit 3)');
    is($rp2->{json}{error}{code}, 'token_missing',
        'AC27: R1 must NOT regress AC8 -- refusal code is still "token_missing"');
}

# =====================================================================
# AC28 <- R2: `complete` must be earned -- a still-pending/running phase at
# completion time is an internal inconsistency, never a silent exit 0.
# =====================================================================
{
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC, 'StubB.pm' => $STUB_B_SRC);
    write_text($scn->{state_path},
        craft_state_json(phase_index => '2', stub_a_status => 'complete', stub_b_status => 'pending'));
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 1, 'AC28: phase_index past the end with a still-"pending" phase never exits 0 (exit 1)');
    is($r->{json}{status}, 'error', 'AC28: refusal status == "error" (pending case)');
    is($r->{json}{error}{code}, 'internal', 'AC28: refusal code == "internal" (pending case)');
}
{
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC, 'StubB.pm' => $STUB_B_SRC);
    write_text($scn->{state_path},
        craft_state_json(phase_index => '2', stub_a_status => 'complete', stub_b_status => 'running'));
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 1, 'AC28: phase_index past the end with a still-"running" phase never exits 0 (exit 1)');
    is($r->{json}{status}, 'error', 'AC28: refusal status == "error" (running case)');
    is($r->{json}{error}{code}, 'internal', 'AC28: refusal code == "internal" (running case)');
}

# =====================================================================
# AC29 <- R3: phase_index is untrusted input -- must be validated on read.
# =====================================================================
for my $case (
    { label => '-1 (negative)',        literal => '-1' },
    { label => '99 (past the end)',    literal => '99' },
    { label => '1.5 (a non-integer)',  literal => '1.5' },
    { label => '"abc" (a string)',     literal => '"abc"' },
) {
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC, 'StubB.pm' => $STUB_B_SRC);
    write_text($scn->{state_path}, craft_state_json(phase_index => $case->{literal}));
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 1, "AC29: phase_index == $case->{label} yields exit 1");
    is($r->{json}{error}{code}, 'state_corrupt', "AC29: phase_index == $case->{label} refusal code == \"state_corrupt\"");
    if ($case->{literal} eq '-1') {
        is(log_line_count($scn->{log_path}), 0,
            'AC29: phase_index == -1 does NOT execute the last phase (Perl negative-index semantics must not apply)');
    }
}

# =====================================================================
# AC30 <- R4: one JSON object on stdout holds on the die path too -- never
# exit 255 with empty stdout. Two sub-cases target two different write
# sites: (a) the RUN-START write (state parent is a plain file, so the very
# first persist attempt fails); (b) a write "in and after the phase loop"
# (R4's own wording) -- the state directory is sabotaged by the phase
# ITSELF right before it returns "complete", so the post-completion
# write_run_state specifically is what fails.
# =====================================================================
{
    # ---- (a) run-start write fails ----
    my $root = temproot();
    my $pdir = "$root/phases";
    write_text("$pdir/StubA.pm", $STUB_A_SRC);

    my $state_parent = "$root/state-blocker";
    write_text($state_parent, "I am a file, not a directory\n");
    my $state_path = "$state_parent/run.json";   # cannot exist: the parent is a plain file

    my $scn = { root => $root, phase_dir => $pdir, state_path => $state_path, log_path => "$root/log30.txt" };
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 1, 'AC30a: an uncaught internal failure at run start (state parent is not a directory) exits 1, never 255');
    ok(length($r->{out}) > 0, 'AC30a: exactly one JSON object is still written to stdout on the die path')
        or diag('stderr: ' . $r->{err});
    my $decoded = eval { decode_json($r->{out}) };
    ok(defined $decoded, 'AC30a: stdout still parses as valid JSON despite the internal failure') or diag($r->{out});
    is($r->{json}{status}, 'error', 'AC30a: status == "error"') if defined $r->{json};
    ok(0, 'AC30a: status == "error"') unless defined $r->{json};
    is($r->{json}{error}{code}, 'internal', 'AC30a: error.code == "internal"') if defined $r->{json};
    ok(0, 'AC30a: error.code == "internal"') unless defined $r->{json};
}
{
    # ---- (b) a write "in and after the phase loop" fails (R4's own wording) ----
    my $scn = new_scenario('StubSabotage.pm' => $STUB_SABOTAGE_SRC);
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 1, 'AC30b: an uncaught internal failure from a post-phase-completion write exits 1, never 255');
    ok(length($r->{out}) > 0, 'AC30b: exactly one JSON object is still written to stdout on the die path')
        or diag('stderr: ' . $r->{err});
    my $decoded = eval { decode_json($r->{out}) };
    ok(defined $decoded, 'AC30b: stdout still parses as valid JSON despite the internal failure') or diag($r->{out});
    is($r->{json}{status}, 'error', 'AC30b: status == "error"') if defined $r->{json};
    ok(0, 'AC30b: status == "error"') unless defined $r->{json};
    is($r->{json}{error}{code}, 'internal', 'AC30b: error.code == "internal"') if defined $r->{json};
    ok(0, 'AC30b: error.code == "internal"') unless defined $r->{json};
}

# =====================================================================
# AC31 <- R5: a phase writing to STDOUT must not corrupt the one-JSON
# contract.
# =====================================================================
{
    my $scn = new_scenario('StubPrinter.pm' => $STUB_PRINTER_SRC);
    my $r = run_backup($scn, '--json');
    my @lines = split /\n/, $r->{out};
    is(scalar(@lines), 1, 'AC31: stdout is exactly one line even though the phase printed junk to STDOUT')
        or diag($r->{out});
    my $decoded = eval { decode_json($r->{out}) };
    ok(defined $decoded, 'AC31: stdout still parses as exactly one JSON object') or diag($r->{out});
    is($decoded->{status}, 'complete', 'AC31: the parsed JSON is the real driver result, not the phase junk')
        if defined $decoded;
    ok(0, 'AC31: the parsed JSON is the real driver result, not the phase junk') unless defined $decoded;
}

# =====================================================================
# AC32 <- R6: re-entering after "running" clears a phase's stored answer (it
# must ask again); re-entering after "paused" PRESERVES it. Both halves of
# the asymmetry are asserted -- that asymmetry is the whole ruling.
# =====================================================================
{
    # ---- running half: mid-execution kill must not let a stale answer
    # silently authorise a second attempt ----
    my $scn = new_scenario('StubR6.pm' => $STUB_R6_SRC);
    $scn->{kill_marker} = "$scn->{root}/r6-kill-marker";

    my $r1 = run_backup($scn, '--json');
    is($r1->{json}{status}, 'needs_decision', '(setup) AC32: stub_r6 pauses for consent');
    my $token = $r1->{json}{resume_token};

    my $r2 = run_backup($scn, '--json', '--resume', ($token // ''), '--answer', 'stub_r6.confirm=yes');
    is($r2->{exit}, 137, '(setup) AC32: the phase dies immediately after receiving the consent answer');

    my $r3 = run_backup($scn, '--json');
    is($r3->{exit}, 10, 'AC32: re-entering a phase whose prior status was "running" clears its stored answer (it must ask again)');
    is($r3->{json}{status}, 'needs_decision',
        'AC32: the stale "yes" consent is NOT silently reused after a mid-execution kill');

    # ---- paused half (contrast): PRESERVES an earlier answer across being
    # paused again for a LATER decision ----
    my $scn_b = new_scenario('StubR6B.pm' => $STUB_R6B_SRC);
    my $b1 = run_backup($scn_b, '--json');
    is($b1->{json}{status}, 'needs_decision', '(setup) AC32: stub_r6b pauses for q1');
    my $token_b1 = $b1->{json}{resume_token};

    my $b2 = run_backup($scn_b, '--json', '--resume', ($token_b1 // ''), '--answer', 'stub_r6b.q1=yes');
    is($b2->{json}{status}, 'needs_decision', '(setup) AC32: stub_r6b pauses again, now for q2');
    my $token_b2 = $b2->{json}{resume_token};

    my $b3 = run_backup($scn_b, '--json', '--resume', ($token_b2 // ''), '--answer', 'stub_r6b.q2=yes');
    is($b3->{exit}, 0, 'AC32: the third resume completes');
    my $found_q1_survived = 0;
    for my $n (@{ $b3->{json}{notes} // [] }) {
        $found_q1_survived = 1 if ($n->{key} // '') eq 'q1_survived_second_pause' && ($n->{value} // '') eq 'yes';
    }
    ok($found_q1_survived,
        'AC32: re-entering after a PAUSED status PRESERVES an earlier answer (q1 survives being paused again for q2) -- the contrast with the running-clear half above');
}

# =====================================================================
# AC33 <- R7: --restart preserves the discarded state by renaming it to
# <state>.discarded-<epoch> before starting fresh, and names the saved path
# in its output.
# =====================================================================
{
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC, 'StubB.pm' => $STUB_B_SRC);
    my $r1  = run_backup($scn, '--json');
    my $old_content = read_text($scn->{state_path});
    ok(defined $old_content && length($old_content) > 0, '(setup) AC33: a real state file exists before --restart');

    my $r2 = run_backup($scn, '--json', '--restart');
    my @discarded = glob("$scn->{state_path}.discarded-*");
    ok(scalar(@discarded) >= 1, 'AC33: --restart renames the old state file to <state>.discarded-<epoch>')
        or diag("looked for: $scn->{state_path}.discarded-*");

    if (@discarded) {
        my $saved_content = read_text($discarded[0]);
        is($saved_content, $old_content, 'AC33: the discarded file holds the OLD state content, byte-identical');
    }
    else {
        ok(0, 'AC33: the discarded file holds the OLD state content, byte-identical');
    }

    if (@discarded) {
        my $whole_output = encode_json($r2->{json} // {});
        like($whole_output, qr/\Q$discarded[0]\E/,
            'AC33: the saved (discarded) path appears somewhere in the --restart output');
    }
    else {
        ok(0, 'AC33: the saved (discarded) path appears somewhere in the --restart output');
    }
}

# EXTRA (explicitly requested, not part of the numbered AC table):
# discover_phases must not treat a file literally named Run.pm as a phase.
# =====================================================================
{
    my $scn = new_scenario('StubA.pm' => $STUB_A_SRC, 'Run.pm' => $RUNPM_GUARD_SRC);
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 0, 'EXTRA: a phase dir containing a Run.pm file completes cleanly (Run.pm is not a phase)')
        or diag($r->{out} . $r->{err});
    is($r->{json}{status}, 'complete', 'EXTRA: status == "complete" with Run.pm present but not loaded as a phase');
    if (ref($r->{json}{phases}) eq 'ARRAY') {
        my @names = map { $_->{name} } @{ $r->{json}{phases} };
        is(join(',', @names), 'stub_a', 'EXTRA: only stub_a appears in the phases list; Run.pm was skipped');
    }
    else {
        ok(0, 'EXTRA: only stub_a appears in the phases list; Run.pm was skipped');
    }
}

# =====================================================================
# CONTRACT AMENDMENT (package 03 handoff, backup-driver blueprint) --
# $ctx->{get_phase_item}: a READ-ONLY, cross-phase accessor. Package 02
# (Preflight.pm) checkpoints settings_outcome under its OWN phase, and
# package 03 (settings-export-merge) needs to read it -- the existing
# get_item/is_done/checkpoint/scratch quartet is phase-scoped (bound to
# $pstate, i.e. the CURRENTLY EXECUTING phase) and cannot do that. Four
# properties, driven with two stub phases where the second reads what the
# first checkpointed:
#   1. a later phase can read an EARLIER phase's checkpointed item
#   2. undef for an unknown phase, and for a known phase + unknown key
#   3. NO AUTOVIVIFICATION: asking about a phase that never ran must not
#      create an entry for it in the on-disk state
#   4. the existing get_item stays phase-scoped (unchanged behavior)
# =====================================================================
my $STUB_CKPT_A_SRC = <<PERL;
package Backup::Phase::StubCkptA;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_ckpt_a', order => 100, resumable => 1, title => 'Stub Ckpt A' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_ckpt_a');
    \$ctx->{checkpoint}->('greeting', { hello => 'stub_ckpt_a says hi', count => 42 });

    # No-autoviv probe: this phase name is never discovered at all (no such
    # .pm file exists in this scenario), so \$state->{phases} must never
    # gain an entry for it merely because it was asked about.
    my \$ghost = \$ctx->{get_phase_item}->('phase_ghost_never_discovered', 'anything');
    \$ctx->{note}->('ghost_phase_result', defined(\$ghost) ? 'defined' : 'undef');

    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

my $STUB_CKPT_B_SRC = <<PERL;
package Backup::Phase::StubCkptB;
use strict;
use warnings;

sub phase_spec {
    return { name => 'stub_ckpt_b', order => 200, resumable => 1, title => 'Stub Ckpt B' };
}

sub run_phase {
    my (\$ctx) = \@_;
    _log('stub_ckpt_b');

    # 1. Read an item checkpointed by an earlier, DIFFERENT phase.
    my \$seen = \$ctx->{get_phase_item}->('stub_ckpt_a', 'greeting');
    if (ref(\$seen) eq 'HASH') {
        \$ctx->{note}->('cross_phase_hello', \$seen->{hello} // '(missing)');
        \$ctx->{note}->('cross_phase_count', defined(\$seen->{count}) ? "\$seen->{count}" : '(missing)');
    }
    else {
        \$ctx->{note}->('cross_phase_hello', '(not a hashref)');
        \$ctx->{note}->('cross_phase_count', '(not a hashref)');
    }

    # 2. Unknown phase name -> undef.
    my \$unknown_phase = \$ctx->{get_phase_item}->('no_such_phase', 'greeting');
    \$ctx->{note}->('unknown_phase_result', defined(\$unknown_phase) ? 'defined' : 'undef');

    # 3. Known phase, unknown key -> undef.
    my \$unknown_key = \$ctx->{get_phase_item}->('stub_ckpt_a', 'no_such_key');
    \$ctx->{note}->('unknown_key_result', defined(\$unknown_key) ? 'defined' : 'undef');

    # 4. get_item stays phase-scoped: stub_ckpt_b never checkpointed
    # 'greeting' itself, so ITS OWN get_item must not see stub_ckpt_a's item.
    my \$own_view = \$ctx->{get_item}->('greeting');
    \$ctx->{note}->('own_get_item_result', defined(\$own_view) ? 'defined' : 'undef');

    return { status => 'complete' };
}

$LOG_HELPER

1;
PERL

{
    my $scn = new_scenario('StubCkptA.pm' => $STUB_CKPT_A_SRC, 'StubCkptB.pm' => $STUB_CKPT_B_SRC);
    my $r = run_backup($scn, '--json');
    is($r->{exit}, 0, 'get_phase_item: a run using it completes cleanly')
        or diag($r->{out} . $r->{err});
    is($r->{json}{status}, 'complete', 'get_phase_item: status == "complete"');

    my %note_of;
    for my $n (@{ $r->{json}{notes} // [] }) {
        $note_of{ $n->{key} // '' } = $n->{value};
    }

    # ---- property 1: cross-phase read of an earlier phase's checkpoint ----
    is($note_of{cross_phase_hello}, 'stub_ckpt_a says hi',
        'get_phase_item: a later phase reads the exact data an earlier phase checkpointed (hello field)');
    is($note_of{cross_phase_count}, '42',
        'get_phase_item: a later phase reads the exact data an earlier phase checkpointed (count field)');

    # ---- property 2: undef for unknown phase / unknown key ----
    is($note_of{unknown_phase_result}, 'undef',
        'get_phase_item: an unknown phase name yields undef');
    is($note_of{unknown_key_result}, 'undef',
        'get_phase_item: a known phase with an unknown key yields undef');
    is($note_of{ghost_phase_result}, 'undef',
        'get_phase_item: a phase that never ran at all yields undef');

    # ---- property 4: get_item stays phase-scoped (unchanged) ----
    is($note_of{own_get_item_result}, 'undef',
        'get_phase_item addition does not change get_item: it still cannot see another phase\'s item');

    # ---- property 3: no autovivification on disk ----
    my $final_state = read_state($scn->{state_path});
    if (defined $final_state && ref($final_state->{phases}) eq 'HASH') {
        ok(!exists $final_state->{phases}{phase_ghost_never_discovered},
            'get_phase_item: no autoviv -- the on-disk state has no entry for a phase that never ran');
        ok(!exists $final_state->{phases}{no_such_phase},
            'get_phase_item: no autoviv -- the on-disk state has no entry for a second never-run phase name');
        is(join(',', sort keys %{ $final_state->{phases} }), 'stub_ckpt_a,stub_ckpt_b',
            'get_phase_item: the phases hash contains ONLY the two phases that actually ran');
    }
    else {
        ok(0, "get_phase_item: $_") for (
            'no autoviv -- the on-disk state has no entry for a phase that never ran',
            'no autoviv -- the on-disk state has no entry for a second never-run phase name',
            'the phases hash contains ONLY the two phases that actually ran',
        );
    }
}

# =====================================================================
# AC19 -- perl -c is clean on all three files
# =====================================================================
{
    my @targets = (
        [ $SCRIPT,               'scripts/backup.pl' ],
        [ $RUNPM,                'scripts/backup/Run.pm' ],
        [ "$Bin/20-backup-driver-core.t", 'this test file (20-backup-driver-core.t)' ],
    );
    for my $t (@targets) {
        my ($path, $label) = @$t;
        my ($tfh, $tfname) = tempfile(UNLINK => 1);
        close $tfh;
        my $cmd = sprintf('"%s" -c "%s" > "%s" 2>&1', $^X, $path, $tfname);
        system($cmd);
        my $rc = $? >> 8;
        my $output = read_text($tfname) // '';
        is($rc, 0, "AC19: perl -c succeeds for $label") or diag($output);
        unlike($output, qr/syntax error|Compilation failed/,
            "AC19: perl -c for $label reports no syntax error / compilation failure");
    }
}

done_testing();
