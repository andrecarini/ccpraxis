#!/usr/bin/env perl
# platform: any
# Blueprints panel: ONE set of columns across every block (operator,
# 2026-11-11, from the fleet scenario: the meter, the count and the driver
# started in a different column on every blueprint line).
#
# Pins:
#   B1. every blueprint line's meter starts in the same column, and so does
#       its d/t count, across blocks with names and counts of different widths;
#   B2. the driver/state text starts after the aligned count, in one column;
#   P1. the package step word (word mode) and the pipeline strip (strip mode)
#       start in the same column in every block;
#   C1. a blueprint name over BP_NAME_MAX is cut with the theme's ellipsis to
#       exactly BP_NAME_MAX columns; one at or under it is drawn whole;
#   W1. alignment never makes a line wrap that fit on one row before: at a
#       width where every line fit unpadded, every line still fits, the name
#       column shrinking instead (to 2 columns at the least).
#
# Non-vacuity, measured 2026-11-11 against HEAD 8418620's DashboardScreen.pm:
# B1/B2 fail (8 not ok: each line placed its meter 3 columns after its own
# name), then the file dies at BP_NAME_MAX, which HEAD lacks; P1 passed there -- package columns were
# panel-wide before this change, and P1 keeps them so.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

require Theme;
require tui::Frame;
require tui::Layout;
require tui::DashboardScreen;

