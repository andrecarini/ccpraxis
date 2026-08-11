#!/usr/bin/env perl
# 67-backpack-screen.t — ORACLE for package 07-backpack-screen (blueprint
# unified-tui-design-system), specs/07-backpack-screen-spec.md. Written BLIND
# to any tui/BackpackScreen.pm implementation -- it does not exist yet --
# directly from the spec's numbered observable behaviors (S3) and acceptance
# criteria (S4, AC-H/L/S/C/W/R/P). Do NOT weaken an assertion here to make a
# future implementation's life easier.
#
# TODAY'S EXPECTED STATE: plugins/sandbox/scripts/tui/BackpackScreen.pm does
# not exist yet. Every direct tui::BackpackScreen::* call below is gated on
# $BS_OK and SKIPs cleanly (not a fail, not a compile error) when it is
# false. Dashboard.pm, Theme.pm, BackpackApproval.pm and the tui/{Frame,
# Layout,Screen,DashboardScreen} modules ALREADY EXIST (shipped by earlier
# packages) and are called directly and unconditionally -- assertions against
# THOSE are expected to go RED TODAY for a WRONG VALUE (no 'b' branch in
# dispatch_key, no _assemble_esc sub, no backpack_screen seam wired into
# run(), no third/second \%err out-param on BackpackApproval::save/load)
# rather than a die, which is an equally valid RED signal.
#
# NON-VACUITY STRATEGY, applied uniformly (per this suite's established
# convention -- package 05's oracle shipped 423 assertions that could not
# fail; package 06's had two if-gated blocks that had never executed):
#   1. Count VALUE NONCES, never label words.
#   2. Every "== 1"/"== 0" count is preceded by a separately named "> 0"
#      liveness assertion.
#   3. Every negative assertion (unlike/no-row/absent) is paired with a
#      COUNTER-FIXTURE proving the SAME detector fires on a hand-built input
#      that SHOULD trip it.
#   4. Negatives are scoped to a VALUE (a span's role, a bounded token
#      extraction), never to a whole rendered line.
#   5. Decision 15 (no whole-shape pins) is enforced MECHANICALLY: AC-P8
#      greps this file's OWN source for `is(scalar(@` outside AC-R2's one
#      whitelisted frame-length identity, and for a whole-vocabulary
#      is_deeply.
#
# The module never touches the filesystem/process/clock/console (S2.0); this
# file therefore never needs launcher.pl, a container, or a real terminal --
# and AC-P7 below asserts, by scanning ITS OWN source, that it never gained
# one.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use JSON::PP ();

my $SCRIPTS   = "$Bin/../../scripts";
my $TUI_DIR      = "$SCRIPTS/tui";
my $BS_PM        = "$TUI_DIR/BackpackScreen.pm";
my $DASHBOARD_PM = "$SCRIPTS/Dashboard.pm";
my $SELF_PATH    = "$Bin/67-backpack-screen.t";

use lib "$Bin/../../scripts";

# ===========================================================================
# Scaffolding
# ===========================================================================

# slurp($path) -> file contents as raw bytes, or undef.
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# _write($path, $content) -> write bytes to a File::Temp-owned path.
sub _write {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print $fh $content;
    close $fh;
}

# _comment_stripped($src) -> $src with whole-line `#` comments blanked
# (spec's "blank comments before any source scan" -- this has bitten the
# suite repeatedly; same shape as t/65/t/66's own helper).
sub _comment_stripped {
    my ($src) = @_;
    return join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1);
}

# ===========================================================================
# Load attempts. Dashboard/Theme/BackpackApproval/tui::{Layout,Frame,Screen,
# DashboardScreen} ship from earlier packages and MUST already be loadable;
# tui::BackpackScreen is THIS package's new file and is not expected to
# exist yet.
# ===========================================================================
my $DASH_OK = eval { require Dashboard; 1 };
ok($DASH_OK, 'plugins/sandbox/scripts/Dashboard.pm loads') or diag("  require Dashboard failed: $@");
my $THEME_OK = eval { require Theme; 1 };
ok($THEME_OK, 'plugins/sandbox/scripts/Theme.pm loads') or diag("  require Theme failed: $@");
my $BA_OK = eval { require BackpackApproval; 1 };
ok($BA_OK, 'plugins/sandbox/scripts/BackpackApproval.pm loads') or diag("  require BackpackApproval failed: $@");
my $BO_OK = eval { require BackpackOps; 1 };
ok($BO_OK, 'plugins/sandbox/scripts/BackpackOps.pm loads') or diag("  require BackpackOps failed: $@");
my $LAYOUT_OK = eval { require tui::Layout; 1 };
ok($LAYOUT_OK, 'plugins/sandbox/scripts/tui/Layout.pm loads (package 05, shipped)') or diag("  require tui::Layout failed: $@");
my $FRAME_OK = eval { require tui::Frame; 1 };
ok($FRAME_OK, 'plugins/sandbox/scripts/tui/Frame.pm loads (package 05, shipped)') or diag("  require tui::Frame failed: $@");
my $SCREEN_OK = eval { require tui::Screen; 1 };
ok($SCREEN_OK, 'plugins/sandbox/scripts/tui/Screen.pm loads (package 05, shipped)') or diag("  require tui::Screen failed: $@");
my $DS_OK = eval { require tui::DashboardScreen; 1 };
ok($DS_OK, 'plugins/sandbox/scripts/tui/DashboardScreen.pm loads (package 06, shipped)') or diag("  require tui::DashboardScreen failed: $@");

my $BS_OK = eval { require tui::BackpackScreen; 1 };
ok($BS_OK, 'plugins/sandbox/scripts/tui/BackpackScreen.pm loads (THIS package -- expected to fail until 07 lands)')
    or diag("  require tui::BackpackScreen failed: $@");

BAIL_OUT('Dashboard.pm did not load -- nothing below can mean anything') unless $DASH_OK;

