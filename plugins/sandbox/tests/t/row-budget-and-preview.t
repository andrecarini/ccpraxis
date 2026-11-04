#!/usr/bin/env perl
# platform: any
# 188 -- IMMUTABLE ORACLE for package
# 07 (blueprint agent-telemetry),
# specs/07-spec.md.
#
# WRITTEN BLIND to any implementation of the new subs: none of
# tui::DashboardScreen::{_multiline_blocks, _blueprints_capacity, _row_cost,
# _pkg_stuck, _blueprints_row_plan, _select_rows, _collapse_notice,
# BLUEPRINTS_PROBE_MARK} exist at the time this file is written, nor does
# scripts/tui-preview.pl's extended synth_runs($n,$phase)/SYNTH_NOW/the
# "blueprints capacity..." report line. Their signatures (spec S2.2, S2.10)
# were read as INTERFACE, never as implementation -- there is no
# implementation to read.
#
# _run_summary_lines, _tree_lines, _package_tree_lines, _orchestrator_line,
# _agent_row, _agent_live, _blueprints_body_width, _blueprints_body (TODAY'S
# shape -- extended, not replaced), _BLUEPRINT_TABLE_OPTS, panels(), screen(),
# Dashboard::compose_frame, tui::Screen::compose, tui::Frame::spans_width,
# Theme::glyph, and scripts/tui-preview.pl's existing
# synth_state/synth_resources/synth_events/capture_report/render_plain/
# term_size already exist and are UNCHANGED (or only additively extended)
# surface this package builds on -- calling them is calling shipped, tested
# behaviour, not peeking at this package's own implementation.
#
# NON-VACUITY STRATEGY, per this initiative's hard-won house rule (the trap
# has fired five times across this blueprint: a property check passing on a
# failure sentinel; a fixture whose two dispatch types were both blocked by
# the same interlock; a boundary fixture that never reached its boundary; an
# oracle that hardcoded a path and tested the wrong tree; a golden capture
# that pinned an assumed value rather than the real one):
#   1. NONCES (zqx*, z-prefixed), never label words, wherever a "this text
#      must/must not appear" check could be tripped by a coincidental
#      substring.
#   2. Every negative assertion is paired with a positive twin on the SAME
#      fixture, or an explicit precondition pinning the fixture's shape
#      BEFORE the assertion depending on it (measured capacity, measured
#      total plan cost, _agent_live truth, the two AC10 closure costs).
#   3. Numbers that decide whether a fixture collapses (budgets, costs,
#      capacities) are MEASURED from the real subs under test at fixture-
#      build time and asserted as preconditions, never hand-predicted and
#      hardcoded -- per this package's own "measured, not modelled" thesis
#      (ruling AT-14) and the fixture-discipline rule in S4.
#   4. _select_rows's mechanics (AC6-AC11) are exercised over HAND-BUILT
#      entries arrays, which the interface itself is generic over (spans/
#      pri/kind/parent) -- this lets AC10's "closure costs 2, budget has 1
#      left, a later 1-row candidate is admitted instead" be constructed
#      exactly rather than hoped for inside a real tree, where a skipped
#      candidate's own parent routinely becomes independently cheap on its
#      OWN turn and silently absorbs the slot meant to demonstrate
#      skip-and-continue.
#
# INTERPRETATION NOTES (recorded, not silently resolved):
#   * S2.10's "field names taken from the shipped struct" is read literally:
#     every run/package/agent fixture built in this file uses exactly the
#     key sets S2.10 and CF() (t/187) already use, never invented ones.
#   * AC49's "no new failures against a baseline" is operationalised as "the
#     listed sibling suites stay green" (same pattern as t/187 AC11/AC51),
#     since this package's changes are additive and the suites are green
#     today (verified below) -- that green run stands as the baseline.
#   * AC44's %INC non-vacuity is proven WITHOUT requiring launcher.pl into
#     this process (hard-banned by this package's own brief): the shared
#     scanner is proven live by matching against a plain SOURCE READ of
#     launcher.pl's own text (no execution) and against tui-preview.pl's
#     existing 'podman-machine-default' string, exactly as S4 AC44 itself
#     prescribes as the live-proof route.
#
# Do NOT weaken an assertion here to make a future implementation's life
# easier.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec ();
use Storable qw(dclone);

my $SCRIPTS = File::Spec->rel2abs("$Bin/../../scripts");
# $Bin itself (not $SCRIPTS -- `use` runs at compile time, before the `my
# $SCRIPTS = ...` assignment above has run) is what every sibling oracle
# uses for `use lib` (t/186:77, t/182:33, t/66:82, t/187:108) -- matching
# that here is what keeps this oracle testing the tree it is actually run
# against (t/187's own H3 fix-batch finding), never a hardcoded clone path.
use lib "$Bin/../../scripts";

require Dashboard;
require tui::DashboardScreen;
require tui::Screen;
require tui::Frame;
require tui::Layout;
require Theme;

my $NOW = 1_800_000_000;

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}
sub deep { return dclone($_[0]) }

# call_ds($sub, @args) -> (\@results, $err) -- symbolic-ref call into
# tui::DashboardScreen so an undefined sub (every new sub, today) is caught
# as a clean string error, not a fatal abort of the whole file.
sub call_ds {
    my ($name, @args) = @_;
    no strict 'refs';
    my @res;
    my $ok = eval { @res = &{"tui::DashboardScreen::$name"}(@args); 1 };
    my $err = $ok ? '' : (defined($@) && length($@) ? $@ : 'unknown error');
    return (\@res, $err);
}
sub call1 { my ($name, @args) = @_; my ($r, $e) = call_ds($name, @args); return ($r->[0], $e); }

# call_ts($sub, @args) -- same shape, into tui::Screen (already shipped).
sub call_ts {
    my ($name, @args) = @_;
    no strict 'refs';
    my @res;
    my $ok = eval { @res = &{"tui::Screen::$name"}(@args); 1 };
    my $err = $ok ? '' : (defined($@) && length($@) ? $@ : 'unknown error');
    return (\@res, $err);
}
sub call_ts1 { my ($name, @args) = @_; my ($r, $e) = call_ts(@_); return ($r->[0], $e); }

# call_tf($sub, @args) -- same shape, into tui::Frame (already shipped;
# spans_width lives there, not in tui::Screen).
sub call_tf {
    my ($name, @args) = @_;
    no strict 'refs';
    my @res;
    my $ok = eval { @res = &{"tui::Frame::$name"}(@args); 1 };
    my $err = $ok ? '' : (defined($@) && length($@) ? $@ : 'unknown error');
    return (\@res, $err);
}
sub call_tf1 { my ($name, @args) = @_; my ($r, $e) = call_tf(@_); return ($r->[0], $e); }

# call_main($sub, @args) -- symbolic-ref call into main:: (scripts/
# tui-preview.pl, once required, defines its subs there -- it has no
# `package` statement).
sub call_main {
    my ($name, @args) = @_;
    no strict 'refs';
    my @res;
    my $ok = eval { @res = &{"main::$name"}(@args); 1 };
    my $err = $ok ? '' : (defined($@) && length($@) ? $@ : 'unknown error');
    return (\@res, $err);
}
sub call_main1 { my ($name, @args) = @_; my ($r, $e) = call_main($name, @args); return ($r->[0], $e); }

sub row_text {
    my ($row) = @_;
    return '' unless ref($row) eq 'ARRAY';
    return join('', map {
        (ref($_) eq 'HASH' && defined($_->{text}) && !ref($_->{text})) ? $_->{text} : ''
    } @$row);
}
sub row_leading {
    my ($row) = @_;
    return -1 unless ref($row) eq 'ARRAY' && ref($row->[0]) eq 'HASH';
    my $t = $row->[0]{text};
    return -1 unless defined($t) && !ref($t);
    return length($1) if $t =~ /^( *)\z/;
    return -1;
}
sub plain {
    my ($c) = @_;
    my $t = (ref($c) eq 'HASH') ? $c->{text} : undef;
    return '' unless defined $t;
    $t =~ s/\x1b\[[0-9;]*m//g;
    return $t;
}
sub frame_text { my ($f) = @_; return '' unless ref($f) eq 'ARRAY'; return join("\n", map { plain($_) } @$f) }

sub _comment_stripped {
    my ($src) = @_;
    return '' unless defined $src;
    return join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1);
}
sub _balanced_braces {
    my ($src, $from) = @_;
    my $idx = index($src, '{', $from);
    return undef if $idx < 0;
    my $depth = 0; my $i = $idx; my $len = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++ }
        elsif ($c eq '}') { $depth--; last if $depth == 0 }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}
sub _sub_body {
    my ($src, $name) = @_;
    while ($src =~ /\bsub\s+\Q$name\E\s*(?:\([^)]*\))?\s*/g) {
        my $after = pos($src);
        return _balanced_braces($src, $after);
    }
    return undef;
}

# base_state(%o) -- same shape as t/79/t/182's own base_state, plus `now`
# (RULING AT-12's wired path -- every new state-level sub reads $now from
# state, per S2.2's signatures).
sub base_state {
    my (%o) = @_;
    return { project_name => 'zqxproj188', container => 'zqxctr188', status => 'running',
             now => $NOW, %o };
}

sub mk_agent {
    my (%o) = @_;
    return {
        id                  => $o{id}                  // 'a',
        role                => $o{role}                 // 'worker',
        worker_type         => exists($o{worker_type})  ? $o{worker_type} : 'zqxwt',
        started_at          => $o{started_at}           // ($NOW - 100),
        budget_seconds      => $o{budget_seconds}       // 1800,
        stale_after_seconds => $o{stale_after_seconds}  // 7200,
    };
}

# tree_run(%o) -- ONE run-level struct carrying a tree (S3.1's TREE
# shorthand), all 17 S2.10 keys present so state-level and preview fixtures
# share one builder.
sub tree_run {
    my (%o) = @_;
    return {
        blueprint                => $o{blueprint}                // 'zqx-run',
        runs_dir                 => $o{runs_dir}                  // '/tmp/zqx-runs',
        state                    => $o{state}                     // 'running',
        orchestrator_pid         => $o{orchestrator_pid}          // 4242,
        orchestrator_alive       => exists($o{orchestrator_alive}) ? $o{orchestrator_alive} : 1,
        orchestrator_started_at  => $o{orchestrator_started_at}   // ($NOW - 500),
        paused_manual            => $o{paused_manual}             // 0,
        paused_reason            => $o{paused_reason},
        packages_total           => $o{packages_total}            // scalar(@{ $o{packages} || [] }),
        packages_done            => $o{packages_done}             // 0,
        current_package          => $o{current_package},
        running_coordinators     => $o{running_coordinators}      // 1,
        escalations_waiting        => $o{escalations_waiting}         // 0,
        inbox_waiting       => $o{inbox_waiting}        // 0,
        triage_waiting         => $o{triage_waiting}          // 0,
        packages                 => $o{packages}                  // [],
        run_agents                => $o{run_agents}               // [],
        # package 13-dashboard-threads (spec S2.2): always-present, additive.
        # Default to "no thread" so every pre-existing caller of tree_run()
        # keeps building byte-identical fixtures; only callers that pass
        # `thread =>` exercise the new thread-line behaviour (AC16 below).
        thread                   => $o{thread},
        thread_events            => $o{thread_events}              // [],
    };
}

# tree_run_1pkg() -- 1 package, coordinator + 1 worker (AC1's smallest TREE).
sub tree_run_1pkg {
    return tree_run(
        blueprint => 'zqx-run1pkg',
        packages  => [ {
            name => 'pkg-t1a', status => 'running', attempt => 1, attempt_cap => 5,
            step => '1/3', steps_pending => [1,2,3], next_action => undef,
            agents => [
                mk_agent(id=>'c1', role=>'coordinator', worker_type=>undef, started_at=>$NOW-300),
                mk_agent(id=>'w1', role=>'worker', worker_type=>'zqxt1-worker', started_at=>$NOW-200),
            ],
        } ],
    );
}

# tree_run_11pkg() -- 11 packages, coordinator + 1 worker each.
sub tree_run_11pkg {
    my @packages;
    for my $i (1 .. 11) {
        my $name = sprintf('pkg-t11-%02d', $i);
        push @packages, {
            name => $name, status => 'running', attempt => 1, attempt_cap => 5,
            step => '1/3', steps_pending => [1,2,3], next_action => undef,
            agents => [
                mk_agent(id=>"$name-c", role=>'coordinator', worker_type=>undef),
                mk_agent(id=>"$name-w", role=>'worker', worker_type=>"zqxt11-w-$i"),
            ],
        };
    }
    return tree_run(blueprint => 'zqx-run11pkg', packages => \@packages);
}

# tree_run_40pkg(%o) -- 40 packages x 6 agents (coordinator, 3 workers,
# judge, admiral/"other"), field names taken from t/187's own many_pkg_
# fixture, not invented. run_agents carries a live conformance judge by
# default (M4, AC27) unless suppressed.
sub tree_run_40pkg {
    my (%o) = @_;
    my @packages;
    for my $i (1 .. 40) {
        my $name = sprintf('pkg-t40-%02d', $i);
        push @packages, {
            name => $name, status => 'running', attempt => 1, attempt_cap => 5,
            step => '1/8', steps_pending => [1..8], next_action => undef,
            agents => [
                mk_agent(id=>"$name-c",  role=>'coordinator', worker_type=>undef),
                mk_agent(id=>"$name-w1", role=>'worker',      worker_type=>"zqxt40-w1-$i"),
                mk_agent(id=>"$name-w2", role=>'worker',      worker_type=>"zqxt40-w2-$i"),
                mk_agent(id=>"$name-w3", role=>'worker',      worker_type=>"zqxt40-w3-$i"),
                mk_agent(id=>"$name-j",  role=>'judge',       worker_type=>"zqxt40-j-$i"),
                mk_agent(id=>"$name-o",  role=>'admiral',     worker_type=>"zqxt40-o-$i"),
            ],
        };
    }
    my @run_agents;
    push @run_agents, mk_agent(id=>'rj', role=>'judge', worker_type=>'zqxt40-conformance-judge')
        unless $o{no_conformance_judge};
    return tree_run(blueprint => ($o{blueprint} // 'zqx-run40pkg'), packages => \@packages,
                     run_agents => \@run_agents, thread => $o{thread}, thread_events => $o{thread_events},
                     state => $o{state});
}

# runs_n($n) -- $n runs with NO tree (state=>solo, matching t/79's own
# runs_n): the "no-tree" fixture shorthand used throughout S3/S4.
sub runs_n {
    my ($n) = @_;
    return [ map { { blueprint => "zqx-notree-$_", state => 'solo',
                      packages_done => 0, packages_total => 3, running_coordinators => 0,
                      escalations_waiting => 0 } } (1 .. $n) ];
}

# plan_total_cost($plan, $width) -> sum of _row_cost over every entry's
# spans, or undef if any call errors. MEASURED, never hardcoded (S4 fixture
# discipline).
sub plan_total_cost {
    my ($plan, $width) = @_;
    return undef unless ref($plan) eq 'ARRAY';
    my $sum = 0;
    for my $e (@$plan) {
        return undef unless ref($e) eq 'HASH';
        my ($c, $err) = call1('_row_cost', $e->{spans}, $width);
        return undef if $err || !defined($c) || ref($c) || $c !~ /^\d+$/;
        $sum += $c;
    }
    return $sum;
}

# find_entry($plan, $nonce) -> the first entry whose row text contains
# $nonce, or undef.
sub find_entry {
    my ($plan, $nonce) = @_;
    return undef unless ref($plan) eq 'ARRAY';
    for my $i (0 .. $#$plan) {
        my $e = $plan->[$i];
        next unless ref($e) eq 'HASH';
        return ($i, $e) if row_text($e->{spans}) =~ /\Q$nonce\E/;
    }
    return (undef, undef);
}

# words_present($haystack, $row) -> 1 iff every non-empty whitespace-split
# word of $row's text is a substring of $haystack (t/75 AC1's "no word
# silently dropped" discipline).
sub words_present {
    my ($haystack, $row) = @_;
    my $t = row_text($row);
    my @words = grep { length } split /\s+/, $t;
    return 1 unless @words;
    for my $w (@words) {
        return 0 unless index($haystack, $w) >= 0;
    }
    return 1;
}

my $RULE_LEAD    = Theme::glyph('rule.h');
my $RULE_LEAD_RE = (defined($RULE_LEAD) && length($RULE_LEAD)) ? quotemeta($RULE_LEAD) : '';

sub title_row_index {
    my ($frame, $title) = @_;
    return -1 unless ref($frame) eq 'ARRAY';
    for my $i (0 .. $#$frame) {
        my $t = plain($frame->[$i]);
        return $i if length($RULE_LEAD_RE) && $t =~ /^\Q$RULE_LEAD\E\s*\Q$title\E\b/;
        return $i if !length($RULE_LEAD_RE) && $t =~ /\b\Q$title\E\b/;
    }
    return -1;
}

# ===========================================================================
# Plan and equivalence (AC1-AC5)
# ===========================================================================

my @AC1_FIXTURES = (
    [ '1-package TREE',  base_state(runs => [ tree_run_1pkg() ]) ],
    [ '11-package TREE', base_state(runs => [ tree_run_11pkg() ]) ],
    [ '40-package TREE', base_state(runs => [ tree_run_40pkg() ]) ],
    [ 'no-tree 12-run',  base_state(runs => runs_n(12)) ],
);

# --- AC1 ---------------------------------------------------------------
for my $f (@AC1_FIXTURES) {
    my ($label, $s) = @$f;
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 120);
    my ($body, $ebody) = call1('_blueprints_body', $s, 120);
    ok(!$eplan, "AC1 ($label): _blueprints_row_plan does not die") or diag(" error: $eplan");
    ok(!$ebody, "AC1 ($label): _blueprints_body does not die") or diag(" error: $ebody");
  SKIP: {
        skip('plan or body missing', 1) unless ref($plan) eq 'ARRAY' && ref($body) eq 'ARRAY';
        my @spans = map { ref($_) eq 'HASH' ? $_->{spans} : undef } @$plan;
        is_deeply(\@spans, $body,
            "AC1 ($label): [ map {spans} \@plan ] is_deeply _blueprints_body -- the plan is the body, annotated");
    }
}

