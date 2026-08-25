#!/usr/bin/env perl
# B2 dashboard framework: Dashboard.pm — the raw-ANSI TUI for `claude-sandbox`.
#
# PART 1  pure helpers: decide_mode, fmt_age, clip_pad, find_exe.
# PART 2  frame composition: exact dimensions, tiny-terminal degradation,
#         content placement, the shutdown-confirm footer.
# PART 3  render diff: full-redraw-once vs per-row diff, synchronized-output
#         wrappers, only-changed rows touched (the B0 flicker fix).
# PART 4  key dispatch incl. the two-step shutdown confirm.
# PART 5  spawn: mode ladder (wt -> start -> inline) + argv construction.
# PART 6  events: B1 launch-log tail parsing + last-N + skip-garbage.
# PART 7  signal paths: blueprint runs/.shutdown derivation + write.
# PART 8  the loop (run) driven by a fake clock + scripted keys with every side
#         effect injected: heartbeat timing, [c] spawn, [s][y] shutdown, [q] quit.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";

# RETARGETED to the LIVE panel builder. Dashboard::_fixed_panels was deleted --
# unreachable since compose_frame began delegating to tui::DashboardScreen, and
# drifted to a panel set (Token/Spend) that no longer renders. The assertions
# below are about Run-panel CONTENT, which the live builder still produces, so
# they are re-pointed rather than dropped.
#
# A shim rather than an inline rewrite at each call site: panels() returns an
# ARRAYREF where _fixed_panels returned a LIST, and $cols was optional there
# (defaulting to 80). One place to state both facts beats twenty.
sub live_panels {
    my ($state, $cols) = @_;
    return @{ tui::DashboardScreen::panels($state, defined $cols ? $cols : 80) };
}
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::Local qw(timegm);

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# ===========================================================================
# BREAKPOINT MIGRATED 100 -> 90 (package 06-dashboard-screen, in-scope oracle
# correction #4; Decision 14 is an operator decision dated 2026-08-06 and
# WINS over the prior 100; driver ruling packages/06-dashboard-screen.md
# 2026-08-07T17:56:38Z / 2026-08-07T20:40:59Z, spec §7 E-D). $BP is declared
# ONCE (spec AC-B4) and reused by every migrated assertion below so the
# breakpoint itself is never re-typed as a bare literal here. Claims at
# :149/:153/:765 are preserved verbatim; only the column SUBJECT moves.
# ===========================================================================
require tui::Layout;
my $BP = tui::Layout::BREAKPOINT_TWO_COL();

# ===========================================================================
# ROLE VOCABULARY + RULE-FILL GLYPH RE-POINTED (package 06 in-scope oracle
# correction, driver ruling 2026-08-08, Family 2): compose_frame now
# composes through tui::DashboardScreen, which emits ONLY Theme role names
# on every cell/span it produces (spec S2.1), and title/panel rules are now
# filled with Theme's declared 'rule.h' glyph instead of a literal ASCII
# '-' repeat (spec S2.1: "every glyph tui::DashboardScreen emits comes from
# Theme::glyph(...)"). Every legacy bare-role assertion below ('title',
# 'footer', 'alert', 'footer-alert', 'footer-flash') is asserted against
# these DERIVED role names -- never hand-typed -- so they cannot drift from
# the authoritative legacy->Theme mapping table (spec S2.1). The claim each
# assertion makes ("row 0 is the title", "an alert row carries the alert
# role", ...) is unchanged; only the role-name vocabulary is.
# ===========================================================================
require Theme;
require tui::DashboardScreen;
my $TITLE_ROLE        = tui::DashboardScreen::theme_role('title');
my $FOOTER_ROLE       = tui::DashboardScreen::theme_role('footer');
my $ALERT_ROLE        = tui::DashboardScreen::theme_role('alert');
my $FOOTER_ALERT_ROLE = tui::DashboardScreen::theme_role('footer-alert');
my $FOOTER_FLASH_ROLE = tui::DashboardScreen::theme_role('footer-flash');
my $RULE_FILL_RE      = quotemeta(Theme::glyph('rule.h'));

# ===========================================================================
# count_banner_starts(\@alert_rows) -- fix-batch step 7 (d02-wrap-every-
# surface, reviewer MUST-FIX #1, red-team follow-up).
#
# The step-6 amended assertions counted "banner-start rows" (a width-
# invariant proxy for "how many banners are present", since a wrapped
# banner now spans more than one row -- Decision D1) with an UNANCHORED
# `grep { $_->{text} =~ /!! / }`. That matches the literal substring "!! "
# anywhere in a row's text, including a CONTINUATION row whose wrapped
# content happens to contain "!! " (e.g. install_warning text containing
# "urgent!!"), silently inflating the count. The reviewer reproduced a
# 2-banner fixture miscounted as 3; the red-team follow-up went further and
# reproduced a 1-REAL-banner fixture miscounted as 2 -- the sharper failure,
# because it is "a banner is genuinely missing but the assertion still
# passes" territory (driver-verified against Dashboard::compose_frame
# directly, see the two pinned assertions below this helper's call sites).
#
# DO NOT "fix" this by anchoring the regex to `^!! ` instead (`/^!! /`).
# That was the reviewer's own suggested minimal fix and the driver proved it
# WRONG: a WRAPPED banner's first row loses its leading "  " indent (the
# spec's documented cosmetic side-effect of rebuilding via make_cell/
# fit_spans, not a spans array) so its text starts "!! ...", but an
# UNWRAPPED (single-row) banner KEEPS the "  !! " indent Dashboard::
# _banner_lines bakes in, so its text starts "  !! ...". `^!! ` matches the
# first shape and MISSES the second, undercounting two real banners (one
# wrapped, one not) down to one. Driver-verified against
# tui::DashboardScreen::compose directly.
#
# STRUCTURAL discriminator (primary, authoritative): every cell wrap_line/
# make_cell emits carries a `spans` arrayref (Frame.pm's single cell
# constructor). A banner-START row's FIRST span carries the banner's own
# role (Screen.pm's $banner_role, e.g. 'state.crit'/'state.warn'); a
# CONTINUATION row's FIRST span carries the continuation-indent role
# CONTINUATION_ROLE below ('text.primary' -- the plain 2-space indent
# wrap_line prepends to every line after the first, Screen.pm
# WRAP_CONTINUATION_INDENT). This distinguishes start-vs-continuation by
# STRUCTURE, not by scanning rendered text for a marker that a banner's own
# (dynamic, tool-surfaced) content could coincidentally contain anywhere.
#
# TEXT discriminator (secondary, belt-and-braces): `/^\s*!! /` matches BOTH
# accepted first-row shapes above (wrapped "!! ..." and unwrapped
# "  !! ...") and rejects the reviewer's `urgent!!`-mid-line repro (no
# leading "!! " on that row). Used only to CORROBORATE the structural count
# where the marker can physically appear intact in a row -- see the
# $cols < 3 note below for where it cannot, by construction.
#
# WIDTH FLOOR, RULED (red-team follow-up, ledger criterion 4 -- width 1-3
# behavior must be DEFINED, not accidental): driver-verified directly
# against Dashboard::compose_frame that at $cols in (1, 2), wrap_line's
# forced-progress/degenerate-budget path (triggered when the continuation
# + leading indent reservation no longer leaves >=1 content column) drops
# the leading-indent span ENTIRELY -- every row, start AND continuation
# alike, ends up with the banner role as its ONLY/first span. At those two
# widths the structural discriminator cannot distinguish start from
# continuation at all (it counts every row), and the text discriminator
# also cannot corroborate anything (the 3-character "!! " marker cannot fit
# intact in a 1- or 2-column row, torn or not). "How many banners are
# present" is therefore NOT RECOVERABLE from the rendered frame at
# $cols < 3 -- not a test-discriminator gap, an inherent floor of a 1-2
# column banner row. Assertions in this file do not claim a banner-start
# COUNT at $cols < 3; see the width 1/2/3 pinned block below PART (E) for
# what IS asserted there instead (frame validity, no crash).
#
# At $cols == 3 EXACTLY the two discriminators diverge (driver-verified):
# structural is still correct (a 200-row-budget, 2-banner probe at cols=3
# returns struct_starts==2, matching ground truth) because Screen.pm still
# manages to keep line 0's span distinct from continuation lines' spans
# even though the "!! " marker text itself is torn across rows 0/1 (only
# one "!" fits per row before the pad). The text discriminator cannot
# corroborate there (the intact marker literally cannot fit in 3 columns
# either -- "!! " is exactly 3 columns wide with zero room for content).
# Per the ruling above: structural is authoritative; the width 1/2/3 pinned
# block below asserts cols==3 gets a real count (via structural alone) and
# cols==1/2 do not.
my $CONTINUATION_ROLE = 'text.primary';   # Screen.pm's wrap-continuation indent role
sub count_banner_starts {
    my ($rows) = @_;
    $rows = [] if ref($rows) ne 'ARRAY';
    my $count = 0;
    for my $row (@$rows) {
        next if ref($row) ne 'HASH';
        my $spans = (ref($row->{spans}) eq 'ARRAY') ? $row->{spans} : undef;
        # A row with no spans array (or an empty one) cannot be identified
        # as a continuation -- there is no indent span to find -- so it
        # counts as a start. Documented, not silently swallowed: every cell
        # this codebase actually emits carries spans (make_cell/wrap_line),
        # so this branch is a defensive default, not an expected path.
        my $first_role = ($spans && @$spans) ? $spans->[0]{role} : undef;
        $count++ if !defined($first_role) || $first_role ne $CONTINUATION_ROLE;
    }
    return $count;
}

# ===========================================================================
# activity_capacity DERIVATION HELPER (package 06, spec S5 ":756-774", Family
# 3), shared by PART 9 and PART 11/C1a-C1b below. Claim preserved verbatim --
# "capacity mirrors compose_frame's budget" -- but every literal number that
# used to sit next to a call site assumed the (now-deleted) Sandbox panel's
# fixed-region height AND the old 100-column breakpoint; BOTH moved the
# fixed region's size, so no literal survives unmigrated. Per spec S5's own
# worked formula:
#   capacity == max(0, rows - 2(title+footer) - _fixed_region_height(state,cols) - 1)
# A live status alert is asserted as a DIFFERENTIAL against the non-alert
# derivation at each call site (preserving this file's own comment, "a
# status alert costs one more row", as a relative claim) rather than folded
# into this formula as a guessed absolute term.
# ===========================================================================
sub _cap_expect {
    my ($state, $r, $c) = @_;
    my $body = $r - 2;
    my $raw  = $body - Dashboard::_fixed_region_height($state, $c) - 1;
    # Flex floor -- see tui::Screen::flex_reserve. The Activity panel is the
    # flex band, so it is guaranteed rows the fixed region cannot take; read
    # the reservation rather than restating it, so this oracle cannot drift
    # away from the renderer it claims to mirror.
    my $floor = tui::Screen::flex_reserve($body) - 1;   # -1 = the panel title
    $raw = $floor if $raw < $floor;
    return $raw > 0 ? $raw : 0;
}

# ===========================================================================
# PART 1 — pure helpers
# ===========================================================================
is(Dashboard::decide_mode(1, 1, 0), 'tui',   'mode: tty + readkey + not-forced -> tui');
is(Dashboard::decide_mode(0, 1, 0), 'plain', 'mode: no tty -> plain');
is(Dashboard::decide_mode(1, 0, 0), 'plain', 'mode: no Term::ReadKey -> plain');
is(Dashboard::decide_mode(1, 1, 1), 'plain', 'mode: force_plain -> plain');

is(Dashboard::fmt_age(0),       '0s',     'age: 0s');
is(Dashboard::fmt_age(59),      '59s',    'age: 59s');
is(Dashboard::fmt_age(60),      '1m',     'age: 60s -> 1m');
is(Dashboard::fmt_age(3599),    '59m',    'age: 59m');
is(Dashboard::fmt_age(3600),    '1h00m',  'age: 1h00m');
is(Dashboard::fmt_age(3660),    '1h01m',  'age: 1h01m');
is(Dashboard::fmt_age(90000),   '1d01h',  'age: 1d01h');
is(Dashboard::fmt_age(undef),   'n/a',    'age: undef -> n/a (ASCII, width-safe)');
is(Dashboard::fmt_age(-5),      'n/a',    'age: negative -> n/a');

# fmt_hms's six assertions removed 2026-08-25. It formatted an uptime as an
# explicit "Xh Ym Zs" with all three components always shown, was deleted as
# unreachable, and has NO successor: the spec that superseded it (AC-F5/S2.4.7)
# says fmt_hms is off every render path, and the live surfaces use fmt_age or
# fmt_duration, whose own assertions sit immediately above and below this note.
# Not re-pointed at fmt_duration, which is a different format ('13s', not
# '0h 0m 13s') -- re-pointing would have meant rewriting the expectations to
# match, which is authoring new coverage rather than preserving old.

is(length(tui::Frame::clip_pad('hi', 5)), 5,  'clip_pad: pads up to width');
is(tui::Frame::clip_pad('hi', 5),  'hi   ',   'clip_pad: right-pads with spaces');
is(tui::Frame::clip_pad('hello world', 5), 'hello', 'clip_pad: truncates to width');
is(tui::Frame::clip_pad('x', 0),   '',        'clip_pad: width 0 -> empty');
is(tui::Frame::clip_pad(undef, 3), '   ',     'clip_pad: undef -> spaces');

{
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/wt.exe" or die; print $fh "x"; close $fh;
    my $path = "/nope${\ ';'}$dir${\ ';'}/also-nope";
    is(Dashboard::find_exe('wt.exe', $path, ';'), "$dir/wt.exe",
        'find_exe: locates the file on a ;-separated PATH');
    is(Dashboard::find_exe('absent.exe', $path, ';'), undef,
        'find_exe: undef when not found');
    is(Dashboard::find_exe('wt.exe', undef, ';'), undef,
        'find_exe: undef PATH -> undef');
}

