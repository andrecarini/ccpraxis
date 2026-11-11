#!/usr/bin/env perl
# platform: any
# The Blueprints panel rules the operator set on 2026-11-05, one block per
# numbered item of that request:
#   1 structure      -- no thread/run row; the driver ("<dot> orchestrator 30h")
#                       on the blueprint line after the meter and count; no
#                       "N coord"; package rows at one two-space indent
#   2 pause text     -- "<pause glyph>  5h limit . until 21:49" / "7d limit",
#                       through Theme's padded glyph, day/date forms kept
#   3 colours        -- blueprint name accent; package number prefix
#                       name.package; the rest name.package.slug (a new Theme
#                       role with a 256 fallback and a no-colour attr); only
#                       the name strings take those roles
#   4 name length    -- at most 16 columns, cut with Theme's ellipsis; the
#                       name column is the longest cut name
#   5 indicator      -- green only for a live coordinator or live agent; the
#                       pause glyph while paused; muted idle otherwise; judge
#                       and last-attempt kept; never more green than live
#   6 durations      -- most significant unit only; a time only from a
#                       recorded start
#   7 row layout     -- dot, name, total, step word, step time, "attempt N/M"
#                       from attempt 2; columns line up across the panel; a
#                       not-started package's reason in text.waiting (muted
#                       italic) in the step-time slot, never widening it
# plus RunState's per-package coordinator facts the indicator and total read.
#
# Every expected string is built from Theme::glyph by NAME.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use File::Temp qw(tempdir);
use File::Path qw(make_path);

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

