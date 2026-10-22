#!/usr/bin/env perl
# platform: any
#
# Follow-ups to where-things-go package 13 (dashboard-threads), from its
# deferred todos:
#
#   20261002-193830-34ac0000  a project with NO blueprint summary showed no
#                             thread events at all (they only rode on runs)
#   20261002-235037-d62e0000  redteam L1-L4, L6 and reviewer N1-N3
#
# Pure: RunState / Dashboard / tui::DashboardScreen in-process against
# File::Temp fixtures. Never loads launcher.pl (static source checks only).

use strict;
use warnings;
no warnings "once";   # RunState package vars are read across the package boundary
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require RunState;
require Dashboard;
require tui::DashboardScreen;

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "write_file($path): $!";
    print $fh $content;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $s = <$fh>; close $fh; $s }
sub rec {
    my (@kv) = @_;
    my @l = ('---');
    while (@kv) { my ($k, $v) = splice(@kv, 0, 2); push @l, "$k: $v" if defined $v }
    return join("\n", @l, '---', '');
}
sub iso_of {
    my @t = gmtime($_[0]);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}
sub alm { "$_[0]/.ccpraxis-local-data/almanac" }
sub thread_rec { my ($P, $name, @kv) = @_; make_path(alm($P) . '/thread'); write_file(alm($P) . "/thread/$name.md", rec(@kv)) }
sub log_rec {
    my ($P, $thread, $id, @kv) = @_;
    my $d = alm($P) . "/thread-log-$thread"; make_path($d); write_file("$d/$id.md", rec(@kv));
}
sub ledger {
    my ($P, $bp, $pkg) = @_;
    my $d = "$P/.ccpraxis-local-data/blueprints/$bp/packages"; make_path($d);
    write_file("$d/$pkg.md", "---\nstatus: pending\n---\n\n## Pipeline\n\n- [ ] 1. scout\n");
}
my $EPOCH = 1_790_000_000;
sub quiet(&) { my ($cb) = @_; my @w; local $SIG{__WARN__} = sub { push @w, $_[0] }; my @r = $cb->(); return (\@w, @r) }

