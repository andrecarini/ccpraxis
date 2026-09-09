#!/usr/bin/env perl
# tui-preview.pl -- a live, resizable preview of the sandbox dashboard, driven
# by synthetic state.
#
# WHY THIS EXISTS. Layout decisions on this TUI kept being argued from measured
# numbers and composed-frame dumps, which answer "does it fit" but not "does it
# look right". The responsive behaviour in particular -- what happens between
# 119 and 178 columns, whether a panel silently vanishes on a short terminal --
# is something you have to WATCH by dragging a window edge. Operator request,
# 2026-08-27: "make a fake TUI with synthetic static data that works as close as
# possible to the real TUI and reacts to different terminal window sizes."
#
# IT IS THE REAL PIPELINE. This composes through Dashboard::compose_frame, which
# is the same entry point the launcher's render tick calls -- so tui::Layout's
# placement, tui::Screen's banding and borders, tui::DashboardScreen's panels
# and Theme's roles and glyphs are all the shipping code. The ONLY thing faked
# is the state hash. If the preview looks wrong, the TUI is wrong.
#
# IT STARTS NO CONTAINERS. It never loads launcher.pl, never forks a sampler and
# never talks to podman. That is deliberate and load-bearing: launcher.pl builds
# images and starts containers as a side effect of being run.
#
#   perl scripts/tui-preview.pl
#
#   [q]        quit
#   [space]    pause / resume the animation
#   [.] [,]    step one phase forward / back (also pauses)
#   [0]        back to phase 0
#   [c]        CAPTURE: viewport, bands, panel heights and the rendered frame,
#              written to .ccpraxis-local-data/tui-preview-capture.txt and
#              copied to the clipboard
#   [d]        dismiss the top warning   [D] bring them all back
#   [+] [-]    pin the blueprint-run count (the panel starved first)
#   [s]        cycle the container status (running, created, stopping, exited,
#              unknown, container-gone, an unrecognised string...)
#   [S]        status back to automatic
#   [a]        release the pin, back to automatic
#
# [d] is dismiss here because [d] is dismiss in the real dashboard
# (Dashboard::dispatch_key). A preview that teaches a different key than the
# thing it previews is worse than one with no keys at all.
#
# Resize the window while it runs; it repaints on the new geometry. Pause on
# anything that looks wrong and press [c] -- the phase is deterministic, so
# `--dump WxH --phase N` reproduces exactly what was on screen, and
# `--dump WxH --phase N --report` prints the same capture.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../plugins/sandbox/scripts";

require Dashboard;
require tui::Screen;
require tui::Layout;
require tui::DashboardScreen;
require tui::Meter;
require Theme;

my $HAVE_READKEY = eval { require Term::ReadKey; 1 } ? 1 : 0;

# SYNTH_NOW -- the fixed synthetic clock (package 07). Every started_at the
# tree fixtures below carry is derived from this ONE constant, never from a
# real time() -- that is what makes `--dump WxH --phase N` byte-identical
# across two runs (AC42) and what keeps `_agent_live`'s stale/future filters
# exercisable without the fixture drifting out of range as real time passes.
# Any fixed positive integer of at most 12 digits works (_epoch's own
# contract); this one reads as a plausible recent epoch, nothing more.
use constant SYNTH_NOW => 1_767_225_600;

# Dismissed warning ids. Lives here, not in synth_state: the generator keeps
# producing a warning while its period is active, so "dismissed" has to be
# remembered by the loop or the popup would return on the next frame.
my %DISMISSED;

# ---------------------------------------------------------------------------
# Synthetic state.
#
# DETERMINISTIC BUT NOT STATIC. Everything is a pure function of $phase, so a
# geometry is reproducible (`--phase N` gives byte-identical output) while still
# animating -- the point is to watch panels CHANGE height under a fixed
# terminal, which is what actually breaks a layout.
#
# Nothing here uses rand() or time() for content, deliberately: a value that
# drifts between two renders makes two screenshots incomparable, and an
# intermittent layout bug you cannot reproduce is worse than none.
#
# The numbers are plausible rather than round -- real readings are what expose
# an alignment bug, and a column of "50%" would hide one.
# ---------------------------------------------------------------------------
my $GB = 1024 ** 3;

# EVERY DIMENSION IS DRIVEN BY $phase, ON A DIFFERENT PERIOD.
#
# Operator, 2026-08-27: "I need it to also exercise the dynamic things that a
# real session would do... see everything that can vary in size and it needs to
# be exercised." A static snapshot shows one geometry; what actually breaks a
# layout is a panel CHANGING height under a fixed terminal -- a banner arriving,
# a sampler dropping out, a blueprint list growing past its cap.
#
# The periods below are deliberately coprime-ish (5, 7, 11, 13, 17, 19, 23, 29,
# 31, 37). Driving everything off one counter would only ever show a handful of
# combinations, always in the same order; staggered periods mean a banner
# eventually arrives while the sampler is down AND the blueprint list is at its
# cap, which is the combination that finds the bug.
#
# The full list of what varies, taken from the state keys DashboardScreen
# actually reads rather than from memory:
#   banners      install_warning, hot_reload      (push the whole grid down)
#   Blueprints   runs count and name lengths      (tallest variable panel)
#   Activity     event count and per-row wrapping (1-3 rows each)
#   Resources    present / partial / sampler-wait, and gauge values sweeping
#                the full 0..100 so all four gauge.* bands appear
#   Providers    logged in / logged out / unreadable
#   Run          triage, backpack, keep-awake, busy lease, oauth
#   header       project and container name lengths, status, spinner
#   footer       needs_you, pending, footer_flash

sub sweep {
    # A triangle wave in 0..100 with period $p, offset by $o. Triangle rather
    # than sawtooth so every value is visited in both directions -- a gauge that
    # only ever grows never shows the crit->warn transition.
    my ($phase, $p, $o) = @_;
    my $x = ($phase + $o) % (2 * $p);
    $x = (2 * $p) - $x if $x > $p;
    return int($x * 100 / $p);
}

