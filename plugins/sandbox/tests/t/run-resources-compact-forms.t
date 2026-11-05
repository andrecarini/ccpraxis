#!/usr/bin/env perl
# platform: any
# The Run, Resources and Claude Code panel rules the operator set on
# 2026-11-05, one block per numbered item of that request:
#    8 Claude Code  -- two label/value pairs per row (account|access,
#                      usage|refresh); today's four rows when too narrow
#    9 machine row  -- "machine  <name>" in state.ok while running, cut with
#                      the ellipsis at 22; any other state keeps its word and
#                      the name takes that state's role; no continuation line
#   10 keep-awake   -- "requested" / "released" / "requested, probe
#                      unreadable" / "not published": what the launcher did
#                      (published a host awake-sources entry), not "holding"
#   11 podman line  -- one line: full words when they fit, else
#                      imgs/ctrs/vols, else i/c/v
#   12 resources    -- "6.6 GB u | 3.9 GB f | 10.4 GB t" when the full words do
#                      not fit, the same form on every gauge row, aligned
# plus tui::Screen's row-alternative mechanism that items 11 and 12 ride on.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

BEGIN {
    require File::Temp;
    my $pin = File::Temp::tempdir(CLEANUP => 1);
    $ENV{HOME} = $pin; $ENV{USERPROFILE} = $pin; $ENV{ALMANAC_HOME} = $pin;
}

require Theme;
require tui::Frame;
require tui::Layout;
require tui::Screen;
require tui::DashboardScreen;
require Dashboard;