# drive_bp(%args) -> \%eff -- build a Dashboard::run() invocation over
# injected seams, same shape as t/25-dashboard.t's own drive() helper (this
# suite's established convention), extended with the backpack seams S2.3
# adds (backpack_screen/bp_load/bp_save/bp_remove) and an ARRAY of every
# `out` payload (not just the joined string) so a test can inspect "the
# very next payload" (AC-H4) distinctly from later ones.
sub drive_bp {
    my (%args) = @_;
    my @keys = @{ $args{keys} || [] };
    my $clock = 1000;
    my %eff = (heartbeats => 0, spawns => 0, gathers => 0, frames => 0,
               bp_screen_calls => 0, bp_screen_ctxs => []);
    my @frames;

    my $rc = Dashboard::run(
        beat_interval   => $args{beat_interval}  // 1,
        state_interval  => $args{state_interval} // 0,
        tick_interval   => 0.25,
        color           => 0,
        max_ticks       => $args{max_ticks} // 20,
        now             => sub { $clock },
        sleep_for       => sub { $clock += $_[0]; },
        read_key        => sub { @keys ? shift @keys : undef },
        term_size       => sub { ($args{cols} // 60, $args{rows} // 24) },
        gather          => sub { $eff{gathers}++;
                                  { project_name => 'demo', container => 'c1',
                                    status => ($args{status} // 'running'),
                                    events => ($args{events} // []) } },
        heartbeat       => sub { $eff{heartbeats}++; 'ok' },
        spawn           => sub { $eff{spawns}++; undef },
        enter_raw       => sub { $eff{entered} = ($eff{entered} || 0) + 1 },
        leave_raw       => sub { $eff{left}    = ($eff{left}    || 0) + 1 },
        out             => sub { push @frames, $_[0]; $eff{frames}++ },
        (exists $args{backpack_screen} ? (backpack_screen => $args{backpack_screen}) : ()),
        (exists $args{bp_load}         ? (bp_load         => $args{bp_load})         : ()),
        (exists $args{bp_save}         ? (bp_save         => $args{bp_save})         : ()),
        (exists $args{bp_remove}       ? (bp_remove       => $args{bp_remove})       : ()),
    );
    $eff{rc}     = $rc;
    $eff{frames_list} = \@frames;
    $eff{out}    = join('', @frames);
    return \%eff;
}

# ===========================================================================
# AC-H -- the hand-off (criterion 1)
# ===========================================================================

# --- AC-H1: behaviour 1 and 3 -- is_deeply over 5 (key,pending) pairs. ---
is_deeply([ Dashboard::dispatch_key('b', '') ], [ 'backpack', '' ],
    "AC-H1: dispatch_key('b','') -> ('backpack','')");
is_deeply([ Dashboard::dispatch_key('B', '') ], [ '', '' ],
    "AC-H1: dispatch_key('B','') -> ('','') -- uppercase is NOT a hotkey here");
is_deeply([ Dashboard::dispatch_key('z', '') ], [ '', '' ],
    "AC-H1: dispatch_key('z','') -> ('','') -- unchanged baseline");
is_deeply([ Dashboard::dispatch_key('b', 'stop-runs') ], [ 'cancel-stop-runs', '' ],
    "AC-H1: dispatch_key('b','stop-runs') -> ('cancel-stop-runs','') -- b cancels an armed confirm");
is_deeply([ Dashboard::dispatch_key('b', 'relaunch') ], [ 'cancel-relaunch', '' ],
    "AC-H1: dispatch_key('b','relaunch') -> ('cancel-relaunch','')");

# --- AC-H2: the :2024 landmine, asserted as a property over a corpus, plus
# a counter-fixture (AC-H2b) proving the checker can fire. ---
{
    my @keys = ('a'..'z', 'A'..'Z', '0'..'9', 'UP', 'DOWN', "\r", "\n", "\e", '', 'y', 'Y');
    my @pendings = ('', 'stop-runs', 'full-shutdown', 'relaunch', 'bogus');

    my $checker = sub {
        my ($dispatch) = @_;
        my $violations = 0;
        my $first;
        for my $p (@pendings) {
            for my $k (@keys) {
                my ($action, $np) = $dispatch->($k, $p);
                next unless defined $np && length $np;
                my ($confirm_action) = $dispatch->('y', $np);
                if (!defined $confirm_action || $confirm_action eq '') {
                    $violations++;
                    $first ||= "key='$k' pending='$p' new_pending='$np'";
                }
            }
        }
        return ($violations, $first);
    };

    my ($unconfirmable, $first_bad) = $checker->(\&Dashboard::dispatch_key);
    is($unconfirmable, 0,
        'AC-H2: every non-empty pending token dispatch_key arms is confirmable by (y, $token)')
        or diag("  first offending pair: " . ($first_bad // '(none captured)'));

    # AC-H2b -- counter-fixture: a stub that arms an unconfirmable token MUST
    # be caught by the identical checker. Without this the checker could be
    # blind (e.g. always returning 0). NOTE (documented spec-text defect,
    # same class as 06's AC-F1/AC-F2 duration-regex note): the spec's own
    # literal illustration `sub { return ('confirm-zz','zz-token') }`
    # ignores its arguments entirely, so calling it as the CONFIRM check
    # `dispatch->('y', $t)` also returns the non-empty action 'confirm-zz'
    # -- under the property exactly as stated ("dispatch_key('y',$t))[0]
    # is non-empty" => no violation), that literal stub can never be
    # flagged, contradicting the spec's own "reports 1 violation" claim.
    # This fixture instead arms 'zz-token' for every key EXCEPT 'y', and on
    # 'y' returns an EMPTY action -- an actual landmine: a token that once
    # armed can never be confirmed. Asserted as "> 0", not "== 1" (the
    # corpus has more than one (key,pending) pair that arms it).
    my $unconfirmable_stub = sub {
        my ($key, $pending) = @_;
        return ('', '') if $key eq 'y';
        return ('confirm-zz', 'zz-token');
    };
    my ($stub_violations, undef) = $checker->($unconfirmable_stub);
    ok($stub_violations > 0,
        'AC-H2b (counter-fixture): a stub arming an unfireable token IS caught by the checker')
        or diag("  stub_violations = $stub_violations");
}

# --- AC-H3: behaviour 4 -- driving Dashboard::run with 'b' scripted and an
# injected backpack_screen seam invokes it exactly once; run returns 0 with
# enter_raw/leave_raw called once each. ---
{
    my $bp_calls = 0;
    my $eff = drive_bp(
        keys            => ['b'],
        max_ticks       => 3,
        backpack_screen => sub { $bp_calls++; return {}; },
    );
    is($bp_calls, 1, 'AC-H3: the backpack_screen seam is invoked exactly once for one b press');
    is($eff->{rc}, 0, 'AC-H3: run() returns 0 after a b press opens and closes the modal');
    is($eff->{entered}, 1, 'AC-H3: enter_raw is called exactly once');
    is($eff->{left},    1, 'AC-H3: leave_raw is called exactly once');
}

# --- AC-H4: behaviour 5 -- the out payload emitted immediately after the
# seam returns is a FULL repaint (contains "\e[2J"). Captures the frame
# index AT THE MOMENT the seam is invoked (from inside the seam itself),
# so this is robust regardless of how many other `out` calls (OSC title,
# heartbeats) precede it -- never a guessed fixed index. AC-H4b (counter-
# fixture): render_frame for two frames differing in exactly one row
# contains NO "\e[2J" -- proving the marker discriminates. ---
{
    my @frames;
    my $bp_calls = 0;
    my $index_at_call;
    my $clock = 1000;
    my @keys = ('b');
    my $rc = Dashboard::run(
        beat_interval   => 1, state_interval => 0, tick_interval => 0.25, color => 0,
        max_ticks       => 3,
        now             => sub { $clock },
        sleep_for       => sub { $clock += $_[0]; },
        read_key        => sub { @keys ? shift @keys : undef },
        term_size       => sub { (60, 24) },
        gather          => sub { { project_name => 'demo', container => 'c1', status => 'running', events => [] } },
        heartbeat       => sub { 'ok' },
        spawn           => sub { undef },
        enter_raw       => sub { },
        leave_raw       => sub { },
        out             => sub { push @frames, $_[0]; },
        backpack_screen => sub { $bp_calls++; $index_at_call = scalar(@frames); return {}; },
    );
    my $post_modal_payload = (defined $index_at_call && defined $frames[$index_at_call])
        ? $frames[$index_at_call] : '';
    # NOTE (test-defect fix): qr/\Q\e[2J\E/ is unsatisfiable by any correct
    # implementation. Inside \Q...\E, \e is NOT interpolated to an ESC byte
    # before quotemeta runs (quotemeta sees the two literal characters
    # backslash-then-e and escapes the backslash), so the compiled pattern
    # matches the SOURCE TEXT "\e[2J", never a real ESC byte -- driver-
    # verified: "\x1b[2J" =~ qr/\Q\e[2J\E/ is false. index() sidesteps the
    # \Q...\E trap entirely; the claim (a full repaint marker follows the
    # modal) is unchanged.
    ok(index($post_modal_payload, "\e[2J") >= 0,
        'AC-H4: the payload right after the modal seam returns is a full repaint');

    # AC-H4b -- counter-fixture.
    my $cell_a = { text => 'AAAA', role => 'text.primary', spans => [ { text => 'AAAA', role => 'text.primary' } ] };
    my $cell_b = { text => 'BBBB', role => 'text.primary', spans => [ { text => 'BBBB', role => 'text.primary' } ] };
    my $cell_c = { text => 'CCCC', role => 'text.primary', spans => [ { text => 'CCCC', role => 'text.primary' } ] };
    my $f1 = [ $cell_a, $cell_c ];
    my $f2 = [ $cell_b, $cell_c ];   # differs in exactly one row
    my $incremental = Dashboard::render_frame($f1, $f2, { color => 0 });
    ok(index($incremental, "\e[2J") < 0,
        'AC-H4b (counter-fixture): an ordinary one-row-changed repaint carries NO full-repaint marker');
}

# --- AC-H5: behaviour 6 -- the loop keeps ticking: modal seam invoked once,
# spawn seam invoked once, for keys ('b','c'). ---
{
    my $bp_calls = 0;
    my $eff = drive_bp(
        keys            => ['b', 'c'],
        max_ticks       => 4,
        backpack_screen => sub { $bp_calls++; return {}; },
    );
    is($bp_calls,        1, 'AC-H5: modal seam invoked exactly once');
    is($eff->{spawns},   1, 'AC-H5: spawn seam invoked exactly once -- the loop dispatches c AFTER the modal returns');
}

# --- AC-H6: behaviour 7 -- a dying modal seam does not kill the dashboard;
# run still returns 0, leave_raw is still called once, and the composed
# banner names the failure. ---
{
    my $nonce = 'zqxdiebp8231';
    my $eff = drive_bp(
        keys            => ['b'],
        max_ticks       => 3,
        backpack_screen => sub { die "$nonce\n"; },
    );
    is($eff->{rc}, 0, 'AC-H6: run() still returns 0 after a dying modal seam');
    is($eff->{left}, 1, 'AC-H6: leave_raw is still called exactly once');
    like($eff->{out}, qr/\Q$nonce\E/, 'AC-H6: the composed frame after the dying seam names the failure');
}

# --- AC-H7: Dashboard::_assemble_esc's table, seven arms, each its own
# assertion. Guarded: the sub does not exist until S2.3's extraction lands. ---
{
    my $has_assemble = defined &Dashboard::_assemble_esc;
    ok($has_assemble, 'AC-H7: Dashboard::_assemble_esc exists (extracted per S2.3)');
  SKIP: {
        skip('Dashboard::_assemble_esc does not exist yet', 6) unless $has_assemble;
        is(Dashboard::_assemble_esc('x', sub { undef }), 'x',
            'AC-H7: a non-ESC key passes through unchanged');
        my @feed_a = ('[', 'A');
        is(Dashboard::_assemble_esc("\e", sub { @feed_a ? shift @feed_a : undef }), 'UP',
            'AC-H7: ESC [ A assembles to UP');
        my @feed_b = ('[', 'B');
        is(Dashboard::_assemble_esc("\e", sub { @feed_b ? shift @feed_b : undef }), 'DOWN',
            'AC-H7: ESC [ B assembles to DOWN');
        my @feed_c = ('[', 'C');
        is(Dashboard::_assemble_esc("\e", sub { @feed_c ? shift @feed_c : undef }), undef,
            'AC-H7: ESC [ C (an unrecognised final letter) assembles to undef');
        is(Dashboard::_assemble_esc("\e", sub { undef }), "\e",
            'AC-H7: a lone ESC (nothing more to read) stays "\\e"');
        my @feed_z = ('z');
        is(Dashboard::_assemble_esc("\e", sub { @feed_z ? shift @feed_z : undef }), 'z',
            'AC-H7: ESC + a non-CSI byte surfaces that byte (Alt+key)');
        is(Dashboard::_assemble_esc(undef, sub { undef }), undef,
            'AC-H7: undef key -> undef');
    }
}

# ===========================================================================
# AC-L -- the listing and the scroll (criterion 2)
# ===========================================================================

# _bp_thin_items($n) -> arrayref of $n THIN gather-shaped items (S2.1's
# second table row: {key,approved}, item=>undef). Used throughout AC-L so
# listing/scroll tests never depend on BackpackApproval's hash machinery
# (that is AC-S/AC-W's job).
sub _bp_thin_items {
    my ($n) = @_;
    return [ map { { key => sprintf('itk%02d', $_), approved => ($_ % 2 == 0) ? 1 : 0 } } (1 .. $n) ];
}

# _bp_joined($ss,$rows,$cols) -> the plain-text concatenation of every
# composed cell's text, in row order.
sub _bp_joined {
    my ($ss, $rows, $cols) = @_;
    my $frame = tui::BackpackScreen::compose($ss, $rows, $cols);
    return join('', map { defined($_->{text}) ? $_->{text} : '' } @$frame);
}

# _bp_list_text($ss,$rows,$cols) -> the plain-text concatenation of ONLY the
# panel-body cells of the composed frame -- the item list, its summary row,
# and the detail panel -- with the title row, every banner row, and the
# footer row excluded. Grounded in spec S2.4.5, verbatim: "compose(ss,rows,
# cols) = tui::Screen::compose(screen(ss,cols), rows, cols)" and "05's
# degradation ladder ... banners dropped from the end first" -- i.e.
# tui::Screen::compose's cell order is fixed as
# [ title_cell, @banner_cells, @body_cells, footer_cell ], and the number of
# banner cells is exactly scalar(@{ banners($ss) }) (S2.4.5 #1: "banners(ss)
# ... at most two"). This is what lets AC-S3/AC-C5/AC-W8 test the real
# claim -- "the dropped item is gone from the LIST" -- without also
# scanning the banner row, which S2.4.4's status table separately REQUIRES
# to name the verb and the item key (an ok/failed banner). Scanning the
# whole frame for absence of the key is unsatisfiable together with that
# requirement; scanning only the body is the standing rule "negatives are
# scoped to a VALUE, never to a whole rendered line" applied one level up,
# at the frame level rather than the single-row level.
sub _bp_list_text {
    my ($ss, $rows, $cols) = @_;
    my $frame = tui::BackpackScreen::compose($ss, $rows, $cols);
    my $nb    = scalar(@{ tui::BackpackScreen::banners($ss) });
    my $last  = $#$frame;
    my $lo    = 1 + $nb;          # past the title cell and every banner cell
    my $hi    = $last - 1;        # before the footer cell
    return '' if $lo > $hi;
    return join('', map { defined($_->{text}) ? $_->{text} : '' } @{$frame}[$lo .. $hi]);
}

# _bp_row_cell($cells, $needle) -> the first cell whose text contains
# $needle, or undef.
sub _bp_row_cell {
    my ($cells, $needle) = @_;
    for my $c (@$cells) {
        next unless defined $c->{text} && index($c->{text}, $needle) >= 0;
        return $c;
    }
    return undef;
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 14) unless $BS_OK;

    # --- AC-L1: behaviour 8, table-driven over S2.1's row model. ---
    my $full_item = { category => 'cat', name => 'zqxfull7714', install => 'echo hi', verify => 'true', rationale => 'because' };
    my %appr_full = ( BackpackApproval::item_key($full_item) => BackpackApproval::item_hash($full_item) );
    my $r_full = tui::BackpackScreen::rows([ $full_item ], \%appr_full);
    is($r_full->[0]{key}, BackpackApproval::item_key($full_item), 'AC-L1: full item key is item_key(...)');
    is($r_full->[0]{approved}, 1, 'AC-L1: full item approved via is_approved(...)');
    is($r_full->[0]{item}, $full_item, 'AC-L1: full item row carries the item itself');

    my $thin_item = { key => 'zqxthin7714', approved => 1 };
    my $r_thin = tui::BackpackScreen::rows([ $thin_item ], {});
    is($r_thin->[0]{key}, 'zqxthin7714', 'AC-L1: thin item key is $it->{key}');
    is($r_thin->[0]{approved}, 1, 'AC-L1: thin item approved via $it->{approved}');
    is($r_thin->[0]{item}, undef, 'AC-L1: thin item row carries item=>undef');

    my $r_scalar = tui::BackpackScreen::rows([ 'not-a-hashref' ], {});
    is($r_scalar->[0]{key}, '?', "AC-L1: a non-hashref element maps to key '?'");
    is($r_scalar->[0]{approved}, 0, 'AC-L1: a non-hashref element maps to approved=0');
    is($r_scalar->[0]{item}, undef, 'AC-L1: a non-hashref element maps to item=>undef');

    my $r_empty = tui::BackpackScreen::rows([ {} ], {});
    is($r_empty->[0]{key}, '?', "AC-L1: an empty hash element maps to key '?'");
    is($r_empty->[0]{approved}, 0, 'AC-L1: an empty hash element maps to approved=0');
    is($r_empty->[0]{item}, undef, 'AC-L1: an empty hash element maps to item=>undef');

    is_deeply(tui::BackpackScreen::rows(undef, {}), [], 'AC-L1: a non-arrayref \@items -> []');

    my @order_fixture = ( { key => 'zqx-a', approved => 0 }, { key => 'zqx-b', approved => 1 }, { key => 'zqx-c', approved => 0 } );
    my $r_order = tui::BackpackScreen::rows(\@order_fixture, {});
    is_deeply([ map { $_->{key} } @$r_order ], [ 'zqx-a', 'zqx-b', 'zqx-c' ],
        'AC-L1: row order is input order, never re-sorted');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 14) unless $BS_OK;

    # --- AC-L2: behaviour 9 -- 7 items, frame large enough to hold them all,
    # each key appears exactly once; a key not in the fixture appears zero
    # times (AC-L2b, folded in here for the same fixture). ---
    my $items = _bp_thin_items(7);
    my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
    my $joined = _bp_joined($ss, 40, 120);

    for my $it (@$items) {
        my $key = $it->{key};
        my $n = () = $joined =~ /\Q$key\E/g;
        ok($n > 0, "AC-L2: key $key is present at least once (liveness)");
        is($n, 1, "AC-L2: key $key appears in the composed frame exactly once");
    }
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 1) unless $BS_OK;
    # --- AC-L2b: the counter-fixture -- a nonce absent from the fixture
    # counts zero times. ---
    my $items = _bp_thin_items(7);
    my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
    my $joined = _bp_joined($ss, 40, 120);
    my $nonce = 'zqxnope7714';
    my $n = () = $joined =~ /\Q$nonce\E/g;
    is($n, 0, 'AC-L2b (counter-fixture): a key absent from the fixture is counted zero times');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 4) unless $BS_OK;
    # --- AC-L3: behaviour 10 -- role/text asserted by EXACT value, never a
    # regex over a rendered line (05's /\bwarn\b/ mistake). ---
    my $items = [ { key => 'zqxapproved7714', approved => 1 }, { key => 'zqxpending7714', approved => 0 } ];
    my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
    my $cells = tui::BackpackScreen::compose($ss, 40, 120);

    my $approved_cell = _bp_row_cell($cells, 'zqxapproved7714');
    my $pending_cell  = _bp_row_cell($cells, 'zqxpending7714');

    SKIP: {
        skip('the approved-item row did not render', 2) unless $approved_cell;
        my ($state_span) = grep { $_->{role} eq tui::BackpackScreen::STATE_ROLE(1) } @{ $approved_cell->{spans} || [] };
        ok(defined $state_span, 'AC-L3: the approved row carries a span with role STATE_ROLE(1)');
        like(($state_span->{text} // ''), qr/\Q@{[ tui::BackpackScreen::STATE_LABEL(1) ]}\E/,
            'AC-L3: that span text contains STATE_LABEL(1)');
    }
    SKIP: {
        skip('the pending-item row did not render', 2) unless $pending_cell;
        my ($state_span) = grep { $_->{role} eq tui::BackpackScreen::STATE_ROLE(0) } @{ $pending_cell->{spans} || [] };
        ok(defined $state_span, 'AC-L3: the pending row carries a span with role STATE_ROLE(0)');
        like(($state_span->{text} // ''), qr/\Q@{[ tui::BackpackScreen::STATE_LABEL(0) ]}\E/,
            'AC-L3: that span text contains STATE_LABEL(0)');
    }
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 3) unless $BS_OK;
    # --- AC-L4: behaviour 11 -- scrolling is real. 40 items, a viewport
    # smaller than 40. ---
    my $items = _bp_thin_items(40);
    my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
    my $first_key = $items->[0]{key};
    my $last_key  = $items->[-1]{key};

    $ss->{cursor} = 0;
    my $joined_top = _bp_joined($ss, 20, 80);
    unlike($joined_top, qr/\Q$last_key\E/, 'AC-L4: at cursor 0 the last item is scrolled off (absent)');
    like($joined_top, qr/\Q$first_key\E/, 'AC-L4: at cursor 0 the first item is visible');

    $ss->{cursor} = 39;
    my $joined_bottom = _bp_joined($ss, 20, 80);
    like($joined_bottom, qr/\Q$last_key\E/, 'AC-L4: at cursor 39 the last item is visible');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 2) unless $BS_OK;
    # --- AC-L5: behaviour 12 -- the selected row is never off-screen, over
    # 4 (rows,cols) pairs x 40 cursor positions, aggregated. AC-L5b: the
    # same predicate applied to a nonce key reports "absent". ---
    my $items = _bp_thin_items(40);
    my @pairs = ( [24,80], [24,120], [10,60], [30,200] );
    my $misses = 0;
    my $first_miss;
    for my $pair (@pairs) {
        my ($rows, $cols) = @$pair;
        for my $cur (0 .. 39) {
            my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
            $ss->{cursor} = $cur;
            my $joined = _bp_joined($ss, $rows, $cols);
            my $key = $items->[$cur]{key};
            unless ($joined =~ /\Q$key\E/) {
                $misses++;
                $first_miss ||= "rows=$rows cols=$cols cursor=$cur key=$key";
            }
        }
    }
    is($misses, 0, 'AC-L5: the selected row is always inside the rendered frame')
        or diag("  first miss: " . ($first_miss // '(none captured)'));

    # AC-L5b -- counter-fixture: a nonce key not in the fixture IS reported absent.
    my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
    $ss->{cursor} = 0;
    my $joined = _bp_joined($ss, 24, 80);
    ok($joined !~ /zqxabsentcursor7714/, 'AC-L5b (counter-fixture): a nonce key IS reported absent by the same predicate');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 3) unless $BS_OK;
    # --- AC-L6: behaviour 13 -- window() is a derivation of
    # tui::Screen::viewport, at three (rows,cols) pairs covering both
    # arrangements. ---
    my $items = _bp_thin_items(15);
    for my $pair ( [24,80], [24,100], [10,60] ) {
        my ($rows, $cols) = @$pair;
        my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
        $ss->{cursor} = 3;
        my $got = tui::BackpackScreen::window($ss, $rows, $cols);
        my $lh  = tui::BackpackScreen::list_height($rows, $cols, scalar(@{ tui::BackpackScreen::banners($ss) }),
                                                     (@{ $ss->{rows} } ? 1 : 0));
        my $expected = tui::Screen::viewport(scalar(@{ $ss->{rows} }), $lh, $ss->{cursor});
        is_deeply($got, $expected, "AC-L6: window() derives viewport() at rows=$rows cols=$cols");
    }
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 3) unless $BS_OK;
    # --- AC-L7: behaviour 14 -- the screen's summary row and the dashboard
    # summary agree, computed through BOTH producing functions, never
    # through pinned numbers. ---
    my $items = [ map { { key => "zqxc$_", approved => ($_ <= 3) ? 1 : 0 } } (1 .. 5) ];
    my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
    my $counts = tui::BackpackScreen::counts($ss->{rows});
    my $summary_joined = _bp_joined($ss, 40, 120);

    my $dash_spans = tui::DashboardScreen::backpack_summary_spans($counts);
    my $dash_text  = tui::Frame::spans_text($dash_spans);

    like($summary_joined, qr/\Q$counts->{total}\E items/, 'AC-L7: the screen summary row states the total count');
    like($dash_text, qr/\Q$counts->{total}\E items/, "AC-L7: tui::DashboardScreen::backpack_summary_spans states the SAME total, from the SAME counts");
    like($dash_text, qr/\Q$counts->{approved}\E approved/, 'AC-L7: both surfaces state the same approved count');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 1) unless $BS_OK;
    # --- AC-L8: row order is input order -- a derivation from the fixture,
    # never a literal. ---
    my $items = _bp_thin_items(9);
    my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
    my $cells = tui::BackpackScreen::compose($ss, 40, 120);
    my @found_order;
    for my $it (@$items) {
        for my $c (@$cells) {
            if (defined $c->{text} && index($c->{text}, $it->{key}) >= 0) {
                push @found_order, $it->{key};
                last;
            }
        }
    }
    is_deeply(\@found_order, [ map { $_->{key} } @$items ],
        'AC-L8: the sequence of keys found in row order equals the fixture order');
}

# ===========================================================================
# AC-S -- persistence through the existing seams (criterion 3)
# ===========================================================================

# _bp_run(%seams_with_keys) -> ($result, \@captured_frames). `keys` (an
# arrayref) drives read_key; `render` is overridden to CAPTURE the actual
# \@frame arrayref (not the bytes render() would normally produce) so a
# test can inspect roles/text directly without re-deriving them from ANSI
# bytes -- render's own contract (S2.4.1) is `->(\@prev|undef,\@frame) ->
# bytes`; nothing requires the coderef to actually MAKE bytes, only that it
# be a coderef, so this is a legitimate seam substitution, not a cheat.
#
# `wait_keys` (test-defect fix, MEDIUM-2/type-ahead-drain harness gap):
# an OPTIONAL second arrayref. Without it, `_bp_run` behaves exactly as
# before -- `read_key` alone, no `wait_key` seam, so an exhausted `keys`
# queue ends the loop via run()'s own "no input source at all" rule
# (S2.4.1: "a poll yields nothing and wait_key is not a coderef" ->
# terminate). That shape makes 'd' and a queued 'y' STRUCTURALLY
# ADJACENT -- both come off the same `read_key` queue with nothing between
# them -- which is indistinguishable from genuine type-ahead queued BEFORE
# the operator could have seen DROP_WARNING(), and run()'s post-arm drain
# (S2.4.1/MEDIUM-2) correctly eats it. That is not a harness bug; it is
# the harness correctly modelling the no-gap case (claim (b), see AC-C6
# below). To model a REAL gap -- a keystroke that arrives strictly AFTER
# the confirm has armed and the drain has already run its course, i.e. the
# operator saw the warning THEN pressed a key -- pass `wait_keys`: it
# becomes the `wait_key => ->($secs)` seam (S2.4.1's own "blocking-with-
# timeout" contract, "production always passes wait_key, so an idle
# dashboard modal never self-closes", spec line 289/301-303). The confirm-
# arm's drain only ever calls `read_key` directly (never `wait_key`), so a
# key supplied via `wait_keys` is NEVER visible to the drain -- it can only
# be observed by the *next* iteration of run()'s own loop, which is
# exactly "a later, separate keystroke" and nothing else. Bounded by
# max_ticks (default 50 once wait_keys is used, generous but finite) so an
# exhausted wait_keys queue (endless undef) cannot hang the test.
sub _bp_run {
    my (%args) = @_;
    my @keys = @{ delete $args{keys} || [] };
    my $wait_keys = delete $args{wait_keys};
    my @frames;
    my %run_args = %args;
    if (defined $wait_keys) {
        my @wq = @$wait_keys;
        $run_args{wait_key}  = sub { @wq ? shift @wq : undef };
        $run_args{max_ticks} = $args{max_ticks} // 50;
    }
    my $result = tui::BackpackScreen::run(
        %run_args,
        read_key => sub { @keys ? shift @keys : undef },
        render   => sub { push @frames, $_[1]; return ''; },
        out      => sub { },
    );
    return ($result, \@frames);
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 6) unless $BS_OK;
    # --- AC-S1: behaviour 15 -- 'a' on a pending row with a save seam. ---
    my $item = { category => 'cat', name => 'zqxs1', install => 'echo hi', verify => 'true' };
    my @save_calls;
    my ($result, $frames) = _bp_run(
        items => [ $item ], approvals => {},
        save  => sub { push @save_calls, { %{ $_[0] } }; return (1, {}); },
        keys  => [ 'a', 'q' ],
    );
    ok(scalar(@save_calls) > 0, 'AC-S1: the save seam fired at least once (liveness)');
    is(scalar(@save_calls), 1, 'AC-S1: the save seam was called exactly once');
    is($save_calls[0]{ BackpackApproval::item_key($item) }, BackpackApproval::item_hash($item),
        'AC-S1: the approvals hash now maps the key to BackpackApproval::item_hash($item)');
    is($result->{approved}, 1, 'AC-S1: %result{approved} is 1');
    my $cell = _bp_row_cell($frames->[-1] || [], BackpackApproval::item_key($item));
    ok(defined $cell, 'AC-S1: the approved row renders in the final frame');
  SKIP: {
        skip('the row did not render', 1) unless $cell;
        ok((grep { $_->{role} eq tui::BackpackScreen::STATE_ROLE(1) } @{ $cell->{spans} || [] }),
            'AC-S1: the row now carries role STATE_ROLE(1)');
    }
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 2) unless $BS_OK;
    # --- AC-S2: behaviour 16 -- 'a' on an already-approved row: save called
    # zero times, kind noop (decision A's nothing-to-do arm). ---
    my $item = { category => 'cat', name => 'zqxs2', install => 'x', verify => 'y' };
    my %appr = ( BackpackApproval::item_key($item) => BackpackApproval::item_hash($item) );
    my @save_calls;
    my ($result, undef) = _bp_run(
        items => [ $item ], approvals => \%appr,
        save  => sub { push @save_calls, 1; return (1, {}); },
        keys  => [ 'a', 'q' ],
    );
    is(scalar(@save_calls), 0, 'AC-S2: the save seam is called zero times for an already-approved row');
    is($result->{status}{kind}, 'noop', 'AC-S2: the status kind is noop');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 7) unless $BS_OK;
    # --- AC-S3: behaviour 17 -- 'd' then, after a GENUINE gap, 'y', with a
    # remove seam.
    #
    # Test-defect fix (MEDIUM-2/type-ahead-drain): this used to script 'd'
    # and 'y' back to back on the SAME read_key queue (keys => ['d','y',
    # 'q']). That shape is indistinguishable from type-ahead queued BEFORE
    # the operator could possibly have seen DROP_WARNING() -- run()'s own
    # post-arm drain (S2.4.1) correctly eats a 'y' with nothing between it
    # and the 'd' that armed the confirm, and the remove seam correctly
    # never fired. The bug was in THIS TEST'S assumption, not in run(): it
    # asserted the fire-after-confirm claim (a) using a fixture that
    # actually exercises the no-gap claim (b) instead (see AC-C6, below,
    # for (b) itself). Modelled here as intended -- claim (a), "a confirm
    # that follows the warning DOES fire" -- by putting 'd' on read_key and
    # 'y'+'q' behind wait_keys, so the drain (which only ever calls
    # read_key, never wait_key) has nothing to eat, and 'y' is only ever
    # observed by run()'s NEXT loop iteration -- a later, separate
    # keystroke by construction, per _bp_run's header comment. ---
    my $item = { category => 'cat', name => 'zqxs3', install => 'x', verify => 'y' };
    my %appr = ( BackpackApproval::item_key($item) => BackpackApproval::item_hash($item) );
    my (@remove_calls, @save_calls);
    my ($result, $frames) = _bp_run(
        items     => [ $item ], approvals => \%appr,
        remove    => sub { push @remove_calls, $_[0]; return (1, {}); },
        save      => sub { push @save_calls, { %{ $_[0] } }; return (1, {}); },
        keys      => [ 'd' ],
        wait_keys => [ 'y', 'q' ],
    );
    is(scalar(@remove_calls), 1, 'AC-S3: the remove seam was called exactly once (confirm AFTER a genuine gap fires -- claim (a))');
    is($remove_calls[0], $item, 'AC-S3: the remove seam received the item HASHREF ITSELF (identity)');
    is(scalar(@save_calls), 1, 'AC-S3: the save seam was called once (approval cleanup)');
    ok(!exists $save_calls[0]{ BackpackApproval::item_key($item) },
        'AC-S3: forget() removed the key from the approvals hash handed to save');
    is($result->{dropped}, 1, 'AC-S3: %result{dropped} is 1');

    # Re-scoped (test-defect fix -- was a whole-frame scan; see
    # _bp_list_text's header comment). Drive an IDENTICAL fixture directly
    # through init/dispatch_key/apply (the same idiom AC-C1..AC-C5 already
    # use) so $ss is in hand and the list body can be isolated from the
    # banner. S2.4.4's status table REQUIRES the ok-kind banner to name the
    # verb and the item key, so a whole-frame absence check is
    # unsatisfiable together with that requirement (see also AC-W8, below).
    my $seams2 = {
        items => [ $item ], approvals => { %appr },
        remove => sub { return (1, {}); },
        save   => sub { return (1, {}); },
    };
    my $ss2 = tui::BackpackScreen::init(%$seams2);
    $ss2->{cursor} = 0;
    tui::BackpackScreen::apply($ss2, tui::BackpackScreen::dispatch_key($ss2, 'd'), $seams2);
    tui::BackpackScreen::apply($ss2, tui::BackpackScreen::dispatch_key($ss2, 'y'), $seams2);
    my $list_text = _bp_list_text($ss2, 40, 120);
    unlike($list_text, qr/\Q@{[ BackpackApproval::item_key($item) ]}\E/,
        'AC-S3: the dropped key no longer renders IN THE LIST (banners excluded)');

    # AC-S3b -- counter-fixture: with the item still present (no drop
    # applied), the SAME detector DOES find the key in the list rows.
    # Without this, "not in the list" would pass trivially against an
    # empty list.
    my $ss_present = tui::BackpackScreen::init(items => [ $item ], approvals => { %appr });
    $ss_present->{cursor} = 0;
    my $list_text_present = _bp_list_text($ss_present, 40, 120);
    like($list_text_present, qr/\Q@{[ BackpackApproval::item_key($item) ]}\E/,
        'AC-S3b (counter-fixture): with the item still present, the key IS found in the list rows');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 5) unless $BS_OK;
    # --- AC-C6 (MEDIUM-2/type-ahead-drain): claim (b), the security
    # property the post-arm drain (S2.4.1) exists for -- a confirm queued
    # BEFORE the operator could possibly have seen DROP_WARNING() must NOT
    # fire, for a NON-UNDOABLE action. This is claim (a)'s mirror,
    # deliberately asserted as its own test rather than folded into AC-S3:
    # AC-S3 above now proves "confirm AFTER a genuine gap DOES fire";
    # without this block, "confirm queued with no gap does NOT fire" would
    # be untested, which is the exact gap the red-team's MEDIUM-2 finding
    # named ("the single-key confirm is satisfiable from type-ahead, so
    # DROP_WARNING() need never be displayed before a NON-UNDOABLE drop
    # fires"). 'd' and 'y' sit on the SAME read_key queue with nothing
    # between them -- indistinguishable from a fast "dy" typed before any
    # frame could have rendered the warning -- so run()'s drain (which
    # fires the instant dispatch_key returns 'confirm-drop', S2.4.1's own
    # description: "the instant a drop confirm ARMS ... discard whatever
    # is already sitting in the input buffer") must eat the 'y' and the
    # drop must never happen. ---
    my $item = { category => 'cat', name => 'zqxc6', install => 'x', verify => 'y' };
    my %appr = ( BackpackApproval::item_key($item) => BackpackApproval::item_hash($item) );
    my (@remove_calls, @save_calls);
    my ($result, undef) = _bp_run(
        items  => [ $item ], approvals => \%appr,
        remove => sub { push @remove_calls, $_[0]; return (1, {}); },
        save   => sub { push @save_calls, { %{ $_[0] } }; return (1, {}); },
        keys   => [ 'd', 'y', 'q' ],
    );
    is(scalar(@remove_calls), 0,
        'AC-C6: a "y" queued with NO gap after the arming "d" does NOT fire the remove seam -- claim (b)');
    is(scalar(@save_calls), 0,
        'AC-C6: ...nor is the save (approval-cleanup) seam called');
    is($result->{dropped}, 0, 'AC-C6: %result{dropped} stays 0 -- the item was never actually dropped');
    my $key = BackpackApproval::item_key($item);
    my $list_text = _bp_list_text(
        tui::BackpackScreen::init(items => [ $item ], approvals => { %appr }), 40, 120);
    # (structural note, not itself the claim under test): the item is of
    # course untouched on disk, so it still renders -- reusing
    # _bp_list_text here only documents that the fixture item is real and
    # findable, the same non-vacuity discipline AC-S3b/AC-C5b/AC-W8b apply.
    like($list_text, qr/\Q$key\E/, 'AC-C6: (sanity) the never-dropped item is still a real, findable row');

    # AC-C6b -- counter-fixture: the SAME no-gap shape, with an item that
    # HAS a genuine gap (via wait_keys, AC-S3's shape) DOES fire the remove
    # seam -- proving AC-C6's zero above is the drain actually discarding
    # the key, not e.g. a broken remove seam or a fixture that can never
    # fire under any timing.
    my $item2 = { category => 'cat', name => 'zqxc6b', install => 'x', verify => 'y' };
    my %appr2 = ( BackpackApproval::item_key($item2) => BackpackApproval::item_hash($item2) );
    my @remove_calls2;
    _bp_run(
        items     => [ $item2 ], approvals => \%appr2,
        remove    => sub { push @remove_calls2, $_[0]; return (1, {}); },
        save      => sub { return (1, {}); },
        keys      => [ 'd' ],
        wait_keys => [ 'y', 'q' ],
    );
    is(scalar(@remove_calls2), 1,
        'AC-C6b (counter-fixture): the identical remove seam DOES fire when "y" arrives after a genuine gap');
}