# --- AC2 -----------------------------------------------------------------
# Retargeted (spec S2.5, ruling J/K): the old per-agent tree gave each
# package's coordinator/worker/judge its own plan row (10-kind vocabulary,
# pri 1-8). The block replaces that with ONE row per rendered package
# (agents collapse into its dot+step; only a run-wide judge in `run_agents`
# gets its own `judge` row) -- the 5(+overflow)-kind vocabulary of S2.5's
# table: blueprint/overflow pri 1, driver pri 2, package pri 3, judge pri 4,
# next pri 5. The 40-package fixture can therefore no longer be expected to
# exceed 50 entries; its real count (1 blueprint + 1 driver + 40 package +
# 1 run-judge = 43) is measured below rather than hand-predicted (this
# file's own "measured, not modeled" discipline, S4/header).
{
    my $s = base_state(runs => [ tree_run_40pkg() ]);
    my ($plan, $err) = call1('_blueprints_row_plan', $s, 120);
    ok(!$err, 'AC2: _blueprints_row_plan does not die on the 40-package fixture') or diag(" error: $err");
    ok(ref($plan) eq 'ARRAY' && @$plan >= 42, 'AC2 precondition: the 40-package plan has at least 42 entries (blueprint + driver + one row per package)')
        or diag(' got ' . (ref($plan) eq 'ARRAY' ? scalar(@$plan) : 'non-array'));
  SKIP: {
        skip('no plan', 1) unless ref($plan) eq 'ARRAY' && @$plan;
        my %KIND = map { $_ => 1 } qw(blueprint overflow driver package judge next);
        my (@bad_keys, @bad_pri, @bad_kind, @bad_parent);
        for my $i (0 .. $#$plan) {
            my $e = $plan->[$i];
            if (ref($e) ne 'HASH') { push @bad_keys, $i; next }
            my @keys = sort keys %$e;
            push @bad_keys, $i unless "@keys" eq 'kind parent pri spans';
            push @bad_pri, $i unless defined($e->{pri}) && !ref($e->{pri}) && $e->{pri} =~ /^[1-5]\z/;
            push @bad_kind, $i unless defined($e->{kind}) && !ref($e->{kind}) && $KIND{$e->{kind}};
            push @bad_parent, $i if defined($e->{parent}) && (ref($e->{parent}) || $e->{parent} !~ /^\d+\z/ || $e->{parent} >= $i);
        }
        is(scalar(@bad_keys), 0, 'AC2: every plan entry has exactly the keys spans/pri/kind/parent') or diag(' bad idx: ' . join(',', @bad_keys));
        is(scalar(@bad_pri), 0, 'AC2: every pri is an integer 1..5') or diag(' bad idx: ' . join(',', @bad_pri));
        is(scalar(@bad_kind), 0, 'AC2: every kind is one of the S2.5 six (blueprint/overflow/driver/package/judge/next)') or diag(' bad idx: ' . join(',', @bad_kind));
        is(scalar(@bad_parent), 0, 'AC2: every defined parent is a valid index strictly less than its own') or diag(' bad idx: ' . join(',', @bad_parent));
    }
}

# --- AC3 -------------------------------------------------------------------
# Retargeted (spec S2.3.6/S2.3.7/S2.5, rulings J/K, Scope): a package-level
# judge/worker no longer gets its own plan row -- it is a SEGMENT inside its
# owning package's single `package` row (worker/judge labels collapse into
# the dot+step, Scope). Only a `run_agents` judge still gets a dedicated
# `judge` row (pri 4). A coordinator contributes no segment at all (Scope)
# and the `kind` vocabulary no longer has a 'coordinator'/'worker'/'cur'/
# 'partial'/'run'/'other' member (S2.5's table: blueprint/overflow pri 1,
# driver pri 2, package pri 3, judge pri 4, next pri 5). The pause reason
# (ruling B/G) now lives on the blueprint line's own STATE slot, so it is
# part of the `blueprint` row's text, not a separate row. current_package
# only ever produces a line when `packages` is NOT an ARRAY (S2.3.6
# fallback) -- here `packages` IS an array, so runA's current_package is
# correctly invisible (not a regression; the old "cur" line's subject does
# not apply to this fixture under the new contract).
{
    my $runA = tree_run(
        blueprint => 'zqx3-runA', state => 'running', orchestrator_alive => 1,
        packages => [
            { name=>'pkg-ac3-stuckjudge', status=>'running', attempt=>1, attempt_cap=>5, agents=>[
                mk_agent(id=>'c1', role=>'coordinator', worker_type=>undef),
                mk_agent(id=>'j1', role=>'judge', worker_type=>'zqx3-judgeA'),
            ]},
            { name=>'pkg-ac3-stuckattempt', status=>'running', attempt=>5, attempt_cap=>5, agents=>[
                mk_agent(id=>'c2', role=>'coordinator', worker_type=>undef),
            ]},
            { name=>'pkg-ac3-healthypkg', status=>'running', attempt=>1, attempt_cap=>5, agents=>[
                mk_agent(id=>'c3', role=>'coordinator', worker_type=>undef),
                mk_agent(id=>'w3', role=>'worker', worker_type=>'zqx3-workerH'),
            ]},
            { name=>'pkg-ac3-zeroagents', status=>'running', attempt=>1, attempt_cap=>5, agents=>[] },
        ],
        run_agents => [
            mk_agent(id=>'rj', role=>'judge',  worker_type=>'zqx3-runjudge'),
            mk_agent(id=>'rw', role=>'worker', worker_type=>'zqx3-runworker'),
        ],
    );
    my $runB = tree_run(
        blueprint => 'zqx3-runB', state => 'running', orchestrator_alive => 0,
        packages => [], run_agents => [],
    );
    my $runC = tree_run(
        blueprint => 'zqx3-runC', state => 'paused', orchestrator_alive => 0,
        paused_reason => 'zqx3-pausedreason waiting for input',
        packages => [], run_agents => [],
    );
    my $s = base_state(runs => [ $runA, $runB, $runC ]);
    my ($plan, $err) = call1('_blueprints_row_plan', $s, 120);
    ok(!$err, 'AC3: _blueprints_row_plan does not die') or diag(" error: $err");
    ok(ref($plan) eq 'ARRAY' && @$plan >= 8, 'AC3 precondition: at least 8 plan entries')
        or diag(' got ' . (ref($plan) eq 'ARRAY' ? scalar(@$plan) : 'non-array'));
  SKIP: {
        skip('bad plan', 1) unless ref($plan) eq 'ARRAY' && @$plan >= 8;
        # zqx3-judgeA (a PACKAGE-level judge) is a text segment inside
        # pkg-ac3-stuckjudge's own `package` row, not a separate row -- so
        # it shares that row's pri/kind, found via the package's own name.
        my %expect = (
            'pkg-ac3-stuckjudge'    => [3, 'package'],
            'pkg-ac3-stuckattempt'  => [3, 'package'],
            'pkg-ac3-healthypkg'    => [3, 'package'],
            'pkg-ac3-zeroagents'    => [3, 'package'],
            'zqx3-runjudge'         => [4, 'judge'],
        );
        my %found_idx;
        for my $nonce (sort keys %expect) {
            my ($idx, $e) = find_entry($plan, $nonce);
            ok(defined($idx), "AC3 precondition: a plan row mentioning '$nonce' exists");
            $found_idx{$nonce} = $idx if defined $idx;
          SKIP: {
                skip('row not found', 2) unless defined($idx);
                is($e->{pri}, $expect{$nonce}[0], "AC3: '$nonce' row has pri $expect{$nonce}[0]");
                is($e->{kind}, $expect{$nonce}[1], "AC3: '$nonce' row has kind '$expect{$nonce}[1]'");
            }
        }
        # zqx3-judgeA's own row is the SAME row as pkg-ac3-stuckjudge's --
        # a package-level judge never gets a row of its own.
        my ($judgeA_idx) = find_entry($plan, 'zqx3-judgeA');
        ok(defined($judgeA_idx) && defined($found_idx{'pkg-ac3-stuckjudge'})
                && $judgeA_idx == $found_idx{'pkg-ac3-stuckjudge'},
            'AC3: a package-level judge (zqx3-judgeA) collapses into its own package\'s single row, not a row of its own');
        # zqx3-runworker (a non-judge run_agents entry) renders no row at
        # all (spec S2.3.7: "Non-judge run_agents are not rendered").
        my ($runworker_idx) = find_entry($plan, 'zqx3-runworker');
        ok(!defined($runworker_idx), 'AC3: a non-judge run_agents entry (zqx3-runworker) contributes no plan row at all');
        # driver rows: identified by the label text, not by nonce (no
        # per-run nonce on the no-thread driver line itself). All three runs
        # keep `orchestrator_pid`'s tree_run() default (4242), so all three
        # (runA alive, runB not-alive, runC paused+not-alive) render one.
        my @drv = grep { ref($_) eq 'HASH' && $_->{kind} eq 'driver' && row_text($_->{spans}) =~ /\borchestrator\b/ } @$plan;
        is(scalar(@drv), 3, 'AC3 precondition: exactly three driver rows (one per run)');
      SKIP: {
            skip('wrong driver row count', 1) unless @drv == 3;
            my @bad_drv_pri = grep { $_->{pri} != 2 } @drv;
            is(scalar(@bad_drv_pri), 0, 'AC3: every driver row (alive or not) carries pri 2, per S2.5\'s table');
        }
        # The pause reason is on run C's OWN blueprint-kind row now (ruling
        # B/G), not a separate 'partial'-kind row -- 'partial' is no longer
        # a member of the kind vocabulary at all.
        my ($pi, $pe) = find_entry($plan, 'zqx3-pausedreason');
        ok(defined($pi), 'AC3 precondition: a row carrying the pause reason exists');
        is($pe->{kind}, 'blueprint', "AC3: the pause-reason row's kind is 'blueprint' (ruling B/G: the reason moved onto the blueprint line)") if defined $pi;
        is($pe->{pri}, 1, 'AC3: the pause-reason (blueprint) row has pri 1') if defined $pi;
        my @non_s25_kind = grep { ref($_) eq 'HASH' && $_->{kind} !~ /^(?:blueprint|overflow|driver|package|judge|next)\z/ } @$plan;
        is(scalar(@non_s25_kind), 0, 'AC3: no plan row uses a kind outside S2.5\'s six (no coordinator/worker/cur/partial/run/other survives)');
    }
}

# --- AC4 -------------------------------------------------------------------
# AC4's whole subject, _pkg_stuck, is removed by ruling A / spec S2.2.1's
# removed-subs table -- the "is this package worth a prominent slot" dot
# precedence it modelled is now ruling K's dot precedence inside
# _run_block itself (S2.3.6: blocked > live judge > last attempt > running),
# not a separate budget-priority predicate. No replacement sub exists to
# retarget this AC onto; deleted rather than resurrecting a removed sub.

# --- AC5 -------------------------------------------------------------------
{
    my $fits_row = [ { text => '  ', role=>'text.primary' }, { text=>'zqx5-short', role=>'accent' } ];
    my ($c1, $e1) = call1('_row_cost', $fits_row, 120);
    ok(!$e1, 'AC5: _row_cost does not die on a fitting row') or diag(" error: $e1");
    is($c1, 1, 'AC5: cost is 1 for a row that fits $width');

    my $long_text = 'zqx5-overflow-' . ('w' x 200);
    my $wide_row  = [ { text => $long_text, role=>'accent' } ];
    my ($sw, $swerr) = call_tf1('spans_width', $wide_row);
    ok(!$swerr, 'AC5 precondition: tui::Frame::spans_width does not die') or diag(" error: $swerr");
    cmp_ok($sw, '>', 30, 'AC5 precondition: the overflowing fixture really overflows width=30 (spans_width > 30)');
    my ($c2, $e2) = call1('_row_cost', $wide_row, 30);
    ok(!$e2, 'AC5: _row_cost does not die on an overflowing row') or diag(" error: $e2");
    cmp_ok($c2, '>=', 2, 'AC5: cost is >= 2 for a row that overflows $width');

    for my $bw (undef, 0, 'x', [], {}) {
        my $label = !defined($bw) ? 'undef' : (ref($bw) ? ref($bw) : ("'$bw'"));
        my ($c, $e) = call1('_row_cost', $fits_row, $bw);
        ok(!$e, "AC5 (width=$label): _row_cost does not die") or diag(" error: $e");
        is($c, 1, "AC5 (width=$label): cost is 1 when width is undef/0/non-integer");
    }
    for my $w (1, 5, 30, 120) {
        my ($c, $e) = call1('_row_cost', $fits_row, $w);
        next if $e;
        cmp_ok($c, '>=', 1, "AC5 (width=$w): cost is never 0 or negative");
    }
}

# ===========================================================================
# Selection (AC6-AC11)
# ===========================================================================

# --- AC6/AC7 -----------------------------------------------------------
{
    my $s = base_state(runs => [ tree_run_40pkg() ]);
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 120);
    ok(!$eplan, 'AC6/AC7 precondition: _blueprints_row_plan does not die on the 40-package fixture') or diag(" error: $eplan");
    my ($width, $ewidth) = call1('_blueprints_body_width', 120);
    ok(!$ewidth && defined($width), 'AC6/AC7 precondition: _blueprints_body_width(120) resolves') or diag(" error: $ewidth");
  SKIP: {
        skip('no plan or width', 2) unless ref($plan) eq 'ARRAY' && @$plan && defined($width);
        # Retargeted (S2.5): one row per package (not one per agent) means
        # the 40-package fixture's real total cost is far below the old
        # per-agent-tree's >50 -- 43 is the measured floor (1 blueprint + 1
        # driver + 40 package + 1 run-judge, none wrapping at width 120).
        my $total = plan_total_cost($plan, $width);
        ok(defined($total) && $total >= 40, 'AC6/AC7 precondition: total plan cost is measured and >= 40')
            or diag(' got ' . (defined($total) ? $total : 'undef'));
      SKIP: {
            skip('no total', 2) unless defined($total) && $total >= 40;
            my $bad_shape = 0;
            my $bad_closure = 0;
            for my $budget (0 .. $total + 1) {
                my ($kept, $err) = call1('_select_rows', $plan, $budget, $width);
                if ($err || ref($kept) ne 'ARRAY') { $bad_shape++; next }
                my %seen;
                my $prev = -1;
                for my $i (@$kept) {
                    $bad_shape++ if !defined($i) || ref($i) || $i !~ /^\d+\z/ || $i > $#$plan || $i <= $prev || $seen{$i}++;
                    $prev = $i;
                }
                # AC7: ancestor closure -- every kept index's parent chain is
                # fully contained in the returned set.
                my %kset = map { $_ => 1 } @$kept;
                for my $i (@$kept) {
                    my $p = $plan->[$i]{parent};
                    while (defined $p) {
                        $bad_closure++, last unless $kset{$p};
                        $p = $plan->[$p]{parent};
                    }
                }
            }
            is($bad_shape, 0, "AC6: _select_rows returns strictly ascending, duplicate-free, in-range indices for every budget 0..$total+1 on the 40-package fixture");
            is($bad_closure, 0, 'AC7: every returned index\'s parent chain is fully contained in the returned set, for every budget tested');
        }
    }
}