my $GB = 1e9;   # fmt_bytes is decimal
sub G { my ($n) = @_; return Theme::glyph($n) // ''; }
sub plain { my ($c) = @_; my $t = $c->{text} // ''; $t =~ s/\x1b\[[0-9;]*m//g; return $t; }
sub frame { my ($st, $rows, $cols) = @_; return [ map { plain($_) } @{ Dashboard::compose_frame($st, $rows, $cols) } ]; }
sub txt { return tui::Frame::spans_text($_[0]); }
sub panel { my ($p, $title) = @_; my ($x) = grep { $_->{title} eq $title } @$p; return $x; }

my %RES = (
    snapshot_state => 'fresh', snapshot_age => 5,
    machine_name => 'podman-machine-default', machine_state => 'running',
    ctr_mem_used => 6.6 * $GB, vm_mem_total => 10.4 * $GB, ctr_cpu_pct => 20,
    host_ram_used => 6.6 * $GB, host_ram_total => 10.5 * $GB,
    host_swap_used => 1.0 * $GB, host_swap_total => 12.6 * $GB,
    host_disk_dev => 'C:', host_disk_used => 80 * $GB, host_disk_total => 254.8 * $GB, host_cpu_pct => 30,
    pod_images => 11.6 * $GB, pod_containers => 3.7 * $GB, pod_volumes => 79.5e6,
);
my %TOK = (logged_in => 1, access_present => 1, access_state => 'ok', access_seconds_left => 7200,
           refresh_present => 1, refresh_fingerprint => 'fp01', subscription_type => 'max', rate_limit_tier => 'tier5');
sub state { my (%o) = @_; return { project_name => 'p', container => 'c', status => 'running', beat_age => 5, uptime => 60,
                                   resources => { %RES }, tokens => { %TOK }, runs => [], events => [], %o }; }

# ===========================================================================
# tui::Screen -- the row-alternative mechanism.
# ===========================================================================
{
    my $row = sub { my ($t) = @_; return [ { text => $t, role => 'text.primary' } ]; };
    my $a1 = $row->('aaaaaaaaaa'); $a1->[0]{alts} = [ [ $row->('aaaaa') ], [ $row->('a') ] ];
    my $b1 = $row->('bbbbbbbbbbbbbbbb'); $b1->[0]{alts} = [ [ $row->('bbbbbbbbb') ] ];
    my $plain = $row->('plain-row-untouched');
    my $out = tui::Screen::_pick_alternatives([ $a1, $plain, $b1 ], 20);
    is_deeply([ map { txt($_) } @$out ], [ 'aaaaaaaaaa', 'plain-row-untouched', 'bbbbbbbbbbbbbbbb' ], 'Screen: everything fits -> the full forms');
    ok(!exists $out->[0][0]{alts}, 'Screen: the chosen row no longer carries the marker');
    is($out->[1], $plain, 'Screen: a row without alternatives passes through as the same reference');
    $out = tui::Screen::_pick_alternatives([ $a1, $plain, $b1 ], 12);
    is_deeply([ map { txt($_) } @$out ], [ 'aaaaa', 'plain-row-untouched', 'bbbbbbbbb' ],
        'Screen: ONE choice for the panel -- b does not fit at 12, so a takes its variant 1 too, though its full form fits');
    $out = tui::Screen::_pick_alternatives([ $a1, $b1 ], 5);
    is_deeply([ map { txt($_) } @$out ], [ 'a', 'bbbbbbbbb' ], 'Screen: nothing fits -> each row\'s LAST variant (then wrapped as usual)');
    my $c1 = $row->('cccccccccccc'); $c1->[0]{alts} = [ [ $row->('c1'), $row->('c2') ] ];
    my $d1 = $row->('dddddddddddd'); $d1->[0]{alts} = [ [] ];
    $out = tui::Screen::_pick_alternatives([ $c1, $d1 ], 6);
    is_deeply([ map { txt($_) } @$out ], [ 'c1', 'c2' ], 'Screen: a variant may be several rows, or none');
    my $lines = [ $row->('x') ];
    is(tui::Screen::_pick_alternatives($lines, 3), $lines, 'Screen: a panel with no alternatives gets its own list back');
}

# ===========================================================================
# 8 -- the Claude Code panel's pairs.
# ===========================================================================
{
    my $p = tui::DashboardScreen::panels(state(), 121);
    my $cc = panel($p, 'Claude Code');
    my @t = map { txt($_) } @{ $cc->{lines} };
    is(scalar(@t), 2, '8: at 121 columns the panel is two rows');
    like($t[0], qr/\Aaccount {7}max \/ tier5 {3,}access {8}expires in 2h00m\z/, '8: row 1 is account on the left, access on the right');
    like($t[1], qr/\Ausage {9}\S.* {3,}refresh {7}present \(fp01\)\z/, '8: row 2 is usage on the left, refresh on the right');
    is(tui::Layout::display_width(substr($t[0], 0, index($t[0], q(access)))), tui::Layout::display_width(substr($t[1], 0, index($t[1], q(refresh)))), '8: the two right-hand labels start in the same column');
    my $narrow = tui::DashboardScreen::panels(state(), 40);
    my @n = map { txt($_) } @{ panel($narrow, 'Claude Code')->{lines} };
    is_deeply([ map { /^(\S+)/ ? $1 : '' } @n ], [ qw(access refresh account usage) ], '8: too narrow -> today\'s four rows, in today\'s order');
}

# ===========================================================================
# 9 -- the machine row.
# ===========================================================================
{
    my $lines = tui::DashboardScreen::_podman_install_lines({ %RES });
    my ($m) = grep { txt($_) =~ /\Amachine/ } @$lines;
    is(txt($m), tui::DashboardScreen::gutter('machine') . 'podman-machine-default', '9: running -> "machine  <name>", no state word');
    is($m->[1]{role}, 'state.ok', '9: ... the name in state.ok');
    my ($long) = grep { txt($_) =~ /\Amachine/ } @{ tui::DashboardScreen::_podman_install_lines({ %RES, machine_name => 'my-very-long-podman-machine-name' }) };
    is(txt($long), tui::DashboardScreen::gutter('machine') . 'my-very-long-podman-m' . G('ellipsis'),
        '9: a name over 22 columns is cut to 22 (21 characters and the theme ellipsis)');
    for my $c ([ 'stopped', 'state.crit' ], [ 'starting', 'state.warn' ]) {
        my ($st, $role) = @$c;
        my ($r) = grep { txt($_) =~ /\Amachine/ } @{ tui::DashboardScreen::_podman_install_lines({ %RES, machine_state => $st }) };
        is(txt($r), tui::DashboardScreen::gutter('machine') . "$st podman-machine-default", "9: $st -> the state word, then the name");
        ok(!(grep { $_->{role} ne $role } @{$r}[1 .. $#$r]), "9: $st -> word and name both in $role");
    }
    my ($u) = grep { txt($_) =~ /\Amachine/ } @{ tui::DashboardScreen::_podman_install_lines({ %RES, machine_state => 'weird' }) };
    is(txt($u), tui::DashboardScreen::gutter('machine') . 'n/a podman-machine-default', '9: an unknown state -> n/a, then the name, muted');
    my $f = frame(state(), 50, 121);
    ok(!(grep { /\(podman-machine-default\)/ } @$f), '9: the "(podman-machine-default)" continuation line is gone');
    ok((grep { /\Amachine {7}podman-machine-default\s*\S?/ } @$f), '9: the composed frame shows "machine  podman-machine-default"');
}

# ===========================================================================
# 10 -- the keep-awake row.
# ===========================================================================
{
    my $keep = sub {
        my (%o) = @_;
        my ($r) = grep { txt($_) =~ /\Akeep-awake/ } @{ tui::DashboardScreen::_run_body({ %o }) };
        return [ substr(txt($r), length(tui::DashboardScreen::gutter('keep-awake'))), $r->[1]{role} ];
    };
    is_deeply($keep->(stay_awake => 1, keepawake_held => 1, keepawake_published => 1, busy_age => 5, lease_probe => { state => 'ok' }),
              [ 'requested', 'state.ok' ], '10: held and published -> "requested" (the launcher asked; it holds nothing)');
    is_deeply($keep->(stay_awake => 0, keepawake_held => 0, busy_age => undef), [ 'released', 'text.muted' ], '10: not held -> "released"');
    is_deeply($keep->(stay_awake => 0, keepawake_held => 1, keepawake_published => 1, busy_age => undef, lease_probe => { state => 'probe-failed', detail => 'x' }),
              [ 'requested, probe unreadable', 'state.warn' ], '10: kept through a failed probe -> "requested, probe unreadable"');
    is_deeply($keep->(stay_awake => 1, keepawake_held => 1, keepawake_published => 0, busy_age => 5),
              [ 'not published', 'state.warn' ], '10: wanted but the registry entry was not written -> "not published"');
    is_deeply($keep->(stay_awake => 1, busy_age => 5), [ 'requested', 'state.ok' ], '10: a gather with neither new key reads stay_awake, as before');
    my $all = join("\n", map { txt($_) } @{ tui::DashboardScreen::_run_body({ stay_awake => 1, keepawake_held => 1 }) });
    unlike($all, qr/holding|wake-lock asserted|PC may sleep/, '10: none of the old wordings survives');
}

# ===========================================================================
# 11 -- the podman line.
# ===========================================================================
{
    my $f121 = frame(state(), 50, 121);
    my @pod = grep { /\Apodman / } @$f121;
    is(scalar(@pod), 1, '11: at 121 columns the podman row is one line');
    like($pod[0], qr/\Apodman {8}i 11\.6 GB  c 3\.7 GB  v 79\.5 MB\s*\x{e2}?/, '11: ... in the i/c/v form, as the operator wrote it');
    my $idx = (grep { $f121->[$_] =~ /\Apodman / } 0 .. $#$f121)[0];
    unlike($f121->[$idx + 1] // '', qr/\A  \S/, '11: and no continuation line follows it');
    my $f80 = frame(state(), 60, 80);
    ok((grep { /\Apodman {8}images 11\.6 GB  containers 3\.7 GB  volumes 79\.5 MB/ } @$f80),
        '11: with room (Run full width at 80 columns) the full words are used');
    my $big = { %RES, pod_volumes => 859e6, pod_containers => 19.3 * $GB, pod_images => 2.8 * $GB };
    my @pb = grep { /\Apodman / } @{ frame(state(resources => $big), 50, 121) };
    like($pb[0] // '', qr/\Apodman {8}i 2\.8 GB c 19\.3 GB v 859\.0 MB/, '11: a value too wide even for i/c/v tightens the gaps rather than wrapping');
}

# ===========================================================================
# 12 -- the resources rows.
# ===========================================================================
{
    my $f = frame(state(), 50, 121);
    my @g = grep { /\A(?:ctr mem|host ram|host swap|host disk)/ } map { (split /\x{e2}\x{94}\x{82}/, $_)[-1] } @$f;
    is(scalar(@g), 4, '12 precondition: the four used/free/total rows are in the Resources panel at 121');
    like($_, qr/ GB u \| .* GB f \| .* GB t/, "12: compact form at 121 -- " . (split / {2,}/, $_)[0]) for @g;
    my @bars = map { my $t = $_; my @p; while ($t =~ /\|/g) { push @p, pos($t) } \@p } @g;
    is_deeply($bars[$_], $bars[0], "12: row ${_} separators line up with the first row's") for 1 .. $#bars;
    my $wide = tui::Screen::_pick_alternatives(tui::DashboardScreen::_resources_body({ %RES }), 200);
    my @w = grep { txt($_) =~ /\A(?:ctr mem|host ram|host swap|host disk)/ } @$wide;
    like(txt($_), qr/ GB used \| .* GB free \| .* GB total/, '12: with room, the full words') for @w;
}

done_testing();