sub synth_resources {
    my ($phase) = @_;

    # Three modes on a slow period: full readings, a partial snapshot with
    # facts missing (the "N facts unavailable" path), and no snapshot at all.
    my $mode = int($phase / 17) % 3;
    return undef if $mode == 2;

    my $ram  = sweep($phase, 37, 0)  / 100;
    my $swap = sweep($phase, 23, 5)  / 100;
    my $disk = sweep($phase, 53, 11) / 100;

    my %r = (
        snapshot_state  => ($phase % 11 == 0) ? 'stale' : 'fresh',
        snapshot_age    => ($phase % 11 == 0) ? 240 : ($phase % 60),
        machine_name    => 'podman-machine-default',
        machine_state   => (int($phase / 29) % 4 == 3) ? 'starting' : 'running',
        ctr_mem_used    => (sweep($phase, 19, 3) / 100) * 10.4 * $GB,
        vm_mem_total    => 10.4 * $GB,
        ctr_cpu_pct     => sweep($phase, 13, 0),
        host_ram_used   => $ram * 25.5 * $GB,
        host_ram_total  => 25.5 * $GB,
        host_swap_used  => $swap * 12.6 * $GB,
        host_swap_total => 12.6 * $GB,
        host_disk_dev   => 'C:',
        host_disk_used  => $disk * 254.8 * $GB,
        host_disk_total => 254.8 * $GB,
        host_cpu_pct    => sweep($phase, 7, 2),
        host_cores      => 16,
    );

    # mode 1: the podman df probe is the one that really does drop out (it has
    # its own 45s budget and 10-minute cadence), so that is what goes missing.
    if ($mode == 0) {
        $r{pod_images}     = 2.6 * $GB;
        $r{pod_containers} = (10 + ($phase % 20)) * $GB;
        $r{pod_volumes}    = ($phase % 3) * 0.4 * $GB;
    }
    return \%r;
}

sub synth_events {
    my ($phase) = @_;
    my @names = qw(
        launch_start manager_ready resources_sampler_forked spend_sampler_forked
        container_sampler_forked launcher_reexec claude_code_launched
        blueprint_run_started blueprint_package_done reaper_swept
        heartbeat_ok snapshot_written podman_machine_checked
    );
    # The feed GROWS AND SHRINKS. A fixed 60-event list always overflows, so the
    # under-filled column -- where the panel is taller than its content and the
    # scroll markers must NOT appear -- never gets rendered at all.
    my $n = 2 + (sweep($phase, 31, 0) * 58 / 100);
    my @out;
    for my $i (0 .. $n - 1) {
        my $mm = 59 - ($i % 60);
        # Row length varies per row AND drifts with phase, so the same event
        # wraps to one, two or three lines over time. Wrapped rows are what make
        # the panel's height stop tracking its event count.
        my $tail = '';
        $tail = ' with a trailing explanation that has to wrap onto a second line'
            if ($i + $phase) % 7 == 0;
        $tail = ' with a considerably longer trailing explanation that keeps going '
              . 'well past two lines and has to be capped by the three-line rule'
            if ($i + $phase) % 17 == 0;
        push @out, [
            { text => tui::DashboardScreen::activity_time_text(sprintf('%02d:%02d', 19 - int($i / 12), $mm)),
              role => 'text.muted' },
            { text => 'o ', role => 'text.primary' },
            { text => $names[ $i % @names ] . $tail, role => 'text.primary' },
        ];
    }
    return \@out;
}

# _synth_pkg_agents($i, $phase, $j, $stuck) -> \@agents. Field names taken
# from the shipped struct (S2.10), never invented: id role worker_type
# started_at budget_seconds stale_after_seconds, role in
# coordinator|worker|judge. Pure function of its own arguments and
# SYNTH_NOW -- no time()/localtime()/rand() (package 07's own AC48 guard).
#
# $stuck=>1 (package index 0 of every running run, package 07's DC3 fixture)
# always carries THREE fixed agents: a coordinator, an OVER-BUDGET-but-still-
# live worker (elapsed exceeds budget_seconds but stays inside
# stale_after_seconds -- AC39), and a live bp-resolve-judge (AC38) -- plus one
# genuinely STALE agent and one FAR-FUTURE-started_at agent (both fail
# _agent_live and so must never appear in a rendered dump -- AC46).
sub _synth_pkg_agents {
    my ($i, $phase, $j, $stuck) = @_;
    my @agents;
    if ($stuck) {
        push @agents, { id => "r${i}p${j}c", role => 'coordinator', worker_type => undef,
                         started_at => SYNTH_NOW() - 900, budget_seconds => 1800, stale_after_seconds => 7200 };
        push @agents, { id => "r${i}p${j}w", role => 'worker', worker_type => 'bp-implementer',
                         started_at => SYNTH_NOW() - 1800, budget_seconds => 900, stale_after_seconds => 7200 };
        push @agents, { id => "r${i}p${j}j", role => 'judge', worker_type => 'bp-resolve-judge',
                         started_at => SYNTH_NOW() - 300, budget_seconds => 1800, stale_after_seconds => 7200 };
        push @agents, { id => "r${i}p${j}stale", role => 'worker', worker_type => 'pv-worker-stale',
                         started_at => SYNTH_NOW() - 100_000, budget_seconds => 1800, stale_after_seconds => 1800 };
        push @agents, { id => "r${i}p${j}future", role => 'worker', worker_type => 'pv-worker-future',
                         started_at => SYNTH_NOW() + 10_000_000, budget_seconds => 1800, stale_after_seconds => 7200 };
        return \@agents;
    }
    # Non-stuck packages: 0..4 agents, swept across (run, phase, package
    # index) so every count from 0 through >=4 appears somewhere across the
    # phase range (package 07's AC40 coverage: 0, exactly 1, and >=4).
    my $n = ($i + $phase + $j) % 5;
    for my $k (1 .. $n) {
        my $role = ($k == 1) ? 'coordinator' : 'worker';
        push @agents, {
            id                  => "r${i}p${j}a${k}",
            role                => $role,
            worker_type         => ($role eq 'coordinator') ? undef : "pv-worker-$i-$j-$k",
            started_at          => SYNTH_NOW() - (300 + 60 * $k),
            budget_seconds      => 1800,
            stale_after_seconds => 7200,
        };
    }
    return \@agents;
}