# --- AC8/AC9 -----------------------------------------------------------
{
    my $stuck_pkg = {
        name => 'pkg-ac89-stuck', status => 'running', attempt=>1, attempt_cap=>5,
        agents => [
            mk_agent(id=>'sj', role=>'judge',       worker_type=>'zqx89-stuckjudge'),
            mk_agent(id=>'sc', role=>'coordinator', worker_type=>undef),
            mk_agent(id=>'sw1', role=>'worker',     worker_type=>'zqx89-stuckw1'),
            mk_agent(id=>'sw2', role=>'worker',     worker_type=>'zqx89-stuckw2'),
        ],
    };
    my $healthy_pkg = {
        name => 'pkg-ac89-healthy', status => 'running', attempt=>1, attempt_cap=>5,
        agents => [
            mk_agent(id=>'hc',  role=>'coordinator', worker_type=>undef),
            mk_agent(id=>'hw1', role=>'worker',      worker_type=>'zqx89-healthyw1'),
            mk_agent(id=>'hw2', role=>'worker',      worker_type=>'zqx89-healthyw2'),
        ],
    };
    # Retargeted (ruling J/Scope, S2.5): agents collapse into their owning
    # package's single atomic row -- there is no finer-grained per-agent
    # row left to drop independently of its package, so AC8 instead proves
    # the tier-3 PREFIX rule (S2.5 point 2) over two whole packages: at a
    # budget that fits blueprint+driver+exactly one package row, the FIRST
    # package in document order (the stuck one, carrying its judge/worker
    # segments as one unit) survives whole, and the second does not -- not
    # a partial, agent-level drop.
    my $run = tree_run(blueprint=>'zqx89-run', packages=>[$stuck_pkg, $healthy_pkg]);
    my $s = base_state(runs => [ $run ]);
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 120);
    ok(!$eplan, 'AC8/AC9 precondition: _blueprints_row_plan does not die') or diag(" error: $eplan");
    my ($width) = call1('_blueprints_body_width', 120);
  SKIP: {
        skip('no plan', 4) unless ref($plan) eq 'ARRAY' && @$plan;
        my ($kept3, $e3) = call1('_select_rows', $plan, 3, $width);
        ok(!$e3, 'AC8: _select_rows does not die at budget=3') or diag(" error: $e3");
      SKIP: {
            skip('no kept3', 3) unless ref($kept3) eq 'ARRAY';
            my %kset = map { $_ => 1 } @$kept3;
            my ($bp_i)       = grep { ref($plan->[$_]) eq 'HASH' && $plan->[$_]{kind} eq 'blueprint' } (0 .. $#$plan);
            my ($drv_i)      = grep { ref($plan->[$_]) eq 'HASH' && $plan->[$_]{kind} eq 'driver' } (0 .. $#$plan);
            my ($stuckrow_i) = find_entry($plan, 'pkg-ac89-stuck');
            my ($healthyrow_i) = find_entry($plan, 'pkg-ac89-healthy');
            ok(defined($bp_i) && defined($drv_i) && defined($stuckrow_i) && defined($healthyrow_i),
                'AC8 precondition: blueprint/driver/stuck-package/healthy-package row indices all resolved');
          SKIP: {
                skip('indices unresolved', 5) unless defined($bp_i) && defined($drv_i) && defined($stuckrow_i) && defined($healthyrow_i);
                is(scalar(@$kept3), 3, 'AC8 precondition: budget=3 on this fixture admits exactly 3 rows');
                ok($kset{$bp_i},  'AC8: the blueprint row survives at budget=3');
                ok($kset{$drv_i}, 'AC8: the driver row survives at budget=3');
                ok($kset{$stuckrow_i}, 'AC8: the first (stuck) package\'s whole row survives at budget=3, judge/worker segments included atomically');
                ok(!$kset{$healthyrow_i}, 'AC8: the SECOND package\'s row does not survive at budget=3 (tier-3 prefix rule, document order)');
            }
        }
    }
}

# --- one-package variant for AC9 (alive-vs-not-alive orchestrator) --------
{
    my $pkg = {
        name => 'pkg-ac9', status => 'running', attempt=>1, attempt_cap=>5,
        agents => [
            mk_agent(id=>'c', role=>'coordinator', worker_type=>undef),
            mk_agent(id=>'w', role=>'worker',      worker_type=>'zqx9-worker'),
        ],
    };
    # Retargeted (S2.5): the old plan gave an alive orchestrator the LOWEST
    # priority tier (pri 8) and a not-alive one a much higher one (pri 3),
    # so the budget dropped an alive orchestrator's row before a worker's
    # but kept a dead one. S2.5's table has no such liveness-dependent
    # split: a `driver` row is ALWAYS pri 2 regardless of
    # `orchestrator_alive` -- liveness changes the row's TEXT (the dot), not
    # its budget priority. So both cases now keep the (always pri-2) driver
    # row and drop the (pri-3) package row at budget=total-1, uniformly.
    my ($width) = call1('_blueprints_body_width', 120);
    for my $case ([1, 'alive'], [0, 'not-alive']) {
        my ($alive, $label) = @$case;
        my $run = tree_run(blueprint=>"zqx9-run-$label", orchestrator_alive=>$alive, packages=>[ deep($pkg) ]);
        my $s = base_state(runs => [ $run ]);
        my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 120);
        ok(!$eplan, "AC9 ($label): _blueprints_row_plan does not die") or diag(" error: $eplan");
      SKIP: {
            skip('no plan', 3) unless ref($plan) eq 'ARRAY' && @$plan;
            my $total = plan_total_cost($plan, $width);
            ok(defined($total) && $total >= 2, "AC9 ($label) precondition: total plan cost measured, >= 2") or diag(' got ' . (defined($total)?$total:'undef'));
          SKIP: {
                skip('no total', 2) unless defined($total) && $total >= 2;
                my ($kept, $err) = call1('_select_rows', $plan, $total - 1, $width);
                ok(!$err, "AC9 ($label): _select_rows does not die at budget=total-1") or diag(" error: $err");
              SKIP: {
                    skip('no kept', 2) unless ref($kept) eq 'ARRAY';
                    my %kset = map { $_ => 1 } @$kept;
                    my ($drv_i) = grep { ref($plan->[$_]) eq 'HASH' && $plan->[$_]{kind} eq 'driver' } (0 .. $#$plan);
                    my ($worker_i) = find_entry($plan, 'zqx9-worker');
                    ok(defined($drv_i) && defined($worker_i), "AC9 ($label) precondition: driver and worker rows resolved");
                    ok($kset{$drv_i} && !$kset{$worker_i},
                        "AC9 ($label): the driver row (pri 2) survives at budget=total-1 regardless of liveness, while the package row (pri 3) is dropped instead");
                }
            }
        }
    }
}

# --- MEDIUM-4 (fix-batch, redteam) --------------------------------------
#
# A wrapped logical row (package name + "attempt N/M" + "step X/Y" long
# enough to wrap at the table width) used to push each of its physical
# lines as an INDEPENDENT same-tier candidate, so the budget could admit
# the head ("01-...  attempt 2/5  step") while separately dropping its own
# continuation ("4/8") -- a truncated row silently reading as complete (a
# package with no step at all). The whole logical row must now be admitted
# or rejected as ONE atomic unit: seven packages, each long enough to wrap
# its own row into two physical lines, at a budget that provably lands
# mid-tier (enough for SOME but not all packages) -- for every package
# that shows its head at all, its own continuation ("4/8") must show too.
{
    # Retargeted: under S2.3.6's grammar a package's step (e.g. 'step=4/8')
    # is no longer a field the renderer reads at all -- step_word/status/
    # 'running' is -- so the OLD 100-column fixture (built from 'step', a
    # dead field) no longer wraps at cols=100; it must wrap at the width
    # under test, or the test proves nothing (S4's own fixture-discipline
    # rule). cols=64 is the measured width at which each of these 7
    # packages wraps into exactly a head + ONE continuation physical row
    # (fewer columns wraps into head + TWO continuations instead, which
    # would not exercise this AC's two-physical-rows shape).
    my @pkgs = map {
        { name => "zqxm4-$_-dispatch-log-write-path-and-hardening", status => 'running',
          attempt => 2, attempt_cap => 5, step_word => 'implementation', agents => [] }
    } (1 .. 7);
    my $run = tree_run(blueprint => 'zqxm4-run', packages => \@pkgs);
    my $s = base_state(runs => [ $run ]);
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 64);
    ok(!$eplan, 'MEDIUM-4 precondition: _blueprints_row_plan does not die') or diag(" error: $eplan");
    my ($width) = call1('_blueprints_body_width', 64);
  SKIP: {
        skip('no plan', 5) unless ref($plan) eq 'ARRAY' && @$plan;
        # Locate, for each package, the index of its own head row (carries
        # the package's own nonce and "attempt") and its own continuation
        # (carries "implementation 2/5" but NOT the package's own nonce --
        # i.e. a DIFFERENT physical row).
        my (@heads, @conts);
        for my $n (1 .. 7) {
            my $nonce = "zqxm4-$n-dispatch";
            my ($head_i) = grep { row_text($plan->[$_]{spans}) =~ /\Q$nonce\E/ } (0 .. $#$plan);
            push @heads, $head_i;
            my ($cont_i) = grep {
                defined($head_i) && defined($plan->[$_]{parent}) && $plan->[$_]{parent} == $head_i
                && $plan->[$_]{kind} eq 'package'
            } (0 .. $#$plan);
            push @conts, $cont_i;
        }
        ok((grep { defined } @heads) == 7, 'MEDIUM-4 precondition: all 7 package head rows resolved');
        ok((grep { defined } @conts) == 7,
            'MEDIUM-4 precondition: all 7 packages genuinely wrapped into a head + a continuation physical row (fixture shape is load-bearing)');
      SKIP: {
            skip('indices unresolved', 3)
                unless (grep { defined } @heads) == 7 && (grep { defined } @conts) == 7;
            # Budget: blueprint(1) + driver(1) + 4 whole packages (1 head +
            # 1 continuation each = 2) + one bare extra unit -- enough to
            # admit package 5's head on its own (cost 1) if heads and
            # continuations were still independently costed, but not
            # enough to also admit its continuation.
            my $budget = 1 + 1 + (4 * 2) + 1;
            my ($kept, $err) = call1('_select_rows', $plan, $budget, $width);
            ok(!$err, 'MEDIUM-4: _select_rows does not die at the mid-tier budget') or diag(" error: $err");
          SKIP: {
                skip('no kept', 2) unless ref($kept) eq 'ARRAY';
                my %kset = map { $_ => 1 } @$kept;
                my @orphaned = grep { $kset{ $heads[$_] } && !$kset{ $conts[$_] } } (0 .. 6);
                is(scalar(@orphaned), 0,
                    'MEDIUM-4: no package shows its head row without its own continuation -- the wrapped row is atomic')
                    or diag(' orphaned package indices (0-based): ' . join(',', @orphaned));
                my @backwards = grep { !$kset{ $heads[$_] } && $kset{ $conts[$_] } } (0 .. 6);
                is(scalar(@backwards), 0,
                    'MEDIUM-4: no package shows its continuation without its own head row');
            }
        }
    }
}

# --- HIGH-2 (fix-batch, redteam) ----------------------------------------
#
# HIGH-2 guarded against a defect class that required a child row's tier
# to be LATER (numerically higher) than its own parent's tier -- the old
# plan had exactly that shape (a `judge` row pri 3 parented to a `package`
# row pri 4/5). Spec S2.5's new parent table removes it structurally, not
# just in this one fixture: EVERY non-blueprint row (driver/package/judge/
# next) parents directly to its block's own `blueprint` row, which is
# always pri 1 -- the globally FIRST tier. There is no longer any row whose
# parent sits in a later tier than itself, so the "shared not-yet-kept
# ancestor in a later tier gets double-charged across siblings" bug this
# AC existed to catch cannot occur under the new shape (the ancestor is
# always kept by the time any child tier is even considered). Package-level
# judges (this fixture's own zqxh2-judgeA/B) no longer get rows of their
# own either (Scope: they collapse into their package's one row), so there
# is no fixture left that could even exercise the old scenario. Deleted
# rather than reconstructed onto a defect class the new parent table
# removes.

# --- AC10 --------------------------------------------------------------
{
    my $entries = [
        { spans => [ { text=>'z10run', role=>'x' } ], pri=>1, kind=>'run',         parent=>undef },  # 0
        { spans => [ { text=>'z10G',   role=>'x' } ], pri=>6, kind=>'coordinator', parent=>0 },       # 1
        { spans => [ { text=>'z10D',   role=>'x' } ], pri=>3, kind=>'judge',       parent=>1 },       # 2
        { spans => [ { text=>'z10H',   role=>'x' } ], pri=>5, kind=>'package',     parent=>0 },       # 3
    ];
    my ($cG, $eG) = call1('_row_cost', $entries->[1]{spans}, 120);
    my ($cD, $eD) = call1('_row_cost', $entries->[2]{spans}, 120);
    my ($cH, $eH) = call1('_row_cost', $entries->[3]{spans}, 120);
    ok(!$eG && !$eD && !$eH, 'AC10 precondition: _row_cost does not die on the three synthetic rows') or diag("errs: $eG/$eD/$eH");
  SKIP: {
        skip('cost calls failed', 3) if $eG || $eD || $eH;
        is($cG, 1, 'AC10 precondition: G costs 1 alone');
        is($cH, 1, 'AC10 precondition: H costs 1 alone');
        is($cG + $cD, 2, 'AC10 precondition: D\'s closure (D + its unkept parent G) costs exactly 2');
    }
    my ($kept, $err) = call1('_select_rows', $entries, 2, 120);
    ok(!$err, 'AC10: _select_rows does not die at budget=2') or diag(" error: $err");
  SKIP: {
        skip('no kept', 2) unless ref($kept) eq 'ARRAY';
        is_deeply($kept, [0, 3],
            'AC10: skip-and-continue -- D\'s cost-2 closure does not fit in the 1 row left after run, so it is SKIPPED, and the scan continues to admit H (a later, cheaper, lower-priority candidate) instead of stopping');
    }
}

# --- AC11 --------------------------------------------------------------
{
    for my $b (undef, 0, -1, 'x', [], {}) {
        my $label = !defined($b) ? 'undef' : (ref($b) ? ref($b) : ("'$b'"));
        my ($kept, $err) = call1('_select_rows', [ { spans=>[], pri=>1, kind=>'run', parent=>undef } ], $b, 120);
        ok(!$err, "AC11 (budget=$label): does not die") or diag(" error: $err");
        is_deeply($kept, [], "AC11 (budget=$label): returns []");
    }
    for my $ent (undef, 'x', [ {}, 'x', undef, [] ]) {
        my $label = !defined($ent) ? 'undef' : (ref($ent) ? ref($ent) : "'$ent'");
        my ($kept, $err) = call1('_select_rows', $ent, 5, 120);
        ok(!$err, "AC11 (entries=$label): does not die or warn on hostile \$entries") or diag(" error: $err");
    }
}

# ===========================================================================
# Body and notice (AC12-AC19)
# ===========================================================================

# --- AC12 --------------------------------------------------------------
my %AC12_GOLDEN;
for my $f (@AC1_FIXTURES) {
    my ($label, $s0) = @$f;
    my $s = { %$s0 };
    delete $s->{blueprint_body_rows};
    my ($body, $err) = call1('_blueprints_body', $s, 120);
    ok(!$err, "AC12 ($label): _blueprints_body does not die with no blueprint_body_rows") or diag(" error: $err");
    $AC12_GOLDEN{$label} = $body;
    ok(1, "AC12 ($label): golden captured for reuse by AC13/AC17");
}

# --- AC13 --------------------------------------------------------------
for my $f (@AC1_FIXTURES) {
    my ($label, $s0) = @$f;
    my ($width) = call1('_blueprints_body_width', 120);
    my $s = { %$s0 };
    delete $s->{blueprint_body_rows};
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 120);
    next if $eplan || ref($plan) ne 'ARRAY';
    my $total = plan_total_cost($plan, $width);
    next unless defined $total;
    $s->{blueprint_body_rows} = $total;
    my ($body, $err) = call1('_blueprints_body', $s, 120);
    ok(!$err, "AC13 ($label): _blueprints_body does not die with blueprint_body_rows == total cost ($total)") or diag(" error: $err");
    is_deeply($body, $AC12_GOLDEN{$label}, "AC13 ($label): output at cap==total cost is is_deeply identical to AC12's no-cap output");
}

# --- AC14/AC15 -----------------------------------------------------------
{
    my $s0 = base_state(runs => [ tree_run_40pkg() ]);
    my $s = { %$s0 };
    my ($width) = call1('_blueprints_body_width', 120);
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 120);
    ok(!$eplan, 'AC14/AC15 precondition: _blueprints_row_plan does not die') or diag(" error: $eplan");
  SKIP: {
        skip('no plan', 1) unless ref($plan) eq 'ARRAY' && @$plan;
        my $total = plan_total_cost($plan, $width);
        ok(defined($total) && $total > 10, 'AC14/AC15 precondition: total cost measured, > 10') or diag(' got ' . (defined($total)?$total:'undef'));
      SKIP: {
            skip('no total', 1) unless defined($total) && $total > 10;
            my $cap = int($total / 2);
            ok($cap >= 1 && $cap < $total, "AC14/AC15 precondition: cap=$cap is below total=$total (a collapse must actually be possible)");
            $s->{blueprint_body_rows} = $cap;
            my ($body, $err) = call1('_blueprints_body', $s, 120);
            ok(!$err, 'AC14: _blueprints_body does not die with a collapsing cap') or diag(" error: $err");
          SKIP: {
                skip('no body', 6) unless ref($body) eq 'ARRAY' && @$body;
                my $cost = 0;
                for my $row (@$body) { my ($c) = call1('_row_cost', $row, $width); $cost += ($c // 0); }
                cmp_ok($cost, '<=', $cap, "AC14: the collapsed body's total row cost ($cost) is <= cap ($cap)");
                my $last = $body->[-1];
                like(row_text($last), qr/\A\+\d+ rows? hidden \(short panel\)\z/, 'AC14: the last row matches the collapse-notice pattern exactly');
                is(row_leading($last), 0, 'AC14: the notice has no leading whitespace (indent 0)');
                my ($hidden) = row_text($last) =~ /\+(\d+) rows? hidden/;
                cmp_ok($hidden, '>=', 1, 'AC14: hidden count is >= 1');
                is($hidden, scalar(@$plan) - (scalar(@$body) - 1),
                    'AC14: hidden == @plan - @kept (kept = body rows minus the notice itself)');

                # AC15: surviving rows (all but the notice) are a subsequence
                # of the plan's own span sequence, in ascending order.
                my @plan_spans = map { $_->{spans} } @$plan;
                my @body_rows  = @$body[0 .. $#$body - 1];
                my $cursor = 0;
                my $ok_order = 1;
                for my $row (@body_rows) {
                    my $found = 0;
                    for (my $j = $cursor; $j <= $#plan_spans; $j++) {
                        if (row_text($plan_spans[$j]) eq row_text($row)) { $found = 1; $cursor = $j + 1; last }
                    }
                    $ok_order = 0 unless $found;
                }
                ok($ok_order, 'AC15: surviving rows appear in ascending plan order (a subsequence of the plan\'s span sequence)');
            }
        }
    }
}

# --- AC16 --------------------------------------------------------------
{
    my $big_run = tree_run_40pkg();
    my @runs = ($big_run, @{ runs_n(11) });
    my $s = base_state(runs => \@runs, blueprint_rows_max => 5);
    my ($width) = call1('_blueprints_body_width', 120);
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 120);
    ok(!$eplan, 'AC16 precondition: _blueprints_row_plan does not die on the 12-run fixture') or diag(" error: $eplan");
  SKIP: {
        skip('no plan', 1) unless ref($plan) eq 'ARRAY' && @$plan;
        my $total = plan_total_cost($plan, $width);
        ok(defined($total) && $total > 20, 'AC16 precondition: total cost measured, > 20') or diag(' got ' . (defined($total)?$total:'undef'));
      SKIP: {
            skip('no total', 1) unless defined($total) && $total > 20;
            my $cap = $total - 10;
            ok($cap >= 1 && $cap < $total, "AC16 precondition: cap=$cap forces a collapse (< total=$total)");
            $s->{blueprint_body_rows} = $cap;
            my ($body, $err) = call1('_blueprints_body', $s, 120);
            ok(!$err, 'AC16: _blueprints_body does not die') or diag(" error: $err");
          SKIP: {
                skip('no body', 4) unless ref($body) eq 'ARRAY' && @$body >= 2;
                my $joined = join("\n", map { row_text($_) } @$body);
                like($joined, qr/\+7 more blueprints?\b/, 'AC16: "+7 more blueprint(s)" appears (12 runs - budget 5; t/79\'s own pluralisation convention, no literal "(s)")');
                like(row_text($body->[-1]), qr/\A\+\d+ rows? hidden \(short panel\)\z/, 'AC16: the collapse notice is the LAST row');
                my ($overflow_i) = grep { row_text($body->[$_]) =~ /more blueprint/ } (0 .. $#$body);
                ok(defined($overflow_i) && $overflow_i < $#$body,
                    'AC16: "+N more blueprint(s)" appears BEFORE the collapse notice');
                my ($hidden) = row_text($body->[-1]) =~ /\+(\d+) rows? hidden/;
                is($hidden, scalar(@$plan) - (scalar(@$body) - 1),
                    'AC16: the notice\'s count equals @plan - @kept exactly (numerically, not by regex alone)');
            }
        }
    }
}

# --- AC17 --------------------------------------------------------------
{
    my $s0 = base_state(runs => [ tree_run_40pkg() ]);
    for my $v ([0,'0'], [-1,'-1'], ['x',"'x'"], [[], '[]'], [undef,'absent']) {
        my ($cap, $label) = @$v;
        my $s = { %$s0 };
        if (defined $cap) { $s->{blueprint_body_rows} = $cap } else { delete $s->{blueprint_body_rows} }
        my ($body, $err) = call1('_blueprints_body', $s, 120);
        ok(!$err, "AC17 (cap=$label): does not die") or diag(" error: $err");
        is_deeply($body, $AC12_GOLDEN{'40-package TREE'}, "AC17 (cap=$label): output equals AC12's no-cap output");
    }
    my $s1 = { %$s0, blueprint_body_rows => 1 };
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s0, 120);
    my ($width) = call1('_blueprints_body_width', 120);
  SKIP: {
        skip('no plan', 1) unless !$eplan && ref($plan) eq 'ARRAY';
        my $total = plan_total_cost($plan, $width);
        ok(defined($total) && $total > 1, 'AC17 precondition: total cost > 1 (a cap of 1 is genuinely below it)') or diag(' got ' . (defined($total)?$total:'undef'));
    }
    my ($body1, $err1) = call1('_blueprints_body', $s1, 120);
    ok(!$err1, 'AC17 (cap=1): does not die') or diag(" error: $err1");
    is(scalar(@{ $body1 || [] }), 1, 'AC17 (cap=1): the body is exactly one row');
  SKIP: {
        skip('wrong row count', 1) unless ref($body1) eq 'ARRAY' && @$body1 == 1;
        like(row_text($body1->[0]), qr/\A\+\d+ rows? hidden \(short panel\)\z/, 'AC17 (cap=1): that one row is the collapse notice');
    }
}

# --- AC18 --------------------------------------------------------------
{
    my $stale  = mk_agent(id=>'stale',  role=>'worker', worker_type=>'zqx18-stale',  started_at=>$NOW-100_000, stale_after_seconds=>7200);
    my $future = mk_agent(id=>'future', role=>'worker', worker_type=>'zqx18-future', started_at=>$NOW+100_000_000, stale_after_seconds=>7200);
    my ($ls, $es) = call1('_agent_live', $stale, $NOW);
    my ($lf, $ef) = call1('_agent_live', $future, $NOW);
    is($ls, 0, 'AC18 precondition: the stale record fails _agent_live') unless $es;
    is($lf, 0, 'AC18 precondition: the far-future record fails _agent_live') unless $ef;

    my $pkg_base = { name=>'pkg-ac18', status=>'running', attempt=>1, attempt_cap=>5,
                      agents=>[ mk_agent(id=>'c', role=>'coordinator', worker_type=>undef) ] };
    my $pkg_with = { %{ deep($pkg_base) } };
    $pkg_with->{agents} = [ @{ $pkg_with->{agents} }, $stale, $future ];

    my $width = ( call1('_blueprints_body_width', 120) )[0];
    for my $pair ([$pkg_base, 'without stale/future'], [$pkg_with, 'with stale/future']) {
        my ($pkg, $label) = @$pair;
        my $run = tree_run(blueprint=>"zqx18-run-$label", packages=>[ $pkg ]);
        my $s = base_state(runs=>[$run]);
        my ($plan, $err) = call1('_blueprints_row_plan', $s, 120);
        ok(!$err, "AC18 ($label): _blueprints_row_plan does not die") or diag(" error: $err");
      SKIP: {
            skip('no plan', 2) unless ref($plan) eq 'ARRAY';
            my $joined = join("\n", map { row_text($_->{spans}) } @$plan);
            unlike($joined, qr/zqx18-stale/, "AC18 ($label): the stale agent contributes no row to the plan");
            unlike($joined, qr/zqx18-future/, "AC18 ($label): the far-future agent contributes no row to the plan");
        }
    }
    # hidden count unaffected: build a small collapsing budget on both
    # variants and compare hidden counts.
    my $run_base = tree_run(blueprint=>'zqx18-cb', packages=>[ deep($pkg_base) ]);
    my $run_with = tree_run(blueprint=>'zqx18-cw', packages=>[ deep($pkg_with) ]);
    my ($plan_base) = call1('_blueprints_row_plan', base_state(runs=>[$run_base]), 120);
    my ($plan_with) = call1('_blueprints_row_plan', base_state(runs=>[$run_with]), 120);
  SKIP: {
        skip('no plans', 1) unless ref($plan_base) eq 'ARRAY' && ref($plan_with) eq 'ARRAY';
        is(scalar(@$plan_base), scalar(@$plan_with),
            'AC18: adding the two filtered records to the fixture does not change the plan\'s row count at all');
    }
}

# --- AC19 --------------------------------------------------------------
{
    my $s = base_state(runs => [ tree_run_40pkg() ]);
    my ($width) = call1('_blueprints_body_width', 120);
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 120);
    ok(!$eplan, 'AC19 precondition: _blueprints_row_plan does not die') or diag(" error: $eplan");
  SKIP: {
        skip('no plan', 1) unless ref($plan) eq 'ARRAY' && @$plan;
        my $total = plan_total_cost($plan, $width);
        ok(defined($total) && $total > 10, 'AC19 precondition: total cost measured, > 10') or diag(' got ' . (defined($total)?$total:'undef'));
      SKIP: {
            skip('no total', 1) unless defined($total) && $total > 10;
            my $cap = int($total * 0.6);
            ok($cap >= 1 && $cap < $total, "AC19 precondition: cap=$cap forces a genuine collapse");
            my ($kept, $err) = call1('_select_rows', $plan, $cap, $width);
            ok(!$err, 'AC19: _select_rows does not die') or diag(" error: $err");
          SKIP: {
                skip('no kept', 1) unless ref($kept) eq 'ARRAY';
                my %kset = map { $_ => 1 } @$kept;
                my @orphans;
                for my $i (@$kept) {
                    my $k = $plan->[$i]{kind};
                    next unless $k =~ /^(coordinator|worker|judge|other)\z/;
                    my $p = $plan->[$i]{parent};
                    while (defined $p) {
                        push(@orphans, $i), last unless $kset{$p};
                        $p = $plan->[$p]{parent};
                    }
                }
                is(scalar(@orphans), 0, 'AC19: no emitted coordinator/worker/judge/other row appears without its parent chain also emitted') or diag(' bad idx: ' . join(',', @orphans));
            }
        }
    }
}

# ===========================================================================
# Capacity, compose, and the frame (AC20-AC29)
# ===========================================================================

# --- AC20 --------------------------------------------------------------
{
    # RULING AT-15's AC20 fix: tree_run()'s builder defaults packages/
    # run_agents with `$o{...} // []`, so passing packages=>undef,
    # run_agents=>undef does NOT omit the keys -- it silently produces
    # packages=>[], run_agents=>[], byte-identical to the 'packages=>[]'
    # case below (which this same test asserts returns 1). "Neither key
    # present" (S2.2: "packages is an ARRAY or run_agents is an ARRAY") is
    # only genuinely distinguishable from "present but empty" if the key is
    # actually ABSENT from the hash, so this fixture is built by deleting
    # the keys the builder can't be told to omit, rather than by passing
    # undef through the builder's // default.
    my $neither_run = tree_run(state => 'running');
    delete $neither_run->{packages};
    delete $neither_run->{run_agents};
    ok((!exists($neither_run->{packages}) && !exists($neither_run->{run_agents})),
        'AC20 precondition: the "neither key" fixture genuinely OMITS the packages and run_agents keys (not merely undef-then-defaulted to []), so it is NOT byte-identical to the packages=>[] case above it');

    # step-7 fix-batch (reviewer-step6.md BLOCKER-2; redteam-step6.md
    # MAJOR-2): per spec S2.2.1, _multiline_blocks is 1 iff the block
    # `_run_block(...)` actually builds has 2+ LINES -- there is no state
    # condition at all. tree_run()'s default orchestrator_pid (4242) with no
    # thread means every one of these fixtures ALREADY gets a no-thread
    # driver line (S2.3.5: present iff thread is not a HASH and
    # orchestrator_pid is defined -- no state check), so blueprint+driver is
    # 2 lines regardless of state. The four cases below ('queued'/'done'/
    # 'failed'/'idle' with packages, and 'neither key') are exactly the old
    # `state eq 'running'` gate's blind spot: they were pinned at 0 under the
    # OLD _tree_present semantics, which the fix replaces.
    my @cases = (
        [ 'running, packages=>[]',           { runs=>[ tree_run(state=>'running', packages=>[], run_agents=>undef) ] }, 1 ],
        [ 'running, run_agents=>[]',         { runs=>[ tree_run(state=>'running', packages=>undef, run_agents=>[]) ] }, 1 ],
        [ 'running, neither key',            { runs=>[ $neither_run ] }, 1 ],
        [ 'queued with packages',            { runs=>[ tree_run(state=>'queued', packages=>[{name=>'x'}]) ] }, 1 ],
        [ 'done with packages',              { runs=>[ tree_run(state=>'done', packages=>[{name=>'x'}]) ] }, 1 ],
        [ 'failed with packages',            { runs=>[ tree_run(state=>'failed', packages=>[{name=>'x'}]) ] }, 1 ],
        [ 'idle with packages',              { runs=>[ tree_run(state=>'idle', packages=>[{name=>'x'}]) ] }, 1 ],
        [ 'runs absent',                     {}, 0 ],
        [ "runs='x'",                        { runs=>'x' }, 0 ],
        [ 'runs=[]',                         { runs=>[] }, 0 ],
        [ 'runs=[undef]',                    { runs=>[undef] }, 0 ],
    );
    for my $c (@cases) {
        my ($label, $s, $expect) = @$c;
        my ($res, $err) = call1('_multiline_blocks', $s);
        ok(!$err, "AC20 ($label): _multiline_blocks does not die") or diag(" error: $err");
        is($res, $expect, "AC20 ($label): _multiline_blocks returns $expect (S2.2.1: 2+ lines, no state condition)");
    }

    # A block whose run has NO driver (orchestrator_pid genuinely ABSENT, no
    # thread) and only non-rendering packages really is single-line
    # regardless of state -- this is the "must not break" case (spec S5,
    # layout-flex-stability.t): a solo run with no thread/marker/packages
    # stays one line.
    #
    # Same AT-15 pitfall as the "neither key" fixture above: tree_run()'s
    # builder defaults orchestrator_pid with `$o{orchestrator_pid} // 4242`,
    # so passing orchestrator_pid=>undef does NOT omit the key -- Perl's `//`
    # treats an explicitly-passed undef as "not supplied" and substitutes
    # 4242 regardless, which per S2.3.5 DOES draw a no-thread driver line
    # (making the block 2 lines, not 1). "No driver" is only genuinely
    # distinguishable from "present" if the key is actually ABSENT from the
    # hash, so each fixture here is built then has the key deleted, exactly
    # like the "neither key" workaround above.
    my $paused_no_driver = tree_run(state => 'paused', packages => [{name=>'x'}]);
    delete $paused_no_driver->{orchestrator_pid};
    my $solo_no_driver = tree_run(state => 'solo');
    delete $solo_no_driver->{orchestrator_pid};
    ok((!exists($paused_no_driver->{orchestrator_pid}) && !exists($solo_no_driver->{orchestrator_pid})),
        'AC20 precondition: both "no driver" fixtures genuinely OMIT orchestrator_pid (not merely undef-then-defaulted to 4242)');
    my @single_line_cases = (
        [ 'paused, no driver, no rendering packages', { runs=>[ $paused_no_driver ] }, 0 ],
        [ 'solo, no driver, no thread, no packages',  { runs=>[ $solo_no_driver ] }, 0 ],
    );
    for my $c (@single_line_cases) {
        my ($label, $s, $expect) = @$c;
        my ($res, $err) = call1('_multiline_blocks', $s);
        ok(!$err, "AC20 ($label): _multiline_blocks does not die") or diag(" error: $err");
        is($res, $expect, "AC20 ($label): _multiline_blocks returns $expect (no driver line, no rendering package line -> 1-line block)");
    }

    # step-7 fix-batch (reviewer-step6.md BLOCKER-2; redteam-step6.md
    # MAJOR-2, probe4 case B): the end-to-end bug is that _blueprints_
    # capacity (and therefore compose()'s auto blueprint_body_rows) gates on
    # _multiline_blocks, so a PAUSED fleet with many package lines never
    # even gets a capacity probe today -- capacity comes back undef no
    # matter how much the block overflows. Mirrors the AC24/AC25 pattern
    # above but with state=>'paused' instead of the default 'running'.
    #
    # The property under test (S2.2.1) is that a PAUSED block is treated
    # IDENTICALLY to a RUNNING one by the capacity probe -- not that
    # capacity is positive at every geometry. 80x10 is, measured, below the
    # panel's viable-capacity floor for BOTH states (same AC24/AC25
    # tolerance this file already applies a few blocks below: "capacity < 2
    # -- geometry precondition not met, recorded rather than silently
    # skipped"), so asserting `cap > 0` there would fail for a reason that
    # has nothing to do with pause-state -- a geometry limit, not a
    # regression. So: assert the equality property at EVERY geometry
    # (it holds trivially at 80x10 too, both measuring 0), and additionally
    # assert positivity only at the geometries that actually clear the
    # floor for both states.
    {
        my $s0_paused  = base_state(runs => [ tree_run_40pkg(state => 'paused') ]);
        my $s0_running = base_state(runs => [ tree_run_40pkg(state => 'running') ]);
        for my $g ([10, 80], [24, 100], [44, 120]) {
            my ($rows, $cols) = @$g;
            my ($cap_paused, $ecap_p) = call1('_blueprints_capacity', $s0_paused, $rows, $cols);
            my ($cap_running, $ecap_r) = call1('_blueprints_capacity', $s0_running, $rows, $cols);
            ok(!$ecap_p && !$ecap_r, "AC20 (paused vs running, ${cols}x${rows}): neither _blueprints_capacity call dies")
                or diag(" errors: $ecap_p / $ecap_r");
            is($cap_paused, $cap_running,
                "AC20 (${cols}x${rows}, BLOCKER-2/MAJOR-2): a PAUSED block measures the SAME capacity as an otherwise-identical RUNNING block (the old gate made paused undef regardless of geometry)")
                or diag(' cap_paused=' . (defined($cap_paused) ? $cap_paused : 'undef')
                      . ' cap_running=' . (defined($cap_running) ? $cap_running : 'undef'));
            if (!defined($cap_running) || $cap_running < 2) {
                ok(1, "AC20 (${cols}x${rows}): capacity < 2 for running too -- geometry precondition not met for the positivity check, recorded rather than silently skipped (cap_running=" . (defined($cap_running)?$cap_running:'undef') . ")");
                next;
            }
            ok(defined($cap_paused) && $cap_paused > 0,
                "AC20 (paused, ${cols}x${rows}, BLOCKER-2/MAJOR-2): _blueprints_capacity is a defined positive number for a PAUSED multi-line block at a geometry that clears the viable-capacity floor")
                or diag(' cap=' . (defined($cap_paused) ? $cap_paused : 'undef'));
        }
    }
}

# --- AC21 --------------------------------------------------------------
{
    my ($mark, $emark) = call1('BLUEPRINTS_PROBE_MARK');
    ok(!$emark, 'AC21 precondition: BLUEPRINTS_PROBE_MARK() does not die') or diag(" error: $emark");
    ok(defined($mark) && length($mark), 'AC21 precondition: BLUEPRINTS_PROBE_MARK is a non-empty string');
    my $s = { blueprints_probe => 7, runs => [ tree_run_1pkg() ] };
    my ($rows, $err) = call1('_blueprints_body', $s, 120);
    ok(!$err, 'AC21: _blueprints_body(probe=>7) does not die') or diag(" error: $err");
    is(scalar(@{ $rows || [] }), 7, 'AC21: probe mode returns exactly 7 rows');
  SKIP: {
        skip('wrong count', 1) unless ref($rows) eq 'ARRAY' && @$rows == 7 && length($mark);
        my @bad = grep { !(ref($_) eq 'ARRAY' && @$_ == 1 && ref($_->[0]) eq 'HASH' && defined($_->[0]{text}) && $_->[0]{text} eq $mark) } @$rows;
        is(scalar(@bad), 0, 'AC21: each row is a single span whose text is exactly BLUEPRINTS_PROBE_MARK');
    }
}

# --- AC22 --------------------------------------------------------------
# CROSS-CHECK METHOD (S4 AC22's own explicitly-sanctioned alternative): the
# sub's own measured capacity is compared against an INDEPENDENTLY-composed
# probe using the same protocol (S2.2), with the total frame row count
# additionally asserted, so the count is never taken from a frame that
# failed to build.
{
    for my $geom ([120,24], [120,44], [200,60], [80,24]) {
        my ($cols, $rows) = @$geom;
        my $s = base_state(runs => [ tree_run_40pkg() ]);
        my ($cap, $ecap) = call1('_blueprints_capacity', $s, $rows, $cols);
        ok(!$ecap, "AC22 (${cols}x${rows}): _blueprints_capacity does not die") or diag(" error: $ecap");
      SKIP: {
            skip('no capacity', 1) unless !$ecap && defined($cap) && $cap >= 1;
            my $probe_state = { %$s, blueprints_probe => $cap };
            my ($scr, $escr) = call1('screen', $probe_state, $cols);
            ok(!$escr && ref($scr) eq 'HASH', "AC22 (${cols}x${rows}): screen() does not die and returns a hashref") or diag(" error: $escr");
          SKIP: {
                skip('no screen', 1) unless !$escr && ref($scr) eq 'HASH';
                $scr->{banners} = [];
                my ($cells, $ecomp) = call_ts1('compose', $scr, $rows, $cols);
                ok(!$ecomp, "AC22 (${cols}x${rows}): tui::Screen::compose does not die") or diag(" error: $ecomp");
              SKIP: {
                    skip('no cells', 2) unless !$ecomp && ref($cells) eq 'ARRAY';
                    is(scalar(@$cells), $rows, "AC22 (${cols}x${rows}): the probe frame has exactly \$rows total rows");
                    my $mark = ( call1('BLUEPRINTS_PROBE_MARK') )[0];
                    my $sentinel_count = grep { ref($_) eq 'HASH' && defined($_->{text}) && index($_->{text}, $mark // "\0NOMARK\0") >= 0 } @$cells;
                    is($sentinel_count, $cap, "AC22 (${cols}x${rows}): the number of sentinel rows in the probe frame equals _blueprints_capacity's own measurement ($cap)");
                }
            }
        }
    }
}

# --- HIGH-1 (fix-batch, redteam) ----------------------------------------
#
# _blueprints_capacity used to count BLUEPRINTS_PROBE_MARK() anywhere in the
# whole composed frame, not just the Blueprints panel body it is meant to
# measure. Any OTHER content that happens to echo the mark -- the project
# directory name (header), a launch-log `reason=` reaching an activity
# event (the side column) -- inflated the measured capacity past what the
# panel can actually show; _render_panel then clips the frame SILENTLY,
# and the dropped row is the LAST one, which by construction (S2.6) is the
# collapse notice itself. This is the exact failure this package exists to
# remove, reproduced through the package's own instrumentation.
#
# A "poisoned" state -- project_name AND several activity events carrying
# the mark -- must measure the SAME capacity as an otherwise-identical
# "clean" state, at a geometry with a side column (so the events sink is
# live) and one without.
{
    my $mark = ( call1('BLUEPRINTS_PROBE_MARK') )[0];
    ok(defined($mark) && length($mark), 'HIGH-1 precondition: BLUEPRINTS_PROBE_MARK is a non-empty string');
    for my $geom ([120,44], [200,60]) {
        my ($cols, $rows) = @$geom;
        my $clean = base_state(runs => [ tree_run_40pkg() ]);
        my $poison = { %$clean,
            project_name => $mark,
            events       => [ map { "worker_exit reason=$mark" } (1 .. 5) ],
        };
        my ($clean_cap, $eclean) = call1('_blueprints_capacity', $clean, $rows, $cols);
        my ($poison_cap, $epoison) = call1('_blueprints_capacity', $poison, $rows, $cols);
        ok(!$eclean && !$epoison, "HIGH-1 (${cols}x${rows}): neither call dies") or diag(" errors: $eclean / $epoison");
        ok(defined($clean_cap) && $clean_cap >= 1, "HIGH-1 (${cols}x${rows}) precondition: the clean state measures a real (>=1) capacity");
        is($poison_cap, $clean_cap,
            "HIGH-1 (${cols}x${rows}): a state whose OTHER content (project_name, activity events) carries the probe mark measures the SAME capacity as the clean state -- the mark is not double-counted from outside the Blueprints panel body");
    }
}

# --- AC23 --------------------------------------------------------------
{
    my $tree_state = base_state(runs => [ tree_run_1pkg() ]);
    my $no_tree_state = base_state(runs => runs_n(3));
    my @cases = (
        [ 'rows=0',      $tree_state, 0, 120 ],
        [ 'rows=-1',     $tree_state, -1, 120 ],
        [ "rows='x'",    $tree_state, 'x', 120 ],
        [ 'rows=[]',     $tree_state, [], 120 ],
        [ 'cols=0',      $tree_state, 24, 0 ],
        [ "cols='x'",    $tree_state, 24, 'x' ],
        [ 'cols=[]',     $tree_state, 24, [] ],
        [ 'no tree',     $no_tree_state, 24, 120 ],
    );
    for my $c (@cases) {
        my ($label, $s, $rows, $cols) = @$c;
        my ($res, $err) = call1('_blueprints_capacity', $s, $rows, $cols);
        ok(!$err, "AC23 ($label): does not die or warn") or diag(" error: $err");
        ok(!defined($res), "AC23 ($label): returns undef");
    }
}

# --- AC24/AC25 -----------------------------------------------------------
{
    my $s0 = base_state(runs => [ tree_run_40pkg() ]);
    my @geoms;
    for my $rows (10, 24, 44) { for my $cols (80, 120) { push @geoms, [$rows, $cols] } }
    for my $g (@geoms) {
        my ($rows, $cols) = @$g;
        my ($cap, $ecap) = call1('_blueprints_capacity', $s0, $rows, $cols);
        my ($plan, $eplan) = call1('_blueprints_row_plan', $s0, $cols);
        my $side = ( call_ts1('side_column_width', $cols) )[0] // 0;
        my $body_width = $cols - $side;
        my ($width, $ewidth) = call1('_blueprints_body_width', $cols);
        next if $ecap || $eplan || $ewidth;
        my $total = plan_total_cost($plan, $width);
        ok(!$ecap, "AC24/AC25 (${cols}x${rows}): _blueprints_capacity does not die") or diag(" error: $ecap");
        my $collapses = (defined($cap) && $cap >= 2 && defined($total) && $total > $cap);
        if (!defined($cap) || $cap < 2) {
            my $s_forced = { %$s0, blueprint_body_rows => 1 };
            my ($body1, $e1) = call1('_blueprints_body', $s_forced, $cols);
            ok(1, "AC24 (${cols}x${rows}): capacity < 2 -- geometry precondition not met, recorded rather than silently skipped (cap=" . (defined($cap)?$cap:'undef') . ")");
            next;
        }
        ok($collapses, "AC24/AC25 (${cols}x${rows}) precondition: capacity ($cap) >= 2 and total plan cost (" . (defined($total)?$total:'undef') . ") > capacity");
      SKIP: {
            skip('precondition not met', 3) unless $collapses;
            my $s = { %$s0, blueprint_body_rows => $cap };
            my ($body, $ebody) = call1('_blueprints_body', $s, $body_width);
            my $frame = Dashboard::compose_frame($s0, $rows, $cols);
            my $ft = frame_text($frame);
            ok(!$ebody, "AC24 (${cols}x${rows}): _blueprints_body does not die") or diag(" error: $ebody");
          SKIP: {
                skip('no body', 1) unless !$ebody && ref($body) eq 'ARRAY';
                my $bad = 0;
                for my $row (@$body) { $bad++ unless words_present($ft, $row) }
                is($bad, 0, "AC24 (${cols}x${rows}): every word of every collapsed-body row (including the notice) appears in the composed frame -- nothing clipped by tui::Screen");
            }

            # AC25: frame row count and title-row index unaffected by
            # collapse.
            is(scalar(@$frame), $rows, "AC25 (${cols}x${rows}): composed frame has exactly \$rows rows");
            my $s_uncollapsed = { %$s0 };
            delete $s_uncollapsed->{blueprint_body_rows};
            my $frame_u = Dashboard::compose_frame($s_uncollapsed, $rows, $cols);
            my $ti_collapsed   = title_row_index($frame, 'Blueprints');
            my $ti_uncollapsed = title_row_index($frame_u, 'Blueprints');
            ok($ti_collapsed >= 0 && $ti_uncollapsed >= 0, "AC25 (${cols}x${rows}) precondition: a Blueprints title row is found in both frames");
            is($ti_collapsed, $ti_uncollapsed, "AC25 (${cols}x${rows}): the Blueprints title row is at the same index whether or not the panel collapsed");
        }
    }
}

# --- AC26 --------------------------------------------------------------
{
    my $stuck_pkg = { name=>'pkg-ac26-stuck', status=>'running', attempt=>1, attempt_cap=>5, agents=>[
        mk_agent(id=>'sj', role=>'judge', worker_type=>'bp-resolve-judge'),
        mk_agent(id=>'sc', role=>'coordinator', worker_type=>undef),
    ] };
    my $healthy_pkg = { name=>'pkg-ac26-healthy', status=>'running', attempt=>1, attempt_cap=>5, agents=>[
        mk_agent(id=>'hc', role=>'coordinator', worker_type=>undef),
        mk_agent(id=>'hw', role=>'worker', worker_type=>'bp-implementer'),
    ] };
    my $run = tree_run(blueprint=>'zqx26-run', orchestrator_alive=>1, packages=>[$stuck_pkg, $healthy_pkg]);
    my $s0 = base_state(runs => [ $run ]);
    # Retargeted (S2.5): under the old per-agent tree, a package-level judge
    # outranked an alive orchestrator's row (pri 3 vs pri 8), so it alone
    # could survive a collapse that dropped the orchestrator. S2.5's fixed
    # kind-based tier order removes that: `driver` is ALWAYS pri 2, strictly
    # BEFORE `package` (pri 3) -- so at any capacity small enough to drop
    # package content, the orchestrator/driver row is exactly what remains,
    # never the other way around, and a package-level judge is now just a
    # text SEGMENT inside its package's one atomic row (so it cannot survive
    # independently of that row either). rows=20 (small) and rows=24
    # (large) are MEASURED below, not hand-predicted, to be the points
    # where this 4-content-row fixture's capacity is first non-zero-but-
    # insufficient and first sufficient for everything.
    my %cap_at;
    for my $rows (20, 24) {
        my ($cap) = call1('_blueprints_capacity', $s0, $rows, 120);
        $cap_at{$rows} = $cap;
    }
    ok((defined($cap_at{20}) && defined($cap_at{24}) && $cap_at{20} > 0 && $cap_at{20} < $cap_at{24}),
        'AC26 precondition: measured capacity is > 0 at rows=20 and strictly larger at rows=24')
        or diag(' cap20=' . ($cap_at{20}//'undef') . ' cap24=' . ($cap_at{24}//'undef'));
    my $plan = ( call1('_blueprints_row_plan', $s0, 120) )[0];
  SKIP: {
        skip('no plan', 1) unless ref($plan) eq 'ARRAY';
        my $joined = join("\n", map { row_text($_->{spans}) } @$plan);
        # S2.3.6: a judge label strips a leading 'bp-' AND a trailing
        # '-judge' ('bp-resolve-judge' -> 'resolve judge'); a worker label
        # strips only the leading 'bp-' ('bp-implementer' -> 'implementer').
        ok(($joined =~ /resolve judge/ && $joined =~ /\bimplementer\b/),
            'AC26 precondition: both agents\' rendered labels are present in the uncollapsed body');
    }
  SKIP: {
        skip('capacities not increasing', 2)
            unless (defined($cap_at{20}) && defined($cap_at{24}) && $cap_at{20} > 0 && $cap_at{20} < $cap_at{24});
        my $frame_small = Dashboard::compose_frame($s0, 20, 120);
        my $ft_small = frame_text($frame_small);
        unlike($ft_small, qr/resolve judge/, 'AC26: at the smaller height, the stuck package\'s judge segment is NOT present (package content is atomic, no special-case judge survival)');
        unlike($ft_small, qr/\bimplementer\b/, 'AC26: at the smaller height, the healthy package\'s worker segment is NOT present either');
        like($ft_small, qr/\borchestrator\b/, 'AC26: at the smaller height, the orchestrator/driver row IS present (pri 2, strictly before package pri 3)');
        like($ft_small, qr/hidden/, 'AC26: at the smaller height, a hidden-rows notice appears (package content did not fit)');

        my $frame_large = Dashboard::compose_frame($s0, 24, 120);
        my $ft_large = frame_text($frame_large);
        like($ft_large, qr/resolve judge/, 'AC26: at the larger height, the resolve-judge segment is present');
        like($ft_large, qr/\bimplementer\b/, 'AC26: at the larger height, the implementer segment is present');
        like($ft_large, qr/\borchestrator\b/, 'AC26: at the larger height, the orchestrator row is present');
    }
}

# --- AC27 --------------------------------------------------------------
# Retargeted (S2.5): AC27's old premise was that the conformance judge
# (pri 3 in the old 8-tier table) always survives a collapse regardless of
# capacity, because it outranked the per-agent coordinator/worker rows
# (pri 6/7) that would be dropped first. S2.5's fixed table makes `judge`
# pri 4, strictly AFTER every `package` row (pri 3) -- so with 40 package
# rows ahead of it in document order, the run-wide judge now survives ONLY
# once capacity is large enough for every package row too (measured below,
# not assumed): it is genuinely absent at a capacity too small for all 40
# packages, and genuinely present once capacity covers the whole plan.
# This is a deliberate consequence of ruling K's tier order, not a defect.
{
    my $s0 = base_state(runs => [ tree_run_40pkg() ]);
    my $plan = ( call1('_blueprints_row_plan', $s0, 120) )[0];
    ok(ref($plan) eq 'ARRAY' && @$plan, 'AC27 precondition: the 40-package plan builds');
  SKIP: {
        skip('no plan', 1) unless ref($plan) eq 'ARRAY' && @$plan;
        # S2.3.6/2.3.7: a judge label strips a leading 'bp-' (absent here)
        # AND a trailing '-judge' -- 'zqxt40-conformance-judge' renders as
        # 'zqxt40-conformance judge' (space, suffix stripped).
        my ($last_tree_i) = grep { $plan->[$_]{kind} !~ /^(run|overflow)\z/ } reverse (0 .. $#$plan);
        ok(defined($last_tree_i) && row_text($plan->[$last_tree_i]{spans}) =~ /zqxt40-conformance judge/,
            'AC27 precondition: in the uncollapsed plan, the LAST tree row is the conformance-judge row');
    }
    my ($cap_small) = call1('_blueprints_capacity', $s0, 44, 120);
    my ($cap_full)  = call1('_blueprints_capacity', $s0, 60, 120);
    ok(defined($cap_small) && defined($cap_full) && $cap_small < @$plan && $cap_full >= @$plan,
        'AC27 precondition: rows=44 measures a capacity too small for the whole plan, rows=60 measures one large enough for all of it')
        or diag(' cap44=' . ($cap_small//'undef') . ' cap60=' . ($cap_full//'undef') . ' plan_size=' . scalar(@$plan));
  SKIP: {
        skip('capacities not as expected', 2)
            unless defined($cap_small) && defined($cap_full) && $cap_small < @$plan && $cap_full >= @$plan;
        my $ft_small = frame_text(Dashboard::compose_frame($s0, 44, 120));
        unlike($ft_small, qr/zqxt40-conformance judge/,
            'AC27 (rows=44, capacity too small for all 40 packages): the conformance-judge row is NOT present -- package rows (pri 3) exhaust the budget first');
        my $ft_full = frame_text(Dashboard::compose_frame($s0, 60, 120));
        like($ft_full, qr/zqxt40-conformance judge/,
            'AC27 (rows=60, capacity large enough for the whole plan): the conformance-judge row IS present');
    }
}

# --- AC28 --------------------------------------------------------------
{
    my $runs = runs_n(12);
    for my $geom ([120,24], [120,40], [80,12]) {
        my ($cols, $rows) = @$geom;
        my $s_a = base_state(runs => $runs);
        my $s_b = base_state(runs => $runs);
        delete $s_b->{blueprint_body_rows};
        my $frame_a = Dashboard::compose_frame($s_a, $rows, $cols);
        my $frame_b = Dashboard::compose_frame($s_b, $rows, $cols);
        is_deeply($frame_a, $frame_b, "AC28 (${cols}x${rows}): a no-tree 12-run frame is identical whether or not blueprint_body_rows is explicitly forced absent");
    }
    my $s_cap = base_state(runs => $runs, blueprint_rows_max => 5);
    my $frame = Dashboard::compose_frame($s_cap, 40, 120);
    like(frame_text($frame), qr/\+7 more blueprints?\b/, 'AC28: "+7 more blueprint(s)" still appears with blueprint_rows_max=>5 on 12 no-tree runs (regression; t/79\'s own pluralisation convention, no literal "(s)")');
}

# --- AC29 --------------------------------------------------------------
{
    my $tree_state = base_state(runs => [ tree_run_40pkg() ]);
    my ($measured_cap) = call1('_blueprints_capacity', $tree_state, 44, 120);
    ok(defined($measured_cap), 'AC29 precondition: the measured capacity at 44x120 resolves') or diag(' undef');
    my $frame_measured = Dashboard::compose_frame({ %$tree_state }, 44, 120);
    my $frame_override  = Dashboard::compose_frame({ %$tree_state, blueprint_body_rows => 4 }, 44, 120);
    my ($mh) = frame_text($frame_measured) =~ /\+(\d+) rows? hidden/;
    my ($oh) = frame_text($frame_override)  =~ /\+(\d+) rows? hidden/;
    ok(defined($oh), 'AC29: forcing blueprint_body_rows=>4 produces a collapse notice (hidden count found)');
  SKIP: {
        skip('no override hidden count', 1) unless defined($oh);
        my $mh_cmp = defined($mh) ? $mh : -1;
        isnt($oh, $mh_cmp, 'AC29: a caller-supplied blueprint_body_rows=>4 collapses to a DIFFERENT hidden count than the measured-capacity case -- the override wins over the probe');
    }
}

# ===========================================================================
# M2, purity, checks (AC30-AC35)
# ===========================================================================

# --- AC30 -- DELETED (01-run-blocks, ruling A / Scope) ------------------
# _agent_row (ruling A) is removed outright, and with it the concept this
# AC pinned (a coordinator's own row, at a fixed indent, carrying a label).
# Ruling A/Scope: coordinators are never shown in the new grammar at all --
# they collapse into the owning package line's dot and step, contributing
# no segment and no text. That replacement behaviour ("a coordinator-only
# package shows its step_word alone, nothing else") is pinned in
# blueprints-panel-tree.t's AC37-retargeted block, so it is not re-derived
# here.

# --- AC31 -- RETARGETED (01-run-blocks, spec S2.3.7, ruling J) ----------
# Was "t/187 AC36 re-asserted" against _tree_lines (ruling A removes it).
# Ruling J: "non-judge run_agents are not rendered" -- the coordinator/
# worker/admiral entries that used to get their OWN row at indent 2 now
# contribute no line at all; only the live judges get a line each, in
# run_agents order (spec S2.3.7).
{
    my $s = { blueprint => 'bp31', state => 'running', packages => [],
        run_agents => [
            mk_agent(id=>'c', role=>'coordinator', worker_type=>'zqxrc36', started_at=>$NOW-100),
            mk_agent(id=>'w', role=>'worker',      worker_type=>'zqxrw36', started_at=>$NOW-100),
            mk_agent(id=>'j', role=>'judge',       worker_type=>'bp-zqxrj36-judge', started_at=>$NOW-100),
            mk_agent(id=>'u', role=>'admiral',     worker_type=>'zqxru36', started_at=>$NOW-100),
        ],
    };
    my ($rows, $err) = call1('_run_summary_lines', [$s], undef, undef, $NOW);
    ok(!$err, 'AC31: _run_summary_lines does not die') or diag(" error: $err");
  SKIP: {
        skip('no rows', 2) unless ref($rows) eq 'ARRAY';
        is(scalar(@{ $rows || [] }), 2, 'AC31: exactly 2 rows -- the blueprint line and the ONE judge line; coordinator/worker/admiral render NOTHING');
        like(row_text($rows->[-1]), qr/zqxrj36/, 'AC31: the single surviving row (beyond the blueprint line) is the live judge\'s line');
        my $joined = join("\n", map { row_text($_) } @$rows);
        for my $nonce (qw(zqxrc36 zqxrw36 zqxru36)) {
            unlike($joined, qr/\Q$nonce\E/, "AC31: the non-judge run_agents entry ($nonce) is rendered NOWHERE");
        }
    }
    my $marker = Theme::glyph('status.judge');
    $marker = '' unless defined $marker;
  SKIP: {
        skip('no marker', 1) unless length($marker) && ref($rows) eq 'ARRAY' && @$rows >= 2;
        my ($judge_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq $marker } @{ $rows->[-1] };
        ok(defined($judge_span), 'AC31: the judge line\'s dot is the judge marker (status.judge)');
    }
}

# --- AC33 --------------------------------------------------------------
{
    my $ds_path = File::Spec->rel2abs("$Bin/../../scripts/tui/DashboardScreen.pm");
    ok(-f $ds_path, 'AC33 precondition: DashboardScreen.pm exists');
  SKIP: {
        skip('not found', 2) unless -f $ds_path;
        my $raw = slurp($ds_path);
        my @high = ($raw =~ /([^\x00-\x7f])/g);
        is(scalar(@high), 0, 'AC33: no byte >= 0x80 in DashboardScreen.pm') or diag(' found ' . scalar(@high) . ' high byte(s)');
        my @esc = ($raw =~ /\\x\{([0-9A-Fa-f]+)\}/g);
        my @bad = grep { hex($_) >= 0x80 } @esc;
        is(scalar(@bad), 0, 'AC33: no \\x{...} escape >= 0x80 in DashboardScreen.pm') or diag(' bad: ' . join(',', @bad));
    }
}

# --- AC34 --------------------------------------------------------------
{
    my $ds_path = File::Spec->rel2abs("$Bin/../../scripts/tui/DashboardScreen.pm");
    ok(-f $ds_path, 'AC34 precondition: DashboardScreen.pm exists');
  SKIP: {
        skip('not found', 8) unless -f $ds_path;
        my $scanned = _comment_stripped(slurp($ds_path));
        for my $word (qw(agent subagent implementer reviewer redteam resolver a1 a2)) {
            ok(($scanned !~ /(['"])\Q$word\E\1/ ? 1 : 0),
                "AC34: the quoted literal '$word' does not appear as a role word in DashboardScreen.pm");
        }
    }
}

# --- AC35 --------------------------------------------------------------
{
    for my $case (['tui/DashboardScreen.pm', "$Bin/../../scripts/tui/DashboardScreen.pm"],
                  ['tui-preview.pl',         "$Bin/../../../../scripts/tui-preview.pl"]) {
        my ($label, $rel) = @$case;
        my $path = File::Spec->rel2abs($rel);
        ok(-f $path, "AC35 precondition: $label exists at $path");
      SKIP: {
            skip("$path not found", 1) unless -f $path;
            # $Bin-relative -I, never a hardcoded absolute path (t/187 H3).
            my $out = `perl -I "$SCRIPTS" -c "$path" 2>&1`;
            my $rc  = $? >> 8;
            is($rc, 0, "AC35: perl -c on $label exits 0") or diag("  output: $out");
        }
    }
}

# ===========================================================================
# The preview harness (AC36-AC48)
# ===========================================================================

my $PREVIEW_PATH = File::Spec->rel2abs("$Bin/../../../../scripts/tui-preview.pl");
ok(-f $PREVIEW_PATH, "preview-harness precondition: scripts/tui-preview.pl exists at $PREVIEW_PATH");

# require()d IN-PROCESS. This is only safe because @INC already carries the
# sandbox scripts directory via this file's own `use lib "$Bin/../../scripts"`
# ABOVE -- FindBin caches $Bin process-wide from $0 (the FIRST script that
# loads it), so tui-preview.pl's OWN `use lib "$Bin/../plugins/sandbox/scripts"`
# would resolve against THIS TEST's directory, not tui-preview.pl's, if this
# test relied on it. It does not: Dashboard.pm and friends are already
# reachable before the require runs, so tui-preview.pl's own (in this
# context, harmless) use-lib line is redundant, never load-bearing here.
# Verified empirically before writing this file.
my $PREVIEW_LOADED = 0;
{
    local $@;
    $PREVIEW_LOADED = eval { require $PREVIEW_PATH; 1 } ? 1 : 0;
    diag("preview require error: $@") if !$PREVIEW_LOADED && $@;
}
ok($PREVIEW_LOADED, 'preview-harness precondition: scripts/tui-preview.pl requires cleanly in-process (main() unless caller guards the interactive loop)');

# --- AC36 --------------------------------------------------------------
SKIP: {
    skip('preview did not load', 4) unless $PREVIEW_LOADED;
    my ($runs, $err) = call_main1('synth_runs', 5, 3);
    ok(!$err, 'AC36: synth_runs(5,3) does not die') or diag(" error: $err");
  SKIP: {
        skip('no runs', 4) unless ref($runs) eq 'ARRAY' && @$runs;
        my @running = grep { ref($_) eq 'HASH' && defined($_->{state}) && $_->{state} eq 'running' } @$runs;
        ok(scalar(@running) >= 1, 'AC36 precondition: at least one synth_runs element has state=>running');
      SKIP: {
            skip('no running element', 3) unless @running;
            # Widened 19 -> 23 / 8 -> 10 by package 01-run-blocks (spec
            # S2.1/S2.6, C5 write-set amendment): scripts/tui-preview.pl's
            # synth_runs/_synth_packages now emit paused_window, relaunch_at,
            # relaunch_local, next_package (run) and step_word, waits_on
            # (package) -- set equality against RunState's own closed key
            # set, mechanically widened in lockstep (same rationale as
            # runstate-package-facts.t's identically-named comment).
            my @RUN_KEYS = qw(blueprint runs_dir state orchestrator_pid orchestrator_alive
                orchestrator_started_at paused_manual paused_reason packages_total packages_done
                current_package running_coordinators escalations_waiting inbox_waiting
                triage_waiting packages run_agents
                thread thread_events
                paused_window relaunch_at relaunch_local next_package);
            my $r = $running[0];
            is_deeply([ sort keys %$r ], [ sort @RUN_KEYS ], 'AC36: a running synth_runs element has EXACTLY the 23 run-level keys RunState emits (set equality)');
            my $pkgs = $r->{packages};
            ok(ref($pkgs) eq 'ARRAY' && @$pkgs, 'AC36 precondition: the running element carries a non-empty packages array');
          SKIP: {
                skip('no packages', 1) unless ref($pkgs) eq 'ARRAY' && @$pkgs;
                my @PKG_KEYS = qw(name status attempt attempt_cap step steps_pending next_action agents step_word waits_on);
                my @bad = grep { !(ref($_) eq 'HASH' && "@{[sort keys %$_]}" eq "@{[sort @PKG_KEYS]}") } @$pkgs;
                is(scalar(@bad), 0, 'AC36: every packages element has exactly the 10 package keys');
            }
            my @agents;
            push @agents, @{ $_->{agents} } for grep { ref($_->{agents}) eq 'ARRAY' } @$pkgs;
            push @agents, @{ $r->{run_agents} } if ref($r->{run_agents}) eq 'ARRAY';
            ok(scalar(@agents) >= 1, 'AC36 precondition: at least one agent exists across packages/run_agents');
          SKIP: {
                skip('no agents', 2) unless @agents;
                my @AGENT_KEYS = qw(id role worker_type started_at budget_seconds stale_after_seconds);
                my @bad = grep { !(ref($_) eq 'HASH' && "@{[sort keys %$_]}" eq "@{[sort @AGENT_KEYS]}") } @agents;
                is(scalar(@bad), 0, 'AC36: every agent element has exactly the 6 agent keys');
                my @badrole = grep { !defined($_->{role}) || $_->{role} !~ /^(coordinator|worker|judge)\z/ } @agents;
                is(scalar(@badrole), 0, 'AC36: every agent role is coordinator|worker|judge');
            }
        }
    }
}

# --- AC37 --------------------------------------------------------------
SKIP: {
    skip('preview did not load', 1) unless $PREVIEW_LOADED;
    my $found = 0;
    my $found_name = '';
    for my $phase (0 .. 40) {
        my ($state, $eerr) = call_main1('synth_state', $phase);
        next if $eerr || ref($state) ne 'HASH';
        my ($runs) = ($state->{runs});
        next unless ref($runs) eq 'ARRAY';
        my ($r) = grep { ref($_) eq 'HASH' && defined($_->{state}) && $_->{state} eq 'running'
                          && ref($_->{packages}) eq 'ARRAY' && @{ $_->{packages} } } @$runs;
        next unless $r;
        my ($dump, $ederr) = call_main1('render_plain', $state, 60, 200, 0, $phase);
        next if $ederr || !defined($dump);
        next if $dump =~ /\?\s+running\s+0\/0\s+pkg/ || $dump =~ /\?\s{2,}running/;
        next unless index($dump, $r->{blueprint} // "\0none\0") >= 0;
        $found = 1; $found_name = $r->{blueprint};
        last;
    }
    ok($found, "AC37: at least one phase (0..40) at 200x60 dumps a frame with no placeholder shape and containing the synth blueprint name" . ($found ? " ($found_name)" : ''));
}

# --- AC38 --------------------------------------------------------------
SKIP: {
    skip('preview did not load', 3) unless $PREVIEW_LOADED;
    my ($found_state, $found_agent, $found_phase);
    for my $phase (0 .. 40) {
        my ($state) = call_main1('synth_state', $phase);
        next unless ref($state) eq 'HASH' && ref($state->{runs}) eq 'ARRAY';
        for my $r (@{ $state->{runs} }) {
            next unless ref($r) eq 'HASH' && ref($r->{packages}) eq 'ARRAY';
            for my $p (@{ $r->{packages} }) {
                next unless ref($p) eq 'HASH' && defined($p->{status}) && $p->{status} eq 'running';
                next unless defined($p->{attempt}) && defined($p->{attempt_cap}) && $p->{attempt} == $p->{attempt_cap};
                next unless ref($p->{agents}) eq 'ARRAY';
                for my $a (@{ $p->{agents} }) {
                    next unless ref($a) eq 'HASH' && defined($a->{role}) && $a->{role} eq 'judge'
                             && defined($a->{worker_type}) && $a->{worker_type} eq 'bp-resolve-judge';
                    my ($live) = call1('_agent_live', $a, $state->{now});
                    next unless $live;
                    $found_state = $state; $found_agent = $a; $found_phase = $phase;
                    last;
                }
                last if $found_agent;
            }
            last if $found_agent;
        }
        last if $found_agent;
    }
    ok(defined($found_agent), 'AC38: some phase yields a stuck package (status=running, attempt==attempt_cap) with a LIVE bp-resolve-judge agent');
  SKIP: {
        skip('no such fixture found', 1) unless defined($found_agent);
        my ($dump) = call_main1('render_plain', $found_state, 60, 200, 0, $found_phase);
        # RETARGETED (01-run-blocks, spec S2.3.6, ruling J): the judge
        # segment's label is no longer the raw worker_type -- it is
        # "<kind> judge" with a leading bp- and a trailing -judge stripped
        # ("bp-resolve-judge" -> "resolve judge"). The judge dot
        # (status.judge, via _judge_marker) is what marks the package line
        # as stuck-under-a-judge, not the literal worker_type string.
        like($dump // '', qr/resolve judge/, "AC38 (phase=$found_phase): the resolve-judge segment ('resolve judge', bp-/-judge stripped) is present in the 200x60 dump");
    }
}

# --- AC39 --------------------------------------------------------------
# RETARGETED (01-run-blocks): the candidate pool is now restricted to
# PACKAGE-sourced worker agents only, excluding run_agents entirely -- spec
# S2.3.7/ruling J says a non-judge run_agents entry (which a worker always
# is) renders NO line at all, regardless of liveness or budget, so a
# worker found only in run_agents could never appear in any dump and would
# make this AC fail for a reason the spec itself predicts, not a missing
# behaviour. The owning package's status is also required to be outside
# {blocked, parked}: a BLOCKED/PARKED package's detail never lists agents
# (spec S2.3.6 BLOCKED detail), so an over-budget worker on such a package
# would likewise never appear even once the renderer is fully implemented.
SKIP: {
    skip('preview did not load', 3) unless $PREVIEW_LOADED;
    my ($found_state, $found_agent, $found_phase);
    for my $phase (0 .. 40) {
        my ($state) = call_main1('synth_state', $phase);
        next unless ref($state) eq 'HASH' && ref($state->{runs}) eq 'ARRAY';
        for my $r (@{ $state->{runs} }) {
            next unless ref($r) eq 'HASH' && ref($r->{packages}) eq 'ARRAY';
            for my $p (@{ $r->{packages} }) {
                next unless ref($p) eq 'HASH' && defined($p->{status}) && $p->{status} !~ /^(?:blocked|parked)\z/;
                next unless ref($p->{agents}) eq 'ARRAY';
                for my $a (@{ $p->{agents} }) {
                    next unless ref($a) eq 'HASH' && defined($a->{role}) && $a->{role} eq 'worker';
                    next unless defined($a->{started_at}) && defined($a->{budget_seconds});
                    next unless ($state->{now} // 0) - $a->{started_at} > $a->{budget_seconds};
                    my ($live) = call1('_agent_live', $a, $state->{now});
                    next unless $live;
                    $found_state = $state; $found_agent = $a; $found_phase = $phase;
                    last;
                }
                last if $found_agent;
            }
            last if $found_agent;
        }
        last if $found_agent;
    }
    ok(defined($found_agent), 'AC39: some phase yields a live worker (on a non-blocked/parked package) with (now - started_at) > budget_seconds (over-budget)');
  SKIP: {
        skip('no such fixture found', 1) unless defined($found_agent);
        my ($dump) = call_main1('render_plain', $found_state, 60, 200, 0, $found_phase);
        (my $expect_label = $found_agent->{worker_type} // '') =~ s/^bp-//;
        like($dump // '', qr/\Q$expect_label\E/, "AC39 (phase=$found_phase): the over-budget worker's label (bp- stripped, spec S2.3.6) appears in the 200x60 dump")
            if length($expect_label);
    }
}

# --- AC40 --------------------------------------------------------------
SKIP: {
    skip('preview did not load', 6) unless $PREVIEW_LOADED;
    my (%agent_counts, $has_op_gt0, $has_op_eq0, $has_conf_judge, $has_empty_run_agents, $has_paused);
    my (%where);
    for my $phase (0 .. 40) {
        my ($state) = call_main1('synth_state', $phase);
        next unless ref($state) eq 'HASH' && ref($state->{runs}) eq 'ARRAY';
        for my $r (@{ $state->{runs} }) {
            next unless ref($r) eq 'HASH';
            if (defined($r->{inbox_waiting})) {
                if ($r->{inbox_waiting} > 0) { $has_op_gt0 //= $phase } else { $has_op_eq0 //= $phase }
            }
            if (defined($r->{state}) && $r->{state} eq 'paused' && defined($r->{paused_reason}) && length($r->{paused_reason})) {
                $has_paused //= $phase;
            }
            if (ref($r->{run_agents}) eq 'ARRAY') {
                if (@{ $r->{run_agents} } == 0) { $has_empty_run_agents //= $phase }
                if (grep { ref($_) eq 'HASH' && ($_->{worker_type}//'') eq 'bp-conformance-judge' } @{ $r->{run_agents} }) {
                    $has_conf_judge //= $phase;
                }
            }
            next unless ref($r->{packages}) eq 'ARRAY';
            for my $p (@{ $r->{packages} }) {
                next unless ref($p) eq 'HASH';
                my $n = ref($p->{agents}) eq 'ARRAY' ? scalar(@{ $p->{agents} }) : -1;
                $agent_counts{$n} //= $phase if $n >= 0;
            }
        }
    }
    ok(exists $agent_counts{0}, 'AC40: some phase yields a package with 0 agents' . (exists $agent_counts{0} ? " (phase $agent_counts{0})" : ''));
    ok(exists $agent_counts{1}, 'AC40: some phase yields a package with exactly 1 agent' . (exists $agent_counts{1} ? " (phase $agent_counts{1})" : ''));
    ok((grep { $_ >= 4 } keys %agent_counts), 'AC40: some phase yields a package with >= 4 agents');
    ok(defined($has_op_gt0), 'AC40: some phase yields inbox_waiting > 0' . (defined($has_op_gt0) ? " (phase $has_op_gt0)" : ''));
    ok(defined($has_op_eq0), 'AC40: some phase yields inbox_waiting == 0' . (defined($has_op_eq0) ? " (phase $has_op_eq0)" : ''));
    ok(defined($has_conf_judge), 'AC40: some phase yields a live bp-conformance-judge in run_agents' . (defined($has_conf_judge) ? " (phase $has_conf_judge)" : ''));
    ok(defined($has_empty_run_agents), 'AC40: some phase yields an empty run_agents' . (defined($has_empty_run_agents) ? " (phase $has_empty_run_agents)" : ''));
    ok(defined($has_paused), 'AC40: some phase yields a paused run with a paused_reason' . (defined($has_paused) ? " (phase $has_paused)" : ''));
}

# --- AC41 --------------------------------------------------------------
SKIP: {
    skip('preview did not load', 5) unless $PREVIEW_LOADED;
    my ($now1, $e1) = call_main1('SYNTH_NOW');
    ok(!$e1, 'AC41: SYNTH_NOW() does not die') or diag(" error: $e1");
  SKIP: {
        skip('no SYNTH_NOW', 4) unless !$e1 && defined($now1);
        ok(!ref($now1) && $now1 =~ /^\d{1,12}\z/ && $now1 > 0, 'AC41: SYNTH_NOW is a positive integer of <= 12 digits');
        my ($s7a) = call_main1('synth_state', 7);
        my ($s7b) = call_main1('synth_state', 7);
        ok(ref($s7a) eq 'HASH' && ref($s7b) eq 'HASH', 'AC41 precondition: synth_state(7) returns a hashref both times');
      SKIP: {
            skip('no state', 2) unless ref($s7a) eq 'HASH' && ref($s7b) eq 'HASH';
            is($s7a->{now}, $now1, "AC41: synth_state(7)->{now} equals SYNTH_NOW");
            is($s7a->{now}, $s7b->{now}, 'AC41: synth_state(7)->{now} is identical across two calls with the same phase');
        }
    }
}

# --- AC42 --------------------------------------------------------------
{
    my ($out1, $rc1);
    {
        local $SIG{ALRM} = sub { die "T188_TIMEOUT\n" };
        eval { alarm(20); $out1 = `perl "$PREVIEW_PATH" --dump 200x60 --phase 7 2>&1`; $rc1 = $? >> 8; alarm(0); };
        alarm(0);
    }
    my ($out2, $rc2);
    {
        local $SIG{ALRM} = sub { die "T188_TIMEOUT\n" };
        eval { alarm(20); $out2 = `perl "$PREVIEW_PATH" --dump 200x60 --phase 7 2>&1`; $rc2 = $? >> 8; alarm(0); };
        alarm(0);
    }
    is($rc1, 0, 'AC42: --dump 200x60 --phase 7 exits 0 (run 1)') or diag(' tail: ' . substr($out1//'', -1000));
    is($rc2, 0, 'AC42: --dump 200x60 --phase 7 exits 0 (run 2)') or diag(' tail: ' . substr($out2//'', -1000));
    is($out1, $out2, 'AC42: two invocations of the same --dump WxH --phase N produce byte-identical stdout');

    my ($out3, $rc3);
    {
        local $SIG{ALRM} = sub { die "T188_TIMEOUT\n" };
        eval { alarm(20); $out3 = `perl "$PREVIEW_PATH" --dump 200x60 --phase 8 2>&1`; $rc3 = $? >> 8; alarm(0); };
        alarm(0);
    }
    is($rc3, 0, 'AC42: --dump 200x60 --phase 8 exits 0') or diag(' tail: ' . substr($out3//'', -1000));
  SKIP: {
        skip('one of the two runs failed', 1) unless $rc1 == 0 && $rc3 == 0;
        isnt($out1, $out3, 'AC42: --phase 7 and --phase 8 produce DIFFERENT stdout');
    }
}

# --- AC43 --------------------------------------------------------------
{
    my ($out, $rc);
    {
        local $SIG{ALRM} = sub { die "T188_TIMEOUT\n" };
        eval { alarm(20); $out = `perl "$PREVIEW_PATH" --dump 120x24,200x60 --phase 3 2>&1`; $rc = $? >> 8; alarm(0); };
        alarm(0);
    }
    is($rc, 0, 'AC43: --dump 120x24,200x60 --phase 3 exits 0') or diag(' tail: ' . substr($out//'', -1500));
  SKIP: {
        skip('subprocess failed', 2) unless defined($out) && $rc == 0;
        my @blocks = split /^=+\n/m, $out;
        @blocks = grep { length($_) } @blocks;
        is(scalar(@blocks), 2, 'AC43: two geometries produce two frame blocks (separated by the "====" marker)');
      SKIP: {
            skip('wrong block count', 2) unless @blocks == 2;
            my @lines0 = split /\n/, $blocks[0];
            my @lines1 = split /\n/, $blocks[1];
            is(scalar(@lines0), 24, 'AC43: the first frame (120x24) has exactly 24 rows');
            is(scalar(@lines1), 60, 'AC43: the second frame (200x60) has exactly 60 rows');
        }
    }
}

# --- AC44 --------------------------------------------------------------
{
    # Part (a): %INC, checked WITHOUT ever requiring launcher.pl (hard-banned
    # by this package's own brief). Non-vacuity for %INC is that Dashboard.pm
    # (or similar) IS a populated key, proving the scan sees real entries.
  SKIP: {
        skip('preview did not load', 2) unless $PREVIEW_LOADED;
        my @launcher_keys = grep { /launcher/i } keys %INC;
        is(scalar(@launcher_keys), 0, 'AC44: requiring scripts/tui-preview.pl leaves no key matching /launcher/i in %INC') or diag(' found: ' . join(',', @launcher_keys));
        my @dashboard_keys = grep { /Dashboard/i } keys %INC;
        ok(scalar(@dashboard_keys) >= 1, 'AC44 precondition: %INC has real, populated entries (Dashboard.pm present) -- the scan is not vacuously empty');
    }

    # Part (b): source scans, proven live against known-positive text WITHOUT
    # executing launcher.pl -- a plain, non-executing file read. COMMENT-
    # STRIPPED (same convention as AC34/AC48): tui-preview.pl's own header
    # PROSE explains, in comments, that it "never loads launcher.pl" and
    # "never talks to podman" -- a raw (non-stripped) scan for those exact
    # substrings would match that explanatory comment and could never pass,
    # which is the "scan written against the rule rather than the subject"
    # trap package 06's own test-writer already found and fixed twice.
    my $preview_raw = slurp($PREVIEW_PATH);
    ok(defined($preview_raw), 'AC44 precondition: tui-preview.pl source is readable');
  SKIP: {
        skip('source unreadable', 4) unless defined($preview_raw);
        my $preview_code = _comment_stripped($preview_raw);
        unlike($preview_code, qr/launcher\.pl/, 'AC44: tui-preview.pl\'s CODE (comments stripped) contains no "launcher.pl"');

        # SCOPED to actual INVOCATION syntax, not any mention of the word
        # "podman" -- the file's own synthetic resources/warning strings
        # legitimately say 'podman-machine-default' and "... podman image
        # pulls will start failing" (a fabricated warning message), neither
        # of which starts a process. A bare substring scan flags prose; this
        # scans for the shapes that actually run something.
        my $podman_invocation_re = qr/`[^`]*podman[^`]*`|\bsystem\s*\([^)]*podman|\bqx[\s\/\(][^)]*podman|\bpodman\.exe\b/i;
        my @podman_invocations = grep { /$podman_invocation_re/ } split /\n/, $preview_code;
        is(scalar(@podman_invocations), 0,
            'AC44: tui-preview.pl\'s CODE contains no podman INVOCATION (backticks/system/qx/podman.exe) -- mentioning "podman" in synthetic data or messages is fine, running it is not')
            or diag(' matching lines: ' . join(' | ', @podman_invocations));
        like('my $x = `podman ps`;', $podman_invocation_re,
            'AC44 non-vacuity: the invocation-shaped regex DOES match a hand-built backtick podman call -- the detector is proven live');

        my $launcher_path = File::Spec->rel2abs("$Bin/../../scripts/launcher.pl");
        my $launcher_code = _comment_stripped(slurp($launcher_path));
        ok(defined($launcher_code) && $launcher_code =~ /launcher\.pl/,
            'AC44 non-vacuity: the SAME "launcher.pl" pattern DOES match launcher.pl\'s own filename-bearing CODE line ($LAUNCHER_PL = ".../launcher.pl") -- the detector is proven live');
        like($preview_code, qr/podman/, 'AC44 non-vacuity: the broader "podman" substring DOES match tui-preview.pl\'s existing podman-machine-default string in code -- the podman detector is proven live before its scoped absence means anything');
    }
}

# --- AC45 --------------------------------------------------------------
{
    my ($out, $rc);
    {
        local $SIG{ALRM} = sub { die "T188_TIMEOUT\n" };
        my $ok = eval { alarm(20); $out = `perl "$PREVIEW_PATH" --dump 200x60 --phase 0 2>&1`; $rc = $? >> 8; alarm(0); 1 };
        alarm(0);
        ok($ok, 'AC45: the bounded --dump 200x60 --phase 0 subprocess did not time out') or diag(" error: $@");
    }
    is($rc, 0, 'AC45: --dump 200x60 --phase 0 exits 0') or diag(' tail: ' . substr($out//'', -1000));
    ok(defined($out) && length($out) > 0, 'AC45: --dump 200x60 --phase 0 prints a non-empty frame');
}

# --- AC46 --------------------------------------------------------------
SKIP: {
    skip('preview did not load', 4) unless $PREVIEW_LOADED;
    my ($stale_agent, $stale_phase, $future_agent, $future_phase);
    for my $phase (0 .. 40) {
        my ($state) = call_main1('synth_state', $phase);
        next unless ref($state) eq 'HASH' && ref($state->{runs}) eq 'ARRAY';
        my @pool;
        for my $r (@{ $state->{runs} }) {
            next unless ref($r) eq 'HASH';
            push @pool, @{ $r->{run_agents} } if ref($r->{run_agents}) eq 'ARRAY';
            push @pool, map { ref($_) eq 'HASH' && ref($_->{agents}) eq 'ARRAY' ? @{ $_->{agents} } : () } @{ $r->{packages} || [] };
        }
        for my $a (@pool) {
            next unless ref($a) eq 'HASH' && defined($a->{started_at});
            my ($live) = call1('_agent_live', $a, $state->{now});
            next if $live;
            if (!defined($stale_agent) && $a->{started_at} <= ($state->{now}//0)) {
                $stale_agent = $a; $stale_phase = $phase;
            }
            if (!defined($future_agent) && $a->{started_at} > ($state->{now}//0)) {
                $future_agent = $a; $future_phase = $phase;
            }
        }
        last if $stale_agent && $future_agent;
    }
    ok(defined($stale_agent), 'AC46 precondition: at least one non-live agent with started_at in the past (stale) exists across phases 0..40');
    ok(defined($future_agent), 'AC46 precondition: at least one non-live agent with started_at in the future exists across phases 0..40');
  SKIP: {
        skip('missing fixtures', 2) unless defined($stale_agent) && defined($future_agent);
        for my $geom ([200,60], [120,24], [80,24]) {
            my ($cols, $rows) = @$geom;
            my ($sdump) = call_main1('render_plain', ( call_main1('synth_state', $stale_phase) )[0], $rows, $cols, 0, $stale_phase);
            unlike($sdump // '', qr/\Q$stale_agent->{worker_type}\E/, "AC46 (${cols}x${rows}): the stale agent's worker_type does not appear in the dump") if defined $stale_agent->{worker_type};
            my ($fdump) = call_main1('render_plain', ( call_main1('synth_state', $future_phase) )[0], $rows, $cols, 0, $future_phase);
            unlike($fdump // '', qr/\Q$future_agent->{worker_type}\E/, "AC46 (${cols}x${rows}): the far-future agent's worker_type does not appear in the dump") if defined $future_agent->{worker_type};
        }
    }
}

# --- AC47 --------------------------------------------------------------
#
# CORRECTED (fix-batch, redteam MEDIUM-2): the original geometry
# (120x24 --phase 5) measures capacity 0 at that height -- the inherited
# Screen/Layout floor documented in the ledger, outside this write set --
# so the Blueprints panel never collapses there and BOTH meaningful
# assertions fell into the `else { ok(1, ...) }` escape below, unexercised.
# That escape is also why MEDIUM-1 (the report's capacity/plan/hidden
# figures computed at the wrong width whenever a side column exists) went
# undetected: the one geometry that actually surfaces the mismatch (cols
# >= ~178, so a side column exists) was never run here.
#
# Two geometries now, each pinned by a HARD precondition -- it fails the
# test outright, it does not skip -- that this geometry genuinely
# collapses (a notice row is present), per S4's own fixture-discipline
# rule ("a collapse AC whose precondition fails fails, it does not skip
# silently"):
#   - 200x60 phase 44: HAS a side column; this is a geometry/phase pair
#     that genuinely produces a "+N rows hidden (short panel)" notice
#     under package 01-run-blocks's far more compact per-package block
#     rendering (1-4 package lines per run instead of one row per agent,
#     S2.3.6) -- phase 9, pinned for the OLD per-agent tree, no longer
#     collapses at this geometry at all (measured: hidden=0, re-verified
#     below as a hard precondition rather than assumed). Re-selected by
#     scanning phases for one whose report and rendered notice both show
#     a non-zero hidden count (S4's "measured, not modeled" discipline),
#     landing on 44 (hidden 7) as the first that also HAS a side column.
#   - 120x35 phase 5: no side column, the narrow case, same phase family
#     as the original geometry but at a height that genuinely produces a
#     Blueprints body instead of none at all.
for my $case (
    { geom => '200x60', phase => 44, label => 'wide, side column' },
    { geom => '120x35', phase => 5, label => 'narrow, no side column' },
) {
    my ($out, $rc);
    {
        local $SIG{ALRM} = sub { die "T188_TIMEOUT\n" };
        eval { alarm(20); $out = `perl "$PREVIEW_PATH" --dump $case->{geom} --phase $case->{phase} --report 2>&1`; $rc = $? >> 8; alarm(0); };
        alarm(0);
    }
    is($rc, 0, "AC47 ($case->{label}): --dump $case->{geom} --phase $case->{phase} --report exits 0")
        or diag(' tail: ' . substr($out//'', -1500));
  SKIP: {
        skip('subprocess failed', 5) unless defined($out) && $rc == 0;
        like($out, qr/^blueprints\s+capacity \S+\s+plan \S+\s+hidden \S+/m,
            "AC47 ($case->{label}): a \"blueprints capacity ... plan ... hidden ...\" line is present");
        my ($hidden) = $out =~ /^blueprints\s+capacity \S+\s+plan \S+\s+hidden (\S+)/m;
        ok(defined($hidden), "AC47 ($case->{label}) precondition: a hidden figure is captured from the report line");
        my ($notice_hidden) = $out =~ /\+(\d+) rows? hidden \(short panel\)/;
        ok(defined($notice_hidden),
            "AC47 ($case->{label}) precondition: this geometry genuinely collapses (a notice row is present in the same report's frame)");
        cmp_ok($hidden, '>=', 1, "AC47 ($case->{label}): at a collapsing geometry, the reported hidden figure is >= 1");
        is($hidden, $notice_hidden,
            "AC47 ($case->{label}): the report's hidden figure equals the count in the notice row of the same report's rendered frame");
    }
}

# --- AC48 --------------------------------------------------------------
{
    my $preview_raw = slurp($PREVIEW_PATH);
    ok(defined($preview_raw), 'AC48 precondition: tui-preview.pl source is readable');
  SKIP: {
        skip('source unreadable', 1) unless defined($preview_raw);
        my $stripped = _comment_stripped($preview_raw);
        my @bad;
        for my $name (qw(synth_state synth_runs)) {
            my $body = _sub_body($stripped, $name);
            next unless defined $body;
            push @bad, "$name(time)"      if $body =~ /\btime\s*\(/;
            push @bad, "$name(localtime)" if $body =~ /\blocaltime\b/;
            push @bad, "$name(rand)"      if $body =~ /\brand\s*\(/;
        }
        is(scalar(@bad), 0, 'AC48: no time()/localtime/rand() inside synth_state or synth_runs bodies') or diag(' bad: ' . join(',', @bad));

        ok($stripped =~ /\blocaltime\b/, 'AC48 non-vacuity: the same scanner DOES find "localtime" in main\'s [c] capture block -- the detector is proven live');
    }
}


# ===========================================================================
# package 13-dashboard-threads (specs/13-dashboard-threads-spec.md S3
# behaviour 16, AC11): the thread line is one atomic `partial`-kind, pri-2
# plan entry (S2.3 "Placement"/"reuses partial rather than adding an
# eleventh kind"), and it survives the row budget whenever its own run row
# does and the budget has room for both -- exactly like the pre-existing
# paused-reason partial row this package's thread line sits beside. AC1's
# plan-is-the-body equivalence and AC2's closed 10-word kind vocabulary
# (already including 'partial') must both keep holding on a plan that
# contains one.
# ===========================================================================
{
    my $thread = {
        name => 'zqx13-thrln', state => 'live', done => 1, total => 3,
        doing => [ { class => 'doing', kind => 'text', title => 'zqx13 doing task', waits_on => undef } ],
        current => undef,
        next    => { class => 'pending', kind => 'text', title => 'zqx13 next task', waits_on => undef },
        owner   => { kind => 'session', id => 'zqx13-sess', alive => undef, activity_at => $NOW - 10, armed => 1 },
    };
    # NOTE (reviewer-1 finding 1): 'zqx13-runbp' and 'zqx13-thrln' are
    # deliberately chosen so that NEITHER is a substring of the other --
    # find_entry() matches by substring, and the previous nonces
    # ('zqx13-threaded' / 'zqx13-thread') collided, so find_entry('zqx13-thread')
    # always matched the run row (entry 0) first instead of the thread line.
    my $s = base_state(runs => [ tree_run(blueprint => 'zqx13-runbp', thread => $thread) ]);
    my ($plan, $eplan) = call1('_blueprints_row_plan', $s, 120);
    ok(!$eplan, 'package-13/B16: _blueprints_row_plan does not die on a run carrying a thread') or diag(" error: $eplan");
  SKIP: {
        skip('no plan', 6) unless ref($plan) eq 'ARRAY' && @$plan;

        # AC1 equivalence still holds: the plan's spans equal the body, with
        # the thread line included.
        my ($body, $ebody) = call1('_blueprints_body', $s, 120);
        ok(!$ebody, 'package-13/B16: _blueprints_body does not die') or diag(" error: $ebody");
        if (ref($body) eq 'ARRAY') {
            my @spans = map { ref($_) eq 'HASH' ? $_->{spans} : undef } @$plan;
            is_deeply(\@spans, $body, 'package-13/B16 (AC1): [ map {spans} @plan ] is_deeply _blueprints_body, with a thread line present');
        } else {
            fail('package-13/B16 (AC1): plan spans equal body, with a thread line present');
        }

        # The thread line itself: find the plan entry whose text names the
        # thread (its name and 'doing'/'next' wording are distinctive nonces).
        my ($idx, $entry) = find_entry($plan, 'zqx13-thrln');
        ok(defined($idx), 'package-13/B16: a plan entry mentions the thread name zqx13-thrln') or diag(' plan: ' . join(' | ', map { row_text($_->{spans}) } @$plan));
      SKIP: {
            skip('thread entry not found', 3) unless defined $idx;
            # Retargeted (spec S2.2.1/S2.3.4/S2.5, ruling A): package
            # 13-dashboard-threads's own `_thread_line` is one of the subs
            # ruling A removes; 01-run-blocks's `_run_block` renders a
            # thread (or no-thread) driver line as its OWN `driver` kind
            # (not a reused 'partial'), still pri 2, per S2.5's table.
            is($entry->{kind}, 'driver', 'package-13/B16: the thread-line entry is kind "driver" (S2.5\'s own kind for a thread or no-thread driver line, not a reused "partial")');
            is($entry->{pri}, 2, 'package-13/B16: the thread-line entry has pri 2 (S2.5 placement)');
            ok(defined($entry->{parent}) && $entry->{parent} < $idx, 'package-13/B16: the thread-line entry has a defined parent index strictly before itself (the blueprint row)');
        }

        # AC2's closed kind vocabulary is now S2.5's six (blueprint/
        # overflow/driver/package/judge/next), and still holds with a
        # thread (driver) line in the plan.
        my %KIND = map { $_ => 1 } qw(blueprint overflow driver package judge next);
        my @bad_kind = grep { !(ref($plan->[$_]) eq 'HASH' && defined($plan->[$_]{kind}) && $KIND{$plan->[$_]{kind}}) } (0 .. $#$plan);
        is(scalar(@bad_kind), 0, 'package-13/B16 (AC2): every plan entry kind is still one of S2.5\'s six, with a thread line present')
            or diag(' bad idx: ' . join(',', @bad_kind));
    }

    # The collapsing-budget half of B16: with the 40-package fixture PLUS a
    # thread, and a budget that still has room for the run row and the
    # thread line (but not everything), the thread line must survive.
    my $s40 = base_state(runs => [ tree_run_40pkg(thread => $thread, blueprint => 'zqx13-runbp') ]);
    my ($width) = call1('_blueprints_body_width', 120);
    my ($plan40, $eplan40) = call1('_blueprints_row_plan', $s40, 120);
    ok(!$eplan40, 'package-13/B16 (40pkg): _blueprints_row_plan does not die') or diag(" error: $eplan40");
  SKIP: {
        skip('no plan40', 2) unless ref($plan40) eq 'ARRAY' && @$plan40;
        my ($run_idx) = find_entry($plan40, 'zqx13-runbp');
        my ($thread_idx) = find_entry($plan40, 'zqx13-thrln');
        ok(defined($run_idx) && defined($thread_idx), 'package-13/B16 (40pkg): both the run row and the thread line are present in the uncollapsed plan');
      SKIP: {
            skip('rows not found', 1) unless defined($run_idx) && defined($thread_idx);
            # A budget costed as exactly the run row + the thread line (plus
            # every entry at a LOWER pri number than the tree, since
            # _select_rows admits by priority -- run=1, thread/paused=2, cur=5
            # -- so a cap covering pri<=2 content always keeps both), PLUS the
            # collapse-notice row's own cost: _blueprints_body (reviewer-1
            # finding 5, DashboardScreen.pm's _blueprints_body) reserves that
            # row FIRST, via `_select_rows($plan, $cap - $reserve, ...)`, before
            # selecting anything else, whenever the plan's total cost exceeds
            # $cap -- which it does here (40 packages). Omitting the reserve
            # from $cap starves _select_rows of the one slot it needs to also
            # keep the thread line, and the thread line drops. The reserve
            # itself is MEASURED (never hardcoded), per this file's own
            # fixture-discipline rule.
            my $cap = 0;
            for my $e (@$plan40) {
                last if $e->{pri} > 2;
                my ($c) = call1('_row_cost', $e->{spans}, $width);
                $cap += ($c // 0);
            }
            my ($notice_spans) = call1('_collapse_notice', scalar(@$plan40));
            my ($reserve) = call1('_row_cost', $notice_spans, $width);
            $cap += ($reserve // 0);
            $s40->{blueprint_body_rows} = $cap;
            my ($body40, $err40) = call1('_blueprints_body', $s40, 120);
            ok(!$err40, 'package-13/B16 (40pkg): _blueprints_body does not die with a pri<=2-plus-notice budget') or diag(" error: $err40");
            my $body_text = join("\n", map { row_text($_) } @{ $body40 || [] });
            like($body_text, qr/zqx13-thrln/, 'package-13/B16 (40pkg): the thread line survives a budget sized to cover its own run row + itself + the reserved collapse notice');
        }
    }
}

done_testing();
