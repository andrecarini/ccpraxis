#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for blueprint
# blueprints-panel-redesign, package 01-run-blocks
# (specs/01-run-blocks-spec.md S3/S3.1/S4, binding amendment: blueprint.md
# Decision 11 C4).
#
# WRITTEN BLIND to any implementation: none of
# tui::DashboardScreen::{_run_block, _wrap_block_row, _blueprints_body_width,
# _multiline_blocks, _block_elapsed, _resume_words, _pause_words} exist at
# the time this file is written (verified by grep before writing). Their
# contracts (spec S2.2/S2.3/S2.4) were read as INTERFACE ONLY -- there is
# no implementation to read. _run_summary_lines, _blueprints_body,
# _blueprints_row_plan, _blueprints_capacity, Theme::glyph/glyph_width,
# tui::Layout::display_width, tui::Frame::spans_text/wrap_capped,
# Dashboard::compose_frame already exist and are UNCHANGED surface this
# package calls into, not peeks at.
#
# BINDING AMENDMENT (blueprint.md Decision 11, C4): the paused STATE slot
# uses Theme glyph 'thread.idle', NOT 'title.paused' (identical bytes, both
# U+23F8 pad 1 -- so every expected frame below is unaffected byte-wise,
# but the source-scan assertions (AC17-style, below) assert the ABSENCE of
# a 'title.paused' call in the pause-slot code path and the PRESENCE of
# 'thread.idle' there instead).
#
# Every expected string is built from Theme::glyph(...) by NAME, never a
# hardcoded glyph byte literal -- so this file does not silently agree with
# itself on a wrong glyph. This file stays ASCII (no `use utf8`); glyph
# bytes reach it only via Theme::glyph.
#
# NOW (fixture constant, spec S3): 1_762_000_000 (Sat 2025-11-01 12:26:40
# UTC). Agent records carry stale_after_seconds=>7200, budget_seconds=>1800.
#
# Do NOT weaken an assertion here to make a future implementation's life
# easier.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use POSIX ();

# AC-pattern hardening (house rule): pin HOME/USERPROFILE/ALMANAC_HOME to a
# scratch tempdir before any RunState call, so F16's real summarize_dir()
# call can never reach the operator's real vault.
BEGIN {
    my $env_pin = File::Temp::tempdir(CLEANUP => 1);
    $ENV{HOME}         = $env_pin;
    $ENV{USERPROFILE}  = $env_pin;
    $ENV{ALMANAC_HOME} = $env_pin;
}

require Theme;
require tui::Layout;
require tui::Frame;
require tui::DashboardScreen;
require Dashboard;
require RunState;

my $NOW = 1_762_000_000;

# ===========================================================================
# Scaffolding
# ===========================================================================

sub G { my ($name) = @_; return Theme::glyph($name) // ''; }
sub S { return ' ' x $_[0]; }

# METER(d, t, full_name, empty_name) -- the 15-cell ceil meter (spec S2.3,
# ruling I). d==0||t==0 -> 0 full; d>=t>0 -> 15 full; else ceil(d*15/t)
# capped at 14.
sub METER {
    my ($d, $t, $full, $empty) = @_;
    return '' unless $t;
    my $f = ($d == 0) ? 0 : ($d >= $t ? 15 : int(($d * 15 + $t - 1) / $t));
    $f = 14 if $f > 14 && !($d >= $t);
    return (G($full) x $f) . (G($empty) x (15 - $f));
}
sub M { return METER($_[0], $_[1], 'gauge.full', 'gauge.empty'); }
sub B { return METER($_[0], $_[1], 'thread.full', 'thread.empty'); }

# call_ds($sub, @args) -> (\@results, $err) -- symbolic-ref call into
# tui::DashboardScreen so a not-yet-existing sub degrades to a clean string
# error rather than a fatal abort of the whole file (t/row-budget-and-
# preview.t's own convention, reused verbatim).
sub call_ds {
    my ($name, @args) = @_;
    no strict 'refs';
    my @res;
    my $ok = eval { @res = &{"tui::DashboardScreen::$name"}(@args); 1 };
    my $err = $ok ? '' : (defined($@) && length($@) ? $@ : 'unknown error');
    return (\@res, $err);
}
sub call1 { my ($name, @args) = @_; my ($r, $e) = call_ds($name, @args); return ($r->[0], $e); }

sub rows_text {
    my ($rows) = @_;
    return [] unless ref($rows) eq 'ARRAY';
    return [ map { ref($_) eq 'ARRAY' ? tui::Frame::spans_text($_) : undef } @$rows ];
}

sub mk_agent {
    my (%o) = @_;
    return { id => $o{id}, role => $o{role}, worker_type => $o{worker_type},
             started_at => $o{started_at}, budget_seconds => $o{budget_seconds} // 1800,
             stale_after_seconds => $o{stale_after_seconds} // 7200 };
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "write_file($path): $!";
    print $fh $content;
    close $fh;
}

# ===========================================================================
# F1 -- Decision 10's combined target block (C1, C2 applied).
# ===========================================================================
my $F1 = {
    blueprint => 'acxpraxis-step-2', state => 'paused', packages_done => 5, packages_total => 14,
    paused_reason => 'usage', paused_window => 'seven_day', relaunch_at => 1_762_193_100,
    relaunch_local => { wday => 'Mon', hhmm => '18:05', day => '03', mon => 'Nov' },
    orchestrator_pid => 4242, orchestrator_alive => 1, orchestrator_started_at => $NOW - 11_520,
    running_coordinators => 2, escalations_waiting => 0, inbox_waiting => 0, triage_waiting => 0,
    thread => { name => 'fleet-acxpraxis-step-2', state => 'live', done => 5, total => 14,
        doing => [ { class => 'doing', kind => 'link', blueprint => 'acxpraxis-step-2', number => '05', step => 'tests' } ],
        current => undef, next => undef,
        owner => { kind => 'orchestrator', id => 'acxpraxis-step-2', alive => 1, activity_at => undef, armed => 0 } },
    packages => [
        { name => '03-make-and-hooks', status => 'pending', agents => [] },
        { name => '05-checks-erlang', status => 'running', attempt => 1, attempt_cap => 5, step_word => 'tests',
            agents => [ mk_agent(id => 'c1', role => 'coordinator', worker_type => undef, started_at => $NOW - 5000),
                        mk_agent(id => 'w1', role => 'worker', worker_type => 'bp-test-writer', started_at => $NOW - 720) ] },
        { name => '10-model-journal-recovery', status => 'running', attempt => 5, attempt_cap => 5,
            step_word => 'implementation',
            agents => [ mk_agent(id => 'w2', role => 'worker', worker_type => 'bp-implementer', started_at => $NOW - 2460) ] },
    ],
    run_agents => [ mk_agent(id => 'j1', role => 'judge', worker_type => 'bp-conformance-judge', started_at => $NOW - 240) ],
    next_package => '03-make-and-hooks',
};
# W = 25 (per spec).
my @F1_LINES = (
    G('icon.blueprints') . ' acxpraxis-step-2' . S(11) . M(5, 14) . S(2) . '5/14' . S(3) . G('thread.idle') . ' weekly limit until Mon 18:05',
    S(2) . G('icon.threads') . ' fleet-acxpraxis-step-2' . S(5) . 'orchestrator ' . G('status.ok') . ' 3h12m' . S(3) . '2 coord',
    S(2) . G('status.ok') . ' 05-checks-erlang' . S(11) . 'tests ' . G('sep.dot') . ' test-writer 12m',
    S(2) . G('status.warn') . ' 10-model-journal-recovery' . S(2) . 'implementation 5/5 ' . G('sep.dot') . ' implementer 41m',
    S(2) . G('status.judge') . ' conformance judge' . S(10) . 'whole blueprint 4m',
    S(2) . G('arrow.right') . ' 03-make-and-hooks' . S(10) . 'next',
);

{
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F1], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC1 precondition: _run_summary_lines(F1) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@F1_LINES, 'AC1: F1 (Decision 10 combined target block, C1/C2 applied) renders byte-exact');
}