my $NOW = 1_762_000_000;
sub G { my ($n) = @_; return Theme::glyph($n) // ''; }
my $DW = sub { tui::Layout::display_width($_[0]) // 0 };

# col($text, $needle) -> display column where $needle starts, or undef.
sub col {
    my ($t, $needle) = @_;
    my $i = index($t, $needle);
    return undef if $i < 0;
    return $DW->(substr($t, 0, $i));
}
sub pipeline {
    my ($cur) = @_;
    my @w = qw(scout spec tests implementation validation review fix-batch);
    my $seen = 0;
    return [ map { my $n = $_ + 1; my $st = $seen ? 'todo' : ($w[$_] eq $cur ? do { $seen = 1; 'todo' } : 'done');
                   { n => [$n], label => $w[$_], word => $w[$_], state => $st } } 0 .. $#w ];
}
sub pkg { my (%o) = @_; return { name => $o{name}, status => 'running', attempt => 1, attempt_cap => 5,
                                 step_word => $o{step}, agents => [], coordinator_alive => 1,
                                 pipeline => $o{pipe} ? pipeline($o{step}) : undef }; }
sub run {
    my (%o) = @_;
    return { blueprint => $o{bp}, state => 'running', orchestrator_pid => 7, orchestrator_alive => 1,
             orchestrator_started_at => $NOW - 3600, packages_done => $o{d}, packages_total => $o{t},
             packages => $o{pkgs} || [] };
}
# rcol($text, $needle) -> column of the LAST occurrence (a reason word also
# appears inside a package name like 02-parked).
sub rcol { my ($t, $n) = @_; my $i = rindex($t, $n); return $i < 0 ? undef : $DW->(substr($t, 0, $i)); }
sub lines_of {
    my ($runs, $w) = @_;
    my $blocks = tui::DashboardScreen::_panel_blocks($runs, $NOW, $w);
    my (@bp, @pk);
    for my $b (@$blocks) {
        for my $ln (@{ $b->{lines} }) {
            my $rows = tui::DashboardScreen::_line_rows($b, $ln, $w);
            my $t = tui::Frame::spans_text($rows->[0]);
            if ($ln->{kind} eq 'blueprint') { push @bp, { text => $t, rows => scalar(@$rows) } }
            else { push @pk, $t }
        }
    }
    return (\@bp, \@pk);
}

my @RUNS = (
    run(bp => 'a',                     d => 1,  t => 4,  pkgs => [ pkg(name => '01-x', step => 'tests', pipe => 1) ]),
    run(bp => 'fleet-observability',   d => 12, t => 15, pkgs => [ pkg(name => '07-wide-package-name', step => 'review', pipe => 1) ]),
    run(bp => 'mid-length-name',       d => 0,  t => 3,  pkgs => [ pkg(name => '3', step => 'implementation', pipe => 1) ]),
);
my $FULL = G('gauge.full'); my $EMPTY = G('gauge.empty');

# --- B1/B2 ------------------------------------------------------------------
for my $w (121, 180) {
    my ($bp) = lines_of(\@RUNS, $w);
    is(scalar(@$bp), 3, "B0 ($w): three blueprint lines");
    my @meter = map { my $t = $_->{text}; my $i = col($t, $FULL); my $j = col($t, $EMPTY);
                      defined $i && (!defined $j || $i < $j) ? $i : $j } @$bp;
    my @count = map { my ($c) = $_->{text} =~ m{(\d+/\d+)}; col($_->{text}, $c) } @$bp;
    my @drv   = map { col($_->{text}, G('status.ok')) } @$bp;
    ok(defined $meter[0], "B1 ($w): the meter is found");
    is_deeply([ @meter[1, 2] ], [ $meter[0], $meter[0] ], "B1 ($w): every blueprint line's meter starts in one column ($meter[0])");
    is($count[0] - 0, $count[0], "B1 ($w): count found");
    is_deeply([ @count[1, 2] ], [ $count[0], $count[0] ], "B1 ($w): every d/t count starts in one column ($count[0])");
    is_deeply([ @drv[1, 2] ], [ $drv[0], $drv[0] ], "B2 ($w): the driver starts in one column too, after the aligned count");
    is($meter[0], 2 + $DW->('fleet-observability') + 3, "B1 ($w): the name column is the widest name present (19), not the cap");
    is(scalar(grep { $_->{rows} == 1 } @$bp), 3, "B1 ($w): and no line wraps");
}

# --- P1 ---------------------------------------------------------------------
{
    my (undef, $pk) = lines_of(\@RUNS, 180);
    my @strip = map { my $t = $_; my ($first) = grep { defined } map { col($t, $_) } ('sco', 'spe'); $first } @$pk;
    is(scalar(grep { defined } @strip), 3, 'P1 precondition: the pipeline strip is drawn on all three package rows (strip mode)');
    # the strip's FIRST cell column: 'sco' of every row (all three have scout)
    my @sco = map { col($_, 'sco') } @$pk;
    is_deeply([ @sco[1, 2] ], [ $sco[0], $sco[0] ], 'P1: the pipeline strip starts in one column in every block');

    # no checklists anywhere -> word mode
    my @WORD = map { my %r = %$_; $r{packages} = [ map { +{ %$_, pipeline => undef } } @{ $_->{packages} } ]; \%r } @RUNS;
    my (undef, $pk80) = lines_of(\@WORD, 120);
    my @word = (col($pk80->[0], 'tests'), col($pk80->[1], 'review'), col($pk80->[2], 'implementation'));
    is(scalar(grep { defined } @word), 3, 'P1 precondition: word mode (no checklists)');
    is_deeply([ @word[1, 2] ], [ $word[0], $word[0] ], 'P1: the step word starts in one column in every block');
}

# --- C1 ---------------------------------------------------------------------
{
    my $MAX = tui::DashboardScreen::BP_NAME_MAX();
    cmp_ok($MAX, '>=', 22, 'C1: BP_NAME_MAX is in the 22-24 range'); cmp_ok($MAX, '<=', 24, 'C1: (upper)');
    my $long = 'an-extremely-long-blueprint-name-that-goes-on';
    my ($bp) = lines_of([ run(bp => $long, d => 1, t => 2), run(bp => 'short', d => 0, t => 2) ], 180);
    my $E = tui::Frame::ELLIPSIS();
    my ($shown) = $bp->[0]{text} =~ /\A\S+ (\S+)/;
    like($shown, qr/\Q$E\E\z/, 'C1: an over-long name ends with the theme ellipsis');
    is($DW->($shown), $MAX, "C1: and is exactly BP_NAME_MAX ($MAX) columns");
    like($bp->[1]{text}, qr/\A\S+ short /, 'C1: a short name is drawn whole');
    is(col($bp->[0]{text}, '1/2'), col($bp->[1]{text}, '0/2'), 'C1: the capped line and the short one still share the count column');
    my ($exact) = lines_of([ run(bp => 'x' x $MAX, d => 1, t => 2) ], 180);
    unlike($exact->[0]{text}, qr/\Q$E\E/, 'C1: a name of exactly BP_NAME_MAX is not cut');
}

# --- W1 ---------------------------------------------------------------------
{
    # 'z' (1 col) and a 24-col name; at a width where the short line fits only
    # unpadded, the column shrinks to keep it on one row.
    my @r = (run(bp => 'z', d => 1, t => 2), run(bp => 'y' x 24, d => 1, t => 2));
    my ($wide) = lines_of(\@r, 180);
    my $short_w = $DW->($wide->[0]{text}) - (24 - 1);    # its natural one-row width
    my $w = $short_w + 5;                                # fits unpadded, not padded to 24
    my ($bp) = lines_of(\@r, $w);
    is($bp->[0]{rows}, 1, "W1: at width $w the short line still fits on one row");
    cmp_ok($DW->($bp->[0]{text}), '<=', $w, 'W1: and within the width');
    is(col($bp->[0]{text}, '1/2'), col($bp->[1]{text}, '1/2'), 'W1: the two lines still share the count column (the long name shrank)');
    like($bp->[1]{text}, qr/\Q@{[tui::Frame::ELLIPSIS()]}\E/, 'W1: the long name is the one cut');
    my ($tiny) = lines_of([ run(bp => 'z', d => 1, t => 2) ], 30);
    unlike($tiny->[0]{text}, qr/\Az {2,}/, 'W1: a lone short name is never padded past itself (the 2-column floor never widens)');
}

# ===========================================================================
# Second review (operator, 2026-11-11): blank rows between blocks, ONE
# status column for package rows, ONE state column on blueprint lines.
# ===========================================================================
sub body_texts {
    my ($state, $cols) = @_;
    return [ map { tui::Frame::spans_text($_) } @{ tui::DashboardScreen::_blueprints_body($state, $cols) } ];
}
# state_col($text) -> column where the state/pause/decision words start on a
# blueprint line: after the count, past the driver (if any), the next word.
sub state_col {
    my ($t) = @_;
    return undef unless $t =~ m{\A(.*?\d+/\d+ +)}s;
    my $pre = $1;
    my $rest = substr($t, length $pre);
    if ($rest =~ /\A(\S+ (?:orchestrator|session|unowned|handed off)(?: (?!\s)[^\s\x{2691}]+)?(?: +|\z))/) { $pre .= $1; }
    return length(substr($t, length $pre)) ? $DW->($pre) : undef;
}

# G1 -- one blank row between blocks, and the blank rows go first.
{
    my @r = (run(bp => 'alpha-fleet', d => 1, t => 3, pkgs => [ pkg(name => '01-a', step => 'tests') ]),
             run(bp => 'beta-fleet',  d => 0, t => 2, pkgs => [ pkg(name => '02-b', step => 'review') ]),
             run(bp => 'gamma-fleet', d => 2, t => 2, pkgs => [ pkg(name => '03-c', step => 'spec') ]));
    my $st = { runs => \@r, now => $NOW };
    my $t = body_texts($st, 121);
    is(scalar(@$t), 3 * 2 + 2, 'G1: three two-row blocks and two blank rows');
    is_deeply([ @$t[2, 5] ], [ '', '' ], 'G1: exactly one blank row between consecutive blocks');
    isnt($t->[-1], '', 'G1: no trailing blank row after the last block');
    my $plan = tui::DashboardScreen::_blueprints_row_plan($st, 121);
    is(scalar(grep { $_->{kind} eq 'gap' } @$plan), 2, 'G1: the row plan carries the two gaps (kind gap)');

    $st->{blueprint_body_rows} = 7;    # one short: a gap goes, no content does, no notice
    $t = body_texts($st, 121);
    is(scalar(grep { $_ ne '' } @$t), 6, 'G2: one row short -> every content row still shown');
    unlike(join("\n", @$t), qr/hidden/, 'G2: and no "rows hidden" notice (nothing is hidden)');
    $st->{blueprint_body_rows} = 6;    # exactly the content
    $t = body_texts($st, 121);
    is_deeply([ grep { $_ eq '' } @$t ], [], 'G2: at exactly the content height, both blank rows are gone');
    is(scalar(@$t), 6, 'G2: and all six content rows remain');
    $st->{blueprint_body_rows} = 5;    # content must give: the notice counts content only
    $t = body_texts($st, 121);
    my ($n) = $t->[-1] =~ /\+(\d+) rows? hidden/;
    ok(defined $n, 'G3: below the content height the collapse notice appears');
    is_deeply([ grep { $_ eq '' } @$t ], [], 'G3: no blank row survives while content is hidden');
    is($n, 6 - (scalar(@$t) - 1), 'G3: the notice counts hidden CONTENT rows, never the dropped blanks');
}

# S1 -- ONE status column, LEFT-aligned, after the step word or strip: step
# times, next, parked, blocked and `waiting on <dep>` all start in it; ONE
# attempt column after it; a long `waiting on` is cut only where an attempt
# follows (operator, 2026-11-11, second and third reviews).
{
    my $live = sub { my ($n, $step, $age, %o) = @_;
        return { %{ pkg(name => $n, step => $step) }, %o,
                 agents => [ { id => "w$n", role => 'worker', worker_type => 'bp-x', started_at => $NOW - $age,
                               budget_seconds => 1800, stale_after_seconds => 7200 } ] } };
    my @r = (run(bp => 'one', d => 0, t => 3, pkgs => [
                 $live->('01-live', 'implementation', 21 * 60, attempt => 3),
                 $live->('02-short', 'tests', 5 * 60),
                 { name => '03-parked', status => 'parked', agents => [] },
                 { name => '04-blocked', status => 'blocked', agents => [] },
                 { name => '05-waits', status => 'blocked', waits_on => '01-live-and-a-long-dependency-name', agents => [] },
                 { name => '06-waits-retry', status => 'blocked', waits_on => '01-live-and-a-long-dependency-name',
                   attempt => 2, attempt_cap => 5, agents => [] } ]),
             run(bp => 'two', d => 0, t => 1, pkgs => [ $live->('07-other', 'review', 40, attempt => 2) ]));
    for my $w (121, 180) {
        my (undef, $pk) = lines_of(\@r, $w);
        my $sc = col($pk->[0], '21m');
        ok(defined $sc, "S1 ($w) precondition: the step time is drawn");
        is(col($pk->[1], '5m'), $sc, "S1 ($w): step times are LEFT-aligned: 5m starts where 21m starts");
        is(rcol($pk->[2], 'parked'),  $sc, "S1 ($w): parked starts in the status column");
        is(rcol($pk->[3], 'blocked'), $sc, "S1 ($w): blocked starts in the status column");
        is(col($pk->[4], 'waiting on'), $sc, "S1 ($w): waiting on starts in the status column");
        is(col($pk->[6], '<1m'), $sc, "S1 ($w): another block's time starts there too");
        cmp_ok($sc, '>', col($pk->[0], 'implementation') + $DW->('implementation'), "S1 ($w): the status column comes after the step word");
        like($pk->[4], qr/dependency-name\z/, "S1 ($w): a long waiting on with no attempt runs on, uncut");
        my @at = map { col($pk->[$_], 'attempt') } (0, 5, 6);
        is(scalar(grep { defined } @at), 3, "S1 ($w) precondition: three rows carry an attempt");
        is_deeply([ @at[1, 2] ], [ $at[0], $at[0] ], "S1 ($w): every attempt starts in one column, whatever the status");
        like($pk->[5], qr/\x{2026}|\xe2\x80\xa6/, "S1 ($w): a long waiting on followed by an attempt is cut with the ellipsis");
        cmp_ok($at[0] - $sc, '<=', tui::DashboardScreen::STATUS_COL_MAX() + 3, "S1 ($w): the status column is at most STATUS_COL_MAX wide");
    }
}

# D1 -- one state column on blueprint lines, driver or not.
{
    my %fs = (shutdown => 0, operator_stop => 0, operator_stop_at => undef);
    my @r = (
        { %{ run(bp => 'live-fleet', d => 1, t => 3) }, orchestrator_started_at => $NOW - 6 * 3600 },
        { %{ run(bp => 'paused-fleet', d => 1, t => 3) }, state => 'paused', paused_reason => 'usage', paused_window => 'five_hour',
          orchestrator_started_at => $NOW - 30 * 3600 },
        { %{ run(bp => 'dead-fleet', d => 2, t => 5) }, state => 'stale', orchestrator_alive => 0, fleet => { %fs },
          packages => [ { name => '01-x', status => 'running', agents => [] } ] },
        { %{ run(bp => 'mine', d => 1, t => 3) }, state => 'parked', orchestrator_pid => undef, orchestrator_alive => undef,
          fleet => { %fs, shutdown => 1, operator_stop => 1 }, packages => [ { name => '01-x', status => 'parked' } ] },
        { blueprint => 'done-fleet', state => 'idle', packages_done => 2, packages_total => 2, fleet => { %fs },
          packages => [ { name => '01-x', status => 'done' }, { name => '02-y', status => 'done' } ] },
        { blueprint => 'solo-run', state => 'solo', packages_done => 0, packages_total => 2, packages => [] },
    );
    for my $w (121, 180) {
        my ($bp) = lines_of(\@r, $w);
        my @sc = map { state_col($_->{text}) } @$bp[1 .. 5];
        is(scalar(grep { defined } @sc), 5, "D1 ($w): every line but the live one carries a state word");
        is_deeply([ @sc[1 .. 4] ], [ ($sc[0]) x 4 ],
            "D1 ($w): pause text, stopped, stopped by you, settled and solo all start in one column ($sc[0])")
            or diag(join("\n", map { $_->{text} } @$bp));
        is(scalar(grep { $_->{rows} == 1 } @$bp), 6, "D1 ($w): and no line wraps");
    }
}

# A1 -- both preview scenarios, at 121 and 180: every visible column lines up.
{
    no warnings 'once';
    my $PREVIEW = "$Bin/../../../../scripts/tui-preview.pl";
    my $loaded = eval { require $PREVIEW; 1 };
    ok($loaded, 'A1 precondition: scripts/tui-preview.pl loads') or diag($@);
    for my $sc (qw(fleet operator)) {
        for my $cols (121, 180) {
            local $main::SCENARIO = $sc;
            my $st = main::synth_state(10, undef, undef);
            my $main = $cols - tui::Screen::side_column_width($cols);
            my $t = body_texts($st, $main);
            my @bpl = grep { /\A\Q@{[G('icon.blueprints')]}\E / } @$t;
            my @pkl = grep { /\A  \S/ } @$t;
            cmp_ok(scalar(@pkl), '>=', 2 * scalar(@bpl), "A1 ($sc, $cols): realistic content -- several package rows per blueprint");
            my %c;
            push @{ $c{meter} }, col($_, (/\Q$FULL\E/ && (index($_, $FULL) < (index($_, $EMPTY) < 0 ? 1e9 : index($_, $EMPTY)))) ? $FULL : $EMPTY) for @bpl;
            push @{ $c{count} }, do { my ($n) = m{(\d+/\d+)}; col($_, $n) } for @bpl;
            push @{ $c{state} }, grep { defined } map { state_col($_) } @bpl;
            push @{ $c{name} }, map { my $x = $_; $x =~ /\A  \S+ +(\S)/ ? $DW->(substr($x, 0, $-[1])) : () } @pkl;
            for my $k (sort keys %c) {
                my %u = map { $_ => 1 } @{ $c{$k} };
                is(scalar(keys %u), 1, "A1 ($sc, $cols): the $k column is one column across the panel")
                    or diag("$k: @{ $c{$k} }\n" . join("\n", @$t));
            }
            # One status column (next, parked, waiting on, no checklist), one
            # attempt column, and -- at these widths -- the blueprint state
            # words in that same status column, top to bottom.
            my ($nx) = grep { /\snext\z/ } @pkl;
            my $stcol = defined($nx) ? rcol($nx, 'next') : undef;
            ok(defined $stcol, "A1 ($sc, $cols) precondition: a next row gives the status column");
            my @stc = map { my $x = $_; (grep { index($x, $_) >= 0 } (' parked')) ? rcol($x, 'parked')
                                      : (index($x, 'waiting on') >= 0) ? col($x, 'waiting on')
                                      : (index($x, 'no checklist') >= 0) ? col($x, 'no checklist') : () } @pkl;
            cmp_ok(scalar(@stc), '>=', 2, "A1 ($sc, $cols) precondition: reasons to compare");
            is_deeply([ sort { $a <=> $b } keys %{{ map { $_ => 1 } @stc, $stcol }} ], [ $stcol ],
                "A1 ($sc, $cols): next, parked, waiting on and no checklist all start in the status column");
            my @att = map { col($_, 'attempt') } grep { /attempt \d/ } @pkl;
            cmp_ok(scalar(@att), '>=', 2, "A1 ($sc, $cols) precondition: several attempt counters");
            is(scalar(keys %{{ map { $_ => 1 } @att }}), 1, "A1 ($sc, $cols): every attempt starts in one column");
            is_deeply([ sort { $a <=> $b } keys %{{ map { $_ => 1 } @{ $c{state} } }} ], [ $stcol ],
                "A1 ($sc, $cols): the blueprint lines' state words start in the package status column -- one status column top to bottom");
            my @gaps = grep { $t->[$_] eq '' } 0 .. $#$t;
            is(scalar(@gaps), scalar(@bpl) - 1, "A1 ($sc, $cols): one blank row between each pair of blocks");
        }
    }
}

done_testing();