# find_exe default separator: ONLY native MSWin32 perl uses ';'. The Git-for-
# Windows perl that runs the launcher is $^O 'cygwin'/'msys' with a colon-PATH, so
# the default must be ':' there. Regression: the old `cygwin|msys -> ;` split a
# colon-PATH into one element -> wt.exe never found -> launch-claude silently
# opened a bare PowerShell console instead of a Windows Terminal window.
SKIP: {
    skip 'native MSWin32 perl uses a ;-separated PATH', 1 if $^O eq 'MSWin32';
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/wt.exe" or die; print $fh 'x'; close $fh;
    is(Dashboard::find_exe('wt.exe', "/nope:$dir:/also-nope"), "$dir/wt.exe",
        'find_exe: default sep is : on cygwin/msys/unix (not ;)');
}

# find_wt: PATH hit wins; else the %LOCALAPPDATA%\Microsoft\WindowsApps fallback;
# else undef. This is the "Windows Terminal is required" assertion the launcher
# uses before launch-claude (it fails loudly when this returns undef).
{
    my $pdir = tempdir(CLEANUP => 1);
    open my $f1, '>', "$pdir/wt.exe" or die; print $f1 'x'; close $f1;
    is(Dashboard::find_wt($pdir, undef), "$pdir/wt.exe", 'find_wt: located on PATH');

    my $la = tempdir(CLEANUP => 1);
    my $wa = File::Spec->catdir($la, 'Microsoft', 'WindowsApps');
    make_path($wa);
    open my $f2, '>', "$wa/wt.exe" or die; print $f2 'x'; close $f2;
    is(Dashboard::find_wt('/nope:/also-nope', $la),
        File::Spec->catfile($wa, 'wt.exe'),
        'find_wt: falls back to %LOCALAPPDATA%\\Microsoft\\WindowsApps');

    is(Dashboard::find_wt('/nope:/also-nope', undef), undef,
        'find_wt: undef when WT is installed nowhere (-> launcher fails loudly)');
}

# ===========================================================================
# PART 2 — frame composition
# ===========================================================================
my %st = (
    project_name => 'demo',
    container    => 'claude-demo-abcd1234',
    status       => 'running',
    beat_age     => 12,
    uptime       => 3660,
    events       => ['10:00:01  launch_start', '10:00:05  container_start exit=0'],
);

{
    my $f = Dashboard::compose_frame(\%st, 24, 80);
    is(scalar(@$f), 24, 'compose: exactly $rows rows');
    is(Dashboard::display_width($f->[0]{text}), 80, 'compose: every row exactly $cols wide (row 0)');
    my $bad = grep { Dashboard::display_width($_->{text}) != 80 } @$f;
    is($bad, 0, 'compose: ALL rows exactly $cols wide');
    is($f->[0]{role}, $TITLE_ROLE, "compose: row 0 is the title (role: $TITLE_ROLE, Theme-derived, spec S2.1)");
    like($f->[0]{text}, qr/ccpraxis sandbox/, 'compose: title text present');
    # Status block leads (operator request, 2026-08-25 -- the two used to be
    # adjacent at the right-hand end), and the container id is the last clause
    # of ONE left-aligned phrase rather than right-justified across a gap
    # (second operator request, same day). RE-POINTED, not deleted: the claim
    # about WHERE the container id sits is still made, it is just a different
    # place.
    like($f->[0]{text}, qr/\A\[running\] ccpraxis sandbox - demo - \Qclaude-demo-abcd1234\E/,
        'compose: status leads the row, then project and container joined by " - "');
    unlike($f->[0]{text}, qr/\Qdemo\E {2,}\Qclaude-demo-abcd1234\E/,
        'compose: no justification gap between the project name and the container id');
    is($f->[-1]{role}, $FOOTER_ROLE, "compose: last row is the footer (role: $FOOTER_ROLE, Theme-derived, spec S2.1)");
    like($f->[-1]{text}, qr/\[q\] quit/, 'compose: footer legend present');
    my $joined = join "\n", map { $_->{text} } @$f;
    # RE-POINTED (spec S5 ":126"): the Sandbox panel is deleted (spec
    # S2.4.3); claim "a panel title renders" moves subject to "-- Run ".
    like($joined, qr/$RULE_FILL_RE Run /,        'compose: Run panel title rendered (subject moved from the deleted Sandbox panel)');
    # RE-POINTED (spec S5 ":127"): the Sandbox panel's own "container : ..."
    # body row is gone -- the container fact now lives ONLY in the header,
    # already asserted two lines above. This becomes Criterion 2/AC-D1's
    # exactly-once count instead of a second (now-impossible) body-row check.
    my $container_count = () = ($joined =~ /\Qclaude-demo-abcd1234\E/g);
    is($container_count, 1,
        'compose: the container name appears exactly once in the frame (moved from the deleted Sandbox panel body -- Criterion 2/AC-D1)');
    like($joined, qr/$RULE_FILL_RE Recent activity /, 'compose: Activity panel rendered');
    like($joined, qr/\Qlaunch_start\E/,   'compose: B1 event surfaced in Activity');
    # RE-POINTED (spec S5 ":130", S2.4.7/Criterion 4): the one duration
    # format is fmt_duration/fmt_age, never fmt_hms's "Xh Ym Zs" -- re-derive
    # the expected text by CALLING fmt_age(3660), never re-pin "1h 1m 0s" or
    # its replacement "1h01m" as a literal.
    my $expected_uptime = Dashboard::fmt_age(3660);
    # AMENDED BY t05-no-colons: the label gutter's separator is now three
    # spaces rather than " : " (operator: "we use way too many instances of the
    # character `:`. Its distracting. We need none of them."). The intent here
    # is untouched and is stated by the comment above -- it is about the
    # DURATION FORMAT, re-derived by calling fmt_age rather than pinned as a
    # literal. Matching on whitespace instead of a colon keeps that intent and
    # stops the assertion re-pinning a separator it was never about.
    like($joined, qr/uptime\s+\Q$expected_uptime\E/,
        "compose: uptime renders via the one duration format (fmt_age(3660) == $expected_uptime, never fmt_hms)");

    # PART 2 additions (s04-render-foundation, AC-8/INV-1): every cell carries
    # a non-empty spans arrayref whose declared width and concatenated text
    # agree exactly with cell->{text}, and no cell text ever contains an ESC.
    my @bad_spans = grep { !$_->{spans} || ref($_->{spans}) ne 'ARRAY' || !@{ $_->{spans} } } @$f;
    is(scalar(@bad_spans), 0, 'compose (s04): every cell has a non-empty spans arrayref');
    my @bad_width = grep { Dashboard::spans_width($_->{spans}) != 80 } @$f;
    is(scalar(@bad_width), 0, 'compose (s04): spans_width(cell->{spans}) == 80 for every row');
    my @bad_text = grep { $_->{text} ne Dashboard::spans_text($_->{spans}) } @$f;
    is(scalar(@bad_text), 0, 'compose (s04): cell->{text} eq spans_text(cell->{spans}) for every row');
    my @has_esc = grep { $_->{text} =~ /\e/ } @$f;
    is(scalar(@has_esc), 0, 'compose (s04): no cell text contains an ESC byte (INV-4)');
}

# s05-responsive-layout (AC-7 smoke): the two-column mode boundary is visible
# right here in the file that owns frame composition -- full unit coverage of
# the composer lives in t/40-layout-responsive.t. BREAKPOINT MIGRATED (see
# file-header note): claims preserved verbatim; 100/99 -> $BP+10/$BP-1 (spec
# S5 ":149-151/:153-159" -- the "at/above" subject is explicitly $BP+10, not
# bare $BP, in the spec's own migration table for this exact region).
#
# SUBJECT ALSO RE-POINTED (Family 1, driver ruling 2026-08-08): the Sandbox
# panel is deleted (spec S2.4.3), so the pair that can now share the lead
# row is Run and Token, not Sandbox and Run ("Two-column assertions that
# named Sandbox|Run as the pair now name Run and Token"). The fixture gains
# a `tokens` hashref so the Token panel actually renders (spec S2.4.3:
# present when `ref $state->{tokens} eq 'HASH'`) -- otherwise there is no
# second lead panel to pair with. The dash-fill regex is rewritten against
# the DERIVED $RULE_FILL_RE (Theme's rule.h glyph), not a literal '-', per
# the file-header role/glyph note.
#
# RE-POINTED AGAIN (package t01-providers-panel, spec §6): Token is deleted;
# Blueprints is Run's new unconditional pairing partner (Behavior 17). The
# `tokens => {}` fixture augmentation is no longer needed -- Blueprints
# exists regardless of input, so plain %st is enough to trigger the pairing.
{
    my $fat = Dashboard::compose_frame(\%st, 24, $BP + 10);
    my $both = grep { $_->{text} =~ /$RULE_FILL_RE Run / && $_->{text} =~ /$RULE_FILL_RE Blueprints / } @$fat;
    is($both, 1, "compose (s05): 24x@{[ $BP + 10 ]} -- exactly one row carries BOTH panel titles (two-column mode)");

    my $below = $BP - 1;
    my $fbelow = Dashboard::compose_frame(\%st, 24, $below);
    my $both_below = grep { $_->{text} =~ /$RULE_FILL_RE Run / && $_->{text} =~ /$RULE_FILL_RE Blueprints / } @$fbelow;
    is($both_below, 0, "compose (s05): 24x$below -- no row carries both panel titles (still stacked)");
    my ($run_below) = grep { $_->{text} =~ /^$RULE_FILL_RE Run (?:$RULE_FILL_RE)+$/ } @$fbelow;
    ok($run_below, "compose (s05): 24x$below -- a row matches /^-- Run <rule.h fill>\$/ (dash-filled full width)");
    is(Dashboard::display_width($run_below->{text}), $below, "compose (s05): that row is exactly $below display columns")
        if $run_below;
}

# tiny-terminal degradation
{
    my $f1 = Dashboard::compose_frame(\%st, 1, 40);
    is(scalar(@$f1), 1, 'compose: 1 row -> title only');
    is($f1->[0]{role}, $TITLE_ROLE, "compose: 1-row frame is the title (role: $TITLE_ROLE)");

    my $f2 = Dashboard::compose_frame(\%st, 2, 40);
    is(scalar(@$f2), 2, 'compose: 2 rows -> title + footer');
    is($f2->[1]{role}, $FOOTER_ROLE, "compose: 2-row frame ends in footer (role: $FOOTER_ROLE)");

    my $f0 = Dashboard::compose_frame(\%st, 0, 40);
    is(scalar(@$f0), 0, 'compose: 0 rows -> empty');

    my $ftiny = Dashboard::compose_frame(\%st, 3, 1);
    is(Dashboard::display_width($ftiny->[0]{text}), 1, 'compose: width 1 -> 1-column rows (no crash)');
}

# stop-runs confirm footer (s11-lifecycle-stop: 'shutdown' pending is retired;
# 'stop-runs' is the new two-step confirm token -- see spec 08 S2.1/S2.2).
{
    my %sc = (%st, pending => 'stop-runs');
    my $f = Dashboard::compose_frame(\%sc, 10, 80);
    is($f->[-1]{role}, $FOOTER_ALERT_ROLE, "compose: pending stop-runs -> footer-alert role (role: $FOOTER_ALERT_ROLE)");
    like($f->[-1]{text}, qr/butler runs/i, 'compose: confirm prompt shown in footer (new stop-runs contract)');
    like($f->[-1]{text}, qr/\[y\] confirm/, 'compose: confirm prompt names [y] confirm');
}