# ===========================================================================
# F2 -- running fleet, no pause.
# ===========================================================================
{
    my $F2 = { %$F1, state => 'running', paused_reason => undef, paused_window => undef,
               relaunch_at => undef, relaunch_local => undef };
    my @lines = @F1_LINES;
    $lines[0] = G('icon.blueprints') . ' acxpraxis-step-2' . S(11) . M(5, 14) . S(2) . '5/14' . S(3) . 'running';
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F2], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC2 precondition: _run_summary_lines(F2) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@lines, 'AC2: F2 (running fleet, no pause) renders byte-exact');
}

# ===========================================================================
# F3 -- drive-solo (session-owned thread with its own bar, no coordinators).
# ===========================================================================
my $F3 = {
    blueprint => 'tooling-fixes', state => 'solo', packages_done => 4, packages_total => 9,
    orchestrator_pid => undef, orchestrator_alive => undef, orchestrator_started_at => undef,
    running_coordinators => 0,
    thread => { name => 'drive-tooling', state => 'live', done => 3, total => 5,
        doing => [ { class => 'doing', kind => 'link', blueprint => 'tooling-fixes', number => '12', step => 'scout' } ],
        current => undef,
        owner => { kind => 'session', id => 'sess-1', alive => undef, activity_at => $NOW - 100, armed => 0 } },
    packages => [
        { name => '10-alpha', status => 'done', agents => [] },
        { name => '12-bug-claimant', status => 'running', attempt => undef, attempt_cap => undef,
          step_word => 'scout', agents => [] },
        { name => '13-guard', status => 'pending', agents => [] },
    ],
    run_agents => [],
    next_package => '13-guard',
};
# W = 15.
my @F3_LINES = (
    G('icon.blueprints') . ' tooling-fixes' . S(4) . M(4, 9) . S(2) . '4/9' . S(3) . 'solo',
    S(2) . G('icon.threads') . ' drive-tooling' . S(4) . B(3, 5) . S(2) . '3/5' . S(3) . 'session ' . G('status.ok'),
    S(2) . G('status.ok') . ' 12-bug-claimant' . S(2) . 'scout',
    S(2) . G('arrow.right') . ' 13-guard' . S(9) . 'next',
);
{
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F3], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC3 precondition: _run_summary_lines(F3) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@F3_LINES, 'AC3: F3 (drive-solo, session bar, no coordinators) renders byte-exact');
}

# ===========================================================================
# F4 -- no attached thread (driver line led by its dot).
# ===========================================================================
my $F4 = {
    blueprint => 'bp-nothread', state => 'running', packages_done => 1, packages_total => 3,
    orchestrator_pid => 4242, orchestrator_alive => 1, orchestrator_started_at => $NOW - 600,
    running_coordinators => 1, thread => undef,
    packages => [ { name => '01-alpha', status => 'running', attempt => 1, attempt_cap => 5,
                     step_word => 'spec', agents => [] } ],
    run_agents => [], next_package => undef,
};
# W = 12.
my @F4_LINES = (
    G('icon.blueprints') . ' bp-nothread' . S(3) . M(1, 3) . S(2) . '1/3' . S(3) . 'running',
    S(2) . G('status.ok') . ' orchestrator' . S(2) . '10m' . S(3) . '1 coord',
    S(2) . G('status.ok') . ' 01-alpha' . S(6) . 'spec',
);
{
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F4], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC4 precondition: _run_summary_lines(F4) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@F4_LINES, 'AC4: F4 (no attached thread, driver line led by its dot) renders byte-exact');
}

# ===========================================================================
# F5 -- dead orchestrator (status.crit); F5b -- mirror thread, dead owner.
# ===========================================================================
{
    my $F5 = { %$F4, state => 'stale', orchestrator_alive => 0, orchestrator_started_at => undef,
               running_coordinators => 0 };
    my @lines = (
        G('icon.blueprints') . ' bp-nothread' . S(3) . M(1, 3) . S(2) . '1/3' . S(3) . 'stale',
        S(2) . G('status.crit') . ' orchestrator',
        S(2) . G('status.ok') . ' 01-alpha' . S(6) . 'spec',
    );
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F5], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC5 precondition: _run_summary_lines(F5) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@lines, 'AC5: F5 (dead orchestrator) renders byte-exact');
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        my ($crit_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq G('status.crit') } @{ $rows->[1] };
        is($crit_span ? $crit_span->{role} : undef, 'state.crit', 'AC5: the dead dot is status.crit with role state.crit');
    }
}
{
    my $F5b = { %$F4, state => 'stale', orchestrator_alive => 0, orchestrator_started_at => undef,
                running_coordinators => 0,
                thread => { name => 'fleet-x', state => 'live', done => 1, total => 3, doing => [], current => undef,
                            owner => { kind => 'orchestrator', id => 'bp-nothread', alive => 0 } } };
    # W = 11.
    my @lines = (
        G('icon.blueprints') . ' bp-nothread' . S(2) . M(1, 3) . S(2) . '1/3' . S(3) . 'stale',
        S(2) . G('icon.threads') . ' fleet-x' . S(6) . 'orchestrator ' . G('status.crit') . S(3) . G('thread.idle') . ' idle',
        S(2) . G('status.ok') . ' 01-alpha' . S(5) . 'spec',
    );
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F5b], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC5 precondition: _run_summary_lines(F5b) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@lines, 'AC5: F5b (mirror thread, dead owner) renders byte-exact');
}

# ===========================================================================
# F6 -- handed off; F6b -- unowned.
# ===========================================================================
{
    my $F6 = {
        blueprint => 'release-target', state => 'idle', packages_done => 1, packages_total => 1,
        orchestrator_pid => undef,
        thread => { name => 'release-prep', state => 'handed-off', done => 2, total => 4, doing => [],
            current => { class => 'blocked', kind => 'text', title => 'Publish the package',
                         waits_on => '20261002-120000-abcd' },
            owner => { kind => 'none' } },
        packages => [ { name => '01-thing', status => 'done', agents => [] } ],
        run_agents => [], next_package => undef,
    };
    # W = 14.
    my @lines = (
        G('icon.blueprints') . ' release-target' . S(2) . M(1, 1) . S(2) . '1/1' . S(3) . 'idle',
        S(2) . G('icon.threads') . ' release-prep' . S(4) . B(2, 4) . S(2) . '2/4' . S(3) . 'handed off ' . G('status.warn')
            . S(3) . G('thread.blocked') . ' blocked Publish the package waiting on 20261002-120000-abcd',
    );
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F6], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC6 precondition: _run_summary_lines(F6) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@lines, 'AC6: F6 (handed off) renders byte-exact');
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 2;
        my ($warn_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq G('status.warn') } @{ $rows->[1] };
        is($warn_span ? $warn_span->{role} : undef, 'state.warn', 'AC6: F6 handed-off dot role is state.warn');
    }

    my $F6b = { %$F6, thread => { %{ $F6->{thread} }, state => 'live', current => undef } };
    my @lines_b = (
        $lines[0],
        S(2) . G('icon.threads') . ' release-prep' . S(4) . B(2, 4) . S(2) . '2/4' . S(3) . 'unowned ' . G('status.idle')
            . S(3) . G('thread.idle') . ' idle',
    );
    my $rows_b = eval { tui::DashboardScreen::_run_summary_lines([$F6b], undef, undef, $NOW) };
    my $err_b = $@;
    ok(!$err_b, 'AC6 precondition: _run_summary_lines(F6b) does not die') or diag("  \$\@ = $err_b");
    is_deeply(rows_text($rows_b), \@lines_b, 'AC6: F6b (unowned) renders byte-exact');
  SKIP: {
        skip('no rows', 1) unless ref($rows_b) eq 'ARRAY' && @$rows_b >= 2;
        my ($idle_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq G('status.idle') } @{ $rows_b->[1] };
        is($idle_span ? $idle_span->{role} : undef, 'text.muted', 'AC6: F6b unowned dot role is text.muted');
    }
}