# _synth_packages($i, $phase) -> \@packages. Package index 0 is always the
# STUCK one (status running, attempt == attempt_cap -- package 07's AC38
# precondition); the rest sweep attempt/step/agent-count for visual variety.
sub _synth_packages {
    my ($i, $phase) = @_;
    my $n = 1 + (($i * 7 + $phase) % 4);   # 1..4 packages per running run
    my @packages;
    for my $j (0 .. $n - 1) {
        my $stuck = ($j == 0) ? 1 : 0;
        my ($attempt, $cap) = $stuck ? (3, 3) : (1 + ($j % 2), 5);
        push @packages, {
            name          => sprintf('pkg-preview-%d-%02d', $i, $j),
            status        => 'running',
            attempt       => $attempt,
            attempt_cap   => $cap,
            step          => sprintf('%d/%d', 1 + ($j % 3), 3 + ($j % 5)),
            steps_pending => [ ($j + 1) .. ($j + 3) ],
            next_action   => undef,
            agents        => _synth_pkg_agents($i, $phase, $j, $stuck),
        };
    }
    return \@packages;
}

# _synth_run_agents($i, $phase) -> \@agents. A live bp-conformance-judge on
# roughly half the (run, phase) combinations, an empty list on the rest --
# package 07's AC40 needs both, and AC27/M4's own fixture is what this
# mirrors (a blueprint-scoped judge in `run_agents`, the last tree row).
sub _synth_run_agents {
    my ($i, $phase) = @_;
    return [] if ($i + $phase) % 2 == 1;
    return [ { id => "r${i}-cj", role => 'judge', worker_type => 'bp-conformance-judge',
                started_at => SYNTH_NOW() - 600, budget_seconds => 1800, stale_after_seconds => 7200 } ];
}

# synth_runs($n, $phase) -> \@runs. Field names taken from the shipped
# struct, never guessed -- a first pass that invented {name}/{pct} rendered
# every row as "? running 0/0 pkg", a preview that looked plausible and
# showed nothing (this file's own long-standing warning, package 07's own
# repeat of it at ten times the struct size). EVERY element (running or not)
# carries the full 17-key run-level struct (S2.10) -- simpler than
# maintaining two shapes, and nothing downstream distinguishes them; a
# non-running element's packages/run_agents are simply empty, which is what
# the real gate (_tree_lines: state eq 'running') already requires for a
# tree to render at all.
sub synth_runs {
    my ($n, $phase) = @_;
    $n     = 0 unless defined($n)     && !ref($n)     && $n     =~ /^\d+$/;
    $phase = 0 unless defined($phase) && !ref($phase) && $phase =~ /^-?\d+$/;

    my @states = qw(running running queued paused done failed);
    my @names  = qw(tui-operator-feedback sandbox-resources statusline-rework
                    activity-column providers-panel theme-tokens layout-bands
                    hot-reload spend-adapter reaper-sweep preview-harness
                    gauge-palette);

    my @out;
    for my $i (1 .. $n) {
        my $state     = $states[ $i % @states ];
        my $blueprint = $names[ ($i - 1) % @names ];
        my $running   = ($state eq 'running') ? 1 : 0;

        my $packages   = $running ? _synth_packages($i, $phase)    : [];
        my $run_agents = $running ? _synth_run_agents($i, $phase)  : [];
        my $current    = (@$packages) ? $packages->[-1]{name} : undef;

        push @out, {
            blueprint               => $blueprint,
            runs_dir                 => "/tmp/ccpraxis-preview-runs/$blueprint",
            state                    => $state,
            orchestrator_pid         => 4000 + (($i * 37) % 5000),
            orchestrator_alive       => (($i + $phase) % 4 == 0) ? 0 : 1,
            orchestrator_started_at  => SYNTH_NOW() - (600 + 300 * ($i % 5)),
            paused_manual            => ($state eq 'paused' && ($i % 2 == 0)) ? 1 : 0,
            paused_reason            => ($state eq 'paused')
                                       ? 'preview-synthetic pause: waiting on operator input'
                                       : undef,
            packages_total           => 9,
            packages_done            => ($i * 3) % 9,
            current_package          => $current,
            running_coordinators     => ($i % 3),
            decisions_waiting        => ($i % 5 == 0) ? 1 : 0,
            decisions_operator       => ($i + $phase) % 3,
            decisions_triage         => ($i + $phase + 1) % 3,
            packages                 => $packages,
            run_agents               => $run_agents,
        };
    }
    return \@out;
}

# EVERY STATUS THE STATUS BLOCK CAN SHOW, in one cycle-able list.
#
# Operator, 2026-08-28: a key to cycle between these on the preview. Driving
# them off $phase alone meant most were unreachable in practice -- the rare ones
# (removing, unknown, the unreachable flag) would need minutes of watching, and
# the unrecognised-string case never appeared at all.
#
# The list is podman's real set (libpod/define/containerstate.go) plus the two
# entries that are NOT statuses: container_gone, which is our heartbeat failing
# rather than anything podman said, and a deliberately unrecognised string,
# which is the only way to see the no-glyph fallback.
our @STATUS_CYCLE = (
    { label => 'auto (phase-driven)' },
    { label => 'running',      status => 'running' },
    { label => 'created',      status => 'created' },
    { label => 'initialized',  status => 'initialized' },
    { label => 'stopping',     status => 'stopping' },
    { label => 'removing',     status => 'removing' },
    { label => 'stopped',      status => 'stopped' },
    { label => 'paused',       status => 'paused' },
    { label => 'exited',       status => 'exited' },
    { label => 'unknown',      status => 'unknown' },
    { label => 'container gone (heartbeat failed)', status => 'running', gone => 1 },
    { label => 'unrecognised string',               status => 'frobnicated' },
);