# install-failure alert banner (#20): a backpack-install failure must surface in
# the dashboard (the pre-dashboard stdout warning is wiped by the alt-screen).
{
    my %sw = (%st, install_warning => 'backpack install FAILED - run /backpack:install');
    my $f = Dashboard::compose_frame(\%sw, 10, 80);
    my @alert = grep { $_->{role} eq $ALERT_ROLE } @$f;
    is(scalar(@alert), 1, "compose: install_warning -> exactly one alert row (role: $ALERT_ROLE)");
    is($f->[1]{role}, $ALERT_ROLE, "compose: alert sits directly under the title (role: $ALERT_ROLE)");
    like($f->[1]{text}, qr/backpack install FAILED/, 'compose: alert shows the warning text');
    is(scalar(@$f), 10, 'compose: alert keeps the frame exactly $rows');
    my $bad = grep { Dashboard::display_width($_->{text}) != 80 } @$f;
    is($bad, 0, 'compose: alert row keeps every row exactly $cols');
    is($f->[-1]{role}, $FOOTER_ROLE, "compose: footer still last with an alert present (role: $FOOTER_ROLE)");

    my $f2 = Dashboard::compose_frame(\%st, 10, 80);   # %st has no warning
    is(scalar(grep { $_->{role} eq $ALERT_ROLE } @$f2), 0, 'compose: no warning -> no alert row');

    my $f3 = Dashboard::compose_frame(\%sw, 3, 80);
    is(scalar(grep { $_->{role} eq $ALERT_ROLE } @$f3), 0, 'compose: rows<4 suppresses the alert (no crash)');

    like(Dashboard::sgr_for_role('alert'), qr/\e\[1;37;41m/, 'sgr: alert role -> bold white on red');
}

# (E) container-status alert banner: a non-running / unreachable / gone container
# surfaces a loud, actionable banner (the loop no longer exits on death).
{
    is(Dashboard::_status_alert({ status => 'running' }), undef,
       'status_alert: running -> no alert');
    is(Dashboard::_status_alert({ status => '' }), undef,
       'status_alert: empty/unknown-yet -> no alert');
    like(Dashboard::_status_alert({ status => 'exited' }), qr/not running/,
       'status_alert: exited -> "not running"');
    like(Dashboard::_status_alert({ status => 'unknown' }), qr/unreachable/,
       'status_alert: unknown -> "unreachable"');
    like(Dashboard::_status_alert({ container_gone => 1, status => 'exited' }), qr/not running/,
       'status_alert: container_gone+exited -> "not running"');
    like(Dashboard::_status_alert({ container_gone => 1, status => 'unknown' }), qr/unreachable/,
       'status_alert: container_gone+unknown -> "unreachable"');

    # A dead container must NOT advertise [c] as a relaunch: [c] only spawns a
    # connector (`podman exec` into a LIVE container), so on a dead container it
    # opens a window that instantly closes. The banner points at the real
    # relaunch path instead (quit, then re-run claude-sandbox).
    for my $dead ({ status => 'exited' },
                  { container_gone => 1, status => 'exited' },
                  { container_gone => 1, status => 'unknown' }) {
        my $msg = Dashboard::_status_alert($dead);
        unlike($msg, qr/\[c\]/, "status_alert: dead container does not offer [c] ($msg)");
        unlike($msg, qr/relaunch.*\[c\]|\[c\].*relaunch/i,
               'status_alert: [c] is never called the relaunch key');
    }
    like(Dashboard::_status_alert({ status => 'exited' }), qr/re-run claude-sandbox/,
       'status_alert: exited banner names the real relaunch path (re-run claude-sandbox)');

    my %dead = (%st, status => 'exited');
    my $f = Dashboard::compose_frame(\%dead, 12, 80);
    my @a = grep { $_->{role} eq $ALERT_ROLE } @$f;
    # AMENDED by package d02-wrap-every-surface, Decision D1
    # (specs/d02-wrap-every-surface-spec.md, Section 0): banners now wrap
    # instead of truncate, so at cols=80 this status banner ("container is
    # exited ... re-run claude-sandbox") spans 2 rows -- "one row per alert"
    # is no longer a valid proxy for "how many alerts are present". The
    # original intent -- exactly one alert (the status alert) is showing --
    # is preserved by counting banner-START rows instead of raw alert rows.
    # RE-AMENDED, fix-batch step 7 (reviewer MUST-FIX #1): counting rows by
    # an unanchored `/!! /` text match over-counts when a continuation row's
    # own content happens to contain "!! " -- see count_banner_starts's
    # doc comment above for why, and why anchoring to `/^!! /` is ALSO
    # wrong (it under-counts an unwrapped banner instead). Use the
    # structural discriminator.
    my $a_starts = count_banner_starts(\@a);
    is($a_starts, 1, "compose: non-running status -> one alert banner (role: $ALERT_ROLE)");
    like($f->[1]{text}, qr/not running/, 'compose: status alert sits under the title');
    is(scalar(@$f), 12, 'compose: status alert keeps the frame exactly $rows');

    # a status alert AND an install_warning coexist as two banners, body intact
    my %both = (%st, status => 'exited', install_warning => 'backpack install FAILED');
    my $f2 = Dashboard::compose_frame(\%both, 12, 80);
    my @a2 = grep { $_->{role} eq $ALERT_ROLE } @$f2;
    # AMENDED by package d02-wrap-every-surface, Decision D1 -- same reasoning
    # as immediately above: at cols=80 these two banners together occupy 3
    # rows (the status banner wraps to 2, the install banner fits in 1), so
    # raw row count no longer says "two alerts". Count banner-start rows.
    # RE-AMENDED, fix-batch step 7 (reviewer MUST-FIX #1): structural
    # discriminator, not unanchored text match -- see count_banner_starts.
    my $a2_starts = count_banner_starts(\@a2);
    is($a2_starts, 2, 'compose: status + install alerts coexist as two banners');
    is(scalar(@$f2), 12, 'compose: two alerts keep the frame exactly $rows');
    # s06-panel-semantics: the container-status line now carries a status
    # glyph, a multi-byte UTF-8 sequence but exactly 2 DISPLAY columns -- the
    # invariant is display_width == $cols, not byte length() (matches the C3
    # regression test's idiom above; see Decision #12).
    my $bad = grep { Dashboard::display_width($_->{text}) != 80 } @$f2;
    is($bad, 0, 'compose: alert rows keep exactly $cols');
}

# count_banner_starts pin (fix-batch step 7, MUST-FIX #1) -- the exact
# failure the unanchored discriminator missed, and its sharper red-team
# variant. Both must resolve to the TRUE banner count, not the inflated one
# an unanchored `/!! /` scan would report.
{
    # Red-team's stronger repro: ONE real banner (install_warning only,
    # no status alert) whose text pushes the two-character "!!" onto a
    # WRAPPED CONTINUATION row -- the "a banner is genuinely missing but
    # the assertion still passes" failure mode, because an unanchored scan
    # counts that continuation row as a second banner-start even though
    # only one banner exists. Driver-verified: 3 rows at cols=80,
    # unanchored count=2 (wrong), structural count=1 (right).
    my $one_banner_text = 'padding words to push the marker off the first '
        . 'wrapped row into a continuation line padding words to push the '
        . 'marker off the first wrapped row into a continuation line '
        . 'urgent!! check this now please and thanks';
    for my $cols (40, 80) {
        my %one = (%st, install_warning => $one_banner_text);
        my $fo = Dashboard::compose_frame(\%one, 12, $cols);
        my @ao = grep { $_->{role} eq $ALERT_ROLE } @$fo;
        my $unanchored_count = scalar(grep { $_->{text} =~ /!! / } @ao);
        my $struct_count     = count_banner_starts(\@ao);
        is($struct_count, 1,
            "count_banner_starts: one real banner whose continuation row contains 'urgent!!' still counts as ONE (cols=$cols)");
        # Pin the failure mode itself: the unanchored scan really does
        # miscount this exact fixture, so the fix is guarded against
        # regressing back to it silently.
        isnt($unanchored_count, 1,
            "sanity: the unanchored /!! / scan DOES miscount this fixture (cols=$cols, got $unanchored_count) -- confirms the discriminator matters here");
    }

    # Reviewer's original repro: TWO real banners (status alert, wrapped +
    # install_warning containing the same "urgent!!" continuation trap).
    my %two_urgent = (%st, status => 'exited', install_warning => $one_banner_text);
    my $ft = Dashboard::compose_frame(\%two_urgent, 12, 80);
    my @at = grep { $_->{role} eq $ALERT_ROLE } @$ft;
    is(count_banner_starts(\@at), 2,
        'count_banner_starts: two real banners (one with an urgent!! continuation trap) count as TWO, not three');

    # The case that kills the reviewer's own suggested `/^!! /` fix: a
    # WRAPPED banner (loses its leading indent on row 0, text "!! ...")
    # and an UNWRAPPED banner (keeps its leading indent, text "  !! ...")
    # in the SAME frame must both be counted exactly once each.
    my %mixed = (%st, status => 'exited', install_warning => 'backpack install FAILED');
    my $fm = Dashboard::compose_frame(\%mixed, 12, 80);
    my @am = grep { $_->{role} eq $ALERT_ROLE } @$fm;
    is(count_banner_starts(\@am), 2,
        'count_banner_starts: a wrapped banner and an unwrapped banner together still count as TWO (the ^!! -anchor trap)');
}

# Width floor for banner-start counting (red-team follow-up, ledger
# criterion 4: width 1-3 behavior must be DEFINED). See count_banner_starts'
# doc comment for the full derivation. Pinned here so it cannot silently
# regress or get "simplified" back to an unqualified claim.
{
    my %one_short = (%st, install_warning => 'x');
    for my $cols (1, 2) {
        my $fw = Dashboard::compose_frame(\%one_short, 24, $cols);
        is(scalar(@$fw), 24, "banner width floor: frame still exactly \$rows at cols=$cols (no crash)");
        my $badw = grep { Dashboard::display_width($_->{text}) != $cols } @$fw;
        is($badw, 0, "banner width floor: every cell still exactly \$cols wide at cols=$cols");
        my @aw = grep { $_->{role} eq $ALERT_ROLE } @$fw;
        ok(scalar(@aw) >= 1, "banner width floor: at least one alert-role row still present at cols=$cols");
        # Deliberately NOT asserting a banner-start COUNT here: at cols<3
        # wrap_line's degenerate-budget path drops the leading-indent span
        # entirely, so count_banner_starts cannot distinguish a start from
        # a continuation (every row looks like a start) -- a genuine floor
        # of a 1-2 column banner row, not a gap in the discriminator.
    }
    # At cols==3 exactly the structural discriminator IS still correct
    # (driver-verified: a 2-banner, huge-row-budget probe at cols=3 returns
    # struct_starts==2), even though the text marker itself is torn across
    # rows there. A real count IS asserted at this width.
    my %two_short = (%st, status => 'exited', install_warning => 'x');
    my $f3 = Dashboard::compose_frame(\%two_short, 200, 3);
    my @a3 = grep { $_->{role} eq $ALERT_ROLE } @$f3;
    is(count_banner_starts(\@a3), 2,
        'banner width floor: at cols==3 EXACTLY, count_banner_starts is still correct (structural, not textual)');
}

# can_launch: [c] may only attach a connector to a RUNNING container; every
# other state suppresses the spawn (else the spawned terminal's `podman exec`
# fails and the window vanishes — the bug this guards).
{
    ok( Dashboard::can_launch({ status => 'running' }), 'can_launch: running -> yes');
    ok(!Dashboard::can_launch({ status => 'exited' }),  'can_launch: exited -> no');
    ok(!Dashboard::can_launch({ status => 'stopped' }), 'can_launch: stopped -> no');
    ok(!Dashboard::can_launch({ status => 'created' }), 'can_launch: created -> no');
    ok(!Dashboard::can_launch({ status => 'restarting' }), 'can_launch: restarting -> no');
    ok(!Dashboard::can_launch({ status => '' }),        'can_launch: not-yet-known -> no');
    ok(!Dashboard::can_launch({ status => 'running', container_gone => 1 }),
       'can_launch: heartbeat says gone -> no (overrides a stale running status)');

    # When a flash is active the footer shows it (with the footer-flash role),
    # not the command legend; absent a flash the legend returns.
    my %fl = (%st, footer_flash => Dashboard::launch_blocked_msg());
    my $ff = Dashboard::compose_frame(\%fl, 12, 80);
    is($ff->[-1]{role}, $FOOTER_FLASH_ROLE, "compose: active flash -> footer row uses footer-flash role (role: $FOOTER_FLASH_ROLE)");
    like($ff->[-1]{text}, qr/container is down/, 'compose: flash text occupies the footer');
    unlike($ff->[-1]{text}, qr/\[s\] stop/, 'compose: flash replaces the command legend (s11: new [s] stop-runs legend)');
    is(length($ff->[-1]{text}), 80, 'compose: flash footer kept exactly $cols');
    like(Dashboard::sgr_for_role('footer-flash'), qr/\e\[1;33m/, 'sgr: footer-flash -> bold yellow');

    my $nf = Dashboard::compose_frame(\%st, 12, 80);   # %st has no footer_flash
    like($nf->[-1]{text}, qr/\[c\] launch/, 'compose: no flash -> normal command legend');
}

# C3 regression: a non-ASCII project name must NOT break the exactly-$cols
# width invariant. That is the claim, and it is unchanged.
#
# What changed is the mechanism it used to rely on. This block previously also
# asserted that non-ASCII mapped 1:1 to '?', which was true when tui::Frame
# replaced every character outside printable ASCII and the Theme glyph table.
# Commit 17693a6 narrowed that: Latin-1 Supplement and Latin Extended-A/B now
# pass through, because tui::Layout::char_cols() already returned their correct
# width of 1 and substituting a character whose width is known was losing
# information for nothing. This machine's own home directory is accented, so
# every project path here was rendering with a '?' in it.
#
# So the byte-level assertion is RE-POINTED, not dropped: an accented letter is
# now expected to survive, while a character whose width the library genuinely
# cannot claim must still be replaced. Both halves are asserted below, and the
# width invariant is checked for each — which is the claim that actually
# protects the frame.
{
    my %sx = (%st, project_name => "caf\xC3\xA9");   # "café" as UTF-8 bytes
    my $f = Dashboard::compose_frame(\%sx, 10, 40);
    my $bad = grep { Dashboard::display_width($_->{text}) != 40 } @$f;
    is($bad, 0, 'compose: non-ASCII project name keeps EVERY row exactly $cols');
    my $joined = join "\n", map { $_->{text} } @$f;
    like($joined, qr/\xC3\xA9/,
         'compose: an accented Latin letter SURVIVES rather than becoming "?" '
       . '(17693a6 — its column width was always known, so the substitution was pure loss)');

    # Counter-fixture. Without this, the assertion above cannot distinguish
    # "the whitelist was widened correctly" from "the sanitiser stopped working".
    my %sw = (%st, project_name => "zh\xE4\xB8\xAD");   # U+4E2D, width this table cannot claim
    my $fw = Dashboard::compose_frame(\%sw, 10, 40);
    my $badw = grep { Dashboard::display_width($_->{text}) != 40 } @$fw;
    is($badw, 0, 'compose: an unknown-width character still keeps EVERY row exactly $cols');
    my $joinedw = join "\n", map { $_->{text} } @$fw;
    unlike($joinedw, qr/\xE4\xB8\xAD/,
           'compose: a character whose width the library cannot claim IS still '
         . 'sanitized — the widening was bounded, not a removal of the guard');
}

# H3 regression: a control char (newline) smuggled into a B1 log field must not
# inject extra line breaks into a composed row.
{
    my @lines = ('{"ts":"2026-06-24T10:00:09Z","type":"oops","state":"a\nb"}');
    my $events = Dashboard::recent_events(\@lines, 5);
    my %se = (%st, events => $events);
    my $f = Dashboard::compose_frame(\%se, 12, 50);
    my $bad = grep { Dashboard::display_width($_->{text}) != 50 } @$f;
    is($bad, 0, 'compose: event with embedded newline keeps rows exactly $cols');
    my $joined = join "\n", map { $_->{text} } @$f;
    is(scalar(() = $joined =~ /\n/g), scalar(@$f) - 1,
       'compose: smuggled newline stripped (no extra row breaks)');
}

# ===========================================================================
# PART 2b — B3 (run / wakefulness) + B4 (backpack) panels
# ===========================================================================
# s06-panel-semantics: panel body lines are now arrayrefs-of-spans (dim labels,
# colored values), not plain strings -- extract text via Dashboard::spans_text
# before regexing (spec S3 behaviors 1-8; see t/41-panel-semantics.t AC1/AC2/
# AC8 for the exact per-span role assertions this file no longer duplicates).
{
    # Run panel: fresh lease + stay_awake -> active / holding; escalations count.
    my @p = live_panels({ %st, busy_age => 30, stay_awake => 1, needs_you => 2 });
    my ($run) = grep { $_->{title} eq 'Run' } @p;
    ok($run, 'panels: a Run panel is present');
    my $rtext = join "\n", map { Dashboard::spans_text($_) } @{ $run->{lines} };
    like($rtext, qr/busy-lease.*active/,   'run: fresh lease + stay_awake -> active');
    like($rtext, qr/keep-awake.*holding/,  'run: stay_awake -> keep-awake holding');
    like($rtext, qr/needs you.*2 decision/,'run: escalations count surfaced');
}
{
    # Stale lease (stay_awake false) -> idle / released; zero decisions -> none.
    my @p = live_panels({ %st, busy_age => 9999, stay_awake => 0, needs_you => 0 });
    my $rtext = join "\n", map { Dashboard::spans_text($_) } @{ (grep { $_->{title} eq 'Run' } @p)[0]->{lines} };
    like($rtext, qr/busy-lease.*idle/,     'run: stale lease -> idle');
    like($rtext, qr/keep-awake.*released/, 'run: not awake -> released (PC may sleep)');
    unlike($rtext, qr/needs you/,     'run: zero decisions -> the escalations row is OMITTED, not rendered as "none"');
}
{
    # No run at all (no busy_age) -> busy-lease none.
    my @p = live_panels({ %st });
    my $rtext = join "\n", map { Dashboard::spans_text($_) } @{ (grep { $_->{title} eq 'Run' } @p)[0]->{lines} };
    like($rtext, qr/busy-lease.*none/, 'run: absent lease -> none (no active run)');
}
{
    # Backpack panel present only when a backpack structure was gathered.
    my @no = grep { $_->{title} eq 'Backpack' } live_panels({ %st });
    ok(!@no, 'backpack: no panel without a gathered structure');

    # RE-POINTED (package 06-dashboard-screen, spec S2.4.3/S2.4.8, Decision
    # 9, driver report item 2). The Backpack panel is deleted entirely; the
    # backpack fact now reaches the frame as a single summary ROW inside
    # Run (tui::DashboardScreen::backpack_summary_spans, the same helper
    # Dashboard::_fixed_panels's render path uses). The original assertions
    # here found a titled 'Backpack' panel and asserted its joined text
    # contained the literal item keys 'apt:jq'/'apt:chromium' -- exactly
    # what done-criterion 6 now forbids ("Backpack renders as a summary
    # line only; no item listing appears on the dashboard"). The surviving
    # claim ("the backpack fact, with its counts, reaches the frame") moves
    # subject from the deleted panel to the `backpack` row inside Run; the
    # item-key assertions INVERT from "present" to "absent from the whole
    # frame" per done-criterion 6, each with a counter-fixture (the summary
    # row itself, with its non-zero total) so "no item keys" cannot pass
    # merely because backpack rendering vanished entirely.
    my $bp = { total => 3, approved => 2, items => [
        { key => 'apt:jq',              approved => 1 },
        { key => 'apt:chromium',        approved => 0 },
        { key => 'npm-global:prettier', approved => 1 },
    ] };
    my @panels = live_panels({ %st, backpack => $bp });
    my ($run) = grep { $_->{title} eq 'Run' } @panels;
    ok($run, 'backpack (re-pointed): a Run panel is present when a backpack structure is gathered');

    # AMENDED BY t05-no-colons, and the amendment makes this STRONGER rather
    # than weaker. It re-derived the gutter width from LABEL_GUTTER but then
    # hand-wrote " : " -- a half-derived expectation, which is what broke when
    # the separator changed. It now calls the same helper the render path uses,
    # which is exactly the discipline the comments a few lines below preach for
    # the value spans.
    my $bp_label = tui::DashboardScreen::gutter('backpack');
    my ($bprow) = $run ? (grep { $_->[0]{text} eq $bp_label } @{ $run->{lines} }) : ();
    ok($bprow, 'backpack (re-pointed): a backpack summary row exists in Run when gathered (subject moved off the deleted Backpack panel)');

    # Derive the expected value spans by CALLING the same helper the real
    # render path uses (tui::DashboardScreen::backpack_summary_spans),
    # never by hand-typing the summary grammar -- so this cannot drift from
    # the implementation's own summary-text contract.
    my $expected_value_spans = tui::DashboardScreen::backpack_summary_spans($bp);
    is_deeply([ @{ $bprow }[1 .. $#$bprow] ], $expected_value_spans,
        'backpack (re-pointed): the row\'s value spans equal backpack_summary_spans($bp) exactly')
        if $bprow;
    my $expected_summary_text = Dashboard::spans_text($expected_value_spans);
    ok(length($expected_summary_text) > 0,
        'backpack (re-pointed) sanity: backpack_summary_spans($bp) is non-empty for a non-zero total');

    # done-criterion 6, INVERTED: the individual item KEYS must not appear
    # anywhere in the whole rendered panel set, even though the summary
    # (with its non-zero total) does.
    my $frame_text = join("\n", map {
        my $p = $_;
        join("\n", map { ref($_) eq 'ARRAY' ? Dashboard::spans_text($_) : (defined($_) ? "$_" : '') } @{ $p->{lines} });
    } @panels);
    unlike($frame_text, qr/\bapt:jq\b/,       'backpack (inverted, done-criterion 6): the approved item KEY does not appear anywhere on the dashboard');
    unlike($frame_text, qr/\bapt:chromium\b/, 'backpack (inverted, done-criterion 6): the pending item KEY does not appear anywhere on the dashboard');

    # Counter-fixture (required alongside the inversion): with backpack
    # items configured, the summary row STILL appears and STILL reports a
    # non-zero total -- so "no item keys" above cannot pass merely because
    # backpack rendering vanished entirely.
    like($frame_text, qr/\Q$expected_summary_text\E/,
        'backpack (inverted, counter-fixture): the summary row (with its non-zero total) IS present in the frame even though the item keys are not');
}
{
    # End-to-end: compose_frame surfaces the new panels (and stays exactly sized).
    my $bp = { total => 1, approved => 0, items => [{ key => 'apt:jq', approved => 0 }] };
    my $f = Dashboard::compose_frame(
        { %st, busy_age => 5, stay_awake => 1, needs_you => 1, backpack => $bp }, 30, 80);
    # s06-panel-semantics: the container-status glyph is multi-byte but exactly
    # 2 display columns -- display_width, not length(), is the invariant.
    is(scalar(grep { Dashboard::display_width($_->{text}) != 80 } @$f), 0, 'compose: new panels keep rows exactly $cols');
    my $joined = join "\n", map { $_->{text} } @$f;
    like($joined, qr/$RULE_FILL_RE Run /,             'compose: Run panel title rendered');
    # RE-POINTED (spec S2.4.8, Decision 9): the Backpack panel dissolves into
    # a single summary ROW inside Run ("Rendered through row(label =>
    # 'backpack', ...) inside the Run panel -- not as a panel of its own"),
    # so it no longer has a title row to match. Claim preserved: the
    # backpack fact still reaches a composed frame -- subject moves from the
    # "-- Backpack " title to the summary text itself.
    # RE-POINTED again: counts are pluralised properly now, so a total of 1
    # renders "1 item" rather than "1 item(s)". That the SINGULAR form is what a
    # count of one produces is the assertion worth making here.
    like($joined, qr/\b1 item\b/, 'compose: backpack summary reaches the frame (as a Run-panel row, not a titled panel -- Decision 9)');
    like($joined, qr/keep-awake.*holding/, 'compose: keep-awake state surfaced in a frame');
}

# ===========================================================================
# PART 3 — render diff (the flicker fix)
# ===========================================================================
{
    my $a = Dashboard::compose_frame(\%st, 10, 60);
    # first render: no prev -> full redraw
    my $full = Dashboard::render_frame(undef, $a, { color => 0 });
    like($full, qr/^\e\[\?2026h/,  'render: opens with synchronized-output begin');
    like($full, qr/\e\[\?2026l$/,  'render: closes with synchronized-output end');
    like($full, qr/\e\[2J\e\[H/,   'render: full redraw clears the screen ONCE');

    # identical next frame -> diff touches no rows (no cursor moves besides wrappers)
    my $b = Dashboard::compose_frame(\%st, 10, 60);
    my $none = Dashboard::render_frame($a, $b, { color => 0 });
    unlike($none, qr/\e\[2J/, 'render: steady state does NOT clear screen (no flicker)');
    unlike($none, qr/\e\[\d+;1H/, 'render: identical frame -> zero row repaints');

    # change one row -> only that row repainted
    my %st2 = (%st, beat_age => 99);   # changes the heartbeat line only
    my $c = Dashboard::compose_frame(\%st2, 10, 60);
    my $diff = Dashboard::render_frame($a, $c, { color => 0 });
    unlike($diff, qr/\e\[2J/, 'render: single-field change is a diff, not a clear');
    my @moves = ($diff =~ /\e\[(\d+);1H/g);
    is(scalar(@moves), 1, 'render: exactly one row repainted for a one-row change');

    # resize (row count changes) -> full redraw
    my $resized = Dashboard::compose_frame(\%st, 12, 60);
    my $rdiff = Dashboard::render_frame($a, $resized, { color => 0 });
    like($rdiff, qr/\e\[2J/, 'render: row-count change (resize) forces a full redraw');

    # width-only resize (same rows, new width) -> diff, not clear; \e[K saves it
    my $wider = Dashboard::compose_frame(\%st, 10, 80);   # $a was 10x60
    my $wdiff = Dashboard::render_frame($a, $wider, { color => 0 });
    unlike($wdiff, qr/\e\[2J/, 'render: width-only resize is a diff, not a clear');
    my @wmoves = ($wdiff =~ /\e\[(\d+);1H/g);
    is(scalar(@wmoves), 10, 'render: width-only resize repaints all rows (all text changed)');

    # color mode emits SGR for the title row -- RE-DERIVED (spec S2.1): the
    # title cell's role is now the Theme role $TITLE_ROLE ('accent'), and
    # spec S2.1 states that role's SGR resolves through Theme::sgr($role,
    # undef), NOT the legacy bare-'title' bold-cyan escape. The source of
    # truth used here is Theme::sgr directly (not Dashboard::sgr_for_role),
    # because sgr_for_role is merely spec'd to DELEGATE to it -- deriving
    # against Theme::sgr catches sgr_for_role's delegation being incomplete
    # instead of trivially agreeing with whatever it currently returns.
    my $colored = Dashboard::render_frame(undef, $a, { color => 1 });
    my $expected_title_sgr = Theme::sgr($TITLE_ROLE, undef);
    like($colored, qr/\Q$expected_title_sgr\E/,
        "render: color mode emits the Theme-derived title SGR (role $TITLE_ROLE, via Theme::sgr -- spec S2.1)");
    like($colored, qr/\e\[0m/,    'render: color mode resets SGR');

    # regression: a trailing \e[K erased the last cell of a full-width row,
    # chopping the title's closing "]" (the "[running" bug). \e[K must come
    # BEFORE the text, never after.
    # THE PROPERTY IS "the last cell of a full-width row survives", not
    # "[running] is at the end". This guard exists because a trailing \e[K once
    # erased the final cell and chopped the title's closing bracket (the
    # "[running" bug). The status block has since moved to the head of the row,
    # so the element occupying that last cell is now the container name -- the
    # anchor moves with it, or the guard silently stops guarding anything.
    #
    # RE-POINTED 2026-08-25: the container id stopped being right-justified, so
    # at 80 columns the final cell is now padding -- and an erased SPACE is
    # invisible, which would leave this assertion passing while guarding
    # nothing. Compose at the header's own natural width instead, so the id
    # occupies the last cell again and the guard keeps its subject. Derived,
    # never a literal: the width follows the header's wording.
    my $natural = Dashboard::spans_text(tui::DashboardScreen::header_spans(\%st, 400));
    $natural =~ s/\s+\z//;
    my $tf = Dashboard::compose_frame(\%st, 6, Dashboard::display_width($natural));
    like($tf->[0]{text}, qr/\Qclaude-demo-abcd1234\E$/,
        'compose: title row ends with the full container name (last cell not erased)');
    my $tr = Dashboard::render_frame(undef, $tf, { color => 0 });
    like($tr,   qr/\e\[1;1H\e\[K/, 'render: line cleared BEFORE the text (\e[K precedes it)');
    unlike($tr, qr/\]\e\[K/,       'render: no \e[K right after "]" (last cell preserved)');
}

# ===========================================================================
# PART 4 — key dispatch
# ===========================================================================
# s11-lifecycle-stop (spec 08 S2.1): 's' is now stop-runs, 'x' is full-shutdown
# (no longer inert), and the legacy 'shutdown' pending token is retired in
# favor of the two new tokens 'stop-runs' / 'full-shutdown'. Full behavioral
# coverage (every key, both confirms, independence, normalization) lives in
# t/46-lifecycle-stop.t AC-1..AC-4; this block keeps the smoke-level PART 4
# key table in sync with the new contract so it does not encode stale
# behavior.
{
    is_deeply([Dashboard::dispatch_key('c', '')],   ['launch', ''],   'key: c -> launch');
    is_deeply([Dashboard::dispatch_key("\r", '')],  ['launch', ''],   'key: Enter -> launch');
    is_deeply([Dashboard::dispatch_key('q', '')],   ['quit', ''],     'key: q -> quit');
    is_deeply([Dashboard::dispatch_key('r', '')],   ['refresh', ''],  'key: r -> refresh');
    is_deeply([Dashboard::dispatch_key('s', '')],   ['confirm-stop-runs', 'stop-runs'],
        'key: s -> arm stop-runs confirm');
    is_deeply([Dashboard::dispatch_key('x', '')],   ['confirm-full-shutdown', 'full-shutdown'],
        'key: x -> arm full-shutdown confirm (no longer inert)');
    is_deeply([Dashboard::dispatch_key('y', 'stop-runs')], ['stop-runs', ''],
        'key: y while stop-runs pending -> fire stop-runs');
    is_deeply([Dashboard::dispatch_key('n', 'stop-runs')], ['cancel-stop-runs', ''],
        'key: any non-y while stop-runs pending -> cancel-stop-runs');
    is_deeply([Dashboard::dispatch_key('y', 'full-shutdown')], ['full-shutdown', ''],
        'key: y while full-shutdown pending -> fire full-shutdown');
    is_deeply([Dashboard::dispatch_key('n', 'full-shutdown')], ['cancel-full-shutdown', ''],
        'key: any non-y while full-shutdown pending -> cancel-full-shutdown');
    # confirm independence: the OTHER control's key cancels rather than firing/re-arming
    is_deeply([Dashboard::dispatch_key('x', 'stop-runs')], ['cancel-stop-runs', ''],
        'key: x while stop-runs pending cancels (does not fire/re-arm full-shutdown)');
    is_deeply([Dashboard::dispatch_key('s', 'full-shutdown')], ['cancel-full-shutdown', ''],
        'key: s while full-shutdown pending cancels (does not fire/re-arm stop-runs)');
    is_deeply([Dashboard::dispatch_key("\e", '')],  ['', ''],         'key: lone ESC -> inert');
    is_deeply([Dashboard::dispatch_key('UP', '')],   ['scroll-up', ''],   'key: UP -> scroll-up');
    is_deeply([Dashboard::dispatch_key('DOWN', '')], ['scroll-down', ''], 'key: DOWN -> scroll-down');
    is_deeply([Dashboard::dispatch_key('k', '')],    ['scroll-up', ''],   'key: k -> scroll-up (alias)');
    is_deeply([Dashboard::dispatch_key('j', '')],    ['scroll-down', ''], 'key: j -> scroll-down (alias)');
    # scroll keys must not disturb a pending confirm (any key cancels) -- for BOTH tokens
    is_deeply([Dashboard::dispatch_key('DOWN', 'stop-runs')], ['cancel-stop-runs', ''],
        'key: arrow while stop-runs-pending still cancels');
    is_deeply([Dashboard::dispatch_key('DOWN', 'full-shutdown')], ['cancel-full-shutdown', ''],
        'key: arrow while full-shutdown-pending still cancels');
}

# ===========================================================================
# PART 6 — B1 event tail
# ===========================================================================
{
    my @lines = (
        '{"ts":"2026-06-24T10:00:01Z","type":"launch_start","pid":1}',
        'not json at all',
        '{"ts":"2026-06-24T10:00:05Z","type":"container_start","exit":0}',
        '{"ts":"2026-06-24T10:00:09Z","type":"container_gone","state":"exited"}',
        '',
    );
    # A4: inject \&CORE::gmtime seam so these assertions stay deterministic once
    # recent_events converts timestamps to local-time.  The 3rd arg is currently
    # IGNORED by the 2-param implementation, so these tests remain green now and
    # will continue to pass after the seam is wired (gmtime == UTC == the ts value).
    #
    # s06-panel-semantics: recent_events now returns an arrayref-of-spans per
    # event (dim timestamp + a classified glyph+body), not a plain string --
    # extract text via Dashboard::spans_text and compute the expected glyph via
    # Dashboard::event_style (never hardcode it) so this stays in sync with the
    # classifier (spec S3.14; see t/41-panel-semantics.t AC19 for the full
    # per-span role assertions this file no longer duplicates).
    # event_style does not exist pre-implementation -- guard with eval{} (this
    # file's existing convention, e.g. PART 11) so a not-yet-defined sub fails
    # these assertions cleanly instead of fatally aborting the whole suite.
    #
    # RE-POINTED (package 06, spec S2.4.6, Family 4): recent_events's OLD 3rd
    # argument (a $localtime_fn) no longer reaches the render path at all --
    # the time span now needs the NEW 4th argument, $now, and renders
    # fmt_duration($now - $epoch), never an absolute HH:MM:SS clock time
    # (spec: "$localtime_fn is retained for signature compatibility ... and
    # is unused by the new time field"). The claim "an event row carries a
    # time, a glyph and a type" survives; only the time's grammar changes.
    # $now is injected (the line's own epoch + 3660s, DERIVED via
    # Time::Local::timegm rather than a hand-typed literal -- see the note
    # in PART 11 below on why a hand-typed epoch for this exact timestamp is
    # a proven bug trap) so the expected time text is re-derived by CALLING
    # fmt_age, never re-pinned as a literal.
    my $epoch_pt6 = timegm(1, 0, 10, 24, 5, 2026);   # 2026-06-24T10:00:01Z
    my $now_pt6   = $epoch_pt6 + 3660;
    my $ev = Dashboard::recent_events(\@lines, 10, \&CORE::gmtime, $now_pt6);
    is(scalar(@$ev), 3, 'events: garbage + blank lines skipped');
    my ($role0, $glyph0) = eval { Dashboard::event_style('launch_start', undef, undef) };
    # Dashboard::fmt_age is the delegating alias for the one duration format
    # (spec S2.4.7: "Dashboard::fmt_age becomes a delegating alias"); there
    # is no Dashboard::fmt_duration -- that name lives only on
    # tui::DashboardScreen (confirmed: Dashboard->can('fmt_duration') is
    # false, Dashboard->can('fmt_age') is true).
    # RE-POINTED (operator request): the time column is the event's own WALL
    # CLOCK time, not its age. "row carries time + glyph + type" is preserved;
    # only what "time" means changes, and it no longer depends on $now.
    my $expected_time0 = tui::DashboardScreen::activity_time_text(Dashboard::_local_hhmm($epoch_pt6, \&CORE::gmtime));
    is(Dashboard::spans_text($ev->[0]), $expected_time0 . ($glyph0 // '') . " launch_start",
        'events: HH:MM + glyph + type (spec S2.4.6 render step 4; time grammar re-derived, "row carries time+glyph+type" preserved)');
    my ($role1, $glyph1) = eval { Dashboard::event_style('container_start', 0, undef) };
    like(Dashboard::spans_text($ev->[1]), qr/\Q$glyph1\E container_start exit=0/, 'events: exit field surfaced') if defined $glyph1;
    fail('events: exit field surfaced (event_style not yet defined)') if !defined $glyph1;
    my ($role2, $glyph2) = eval { Dashboard::event_style('container_gone', undef, 'exited') };
    like(Dashboard::spans_text($ev->[2]), qr/\Q$glyph2\E container_gone state=exited/, 'events: state field surfaced') if defined $glyph2;
    fail('events: state field surfaced (event_style not yet defined)') if !defined $glyph2;

    my $last2 = Dashboard::recent_events(\@lines, 2, \&CORE::gmtime);
    is(scalar(@$last2), 2, 'events: honors the last-N limit');
    like(Dashboard::spans_text($last2->[-1]), qr/container_gone/,  'events: keeps the most recent (last)');
    like(Dashboard::spans_text($last2->[0]),  qr/container_start/, 'events: preserves chronological order (oldest-of-N first)');
}

# ===========================================================================
# PART 7 — shutdown signal paths
# ===========================================================================
{
    my $proj = tempdir(CLEANUP => 1);
    make_path("$proj/.ccpraxis-local-data/blueprints/alpha/runs");
    make_path("$proj/.ccpraxis-local-data/blueprints/beta/runs");
    make_path("$proj/.ccpraxis-local-data/blueprints/gamma");  # no runs/ -> excluded

    my @dirs = Dashboard::blueprint_runs_dirs("$proj/.ccpraxis-local-data");
    is(scalar(@dirs), 2, 'signals: only blueprints WITH a runs/ dir counted');

    my @targets = Dashboard::shutdown_targets($proj);
    is(scalar(@targets), 2, 'signals: one .shutdown target per blueprint runs dir');
    ok((grep { m{/alpha/runs/\.shutdown$} } @targets), 'signals: alpha target path correct');
    ok((grep { m{/beta/runs/\.shutdown$}  } @targets), 'signals: beta target path correct');

    my $n = Dashboard::write_shutdown_signals(@targets);
    is($n, 2, 'signals: write touches every target');
    ok(-f "$proj/.ccpraxis-local-data/blueprints/alpha/runs/.shutdown", 'signals: alpha .shutdown created');
    ok(-f "$proj/.ccpraxis-local-data/blueprints/beta/runs/.shutdown",  'signals: beta .shutdown created');

    # empty project -> no targets, no crash
    my $empty = tempdir(CLEANUP => 1);
    is(scalar(Dashboard::shutdown_targets($empty)), 0, 'signals: project with no blueprints -> 0 targets');
}

# ===========================================================================
# PART 8 — the loop (run) with a fake clock + scripted keys
# ===========================================================================

# helper: build a run() invocation over injected seams. Returns captured effects.
sub drive {
    my (%args) = @_;
    my @keys = @{ $args{keys} || [] };
    my $clock = 1000;
    my %eff = (heartbeats => 0, spawns => 0, stop_runs => 0, full_shutdown => 0, gathers => 0, frames => 0);
    my $out = '';

    my $rc = Dashboard::run(
        beat_interval  => $args{beat_interval}  // 1,
        state_interval => $args{state_interval} // 0,   # gather every tick
        tick_interval  => 0.25,
        color          => 0,
        max_ticks      => $args{max_ticks} // 20,
        now            => sub { $clock },
        sleep_for      => sub { $clock += $_[0]; },     # advance the fake clock
        read_key       => sub { @keys ? shift @keys : undef },
        term_size      => sub { ($args{cols} // 60, $args{rows} // 12) },
        gather         => sub { $eff{gathers}++; { project_name => 'demo', container => 'c1', status => ($args{status} // 'running'), events => ($args{events} // []), busy_age => $args{busy_age}, oauth_expires_at => $args{oauth_expires_at} } },
        heartbeat      => sub { $eff{heartbeats}++; $args{hb_returns} ? $args{hb_returns}->() : 'ok' },
        spawn          => sub { $eff{spawns}++; undef },
        stop_runs      => sub {
            my ($state, $progress) = @_;
            $eff{stop_runs}++;
            return { mode => 'stop-runs', ok => 1, timed_out => 0, stages => [],
                      machine_stopped => 0, others => [], others_known => 0,
                      summary => 'stop-runs ok' };
        },
        full_shutdown  => sub {
            my ($state, $progress) = @_;
            $eff{full_shutdown}++;
            return { mode => 'full-shutdown', ok => 1, timed_out => 0, stages => [],
                      machine_stopped => 1, others => [], others_known => 1,
                      summary => 'full shutdown ok' };
        },
        enter_raw      => sub { $eff{entered} = 1 },
        leave_raw      => sub { $eff{left} = ($eff{left} || 0) + 1 },
        keepawake      => sub { $eff{keepawake_calls}++; $eff{last_busy_age} = $_[0]{busy_age} },
        out            => sub { $out .= $_[0]; $eff{frames}++ },
    );
    $eff{rc} = $rc;
    $eff{out} = $out;
    return \%eff;
}

{
    # 'q' quits promptly and restores the terminal exactly once.
    my $e = drive(keys => ['q'], max_ticks => 50);
    is($e->{rc}, 0, 'loop: q exits with rc 0');
    ok($e->{entered}, 'loop: entered raw mode');
    is($e->{left}, 1, 'loop: left raw mode exactly once (clean restore)');
    ok($e->{frames} >= 1, 'loop: rendered at least one frame');
    like($e->{out}, qr/\e\[\?2026h/, 'loop: output uses synchronized rendering');
}

{
    # heartbeat fires on the first tick, then on cadence as the clock advances.
    my $e = drive(keys => [(undef) x 30], beat_interval => 1, max_ticks => 6);
    ok($e->{heartbeats} >= 2, 'loop: heartbeat fires repeatedly on the time cadence');
}

{
    # B5: the keepawake seam fires on every state refresh, receiving the freshly
    # gathered state (busy_age) so the launcher can drive the wake-lock.
    my $e = drive(keys => [(undef) x 10], busy_age => 42, state_interval => 0, max_ticks => 5);
    ok($e->{keepawake_calls} >= 1, 'loop: keepawake seam fires on state refresh');
    is($e->{last_busy_age}, 42, 'loop: keepawake seam receives the gathered busy_age');
}

{
    # (E) container 'gone' from the heartbeat must NOT end the loop — the
    # dashboard stays open so the user can see the dead state and relaunch/quit.
    my $e = drive(keys => [(undef) x 30], hb_returns => sub { 'gone' },
                  status => 'exited', beat_interval => 1, max_ticks => 8);
    ok($e->{heartbeats} >= 2, 'loop: keeps heartbeating after "gone" (does not exit early)');
    is($e->{rc}, 0, 'loop: runs to max_ticks rather than a gone-exit');
    like($e->{out}, qr/not running|unreachable/, 'loop: surfaces a container-dead alert');
    is($e->{left}, 1, 'loop: restores the terminal exactly once at the end');
}

{
    # (D) [r] forces a FULL repaint (blank \e[2J + redraw). The first frame is
    # always a full clear; refresh produces a SECOND one.
    my $e = drive(keys => [undef, 'r', undef, 'q'], max_ticks => 50);
    my $clears = () = ($e->{out} =~ /\e\[2J/g);
    ok($clears >= 2, 'loop: refresh triggers an extra full-screen clear (hard refresh)');
}

{
    # Activity: newest-first, and DOWN/q scrolls without crashing (a tall enough
    # terminal so the Activity panel renders under the Sandbox/Run panels). The
    # newest-first + offset correctness itself is covered by activity_view tests.
    my @evs = ('10:00:01  launch_start', '10:00:02  container_start', '10:00:03  manager_ready');
    my $top = drive(keys => ['q'], events => \@evs, rows => 30, max_ticks => 50);
    like($top->{out}, qr/manager_ready/, 'activity: newest event is rendered');

    my $scrolled = drive(keys => ['DOWN', 'DOWN', undef, 'q'], events => \@evs, rows => 30, max_ticks => 50);
    is($scrolled->{rc}, 0, 'activity: DOWN scrolling runs cleanly to quit');
    like($scrolled->{out}, qr/launch_start/, 'activity: events still render while scrolling');
}

{
    # 'c' launches a session (spawn), then 'q'.
    my $e = drive(keys => ['c', 'q'], max_ticks => 50);
    is($e->{spawns}, 1, 'loop: c -> exactly one spawn');
    is($e->{rc}, 0, 'loop: then q exits');
}

{
    # 'c' on a NON-running container must NOT spawn (the connector window would
    # just open and vanish); instead the footer flashes the real recovery path.
    my $e = drive(keys => ['c', undef, 'q'], status => 'exited', max_ticks => 50);
    is($e->{spawns}, 0, 'loop: c on a dead container -> no doomed spawn');
    like($e->{out}, qr/container is down/, 'loop: c on a dead container -> footer flash shown');
    is($e->{rc}, 0, 'loop: then q exits');
}

{
    # s11-lifecycle-stop: 's' arms stop-runs, 'x' arms full-shutdown; both are
    # two-step confirms and neither exits the loop (spec 08 #2/#4 -- 'q' is
    # still required afterward). Full mechanism (order, guard, staged frames)
    # is t/46-lifecycle-stop.t's job; this is the PART 8 loop-wiring smoke.
    my $e1 = drive(keys => ['s', 'y', 'q'], max_ticks => 50);
    is($e1->{stop_runs}, 1, 'loop: s,y -> stop_runs seam fired once');
    is($e1->{rc}, 0, 'loop: s,y,q -> rc 0 (q still required to exit)');
    my $e2 = drive(keys => ['s', 'n', 'q'], max_ticks => 50);
    is($e2->{stop_runs}, 0, 'loop: s,n -> stop-runs cancelled (seam not fired)');

    my $e3 = drive(keys => ['x', 'y', 'q'], max_ticks => 50);
    is($e3->{full_shutdown}, 1, 'loop: x,y -> full_shutdown seam fired once');
    is($e3->{rc}, 0, 'loop: x,y,q -> rc 0 (q still required to exit)');
    my $e4 = drive(keys => ['x', 'n', 'q'], max_ticks => 50);
    is($e4->{full_shutdown}, 0, 'loop: x,n -> full-shutdown cancelled (seam not fired)');
}

# ===========================================================================
# PART 9 — scroll fix: capacity, windowing, overflow hint, drain coalescing
# ===========================================================================

# _scroll_hint / the separate hint-row mechanism is REMOVED by s06-panel-semantics
# (Decision #19): the overflow indicator is now an inline Unicode overlay on the
# first/last visible Activity row, owned by activity_window + _justify_spans.
# See t/41-panel-semantics.t AC20-AC26 for the replacement coverage.
ok(!Dashboard->can('_scroll_hint'), '_scroll_hint no longer exists (s06: replaced by the inline overlay)');

# activity_capacity: mirrors compose_frame's budget (deterministic for %st).
# RE-DERIVED (package 06, spec S5 ":756-774", Family 3): the Sandbox panel
# that the old comment's "Sandbox(5)+Run(3)" arithmetic depended on is
# deleted (spec S2.4.3), and the breakpoint moved 100 -> $BP==90 (Decision
# 14) -- BOTH independently changed the fixed region's size, so every
# literal number below is replaced by _cap_expect() (declared once near the
# top of this file), which calls the spec's own migration formula:
#   capacity == max(0, rows - 2(title+footer) - _fixed_region_height(state,cols) - 1)
# Claim preserved verbatim: "capacity mirrors compose_frame's budget." A
# live status alert is asserted as a DIFFERENTIAL against the non-alert
# derivation (preserving this file's own original comment, "a status alert
# costs one more row", as a relative claim rather than a guessed absolute
# term folded into the formula).
is(Dashboard::activity_capacity(\%st, 24, 80), _cap_expect(\%st, 24, 80),
   'capacity: 24 rows, no alert -- rows - 2 - _fixed_region_height - 1 (derivation, spec S5)');
# RE-POINTED (package t01-providers-panel, operator ruling 2026-08-13): at 24
# rows the Providers+Blueprints panels this package adds pin Activity at the
# flex floor for BOTH plain and alert states, so the differential cannot be
# observed there any more -- see the SATURATION and THRESHOLD blocks below
# (declared once, shared with t/40-layout-responsive.t's identical claim)
# for the 24-row coverage this move would otherwise drop.
is(Dashboard::activity_capacity({ %st, status => 'exited' }, 31, 80),
   Dashboard::activity_capacity(\%st, 31, 80) - 1,
   'capacity: a status alert costs one more row (differential, this file\'s own original claim; row count chosen above the flex floor -- see AC-11 THRESHOLD below)');
is(Dashboard::activity_capacity(\%st, 12, 80), _cap_expect(\%st, 12, 80),
   'capacity: too short for the fixed panels -- derivation (clamped at 0 if negative)');

# s05-responsive-layout (AC-11): the two-column capacity oracles. RE-DERIVED
# for the same two reasons (Sandbox dissolution + Decision 14's breakpoint
# move) -- the OLD "max(T_sandbox, T_run)" arithmetic named a panel that no
# longer exists; _fixed_region_height(state,cols) is the single function
# both this file and t/40-layout-responsive.t's AC-11 now derive against.
is(Dashboard::activity_capacity(\%st, 24, $BP), _cap_expect(\%st, 24, $BP),
   "capacity: two-column mode (cols>=\$BP=$BP) -- derivation (Sandbox dissolved; formula, not the old max(T_sandbox,T_run))");
is(Dashboard::activity_capacity(\%st, 12, 120), _cap_expect(\%st, 12, 120),
   'capacity: two-column mode, 12 rows -- derivation');
is(Dashboard::activity_capacity(\%st, 10, 120), _cap_expect(\%st, 10, 120),
   'capacity: two-column mode, 10 rows -- derivation (0, too short)');
is(Dashboard::activity_capacity(\%st, 8, 120), _cap_expect(\%st, 8, 120),
   'capacity: two-column mode, 8 rows -- derivation (clamped from a non-positive body_h)');
# RE-POINTED (package t01-providers-panel, operator ruling 2026-08-13): same
# reasoning as the 80-column differential above -- 24 rows now saturates the
# floor in two-column mode too.
is(Dashboard::activity_capacity({ %st, status => 'exited' }, 28, 120),
   Dashboard::activity_capacity(\%st, 28, 120) - 1,
   'capacity: two-column mode + a status alert costs one more row (differential; row count chosen above the flex floor -- see AC-11 THRESHOLD below)');

# ---------------------------------------------------------------------------
# AC-11 SATURATION (rows=24, cols=80/120) -- operator ruling 2026-08-13
# (t01-providers-panel): ACCEPT the taller fixed region, do NOT shrink
# mandated panel content, and assert the new floor-pinned behaviour at 24
# rows explicitly (mirrors t/40-layout-responsive.t's identical block).
#
# The floor value (3) is HAND-DERIVED from tui::Screen::flex_reserve's own
# documented formula (plugins/sandbox/scripts/tui/Screen.pm:164-172:
# reserve = min(4, floor(body_h/2)), floored at 0) applied to THIS fixture's
# own dimensions -- rows=24 -> body_h = 24-2 = 22 -> half = floor(22/2) = 11
# -> reserve = min(4,11) = 4 -> activity floor = reserve-1 = 3 -- NEVER by
# calling flex_reserve() or activity_capacity() itself, so a future change
# that quietly lowers the reservation is caught by this literal going red.
# ---------------------------------------------------------------------------
{
    my $floor24 = 3;
    my %exited24 = (%st, status => 'exited');
    is(Dashboard::activity_capacity(\%st, 24, 80), $floor24,
        "AC-11 saturation: 24x80 (stacked) -- capacity == the hand-derived flex floor ($floor24)");
    is(Dashboard::activity_capacity(\%exited24, 24, 80), $floor24,
        "AC-11 saturation: 24x80 with a status alert -- capacity is STILL $floor24 (the floor absorbs the alert row; no differential at this row count)");
    is(Dashboard::activity_capacity(\%st, 24, 120), $floor24,
        "AC-11 saturation: 24x120 (two-column) -- capacity == the hand-derived flex floor ($floor24)");
    is(Dashboard::activity_capacity(\%exited24, 24, 120), $floor24,
        "AC-11 saturation: 24x120 with a status alert -- capacity is STILL $floor24 (the floor absorbs the alert row; no differential at this row count)");
}

# ---------------------------------------------------------------------------
# AC-11 THRESHOLD -- the exact row count where the differential resumes,
# pinned as a permanent guarantee. Measured exhaustively (row 11-80 scan,
# both 80 and 120 columns): diff=0 throughout the dead band with no
# exceptions, diff=1 from the threshold onward with no exceptions.
# ---------------------------------------------------------------------------
{
    my $floor24 = 3;
    my %exited = (%st, status => 'exited');

    # THE THRESHOLD IS LOCATED, NOT PASTED.
    #
    # This block's comment has always said the threshold was "measured
    # exhaustively (row 11-80 scan)" -- but only the ANSWER was written down
    # (30/31 at 80 cols, 27/28 at 120). That answer is a function of how tall
    # the panels above Activity happen to be, so it moved by one row the moment
    # the Providers panel lost a line (Go and Zen nested under one OpenCode
    # heading, 2026-08-25) and this block went red over a change that did not
    # touch the dead band at all.
    #
    # The PROPERTY is what deserves pinning: there is a contiguous dead band in
    # which a status alert costs nothing, it ends at exactly one row count, and
    # from there on the alert costs exactly one row. So do the scan the comment
    # describes, then assert the shape around whatever it finds.
    my $find_threshold = sub {
        my ($cols) = @_;
        for my $rows (11 .. 80) {
            my $base  = Dashboard::activity_capacity(\%st, $rows, $cols);
            my $alert = Dashboard::activity_capacity(\%exited, $rows, $cols);
            return $rows if $base > $floor24 && $alert == $base - 1;
        }
        return undef;
    };

    for my $cols (80, 120) {
        my $thr = $find_threshold->($cols);
        ok(defined $thr, "AC-11 threshold: a differential threshold exists at ${cols} cols (scan 11..80)");
        next unless defined $thr;

        my $below = Dashboard::activity_capacity(\%st, $thr - 1, $cols);
        is($below, $floor24,
            "AC-11 threshold precondition: @{[$thr-1]}x$cols -- one row below the threshold, capacity is still "
          . "exactly at the floor (proves the dead band, not a coincidence)");
        is(Dashboard::activity_capacity(\%exited, $thr - 1, $cols), $below,
            "AC-11 threshold: @{[$thr-1]}x$cols -- one row BELOW the threshold, a status alert costs NOTHING");

        my $at = Dashboard::activity_capacity(\%st, $thr, $cols);
        cmp_ok($at, '>', $floor24,
            "AC-11 threshold precondition: ${thr}x$cols -- capacity has genuinely left the floor (not still clamped)");
        is(Dashboard::activity_capacity(\%exited, $thr, $cols), $at - 1,
            "AC-11 threshold: ${thr}x$cols -- the FIRST row count where a status alert costs exactly one more row again");

        # The dead band is CONTIGUOUS below the threshold -- no stray row where
        # the differential flickers on and off. This is the half the pasted
        # answer could never assert.
        my @leaks = grep {
            Dashboard::activity_capacity(\%exited, $_, $cols)
              != Dashboard::activity_capacity(\%st, $_, $cols)
        } (11 .. $thr - 1);
        is_deeply(\@leaks, [],
            "AC-11 threshold: the dead band below ${thr}x$cols is contiguous -- no row count inside it "
          . "charges for the alert");
    }
}
{
    # s06-panel-semantics + package 06 (Decision 9): the Backpack panel is no
    # longer a panel at all -- it is one summary ROW inside Run (spec
    # S2.4.8), so the old itemized/paragraph-height arithmetic this comment
    # used to carry (T_2=4/6) is moot. _fixed_region_height(state,cols)
    # reflects the backpack row's contribution to Run's own height
    # automatically, by construction, needing no special-casing here.
    my $bp3 = { total => 3, approved => 0, items => [
        { key => 'apt:a', approved => 0 },
        { key => 'apt:b', approved => 0 },
        { key => 'apt:c', approved => 0 },
    ] };
    is(Dashboard::activity_capacity({ %st, backpack => $bp3 }, 24, 120),
       _cap_expect({ %st, backpack => $bp3 }, 24, 120),
       'capacity: two-column mode with a gathered 3-item backpack (now a Run-panel row, not a panel -- Decision 9) -- derivation');
}
# boundary pair: cols=$BP-1 stays stacked, cols=$BP flips to two-column mode.
# RE-DERIVED (duplicate of the boundary pair above, same reasoning).
is(Dashboard::activity_capacity(\%st, 24, $BP - 1), _cap_expect(\%st, 24, $BP - 1),
   "capacity: boundary -- cols=@{[ $BP - 1 ]} is still stacked -- derivation");
is(Dashboard::activity_capacity(\%st, 24, $BP), _cap_expect(\%st, 24, $BP),
   "capacity: boundary -- cols=$BP flips to two-column mode -- derivation");

# activity_window: fits / empty / zero-capacity. The overflow/scroll/clamp +
# inline-overlay coverage (s06-panel-semantics, Decision #19) moved to
# t/41-panel-semantics.t AC20-AC26 -- that suite is the current oracle for
# activity_window's overflow behavior, arithmetic ($visible=$cap, no reserved
# hint row), and the overlay mechanism; duplicating it here against the OLD
# (pre-s06) hint-row arithmetic would just rot out of sync.
my @D = ('e5','e4','e3','e2','e1');   # newest-first (already descending)
{
    my $w = Dashboard::activity_window(\@D, 0, 10);
    is_deeply($w->{lines}, \@D, 'window: everything fits -> all shown');
    is($w->{above}, 0,       'window: fits -> above 0 (no overlay)');
    is($w->{below}, 0,       'window: fits -> below 0 (no overlay)');
    is($w->{max_offset}, 0,     'window: fits -> max_offset 0 (no scroll)');
}
is_deeply(Dashboard::activity_window([], 0, 5)->{lines}, [], 'window: empty -> empty');
is_deeply(Dashboard::activity_window(\@D, 0, 0)->{lines}, [], 'window: zero capacity -> empty');

# 'scrollhint' is intentionally left defined in sgr_for_role (spec's own out-of-
# scope ruling: removing an unused role is churn, not a fix) even though no
# production code path assigns it anymore (the new overlay uses 'muted').
is(Dashboard::sgr_for_role('scrollhint'), "\e[2m", 'sgr: scrollhint -> dim (\e[2m, like the footer) -- role kept, unused');

{
    # DRAIN coalescing: three DOWN keys in ONE tick advance the offset by three
    # (not one-per-tick). With 20 events overflowing the capacity, offset=3
    # after the drain means above=3 regardless of the exact capacity/below
    # split -- s06-panel-semantics (Decision #19) renders that as an inline
    # "<UP-TRIANGLE> 3 more" overlay on the first visible row (replaces the
    # old ASCII "3 more above" hint-row text).
    my $tri_up = Encode::encode('UTF-8', "\x{25B2}");
    my @evs = map { "evt$_" } (1 .. 20);
    my $e = drive(keys => ['DOWN','DOWN','DOWN', undef, 'q'],
                  events => \@evs, rows => 24, max_ticks => 50);
    is($e->{rc}, 0, 'drain: scrolls then quits cleanly');
    like($e->{out}, qr/\Q$tri_up\E 3 more/,
         'drain: 3 DOWNs in one tick coalesce -> offset advanced by 3 (inline overlay shows "<UP-TRIANGLE> 3 more")');
}

# ===========================================================================
# PART 10 — scroll-responsiveness oracle (spec 01-scroll-responsiveness A–E)
#
# These tests encode the IMMUTABLE acceptance criteria.  They are written
# against the UNFIXED code and therefore FAIL for the right reason now.
# The implementer must satisfy them without weakening any assertion.
#
# Seam recap (Dashboard.pm::run):
#   $out      (:709)   — called once per render; we count calls per tick
#   $gather   (:702)   — must NOT fire on a pure-scroll tick (criterion B)
#   $sleep_for(:699)   — called once per tick (after the drain, before next iter);
#                        used as the tick-boundary signal for per-tick accounting
#
# Key encodings (dispatch_key, confirmed by PART 4 tests above):
#   'UP'   -> scroll-up    'DOWN' -> scroll-down
#   'k'    -> scroll-up    'j'    -> scroll-down
# ===========================================================================

# drive_per_tick: like drive(), but records the OUT-call count for each
# completed tick (indexed 0..N-1) so tests can assert per-tick render counts.
#
# sleep_for is the tick-end sentinel: it fires after the drain and after the
# max_ticks guard, so the delta of $frames at each sleep_for invocation is the
# number of $out calls that tick produced.  The final tick (where max_ticks fires
# the `last`) does NOT call sleep_for; its render count is inferred from the
# total minus the sum of recorded ticks.
#
# Returns a hashref with the same keys as drive() plus:
#   frames_per_tick => [ count_tick0, count_tick1, ... ]  (all completed ticks)
#   gathers_per_tick => [ count_tick0, count_tick1, ... ]
sub drive_per_tick {
    my (%args) = @_;
    my @keys       = @{ $args{keys} || [] };
    my $clock      = 1000;
    my %eff        = (heartbeats => 0, spawns => 0, stop_runs => 0, full_shutdown => 0, gathers => 0, frames => 0);
    my $out_str    = '';
    my $prev_frames  = 0;
    my $prev_gathers = 0;
    my @fps;   # frames per tick (completed ticks only)
    my @gps;   # gathers per tick

    my $rc = Dashboard::run(
        beat_interval  => $args{beat_interval}  // 9999,
        state_interval => $args{state_interval} // 999,   # suppress mid-run gathers unless overridden
        tick_interval  => 0.25,
        # The title spinner is PINNED for this shared driver. Blocks below
        # count OSC payloads and out-calls per tick, asserting that the title
        # is emitted ONLY WHEN IT CHANGES -- a change-detection property. At
        # the production 500ms cadence the lead character advances during the
        # run, so the title genuinely changes and the counts genuinely rise,
        # which would turn those assertions into measurements of the spinner
        # rather than of the property they name. A period longer than the run
        # holds the character still.
        title_spinner_period => 9_999,
        color          => 0,
        max_ticks      => $args{max_ticks} // 5,
        now            => sub { $clock },
        sleep_for      => sub {
            $clock += $_[0];
            push @fps, $eff{frames}  - $prev_frames;
            push @gps, $eff{gathers} - $prev_gathers;
            $prev_frames  = $eff{frames};
            $prev_gathers = $eff{gathers};
        },
        read_key  => sub { @keys ? shift @keys : undef },
        term_size => sub { ($args{cols} // 60, $args{rows} // 24) },
        gather    => sub {
            $eff{gathers}++;
            {   project_name => 'demo',
                container    => 'c1',
                status       => 'running',
                events       => ($args{events} // []),
            }
        },
        heartbeat     => sub { 'ok' },
        spawn         => sub { $eff{spawns}++; undef },
        stop_runs     => sub { $eff{stop_runs}++; return { mode => 'stop-runs', ok => 1, timed_out => 0,
                                  stages => [], machine_stopped => 0, others => [], others_known => 0,
                                  summary => 'stop-runs ok' }; },
        full_shutdown => sub { $eff{full_shutdown}++; return { mode => 'full-shutdown', ok => 1, timed_out => 0,
                                  stages => [], machine_stopped => 1, others => [], others_known => 1,
                                  summary => 'full shutdown ok' }; },
        enter_raw     => sub { },
        leave_raw     => sub { },
        keepawake     => sub { },
        out           => sub { $out_str .= $_[0]; $eff{frames}++ },
    );

    $eff{rc}             = $rc;
    $eff{out}            = $out_str;
    $eff{frames_per_tick}  = \@fps;
    $eff{gathers_per_tick} = \@gps;
    return \%eff;
}

# ---------------------------------------------------------------------------
# A — PROMPTNESS (THE KEY ASSERTION)
#
# A DOWN scroll key injected on tick 1 must cause an ADDITIONAL $out call
# within THAT SAME TICK — i.e. the scroll tick has >= 2 renders.
#
# Current code (render-before-drain): renders once per tick unconditionally,
# before the drain.  The scroll key is read in the drain AFTER the render, so
# the scroll effect is only visible on tick 2.  Therefore frames_per_tick[1]
# == 1 now.  This test FAILS until the post-drain re-render is added.
#
# Key sequence: [undef, 'DOWN', undef, undef]
#   Tick 0 drain: undef -> drain empty      (no scroll)
#   Tick 1 drain: 'DOWN' then undef -> DOWN drain ends (scroll fires)
#   Tick 2 drain: undef -> drain empty      (no scroll)
#   Tick 3: max_ticks fires (no sleep_for for this tick)
# The 20-event list ensures $activity_max > 0 so the DOWN actually mutates offset.
# ---------------------------------------------------------------------------
{
    my @evs = map { "evt$_" } (1 .. 20);
    my $e = drive_per_tick(
        keys       => [undef, 'DOWN', undef, undef],
        events     => \@evs,
        rows       => 24,
        max_ticks  => 4,
        state_interval => 999,   # gather only on tick 0 (last_state=undef gate)
    );
    # frames_per_tick[1] is the scroll tick (ticks 0/1/2 each call sleep_for; tick 3 exits)
    my $scroll_tick_renders = $e->{frames_per_tick}[1];
    cmp_ok($scroll_tick_renders, '>=', 2,
        'A: scroll-responsiveness: DOWN tick emits >=2 out calls (post-drain re-render)');
}

# ---------------------------------------------------------------------------
# B — NO GATHER ON PURE SCROLL
#
# The re-render after a scroll must reuse @all_events (already in scope).
# gather() must NOT be called during a tick where the only key is a scroll key.
#
# gathers_per_tick[0] == 1  (forced on first tick because last_state=undef)
# gathers_per_tick[1] == 0  (scroll tick — no new gather allowed)
# ---------------------------------------------------------------------------
{
    my @evs = map { "evt$_" } (1 .. 20);
    my $e = drive_per_tick(
        keys       => [undef, 'DOWN', undef, undef],
        events     => \@evs,
        rows       => 24,
        max_ticks  => 4,
        state_interval => 999,
    );
    is($e->{gathers_per_tick}[1], 0,
        'B: pure-scroll tick does NOT call the gather seam');
}

# ---------------------------------------------------------------------------
# C — GATHER CADENCE UNCHANGED
#
# A tick past state_interval with NO input must still gather exactly once.
# The scroll path must not perturb the gather timer.
#
# Setup: state_interval => 1, tick_interval => 0.25 (so sleep_for adds 0.25 to
# the clock each tick).  After 4 ticks (4 * 0.25 = 1s) the clock has advanced
# 1s from the initial gather, so tick 4 fires a gather.  Verify gathers_per_tick
# for a quiet (no-key) run: tick 0 gathers (last_state=undef), ticks 1-3 don't,
# tick 4 does (1s elapsed).
#
# Drive 5 completed ticks (max_ticks=6: ticks 0..4 each call sleep_for,
# tick 5 exits via max_ticks without sleep_for).
# ---------------------------------------------------------------------------
{
    my $e = drive_per_tick(
        keys           => [],       # no input at all
        rows           => 24,
        max_ticks      => 6,
        state_interval => 1,        # gather when clock advances >= 1s
    );
    my @gpt = @{ $e->{gathers_per_tick} };
    is($gpt[0], 1, 'C: tick 0 gathers (last_state=undef gate fires unconditionally)');
    is($gpt[1], 0, 'C: tick 1 does NOT gather (state_interval not elapsed)');
    is($gpt[2], 0, 'C: tick 2 does NOT gather');
    is($gpt[3], 0, 'C: tick 3 does NOT gather');
    is($gpt[4], 1, 'C: tick 4 gathers (1s elapsed -> state_interval fires again)');
}

# ---------------------------------------------------------------------------
# D — NO EXTRA RENDER WITHOUT SCROLL
#
# A tick with no scroll input emits EXACTLY ONE $out call.
# Guards against an "always re-render" regression: the re-render must be gated
# strictly on a scroll-dirty flag, not on every tick unconditionally.
#
# frames_per_tick for a quiet-key run must be 1 for every completed tick.
# ---------------------------------------------------------------------------
{
    my $e = drive_per_tick(
        keys      => [],    # no input
        rows      => 24,
        max_ticks => 4,
        state_interval => 999,
    );
    my @fps = @{ $e->{frames_per_tick} };
    # s07-live-status Decision #8: the OSC window-title emit is its OWN $out call,
    # made once on the first primary render ($last_title starts undef) and then
    # only on change.  So tick 0 legitimately has TWO out calls (title + render)
    # and every later tick has exactly one (title unchanged -> no re-emit).
    # Pinned exactly: WHICH tick deviates, and BY HOW MUCH -- a bare
    # "one tick deviates" would also pass if an unrelated regression added a
    # stray render on a different tick.
    # max_ticks => 4 drives 3 COMPLETED ticks (0,1,2): frames_per_tick is only
    # appended inside sleep_for, and the 4th (final) tick exits via the
    # max_ticks guard before calling sleep_for -- same pattern as block C's
    # "max_ticks=6 -> 5 completed ticks" above.
    is(scalar(@fps), 3, 'D: 3 completed ticks were driven (the shape below is not vacuous)');
    my @off_shape = grep { $fps[$_] != 1 } 0 .. $#fps;
    is_deeply(\@off_shape, [0],
        'D: exactly ONE tick deviates from 1 out call and it is tick 0 (the one-time initial OSC window-title emit); every later tick is exactly 1 (no spurious extra render)');
    is($fps[0], 2,
        'D: tick 0 emits exactly 2 out calls -- initial OSC window-title emit + primary render -- and no more');
    # The title's lead character animates through the ten braille frames
    # (operator request, 2026-08-25), so the payload is no longer pure ASCII.
    # The property here is the SHAPE -- an OSC title emit followed immediately
    # by a sync-wrapped frame -- so the payload class widens to "any byte that
    # cannot terminate the sequence or start another", i.e. no control bytes.
    like($e->{out}, qr/\A\e\]0;[^\x00-\x1F\x7F]*\a\e\[\?2026h/,
        'D: tick 0\'s extra out call IS specifically the OSC window-title emit (title text, then immediately a sync-wrapped frame) -- not some other spurious render that happens to also produce a count of 2');
}

# ---------------------------------------------------------------------------
# E — $prev BASELINE AFTER DOUBLE RENDER
#
# After a scroll tick's double render, the NEXT tick's diff must be computed
# against the re-rendered frame (the second one), NOT the pre-drain frame.
#
# The landmine (scout risk 3): if $prev is NOT updated after the re-render,
# the next tick's render_frame diffs against a stale baseline and emits wrong
# row updates.
#
# Observable proxy: with no state change between tick 1 (scroll) and tick 2
# (no input, no gather), the tick-2 render must be a DIFF render (not a
# full-clear).  If $prev is stale (not updated after the re-render), the
# baseline mismatch causes wrong/extra row repaints.
#
# We assert this at the $out seam level: if the fix is correct, the TOTAL
# number of row-move escapes (\e[R;1H) in the THIRD render (tick-2's single
# render) must be 0 — because the frame content is identical to the re-rendered
# frame from tick 1 (same events, same offset, same state).
#
# Implementation: capture each individual $out call in sequence; inspect the
# third call (index 2) — i.e. render #3 — for row-repaint escapes.
# With the FIX the sequence is: render#1(tick0), render#2(tick1-primary),
# render#3(tick1-scroll-rerender), render#4(tick2) — so render#4 should have 0
# row moves.
# Without the FIX there is no render#3, so render#3==tick2's render, which
# diffs against tick1-primary ($prev still the pre-drain frame) — but since
# offset was also not updated in the render, the frame IS the same as tick0's
# render, so render#3 also has 0 row moves.  This means E cannot produce a
# false-positive failure right now; it passes vacuously (or with the fix).
# We therefore frame E as a NON-regression assertion: the number of row moves
# in the first quiet-tick render after a scroll is 0 — correct with or without
# the fix, but catches a broken $prev update path.
#
# The critical non-vacuous E test: with the fix, frames_per_tick[1] == 2 AND
# the post-scroll tick still shows 0 spurious row repaints.  We capture all
# $out calls individually to inspect.
# ---------------------------------------------------------------------------
{
    my @evs = map { "evt$_" } (1 .. 20);
    my @renders;    # each individual $out call, in order
    my $clock = 1000;
    my %eff = (gathers => 0, frames => 0);
    my @keys_e = (undef, 'DOWN', undef, undef);

    Dashboard::run(
        beat_interval  => 9999,
        state_interval => 999,
        tick_interval  => 0.25,
        # The spinner period is 500ms in production and is no longer borrowed
        # from the render tick (a render tick is an input-latency decision, not
        # an animation speed). This block asserts that a quiet tick repaints
        # EXACTLY the title row -- which requires the spinner to advance on
        # every tick -- so it states the period it needs rather than inheriting
        # one that would leave three ticks in four with nothing to repaint.
        spinner_period => 0.25,
        color          => 0,
        max_ticks      => 4,
        now            => sub { $clock },
        sleep_for      => sub { $clock += $_[0]; },
        read_key       => sub { @keys_e ? shift @keys_e : undef },
        term_size      => sub { (60, 24) },
        gather         => sub {
            $eff{gathers}++;
            { project_name => 'demo', container => 'c1', status => 'running',
              events => \@evs }
        },
        heartbeat     => sub { 'ok' },
        spawn         => sub { undef },
        write_signals => sub { 1 },
        enter_raw     => sub { },
        leave_raw     => sub { },
        keepawake     => sub { },
        out           => sub { push @renders, $_[0]; $eff{frames}++ },
    );

    # With the fix: renders are [tick0, tick1-primary, tick1-rerender, tick2].
    # Without the fix: renders are [tick0, tick1, tick2, tick3].
    # In both cases the LAST render in a quiet, no-gather tick should have 0 row moves.
    # The real guard: the render IMMEDIATELY AFTER the scroll tick must have
    # 0 row-repaint escapes (the diff sees no change vs the last emitted frame).
    #
    # We target the render that follows the scroll event.  With the fix, that is
    # renders[-1] (tick2's render, index 3 in a 4-render sequence).
    # Without the fix, that is renders[2] (tick2's render, no re-render existed).
    # We use frames_per_tick to locate it: the render right after the scroll tick.
    my $total = scalar @renders;
    ok($total >= 3, 'E: at least 3 out calls produced (enough to inspect post-scroll render)');

    # The last render in the captured sequence is the one for the quiet tick
    # that follows the scroll tick (tick2, no scroll, no gather).
    my $post_scroll_render = $renders[-1];
    # s07-live-status done-criterion #2 makes an idle tick a 1-ROW update, not a
    # 0-row update: the title row repaints because the spinner index advanced.
    # So exactly ONE row move is expected -- and it must be row 1 (the title
    # row).  A repaint of any OTHER row would still mean a stale $prev baseline.
    my @row_moves = ($post_scroll_render =~ /\e\[(\d+);1H/g);
    is(scalar(@row_moves), 1,
        'E: post-scroll quiet-tick render repaints EXACTLY ONE row (prev baseline is current, not stale)');
    is_deeply(\@row_moves, ['1'],
        'E: ...and that one row is row 1, the title row (legitimate spinner advance), not a content row');
}

# ===========================================================================
# PART 11 — 01-dashboard-localtime-oauth acceptance criteria
# ===========================================================================

# ---------------------------------------------------------------------------
# B1–B5  fmt_oauth($remaining_secs)
#
# fmt_oauth does NOT exist yet.  Each call is wrapped in eval{} so the missing
# sub produces a per-assertion FAIL rather than aborting the file.
# ---------------------------------------------------------------------------
{
    my $have_fmt_oauth = Dashboard->can('fmt_oauth');

    # B1: undef (no token yet) -> actionable 'not logged in (run /login)'
    my $b1 = eval { tui::DashboardScreen::_fmt_oauth_like(undef) };
    is($b1, 'not logged in (run /login)',
        'B1: fmt_oauth(undef) eq "not logged in (run /login)"');
    unlike($b1 // '', qr/[^\x20-\x7E]/,
        'B1-ascii: not-logged-in label is ASCII-only (width-safe)');

    # B2: negative -> 'EXPIRED'
    my $b2 = eval { tui::DashboardScreen::_fmt_oauth_like(-5) };
    is($b2, 'EXPIRED',
        'B2: fmt_oauth(-5) eq "EXPIRED"');

    # B3: zero -> 'EXPIRED'
    my $b3 = eval { tui::DashboardScreen::_fmt_oauth_like(0) };
    is($b3, 'EXPIRED',
        'B3: fmt_oauth(0) eq "EXPIRED"');

    # B4: 3h12m -> 'expires in 3h12m'
    my $b4 = eval { tui::DashboardScreen::_fmt_oauth_like(3*3600 + 12*60) };
    is($b4, 'expires in 3h12m',
        'B4: fmt_oauth(3*3600+12*60) eq "expires in 3h12m"');

    # B5: sub-minute -> 'expires in 45s'
    my $b5 = eval { tui::DashboardScreen::_fmt_oauth_like(45) };
    is($b5, 'expires in 45s',
        'B5: fmt_oauth(45) eq "expires in 45s"');

    # B-ascii: all non-undef returns are ASCII-only (no multi-byte chars)
    for my $secs (-5, 0, 45, 3*3600+12*60) {
        my $r = eval { tui::DashboardScreen::_fmt_oauth_like($secs) };
        if (defined $r) {
            unlike($r, qr/[^\x20-\x7E]/,
                "B-ascii: fmt_oauth($secs) returns ASCII-only string");
        }
    }
}

# ---------------------------------------------------------------------------
# C1  The oauth line is ALWAYS present in the Sandbox panel — whether or not a
# token expiry is known — so activity capacity is 9 in BOTH cases. A known
# expiry shows the countdown; no token shows the actionable "not logged in"
# prompt (never silently dropped).
# ---------------------------------------------------------------------------
{
    # RE-DERIVED (package 06, Family 3, same reasoning/formula as PART 9's
    # _cap_expect): the literal 9 assumed the deleted Sandbox panel's fixed
    # height. Claim preserved verbatim -- "the oauth line is present whether
    # or not a token expiry is known, so the two capacities agree" -- by
    # asserting EQUALITY between the two derivations directly, which is
    # exactly that claim, rather than re-pinning whatever number the
    # dissolution happens to produce.
    my %st_oauth = (%st, oauth_remaining => 3*3600 + 12*60);
    is(Dashboard::activity_capacity(\%st_oauth, 24, 80), _cap_expect(\%st_oauth, 24, 80),
        'C1a: known expiry -> oauth line present -> capacity == the derivation (spec S5)');
    is(Dashboard::activity_capacity(\%st, 24, 80), Dashboard::activity_capacity(\%st_oauth, 24, 80),
        'C1b: no token (undef) -> oauth line STILL present -> capacity EQUALS the known-expiry case (the row always renders, just with a different value)');

    # s06-panel-semantics: panel lines are now arrayrefs-of-spans -- extract
    # text via Dashboard::spans_text before joining/regexing.
    my @panels_none = live_panels(\%st);
    my $panels_none = join("\n", map { Dashboard::spans_text($_) } map { @{ $_->{lines} } } @panels_none);
    like($panels_none, qr{oauth\s+not logged in \(run /login\)},
        'C1c: not-logged-in state renders the actionable oauth prompt');
    my @panels_oauth = live_panels(\%st_oauth);
    my $panels_oauth = join("\n", map { Dashboard::spans_text($_) } map { @{ $_->{lines} } } @panels_oauth);
    like($panels_oauth, qr{oauth\s+expires in 3h12m},
        'C1d: known expiry renders the countdown');
}

# ---------------------------------------------------------------------------
# D  Loop integration: oauth_expires_at in the gather hash -> "expires in 3h12m"
#    appears in the rendered Sandbox panel output.
#
# drive() already threads oauth_expires_at from %args into the gather hash.
# With seed clock=1000 and oauth_expires_at=12520, run() must compute
# oauth_remaining = 12520 - 1000 = 11520 = 3*3600+12*60 and render
# "expires in 3h12m" in the Sandbox panel.
# ---------------------------------------------------------------------------
{
    my $e = drive(
        keys           => ['q'],
        max_ticks      => 50,
        rows           => 30,
        oauth_expires_at => 12520,   # 1000 + 3*3600 + 12*60
    );
    is($e->{rc}, 0, 'D: loop with oauth_expires_at exits cleanly');
    like($e->{out}, qr/expires in 3h12m/,
        # Names the FRAME, not a panel: this matches the whole rendered output,
        # and the Sandbox panel it used to name was deleted by package 06
        # (spec S2.4.3). The mechanism was always frame-wide, so only the
        # description was wrong -- but a description naming a panel that no
        # longer exists sends the next reader looking for it.
        'D: rendered frame contains "expires in 3h12m" when oauth_expires_at set');
}

# ---------------------------------------------------------------------------
# M. _decode_str cannot spin, however this module was loaded.
#
#    This module's `require tui::Layout / tui::DashboardScreen / Theme` are
#    RUNTIME statements near the top; $UTF8_CHAR_RE is assigned further down;
#    and subs are installed at COMPILE time. So a failed require aborts the load
#    with every sub already in the symbol table and the pattern still undef. A
#    caller that wraps the require in eval and then probes
#    `defined &Dashboard::fit_spans` sees a healthy module and calls in.
#
#    With the pattern undef the match becomes `(?:)+`, which succeeds on the
#    empty string, so nothing is consumed and the while-loop never advances.
#    Measured on 2026-08-08: bp-statusline.pl exit 124 with 250 MB of stderr,
#    and a probe against the pre-fix source confirmed exit 124 while the fixed
#    source exits 0. So the hang was real and the fix is what changed it.
#
#    Asserted structurally. The behavioural form needs the module half-loaded,
#    which cannot be staged in-process ($UTF8_CHAR_RE is a file lexical, so no
#    caller can localise it), and staging it in a subprocess would put an
#    unbounded loop inside the suite on the very run where the guard regressed.
# ---------------------------------------------------------------------------
{
    my $dash_src = do {
        local (@ARGV, $/) = ("$Bin/../../scripts/Dashboard.pm"); <>
    };
    ok(defined $dash_src && length $dash_src, 'M1: Dashboard.pm source is readable');

    my ($body) = $dash_src =~ /sub\s+_decode_str\s*\{(.*?)\n\}/s;
    ok(defined $body, 'M2: located sub _decode_str');

    # ONE checker, applied to the live body AND to the pre-fix shape below.
    my $cannot_spin = sub {
        my ($b) = @_;
        return 0 unless defined $b;
        my $load_guard = $b =~ /!\s*defined\s+\$UTF8_CHAR_RE/       ? 1 : 0;
        # Match the guard itself, not what precedes it: the token before `&&` is
        # the match's closing regex delimiter, not a paren.
        my $adv_guard  = $b =~ /&&\s*length\s*\(\s*\$1\s*\)/        ? 1 : 0;
        return ($load_guard && $adv_guard) ? 1 : 0;
    };

    ok($cannot_spin->($body),
       'M3: _decode_str carries BOTH guards — it returns the bytes unchanged when '
     . 'the module never finished loading, and its match must consume at least one '
     . 'byte before the loop continues');

    # THE COUNTER-FIXTURE: the exact shape that shipped before the fix. If M3 can
    # pass against this, M3 is measuring nothing.
    my $prefix_body = <<'PREFIX';
    my ($str) = @_;
    return '' if !defined $str;
    return $str if $str =~ /[^\x00-\xFF]/;
    my $bytes = $str;
    my $out = '';
    while (length $bytes) {
        if ($bytes =~ /\A((?:$UTF8_CHAR_RE)+)/) {
            my $good = $1;
PREFIX
    ok(!$cannot_spin->($prefix_body),
       'M4: and the check fires — the pre-fix body, whose loop could consume zero '
     . 'bytes forever, is rejected by the same checker');

    # The guards must not have broken ordinary decoding.
    is(Dashboard::_decode_str("caf\xC3\xA9"), "caf\x{E9}",
       'M5: a valid UTF-8 sequence still decodes (the guards are not a bypass)');
    is(Dashboard::_decode_str("a\xFFb"), "a\x{FFFD}b",
       'M6: a malformed byte still becomes exactly one U+FFFD, one per bad byte');
}

done_testing();