# ===========================================================================
# F7 -- blocked packages.
# ===========================================================================
{
    my $F7 = {
        blueprint => 'bp-blocked', state => 'running', packages_done => 2, packages_total => 5,
        orchestrator_pid => undef, thread => undef,
        packages => [
            { name => '03-gamma', status => 'blocked', waits_on => '20261002-120000-abcd', attempt => 2, attempt_cap => 5,
              step_word => 'implementation',
              agents => [ mk_agent(id => 'w', role => 'worker', worker_type => 'bp-implementer', started_at => $NOW - 300) ] },
            { name => '04-delta', status => 'blocked', waits_on => undef },
        ],
        run_agents => [], next_package => undef,
    };
    # W = 10.
    my @lines = (
        G('icon.blueprints') . ' bp-blocked' . S(2) . M(2, 5) . S(2) . '2/5' . S(3) . 'running',
        S(2) . G('thread.blocked') . ' 03-gamma' . S(4) . 'blocked waiting on 20261002-120000-abcd',
        S(2) . G('thread.blocked') . ' 04-delta' . S(4) . 'blocked',
    );
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F7], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC7 precondition: _run_summary_lines(F7) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@lines, 'AC7: F7 (blocked packages, thread.blocked, waiting on only when known) renders byte-exact');
}

# ===========================================================================
# F8 -- package under a judge; AC8 precedence table.
# ===========================================================================
{
    my $F8 = {
        blueprint => 'bp-judged', state => 'running', packages_done => 3, packages_total => 6,
        packages => [
            { name => '06-zeta', status => 'reviewing', attempt => 2, attempt_cap => 5, step_word => 'review',
              agents => [ mk_agent(id => 'j', role => 'judge', worker_type => 'bp-oracle-judge', started_at => $NOW - 300),
                          mk_agent(id => 'r', role => 'worker', worker_type => 'bp-reviewer', started_at => $NOW - 180) ] },
        ],
        run_agents => [], next_package => undef,
    };
    # W = 9.
    my @lines = (
        G('icon.blueprints') . ' bp-judged' . S(2) . M(3, 6) . S(2) . '3/6' . S(3) . 'running',
        S(2) . G('status.judge') . ' 06-zeta' . S(4) . 'review 2/5 ' . G('sep.dot') . ' reviewer 3m ' . G('sep.dot') . ' oracle judge 5m',
    );
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F8], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC8 precondition: _run_summary_lines(F8) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@lines, 'AC8: F8 (package under a judge) renders byte-exact');

    # AC8 precedence table: {blocked, live judge, attempt 5/5} -> thread.blocked;
    # {live judge, 5/5} -> status.judge; {5/5} -> status.warn; {1/5} -> status.ok.
    my @cases = (
        [ 'blocked+judge+5/5', { status => 'blocked', waits_on => undef, attempt => 5, attempt_cap => 5,
            agents => [ mk_agent(id=>'j',role=>'judge',worker_type=>'bp-x-judge',started_at=>$NOW-10) ] }, 'thread.blocked' ],
        [ 'judge+5/5 (not blocked)', { status => 'reviewing', attempt => 5, attempt_cap => 5,
            agents => [ mk_agent(id=>'j',role=>'judge',worker_type=>'bp-x-judge',started_at=>$NOW-10) ] }, 'status.judge' ],
        [ '5/5 (no judge)', { status => 'running', attempt => 5, attempt_cap => 5, agents => [] }, 'status.warn' ],
        [ '1/5', { status => 'running', attempt => 1, attempt_cap => 5, agents => [] }, 'status.ok' ],
    );
    for my $c (@cases) {
        my ($label, $pkg_extra, $expect_glyph_name) = @$c;
        my $s = { blueprint => 'bp-prec', state => 'running', packages_done => 0, packages_total => 1,
                  packages => [ { name => '01-x', %$pkg_extra } ], run_agents => [] };
        my $rows_p = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        my $err_p = $@;
        ok(!$err_p, "AC8 precedence ($label): _run_summary_lines does not die") or diag("  \$\@ = $err_p");
      SKIP: {
            skip('no package line', 1) unless ref($rows_p) eq 'ARRAY' && @$rows_p >= 2;
            my $glyph = G($expect_glyph_name);
            my $text = tui::Frame::spans_text($rows_p->[1]);
            ok(length($glyph) && index($text, $glyph) == 2, "AC8 precedence ($label): the package line's dot is $expect_glyph_name");
        }
    }
}

# ===========================================================================
# F9 -- escalations waiting and in triage.
# ===========================================================================
{
    my $DECISIONS = G('icon.decisions');
    # (a) F4 with inbox_waiting=>2, triage_waiting=>1.
    my $s_a = { %$F4, inbox_waiting => 2, triage_waiting => 1 };
    my $line_a = G('icon.blueprints') . ' bp-nothread' . S(3) . M(1, 3) . S(2) . '1/3' . S(3) . 'running'
        . S(3) . $DECISIONS . ' 2' . S(3) . '1 triage';
    my $rows_a = eval { tui::DashboardScreen::_run_summary_lines([$s_a], undef, undef, $NOW) };
    ok(!$@, 'AC9a precondition: does not die') or diag("  \$\@ = $@");
    is(ref($rows_a) eq 'ARRAY' ? tui::Frame::spans_text($rows_a->[0]) : undef, $line_a, 'AC9a: inbox_waiting+triage_waiting renders byte-exact');
  SKIP: {
        skip('no row', 1) unless ref($rows_a) eq 'ARRAY';
        my ($wait_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq $DECISIONS . ' 2' } @{ $rows_a->[0] };
        is($wait_span ? $wait_span->{role} : undef, 'state.warn', 'AC9a: the escalations span role is state.warn (running)');
    }

    # (b) paused base with usage/no window, inbox_waiting=>1 -> state.crit.
    my $s_b = { blueprint => 'bp-p', state => 'paused', packages_done => 0, packages_total => 2,
                paused_reason => 'usage', inbox_waiting => 1 };
    my $P = G('icon.blueprints') . ' bp-p' . S(2) . M(0, 2) . S(2) . '0/2' . S(3) . G('thread.idle') . ' ';
    my $line_b = $P . 'usage limit' . S(3) . $DECISIONS . ' 1';
    my $rows_b = eval { tui::DashboardScreen::_run_summary_lines([$s_b], undef, undef, $NOW) };
    ok(!$@, 'AC9b precondition: does not die') or diag("  \$\@ = $@");
    is(ref($rows_b) eq 'ARRAY' ? tui::Frame::spans_text($rows_b->[0]) : undef, $line_b, 'AC9b: paused + inbox_waiting renders byte-exact');
  SKIP: {
        skip('no row', 1) unless ref($rows_b) eq 'ARRAY';
        my ($wait_span) = grep { ref($_) eq 'HASH' && defined($_->{text}) && $_->{text} eq $DECISIONS . ' 1' } @{ $rows_b->[0] };
        is($wait_span ? $wait_span->{role} : undef, 'state.crit', 'AC9b: the escalations span role is state.crit (paused)');
    }

    # (c) F4 with inbox_waiting=>0, triage_waiting=>3.
    my $s_c = { %$F4, inbox_waiting => 0, triage_waiting => 3 };
    my $line_c = G('icon.blueprints') . ' bp-nothread' . S(3) . M(1, 3) . S(2) . '1/3' . S(3) . 'running' . S(3) . '3 triage';
    my $rows_c = eval { tui::DashboardScreen::_run_summary_lines([$s_c], undef, undef, $NOW) };
    ok(!$@, 'AC9c precondition: does not die') or diag("  \$\@ = $@");
    is(ref($rows_c) eq 'ARRAY' ? tui::Frame::spans_text($rows_c->[0]) : undef, $line_c, 'AC9c: triage_waiting with inbox_waiting=0 renders byte-exact');

    # (d) F4 with inbox_waiting absent, escalations_waiting=>2.
    my $s_d = { %$F4 };
    delete $s_d->{inbox_waiting};
    $s_d->{escalations_waiting} = 2;
    my $line_d = G('icon.blueprints') . ' bp-nothread' . S(3) . M(1, 3) . S(2) . '1/3' . S(3) . 'running' . S(3) . $DECISIONS . ' 2';
    my $rows_d = eval { tui::DashboardScreen::_run_summary_lines([$s_d], undef, undef, $NOW) };
    ok(!$@, 'AC9d precondition: does not die') or diag("  \$\@ = $@");
    is(ref($rows_d) eq 'ARRAY' ? tui::Frame::spans_text($rows_d->[0]) : undef, $line_d, 'AC9d: inbox_waiting absent falls back to escalations_waiting');
}

