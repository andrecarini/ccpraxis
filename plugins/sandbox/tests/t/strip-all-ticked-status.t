#!/usr/bin/env perl
# platform: any
# An active package whose every drawn step is ticked has no current step, so its
# pipeline strip reads as a finished pipeline beside a live dot. On 2026-11-12 the
# operator read acxpraxis-step-2 package 15's row ("16m  spe tes imp val rev fix",
# reopened after a failed harvest with its old ticks intact) as stopped at imp.
#
#   1  a live package with every drawn step ticked says "all steps ticked" in the
#      status column (text.waiting), where the step time would go
#   2  a live worker's time still wins the status column
#   3  a package with an unticked step is unchanged: no such status
#   4  skipped / n/a steps do not count as unticked (they are blank cells)
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);

BEGIN {
    my $pin = File::Temp::tempdir(CLEANUP => 1);
    $ENV{HOME} = $pin; $ENV{USERPROFILE} = $pin; $ENV{ALMANAC_HOME} = $pin;
}

require Theme;
require tui::Layout;
require tui::Frame;
require tui::DashboardScreen;
require RunState;

my $NOW = 1_762_000_000;
my $EM  = "\xE2\x80\x94";

sub rows  { my ($runs, $w) = @_; return tui::DashboardScreen::_run_summary_lines($runs, undef, $w, $NOW); }
sub texts { my ($r) = @_; return [ map { tui::Frame::spans_text($_) } @$r ]; }

my @WORDS = ('Scout the terrain', 'Spec written', 'Tests written', 'Implementation converged',
             'Validation green', 'Review complete', 'Fix-batch applied', 'UI pass');
# pl($marks) -> RunState pipeline; one char per step: x done, ' ' todo,
# s skipped (ticked with marker), n n/a (ticked with marker).
sub pl {
    my ($marks) = @_;
    my @m = split //, $marks;
    my @l = ("---", "package: p", "status: running", "---", "# ledger", "", "## Pipeline", "");
    for my $i (0 .. $#m) {
        my ($n, $t) = ($i + 1, $WORDS[$i]);
        push @l, $m[$i] eq 'x' ? "- [x] $n. $t"
               : $m[$i] eq 's' ? "- [x] $n. $t $EM skipped: maps cleanly"
               : $m[$i] eq 'n' ? "- [x] $n. $t $EM n/a: no UI"
               :                 "- [ ] $n. $t";
    }
    return RunState::_scan_pipeline(join("\n", @l, '', '## Decisions', ''));
}
sub pkg {
    my (%o) = @_;
    return { name => $o{name}, status => 'running', attempt => 1, attempt_cap => 5,
             step => undef, steps_pending => undef, next_action => undef, agents => $o{agents} // [],
             step_word => undef, waits_on => undef, pipeline => $o{pipeline},
             coordinator_alive => 1, coordinator_started_at => $NOW - 960 };
}
sub run {
    my (@p) = @_;
    return { blueprint => 'acxpraxis-step-2', state => 'running',
             packages_done => 13, packages_total => 15, paused_reason => undef, paused_window => undef,
             relaunch_at => undef, relaunch_local => undef,
             orchestrator_pid => 41, orchestrator_alive => 1, orchestrator_started_at => $NOW - 108_960,
             running_coordinators => 1, inbox_waiting => 0, triage_waiting => 0,
             thread => { name => 'fleet', state => 'live', done => 0, total => 0, doing => [], current => undef,
                         owner => { kind => 'orchestrator', id => 'x', alive => 1 } },
             packages => \@p, run_agents => [], next_package => undef };
}
sub role_of {
    my ($line, $needle) = @_;
    for my $s (@$line) { return $s->{role} if defined $s->{text} && index($s->{text}, $needle) >= 0 }
    return undef;
}

# 1 + 4: package 15 as the operator saw it -- scout skipped, ui n/a, the rest ticked.
{
    my $r = rows([ run(pkg(name => '15-model-check-cost', pipeline => pl('sxxxxxxn'))) ]);
    my $t = texts($r);
    like($t->[1], qr/spe tes imp val rev fix\s+all steps ticked\z/,
         '1: every drawn step ticked -> "all steps ticked" after the strip') or diag(explain($t));
    is(role_of($r->[1], 'all steps ticked'), 'text.waiting', '1: in the waiting role, like the other reasons');
    unlike($t->[1], qr/\bsco\b|\bui\b/, '4: the skipped scout and n/a ui stay blank cells');
}

# 2: a live worker's time wins the status column.
{
    my $w = { id => 'w1', role => 'worker', worker_type => 'bp-architect', started_at => $NOW - 120,
              budget_seconds => 1800, stale_after_seconds => 86_400 };
    my $t = texts(rows([ run(pkg(name => '15-model-check-cost', pipeline => pl('sxxxxxxn'), agents => [$w])) ]));
    like($t->[1], qr/fix\s+2m\b/, '2: a live worker shows its time');
    unlike($t->[1], qr/all steps ticked/, '2: and the reason is not shown over it');
}

# 3: a package with a current step is unchanged.
{
    my $t = texts(rows([ run(pkg(name => '15-model-check-cost', pipeline => pl('sx     n'))) ]));
    unlike($t->[1], qr/all steps ticked/, '3: a package with an unticked step has no such status');
}

done_testing();