# --- AC-S4: behaviour 18 -- no JSON read/written by the module itself, by
# comment-stripped source scan. AC-S4b: each detector proven live. ---
{
    my $src = slurp($BS_PM);
  SKIP: {
        skip('tui/BackpackScreen.pm does not exist yet', 2) unless defined $src;
        my $stripped = _comment_stripped($src);
        unlike($stripped, qr/BackpackApproval::(?:load|save)\b/,
            'AC-S4: the module source names neither BackpackApproval::load nor ::save');
        # NOTE (test-defect fix, same class as AC-P2's 'warn' narrowing
        # below): 'close' is singled out to its CALL form (\bclose\s*\()
        # rather than a bare \b. A bare \bclose\b matches the STRING
        # LITERAL 'close' -- the spec's own closed token set (S2.4.3) names
        # the quit/close action 'close', not 'quit' (BackpackScreen.pm:218-
        # 227's S1 comment), so a future `return 'close' if ...` /
        # `if ($action eq 'close')` trips the bare word exactly as a real
        # close() call would, even though it opens no filehandle -- driver-
        # verified: this is why S1 (renaming the 'quit' token to the spec's
        # 'close') had to be REVERTED rather than shipped. The other
        # builtins in this class have no mandated literal that could
        # collide with a bare \b match (verified directly against the
        # shipped source, see the report), so they stay bare-word.
        unlike($stripped, qr/\b(?:open|unlink|rename|system|exec|readpipe|qx)\b|\bclose\s*\(/,
            'AC-S4: the module source names no filesystem/process builtin');
    }

    # AC-S4b -- counter-fixture: each forbidden token, alone in a temp file,
    # IS caught by the same detector.
    for my $tok (qw(BackpackApproval::load BackpackApproval::save open close unlink rename system exec readpipe qx)) {
        my (undef, $tmp) = tempfile();
        _write($tmp, "sub demo { my \$x = $tok(1,2,3); return \$x; }\n1;\n");
        my $tstripped = _comment_stripped(slurp($tmp));
        my $fires = ($tok =~ /^BackpackApproval::/)
            ? ($tstripped =~ /BackpackApproval::(?:load|save)\b/ ? 1 : 0)
            : ($tstripped =~ /\b(?:open|unlink|rename|system|exec|readpipe|qx)\b|\bclose\s*\(/ ? 1 : 0);
        ok($fires, "AC-S4b (counter-fixture): the detector fires on a fixture containing '$tok'");
    }

    # AC-S4c (test-defect fix, counter-fixture -- the false positive this
    # narrowing removes): a STRING LITERAL 'close' (the spec's closed-token
    # shape, S2.4.3) must NOT trip the narrowed detector, while a genuine
    # close(...) call still does.
    my (undef, $tmp_lit) = tempfile();
    _write($tmp_lit, "sub demo { my \$action = 'close'; return \$action eq 'close' ? 1 : 0; }\n1;\n");
    ok((_comment_stripped(slurp($tmp_lit)) !~ /\b(?:open|unlink|rename|system|exec|readpipe|qx)\b|\bclose\s*\(/),
        "AC-S4c (counter-fixture): the narrowed detector does NOT fire on the string literal 'close' (the false positive removed)");
    my (undef, $tmp_call) = tempfile();
    _write($tmp_call, "sub demo { close(\$fh); }\n1;\n");
    ok((_comment_stripped(slurp($tmp_call)) =~ /\b(?:open|unlink|rename|system|exec|readpipe|qx)\b|\bclose\s*\(/),
        'AC-S4c (counter-fixture): the narrowed detector DOES still fire on a genuine close( call');
}

# --- AC-S5: no second storage model -- permitted-import list scan, plus a
# live-detector counter-fixture against 'use JSON::PP;'. ---
{
    my $src = slurp($BS_PM);
    my @closed = qw(strict warnings constant Theme BackpackApproval tui::Frame tui::Layout tui::Screen tui::DashboardScreen);
    my %closed_set = map { $_ => 1 } @closed;
  SKIP: {
        skip('tui/BackpackScreen.pm does not exist yet', 1) unless defined $src;
        my $stripped = _comment_stripped($src);
        my @bad;
        while ($stripped =~ /^\s*(?:use|require)\s+([\w:]+)/mg) {
            push @bad, $1 unless $closed_set{$1};
        }
        is(scalar(@bad), 0, "AC-S5: every use/require target is within S2.0's closed list")
            or diag("  unexpected imports: @bad");
    }

    my (undef, $tmp) = tempfile();
    _write($tmp, "use strict;\nuse JSON::PP;\n1;\n");
    my $tstripped = _comment_stripped(slurp($tmp));
    my @bad;
    while ($tstripped =~ /^\s*(?:use|require)\s+([\w:]+)/mg) {
        push @bad, $1 unless $closed_set{$1};
    }
    ok(scalar(@bad) > 0, "AC-S5b (counter-fixture): 'use JSON::PP;' IS flagged by the same detector");
}

# ===========================================================================
# AC-C -- the confirm and the undo decision (criterion 4)
# ===========================================================================

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 3) unless $BS_OK;
    # --- AC-C1: behaviour 19 -- 'd' alone never writes. ---
    my $item = { category => 'cat', name => 'zqxc1', install => 'x', verify => 'y' };
    my @remove_calls;
    my $seams = { items => [ $item ], approvals => {}, remove => sub { push @remove_calls, $_[0]; return (1, {}); } };
    my $ss = tui::BackpackScreen::init(%$seams);
    $ss->{cursor} = 0;
    my $action = tui::BackpackScreen::dispatch_key($ss, 'd');
    is($action, 'confirm-drop', "AC-C1: dispatch_key(ss,'d') -> 'confirm-drop'");
    tui::BackpackScreen::apply($ss, $action, $seams);
    is(scalar(@remove_calls), 0, 'AC-C1: the remove seam is called ZERO times by arming alone');
    my $banners = tui::BackpackScreen::banners($ss);
    my $key = BackpackApproval::item_key($item);
    my $found = grep {
        my $t = tui::Frame::spans_text($_);
        $t =~ /\Q$key\E/ && $t =~ /\Q@{[ tui::BackpackScreen::DROP_WARNING() ]}\E/
    } @$banners;
    ok($found, 'AC-C1: the frame carries a banner containing the item key and DROP_WARNING()');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 9) unless $BS_OK;
    # --- AC-C2: behaviour 20 -- cancel, for three different cancelling
    # keys (n, q, k). 'q' while armed cancels the confirm; it does not
    # ALSO close the screen (rule 2 precedes rule 3, S2.4.3). ---
    for my $cancel_key (qw(n q k)) {
        my $item = { category => 'cat', name => "zqxc2$cancel_key", install => 'x', verify => 'y' };
        my @remove_calls;
        my $seams = { items => [ $item ], approvals => {}, remove => sub { push @remove_calls, $_[0]; return (1, {}); } };
        my $ss = tui::BackpackScreen::init(%$seams);
        $ss->{cursor} = 0;
        my $arm_action = tui::BackpackScreen::dispatch_key($ss, 'd');
        tui::BackpackScreen::apply($ss, $arm_action, $seams);
        my $cancel_action = tui::BackpackScreen::dispatch_key($ss, $cancel_key);
        is($cancel_action, 'cancel-drop', "AC-C2: '$cancel_key' while armed -> 'cancel-drop'");
        tui::BackpackScreen::apply($ss, $cancel_action, $seams);
        is(scalar(@remove_calls), 0, "AC-C2: the remove seam was called zero times after cancelling with '$cancel_key'");

        if ($cancel_key eq 'n') {
            my $banners = tui::BackpackScreen::banners($ss);
            my $still_has_warning = grep { tui::Frame::spans_text($_) =~ /\Q@{[ tui::BackpackScreen::DROP_WARNING() ]}\E/ } @$banners;
            ok(!$still_has_warning, 'AC-C2: the confirm banner is gone after cancelling');
            is($ss->{status}{kind}, 'noop', 'AC-C2: the status kind is noop after cancelling');
            my $cells = tui::BackpackScreen::compose($ss, 40, 120);
            my $joined = join('', map { defined($_->{text}) ? $_->{text} : '' } @$cells);
            like($joined, qr/\Q@{[ BackpackApproval::item_key($item) ]}\E/, 'AC-C2: the row still renders after cancelling');
        }
    }
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 4) unless $BS_OK;
    # --- AC-C3: behaviour 21 -- the not-undoable decision, derived from
    # the accessors, plus the confirm banner carrying DROP_WARNING() verbatim. ---
    is(tui::BackpackScreen::DROP_IS_UNDOABLE(), 0, 'AC-C3: DROP_IS_UNDOABLE() is 0');
    like(tui::BackpackScreen::DROP_WARNING(), qr/permanent/i, 'AC-C3: DROP_WARNING() contains "permanent"');
    like(tui::BackpackScreen::DROP_WARNING(), qr/cannot be undone/i, 'AC-C3: DROP_WARNING() contains "cannot be undone"');

    my $item = { category => 'cat', name => 'zqxc3', install => 'x', verify => 'y' };
    my $seams = { items => [ $item ], approvals => {}, remove => sub { return (1, {}); } };
    my $ss = tui::BackpackScreen::init(%$seams);
    $ss->{cursor} = 0;
    my $action = tui::BackpackScreen::dispatch_key($ss, 'd');
    tui::BackpackScreen::apply($ss, $action, $seams);
    my $banners = tui::BackpackScreen::banners($ss);
    my $warning = tui::BackpackScreen::DROP_WARNING();
    my $found = grep { index(tui::Frame::spans_text($_), $warning) >= 0 } @$banners;
    ok($found, 'AC-C3: the confirm banner text contains DROP_WARNING() VERBATIM');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 3) unless $BS_OK;
    # --- AC-C4: behaviour 22 -- an unfireable confirm is never armed (no
    # remove seam). The modal's own answer to the :2024 landmine. ---
    my $item = { category => 'cat', name => 'zqxc4', install => 'x', verify => 'y' };
    my $seams = { items => [ $item ], approvals => {} };   # deliberately NO remove seam
    my $ss = tui::BackpackScreen::init(%$seams);
    $ss->{cursor} = 0;
    my $action = tui::BackpackScreen::dispatch_key($ss, 'd');
    tui::BackpackScreen::apply($ss, $action, $seams);
    my $banners = tui::BackpackScreen::banners($ss);
    my $has_warning = grep { tui::Frame::spans_text($_) =~ /\Q@{[ tui::BackpackScreen::DROP_WARNING() ]}\E/ } @$banners;
    ok(!$has_warning, 'AC-C4: no confirm banner renders when there is no remove seam');
    is($ss->{status}{kind}, 'unavailable', 'AC-C4: the status kind is unavailable');
    my $y_action = tui::BackpackScreen::dispatch_key($ss, 'y');
    is($y_action, '', "AC-C4: a following 'y' fires nothing -- there is no armed confirm to fire");
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 4) unless $BS_OK;
    # --- AC-C5: after a confirmed drop, no restore path exists. ---
    my $item = { category => 'cat', name => 'zqxc5', install => 'x', verify => 'y' };
    my %appr = ( BackpackApproval::item_key($item) => BackpackApproval::item_hash($item) );
    my $seams = {
        items => [ $item ], approvals => \%appr,
        remove => sub { return (1, {}); },
        save   => sub { return (1, {}); },
    };
    my $ss = tui::BackpackScreen::init(%$seams);
    $ss->{cursor} = 0;
    my $a1 = tui::BackpackScreen::dispatch_key($ss, 'd');
    tui::BackpackScreen::apply($ss, $a1, $seams);
    my $a2 = tui::BackpackScreen::dispatch_key($ss, 'y');
    tui::BackpackScreen::apply($ss, $a2, $seams);

    is(tui::BackpackScreen::dispatch_key($ss, 'u'), '', "AC-C5: dispatch_key(ss,'u') -> '' -- no restore path");
    is(tui::BackpackScreen::dispatch_key($ss, 'z'), '', "AC-C5: dispatch_key(ss,'z') -> '' -- no restore path");

    # Re-scoped (test-defect fix -- was a whole-frame scan; see
    # _bp_list_text's header comment): the claim under test is that the
    # dropped key is gone from the LIST, not that it appears nowhere on
    # screen -- S2.4.4's status table requires the ok-kind banner to name
    # the verb and the item key, so a whole-frame absence check is
    # unsatisfiable together with that requirement.
    my $list_text = _bp_list_text($ss, 40, 120);
    unlike($list_text, qr/\Q@{[ BackpackApproval::item_key($item) ]}\E/,
        'AC-C5: the dropped key does not reappear IN THE LIST (banners excluded)');

    # AC-C5b -- counter-fixture: with the item still present (a fresh $ss,
    # no drop applied), the SAME detector DOES find the key in the list
    # rows. Without this, "does not reappear" would pass trivially against
    # an empty list.
    my $ss_present = tui::BackpackScreen::init(items => [ $item ], approvals => { %appr });
    $ss_present->{cursor} = 0;
    my $list_text_present = _bp_list_text($ss_present, 40, 120);
    like($list_text_present, qr/\Q@{[ BackpackApproval::item_key($item) ]}\E/,
        'AC-C5b (counter-fixture): with the item still present, the key IS found in the list rows');
}