# ===========================================================================
# F10/F11 -- pause words and resume times.
# ===========================================================================
{
    my $P = G('icon.blueprints') . ' bp-p' . S(2) . M(0, 2) . S(2) . '0/2' . S(3) . G('thread.idle') . ' ';
    my $T15  = { wday => 'Sat', hhmm => '15:26', day => '01', mon => 'Nov' };
    my $TMON = { wday => 'Mon', hhmm => '18:05', day => '03', mon => 'Nov' };
    my $T10  = { wday => 'Mon', hhmm => '12:26', day => '10', mon => 'Nov' };

    my @cases = (
        [ 'five_hour',  'usage', 'five_hour', 1_762_010_800, $T15,  $P . '5-hour limit until 15:26' ],
        [ 'no window',  'usage', undef,       1_762_010_800, $T15,  $P . 'usage limit until 15:26' ],
        [ 'telemetry',  'telemetry', undef,   undef, undef,         $P . 'usage unknown' ],
        [ 'other token', 'usage-contract', undef, undef, undef,     $P . 'usage-contract' ],
        [ 'no reason',  undef, undef, undef, undef,                 $P . 'paused' ],
        [ 'missing',    'usage', 'seven_day', undef, undef,          $P . 'weekly limit' ],
        [ 'past',       'usage', 'seven_day', $NOW - 60, $T15,       $P . 'weekly limit resuming' ],
        [ 'within 24 h','usage', 'seven_day', 1_762_010_800, $T15,  $P . 'weekly limit until 15:26' ],
        [ 'within 7 days','usage','seven_day', 1_762_193_100, $TMON, $P . 'weekly limit until Mon 18:05' ],
        [ 'over 7 days','usage', 'seven_day', 1_762_777_600, $T10,  $P . 'weekly limit until 10 Nov' ],
    );
    for my $c (@cases) {
        my ($label, $reason, $window, $relaunch_at, $relaunch_local, $expect) = @$c;
        my $s = { blueprint => 'bp-p', state => 'paused', packages_done => 0, packages_total => 2,
                  paused_reason => $reason, paused_window => $window,
                  relaunch_at => $relaunch_at, relaunch_local => $relaunch_local };
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        ok(!$@, "F10/F11 ($label) precondition: does not die") or diag("  \$\@ = $@");
        is(ref($rows) eq 'ARRAY' ? tui::Frame::spans_text($rows->[0]) : undef, $expect, "F10/F11 ($label) renders byte-exact");
    }

    # B3 boundaries, relaunch_local = TMON (the branch is asserted).
    my @boundaries = (
        [ 'NOW+86399 -> clock only',      $NOW + 86_399, $P . 'weekly limit until 18:05' ],
        [ 'NOW+86400 -> weekday form',    $NOW + 86_400, $P . 'weekly limit until Mon 18:05' ],
        [ 'NOW+604799 -> weekday form',   $NOW + 604_799, $P . 'weekly limit until Mon 18:05' ],
        [ 'NOW+604800 -> date form',      $NOW + 604_800, $P . 'weekly limit until 03 Nov' ],
        [ 'NOW -> resuming',              $NOW,           $P . 'weekly limit resuming' ],
    );
    for my $b (@boundaries) {
        my ($label, $relaunch_at, $expect) = @$b;
        my $s = { blueprint => 'bp-p', state => 'paused', packages_done => 0, packages_total => 2,
                  paused_reason => 'usage', paused_window => 'seven_day',
                  relaunch_at => $relaunch_at, relaunch_local => $TMON };
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        ok(!$@, "B3 boundary ($label): does not die") or diag("  \$\@ = $@");
        is(ref($rows) eq 'ARRAY' ? tui::Frame::spans_text($rows->[0]) : undef, $expect, "B3 boundary ($label) renders byte-exact");
    }
}

# ===========================================================================
# F12 -- two blueprints, different name widths.
# ===========================================================================
my ($F12_A, $F12_B);
{
    $F12_A = { blueprint => 'a', state => 'idle', packages_done => 0, packages_total => 1, next_package => '01-x' };
    $F12_B = { blueprint => 'longer-blueprint-name', state => 'running', packages_done => 2, packages_total => 4,
               packages => [ { name => '07-wide-package-name', status => 'running', step_word => 'tests', agents => [] } ] };
    my @lines = (
        G('icon.blueprints') . ' a' . S(5) . M(0, 1) . S(2) . '0/1' . S(3) . 'idle',
        S(2) . G('arrow.right') . ' 01-x' . S(2) . 'next',
        G('icon.blueprints') . ' longer-blueprint-name' . S(2) . M(2, 4) . S(2) . '2/4' . S(3) . 'running',
        S(2) . G('status.ok') . ' 07-wide-package-name' . S(3) . 'tests',
    );
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F12_A, $F12_B], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC12 precondition: _run_summary_lines([A,B]) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@lines, 'AC12: F12 (two blueprints, different name widths) renders byte-exact');
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY' && @$rows >= 4;
        my $dc_a = tui::Layout::display_width(tui::Frame::spans_text([ @{ $rows->[1] }[0 .. 2] ]));
        my $dc_b = tui::Layout::display_width(tui::Frame::spans_text([ @{ $rows->[3] }[0 .. 2] ]));
        is($dc_a, 10, 'AC12: block A sub-line detail column is 10');
        is($dc_b, 27, 'AC12: block B sub-line detail column is 27');
        isnt($dc_a, $dc_b, 'AC12: the two blocks\' detail columns genuinely differ');
    }
}

# ===========================================================================
# F13 -- no runs. F14 -- overflow.
# ===========================================================================
{
    my ($rows, $err) = call1('_blueprints_body_today', { runs => [] }, undef);
    ok(!$err, 'AC13 precondition: _blueprints_body_today({runs=>[]}) does not die') or diag("  error: $err");
    is(ref($rows) eq 'ARRAY' ? scalar(@$rows) : undef, 1, 'AC13: F13 (no runs) returns exactly one row') if ref($rows) eq 'ARRAY';
    like(ref($rows) eq 'ARRAY' ? tui::Frame::spans_text($rows->[0]) : '', qr/no active runs/, 'AC13: F13 text is "no active runs"');
}
{
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F12_A, $F12_B, $F4], 2, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC13 precondition: _run_summary_lines(3 runs, cap 2) does not die') or diag("  \$\@ = $err");
  SKIP: {
        skip('no rows', 1) unless ref($rows) eq 'ARRAY';
        is(tui::Frame::spans_text($rows->[-1]), '+1 more blueprint', 'AC13: F14 ends with "+1 more blueprint"');
    }
    my $rows3 = eval { tui::DashboardScreen::_run_summary_lines([$F12_A, $F12_B, $F4], 1, undef, $NOW) };
    ok(!$@, 'AC13 precondition: _run_summary_lines(3 runs, cap 1) does not die') or diag("  \$\@ = $@");
  SKIP: {
        skip('no rows', 1) unless ref($rows3) eq 'ARRAY';
        is(tui::Frame::spans_text($rows3->[-1]), '+2 more blueprints', 'AC13: 3 runs over a cap of 1 end with "+2 more blueprints"');
    }
}

