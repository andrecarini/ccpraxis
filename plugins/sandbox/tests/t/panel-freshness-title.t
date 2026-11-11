#!/usr/bin/env perl
# platform: any
# Panel freshness in the panel title (operator, 2026-11-11). The Resources
# `snapshot` row and the Run `heartbeat` row are gone; the title rule carries
# the freshness instead:
#
#   ─ Resources · <1m ──...         fresh (age in text.muted)
#   ─ Resources · stale 12m ──...   stale, state.warn
#   ─ Resources · sampling… ──...   no reading yet
#   ─ Run · <1m ──...  /  ─ Run · stale Nm ──...
#
# and a sampler failure or stall (and a snapshot with no or partial readings,
# or an unreadable one) is ONE body line, present only while it holds.
#
# Pins:
#   F. tui::Frame::panel_title_line's suffix: drawn after the title with its
#      own roles, the line still exactly $w wide, and no suffix = the old line.
#   R. resources_title_suffix for fresh / stale / sampling / unreadable.
#   A. resources_alert_spans: present for FAILED, STALLED, no readings, facts
#      unavailable, unreadable; absent while sampling, fresh or stale.
#   H. run_title_suffix: absent with no heartbeat, the age below
#      HEARTBEAT_STALE_SECS, "stale" from it on.
#   P. panels()/compose_frame: the titles render, the two rows are gone, and
#      both titles fit the narrow 45|76 split at 121 columns.
#
# Non-vacuity, measured 2026-11-11 against the tree before this change: no
# title suffix exists (panel_title_line ignores a 4th argument, the three
# *_suffix / *_alert subs are missing): F2's shape and F3's role assertions
# fail (2 not ok), then the file dies (exit 255) at the first
# resources_title_suffix call.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

require Theme;
require tui::Frame;
require tui::Layout;
require tui::DashboardScreen;
require Dashboard;