sub G { my ($n) = @_; return Theme::glyph($n) // ''; }
sub S { return ' ' x $_[0]; }
sub M {
    my ($d, $t) = @_;
    my $f = ($d == 0 || $t == 0) ? 0 : ($d >= $t ? 15 : int(($d * 15 + $t - 1) / $t));
    $f = 14 if $f > 14 && $d < $t;
    return (G('gauge.full') x $f) . (G('gauge.empty') x (15 - $f));
}
sub agent {
    my (%o) = @_;
    return { id => $o{id}, role => $o{role}, worker_type => $o{worker_type},
             started_at => $NOW - $o{age}, budget_seconds => 1800, stale_after_seconds => 7200 };
}
sub rows { my ($runs, $w) = @_; return tui::DashboardScreen::_run_summary_lines($runs, undef, $w, $NOW); }
sub texts { my ($r) = @_; return [ map { tui::Frame::spans_text($_) } @$r ]; }
sub dw { return tui::Layout::display_width($_[0]); }

my $fleet_thread = sub {
    my ($bp) = @_;
    return { name => "fleet-$bp", state => 'live', done => 0, total => 0, doing => [], current => undef,
             owner => { kind => 'orchestrator', id => $bp, alive => 1 } };
};

# A fleet paused on its 5-hour limit, orchestrator up 30h14m, every
# coordinator checked dead, no live agent anywhere.
my $PAUSED = {
    blueprint => 'acxpraxis-step-2', state => 'paused', packages_done => 9, packages_total => 15,
    paused_reason => 'usage', paused_window => 'five_hour', relaunch_at => $NOW + 3 * 3600,
    relaunch_local => { wday => 'Sat', hhmm => '21:49', day => '01', mon => 'Nov' },
    orchestrator_pid => 41, orchestrator_alive => 1, orchestrator_started_at => $NOW - (30 * 3600 + 14 * 60),
    running_coordinators => 1, inbox_waiting => 0, triage_waiting => 0,
    thread => $fleet_thread->('acxpraxis-step-2'),
    packages => [
        { name => '03-make-and-hooks', status => 'running', attempt => 2, attempt_cap => 5, step_word => 'implementation',
          coordinator_alive => 0, agents => [ agent(id => 'w', role => 'worker', worker_type => 'bp-implementer', age => 600) ] },
        { name => '05-checks-erlang', status => 'running', attempt => 1, attempt_cap => 5, step_word => 'tests',
          coordinator_alive => 0, agents => [] },
    ],
    run_agents => [], next_package => undef,
};
my $RUNNING = { %$PAUSED, state => 'running', paused_reason => undef, paused_window => undef,
                relaunch_at => undef, relaunch_local => undef };

# ===========================================================================
# 1 + 2 -- the two example blueprint lines, byte-exact.
# ===========================================================================
{
    my $r = texts(rows([$RUNNING]));
    is($r->[0], G('icon.blueprints') . ' acxpraxis-step-2' . S(3) . M(9, 15) . S(2) . '9/15' . S(3)
        . G('status.ok') . ' orchestrator 30h',
        '1: running -- "<icon> name   meter  9/15   <ok> orchestrator 30h", the driver after the count, the dot first');
    my $p = texts(rows([$PAUSED]));
    is($p->[0], G('icon.blueprints') . ' acxpraxis-step-2' . S(3) . M(9, 15) . S(2) . '9/15' . S(3)
        . G('status.ok') . ' orchestrator 30h' . S(3) . G('thread.idle') . ' 5h limit ' . G('sep.dot') . ' until 21:49',
        '1/2: paused -- the pause text follows the driver: "<pause>  5h limit . until 21:49"');
    like(G('thread.idle'), qr/ \z/, '2 precondition: the pause glyph Theme hands out carries its pad');
    ok(index($p->[0], G('thread.idle') . ' 5h') >= 0 && index($p->[0], G('thread.idle') . ' 5h') == index($p->[0], substr(G('thread.idle'), 0, -1) . '  5h'),
        '2: the pause glyph is followed by TWO spaces (its pad plus the separator), never a bare glyph and one space');
    my $block = tui::DashboardScreen::_run_block($PAUSED, $NOW, undef);
    ok(!(grep { $_->{kind} eq 'driver' } @{ $block->{lines} }), '1: there is no driver/thread row');
    unlike(join("\n", @$p), qr/\bcoord\b|fleet-acxpraxis/, '1: neither "N coord" nor the thread name is drawn');
    is(scalar(@$p), 3, '1: the block is the blueprint line plus one row per package');
    like($p->[$_], qr/\A  \S/, "1: package row $_ sits at exactly one two-space indent") for 1 .. 2;

    # 2: the 7-day window, and the distant-time forms kept.
    for my $c ([ 'seven_day', $NOW + 3600,    { wday => 'Sat', hhmm => '13:26', day => '01', mon => 'Nov' }, '7d limit ' . G('sep.dot') . ' until 13:26' ],
               [ 'seven_day', $NOW + 2 * 86400, { wday => 'Mon', hhmm => '18:05', day => '03', mon => 'Nov' }, '7d limit ' . G('sep.dot') . ' until Mon 18:05' ],
               [ 'five_hour', $NOW + 8 * 86400, { wday => 'Sun', hhmm => '09:00', day => '09', mon => 'Nov' }, '5h limit ' . G('sep.dot') . ' until 09 Nov' ]) {
        my ($win, $at, $loc, $want) = @$c;
        my $s = { %$PAUSED, paused_window => $win, relaunch_at => $at, relaunch_local => $loc };
        like(texts(rows([$s]))->[0], qr/\Q${\ G('thread.idle') } $want\E\z/, "2: $win, relaunch in " . ($at - $NOW) . "s -> '$want'");
    }
    # A drive-solo session driver.
    my $solo = { blueprint => 'tooling-fixes', state => 'solo', packages_done => 1, packages_total => 4,
                 thread => { name => 'drive-tooling', state => 'live', done => 2, total => 5, doing => [], current => undef,
                             owner => { kind => 'session', id => 's', alive => undef, activity_at => $NOW - 60, armed => 0 } },
                 packages => [], run_agents => [] };
    is(texts(rows([$solo]))->[0], G('icon.blueprints') . ' tooling-fixes' . S(3) . M(1, 4) . S(2) . '1/4' . S(3)
        . G('status.ok') . ' session' . S(3) . 'solo',
        '1: a drive-solo run shows its session driver, with no uptime (a session has no recorded start)');
}

# ===========================================================================
# 3 -- colours: only the name strings take the name roles.
# ===========================================================================
{
    my $r = rows([$RUNNING]);
    my @bp_name = grep { $_->{text} eq 'acxpraxis-step-2' } @{ $r->[0] };
    is($bp_name[0]{role}, 'accent', '3: the blueprint name is accent');
    my %by = map { ($_->{text} => $_->{role}) } @{ $r->[1] };
    is($by{'03'}, 'name.package', '3: the package number prefix "03" is name.package');
    is($by{'-make-and-hoo' . G('ellipsis')}, 'name.package.slug', '3: the rest of the (cut) name is name.package.slug');
    my @name_roles = grep { $_->{role} =~ /\Aname\./ } map { @$_ } @$r;
    is_deeply([ sort map { $_->{text} } @name_roles ], [ sort('03', '-make-and-hoo' . G('ellipsis'), '05', '-checks-erlang') ],
        '3: no span other than the two package names carries a name.* role');
    my $z = tui::DashboardScreen::_package_name_spans('z01-follow-up');
    is_deeply($z, [ { text => 'z01', role => 'name.package' }, { text => '-follow-up', role => 'name.package.slug' } ],
        '3: a letter-led prefix (z01) is a prefix too');
    is_deeply(tui::DashboardScreen::_package_name_spans('pkg-x'), [ { text => 'pkg-x', role => 'name.package' } ],
        '3: a name with no number prefix is drawn whole in name.package, not faded');

    my $roles = Theme::roles();
    my $slug = $roles->{'name.package.slug'};
    ok($slug, '3: Theme declares name.package.slug');
    is_deeply($slug->{rgb}, [88, 138, 150], '3: name.package.slug is rgb 88,138,150');
    is_deeply($roles->{'name.package'}{rgb}, [86, 204, 214], '3: name.package is rgb 86,204,214');
    is(Theme::sgr('name.package.slug', 'truecolor'), "\e[38;2;88;138;150m", '3: slug truecolour SGR');
    is(Theme::sgr('name.package.slug', '256'), "\e[38;5;$slug->{x256}m", '3: slug 256-colour fallback');
    is(Theme::sgr('name.package.slug', 'none'), "\e[2m", '3: slug at no colour is dim, the prefix plain -- the split survives');
    is(Theme::sgr('name.package', 'none'), '', '3: prefix at no colour is plain');
    my $w = $roles->{'text.waiting'};
    ok($w && $w->{italic}, '7: Theme declares the italic text.waiting role');
    is(Theme::sgr('text.waiting', 'truecolor'), Theme::sgr('text.muted', 'truecolor') . "\e[3m", '7: text.waiting is text.muted plus italic (truecolour)');
    is(Theme::sgr('text.waiting', 'none'), "\e[2m\e[3m", '7: text.waiting stays italic with no colour');
    ok(!exists $roles->{'text.muted'}{italic}, '7: no other role gains an italic key');
}

# ===========================================================================
# 4 -- package-name length.
# ===========================================================================
{
    my $r = texts(rows([$RUNNING]));
    like($r->[1], qr/ 03-make-and-hoo\Q${\ G('ellipsis') }\E /, '4: a 17-column name is cut to 16 with the theme ellipsis');
    my $short = { %$RUNNING, packages => [ { name => '01-a', status => 'running', step_word => 'tests', agents => [] },
                                           { name => '02-bb', status => 'running', step_word => 'tests', agents => [] } ] };
    my $t = texts(rows([$short]));
    is($t->[1], S(2) . G('status.idle') . ' 01-a ' . S(3) . 'tests', '4: the name column is as wide as the longest name (5), not 16');
    is($t->[2], S(2) . G('status.idle') . ' 02-bb' . S(3) . 'tests', '4: ... and the longest name is unpadded');
    is(tui::DashboardScreen::_clip_name("caf\xC3\xA9-" . ('x' x 20), 16), "caf\xC3\xA9-" . ('x' x 10) . G('ellipsis'),
        '4: the cut counts columns, not bytes, and never splits a multi-byte character');
}

# ===========================================================================
# 5 -- the truthful indicator.
# ===========================================================================
{
    my $p = texts(rows([$PAUSED]));
    unlike(join("\n", @$p[1 .. $#$p]), qr/\Q${\ G('status.ok') }\E/, '5: a paused fleet whose coordinators are all dead shows no green package dot');
    is(substr($p->[2], 2, length(G('thread.idle'))), G('thread.idle'), '5: while paused, a package with nothing live shows the pause glyph');
    is(substr($p->[1], 2, length(G('thread.idle'))), G('thread.idle'),
        '5: a coordinator checked dead discards its package\'s dispatch-log worker (no green from a stale subagent record)');
    my $r = texts(rows([$RUNNING]));
    is(substr($r->[2], 2, length(G('status.idle'))), G('status.idle'), '5: not paused and nothing live -> the muted idle dot');
    my $rr = rows([$RUNNING]);
    my ($dot) = grep { $_->{text} eq G('status.idle') } @{ $rr->[2] };
    is($dot->{role}, 'text.muted', '5: the idle dot is muted');

    my @cases = (
        [ 'live coordinator',            { coordinator_alive => 1, agents => [] },                                           'status.ok',   'state.ok' ],
        [ 'unknown coordinator, live worker', { agents => [ agent(id => 'w', role => 'worker', worker_type => 'bp-x', age => 60) ] }, 'status.ok', 'state.ok' ],
        [ 'live judge',                  { coordinator_alive => 1, agents => [ agent(id => 'j', role => 'judge', worker_type => 'bp-x-judge', age => 60) ] }, 'status.judge', 'state.warn' ],
        [ 'last attempt',                { coordinator_alive => 1, attempt => 5, attempt_cap => 5, agents => [] },            'status.warn', 'state.warn' ],
        [ 'dead coordinator, stale-free worker', { coordinator_alive => 0, agents => [ agent(id => 'w', role => 'worker', worker_type => 'bp-x', age => 60) ] }, 'status.idle', 'text.muted' ],
    );
    for my $c (@cases) {
        my ($label, $extra, $glyph, $role) = @$c;
        my $s = { blueprint => 'b', state => 'running', packages => [ { name => '01-x', status => 'running', attempt => 1, attempt_cap => 5, %$extra } ], run_agents => [] };
        my $row = rows([$s])->[1];
        my $g = $glyph eq 'status.judge' ? G('status.judge') : G($glyph);
        my ($sp) = grep { $_->{text} eq $g } @$row;
        ok($sp && $sp->{role} eq $role, "5: $label -> $glyph in $role");
    }

    # Never more green than live: a mixed fleet.
    my @pk = map { { name => sprintf('%02d-p', $_), status => 'running', agents => [],
                     coordinator_alive => ($_ % 3 == 0 ? 1 : ($_ % 3 == 1 ? 0 : undef)) } } 1 .. 9;
    my $mixed = { blueprint => 'mix', state => 'running', packages => \@pk, run_agents => [] };
    my $green = grep { index($_, '  ' . G('status.ok')) == 0 } @{ texts(rows([$mixed])) };
    my $live  = grep { tui::DashboardScreen::_package_is_live($_, $NOW) } @pk;
    is($live, 3, '5 precondition: three of nine packages have a live coordinator');
    is($green, $live, '5: the panel shows exactly as many green package dots as there are live packages');
}

# ===========================================================================
# 6 -- durations.
# ===========================================================================
{
    my %want = (0 => '<1m', 59 => '<1m', 60 => '1m', 3599 => '59m', 3600 => '1h', 48 * 3600 - 1 => '47h',
                48 * 3600 => '2d', 30 * 86400 => '30d');
    for my $secs (sort { $a <=> $b } keys %want) {
        is(tui::DashboardScreen::_block_elapsed($secs), $want{$secs}, "6: $secs s -> $want{$secs}");
    }
    ok(!defined tui::DashboardScreen::_block_elapsed(-1), '6: a negative span is no duration at all');
    is(tui::DashboardScreen::fmt_duration(3 * 3600 + 5 * 60), '3h05m', '6: fmt_duration (other panels) is unchanged');

    # Only from recorded starts.
    my $pk = sub { my (%o) = @_; return { blueprint => 'b', state => 'running', run_agents => [],
                                           packages => [ { name => '01-x', status => 'running', step_word => 'tests', %o } ] }; };
    is(texts(rows([ $pk->(coordinator_alive => 1, coordinator_started_at => $NOW - 7200, agents => []) ]))->[1],
       S(2) . G('status.ok') . ' 01-x 2h   tests', '6: total from the registry launch of a live coordinator (7200 s -> 2h)');
    is(texts(rows([ $pk->(coordinator_alive => 1, coordinator_started_at => undef, agents => []) ]))->[1],
       S(2) . G('status.ok') . ' 01-x   tests', '6: a live coordinator with no recorded launch shows no total');
    is(texts(rows([ $pk->(coordinator_alive => 1, coordinator_started_at => $NOW + 3600, agents => []) ]))->[1],
       S(2) . G('status.ok') . ' 01-x   tests', '6: a launch recorded in the future shows no total (never a disguised <1m)');
    is(texts(rows([ $pk->(coordinator_alive => 0, coordinator_started_at => $NOW - 7200, agents => []) ]))->[1],
       S(2) . G('status.idle') . ' 01-x   tests', '6: a dead coordinator\'s launch time is never shown');
    is(texts(rows([ $pk->(agents => [ agent(id => 'w1', role => 'worker', worker_type => 'bp-a', age => 900),
                                      agent(id => 'w2', role => 'worker', worker_type => 'bp-b', age => 300) ]) ]))->[1],
       S(2) . G('status.ok') . ' 01-x   tests   15m', '6: the step time is the OLDEST live worker\'s (900 s -> 15m), with no total (no coordinator record)');
    my $d = { %$RUNNING, orchestrator_started_at => undef };
    like(texts(rows([$d]))->[0], qr/\Q${\ G('status.ok') } orchestrator\E\z/, '6: no orchestrator start recorded -> no driver uptime');
    my $long = { %$RUNNING, orchestrator_started_at => $NOW - 3 * 86400 };
    like(texts(rows([$long]))->[0], qr/ orchestrator 3d\z/, '6: an uptime past 48 h is in days');
}

# ===========================================================================
# 7 -- the row layout.
# ===========================================================================
{
    my $A = { blueprint => 'aa', state => 'running', run_agents => [], packages => [
        { name => '01-alpha', status => 'running', step_word => 'implementation', attempt => 2, attempt_cap => 5,
          coordinator_alive => 1, coordinator_started_at => $NOW - 3 * 3600,
          agents => [ agent(id => 'w', role => 'worker', worker_type => 'bp-i', age => 45 * 60) ] },
        { name => '02-beta', status => 'blocked', waits_on => '01-alpha-and-a-very-long-dependency-name' },
    ] };
    my $B = { blueprint => 'bb', state => 'running', run_agents => [], packages => [
        { name => '07-gamma', status => 'running', step_word => 'tests', attempt => 1, attempt_cap => 5,
          coordinator_alive => 1, coordinator_started_at => $NOW - 30,
          agents => [ agent(id => 'w', role => 'worker', worker_type => 'bp-t', age => 20) ] },
    ] };
    my $r = rows([$A, $B]);
    my $t = texts($r);
    # Columns: dot slot 2, name N=8, total T=3 ('<1m'), step S=14, time U=3 ('45m').
    is($t->[1], S(2) . G('status.ok') . ' 01-alpha' . '  3h' . S(3) . 'implementation' . S(3) . '45m' . S(3) . 'attempt 2/5',
        '7: "<dot> <name> <total>   <step word>   <step time>   attempt N/M", times right-aligned');
    # $t->[3] is the blank row between the two blocks (2026-11-11).
    is($t->[3], '', '7: one blank row separates the two blueprint blocks');
    is($t->[5], S(2) . G('status.ok') . ' 07-gamma' . ' <1m' . S(3) . 'tests' . S(9) . S(3) . '<1m',
        '7: a row in ANOTHER blueprint uses the same columns, and attempt 1 shows no counter');
    my $col = sub { my ($s, $w) = @_; my $i = index($s, $w); return $i < 0 ? -1 : dw(substr($s, 0, $i + length $w)); };
    is($col->($t->[1], '3h'), $col->($t->[5], '<1m'), '7: the total column ends in the same column across blueprints');
    my $u_end = $col->($t->[1], '45m');
    is(dw($t->[5]), $u_end, '7: the step-time column ends in the same column across blueprints');
    like($t->[1], qr/attempt 2\/5\z/, '7: the attempt counter is labelled "attempt"');

    # The not-started row: its reason is in the step-time slot, muted italic,
    # nothing in the step-word slot, and it does not widen the time column.
    my $start_of_time = dw(S(2) . G('status.ok') . ' 01-alpha' . '  3h' . S(3) . 'implementation' . S(3));
    is($t->[2], S(2) . G('thread.blocked') . ' 02-beta ' . ' ' . S(3) . S(3) . S(14) . S(3) . 'waiting on 01-alpha-and-a-very-long-dependency-name',
        '7: a blocked package says "waiting on <dep>" where the step time starts, with an empty step slot');
    is($col->($t->[2], 'waiting') - length('waiting'), $start_of_time, '7: the reason starts exactly at the step-time column');
    my ($aside) = grep { $_->{text} =~ /\Awaiting on / } @{ $r->[2] };
    is($aside->{role}, 'text.waiting', '7: the reason is drawn in text.waiting (muted italic)');
    my $without = texts(rows([ { %$A, packages => [ $A->{packages}[0] ] }, $B ]));
    is($without->[1], $t->[1], '7: removing the long reason changes no other row -- it never widened a column');
}

# ===========================================================================
# RunState: the per-package coordinator facts.
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $dir = "$root/.ccpraxis-local-data/blueprints/bp-facts";
    make_path("$dir/runs", "$dir/packages");
    my $write = sub { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print $fh $c; close $fh; };
    $write->("$dir/blueprint.md", "| pkg | d | depends_on | model |\n|-----|---|---|---|\n| 01-a | x | - | s |\n| 02-b | y | - | s |\n| 03-c | z | - | s |\n");
    $write->("$dir/packages/$_.md", "---\npackage: $_\nstatus: running\n---\n# l\n") for qw(01-a 02-b 03-c);
    $write->("$dir/runs/registry.json", '{"packages":{'
        . '"01-a":{"pid":101,"launched_at":"2025-11-01T10:26:40Z","attempt":1},'
        . '"02-b":{"pid":102,"launched_at":"2025-11-01T10:26:40Z","attempt":1},'
        . '"03-c":{"pid":103,"launched_at":"not-a-time","attempt":1}}}');
    local $RunState::PID_ALIVE = sub { my ($pid) = @_; return $pid == 102 ? 0 : 1; };
    my $s = RunState::summarize_dir($dir);
    my %p = map { ($_->{name} => $_) } @{ $s->{packages} || [] };
    is($p{'01-a'}{coordinator_alive}, 1, 'RunState: a registry pid that probes alive -> coordinator_alive 1');
    is($p{'01-a'}{coordinator_started_at}, 1_761_992_800, 'RunState: launched_at (iso_now UTC) -> its exact epoch');
    is($p{'02-b'}{coordinator_alive}, 0, 'RunState: a registry pid checked dead -> coordinator_alive 0');
    ok(!defined $p{'02-b'}{coordinator_started_at}, 'RunState: a dead coordinator carries no start');
    ok(!defined $p{'03-c'}{coordinator_started_at}, 'RunState: a launched_at it cannot read exactly is no start at all');
    is($p{'03-c'}{coordinator_alive}, 1, 'RunState: ... while its liveness is still reported');
}

done_testing();