sub synth_state {
    my ($phase, $runs_override, $status_idx) = @_;

    my @statuses = ('running', 'running', 'running', 'starting', 'exited');
    my $status   = $statuses[ int($phase / 29) % @statuses ];

    # A pinned status overrides the phase-driven one. Index 0 is 'auto', which
    # leaves the animation in charge.
    my $pin = ($status_idx && $STATUS_CYCLE[$status_idx]) ? $STATUS_CYCLE[$status_idx] : undef;
    $status = $pin->{status} if $pin && defined $pin->{status};

    # Names change length: the header is the one row that must absorb a long
    # project AND a long container id without pushing anything else around.
    my $long_names = (int($phase / 19) % 2) == 1;
    my $project    = $long_names ? 'indocs-bacen-scraper-with-a-very-long-name' : 'ccpraxis';
    my $container  = $long_names ? 'claude-indocs-bacen-scraper-with-a-very-long-name-2c052ba3'
                                 : 'claude-ccpraxis-8f21ab3';

    # Providers cycles through logged in / logged out / endpoint unreadable --
    # each a different number of rows.
    my $prov = int($phase / 13) % 3;
    my ($tokens, $spend);
    if ($prov == 0) {
        $tokens = { utilization => sweep($phase, 11, 0), resets_at => time + 3600 };
        $spend  = { claude => { utilization => sweep($phase, 11, 0) },
                    go     => { used => ($phase % 10), limit => 10 },
                    zen    => { balance => 12.5 } };
    }
    elsif ($prov == 1) { $tokens = undef; $spend = undef }
    else               { $tokens = { utilization => undef }; $spend = { claude => {} } }

    my $n_runs = defined $runs_override ? $runs_override
               : int(sweep($phase, 15, 0) * 14 / 100);

    my %st = (
        project_name     => $project,
        container        => $container,
        status           => $status,
        # SYNTH_NOW, not time() -- the fixed synthetic clock every started_at
        # in synth_runs is measured against, so a geometry/phase reproduces
        # byte-identically (package 07, AC41/AC42).
        now              => SYNTH_NOW(),
        container_gone   => $pin ? ($pin->{gone} ? 1 : 0)
                                 : (($status eq 'exited' && $phase % 2) ? 1 : 0),
        beat_age         => ($phase % 41),
        busy_age         => ($phase % 9 < 4) ? ($phase % 300) : undef,
        uptime           => 3 * 3600 + ($phase * 37) % 3600,
        stay_awake       => ($phase % 6 < 3) ? 1 : 0,
        spinner_idx      => $phase % Theme::SPINNER_FRAMES(),
        # The window title reads its OWN index, and omitting it is not a no-op:
        # _title_spinner_char falls back to a literal '*' when the index is
        # missing, so the title showed a static asterisk and the preview
        # misrepresented the shipping behaviour as a design choice. The two
        # counters are separate in the real launcher (the title advances on its
        # own cadence), so they are separate here.
        title_spinner_idx => $phase % Theme::SPINNER_FRAMES(),
        resources        => synth_resources($phase),
        events           => synth_events($phase),
        runs             => synth_runs($n_runs, $phase),
        backpack         => { items => ($phase % 8), pending => ($phase % 5) },
        oauth_remaining  => 7 * 3600 + 21 * 60 - ($phase * 60),
        tokens           => $tokens,
        spend            => $spend,
        triage_queued    => int($phase / 5) % 4,
        needs_you        => int($phase / 11) % 3,
        pending          => int($phase / 3) % 4,
    );

    # BANNERS ARE THE BIGGEST SIZE EVENT ON THE SCREEN -- each one pushes the
    # whole panel grid down a row (or several, once it wraps), so a layout that
    # only ever fits without one is not a layout that fits. They arrive and
    # clear on their own periods.
    # WARNINGS ARE NOW AN OVERLAY, NOT A BANNER (operator, 2026-08-27). They no
    # longer go through install_warning, which composed into the layout and
    # pushed the grid down. Three of them arrive on different periods so the
    # STACK is exercised -- one warning proves nothing about how two stack, and
    # the stacking is the part with an ordering rule to get wrong.
    my @warn;
    push @warn, { id => 'install', key => 'd',
                  text => 'the installed launcher is older than this clone -- run install.pl '
                        . 'to promote it, or the sandbox will keep launching the previous revision' }
        if ($phase % 23) < 8;
    push @warn, { id => 'disk', key => 'd',
                  text => 'host disk above 90% -- podman image pulls will start failing' }
        if ($phase % 13) < 5;
    push @warn, { id => 'sampler', key => 'd',
                  text => 'the resources sampler has not written a snapshot for 4 minutes' }
        if ($phase % 37) < 6;
    $st{warnings} = \@warn if @warn;

    $st{hot_reload} = { reloaded => 3, failed => 0 } if ($phase % 31) < 4;
    $st{footer_flash} = 'reloaded 3 modules' if ($phase % 31) < 2;
    $st{resources_sampler} = { state => 'starting' } if !defined $st{resources};

    return \%st;
}

# ---------------------------------------------------------------------------
# Diagnostics -- what the layout engine decided, in the engine's own terms.
# ---------------------------------------------------------------------------
sub tier_of {
    my ($cols) = @_;
    my $side = tui::Screen::side_column_width($cols);
    my $main = $cols - $side;
    return $side > 0 ? 'FULL (side column)'
         : ($main >= 119 ? 'WIDE (paired, in-flow activity)' : 'NARROW (single column)');
}