sub G { my ($n) = @_; return Theme::glyph($n) // ''; }
sub T { my ($sp) = @_; return join '', map { $_->{text} } @$sp; }
my $DOT = G('sep.dot');
my $RULE = G('rule.h');

# ===========================================================================
# F. the title line
# ===========================================================================
{
    my $plain = tui::Frame::panel_title_line('Resources', 40);
    my $same  = tui::Frame::panel_title_line('Resources', 40, undef, []);
    is_deeply($same, $plain, 'F1: an empty suffix leaves the title line exactly as it was');

    my $sp = tui::Frame::panel_title_line('Resources', 40, undef,
        [ { text => $DOT, role => 'text.muted' }, { text => ' stale 12m', role => 'state.warn' } ]);
    like(T($sp), qr/\A\Q$RULE\E Resources \Q$DOT\E stale 12m (?:\Q$RULE\E)+\z/, 'F2: "─ Resources · stale 12m ──..."');
    is(tui::Layout::display_width(T($sp)), 40, 'F2: still exactly the panel width');
    my ($warn) = grep { $_->{text} eq ' stale 12m' } @$sp;
    is($warn && $warn->{role}, 'state.warn', 'F3: the suffix keeps its own role');
    my ($title) = grep { $_->{text} eq ' Resources ' } @$sp;
    ok($title, 'F3: the title text span is unchanged');

    my $tiny = tui::Frame::panel_title_line('Resources', 12, undef, [ { text => "$DOT stale 12m", role => 'state.warn' } ]);
    is(tui::Layout::display_width(T($tiny)), 12, 'F4: a suffix wider than the panel is cut to the width, never overflows');
}

# ===========================================================================
# R. Resources title
# ===========================================================================
my $S = \&tui::DashboardScreen::resources_title_suffix;
{
    my $sp = $S->({ resources => { snapshot_state => 'fresh', snapshot_age => 30 } });
    is(T($sp), "$DOT <1m", 'R1: fresh, 30s -> "· <1m"');
    is($sp->[0]{role}, 'text.muted', 'R1: muted');

    is(T($S->({ resources => { snapshot_state => 'fresh', snapshot_age => 725 } })), "$DOT 12m", 'R2: fresh, 725s -> one unit, "· 12m"');

    $sp = $S->({ resources => { snapshot_state => 'stale', snapshot_age => 725 } });
    is(T($sp), "$DOT stale 12m", 'R3: stale -> "· stale 12m"');
    my ($w) = grep { $_->{text} =~ /stale/ } @$sp;
    is($w && $w->{role}, 'state.warn', 'R3: the stale words are state.warn');
    is($sp->[0]{role}, 'text.muted', 'R3: the dot stays muted');

    $sp = $S->({ resources => undef, resources_sampler => { status => 'running', elapsed => 3, grace => 60 } });
    is(T($sp), "$DOT sampling" . G('ellipsis'), 'R4: no snapshot yet -> "· sampling…"');
    is($sp->[0]{role}, 'text.muted', 'R4: muted');

    $sp = $S->({ resources => { snapshot_state => 'failed' } });
    is(T($sp), "$DOT unreadable", 'R5: an unreadable snapshot says so');
    ok((grep { $_->{role} eq 'state.crit' } @$sp), 'R5: in state.crit');

    is(T($S->({ resources => { snapshot_state => 'stale' } })), "$DOT stale", 'R6: stale with no age -> "· stale"');
    is_deeply($S->({ resources => {} }), [], 'R7: a resources hash with no snapshot_state draws no suffix');
}

# ===========================================================================
# A. the one body line
# ===========================================================================
my $A = \&tui::DashboardScreen::resources_alert_spans;
{
    my $full = { snapshot_state => 'fresh', snapshot_age => 5 };
    $full->{$_} = 1 for qw(machine_name machine_state ctr_mem_used vm_mem_total ctr_cpu_pct host_ram_used
                            host_ram_total host_swap_used host_swap_total host_disk_used host_disk_total
                            host_cpu_pct host_cores pod_images pod_containers pod_volumes host_disk_dev);
    is_deeply($A->({ resources => $full }), [], 'A1: fresh and complete -> no body line');
    is_deeply($A->({ resources => { %$full, snapshot_state => 'stale', snapshot_age => 300 } }), [], 'A2: stale -> no body line (the title says it)');
    is_deeply($A->({ resources => undef, resources_sampler => { status => 'running', child_alive => 1, elapsed => 3, grace => 60 } }), [],
        'A3: still sampling inside the grace window -> no body line');

    my $sp = $A->({ resources => undef, resources_sampler => { status => 'running', child_alive => 0, why => 'perl: bad flag' } });
    is(scalar(@$sp), 1, 'A4: a sampler that exited -> exactly one span');
    is($sp->[0]{text}, 'FAILED - sampler exited before writing a reading - perl: bad flag', 'A4: its full FAILED text, cause included, no label');
    is($sp->[0]{role}, 'state.crit', 'A4: state.crit');

    $sp = $A->({ resources => undef, resources_sampler => { status => 'failed' } });
    like($sp->[0]{text} // '', qr/\AFAILED - sampler failed to start/, 'A5: a sampler that never started');

    $sp = $A->({ resources => undef, resources_sampler => { status => 'running', child_alive => 1, elapsed => 200, grace => 60 } });
    like($sp->[0]{text} // '', qr/\ASTALLED - sampler still running, no reading after 3m\z/, 'A6: a stalled sampler');
    is($sp->[0]{role}, 'state.warn', 'A6: state.warn');

    $sp = $A->({ resources => { snapshot_state => 'fresh', snapshot_age => 5,
                                snapshot_probe_errors => { stats => 'Cannot connect to Podman socket' } } });
    is($sp->[0]{text}, 'no readings - Cannot connect to Podman socket', 'A7: a snapshot with no readings, and why');
    is($sp->[0]{role}, 'state.crit', 'A7: state.crit');

    my %part = %$full; delete @part{qw(pod_images pod_containers)};
    $sp = $A->({ resources => { %part, snapshot_probe_errors => { df => 'df timed out' } } });
    is($sp->[0]{text}, '2 facts unavailable - df timed out', 'A8: a partial snapshot keeps only what is missing and why (freshness is the title\'s)');
    is($sp->[0]{role}, 'state.warn', 'A8: state.warn');

    $sp = $A->({ resources => { snapshot_state => 'failed' } });
    is($sp->[0]{text}, 'FAILED - snapshot unreadable; no values', 'A9: an unreadable snapshot');
}

# ===========================================================================
# H. Run title
# ===========================================================================
my $H = \&tui::DashboardScreen::run_title_suffix;
{
    my $lim = tui::DashboardScreen::HEARTBEAT_STALE_SECS();
    cmp_ok($lim, '>', 120, 'H0: the stale threshold is past the 120s heartbeat interval');
    is_deeply($H->({}), [], 'H1: no heartbeat yet -> no suffix (the row it replaces was absent too)');
    is(T($H->({ beat_age => 30 })), "$DOT <1m", 'H2: a 30s-old heartbeat -> "· <1m"');
    is($H->({ beat_age => 30 })->[0]{role}, 'text.muted', 'H2: muted');
    is(T($H->({ beat_age => $lim - 1 })), "$DOT " . tui::DashboardScreen::_block_elapsed($lim - 1), 'H3: just under the threshold is still an age');
    my $sp = $H->({ beat_age => $lim });
    is(T($sp), "$DOT stale " . tui::DashboardScreen::_block_elapsed($lim), 'H4: at the threshold -> "· stale Nm"');
    ok((grep { $_->{role} eq 'state.warn' && $_->{text} =~ /stale/ } @$sp), 'H4: in state.warn');
    is_deeply($H->({ beat_age => 'soon' }), [], 'H5: a non-numeric age draws nothing');
}

# ===========================================================================
# P. the composed panels
# ===========================================================================
sub frame { my ($st, $r, $c) = @_; return join "\n", map { $_->{text} // '' } @{ Dashboard::compose_frame($st, $r, $c) }; }
sub base_state {
    return { project_name => 'demo', container => 'c1', status => 'running', events => [], now => 1_767_225_600,
             beat_age => 12, uptime => 3600, runs => [] , @_ };
}
{
    my $res = { snapshot_state => 'stale', snapshot_age => 725, ctr_cpu_pct => 12, host_cpu_pct => 30 };
    my $f = frame(base_state(resources => $res), 40, 121);
    like($f, qr/\Q$RULE\E Run \Q$DOT\E <1m \Q$RULE\E/, 'P1: the Run title carries the heartbeat age');
    like($f, qr/\Q$RULE\E Resources \Q$DOT\E stale 12m \Q$RULE\E/, 'P1: the Resources title carries "stale 12m"');
    unlike($f, qr/^heartbeat\s/m, 'P2: the heartbeat row is gone from Run');
    unlike($f, qr/(?:^|\x{2502})snapshot\s/m, 'P2: the snapshot row is gone from Resources');
    like($f, qr/^uptime\s/m, 'P2 control: the Run body is still there (uptime row)');
    like($f, qr/ctr cpu/, 'P2 control: the Resources readings are still there');
    unlike($f, qr/STALE - last written/, 'P3: no stale body line (the title says it)');

    $f = frame(base_state(resources => undef, resources_sampler => { status => 'running', child_alive => 0, why => 'boom' }), 40, 121);
    like($f, qr/Resources \Q$DOT\E sampling/, 'P4: no snapshot -> "Resources · sampling…"');
    like($f, qr/FAILED - sampler exited before writing a reading - boom/, 'P4: and the failure is the one body line');

    $f = frame(base_state(resources => undef, resources_sampler => { status => 'running', child_alive => 1, elapsed => 2, grace => 60 }), 40, 121);
    unlike($f, qr/sampling - no reading yet/, 'P5: while simply sampling the body says nothing (the title does)');

    $f = frame(base_state(resources => $res, beat_age => 400), 40, 121);
    like($f, qr/Run \Q$DOT\E stale 6m/, 'P6: a stale heartbeat reads "Run · stale 6m"');

    # the narrow split: at 121 columns Run is 44-45 wide; its stale title fits
    my ($row) = grep { /Run \Q$DOT\E stale/ } split /\n/, $f;
    my ($run_part) = split /\x{2502}|\x{252C}/, $row // '';
    like($run_part // '', qr/Run \Q$DOT\E stale 6m \Q$RULE\E/, 'P7: "Run · stale 6m" fits whole in the narrow Run column');
}

done_testing();