# ===========================================================================
# AC-W -- a failed write surfaces (criterion 5)
# ===========================================================================

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 5) unless $BS_OK;
    # --- AC-W1: behaviour 23 -- 'a' with a save seam returning failure. ---
    my $item = { category => 'cat', name => 'zqxw1', install => 'x', verify => 'y' };
    my $nonce = 'zqxerr9182';
    my ($result, $frames) = _bp_run(
        items => [ $item ], approvals => {},
        save  => sub { return (0, { broken => 1, message => $nonce }); },
        keys  => [ 'a', 'q' ],
    );
    my $last = $frames->[-1] || [];
    my $joined = join('', map { defined($_->{text}) ? $_->{text} : '' } @$last);
    like($joined, qr/\Q$nonce\E/, 'AC-W1: the nonce appears in the composed frame');
    my $has_crit = grep { grep { $_->{role} eq 'state.crit' } @{ $_->{spans} || [] } } @$last;
    ok($has_crit, 'AC-W1: a state.crit span renders');
    is($result->{failures}, 1, 'AC-W1: %result{failures} is 1');
    is($result->{status}{kind}, 'failed', 'AC-W1: status kind is failed');
    my $cell = _bp_row_cell($last, BackpackApproval::item_key($item));
    ok(($cell && grep { $_->{role} eq tui::BackpackScreen::STATE_ROLE(0) } @{ $cell->{spans} || [] }),
        'AC-W1: the row still renders as PENDING (the rollback)');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 3) unless $BS_OK;
    # --- AC-W2 (counter-fixture): the identical assertions against a
    # SUCCEEDING save seam find the nonce 0 times and failures==0. ---
    my $item = { category => 'cat', name => 'zqxw2', install => 'x', verify => 'y' };
    my $nonce = 'zqxerr9182';
    my ($result, $frames) = _bp_run(
        items => [ $item ], approvals => {},
        save  => sub { return (1, {}); },
        keys  => [ 'a', 'q' ],
    );
    my $last = $frames->[-1] || [];
    my $joined = join('', map { defined($_->{text}) ? $_->{text} : '' } @$last);
    my $n = () = $joined =~ /\Q$nonce\E/g;
    is($n, 0, 'AC-W2 (counter-fixture): the nonce is found ZERO times when save succeeds');
    my $has_crit = grep { grep { $_->{role} eq 'state.crit' } @{ $_->{spans} || [] } } @$last;
    ok(!$has_crit, 'AC-W2 (counter-fixture): no state.crit span is produced when save succeeds');
    is($result->{failures}, 0, 'AC-W2 (counter-fixture): %result{failures} is 0');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 6) unless $BS_OK;
    # --- AC-W3: behaviour 25 -- the three list states (non-empty,
    # empty-and-fine, broken-load) produce pairwise DIFFERENT joined frame
    # texts, and only the broken one produces a state.crit span. ---
    my $ss_nonempty = tui::BackpackScreen::init(items => [ { key => 'zqxw3a', approved => 0 } ], approvals => {});
    my $ss_empty    = tui::BackpackScreen::init(items => [], approvals => {});
    my $ss_broken   = tui::BackpackScreen::init(load => sub { return { items => [], approvals => {}, error => { broken => 1, message => 'zqxbroken7714' } }; });

    my $j_nonempty = _bp_joined($ss_nonempty, 40, 120);
    my $j_empty    = _bp_joined($ss_empty,    40, 120);
    my $j_broken   = _bp_joined($ss_broken,   40, 120);

    isnt($j_nonempty, $j_empty,  'AC-W3: non-empty and empty-and-fine render different text');
    isnt($j_nonempty, $j_broken, 'AC-W3: non-empty and broken-load render different text');
    isnt($j_empty,    $j_broken, 'AC-W3: empty-and-fine and broken-load render different text');

    my $crit_nonempty = grep { grep { $_->{role} eq 'state.crit' } @{ $_->{spans} || [] } } @{ tui::BackpackScreen::compose($ss_nonempty, 40, 120) };
    my $crit_empty    = grep { grep { $_->{role} eq 'state.crit' } @{ $_->{spans} || [] } } @{ tui::BackpackScreen::compose($ss_empty,    40, 120) };
    my $crit_broken   = grep { grep { $_->{role} eq 'state.crit' } @{ $_->{spans} || [] } } @{ tui::BackpackScreen::compose($ss_broken,   40, 120) };
    ok(!$crit_nonempty, 'AC-W3: the non-empty list carries no state.crit span');
    ok(!$crit_empty,    'AC-W3: the empty-and-fine list carries no state.crit span (absence != broken)');
    ok($crit_broken,    'AC-W3: only the broken-load list carries a state.crit span');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 8) unless $BS_OK;
    # --- AC-W4: behaviour 26 -- 'unavailable' for each of the four
    # capability-absent paths, asserted as TWO separate assertions each so
    # a collapse of failed/unavailable fails loudly. ---

    # Case 1: item undef (thin row) x approve.
    {
        my $seams = { items => [ { key => 'zqxw4a1', approved => 0 } ], approvals => {}, save => sub { return (1, {}); } };
        my $ss = tui::BackpackScreen::init(%$seams);
        $ss->{cursor} = 0;
        my $action = tui::BackpackScreen::dispatch_key($ss, 'a');
        tui::BackpackScreen::apply($ss, $action, $seams);
        isnt($ss->{status}{kind}, 'failed', 'AC-W4 case1 (item undef x approve): kind is not failed');
        is($ss->{status}{kind}, 'unavailable', 'AC-W4 case1 (item undef x approve): kind is unavailable');
    }
    # Case 2: item undef (thin row) x drop.
    {
        my $seams = { items => [ { key => 'zqxw4a2', approved => 0 } ], approvals => {}, remove => sub { return (1, {}); } };
        my $ss = tui::BackpackScreen::init(%$seams);
        $ss->{cursor} = 0;
        my $action = tui::BackpackScreen::dispatch_key($ss, 'd');
        tui::BackpackScreen::apply($ss, $action, $seams);
        isnt($ss->{status}{kind}, 'failed', 'AC-W4 case2 (item undef x drop): kind is not failed');
        is($ss->{status}{kind}, 'unavailable', 'AC-W4 case2 (item undef x drop): kind is unavailable');
    }
    # Case 3: no save seam.
    {
        my $item = { category => 'cat', name => 'zqxw4a3', install => 'x', verify => 'y' };
        my $seams = { items => [ $item ], approvals => {} };
        my $ss = tui::BackpackScreen::init(%$seams);
        $ss->{cursor} = 0;
        my $action = tui::BackpackScreen::dispatch_key($ss, 'a');
        tui::BackpackScreen::apply($ss, $action, $seams);
        isnt($ss->{status}{kind}, 'failed', 'AC-W4 case3 (no save seam): kind is not failed');
        is($ss->{status}{kind}, 'unavailable', 'AC-W4 case3 (no save seam): kind is unavailable');
    }
    # Case 4: no remove seam.
    {
        my $item = { category => 'cat', name => 'zqxw4a4', install => 'x', verify => 'y' };
        my $seams = { items => [ $item ], approvals => {} };
        my $ss = tui::BackpackScreen::init(%$seams);
        $ss->{cursor} = 0;
        my $action = tui::BackpackScreen::dispatch_key($ss, 'd');
        tui::BackpackScreen::apply($ss, $action, $seams);
        isnt($ss->{status}{kind}, 'failed', 'AC-W4 case4 (no remove seam): kind is not failed');
        is($ss->{status}{kind}, 'unavailable', 'AC-W4 case4 (no remove seam): kind is unavailable');
    }
}