# capture_report(...) -> the full diagnostic dump, as text.
#
# REPLACES THE PERMANENT DIAGNOSTICS BAR. That bar overwrote the footer row --
# the very thing it was sitting on top of -- so it hid one of the surfaces being
# previewed, and it was on screen constantly for information that is only wanted
# at the moment something looks wrong. Operator, 2026-08-27: "Remove the debug
# info bar that you added and just make it copy to clipboard all the info you
# need (including the current viewport) or save it to some file on a keypress."
#
# It carries the RENDERED FRAME as well as the numbers, because the numbers say
# what the engine decided and the frame says what that looked like -- and the
# whole reason this harness exists is that those are different questions.
sub capture_report {
    my ($state, $rows, $cols, $phase, $dismissed) = @_;
    my $side = tui::Screen::side_column_width($cols);
    my $main = $cols - $side;
    my $panels = tui::DashboardScreen::panels($state, $main);
    my $placed = tui::Layout::place($panels, $main);

    my @out;
    push @out, "ccpraxis tui-preview capture";
    push @out, sprintf("reproduce: perl scripts/tui-preview.pl --dump %dx%d --phase %d", $cols, $rows, $phase);
    push @out, '';
    push @out, sprintf("viewport      %d cols x %d rows", $cols, $rows);
    push @out, sprintf("phase         %d", $phase);
    push @out, sprintf("tier          %s", tier_of($cols));
    push @out, sprintf("side column   %d  (body %d)", $side, tui::Screen::side_column_body_width($cols));
    push @out, sprintf("main region   %d", $main);
    push @out, sprintf("chrome rows   %d   body rows %d", tui::Screen::chrome_rows(), $rows - tui::Screen::chrome_rows());
    push @out, '';
    push @out, "bands:";
    for my $band (@$placed) {
        push @out, '  ' . join('  |  ', map { sprintf('%s w=%d', $_->{panel}{title}, $_->{w}) } @$band);
    }
    push @out, '';
    push @out, "panel natural heights (title + body lines):";
    for my $p (@$panels) {
        push @out, sprintf('  %-16s %3d%s%s', $p->{title}, 1 + scalar(@{ $p->{lines} || [] }),
            ($p->{flex} ? '  flex' : ''), ($p->{side} ? '  side' : ''));
    }
    push @out, '';
    # THE MEASURED ROW BUDGET (package 07, S2.10). `C` is what
    # _blueprints_capacity actually measured at this geometry through the
    # real tui::Screen pipeline (ruling AT-14 -- never predicted); `P` is the
    # row plan's own entry count; `H` is how many of those the SAME
    # collapse math (_blueprints_body's own S2.3 pseudocode, replicated here
    # only to REPORT the number, not to render it -- the render still goes
    # through Dashboard::compose_frame/compose()'s own S2.7 wiring) would
    # hide at that capacity. 'n/a' for any part that could not be measured
    # (no tree present, a geometry too small to resolve).
    # CORRECTED (fix-batch, redteam MEDIUM-1): the plan/table-width figures
    # below must be computed at $main, the width the Blueprints panel is
    # ACTUALLY rendered into (panels() above already uses $main, matching
    # what screen()/panels() does internally in the real pipeline) -- not
    # $cols, the raw terminal width including any side column. At cols >=
    # ~178 (a side column exists) the two widths diverge and the reported
    # figures described a panel that was never rendered (report said
    # "hidden 5" while the frame's own notice said "+6"). _blueprints_capacity
    # is the one exception: it is called with the raw $cols deliberately,
    # matching Dashboard::compose()'s own call (it composes a full probe
    # frame and narrows internally via screen()/compose(), exactly as the
    # real pipeline does).
    my $bp_cap  = tui::DashboardScreen::_blueprints_capacity($state, $rows, $cols);
    my $bp_plan = tui::DashboardScreen::_blueprints_row_plan($state, $main);
    my $bp_plan_n = (ref($bp_plan) eq 'ARRAY') ? scalar(@$bp_plan) : undef;
    my $bp_hidden;
    # $bp_cap >= 1 -- a SECOND defect in the same block: _blueprints_body's
    # own gate (`$cap >= 1`) treats capacity 0 as "no collapse" (today's
    # unbounded pipeline runs instead), but the collapse math below used to
    # run unconditionally, reporting the WHOLE plan as hidden even though
    # the rendered frame carries no collapse notice at all (capacity 0 ==
    # no Blueprints body, S5's own documented "no collapse" edge case).
    if (defined($bp_cap) && $bp_cap >= 1 && defined($bp_plan_n) && $bp_plan_n > 0
        && tui::DashboardScreen::_tree_present($state)) {
        my $bp_width = tui::DashboardScreen::_blueprints_table_width($main);
        my $bp_total = 0;
        $bp_total += tui::DashboardScreen::_row_cost($_->{spans}, $bp_width) for @$bp_plan;
        if ($bp_total <= $bp_cap) {
            $bp_hidden = 0;
        } else {
            my $bp_reserve = tui::DashboardScreen::_row_cost(
                tui::DashboardScreen::_collapse_notice($bp_plan_n), $bp_width);
            my $bp_keep = tui::DashboardScreen::_select_rows($bp_plan, $bp_cap - $bp_reserve, $bp_width);
            $bp_hidden = $bp_plan_n - (ref($bp_keep) eq 'ARRAY' ? scalar(@$bp_keep) : 0);
        }
    }
    push @out, sprintf("blueprints    capacity %s  plan %s  hidden %s",
        defined($bp_cap)     ? $bp_cap     : 'n/a',
        defined($bp_plan_n)  ? $bp_plan_n  : 'n/a',
        defined($bp_hidden)  ? $bp_hidden  : 'n/a');
    push @out, '';
    # THE REAL POPULATION, via warning_entries -- not $state->{warnings}.
    #
    # This reported the raw caller-supplied list, which is exactly the blind
    # spot that let a visible `!!` row coexist with "warnings live 0" in a
    # capture. A diagnostic that reads a different source than the renderer will
    # confirm whatever you already believe.
    my $live = tui::DashboardScreen::warning_entries($state);
    push @out, sprintf("warnings live %d   dismissed: %s",
        scalar(@$live),
        (%$dismissed ? join(',', sort keys %$dismissed) : '(none)'));
    push @out, sprintf("  - %-12s %s", $_->{id}, $_->{text}) for @$live;
    push @out, sprintf("status        %s%s", $state->{status} // '?',
        ($state->{container_gone} ? ' (container gone)' : ''));
    push @out, sprintf("window title  %s", Dashboard::window_title($state));
    push @out, '';
    push @out, '--- rendered frame ---';
    push @out, split /\n/, render_plain($state, $rows, $cols, 0, $phase);
    return join("\n", @out) . "\n";
}