# ===========================================================================
# F15 -- legacy summary (no `packages` key).
# ===========================================================================
{
    my $F15 = { blueprint => 'bp-legacy', state => 'running', packages_done => 1, packages_total => 3,
                current_package => 'pkg-a' };
    # W = 9.
    my @lines = (
        G('icon.blueprints') . ' bp-legacy' . S(2) . M(1, 3) . S(2) . '1/3' . S(3) . 'running',
        S(2) . G('status.ok') . ' pkg-a' . S(6) . 'running',
    );
    my $rows = eval { tui::DashboardScreen::_run_summary_lines([$F15], undef, undef, $NOW) };
    my $err = $@;
    ok(!$err, 'AC14 precondition: _run_summary_lines(F15) does not die') or diag("  \$\@ = $err");
    is_deeply(rows_text($rows), \@lines, 'AC14: F15 (legacy summary, no packages key) renders byte-exact');
}

# ===========================================================================
# F16 -- RunState end to end, TZ pinned (ruling C).
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = "$root/.ccpraxis-local-data/blueprints/acx-int";
    make_path($dir);
    make_path("$dir/runs");
    make_path("$dir/packages");

    write_file("$dir/blueprint.md", join("\n",
        '| pkg | deliverable | depends_on | model |',
        '|-----|-------------|------------|-------|',
        "| 01-a | x | \xE2\x80\x94 | sonnet |",
        '| 02-b | y | 01-a | sonnet |',
        '| 03-c | z | 01-a, 02-b | sonnet |',
        '| 04-d | w | 01-a | sonnet |',
        ''));
    write_file("$dir/packages/01-a.md", "---\npackage: 01-a\nstatus: done\n---\n# ledger\n");
    write_file("$dir/packages/02-b.md",
        "---\npackage: 02-b\nstatus: running\n---\n# ledger\n\n## Pipeline\n\n- [x] 1. Scout\n- [x] 2. Spec\n- [ ] 3. Tests\n");
    write_file("$dir/packages/03-c.md", "---\npackage: 03-c\nstatus: pending\n---\n# ledger\n");
    write_file("$dir/packages/04-d.md", "---\npackage: 04-d\nstatus: pending\n---\n# ledger\n");

    write_file("$dir/runs/.paused",
        '{"reason":"usage","relaunch_at":1762193100,"resets_at":1762192500,"created_at":1762000000}');
    write_file("$dir/runs/orchestrator.log", join("\n",
        '{"ts":1,"type":"pause","reason":"usage","window":"five_hour","resets_at":1,"relaunch_at":1,"util":0}',
        '{"ts":2,"type":"pause","reason":"usage","window":"seven_day","resets_at":2,"relaunch_at":1762193100,"util":0}',
        '{"ts":3,"type":"busy_lease_tick","util":0}',
        ''));

    local $ENV{TZ} = 'UTC';
    POSIX::tzset();
    local $RunState::PID_ALIVE = undef;

    my $s = eval { RunState::summarize_dir($dir) };
    my $err = $@;
    ok(!$err, 'F16 precondition: RunState::summarize_dir(acx-int) does not die') or diag("  \$\@ = $err");
  SKIP: {
        skip('summarize_dir died', 8) unless !$err && ref($s) eq 'HASH';
        is($s->{state}, 'paused', 'F16: state is paused');
        is($s->{paused_window}, 'seven_day', 'F16: paused_window is the LAST pause record\'s window');
        is($s->{relaunch_at}, 1762193100, 'F16: relaunch_at from .paused');
        is_deeply($s->{relaunch_local}, { wday => 'Mon', hhmm => '18:05', day => '03', mon => 'Nov' },
            'F16: relaunch_local under TZ=UTC');
        is($s->{next_package}, '04-d', 'F16: next_package skips 03-c (02-b not done) and picks 04-d');
        my ($pkg_b) = grep { ref($_) eq 'HASH' && ($_->{name} // '') eq '02-b' } @{ $s->{packages} || [] };
        ok($pkg_b, 'F16 precondition: package 02-b is present');
        is($pkg_b ? $pkg_b->{step_word} : undef, 'tests', 'F16: 02-b step_word is "tests"') if $pkg_b;

        my @lines = (
            G('icon.blueprints') . ' acx-int' . S(2) . M(1, 4) . S(2) . '1/4' . S(3) . G('thread.idle') . ' weekly limit until Mon 18:05',
            S(2) . G('status.ok') . ' 02-b' . S(5) . 'tests',
            S(2) . G('arrow.right') . ' 04-d' . S(5) . 'next',
        );
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$s], undef, undef, $NOW) };
        my $err2 = $@;
        ok(!$err2, 'F16 precondition: _run_summary_lines(summarize_dir result) does not die') or diag("  \$\@ = $err2");
        is_deeply(rows_text($rows), \@lines, 'F16: the rendered 3 rows match byte-exact under TZ=UTC');
    }

    # Non-vacuity: JST-9 proves host-local conversion, not a hardcoded UTC.
    {
        local $ENV{TZ} = 'JST-9';
        POSIX::tzset();
        local $RunState::PID_ALIVE = undef;
        my $s2 = eval { RunState::summarize_dir($dir) };
        ok(!$@, 'F16 non-vacuity precondition: summarize_dir under TZ=JST-9 does not die') or diag("  \$\@ = $@");
        is_deeply($s2->{relaunch_local}, { wday => 'Tue', hhmm => '03:05', day => '04', mon => 'Nov' },
            'F16 non-vacuity: relaunch_local under TZ=JST-9 proves host-local conversion, not hardcoded UTC')
            if ref($s2) eq 'HASH';
    }
    POSIX::tzset();
}

# ===========================================================================
# AC16 -- alignment, measured with tui::Layout::display_width.
# Done criterion (2). For every aligned-mode block above whose blueprint
# line has a non-empty detail: the first 2 spans' display width is W+4; for
# every sub-line with a non-empty detail: the first 3 spans' width is W+6.
# ===========================================================================
{
    my @cases = (
        [ 'F1',  $F1,  25 ],
        [ 'F3',  $F3,  15 ],
        [ 'F4',  $F4,  12 ],
    );
    for my $c (@cases) {
        my ($label, $summary, $w) = @$c;
        my $rows = eval { tui::DashboardScreen::_run_summary_lines([$summary], undef, undef, $NOW) };
        next if $@ || ref($rows) ne 'ARRAY' || !@$rows;
        if (@{ $rows->[0] } > 2) {
            my $dc = tui::Layout::display_width(tui::Frame::spans_text([ @{ $rows->[0] }[0, 1] ]));
            is($dc, $w + 4, "AC16 ($label): the blueprint line's detail column is W+4 ($w+4)");
        }
        for my $i (1 .. $#$rows) {
            my $line = $rows->[$i];
            next unless ref($line) eq 'ARRAY' && @$line > 3;
            my $dc = tui::Layout::display_width(tui::Frame::spans_text([ @{$line}[0 .. 2] ]));
            is($dc, $w + 6, "AC16 ($label): sub-line index $i detail column is W+6 ($w+6)");
        }
    }
}