# --- AC-W5/AC-W6/AC-W7: BackpackApproval's own out-param, over the real
# filesystem (File::Temp). These do NOT depend on tui::BackpackScreen at
# all -- BackpackApproval.pm already exists -- so they run unconditionally. ---
{
    my $tmpdir = tempdir(CLEANUP => 1);

    # AC-W5: save's out-param.
    my $good_path = "$tmpdir/w5-good.json";
    my %err_ok;
    is(BackpackApproval::save($good_path, { a => 'b' }, \%err_ok), 1, 'AC-W5: save() succeeds against a writable path');
    is(scalar(keys %err_ok), 0, 'AC-W5: %err is left empty on success');

    my %err_nopath;
    is(BackpackApproval::save(undef, { a => 'b' }, \%err_nopath), 0, 'AC-W5: save(undef,...) returns 0');
    is(($err_nopath{op} // ''), 'no-path', "AC-W5: no-path arm sets op eq 'no-path'");
    is(($err_nopath{broken} // ''), 0, 'AC-W5: no-path arm sets broken == 0');

    my $bad_path = "$tmpdir/w5-missing-subdir/nested/file.json";
    my %err_open;
    is(BackpackApproval::save($bad_path, { a => 'b' }, \%err_open), 0, 'AC-W5: save() under a non-existent parent dir returns 0');
    is(($err_open{op} // ''), 'open', "AC-W5: open-failure arm sets op eq 'open'");
    is(($err_open{broken} // ''), 1, 'AC-W5: open-failure arm sets broken == 1');
    ok(defined($err_open{errno}) && length($err_open{errno}), 'AC-W5: open-failure arm sets a NON-EMPTY errno (never pinned to a message string)');

    # AC-W6: load's out-param, four arms.
    my $load_good_path = "$tmpdir/w6-good.json";
    _write($load_good_path, '{"version":1,"approved":{"cat:zqxgood":"deadbeef"}}');
    my %err_load_ok;
    my $res_ok = BackpackApproval::load($load_good_path, \%err_load_ok);
    is(scalar(keys %err_load_ok), 0, 'AC-W6: %err is left empty for a good store');
    is_deeply($res_ok, { 'cat:zqxgood' => 'deadbeef' }, 'AC-W6: a good store decodes to its approved hash');

    my $load_missing_path = "$tmpdir/w6-missing-$$-zqx.json";
    my %err_load_absent;
    my $res_absent = BackpackApproval::load($load_missing_path, \%err_load_absent);
    is(($err_load_absent{op} // ''), 'absent', "AC-W6: a missing file sets op eq 'absent'");
    is(($err_load_absent{broken} // ''), 0, 'AC-W6: a missing file sets broken == 0');
    is_deeply($res_absent, {}, 'AC-W6: a missing file returns {}');

    my $load_corrupt_path = "$tmpdir/w6-corrupt.json";
    _write($load_corrupt_path, '{');
    my %err_load_decode;
    my $res_decode = BackpackApproval::load($load_corrupt_path, \%err_load_decode);
    is(($err_load_decode{op} // ''), 'decode', "AC-W6: a corrupt file sets op eq 'decode'");
    is(($err_load_decode{broken} // ''), 1, 'AC-W6: a corrupt file sets broken == 1');
    is_deeply($res_decode, {}, 'AC-W6: a corrupt file returns {}');

    my $load_wrongshape_path = "$tmpdir/w6-wrongshape.json";
    _write($load_wrongshape_path, '{"version":1}');
    my %err_load_schema;
    my $res_schema = BackpackApproval::load($load_wrongshape_path, \%err_load_schema);
    is(($err_load_schema{op} // ''), 'schema', "AC-W6: a well-formed-but-wrong-shape file sets op eq 'schema'");
    is(($err_load_schema{broken} // ''), 1, 'AC-W6: a well-formed-but-wrong-shape file sets broken == 1');
    is_deeply($res_schema, {}, 'AC-W6: a well-formed-but-wrong-shape file returns {}');

    # AC-W7: backward compatibility -- every assertion above, repeated in
    # its TWO-ARGUMENT form, must produce the IDENTICAL return value.
    is(BackpackApproval::save($good_path, { a => 'b' }), 1, 'AC-W7: two-arg save() success still returns 1');
    is(BackpackApproval::save(undef, { a => 'b' }), 0, 'AC-W7: two-arg save(undef,...) still returns 0');
    is(BackpackApproval::save($bad_path, { a => 'b' }), 0, 'AC-W7: two-arg save() under a missing parent dir still returns 0');
    is_deeply(BackpackApproval::load($load_good_path), { 'cat:zqxgood' => 'deadbeef' }, 'AC-W7: two-arg load() of a good store is unchanged');
    is_deeply(BackpackApproval::load($load_missing_path), {}, 'AC-W7: two-arg load() of a missing file is unchanged ({})');
    is_deeply(BackpackApproval::load($load_corrupt_path), {}, 'AC-W7: two-arg load() of a corrupt file is unchanged ({})');
    is_deeply(BackpackApproval::load($load_wrongshape_path), {}, 'AC-W7: two-arg load() of a wrong-shape file is unchanged ({})');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 5) unless $BS_OK;
    # --- AC-W8: the drop-succeeded-but-cleanup-failed arm.
    #
    # Test-defect fix (MEDIUM-2/type-ahead-drain, same shape as AC-S3
    # above): 'y' now arrives via wait_keys, after a genuine gap past the
    # 'd' that arms the confirm, so run()'s post-arm drain (which only
    # touches read_key) has nothing queued to eat -- this is claim (a),
    # "a confirm that follows the warning fires", exercised here through
    # the failed-cleanup arm specifically. ---
    my $item = { category => 'cat', name => 'zqxw8', install => 'x', verify => 'y' };
    my %appr = ( BackpackApproval::item_key($item) => BackpackApproval::item_hash($item) );
    my $nonce = 'zqxcln4471';
    my ($result, $frames) = _bp_run(
        items     => [ $item ], approvals => \%appr,
        remove    => sub { return (1, {}); },
        save      => sub { return (0, { broken => 1, message => $nonce }); },
        keys      => [ 'd' ],
        wait_keys => [ 'y', 'q' ],
    );
    is($result->{status}{kind}, 'failed', 'AC-W8: the status kind is failed');
    my $detail = $result->{status}{detail} // '';
    my $key = BackpackApproval::item_key($item);
    like($detail, qr/\Q$key\E/, 'AC-W8: the detail names the dropped key');
    like($detail, qr/\Q$nonce\E/, 'AC-W8: the detail names the cleanup-save nonce');

    # Re-scoped (test-defect fix -- was a whole-frame scan; see
    # _bp_list_text's header comment): S2.4.4's status table requires the
    # failed-kind banner to name the op and the %err detail (which already
    # includes the key, per the two assertions just above), so a
    # whole-frame absence check for the key is unsatisfiable together with
    # that requirement. Drive an IDENTICAL fixture directly through
    # init/dispatch_key/apply so $ss is in hand and the list body can be
    # isolated from the banner.
    my $seams2 = {
        items => [ $item ], approvals => { %appr },
        remove => sub { return (1, {}); },
        save   => sub { return (0, { broken => 1, message => $nonce }); },
    };
    my $ss2 = tui::BackpackScreen::init(%$seams2);
    $ss2->{cursor} = 0;
    tui::BackpackScreen::apply($ss2, tui::BackpackScreen::dispatch_key($ss2, 'd'), $seams2);
    tui::BackpackScreen::apply($ss2, tui::BackpackScreen::dispatch_key($ss2, 'y'), $seams2);
    my $list_text = _bp_list_text($ss2, 40, 120);
    unlike($list_text, qr/\Q$key\E/,
        'AC-W8: the item is nevertheless gone from the LIST (banners excluded)');

    # AC-W8b -- counter-fixture: with the item still present (a fresh $ss,
    # no drop applied), the SAME detector DOES find the key in the list
    # rows. Without this, "gone from the list" would pass trivially against
    # an empty list.
    my $ss_present = tui::BackpackScreen::init(items => [ $item ], approvals => { %appr });
    $ss_present->{cursor} = 0;
    my $list_text_present = _bp_list_text($ss_present, 40, 120);
    like($list_text_present, qr/\Q$key\E/,
        'AC-W8b (counter-fixture): with the item still present, the key IS found in the list rows');
}

# ===========================================================================
# AC-R -- reflow (criterion 6)
# ===========================================================================

my $BP = tui::Layout::BREAKPOINT_TWO_COL();   # declared ONCE (S2.0's "no literal 90" rule)

my @BP_TITLES_R = ('items', 'selected item');
sub _bp_panel_title_hits_in_row {
    my ($text) = @_;
    return 0 unless defined $text;
    my $n = 0;
    for my $t (@BP_TITLES_R) {
        $n += () = $text =~ /-- \Q$t\E /g;
    }
    return $n;
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 1) unless $BS_OK;
    # --- AC-R1: behaviour 29 -- for every integer cols 20..200 at rows=24,
    # every cell's display width is exactly cols, text eq spans_text(spans),
    # and no cell text contains \e. One aggregate. ---
    my $items = _bp_thin_items(5);
    my $violations = 0;
    my $first;
    for my $cols (20 .. 200) {
        my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
        my $frame = tui::BackpackScreen::compose($ss, 24, $cols);
        for my $i (0 .. $#$frame) {
            my $cell = $frame->[$i];
            my $text = defined($cell->{text}) ? $cell->{text} : '';
            my $w    = tui::Layout::display_width($text);
            my $st   = tui::Frame::spans_text($cell->{spans} || []);
            next if $w == $cols && $text eq $st && $text !~ /\e/;
            $violations++;
            $first ||= "cols=$cols row=$i width=$w";
        }
    }
    is($violations, 0, 'AC-R1: every composed cell is exactly $cols wide, text==spans_text, no ESC, over cols 20..200')
        or diag("  first offender: " . ($first // '(none captured)'));
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 76) unless $BS_OK;
    # --- AC-R2: behaviour 30 -- compose() returns exactly $rows cells, for
    # every $rows in 3..40 at $cols in {60,100}. THE one row-count identity
    # Decision 15 permits (AC-P8 whitelists exactly this call shape). ---
    my $items = _bp_thin_items(5);
    for my $cols (60, 100) {
        for my $rows (3 .. 40) {
            my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
            my $frame = tui::BackpackScreen::compose($ss, $rows, $cols);
            is(scalar(@$frame), $rows, "AC-R2: compose(ss,$rows,$cols) returns exactly $rows cells");   # shape-lint: intentional -- AC-R2 whitelisted identity
        }
    }
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 6) unless $BS_OK;
    # --- AC-R3: behaviour 31 -- panel-title placement flips at the
    # breakpoint, at $BP-30,$BP-1,$BP,$BP+1,$BP+30,$BP+110. ---
    my $items = _bp_thin_items(3);
    for my $cols ($BP - 30, $BP - 1, $BP, $BP + 1, $BP + 30, $BP + 110) {
        my $ss = tui::BackpackScreen::init(items => $items, approvals => {});
        my $frame = tui::BackpackScreen::compose($ss, 30, $cols);
        my $max_hits = 0;
        for my $cell (@$frame) {
            my $h = _bp_panel_title_hits_in_row($cell->{text});
            $max_hits = $h if $h > $max_hits;
        }
        if ($cols < $BP) {
            ok($max_hits < 2, "AC-R3: at cols=$cols (below breakpoint) no row carries two panel titles");
        } else {
            ok($max_hits >= 2, "AC-R3: at cols=$cols (at/above breakpoint) at least one row carries two panel titles");
        }
    }
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 2) unless $BS_OK;
    # --- AC-R4: behaviour 32 -- the hostile fixture: a 300-char key, a key
    # containing raw \e[31m, an item with a newline in rationale, and a
    # non-hashref element. Same aggregate form as AC-R1, plus a joined-text
    # ESC check. ---
    my @hostile_items = (
        { key => ('k' x 300), approved => 0 },
        { key => "esc\e[31mkey", approved => 1 },
        { category => 'cat', name => 'zqxnl', install => 'x', verify => 'y', rationale => "line1\nline2" },
        'not-a-hashref',
    );
    my $violations = 0;
    my $first;
    for my $cols (20 .. 200) {
        my $ss = tui::BackpackScreen::init(items => \@hostile_items, approvals => {});
        my $frame = tui::BackpackScreen::compose($ss, 24, $cols);
        for my $i (0 .. $#$frame) {
            my $cell = $frame->[$i];
            my $text = defined($cell->{text}) ? $cell->{text} : '';
            my $w    = tui::Layout::display_width($text);
            my $st   = tui::Frame::spans_text($cell->{spans} || []);
            next if $w == $cols && $text eq $st && $text !~ /\e/;
            $violations++;
            $first ||= "cols=$cols row=$i width=$w";
        }
    }
    is($violations, 0, 'AC-R4: behaviour 29 holds for the hostile fixture, over cols 20..200')
        or diag("  first offender: " . ($first // '(none captured)'));

    my $joined = _bp_joined(tui::BackpackScreen::init(items => \@hostile_items, approvals => {}), 24, 100);
    unlike($joined, qr/\e/, 'AC-R4: the hostile fixture never leaks a raw ESC into the joined frame text');
}

# --- AC-R4b (counter-fixture): the SAME ESC detector fires on a hand-built
# string containing "\e[31m" -- proving it is not vacuously blind. Does not
# depend on tui::BackpackScreen. ---
{
    my $counter = "prefix \e[31m suffix";
    like($counter, qr/\e/, 'AC-R4b (counter-fixture): the ESC detector DOES fire on a hand-built "\e[31m" string');
}

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 2) unless $BS_OK;
    # --- AC-R5: list_height is monotone and floored over a hostile
    # argument corpus, and strictly smaller in single-column than
    # two-column for the same $rows when $hd is 1. ---
    my @hostile_args = (undef, '', {}, [], -5);
    my $floor_violations = 0;
    for my $r (@hostile_args) {
        for my $c (@hostile_args) {
            for my $nb (@hostile_args) {
                for my $hd (@hostile_args) {
                    my $v = tui::BackpackScreen::list_height($r, $c, $nb, $hd);
                    $floor_violations++
                        unless defined($v) && !ref($v) && $v =~ /^-?\d+$/ && $v >= 0;
                }
            }
        }
    }
    is($floor_violations, 0, 'AC-R5: list_height(...) is always a non-negative integer over the hostile corpus');

    my $lh_single = tui::BackpackScreen::list_height(24, $BP - 10, 0, 1);
    my $lh_two    = tui::BackpackScreen::list_height(24, $BP + 10, 0, 1);
    ok($lh_single < $lh_two,
        'AC-R5: list_height is strictly SMALLER in single-column than two-column for the same rows (hd=1)');
}

# ===========================================================================
# AC-O -- BackpackOps.pm: the REAL bp_load/bp_save/bp_remove closures,
# extracted from launcher.pl specifically so they stop being untested
# (review-driver-round M1 / red-team HIGH-1/HIGH-2/HIGH-3). Everything
# above this point proves tui::BackpackScreen correct against INJECTED
# seams; nothing above exercises the real code that supplies those seams
# in the shipped binary. This section does -- directly, never via
# launcher.pl (AC-P7 forbids naming it, and BackpackOps.pm's own header
# says exactly why it was extracted).
# ===========================================================================

# _bp_write_json($path, \%data) -> write %data as UTF-8-encoded JSON bytes
# to $path (File::Temp-owned). Mirrors backpack.pl's own encoding
# (BackpackOps.pm's load() comment: "decode as UTF-8, matching backpack.pl's
# own decode_json") so a fixture built this way is a faithful stand-in for
# a real backpack.json, not a convenient shortcut.
sub _bp_write_json {
    my ($path, $data) = @_;
    my $bytes = JSON::PP->new->utf8->encode($data);
    _write($path, $bytes);
}

SKIP: {
    skip('BackpackOps.pm did not load', 42) unless $BO_OK;

    my $dir = tempdir(CLEANUP => 1);

    # --- AC-O1 (HIGH-2, direction 1): both stores genuinely absent -- the
    # commonest case, first launch, nothing ever packed or approved.
    # Absence must be decided by -f on the file itself, per the fixed
    # precedence rule; NOT by attempting (and failing) to decode. ---
    {
        my $host = "$dir/o1-backpack.json";       # never created
        my $appr = "$dir/o1-approvals.json";       # never created
        my $bp = BackpackOps::load(host_file => $host, appr_file => $appr);
        is_deeply($bp->{items}, [], 'AC-O1: items is [] when backpack.json is absent');
        is_deeply($bp->{approvals}, {}, 'AC-O1: approvals is {} when the approvals store is absent');
        ok(defined $bp->{error}, 'AC-O1: an error IS surfaced (liveness) for the absent case');
        is($bp->{error}{op}, 'absent', "AC-O1: error op is 'absent', not a decode failure -- HIGH-2 direction 1");
        is($bp->{error}{broken}, 0, 'AC-O1: broken is 0 for a genuinely absent file');
    }

    # --- AC-O2 (HIGH-2, direction 2): backpack.json exists but is CORRUPT,
    # approvals store absent (the common real-world pairing: `backpack.pl
    # validate` failing means the approvals store is never created). Before
    # the fix, %e from the absent approvals store won the branch race and
    # this reported broken=>0 ('nothing packed') for a file that is
    # actually unreadable. ---
    {
        my $host = "$dir/o2-backpack.json";
        _write($host, "{ this is not valid json ");
        my $appr = "$dir/o2-approvals.json";       # absent
        my $bp = BackpackOps::load(host_file => $host, appr_file => $appr);
        ok(defined $bp->{error}, 'AC-O2: an error IS surfaced (liveness) for the corrupt case');
        is($bp->{error}{op}, 'decode', "AC-O2: error op is 'decode' for a corrupt backpack.json -- HIGH-2 direction 2");
        is($bp->{error}{broken}, 1, 'AC-O2: broken is 1 for a corrupt backpack.json, even though the OTHER store is merely absent');
        is_deeply($bp->{items}, [], 'AC-O2: items is [] (undecodable) rather than a partial/garbage parse');
    }

    # --- AC-O3: broken beats absent regardless of WHICH store reports it --
    # the mirror of AC-O2. backpack.json is absent (clean, ordinary), but
    # the approvals store is corrupt. The overall error must still be
    # broken=>1 -- an absent host must not mask a broken approvals store
    # either. ---
    {
        my $host = "$dir/o3-backpack.json";        # absent
        my $appr = "$dir/o3-approvals.json";
        _write($appr, "{ not json either ");
        my $bp = BackpackOps::load(host_file => $host, appr_file => $appr);
        ok(defined $bp->{error}, 'AC-O3: an error IS surfaced (liveness) for the broken-approvals case');
        is($bp->{error}{broken}, 1,
            'AC-O3: broken is 1 -- a broken APPROVALS store wins over an absent backpack.json (broken beats absent, either direction)');
    }

    # --- AC-O3b (counter-fixture): with BOTH stores clean (host present
    # and decodable, approvals present and decodable), broken must be
    # false -- proving AC-O1/AC-O2/AC-O3's broken=>1 readings are not a
    # detector that fires unconditionally. ---
    {
        my $host = "$dir/o3b-backpack.json";
        _bp_write_json($host, { items => [] });
        my $appr = "$dir/o3b-approvals.json";
        ok(BackpackApproval::save($appr, {}), 'AC-O3b: (fixture) a clean approvals store saves');
        my $bp = BackpackOps::load(host_file => $host, appr_file => $appr);
        is($bp->{error}, undef, 'AC-O3b (counter-fixture): with both stores clean, error is undef -- broken is never a false positive');
    }

    # --- AC-O4: a clean, positive round trip -- items and approvals both
    # present and readable, no error, item identity preserved. This is the
    # module doing its ordinary job, not just its three defect regressions. ---
    {
        my $item = { category => 'apt', name => 'zqxo4', install => 'i', verify => 'v' };
        my $host = "$dir/o4-backpack.json";
        _bp_write_json($host, { items => [ $item ] });
        my $appr = "$dir/o4-approvals.json";
        my %store = ( BackpackApproval::item_key($item) => BackpackApproval::item_hash($item) );
        ok(BackpackApproval::save($appr, \%store), 'AC-O4: (fixture) the approvals store saves');
        my $bp = BackpackOps::load(host_file => $host, appr_file => $appr);
        is($bp->{error}, undef, 'AC-O4: no error on a clean round trip');
        is(scalar(@{ $bp->{items} }), 1, 'AC-O4: one item comes back');
        is($bp->{items}[0]{name}, 'zqxo4', 'AC-O4: the item name round-trips');
        is($bp->{approvals}{ BackpackApproval::item_key($item) }, BackpackApproval::item_hash($item),
            'AC-O4: the approval record round-trips');
    }

    # --- AC-O5 (HIGH-1, encoding half): a NON-ASCII item name round-trips.
    # Before the fix, load() decoded backpack.json as (effectively)
    # Latin-1 while backpack.pl decodes UTF-8, so any non-ASCII name came
    # out mojibake -- this machine's own paths contain "Andre" with an
    # acute accent, not a hypothetical. Built via \x{...} (never a raw high
    # byte in THIS file's source) and compared against the wide-char string
    # load() should have produced from UTF-8-encoded fixture bytes. ---
    {
        my $name = "caf" . chr(0xE9);   # "café" -- one non-ASCII codepoint, U+00E9
        my $item = { category => 'apt', name => $name, install => 'i', verify => 'v' };
        my $host = "$dir/o5-backpack.json";
        _bp_write_json($host, { items => [ $item ] });
        my $appr = "$dir/o5-approvals.json";   # absent; irrelevant to this claim
        my $bp = BackpackOps::load(host_file => $host, appr_file => $appr);
        is(scalar(@{ $bp->{items} }), 1, 'AC-O5: the non-ASCII-named item is present (liveness)');
        is($bp->{items}[0]{name}, $name, 'AC-O5: the non-ASCII item name round-trips byte-for-byte (UTF-8, not Latin-1)');
        isnt($bp->{items}[0]{name}, "caf\xC3\xA9",
            'AC-O5: (sanity) the round-tripped name is the DECODED wide-char string, not the raw two-byte UTF-8 sequence misread as Latin-1');
    }

    # --- AC-O6: save() -- a thin, testable pass-through to
    # BackpackApproval::save's out-param contract. ---
    {
        my $appr = "$dir/o6-approvals.json";
        my %store = ( 'apt:jq' => 'deadbeef' );
        my ($ok, $err) = BackpackOps::save(\%store, appr_file => $appr);
        is($ok, 1, 'AC-O6: save() succeeds for a writable path');
        is_deeply($err, {}, 'AC-O6: save() leaves \%err empty on success');
        is_deeply(BackpackApproval::load($appr), \%store, 'AC-O6: the store round-trips through the real BackpackApproval::load');

        my ($ok2, $err2) = BackpackOps::save(\%store, appr_file => undef);
        is($ok2, 0, 'AC-O6: save() fails cleanly when given no path');
        ok(defined($err2) && ref($err2) eq 'HASH' && %$err2,
            'AC-O6: ...and \%err is populated (not silently swallowed) on that failure');
    }

    # --- AC-O7 (HIGH-1, the destructive-lying half): `backpack.pl remove`
    # exits 0 with a "STATUS: noop" line when nothing matched -- rc==0 is
    # NOT sufficient for success. Before the fix this was reported as a
    # successful drop for an item still on disk. ---
    {
        my $item = { category => 'APT', name => 'zqxo7', install => 'i', verify => 'v' };
        my ($ok, $err) = BackpackOps::remove($item,
            host_file => "$dir/o7-backpack.json", backpack_pl => "$dir/o7-backpack.pl",
            run => sub { return (0, "STATUS: noop\nREASON: no match\n"); });
        is($ok, 0, 'AC-O7: a "STATUS: noop" result (rc==0) is reported as a FAILURE, not a success -- HIGH-1');
        ok(defined($err) && ref($err) eq 'HASH' && $err->{op} && $err->{op} eq 'remove',
            'AC-O7: the error names the remove op');
        is($err->{broken}, 0, 'AC-O7: a noop is not "broken" storage -- it is "nothing to do", a distinct failure shape');
    }

    # --- AC-O7b (counter-fixture): a GENUINE success (rc==0, no "STATUS:
    # noop" in the captured output) IS reported as ok=1. Without this,
    # AC-O7's ok==0 could be a detector that always reports failure. ---
    {
        my $item = { category => 'apt', name => 'zqxo7b', install => 'i', verify => 'v' };
        my ($ok, $err) = BackpackOps::remove($item,
            host_file => "$dir/o7b-backpack.json", backpack_pl => "$dir/o7b-backpack.pl",
            run => sub { return (0, "STATUS: ok\ndropped apt:zqxo7b\n"); });
        is($ok, 1, 'AC-O7b (counter-fixture): a genuine success (rc==0, no noop) IS reported as ok=1');
        is_deeply($err, {}, 'AC-O7b (counter-fixture): \%err is empty on a genuine success');
    }

    # --- AC-O7c: a genuine subprocess failure (non-zero rc) is ALSO a
    # failure, and marked broken (distinct from the noop's broken=>0). ---
    {
        my $item = { category => 'apt', name => 'zqxo7c', install => 'i', verify => 'v' };
        my ($ok, $err) = BackpackOps::remove($item,
            host_file => "$dir/o7c-backpack.json", backpack_pl => "$dir/o7c-backpack.pl",
            run => sub { return (256, "some crash output\n"); });   # rc==256 -> exit code 1
        is($ok, 0, 'AC-O7c: a non-zero exit is a failure');
        is($err->{broken}, 1, 'AC-O7c: ...and IS marked broken (unlike the noop arm)');
    }

    # --- AC-O8 (HIGH-3, no shell): capture_quiet passes a
    # metacharacter-laden argument through as ONE literal argv element,
    # with NO SHELL involved to interpret it. Verified two ways: (1) a
    # child perl process, invoked via capture_quiet itself, echoes the
    # argument back byte-for-byte (proving no shell truncated/split it at
    # '&', ';', '|' or '$(...)'); (2) a marker file that a shell WOULD have
    # created via an injected '&echo...>file' never appears. Written only
    # under File::Temp/scratchpad, never the repo. ---
    {
        my $marker = "$dir/o8-injected-marker.txt";
        ok(!-e $marker, 'AC-O8: (sanity) the injection marker does not exist before the call');
        my $hostile = 'safe & echo INJECTED > "' . $marker . '" & echo more; $(echo pwned) | echo pipe';
        my ($rc, $out) = BackpackOps::capture_quiet($^X, '-e', 'print $ARGV[0]', $hostile);
        is($rc, 0, 'AC-O8: the child process ran and exited 0');
        is($out, $hostile,
            'AC-O8: the metacharacter-laden argument round-trips as ONE literal argv element (echoed verbatim by the child)');
        ok(!-e $marker, 'AC-O8: HIGH-3 -- the shell metacharacters did NOT execute a second command (no shell involved)');
    }

    # --- AC-O8b (counter-fixture): capture_quiet DOES propagate a real
    # child exit code and DOES combine stdout+stderr -- proving AC-O8's
    # clean run above is exercising a live subprocess boundary, not a stub
    # that always returns (0, $input). ---
    {
        my ($rc, $out) = BackpackOps::capture_quiet(
            $^X, '-e', 'print STDOUT "OUT-zqxo8b"; print STDERR "ERR-zqxo8b"; exit 7;');
        is($rc >> 8, 7, 'AC-O8b (counter-fixture): the real child exit code (7) propagates through $rc');
        like($out, qr/OUT-zqxo8b/, 'AC-O8b (counter-fixture): captured output contains the child\'s STDOUT');
        like($out, qr/ERR-zqxo8b/, 'AC-O8b (counter-fixture): captured output contains the child\'s STDERR (merged, per E-C)');
    }

    # --- AC-O9: end-to-end integration of remove() over its DEFAULT seams
    # (perl => $^X, run => \&capture_quiet) against a REAL backpack.pl-
    # shaped fixture script -- not an injected `run` stub. This is the
    # closest this suite comes to exercising the exact wiring launcher.pl
    # uses, without ever naming or spawning launcher.pl itself. ---
    {
        my $fake_pl = "$dir/o9-fake-backpack.pl";
        _write($fake_pl, <<'FAKE');
use strict;
use warnings;
my %a;
for (my $i = 0; $i < @ARGV; $i++) {
    $a{category} = $ARGV[$i+1] if $ARGV[$i] eq '--category';
    $a{name}     = $ARGV[$i+1] if $ARGV[$i] eq '--name';
}
if (defined($a{name}) && $a{name} eq 'realitem') {
    print "STATUS: ok\ndropped $a{category}:$a{name}\n";
    exit 0;
}
print "STATUS: noop\nREASON: no match\n";
exit 0;
FAKE
        my $ok_item = { category => 'apt', name => 'realitem', install => 'i', verify => 'v' };
        my ($ok1, $err1) = BackpackOps::remove($ok_item,
            host_file => "$dir/o9-backpack.json", backpack_pl => $fake_pl);
        is($ok1, 1, 'AC-O9: remove() over its REAL default seams (perl=$^X, run=capture_quiet) succeeds for a matching item');

        my $miss_item = { category => 'apt', name => 'ghostitem', install => 'i', verify => 'v' };
        my ($ok2, $err2) = BackpackOps::remove($miss_item,
            host_file => "$dir/o9-backpack.json", backpack_pl => $fake_pl);
        is($ok2, 0, 'AC-O9: ...and correctly fails (not a false success) for a non-matching item, over the SAME real seams');
    }
}

# ===========================================================================
# AC-P -- purity, hygiene, and non-vacuity
# ===========================================================================

# --- AC-P1 ---
use_ok('tui::BackpackScreen');

# --- AC-P2: behaviour 33 -- one assertion per forbidden class, over the
# comment-stripped source. AC-P2b: every detector proven live. ---
{
    my $raw = slurp($BS_PM);
  SKIP: {
        skip('tui/BackpackScreen.pm does not exist yet', 5) unless defined $raw;
        my $stripped = _comment_stripped($raw);
        unlike($stripped, qr/\bDashboard\b/, "AC-P2 class 'Dashboard': the module source never names Dashboard");

        my @high_bytes = grep { ord($_) >= 0x80 } split //, $raw;
        is(scalar(@high_bytes), 0, "AC-P2 class 'byte>=0x80': the module source contains no byte >= 0x80");

        my $has_hi_escape = 0;
        while ($stripped =~ /\\x\{([0-9A-Fa-f]{2,6})\}/g) {
            $has_hi_escape = 1 if hex($1) >= 0x80;
        }
        ok(!$has_hi_escape, "AC-P2 class '\\x{...}>=0x80': the module source contains no such escape");

        # NOTE (test-defect fix): 'warn' is singled out to its CALL form
        # (\bwarn\s*\() rather than a bare \b. A bare \bwarn\b matches the
        # Theme role literal 'state.warn' (STATE_ROLE(0), status_spans'
        # 'unavailable' arm), because '.' and the surrounding quotes both
        # satisfy \b -- driver-verified: "state.warn" =~ /\bwarn\b/ matches.
        # This is the exact bug package 05 shipped and 06 already fixed
        # (t/66-dashboard-screen.t's FORBIDDEN_CLASS{console}, which applies
        # the identical \bwarn\s*\( narrowing).
        #
        # 'close' is likewise singled out to its CALL form (\bclose\s*\()
        # -- same fix, same shape, same AC-S4/AC-S4c note above -- because
        # the spec's closed token set (S2.4.3) names the quit/close action
        # 'close' (not 'quit'), and a bare \bclose\b trips on that STRING
        # LITERAL exactly as it would on a real close() call. Confirmed
        # this is not hypothetical: fix-batch S1 (renaming the shipped
        # 'quit' token to the spec's 'close') was driver-verified to trip
        # this very bareword and had to be reverted rather than applied;
        # narrowing here is what unblocks it.
        #
        # The other builtins in this class (open, unlink, rename, system,
        # exec, time, print) have no mandated literal that could collide
        # with a bare \b match (verified directly against the shipped
        # source -- see the report), so they stay bare-word.
        unlike($stripped, qr/\b(?:open|unlink|rename|system|exec|time|print)\b|\bwarn\s*\(|\bclose\s*\(/,
            "AC-P2 class 'filesystem/process/clock/console': the module source names none of these builtins");

        unlike($stripped, qr/(?<![\d.])90(?![\d.])/, "AC-P2 class 'literal 90': the module source contains no bare 90");
    }

    # AC-P2b -- counter-fixture: each detector fires on a temp file
    # containing that exact construct.
    my (undef, $tmp1) = tempfile();
    _write($tmp1, "package x; use Dashboard; 1;\n");
    ok((_comment_stripped(slurp($tmp1)) =~ /\bDashboard\b/), "AC-P2b: 'Dashboard' detector fires on a fixture containing it");

    my (undef, $tmp2) = tempfile();
    _write($tmp2, "my \$s = 'caf\xC3\xA9';\n");   # raw UTF-8 bytes for 'e' with an acute accent
    my $raw2 = slurp($tmp2);
    my @hi2 = grep { ord($_) >= 0x80 } split //, $raw2;
    ok(scalar(@hi2) > 0, 'AC-P2b: byte>=0x80 detector fires on a fixture containing a raw high byte');

    my (undef, $tmp3) = tempfile();
    _write($tmp3, 'my $s = "\x{2022}";' . "\n");
    my $tstripped3 = _comment_stripped(slurp($tmp3));
    my $found3 = 0;
    while ($tstripped3 =~ /\\x\{([0-9A-Fa-f]{2,6})\}/g) { $found3 = 1 if hex($1) >= 0x80; }
    ok($found3, 'AC-P2b: \x{...}>=0x80 detector fires on a fixture containing that escape');

    my (undef, $tmp4) = tempfile();
    _write($tmp4, "sub demo { my \$t = time(); print \$t; }\n");
    ok((_comment_stripped(slurp($tmp4)) =~ /\b(?:open|unlink|rename|system|exec|time|print)\b|\bwarn\s*\(|\bclose\s*\(/),
        'AC-P2b: filesystem/process/clock/console detector fires on a fixture containing time()/print');

    # AC-P2b (warn-specific, test-defect fix): the corrected detector still
    # fires on a GENUINE warn(...) call -- proving the \bwarn\s*\( narrowing
    # did not blind it -- while a role literal shaped like 'state.warn' does
    # NOT fire (the false positive the fix removes).
    my (undef, $tmp4b) = tempfile();
    _write($tmp4b, "sub demo { warn(\"oops\\n\"); }\n");
    ok((_comment_stripped(slurp($tmp4b)) =~ /\b(?:open|unlink|rename|system|exec|time|print)\b|\bwarn\s*\(|\bclose\s*\(/),
        'AC-P2b: the corrected detector DOES fire on a genuine warn( call');

    my (undef, $tmp4c) = tempfile();
    _write($tmp4c, "sub demo { return \$approved ? 'state.ok' : 'state.warn'; }\n");
    ok((_comment_stripped(slurp($tmp4c)) !~ /\b(?:open|unlink|rename|system|exec|time|print)\b|\bwarn\s*\(|\bclose\s*\(/),
        "AC-P2b: the corrected detector does NOT fire on the role literal 'state.warn' (the false positive removed)");

    # AC-P2b (close-specific, test-defect fix, same shape as the warn pair
    # above): the corrected detector still fires on a GENUINE close(...)
    # call, while the spec's closed-token string literal 'close' does NOT
    # fire (the false positive this narrowing removes, and the one that
    # blocked fix-batch S1).
    my (undef, $tmp4d) = tempfile();
    _write($tmp4d, "sub demo { close(\$fh); }\n");
    ok((_comment_stripped(slurp($tmp4d)) =~ /\b(?:open|unlink|rename|system|exec|time|print)\b|\bwarn\s*\(|\bclose\s*\(/),
        'AC-P2b: the corrected detector DOES fire on a genuine close( call');

    my (undef, $tmp4e) = tempfile();
    _write($tmp4e, "sub demo { my \$action = shift; return \$action eq 'close' ? 1 : 0; }\n");
    ok((_comment_stripped(slurp($tmp4e)) !~ /\b(?:open|unlink|rename|system|exec|time|print)\b|\bwarn\s*\(|\bclose\s*\(/),
        "AC-P2b: the corrected detector does NOT fire on the closed-token string literal 'close' (the false positive removed)");

    my (undef, $tmp5) = tempfile();
    _write($tmp5, "use constant BREAKPOINT => 90;\n");
    ok((_comment_stripped(slurp($tmp5)) =~ /(?<![\d.])90(?![\d.])/), "AC-P2b: literal '90' detector fires on a fixture containing it");
}

# --- AC-P3: behaviour 34 -- tui::Frame::is_known_role, applied to every
# span of every cell of every fixture frame, aggregated. AC-P3b: the
# detector distinguishes a legacy name from a Theme name. ---
SKIP: {
    skip('tui::BackpackScreen does not exist yet', 1) unless $BS_OK;
    my @fixture_frames;
    push @fixture_frames, tui::BackpackScreen::compose(
        tui::BackpackScreen::init(items => _bp_thin_items(6), approvals => {}), 30, 100);
    push @fixture_frames, tui::BackpackScreen::compose(
        tui::BackpackScreen::init(items => [], approvals => {}), 24, 80);
    push @fixture_frames, tui::BackpackScreen::compose(
        tui::BackpackScreen::init(load => sub { return { items => [], approvals => {}, error => { broken => 1 } }; }), 24, 80);
    my $armed_ss = tui::BackpackScreen::init(items => [ { category => 'cat', name => 'zqxp3', install => 'x', verify => 'y' } ], approvals => {}, remove => sub { return (1, {}); });
    $armed_ss->{cursor} = 0;
    tui::BackpackScreen::apply($armed_ss, tui::BackpackScreen::dispatch_key($armed_ss, 'd'), { items => [], approvals => {}, remove => sub { return (1, {}); } });
    push @fixture_frames, tui::BackpackScreen::compose($armed_ss, 24, 80);

    my $bad_roles = 0;
    my $first;
    for my $frame (@fixture_frames) {
        for my $cell (@$frame) {
            for my $sp (@{ $cell->{spans} || [] }) {
                next if tui::Frame::is_known_role($sp->{role});
                $bad_roles++;
                $first ||= "role='" . (defined($sp->{role}) ? $sp->{role} : 'undef') . "'";
            }
        }
    }
    is($bad_roles, 0, 'AC-P3: every span of every cell of every fixture frame carries a known Theme role')
        or diag("  first offender: " . ($first // '(none captured)'));
}

{
    # AC-P3b -- counter-fixture: distinguishes a legacy name from a Theme name.
    is(tui::Frame::is_known_role('good'), 0, "AC-P3b: is_known_role('good') is 0 -- a legacy name is NOT known");
    is(tui::Frame::is_known_role('state.ok'), 1, "AC-P3b: is_known_role('state.ok') is 1 -- a Theme name IS known");
}

# --- AC-P4: behaviour 35 -- _backpack_lines stays off the render path, by
# comment-stripped scan of Dashboard.pm and every tui/*.pm: the name
# appears only in its own sub line. AC-P4b: the same scan reports a call
# in a fixture that has one. Always runs -- Dashboard.pm/tui/*.pm already exist. ---
{
    my @scan_files = ($DASHBOARD_PM, glob("$TUI_DIR/*.pm"));
    my $bad_refs = 0;
    my $first;
    for my $f (@scan_files) {
        my $s = slurp($f);
        next unless defined $s;
        my $stripped = _comment_stripped($s);
        for my $line (split /\n/, $stripped) {
            next unless $line =~ /_backpack_lines/;
            next if $line =~ /^\s*sub\s+_backpack_lines\b/;
            $bad_refs++;
            $first ||= "$f: " . $line;
        }
    }
    is($bad_refs, 0, 'AC-P4: _backpack_lines is referenced nowhere outside its own sub definition')
        or diag("  first offender: " . ($first // '(none captured)'));

    my (undef, $tmp) = tempfile();
    _write($tmp, "my \@x = _backpack_lines(\$bp, 80);\n");
    my $tstripped = _comment_stripped(slurp($tmp));
    my $found_call = 0;
    for my $line (split /\n/, $tstripped) {
        next unless $line =~ /_backpack_lines/;
        next if $line =~ /^\s*sub\s+_backpack_lines\b/;
        $found_call = 1;
    }
    ok($found_call, 'AC-P4b (counter-fixture): the same scan DOES report a call in a fixture containing one');
}

# --- AC-P5: behaviour 36 -- totality over a hostile corpus, aggregated
# (never dies, never warns). ---
SKIP: {
    skip('tui::BackpackScreen does not exist yet', 1) unless $BS_OK;
    my @HOSTILE = (undef, '', [], {}, bless({}, 'Zqx::HostileClass'), "\xC0\xC0\xC0", ('x' x 10240));
    my %CALLS = (
        rows         => sub { tui::BackpackScreen::rows($_[0], {}) },
        counts       => sub { tui::BackpackScreen::counts($_[0]) },
        window       => sub { tui::BackpackScreen::window({ rows => [], cursor => 0 }, $_[0], 80) },
        list_height  => sub { tui::BackpackScreen::list_height($_[0], 80, 0, 0) },
        banners      => sub { tui::BackpackScreen::banners({ confirm => $_[0], status => undef }) },
        panels       => sub { tui::BackpackScreen::panels({ rows => [], cursor => 0 }, $_[0]) },
        screen       => sub { tui::BackpackScreen::screen({ rows => [], cursor => 0 }, $_[0]) },
        compose      => sub { tui::BackpackScreen::compose({ rows => [], cursor => 0 }, 24, $_[0]) },
        STATE_LABEL  => sub { tui::BackpackScreen::STATE_LABEL($_[0]) },
        STATE_ROLE   => sub { tui::BackpackScreen::STATE_ROLE($_[0]) },
        status_spans => sub { tui::BackpackScreen::status_spans($_[0]) },
        dispatch_key => sub { tui::BackpackScreen::dispatch_key({ rows => [], cursor => 0 }, $_[0]) },
    );
    my $violations = 0;
    my $first;
    my $warned;
    local $SIG{__WARN__} = sub { $warned = $_[0]; };
    for my $name (sort keys %CALLS) {
        my $fn = $CALLS{$name};
        for my $h (@HOSTILE) {
            $warned = undef;
            my $ok = eval { $fn->($h); 1 };
            if (!$ok || defined $warned) {
                $violations++;
                $first ||= "fn=$name hostile=" . (ref($h) || (defined($h) ? "'$h'" : 'undef'));
            }
        }
    }
    is($violations, 0, 'AC-P5: every public function survives the hostile corpus without dying or warning')
        or diag("  first offender: " . ($first // '(none captured)'));
}

# --- AC-P6: any duration-shaped token extracted from any fixture frame
# (06's superset extractor) matches tui::DashboardScreen::DURATION_RE().
# AC-P6b: the same extractor matches '1h 1m 0s' and '14:32:07'. ---
my $DUR_EXTRACT_RE = qr/(?<![\w.])\d+(?:\.\d+)?\s*(?:sec|secs|s|min|mins|minute|minutes|m|hour|hours|h|day|days|d)(?![\w])|\b\d{1,3}:\d{2}:\d{2}\b|\b\d+h \d+m \d+s\b/;

SKIP: {
    skip('tui::BackpackScreen does not exist yet', 1) unless $BS_OK;
    my $ss = tui::BackpackScreen::init(items => _bp_thin_items(5), approvals => {});
    my $joined = _bp_joined($ss, 40, 120);
    my @tokens = ($joined =~ /$DUR_EXTRACT_RE/g);
    my $bad = grep { $_ !~ tui::DashboardScreen::DURATION_RE() } @tokens;
    is($bad, 0, 'AC-P6: every duration-shaped token in a fixture frame matches DURATION_RE()');
}

{
    like('1h 1m 0s', $DUR_EXTRACT_RE, 'AC-P6b (counter-fixture): the extractor matches "1h 1m 0s"');
    like('14:32:07', $DUR_EXTRACT_RE, 'AC-P6b (counter-fixture): the extractor matches "14:32:07"');
}

# --- AC-P7: the no-launcher guard -- this file slurps its OWN source.
#
# EVERY forbidden pattern/message below is built from CONCATENATED PARTS,
# never written as one literal contiguous substring. Writing any of them
# literally (even inside a description STRING, not just a regex) makes
# THIS CODE self-match ITS OWN detector when this file scans its own
# source -- a real self-trap hit three separate times while authoring
# this oracle: once via the qx-delimiter character class containing the
# literal text "qx[", once via the description text containing the plain
# words "launcher.pl"/"system("/"exec(", and once via the backtick
# detector's regex needing actual backtick characters (which, written
# literally, form their own matching pair). All five are rebuilt below
# from parts so the SOURCE TEXT of this block never contains the
# substring it is checking for. ---
{
    my $self_src = slurp($SELF_PATH);
  SKIP: {
        skip('this file could not read its own source', 5) unless defined $self_src;
        my $stripped = _comment_stripped($self_src);

        my $launcher_name = 'launcher' . '.' . 'pl';
        unlike($stripped, qr/\Q$launcher_name\E/, 'AC-P7: this file does not name the sandbox launcher script');

        my $sys_word = 'sys' . 'tem';
        unlike($stripped, qr/\b\Q$sys_word\E\(/, 'AC-P7: this file never invokes the system builtin as a function call');

        my $exec_word = 'ex' . 'ec';
        unlike($stripped, qr/\b\Q$exec_word\E\(/, 'AC-P7: this file never invokes the exec builtin as a function call');

        my $bt = chr(96);   # a backtick, built from its ordinal so the source never contains one literally
        my $bt_pat = $bt . '[^' . $bt . ']*' . $bt;
        unlike($stripped, qr/$bt_pat/, 'AC-P7: this file contains no backtick-quoted command substitution');

        my $qx_word = 'q' . 'x';
        my $qx_delims = '(' . '{' . '[' . '/';
        unlike($stripped, qr/\b\Q$qx_word\E\s*[\Q$qx_delims\E]/, 'AC-P7: this file contains no qx-quote-like operator');
    }
}

# --- AC-P8: the Decision 15 self-scan -- this file slurps its OWN source
# and asserts it names no is(scalar(@ pin over a frame/panel/cell/banner
# shape other than AC-R2's whitelisted identity, and no is_deeply(...)
# over a whole action-vocabulary/role-set literal (a qw(...) array). ---
{
    my $self_src = slurp($SELF_PATH);
  SKIP: {
        skip('this file could not read its own source', 2) unless defined $self_src;

        my @bad_scalar;
        for my $line (split /\n/, $self_src) {
            next unless $line =~ /is\(\s*scalar\(\@\{?\$?(?:frame|frames|panel|panels|cell|cells|banner|banners)\b/i;
            next if $line =~ /shape-lint: intentional/;
            push @bad_scalar, $line;
        }
        is(scalar(@bad_scalar), 0, 'AC-P8: no is(scalar(@ pin over a frame/panel/cell/banner shape outside the AC-R2 whitelist')
            or diag(join("\n", @bad_scalar));

        my @bad_deeply;
        for my $line (split /\n/, $self_src) {
            push @bad_deeply, $line if $line =~ /is_deeply\(\s*\[\s*qw\(/;
        }
        is(scalar(@bad_deeply), 0, 'AC-P8: no is_deeply(...) pin over a whole action-vocabulary/role-set literal');
    }
}

done_testing();