# to_clipboard($text) -> 1 on success. Best-effort and platform-detected; the
# file is written regardless, so a missing clipboard tool costs nothing.
sub to_clipboard {
    my ($text) = @_;
    my $cmd;
    for my $c ('clip.exe', 'pbcopy', 'xclip -selection clipboard', 'wl-copy') {
        my ($bin) = split / /, $c;
        my $found = `command -v $bin 2>/dev/null`;
        if (defined $found && $found =~ /\S/) { $cmd = $c; last }
    }
    return 0 unless $cmd;
    open my $ph, '|-', $cmd or return 0;
    print $ph $text;
    close $ph;
    return 1;
}

sub diag_line {
    my ($state, $rows, $cols, $phase) = @_;
    my $side  = tui::Screen::side_column_width($cols);
    my $main  = $cols - $side;
    my $panels = tui::DashboardScreen::panels($state, $main);
    my $placed = tui::Layout::place($panels, $main);
    my $bands  = join ' / ', map {
        join('+', map { substr($_->{panel}{title}, 0, 4) . ':' . $_->{w} } @$_)
    } @$placed;
    # The side panel is EXCLUDED from the height sum. It is lifted out of the
    # flow before placement and spans the body by construction, so counting its
    # (deliberately over-supplied) event list made every geometry report a wild
    # overflow that told you nothing.
    # A FLEX panel is counted at its MINIMUM (title + one row), not its natural
    # height: it absorbs whatever the fixed panels leave rather than demanding
    # its content's height. Counting Activity's sixty synthetic events made
    # every narrow geometry report a fictional overflow, which is worse than no
    # number at all -- the figure is here to say whether the FIXED panels fit.
    my $natural = 0;
    for my $p (@$panels) {
        next if $side > 0 && ref($p) eq 'HASH' && $p->{side};
        $natural += (ref($p) eq 'HASH' && $p->{flex})
                  ? 2
                  : 1 + scalar(@{ $p->{lines} || [] });
    }
    my $body = $rows - tui::Screen::chrome_rows();
    return sprintf(' %dx%d  side=%d main=%d  body=%d need=%d%s  %s  [%s] ',
        $cols, $rows, $side, $main, $body, $natural,
        ($natural > $body ? ' OVERFLOW' : ''), $bands, tier_of($cols));
}

# ---------------------------------------------------------------------------
# Terminal handling. The same GetTerminalSize the launcher's term_size seam
# uses, so the preview measures the window exactly as the real TUI does.
# ---------------------------------------------------------------------------
sub term_size {
    if ($HAVE_READKEY) {
        # GetTerminalSize DIES (rather than returning empty) when it cannot
        # measure -- which is every non-tty context, including a pipe. The warn
        # handler is silenced too: it emits its complaint before dying, so
        # catching the exception alone still leaves the message printed over the
        # frame.
        my @s = eval {
            local $SIG{__WARN__} = sub { };
            Term::ReadKey::GetTerminalSize();
        };
        return (((@s && $s[0]) ? $s[0] : 80), ((@s && $s[1]) ? $s[1] : 24)) if @s;
    }
    my $out = `stty size 2>/dev/null` || '';
    return ($2, $1) if $out =~ /^(\d+)\s+(\d+)/;
    return (80, 24);
}