# ---------------------------------------------------------------- 193830: no blueprint, still thread events
{
    my $P = tempdir(CLEANUP => 1);
    thread_rec($P, 'solo-thread', created => iso_of($EPOCH - 100), state => 'live', owner_kind => 'none');
    log_rec($P, 'solo-thread', '00000001', at => iso_of($EPOCH), actor => 'driver', event => 'created');
    my $root = "$P/.ccpraxis-local-data/blueprints";   # deliberately does not exist

    my %extra;
    my $runs = RunState::summarize($root, \%extra);
    is_deeply($runs, [], 'no blueprint -> no summaries');
    is(ref($extra{thread_events}), 'ARRAY', 'the out parameter is filled anyway');
    is(scalar(@{ $extra{thread_events} || [] }), 1, '...with the project\'s thread event');
    is(($extra{thread_events}[0] || {})->{event}, 'created', '...the right one');
    is_deeply(RunState::summarize($root), [], 'one-argument summarize is unchanged');

    my $carriers = Dashboard::thread_event_carriers({ runs => $runs, thread_events => $extra{thread_events} });
    my $merged = Dashboard::merge_thread_events([], $carriers, sub { gmtime($_[0]) }, $EPOCH + 60);
    ok((grep { Dashboard::spans_text($_) =~ /created thread=solo-thread/ } @$merged),
       'the merged feed shows the event with no run to carry it');
    is_deeply(Dashboard::thread_event_carriers(undef), [], 'carriers: non-HASH -> []');
    is(scalar @{ Dashboard::thread_event_carriers({ runs => [ {}, {} ] }) }, 2, 'carriers: no thread_events key -> runs only');

    # The wiring, statically (launcher.pl is never loaded).
    my $L = slurp("$Bin/../../scripts/launcher.pl") // '';
    like($L, qr/_gather_runs\(\$PROJECT_PATH, \\%runs_extra\)/, 'launcher gathers with the out parameter');
    like($L, qr/thread_events\s*=>\s*\$cached_thread_events/, 'launcher passes thread_events in the gathered state');
    my $D = slurp("$Bin/../../scripts/Dashboard.pm") // '';
    like($D, qr/merge_thread_events\(\$base->\{events\} \|\| \[\], thread_event_carriers\(\$base\)/,
       'Dashboard::run merges over the carriers, not runs alone');
}

# ---------------------------------------------------------------- L1: no clock, correct arithmetic
{
    my $src = slurp("$Bin/../../scripts/RunState.pm") // '';
    (my $code = $src) =~ s/#[^\n]*//g;
    unlike($code, qr/Time::Local/, 'L1: RunState no longer uses Time::Local (it reads the clock at load)');
    my %cases = ('1970-01-01T00:00:00Z' => 0, '2000-02-29T23:59:59Z' => 951868799,
                 '2026-10-22T13:05:09Z' => 1792674309, '2100-03-01T00:00:00Z' => 4107542400);
    for my $iso (sort keys %cases) {
        my @f = $iso =~ /(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)Z/;
        is(RunState::_utc_epoch(@f), $cases{$iso}, "L1: _utc_epoch($iso)");
        is(iso_of($cases{$iso}), $iso, "L1: ...and gmtime agrees ($iso)");
    }
    for my $bad ([1969, 12, 31, 0, 0, 0], [2023, 2, 29, 0, 0, 0], [2026, 13, 1, 0, 0, 0],
                 [2026, 4, 31, 0, 0, 0], [2026, 1, 1, 24, 0, 0], [2026, 1, 1, 0, 60, 0], [2026, 1, 1, 0, 0, 60]) {
        is(RunState::_utc_epoch(@$bad), undef, "L1: not an instant -> undef (@$bad)");
    }
}

# ---------------------------------------------------------------- L2: dedup is tied to the fleet run's thread
{
    my $DAY0 = 1_700_000_000 - (1_700_000_000 % 86400);
    my $GM = sub { gmtime($_[0]) };
    my $orch = [ { text => '10:00 ', role => 'muted' }, { text => 'g ', role => 'accent' }, { text => 'orchestrator_start x', role => 'accent' } ];
    my $ev = { thread => 'other', id => '00000001', epoch => $DAY0 + 36120, at => iso_of($DAY0 + 36120), event => 'launched' };
    my $fleet = { blueprint => 'bp-b', runs_dir => '/x/bp-b/runs', state => 'running', thread => { name => 'mine' } };

    my $m = Dashboard::merge_thread_events([ $orch ], [ $fleet, { thread_events => [ $ev ] } ], $GM, undef);
    my @t = map { Dashboard::spans_text($_) } @$m;
    ok((grep { /orchestrator_start/ } @t) && (grep { /launched thread=other/ } @t),
       'L2: another thread\'s launched does not swallow the fleet run\'s orchestrator_start');

    my $mine = { %$ev, thread => 'mine' };
    $m = Dashboard::merge_thread_events([ $orch ], [ $fleet, { thread_events => [ $mine ] } ], $GM, undef);
    @t = map { Dashboard::spans_text($_) } @$m;
    is((grep { /launched thread=mine/ } @t), 0, 'L2: the fleet run\'s own thread still dedups');

    $m = Dashboard::merge_thread_events([ $orch ], [ { thread_events => [ $ev ] } ], $GM, undef);
    @t = map { Dashboard::spans_text($_) } @$m;
    is((grep { /launched/ } @t), 0, 'L2: no identifiable fleet run -> the kind-only match stands');
}

# ---------------------------------------------------------------- L3 + N2: event vocabulary
{
    my $tsrc = slurp("$Bin/../../../almanac/scripts/Almanac/Thread.pm") // '';
    my ($list) = $tsrc =~ /our\s+\@EVENTS\s*=\s*qw\(([^)]*)\)/;
    ok(defined $list, 'Almanac::Thread @EVENTS found');
    is_deeply([ sort @RunState::THREAD_EVENTS ], [ sort split ' ', ($list // '') ],
              'L3: RunState restates Almanac::Thread\'s @EVENTS exactly');

    my $P = tempdir(CLEANUP => 1);
    thread_rec($P, 't1', created => iso_of($EPOCH - 100), state => 'live', owner_kind => 'none');
    log_rec($P, 't1', '00000001', at => iso_of($EPOCH), event => 'x_dead');
    log_rec($P, 't1', '00000002', at => iso_of($EPOCH + 1), event => 'paused');
    my %x;
    RunState::summarize("$P/.ccpraxis-local-data/blueprints", \%x);
    is_deeply([ map { $_->{event} } @{ $x{thread_events} || [] } ], ['paused'],
              'L3: a log record with a non-Almanac event name is not surfaced');

    my ($w, $rows) = quiet { Dashboard::thread_event_rows([ { thread_events => [
        { thread => 't', id => '1', epoch => $EPOCH, event => undef },
        { thread => 't', id => '2', epoch => $EPOCH, event => 'paused' } ] } ], sub { gmtime($_[0]) }, undef) };
    is(scalar(@$rows), 1, 'N2: an undef event is skipped');
    is(scalar(@$w), 0, 'N2: ...without a warning') or diag(@$w);
}

# ---------------------------------------------------------------- L4: orchestrator owner of ANOTHER blueprint
{
    local $RunState::PID_ALIVE = sub { 1 };
    my $P = tempdir(CLEANUP => 1);
    my $root = "$P/.ccpraxis-local-data/blueprints";
    ledger($P, 'bp-a', '01-x');
    make_path("$root/bp-b/runs");
    write_file("$root/bp-b/runs/.orchestrator", "4242\n");
    thread_rec($P, 'foreign', created => iso_of($EPOCH), state => 'live',
               owner_kind => 'orchestrator', owner_id => 'bp-b', blueprints => 'bp-a');
    my ($s) = grep { $_->{blueprint} eq 'bp-a' } @{ RunState::summarize($root) };
    ok($s && ref $s->{thread} eq 'HASH', 'L4 precondition: bp-a carries the thread');
    is($s && $s->{thread}{owner}{alive}, undef, 'L4: bp-b\'s orchestrator liveness is not borrowed onto bp-a\'s line');

    make_path("$root/bp-a/runs");
    write_file("$root/bp-a/runs/.orchestrator", "4243\n");
    thread_rec($P, 'foreign', created => iso_of($EPOCH), state => 'live',
               owner_kind => 'orchestrator', owner_id => 'bp-a', blueprints => 'bp-a');
    ($s) = grep { $_->{blueprint} eq 'bp-a' } @{ RunState::summarize($root) };
    is($s && $s->{thread}{owner}{alive}, 1, 'L4: its own orchestrator\'s liveness still shows');
}

# ---------------------------------------------------------------- L6: over-cap thread stays on its line
{
    my $P = tempdir(CLEANUP => 1);
    my $root = "$P/.ccpraxis-local-data/blueprints";
    ledger($P, 'bp-a', '01-x');
    thread_rec($P, 'big', created => iso_of($EPOCH), state => 'live', owner_kind => 'none', blueprints => 'bp-a');
    my $td = alm($P) . '/thread-tasks-big';
    make_path($td);
    write_file(sprintf('%s/%08d.md', $td, $_), rec(rank => 'a', title => "t$_", status => 'pending'))
        for 1 .. $RunState::MAX_THREAD_TASKS + 1;
    my ($s) = grep { $_->{blueprint} eq 'bp-a' } @{ RunState::summarize($root) };
    ok($s && ref $s->{thread} eq 'HASH', 'L6: a thread over the task cap is NOT dropped from its blueprint');
    is($s && $s->{thread}{name}, 'big', 'L6: ...it is the right thread');
    like(($s && $s->{thread}{current}{title}) // '', qr/not read/, 'L6: ...and it says its tasks were not read');
}

# ---------------------------------------------------------------- N1, N3
{
    my ($w, $st) = quiet { tui::DashboardScreen::thread_owner_status(
        { state => 'live', owner => { kind => 'orchestrator', alive => 'yes' } }, $EPOCH) };
    is($st, 'unknown', 'N1: a non-numeric alive reads unknown');
    is(scalar(@$w), 0, 'N1: ...without a numeric warning') or diag(@$w);
    is((quiet { tui::DashboardScreen::thread_owner_status({ state => 'live', owner => { kind => 'orchestrator', alive => 1 } }, $EPOCH) })[1],
       'live', 'N1: alive 1 still reads live');

    is(RunState::_pipeline_step_word("## Pipeline\n- [x] 01. scout\n- [ ] 1. spec\n- [ ] 2. build\n"), 'build',
       'N3: "01." and "1." are the same step (first occurrence wins)');
}

done_testing();