# ===========================================================================
# AC17/AC18 -- done criterion (3): no glyph literal in tui/ source; the
# pause slot uses thread.idle (Decision 11 C4), never title.paused, in
# DashboardScreen.pm; U+23F8 pad correctness in every fixture row above.
# ===========================================================================
{
    my @pm_files = glob("$Bin/../../scripts/tui/*.pm");
    ok(scalar(@pm_files) > 0, 'AC17 precondition: tui/*.pm files are found');
    for my $f (@pm_files) {
        open(my $fh, '<:raw', $f) or next;
        local $/;
        my $raw = <$fh>;
        close $fh;
        my @high = ($raw =~ /([^\x00-\x7f])/g);
        my ($base) = $f =~ m{([^/\\]+)$};
        is(scalar(@high), 0, "AC17: $base contains no byte >= 0x80");
    }

    my $ds_path = "$Bin/../../scripts/tui/DashboardScreen.pm";
    open(my $fh, '<:raw', $ds_path) or die "cannot open $ds_path: $!";
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $src = $raw;
    $src =~ s/#[^\n]*//g;

    my @hex_escapes = ($src =~ /\\x\{([0-9A-Fa-f]+)\}/g);
    my @bad_hex = grep { hex($_) >= 0x80 } @hex_escapes;
    is(scalar(@bad_hex), 0, 'AC17: DashboardScreen.pm (comments stripped) contains no \x{...} escape >= 0x80');
    unlike($src, qr/\\N\{/, 'AC17: DashboardScreen.pm contains no \N{ escape');
    my @chr_calls = ($src =~ /\bchr\s*\(\s*0x([0-9A-Fa-f]+)\s*\)/g);
    my @bad_chr = grep { hex($_) >= 0x80 } @chr_calls;
    is(scalar(@bad_chr), 0, 'AC17: DashboardScreen.pm contains no chr(0x..) call >= 0x80');
    unlike($src, qr/23[Ff]8/, 'AC17: DashboardScreen.pm contains no 23F8/23f8 literal token');

    my $judge_count = () = ($src =~ /Theme::glyph\(\s*['"]status\.judge['"]\s*\)/g);
    is($judge_count, 1, 'AC17: Theme::glyph(\'status.judge\') occurs exactly once in DashboardScreen.pm');
    if ($src =~ /\bsub\s+_judge_marker\b(.*?)(?:\nsub\s|\z)/s) {
        like($1, qr/Theme::glyph\(\s*['"]status\.judge['"]\s*\)/, 'AC17: that one call site is inside _judge_marker');
    } else {
        fail('AC17: _judge_marker sub body not locatable for the one-call-site check');
    }

    # Decision 11 C4: the pause slot uses thread.idle, never title.paused, in
    # the Blueprints panel code. container_glyph's `title` family map feeds
    # the OS WINDOW TITLE (Dashboard.pm:670), the one place title.* glyphs
    # belong (Theme.pm; theme-tokens.t B-E14); it is pre-existing, unrelated
    # to the Blueprints panel, and may legitimately use 'title.paused'. Strip
    # that one sub's body before scanning so the whole-file check still
    # forbids title.paused everywhere else, including the Blueprints panel.
    (my $src_sans_container_glyph = $src) =~ s/\bsub\s+container_glyph\b.*?(?:\nsub\s|\z)/\nsub /s;
    my $title_paused_count = () = ($src_sans_container_glyph =~ /title\.paused/g);
    is($title_paused_count, 0, 'AC17 (Decision 11 C4): DashboardScreen.pm contains no title.paused token outside container_glyph\'s window-title map');
    like($src, qr/thread\.idle/, 'AC17 (Decision 11 C4) non-vacuity: DashboardScreen.pm DOES reference thread.idle somewhere');
}
{
    # AC18: pad check across the collected fixture rows above.
    my @all_rows = (@F1_LINES, @F3_LINES, @F4_LINES);
    my $idle_bytes = "\xE2\x8F\xB8";    # U+23F8
    my $found_any = 0;
    for my $row (@all_rows) {
        my $pos = 0;
        while (($pos = index($row, $idle_bytes, $pos)) >= 0) {
            $found_any = 1;
            my $after = substr($row, $pos + length($idle_bytes), 3);
            ok((substr($after, 0, 2) eq '  ') && (length($after) < 3 || substr($after, 2, 1) ne ' '),
                "AC18: U+23F8 at offset $pos in a fixture row is followed by exactly two spaces then a non-space byte")
                or diag("  row=[$row] after=[$after]");
            $pos += length($idle_bytes);
        }
    }
    ok($found_any, 'AC18 non-vacuity: at least one fixture row above contains U+23F8') if length(G('thread.idle'));
}

# ===========================================================================
# AC19/AC20 -- done criterion (4): wrap at 80/100/140; 6-row collapse.
# ===========================================================================
{
    for my $cols (80, 100, 140) {
        my $frame = eval { Dashboard::compose_frame({ runs => [$F1], now => $NOW, events => [], tokens => {} }, 60, $cols) };
        my $err = $@;
        ok(!$err, "AC19 (cols=$cols): Dashboard::compose_frame does not die") or diag("  \$\@ = $err");
      SKIP: {
            skip('no frame', 2) unless ref($frame) eq 'ARRAY';
            my @frame_text = map { ref($_) eq 'HASH' ? ($_->{text} // '') : '' } @$frame;
            for my $t (@frame_text) {
                my $w = tui::Layout::display_width($t);
                ok($w <= $cols, "AC19 (cols=$cols): no frame row exceeds $cols display columns") if length($t);
            }
            my @all_words = map { split /\s+/, $_ } grep { length } @F1_LINES;
            my $joined = join("\n", @frame_text);
            my @missing = grep { index($joined, $_) < 0 } grep { length } @all_words;
            is(scalar(@missing), 0, "AC19 (cols=$cols): every whitespace-separated word of F1's six rows appears in the frame")
                or diag('  missing: ' . join(', ', @missing));

            # step-7 strengthening (reviewer-step6.md BLOCKER-1, test gap):
            # "every word appears somewhere" cannot see the pause glyph's pad
            # being dropped at a span edge when the blueprint line wraps. At
            # 100 and 140 (AC19's spec text) every F1 row must be a PREFIX of
            # exactly one frame row -- not merely contain its words in order.
            if ($cols == 100 || $cols == 140) {
                for my $i (0 .. $#F1_LINES) {
                    my $line = $F1_LINES[$i];
                    my @hits = grep { index($_, $line) == 0 } @frame_text;
                    is(scalar(@hits), 1,
                        "AC19 (cols=$cols): F1 row L" . ($i + 1) . " is a prefix (index==0) of exactly one frame row");
                }
            }

            # At 80, the spec (S4 AC19) requires the blueprint line to wrap
            # into exactly two rows, the second BYTE-EXACT including the
            # pause glyph's full pad and separating space:
            # S(29).'5/14'.S(3).G('thread.idle').' weekly limit until Mon 18:05'
            # followed only by spaces. This is BLOCKER-1: the glyph span and
            # the words span are split at a single-space edge today, so
            # wrap_line drops the pad and this assertion fails against the
            # current implementation.
            if ($cols == 80) {
                my $l1_head = G('icon.blueprints') . ' acxpraxis-step-2' . S(11) . M(5, 14);
                my @l1_hits = grep { index($frame_text[$_], $l1_head) == 0 } (0 .. $#frame_text);
                is(scalar(@l1_hits), 1,
                    'AC19 (cols=80): exactly one frame row starts with the blueprint line\'s first wrapped segment');
              SKIP: {
                    skip('no L1 head row found', 1) unless @l1_hits == 1;
                    my $idx = $l1_hits[0];
                    my $second = $frame_text[$idx + 1] // '';
                    (my $second_trimmed = $second) =~ s/\s+\z//;
                    my $expect_second = S(29) . '5/14' . S(3) . G('thread.idle') . ' weekly limit until Mon 18:05';
                    is($second_trimmed, $expect_second,
                        'AC19 (cols=80, BLOCKER-1): the wrapped continuation keeps the pause glyph\'s full Theme pad and the separating space byte-exact');
                }
            }
        }
    }
}
{
    # step-7 strengthening (reviewer-step6.md MINOR-3): a run of single
    # spaces at a span edge (around ' . sep.dot . ' ') can wrap, leaving a
    # bare separator dangling at the end of a row. Reproduced at width 80
    # with F1's own '10-model-journal-recovery' package PLUS a second live
    # worker (so the ACTIVE detail has two ' sep.dot ' separators):
    # "  \xE2\x96\xB3 10-model-journal-recovery  implementation 5/5 \xC2\xB7"
    # -- the row ends in the dot with nothing after it.
    my $sepdot_run = {
        blueprint => 'acxpraxis-step-2', state => 'running', packages_done => 5, packages_total => 14,
        orchestrator_pid => undef, thread => undef,
        packages => [ { name => '10-model-journal-recovery', status => 'running', attempt => 5, attempt_cap => 5,
            step_word => 'implementation',
            agents => [ mk_agent(id => 'w1', role => 'worker', worker_type => 'bp-implementer', started_at => $NOW - 2460),
                        mk_agent(id => 'w2', role => 'worker', worker_type => 'bp-test-writer', started_at => $NOW - 900) ] } ],
        run_agents => [], next_package => undef,
    };
    my $sep_dot = G('sep.dot');
    my ($block, $eblock) = call1('_run_block', $sepdot_run, $NOW, 80);
    ok(!$eblock, 'MINOR-3 precondition: _run_block(sepdot_run, NOW, 80) does not die') or diag("  error: $eblock");
  SKIP: {
        skip('no block', 1) unless ref($block) eq 'HASH';
        my $bad = 0;
        for my $line (@{ $block->{lines} || [] }) {
            my ($rows, $erows) = call1('_wrap_block_row', $line->{spans}, 80, $block->{hang});
            next if $erows || ref($rows) ne 'ARRAY';
            for my $row (@$rows) {
                my $t = tui::Frame::spans_text($row);
                (my $trimmed = $t) =~ s/\s+\z//;
                $bad++ if length($sep_dot) && substr($trimmed, -length($sep_dot)) eq $sep_dot;
            }
        }
        is($bad, 0, 'MINOR-3: at 80 columns, no wrapped row (right-trimmed) ends with a lone sep.dot separator');
    }
}
{
    my ($body, $err) = call1('_blueprints_body', { runs => [$F1], now => $NOW, blueprint_body_rows => 6 }, 80);
    ok(!$err, 'AC20 (80x6): _blueprints_body does not die') or diag("  error: $err");
  SKIP: {
        skip('no body', 1) unless ref($body) eq 'ARRAY';
        my @texts = map { ref($_) eq 'ARRAY' ? tui::Frame::spans_text($_) : '' } @$body;
        s/\s+\z// for @texts;
        like(join("\n", @texts), qr/hidden \(short panel\)/, 'AC20 (80x6): a collapse notice is present');
    }
    my ($body2, $err2) = call1('_blueprints_body', { runs => [$F1], now => $NOW, blueprint_body_rows => 4 }, 140);
    ok(!$err2, 'AC20 (140x4): _blueprints_body does not die') or diag("  error: $err2");
  SKIP: {
        skip('no body', 2) unless ref($body2) eq 'ARRAY';
        my @texts = map { ref($_) eq 'ARRAY' ? tui::Frame::spans_text($_) : '' } @$body2;
        s/\s+\z// for @texts;
        like(join("\n", @texts), qr/\Q$F1_LINES[0]\E/, 'AC20 (140x4): the blueprint line (L1) is present');
        like(join("\n", @texts), qr/hidden \(short panel\)/, 'AC20 (140x4): a collapse notice is present, 3 rows hidden (L4-L6 dropped at the package tier)');
    }
}

# ===========================================================================
# AC20 (step-7 fix-batch): BLOCKER-2/MAJOR-2 -- per spec S2.2.1, a block gets
# row budget whatever its STATE ("2 or more lines", no state condition). The
# two tests above call _blueprints_body with blueprint_body_rows supplied
# DIRECTLY, which bypasses the real bug: compose()/_blueprints_capacity only
# ever SET blueprint_body_rows when _multiline_blocks($state) is true, and
# the current implementation keeps the old _tree_present gate (state eq
# 'running'). A PAUSED fleet -- the reviewer's and red-team's own repro
# (reviewer-step6.md BLOCKER-2; redteam-step6.md MAJOR-2, probe4 case B) --
# therefore never gets a capacity probe at all: _blueprints_capacity returns
# undef, blueprint_body_rows is never set, and the panel silently clips
# package lines with NO "+N rows hidden" notice, in exactly the state the
# operator most wants an honest panel.
# ===========================================================================
{
    my @pkgs40_paused;
    for my $i (1 .. 40) {
        push @pkgs40_paused, { name => sprintf('pz-%02d', $i), status => 'blocked', waits_on => undef };
    }
    my $F_PAUSED_OVERFLOW = {
        blueprint => 'bp-paused-overflow', state => 'paused', packages_done => 0, packages_total => 40,
        paused_reason => 'usage', paused_window => 'seven_day', relaunch_at => $NOW + 193_100,
        relaunch_local => { wday => 'Mon', hhmm => '18:05', day => '03', mon => 'Nov' },
        orchestrator_pid => 4242, orchestrator_alive => 1, orchestrator_started_at => $NOW - 500,
        running_coordinators => 0, escalations_waiting => 0, inbox_waiting => 0, triage_waiting => 0,
        thread => undef, packages => \@pkgs40_paused, run_agents => [],
        next_package => 'zz-never-shown',
    };

    my ($multi, $emulti) = call1('_multiline_blocks', { runs => [$F_PAUSED_OVERFLOW] });
    ok(!$emulti, 'AC20 (paused overflow) precondition: _multiline_blocks does not die') or diag("  error: $emulti");
    is($multi, 1,
        'AC20 (paused overflow, BLOCKER-2/MAJOR-2): _multiline_blocks returns 1 for a PAUSED run whose block has 2+ lines (blueprint + driver + 40 blocked packages), per S2.2.1 which has NO state condition');

    my $frame = eval { Dashboard::compose_frame({ runs => [$F_PAUSED_OVERFLOW], now => $NOW, events => [], tokens => {} }, 24, 100) };
    my $err = $@;
    ok(!$err, 'AC20 (paused overflow): Dashboard::compose_frame does not die') or diag("  \$\@ = $err");
  SKIP: {
        skip('no frame', 4) unless ref($frame) eq 'ARRAY';
        my @frame_text = map { ref($_) eq 'HASH' ? ($_->{text} // '') : '' } @$frame;
        my $joined = join("\n", @frame_text);
        like($joined, qr/hidden \(short panel\)/,
            'AC20 (paused overflow, BLOCKER-2/MAJOR-2): a short, PAUSED, overflowing panel shows the "+N row(s) hidden (short panel)" notice instead of silently clipping');
        my $shown_count = () = ($joined =~ /\bpz-\d\d\b/g);
        ok($shown_count > 0 && $shown_count < 40,
            "AC20 (paused overflow): only some of the 40 blocked-package lines are shown ($shown_count of 40) -- an actual collapse, not all-or-nothing");
        ok((index($joined, 'pz-01') >= 0),
            'AC20 (paused overflow): the FIRST package line (document order) survives the collapse');
        ok((index($joined, 'pz-40') < 0),
            'AC20 (paused overflow): the LAST package line is dropped (tier-3 prefix rule: collapse drops from the end first)');
    }
}

# ===========================================================================
# AC21 -- priority of plan entries.
# ===========================================================================
{
    my $F7_blocked = { blueprint => 'bp-blocked', state => 'running', packages_done => 2, packages_total => 5,
        packages => [ { name => '03-gamma', status => 'blocked', waits_on => '20261002-120000-abcd' } ] };
    # now=>$NOW (unlike the bare state above) so F1's judge/driver-uptime/
    # agent-elapsed lines are actually emitted -- otherwise the judge tier
    # never appears and "judge 4" below would be vacuously untestable.
    my ($plan, $err) = call1('_blueprints_row_plan', { runs => [$F1, $F7_blocked], now => $NOW }, 120);
    ok(!$err, 'AC21 precondition: _blueprints_row_plan([F1,F7]) does not die') or diag("  error: $err");
  SKIP: {
        skip('no plan', 1) unless ref($plan) eq 'ARRAY' && @$plan;

        # step-7 strengthening (reviewer-step6.md MAJOR-1): replace the
        # vacuous `ok(...) if exists ...` with the real S2.5 priority table
        # (blueprint 1, driver 2, package 3, judge 4, next 5), checked for
        # EVERY entry, plus non-vacuity that each kind actually occurred.
        my %expect_pri = (blueprint => 1, driver => 2, package => 3, judge => 4, next => 5);
        my $bad_pri = 0;
        for my $e (@$plan) {
            next unless ref($e) eq 'HASH';
            my $kind = $e->{kind} // '?';
            next unless exists $expect_pri{$kind};
            $bad_pri++ unless defined($e->{pri}) && $e->{pri} == $expect_pri{$kind};
        }
        is($bad_pri, 0,
            'AC21: every plan entry\'s pri matches its kind\'s S2.5 tier (blueprint=1, driver=2, package=3, judge=4, next=5)');
        for my $kind (sort { $expect_pri{$a} <=> $expect_pri{$b} } keys %expect_pri) {
            ok((grep { ref($_) eq 'HASH' && ($_->{kind} // '') eq $kind } @$plan),
                "AC21 non-vacuity: a $kind-kind entry (pri $expect_pri{$kind}) exists in the plan for [F1,F7]");
        }

        # Exact surviving rows for a FIXED short panel (budget=6, width=120):
        # MEASURED against this exact plan (probe, not guessed) -- tier 1
        # (both blueprint lines, cost 2) + tier 2 (F1's driver, cost 1) + ALL
        # THREE tier-3 package candidates fit exactly (cost 3), leaving no
        # room for F1's judge (pri 4) or next (pri 5) line: both are
        # dropped. This is the "packages 3, dropping from the end first"
        # rule in miniature -- at a tighter budget (below) a LATER package
        # line is dropped before an earlier one, even across blocks.
        my ($width, $ewidth) = call1('_blueprints_body_width', 120);
      SKIP: {
            skip('no width', 2) unless !$ewidth && defined($width);
            my ($keep6, $ekeep6) = call1('_select_rows', $plan, 6, $width);
            ok(!$ekeep6, 'AC21 (fixed short panel, budget=6): _select_rows does not die') or diag("  error: $ekeep6");
          SKIP: {
                skip('no keep6', 1) unless ref($keep6) eq 'ARRAY';
                my @kept_kinds = map { ref($plan->[$_]) eq 'HASH' ? ($plan->[$_]{kind} // '?') : '?' } @$keep6;
                my @kept_texts = map { ref($plan->[$_]) eq 'HASH' ? tui::Frame::spans_text($plan->[$_]{spans}) : undef } @$keep6;
                is_deeply(\@kept_kinds, [ 'blueprint', 'driver', 'package', 'package', 'blueprint', 'package' ],
                    'AC21 (fixed short panel, budget=6): the exact surviving kinds are both blueprint lines, F1\'s driver, both F1 package lines, and bp-blocked\'s one package line')
                    or diag('  kinds: ' . join(',', @kept_kinds));
                is_deeply(\@kept_texts,
                    [ $F1_LINES[0], $F1_LINES[1], $F1_LINES[2], $F1_LINES[3],
                      G('icon.blueprints') . ' bp-blocked' . S(2) . M(2, 5) . S(2) . '2/5' . S(3) . 'running',
                      S(2) . G('thread.blocked') . ' 03-gamma' . S(4) . 'blocked waiting on 20261002-120000-abcd' ],
                    'AC21 (fixed short panel, budget=6): the exact surviving row TEXT -- F1\'s judge and next lines (pri 4/5) are dropped for lack of room')
                    or diag('  texts: ' . join("\n", map { $_ // '<undef>' } @kept_texts));
            }

            # A tighter budget shows the tier-3 PREFIX rule across blocks:
            # at budget=4 only the FIRST package candidate (F1's
            # 05-checks-erlang) is admitted; F1's OWN second package line
            # and bp-blocked's package line (a DIFFERENT block, document
            # order AFTER it) are both dropped, because "the first tier-3
            # candidate whose closure does not fit ends tier 3 -- no LATER
            # package line, in any block, is admitted" (S2.5).
            my ($keep4, $ekeep4) = call1('_select_rows', $plan, 4, $width);
            ok(!$ekeep4, 'AC21 (fixed short panel, budget=4): _select_rows does not die') or diag("  error: $ekeep4");
          SKIP: {
                skip('no keep4', 1) unless ref($keep4) eq 'ARRAY';
                my @kept_texts4 = map { ref($plan->[$_]) eq 'HASH' ? tui::Frame::spans_text($plan->[$_]{spans}) : undef } @$keep4;
                is_deeply(\@kept_texts4,
                    [ $F1_LINES[0], $F1_LINES[1], $F1_LINES[2],
                      G('icon.blueprints') . ' bp-blocked' . S(2) . M(2, 5) . S(2) . '2/5' . S(3) . 'running' ],
                    'AC21 (fixed short panel, budget=4, tier-3 prefix rule): F1\'s SECOND package line and bp-blocked\'s package line (later in document order) are both dropped once the first tier-3 candidate that does not fit ends the whole tier')
                    or diag('  texts: ' . join("\n", map { $_ // '<undef>' } @kept_texts4));
            }
        }
    }
    my ($plan3, $err3) = call1('_blueprints_row_plan', { runs => [$F1, $F7_blocked, $F4], blueprint_rows_max => 2 }, 120);
    ok(!$err3, 'AC21 precondition: _blueprints_row_plan with blueprint_rows_max=>2 does not die') or diag("  error: $err3");
  SKIP: {
        skip('no plan3', 1) unless ref($plan3) eq 'ARRAY';
        my @overflow = grep { ref($_) eq 'HASH' && ($_->{kind} // '') eq 'overflow' } @$plan3;
        ok(scalar(@overflow) >= 1, 'AC21: an overflow-kind entry is added at pri 1 when blueprint_rows_max is exceeded');
    }

    my ($plan_nb, $err_nb) = call1('_blueprints_row_plan', { runs => [$F1] }, 120);
    my $body = eval { tui::DashboardScreen::_blueprints_body({ runs => [$F1] }, 120) };
    ok(!$@, 'AC21 precondition: _blueprints_body (no budget) does not die') or diag("  \$\@ = $@");
  SKIP: {
        skip('no plan_nb', 1) unless ref($plan_nb) eq 'ARRAY' && ref($body) eq 'ARRAY';
        my @plan_spans = map { ref($_) eq 'HASH' ? $_->{spans} : undef } @$plan_nb;
        is_deeply(\@plan_spans, $body, 'AC21: with no budget, [map {spans} @plan] is_deeply _blueprints_body');
    }
}

# ===========================================================================
# AC22 -- compact mode.
# ===========================================================================
{
    my ($block, $err) = call1('_run_block', $F1, $NOW, 50);
    ok(!$err, 'AC22 precondition: _run_block(F1, NOW, 50) does not die') or diag("  error: $err");
  SKIP: {
        skip('no block', 2) unless ref($block) eq 'HASH';
        is($block->{hang}, 2, 'AC22: _run_block(F1, NOW, 50) has hang==2 (compact mode)');
        for my $line (@{ $block->{lines} || [] }) {
            next unless ref($line) eq 'HASH' && ref($line->{spans}) eq 'ARRAY' && @{ $line->{spans} } > 2;
            my $text = tui::Frame::spans_text($line->{spans});
            like($text, qr/\S\s\s\S/, 'AC22: a compact-mode line with detail has its name followed by exactly two spaces')
                if length($text);
        }
    }
    my ($block59, $err59) = call1('_run_block', $F1, $NOW, 59);
    ok(!$err59, 'AC22 precondition: _run_block(F1, NOW, 59) does not die') or diag("  error: $err59");
    is(ref($block59) eq 'HASH' ? $block59->{hang} : undef, 29, 'AC22: at width 59 (max(25+26,2*25+9)=59) F1 is aligned (hang=W+4=29)')
        if ref($block59) eq 'HASH';
    my ($block58, $err58) = call1('_run_block', $F1, $NOW, 58);
    ok(!$err58, 'AC22 precondition: _run_block(F1, NOW, 58) does not die') or diag("  error: $err58");
    is(ref($block58) eq 'HASH' ? $block58->{hang} : undef, 2, 'AC22: at width 58 F1 is compact (hang=2)')
        if ref($block58) eq 'HASH';
}

done_testing();
