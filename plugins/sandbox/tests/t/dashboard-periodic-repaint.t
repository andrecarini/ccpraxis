#!/usr/bin/env perl
# platform: any
# The dashboard re-emits every row (without clearing) every FULL_REPAINT_SECS.
#
# Why (operator, 2026-11-03): the MSYS runtime printed "dofork: child -1 -
# forked process ... died unexpectedly ... error 1455" straight onto the
# console when a sampler's fork hit the Windows commit limit. The renderer
# repaints only rows whose content changed, so the text stayed on screen until
# the operator pressed [r]. A periodic full re-emit bounds that to seconds.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

my $PERIOD = Dashboard::FULL_REPAINT_SECS();
cmp_ok($PERIOD, '>', 0,   'the period is positive');
cmp_ok($PERIOD, '<=', 60, 'and short enough that stray text does not linger for minutes');

my $ROWS  = 24;
my $clock = 1_000_000;
my @chunks;
Dashboard::run(
    beat_interval  => 100000,
    state_interval => 1,
    tick_interval  => 1,
    color          => 0,
    max_ticks      => int($PERIOD * 2.5),
    now            => sub { $clock },
    sleep_for      => sub { $clock += $_[0] },
    read_key       => sub { undef },
    term_size      => sub { (80, $ROWS) },
    gather         => sub { { project_name => 'demo', container => 'c1', status => 'running', events => [] } },
    heartbeat      => sub { 'ok' },
    spawn          => sub { undef },
    enter_raw      => sub { },
    leave_raw      => sub { },
    keepawake      => sub { },
    out            => sub { push @chunks, [$clock, $_[0]] },
);

my @full = grep { $_->[1] =~ /\e\[2J/ } @chunks;
my @reemit = grep {
    my $s = $_->[1];
    my %rows = map { $_ => 1 } ($s =~ /\e\[(\d+);1H\e\[K/g);
    $s !~ /\e\[2J/ && keys(%rows) >= $ROWS;
} @chunks;

is(scalar @full, 1, 'the screen is cleared exactly once (the first frame), never periodically');
cmp_ok(scalar @reemit, '>=', 2, "every row is re-emitted, without clearing, at least twice in 2.5 periods")
    or diag(scalar(@chunks) . ' chunks written');
if (@reemit >= 2) {
    my $gap = $reemit[1][0] - $reemit[0][0];
    cmp_ok(abs($gap - $PERIOD), '<=', 1, "the re-emits are one period apart (gap ${gap}s)");
}

done_testing();