# render_plain($state, $rows, $cols) -> the frame as plain text, SGR stripped.
# Used by --dump, which exists so a geometry can be inspected (or pasted into a
# discussion) without a terminal at all.
sub render_plain {
    my ($state, $rows, $cols, $show_diag, $phase) = @_;
    my $frame = Dashboard::compose_frame($state, $rows, $cols);
    if ($show_diag && @$frame) {
        my $d = diag_line($state, $rows, $cols, $phase);
        $d = substr($d, 0, $cols) if length($d) > $cols;
        $frame->[-1] = { text => $d, role => "footer" };
    }
    my @out;
    for my $cell (@$frame) {
        my $t = defined $cell->{text} ? $cell->{text} : '';
        $t =~ s/\e\[[0-9;]*m//g;
        $t =~ s/\s+\z//;
        push @out, $t;
    }
    return join("\n", @out) . "\n";
}

my $RAW = 0;
sub raw_on  { return unless $HAVE_READKEY; eval { Term::ReadKey::ReadMode(3) }; $RAW = 1 }
sub raw_off { return unless $RAW; eval { Term::ReadKey::ReadMode(0) }; $RAW = 0 }

sub read_key {
    return undef unless $HAVE_READKEY;
    my $k = eval { Term::ReadKey::ReadKey(-1) };
    return defined $k ? $k : undef;
}

# Restore the terminal on EVERY exit path. A preview that leaves the screen in
# the alternate buffer with the cursor hidden and echo off is worse than no
# preview -- the shell is still there but looks dead.
my $RESTORED = 0;
my $ENTERED_ALT = 0;
sub restore {
    return if $RESTORED;
    $RESTORED = 1;
    raw_off();
    # Only undo what was actually done. --dump never enters the alternate screen
    # or hides the cursor, and emitting the restore sequences anyway put escape
    # bytes into piped output -- which is exactly the output somebody would be
    # diffing two geometries with.
    print "\e[?25h\e[?1049l" if $ENTERED_ALT;
}
$SIG{INT} = $SIG{TERM} = sub { restore(); exit 0 };
END { restore() }

# ---------------------------------------------------------------------------
# `unless caller` so the file can be require'd for its subs (a test, or a
# one-off render) without launching the interactive loop.
main() unless caller;

sub main {
    my $report_mode = 0;

    # --dump WxH[,WxH...] -- render each geometry as plain text and exit. No
    # alternate screen, no raw mode, no terminal required.
    my @dump;
    my $dump_phase = 0;
    my $dump_runs;
    my $dump_status = 0;
    my @argv = @ARGV;
    while (@argv) {
        my $a = shift @argv;
        if    ($a eq '--dump')    { push @dump, split(/,/, (shift(@argv) // '')) }
        elsif ($a eq '--phase')   { $dump_phase = int(shift(@argv) // 0) }
        elsif ($a eq '--runs')    { $dump_runs  = int(shift(@argv) // 0) }
        elsif ($a eq '--report')  { $report_mode = 1 }
        elsif ($a eq '--status')  { $dump_status = int(shift(@argv) // 0) }
    }
    if (@dump) {
        for my $g (@dump) {
            my ($c, $r) = $g =~ /^(\d+)x(\d+)$/ or next;
            my $st = synth_state($dump_phase, $dump_runs, $dump_status);
            print "=" x $c, "\n" if @dump > 1;
            # --report gives the same text [c] captures; plain --dump gives just
            # the frame, so two geometries can be diffed without the numbers
            # changing on every line.
            print $report_mode ? capture_report($st, $r, $c, $dump_phase, \%DISMISSED)
                               : render_plain($st, $r, $c, 0, $dump_phase);
        }
        return;
    }

    my ($cols, $rows) = term_size();

    raw_on();
    $ENTERED_ALT = 1;
    print "\e[?1049h\e[?25l\e[2J\e[H";

    my $prev;
    my ($last_c, $last_r) = (0, 0);
    my $phase   = 0;
    my $last_title;
    my $running = 1;                 # animating, vs frozen on one phase
    my $runs_override;               # set by +/-, cleared by [a]
    my $tick    = 0;
    my $capture = 0;
    my $status_idx = 0;
    # A TRANSIENT confirmation, not a permanent bar. It occupies the footer for
    # about a second so [c] is not silent, then gives the row back.
    my ($toast, $toast_until) = ('', 0);

    while (1) {
        my $k = read_key();
        if (defined $k) {
            last if $k eq 'q' || $k eq "\003";
            if    ($k eq 'c')  { $capture = 1 }
            elsif ($k eq ' ')  { $running = !$running }
            elsif ($k eq '.')  { $phase++; $running = 0 }       # single-step
            elsif ($k eq ',')  { $phase-- if $phase > 0; $running = 0 }
            elsif ($k eq 'a')  { $runs_override = undef }
            # [s] walks the status list, [S] hands it back to the animation.
            elsif ($k eq 's')  { $status_idx = ($status_idx + 1) % scalar(@STATUS_CYCLE);
                                     $toast = ' status: ' . $STATUS_CYCLE[$status_idx]{label} . ' ';
                                     $toast_until = $tick + 16; $prev = undef }
            elsif ($k eq 'S')  { $status_idx = 0;
                                     $toast = ' status: auto (phase-driven) ';
                                     $toast_until = $tick + 16; $prev = undef }       # back to automatic
            elsif ($k eq '0')  { $phase = 0 }
            elsif ($k eq '+' || $k eq '=') { $runs_override = ($runs_override // 0) + 1 }
            elsif ($k eq '-' || $k eq '_') { $runs_override = ($runs_override // 1) - 1;
                                             $runs_override = 0 if $runs_override < 0 }
        }

        # ONE PHASE PER ~0.6s, not per frame. Fast enough to watch the layout
        # move, slow enough to read what moved -- a change you cannot see happen
        # is indistinguishable from a rendering glitch.
        $tick++;
        $phase++ if $running && $tick % 8 == 0;

        my $state = synth_state($phase, $runs_override, $status_idx);

        # DISMISSAL IS INDEPENDENT AND PER-WARNING, keyed by id. [w] dismisses
        # the TOP of the stack -- the newest -- because that is the one the
        # operator is looking at; pressing it repeatedly walks down the stack.
        #
        # A dismissed id stays dismissed even while its generator keeps
        # producing it, or the warning would reappear on the very next frame and
        # the key would look broken.
        # DISMISSAL GOES THROUGH THE REAL MECHANISM. The preview used to filter
        # its OWN synthetic list, which is precisely how it missed that lifecycle
        # and status alerts were still being rendered as banners over Recent
        # activity: the preview only ever knew about the warnings it invented.
        # It now asks tui::DashboardScreen::warning_entries what is actually on
        # screen, so anything the dashboard can emit is dismissable here.
        $state->{dismissed_warnings} = \%DISMISSED;
        if (defined $k && $k eq 'd') {
            my $live = tui::DashboardScreen::warning_entries($state);
            $DISMISSED{ $live->[-1]{id} } = 1 if @$live;
            $prev = undef;
        }
        # [D] RESTORES, AND SAYS SO. It was silent, and silence is
        # indistinguishable from broken -- especially because a restored warning
        # only REAPPEARS if its condition still holds. The synthetic producers
        # come and go on their own periods, so dismissing one and pressing [D]
        # after its window has closed correctly shows nothing, which looks
        # exactly like the key not working. The toast distinguishes the two.
        if (defined $k && $k eq 'D') {
            my $n = scalar keys %DISMISSED;
            %DISMISSED = ();
            $state->{dismissed_warnings} = \%DISMISSED;
            my $back = scalar @{ tui::DashboardScreen::warning_entries($state) };
            $toast = $n ? sprintf(' un-dismissed %d; %d now showing%s ', $n, $back,
                                  ($back ? '' : ' (their conditions no longer hold)'))
                        : ' nothing was dismissed ';
            $toast_until = $tick + 16;
            $prev = undef;
        }

        ($cols, $rows) = term_size();
        if ($cols != $last_c || $rows != $last_r) {
            # A resize invalidates the diff: our model and the glass disagree
            # and only the glass knows it. Drop prev so the next paint is full.
            $prev = undef;
            ($last_c, $last_r) = ($cols, $rows);
        }

        my $frame = Dashboard::compose_frame($state, $rows, $cols);

        # [c] CAPTURES instead of a permanent diagnostics bar. The report goes to
        # a file always, and to the clipboard when a clipboard tool exists --
        # the file is the reliable half, the clipboard the convenient one.
        if ($capture) {
            $capture = 0;
            my $report = capture_report($state, $rows, $cols, $phase, \%DISMISSED);

            # TIMESTAMPED FILE, AND THE CLIPBOARD GETS THE PATH -- not the text.
            #
            # Operator, 2026-08-28: "I'd rather have it saved to a timestamped
            # file and then copied to clipboard the file name so I can paste it
            # here to reference it." Two consequences worth stating: captures
            # accumulate instead of overwriting, so a before/after pair
            # survives, and pasting a path costs one line instead of a whole
            # screenful.
            #
            # time() is used HERE and nowhere else in this file: the content
            # must stay a pure function of $phase (so --phase N reproduces it),
            # but a filename that collides on every capture would defeat the
            # point of keeping them.
            my @t = localtime(time);
            my $stamp = sprintf('%04d%02d%02d-%02d%02d%02d',
                $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
            my $dir  = "$Bin/../.ccpraxis-local-data/tui-captures";
            mkdir "$Bin/../.ccpraxis-local-data" unless -d "$Bin/../.ccpraxis-local-data";
            mkdir $dir unless -d $dir;
            my $path = -d $dir ? "$dir/$stamp.txt" : "tui-capture-$stamp.txt";

            # NORMALISE BEFORE IT REACHES THE CLIPBOARD. $Bin is the scripts/
            # directory, so the joined path came out as
            # ".../scripts/../.ccpraxis-local-data/tui-captures/..." -- valid,
            # but it is going to be PASTED somewhere, and a path with a /../ in
            # the middle reads as garbled. Cwd::abs_path resolves it against the
            # real filesystem; if that fails the unresolved path is still
            # correct, so the fallback loses nothing.
            require Cwd;
            my $pretty = eval { Cwd::abs_path($dir) };
            $pretty = (defined $pretty && length $pretty) ? "$pretty/$stamp.txt" : $path;

            my $wrote = 0;
            if (open my $fh, '>', $path) { print $fh $report; close $fh; $wrote = 1 }

            # The path is reported as given to open(), which is what actually
            # worked -- resolving it to something prettier risks printing a path
            # that was never written to.
            my $clipped = $wrote ? to_clipboard($pretty) : 0;
            $toast = $wrote ? " captured -> $pretty" . ($clipped ? '  (path copied)' : '  (no clipboard tool)')
                            : ' CAPTURE FAILED: could not write the file ';
            $toast_until = $tick + 16;
            $prev = undef;
        }
        if ($toast && $tick < $toast_until && @$frame) {
            my $t = substr($toast, 0, $cols);
            $frame->[-1] = { text => $t, role => 'footer-flash' };
        }
        elsif ($toast && $tick >= $toast_until) { $toast = ''; $prev = undef }

        # THE SIZE READOUT -- PREVIEW ONLY, and that restriction is the point.
        #
        # Operator, 2026-08-28: a persistent bottom-right overlay showing the
        # terminal's current width and height, "but only for the debug mode
        # script". It lives here rather than in tui::Screen precisely so it
        # cannot reach the shipping dashboard: this file is not loaded by the
        # launcher, so there is no flag to leave switched on by accident.
        #
        # It overlays the LAST row's right-hand end. That row is the footer,
        # whose hotkey text is left-aligned and short, so the columns being
        # painted over are empty in practice -- and unlike a dedicated row it
        # cannot change the geometry it exists to report.
        if (@$frame) {
            my $label = sprintf(' %dx%d ', $cols, $rows);
            my $lw    = length $label;
            if ($cols > $lw) {
                my $base = $frame->[-1]{text};
                $base = '' unless defined $base;
                $base =~ s/\e\[[0-9;]*m//g;
                $base = substr($base, 0, $cols - $lw);
                $base .= ' ' x (($cols - $lw) - length $base) if length($base) < $cols - $lw;
                $frame->[-1] = {
                    text  => $base . $label,
                    role  => 'footer',
                    spans => [ { text => $base,  role => 'footer' },
                               { text => $label, role => 'overlay.warn' } ],
                };
            }
        }

        my $out = Dashboard::render_frame($prev, $frame, { color => 1 });
        print $out if length $out;
        $prev = $frame;

        # THE WINDOW TITLE IS PART OF WHAT VARIES, and it was not being
        # exercised (operator, 2026-08-27: "the simulated TUI doesn't exercise
        # the terminal window namings"). It is also the one output that survives
        # into a taskbar button, so its rules -- the lead character animating
        # only while running, and `!` FOLLOWING the spinner rather than
        # replacing it -- are only checkable by watching a real title bar.
        #
        # Emitted through Dashboard::window_title, the same function the
        # launcher uses, so this previews the shipping behaviour and not a
        # reimplementation of it.
        my $title = Dashboard::window_title($state);
        if (defined $title && length $title && (!defined $last_title || $title ne $last_title)) {
            print "\e]0;$title\a";
            $last_title = $title;
        }

        select(undef, undef, undef, 0.08);
    }

    restore();
    print "preview closed\n";
}
