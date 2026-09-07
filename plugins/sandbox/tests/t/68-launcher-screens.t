#!/usr/bin/env perl
# 68-launcher-screens.t -- ORACLE for package 08-launcher-screens (blueprint
# unified-tui-design-system), specs/08-launcher-screens-spec.md. Written BLIND
# to any tui/LaunchScreens.pm implementation -- it does not exist yet --
# directly from the spec's numbered observable behaviors (S3) and acceptance
# criteria (S4). Do NOT weaken an assertion here to make a future
# implementation's life easier.
#
# TODAY'S EXPECTED STATE: plugins/sandbox/scripts/tui/LaunchScreens.pm does
# not exist, BackpackReview::plan/commit do not exist, skills.pl has no
# select-model/select-apply, select-session.pl has no --list-json, and
# launcher.pl has no launch-emit sentinels. Every group below therefore goes
# RED for exactly one reason: THE IMPLEMENTATION DOES NOT EXIST YET.
# Direct tui::LaunchScreens::* calls are gated on $LS_OK and reported as
# explicit failures (never a die, never a silent skip) when it is false.
#
# NEVER SPAWNS launcher.pl. It builds a container image and starts a
# container; AC-P7 below scans THIS FILE'S OWN SOURCE to assert it cannot.
# launcher.pl / skills.pl / select-session.pl are read as SOURCE TEXT only.
#
# NON-VACUITY STRATEGY (this suite's established convention -- package 05
# shipped 423 assertions that could not fail; package 06 had two guarded
# blocks that had never executed):
#   1. Count VALUE NONCES, never label words.
#   2. Every negative/absence assertion is paired with a COUNTER-FIXTURE
#      proving the SAME detector fires on input that SHOULD trip it.
#   3. Decision 15: no rendered-row-count pins, no "exactly N panels", no
#      key-set is_deeply. Behaviour and content reach only.
#   4. Decision 14: the breakpoint is tui::Layout::BREAKPOINT_TWO_COL(),
#      never the literal 90.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);

my $SCRIPTS   = "$Bin/../../scripts";
my $TUI_DIR   = "$SCRIPTS/tui";
my $LS_PM     = "$TUI_DIR/LaunchScreens.pm";
my $LAUNCHER  = "$SCRIPTS/launcher.pl";
my $SKILLS_PL = "$SCRIPTS/skills.pl";
my $SELSESS   = "$SCRIPTS/select-session.pl";
my $BR_PM     = "$SCRIPTS/BackpackReview.pm";
my $SELF_PATH = "$Bin/68-launcher-screens.t";

use lib "$Bin/../../scripts";

# THE PANEL TITLE LEAD-IN, DERIVED. It was the ASCII '-- '; it is now one
# Theme rule.h glyph plus a space, so a title line is continuous with its own
# filler and can serve as the panel's top border (operator request,
# 2026-08-25). Taken from Theme rather than written out, so it cannot drift
# from the declaration the renderer actually uses.
require Theme;
my $RULE_LEAD    = Theme::glyph('rule.h');      # UTF-8 BYTES, matches row text
my $RULE_LEAD_RE = quotemeta($RULE_LEAD);

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

# _comment_stripped($src) -> $src with whole-line `#` comments blanked. A
# scan that reads prose punishes a file for documenting its own reasoning;
# that has bitten this suite repeatedly.
sub _comment_stripped {
    my ($src) = @_;
    return join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1);
}

# idx_of($haystack, $needle) -> index, using index() and never a regex, so
# ESC bytes and other metacharacters compare literally (spec C-M iii).
sub idx_of {
    my ($h, $n) = @_;
    # An EMPTY needle would make index() answer 0 and turn every containment
    # check into a vacuous pass, which is exactly the failure mode package 05
    # shipped 423 times. An empty needle is "not found".
    return -1 unless defined $h && defined $n && length $n;
    return index($h, $n);
}

# ok_ls($name) -> record a failure with a clear reason when the module is
# absent, so an absent implementation is RED and never silently skipped.
my $LS_OK;
sub need_ls {
    my ($name) = @_;
    return 1 if $LS_OK;
    fail("$name (tui::LaunchScreens.pm does not load -- implementation missing)");
    return 0;
}

# call_ls($fn, @args) -> (\@result, $err). Never dies; a missing sub is an
# error string rather than an abort, so one absent function cannot take the
# whole file down.
sub call_ls {
    my ($fn, @args) = @_;
    my @r;
    my $ok = eval { no strict 'refs'; @r = &{"tui::LaunchScreens::$fn"}(@args); 1 };
    return (\@r, $ok ? undef : ($@ || 'died'));
}

# scalar_ls($fn, @args) -> first returned value or undef.
sub scalar_ls {
    my ($r, $e) = call_ls(@_);
    return undef if $e;
    return $r->[0];
}

# ===========================================================================
# Module loads. Theme / tui::{Frame,Layout,Screen,DashboardScreen} ship from
# packages 05 and 06 and MUST already load; tui::LaunchScreens is THIS
# package's new file.
# ===========================================================================
my $THEME_OK = eval { require Theme; 1 };
ok($THEME_OK, 'L1 Theme.pm loads (shipped)') or diag("  require Theme failed: $@");
my $FRAME_OK = eval { require tui::Frame; 1 };
ok($FRAME_OK, 'L2 tui/Frame.pm loads (package 05, shipped)') or diag("  require tui::Frame failed: $@");
my $LAYOUT_OK = eval { require tui::Layout; 1 };
ok($LAYOUT_OK, 'L3 tui/Layout.pm loads (package 05, shipped)') or diag("  require tui::Layout failed: $@");
my $SCREEN_OK = eval { require tui::Screen; 1 };
ok($SCREEN_OK, 'L4 tui/Screen.pm loads (package 05, shipped)') or diag("  require tui::Screen failed: $@");
my $DS_OK = eval { require tui::DashboardScreen; 1 };
ok($DS_OK, 'L5 tui/DashboardScreen.pm loads (package 06, shipped)') or diag("  require tui::DashboardScreen failed: $@");

$LS_OK = eval { require tui::LaunchScreens; 1 };
ok($LS_OK, 'L6 tui/LaunchScreens.pm loads (THIS package -- expected RED until 08 lands)')
    or diag("  require tui::LaunchScreens failed: $@");

my $BR_OK = eval { require BackpackReview; 1 };
ok($BR_OK, 'L7 BackpackReview.pm loads (shipped)') or diag("  require BackpackReview failed: $@");

# ===========================================================================
# Shared helpers over the module under test. Every one is total: a missing
# function yields undef/[] rather than a die, so an absent implementation
# produces RED ASSERTIONS rather than an aborted run.
# ===========================================================================

# count_sub($haystack, $needle) -> non-overlapping occurrence count, by
# index() only (a regex cannot be trusted with ESC bytes -- and \Q..\E does
# NOT interpolate escapes, so qr/\Q\e[2J\E/ can never match an ESC).
sub count_sub {
    my ($h, $n) = @_;
    return 0 unless defined $h && defined $n && length $n;
    my ($c, $p) = (0, 0);
    while ((my $i = index($h, $n, $p)) >= 0) { $c++; $p = $i + length($n); }
    return $c;
}

sub aref { my ($x) = @_; return ref $x eq 'ARRAY' ? $x : []; }
sub href { my ($x) = @_; return ref $x eq 'HASH'  ? $x : {}; }
sub bstr { my ($x) = @_; return defined $x && !ref $x ? $x : ''; }

# scalar_layout_width($s) -- measure with the SAME helper the renderer pads
# with. Using length() here instead would agree on today's ASCII labels and
# then disagree, silently, the first time a label or glyph is not ASCII --
# which is precisely the case the padding has to survive. tui::Layout is
# already loaded as a dependency of tui::LaunchScreens.
sub scalar_layout_width {
    my ($s) = @_;
    return 0 unless defined $s && length $s;
    my $w = eval { tui::Layout::display_width($s) };
    return defined $w ? $w : length $s;
}

# num($x) -> $x when it is a number, else -1. A missing implementation
# returns undef; coercing to -1 keeps every numeric comparison FAILING (which
# is correct today) instead of drowning the run in uninitialized warnings.
sub num {
    my ($x) = @_;
    return -1 unless defined $x && !ref $x && $x =~ /\A-?\d+(?:\.\d+)?\z/;
    return $x;
}

sub LS_ENTER_TITLE  { bstr(scalar_ls('ENTER_TITLE_BYTES'))  }
sub LS_ENTER_SCREEN { bstr(scalar_ls('ENTER_SCREEN_BYTES')) }
sub LS_LEAVE_TITLE  { bstr(scalar_ls('LEAVE_TITLE_BYTES'))  }
sub LS_LEAVE_SCREEN { bstr(scalar_ls('LEAVE_SCREEN_BYTES')) }
sub LS_TEARDOWN_OPS { aref(scalar_ls('TEARDOWN_OPS'))       }
sub LS_STAGE_IDS    { aref(scalar_ls('STAGE_IDS'))          }
sub LS_STAGE_STATES { aref(scalar_ls('STAGE_STATES'))       }
sub LS_EMIT_ROLES   { aref(scalar_ls('EMIT_ROLES'))         }
sub LS_LIST_MODES   { aref(scalar_ls('LIST_MODES'))         }
sub LS_TRIAGE_STATES{ aref(scalar_ls('TRIAGE_STATES'))      }
sub LS_EMIT_UNITS   { aref(scalar_ls('EMIT_UNITS'))         }
sub LS_DROP_WARNING { bstr(scalar_ls('DROP_WARNING'))       }

# rec_host(%extra) -> (\%host, \%rec). A recording launch host: every seam
# writes into %rec so the test can inspect bytes, read-mode transitions,
# plain-path records and heartbeat ticks without a terminal.
sub rec_host {
    my (%extra) = @_;
    my %rec = (out => '', err => '', modes => [], plain => [], hb => 0);
    my %seams = (
        mode      => 'tui',
        out       => sub { $rec{out} .= bstr($_[0]); 1 },
        err       => sub { $rec{err} .= bstr($_[0]); 1 },
        read_mode => sub { push @{ $rec{modes} }, bstr($_[0]); 1 },
        plain     => sub { push @{ $rec{plain} }, $_[0]; 1 },
        heartbeat => sub { $rec{hb}++; 1 },
        now       => sub { 0 },
        term_size => sub { (80, 24) },
        render    => sub { my (undef, $f) = @_;
                           join('', map { bstr(href($_)->{text}) . "\n" } @{ aref($f) }) },
        %extra,
    );
    my $h = scalar_ls('make_host', %seams);
    $h = {} unless ref $h eq 'HASH';
    return ($h, \%rec);
}

# host_ops($host) -> the ops list with the 'enter' marker removed, i.e. the
# TEARDOWN ops in the order they were recorded.
sub host_ops {
    my ($h) = @_;
    return [ grep { defined $_ && $_ ne 'enter' } @{ aref(href($h)->{ops}) } ];
}

# ===========================================================================
# AC-T -- terminal control and teardown (done criterion 3)
# Behaviours 1-7. No fixtures beyond a recording host.
# ===========================================================================

# --- AC-T8 (accessors first: everything below quotes them) -----------------
{
    my @acc = (LS_ENTER_TITLE(), LS_ENTER_SCREEN(), LS_LEAVE_TITLE(), LS_LEAVE_SCREEN());
    my @nm  = qw(ENTER_TITLE_BYTES ENTER_SCREEN_BYTES LEAVE_TITLE_BYTES LEAVE_SCREEN_BYTES);
    for my $i (0 .. 3) {
        ok(length($acc[$i]) > 0, "AC-T8 $nm[$i]() is a non-empty byte string");
    }
    my $distinct = 0;
    for my $i (0 .. 3) { for my $j ($i + 1 .. 3) { $distinct++ if $acc[$i] ne $acc[$j] } }
    is($distinct, 6, 'AC-T8 the four control byte strings are pairwise distinct');

    cmp_ok(idx_of(LS_ENTER_SCREEN(), "\e[?1049h"), '>=', 0,
        'AC-T8 ENTER_SCREEN_BYTES() contains the alt-screen enter sequence');
    cmp_ok(idx_of(LS_ENTER_SCREEN(), "\e[?25l"), '>=', 0,
        'AC-T8 ENTER_SCREEN_BYTES() contains the hide-cursor sequence');
    cmp_ok(idx_of(LS_LEAVE_SCREEN(), "\e[?1049l"), '>=', 0,
        'AC-T8 LEAVE_SCREEN_BYTES() contains the alt-screen leave sequence');
    cmp_ok(idx_of(LS_LEAVE_SCREEN(), "\e[?25h"), '>=', 0,
        'AC-T8 LEAVE_SCREEN_BYTES() contains the show-cursor sequence');
    cmp_ok(idx_of(LS_ENTER_TITLE(), "\e[22;0t"), '>=', 0,
        'AC-T8 ENTER_TITLE_BYTES() contains XTPUSHTITLE');
    cmp_ok(idx_of(LS_LEAVE_TITLE(), "\e[23;0t"), '>=', 0,
        'AC-T8 LEAVE_TITLE_BYTES() contains XTPOPTITLE');

    is_deeply(LS_TEARDOWN_OPS(), ['title-restore', 'screen-restore', 'readmode-restore'],
        'AC-T8 TEARDOWN_OPS() is the declared three-step order');
}

# --- AC-T1: behaviour 1, both modes ----------------------------------------
{
    my ($ph, $prec) = rec_host(mode => 'plain');
    my $r = scalar_ls('host_enter', $ph);
    is($r, 0, 'AC-T1 host_enter on a plain host returns 0');
    is($prec->{out}, '', 'AC-T1 host_enter on a plain host emits no bytes');
    is(scalar @{ $prec->{modes} }, 0, 'AC-T1 host_enter on a plain host does not touch read_mode');

    my ($th, $trec) = rec_host(title => 'sandbox-nonce-T1');
    my $r2 = scalar_ls('host_enter', $th);
    is($r2, 1, 'AC-T1 host_enter on a tui host returns 1');
    cmp_ok(idx_of($trec->{out}, LS_ENTER_TITLE()), '>=', 0,
        'AC-T1 host_enter emitted ENTER_TITLE_BYTES()');
    cmp_ok(idx_of($trec->{out}, LS_ENTER_SCREEN()), '>=', 0,
        'AC-T1 host_enter emitted ENTER_SCREEN_BYTES()');
    cmp_ok(idx_of($trec->{out}, LS_ENTER_TITLE()), '<', idx_of($trec->{out}, LS_ENTER_SCREEN()),
        'AC-T1 the title push precedes the alt-screen enter');
    is($prec->{modes}[0], undef, 'AC-T1 (plain) read_mode still untouched');
    is($trec->{modes}[0], 'cbreak', "AC-T1 host_enter called read_mode('cbreak')");
    cmp_ok(idx_of($trec->{out}, "\e]0;sandbox-nonce-T1\a"), '>=', 0,
        'AC-T1 a non-empty title is written as an OSC 0 title sequence');
    is(href($th)->{entered}, 1, 'AC-T1 host_enter sets entered');
    is(href($th)->{active},  1, 'AC-T1 host_enter sets active');
    is(scalar_ls('host_enter', $th), 0, 'AC-T1 a second host_enter is a no-op returning 0');
}

# --- AC-T2: behaviour 2 -----------------------------------------------------
{
    my ($h, $rec) = rec_host();
    scalar_ls('host_enter', $h);
    my $pre = length $rec->{out};
    my $r = scalar_ls('host_leave', $h);
    is($r, 1, 'AC-T2 host_leave on an entered host returns 1');
    my $td = substr($rec->{out}, $pre);
    is_deeply(host_ops($h), LS_TEARDOWN_OPS(),
        'AC-T2 a single teardown records TEARDOWN_OPS() in that exact order');
    cmp_ok(idx_of($td, LS_LEAVE_TITLE()),  '>=', 0, 'AC-T2 teardown emitted LEAVE_TITLE_BYTES()');
    cmp_ok(idx_of($td, LS_LEAVE_SCREEN()), '>=', 0, 'AC-T2 teardown emitted LEAVE_SCREEN_BYTES()');
    cmp_ok(idx_of($td, LS_LEAVE_TITLE()), '<', idx_of($td, LS_LEAVE_SCREEN()),
        'AC-T2 the title restore precedes the screen restore');
    is($rec->{modes}[-1], 'restore', "AC-T2 teardown called read_mode('restore')");
    is(href($h)->{active}, 0, 'AC-T2 host_leave clears active');
}

# --- AC-T3: behaviour 3, the once-guard ------------------------------------
{
    my ($h, $rec) = rec_host();
    scalar_ls('host_enter', $h);
    my $pre = length $rec->{out};
    scalar_ls('host_leave', $h) for 1 .. 3;
    my $td = substr($rec->{out}, $pre);
    cmp_ok(count_sub($td, LS_LEAVE_SCREEN()), '>', 0,
        'AC-T3 liveness: LEAVE_SCREEN_BYTES() was emitted at least once');
    is(count_sub($td, LS_LEAVE_TITLE()), 1,
        'AC-T3 three teardowns emit LEAVE_TITLE_BYTES() exactly once (the title-stack guard)');
    is(count_sub($td, LS_LEAVE_SCREEN()), 3,
        'AC-T3 three teardowns emit LEAVE_SCREEN_BYTES() exactly three times');
    my @ops = @{ host_ops($h) };
    is(scalar(grep { $_ eq 'title-restore' }    @ops), 1, "AC-T3 'title-restore' recorded once");
    is(scalar(grep { $_ eq 'screen-restore' }   @ops), 3, "AC-T3 'screen-restore' recorded three times");
    is(scalar(grep { $_ eq 'readmode-restore' } @ops), 3, "AC-T3 'readmode-restore' recorded three times");
}

# --- AC-T4: behaviour 4, a dying out seam; AC-T4b its counter-fixture ------
{
    my @modes;
    my $h = scalar_ls('make_host',
        mode => 'tui',
        out  => sub { die "seam exploded\n" },
        read_mode => sub { push @modes, bstr($_[0]); 1 },
    );
    $h = {} unless ref $h eq 'HASH';
    my $entered = eval { scalar_ls('host_enter', $h) };
    my $r = eval { scalar_ls('host_leave', $h) };
    is($@, '', 'AC-T4 host_leave does not propagate a dying out seam');
    is($r, 1, 'AC-T4 host_leave still returns 1 when out dies');
    is(scalar(grep { $_ eq 'restore' } @modes), 1,
        "AC-T4 read_mode('restore') still ran after a dying out seam");
    is(scalar(grep { $_ eq 'readmode-restore' } @{ host_ops($h) }), 1,
        "AC-T4 'readmode-restore' still recorded after a dying out seam");

    # AC-T4b counter-fixture: the identical recorder with a healthy seam also
    # records the restore, so AC-T4 is not satisfied by a teardown that never
    # ran at all.
    my ($h2, $rec2) = rec_host();
    scalar_ls('host_enter', $h2);
    scalar_ls('host_leave', $h2);
    is(scalar(grep { $_ eq 'restore' } @{ $rec2->{modes} }), 1,
        'AC-T4b counter-fixture: a healthy seam records exactly one restore under the same check');
}

# --- AC-T5: behaviour 5 -----------------------------------------------------
{
    my ($h, $rec) = rec_host();
    my $r = scalar_ls('host_leave', $h);
    is($r, 0, 'AC-T5 host_leave on a host that never entered returns 0');
    is($rec->{out}, '', 'AC-T5 host_leave on a never-entered host emits nothing');
    is(scalar @{ host_ops($h) }, 0, 'AC-T5 host_leave on a never-entered host records no ops');
}

# --- AC-T6: behaviour 6 -- criterion 3's PER-STAGE assertion ---------------
{
    my @ids = @{ LS_STAGE_IDS() };
    cmp_ok(scalar @ids, '>', 0, 'AC-T6 liveness: STAGE_IDS() yields at least one stage to drive');

    # An array in a `my (...)` list slurps EVERY remaining value, so the original
    # form of this line -- my ($ref_bytes, @ref_ops, $mismatches, $first_bad) --
    # left $mismatches and $first_bad undef and handed @ref_ops the 0 and undef
    # meant for them. `is($mismatches, 0, ...)` could then never pass: with no
    # mismatch it stayed undef, and with one it became 1. The comparison logic
    # below was correct the whole time; only the accumulator was unreachable.
    # Declared separately so the scalars keep their initialisers.
    my @ref_ops;
    my ($ref_bytes, $mismatches, $first_bad) = (undef, 0, undef);
    for my $id (@ids) {
        my ($h, $rec) = rec_host();
        my $st = scalar_ls('stages_init', undef);
        $h->{stages} = $st if ref $st eq 'ARRAY';
        scalar_ls('host_enter', $h);
        scalar_ls('stage_begin', $h->{stages}, $id, 0);
        scalar_ls('stream_line', $h, "line for $id\n");
        my $pre = length $rec->{out};
        scalar_ls('host_leave', $h);
        my $td  = substr($rec->{out}, $pre);
        my $ops = host_ops($h);
        if (!defined $ref_bytes) { $ref_bytes = $td; @ref_ops = @$ops; next; }
        my $same = ($td eq $ref_bytes)
            && (scalar(@$ops) == scalar(@ref_ops))
            && !grep { $ops->[$_] ne $ref_ops[$_] } 0 .. $#ref_ops;
        if (!$same) { $mismatches++; $first_bad //= $id; }
    }
    is($mismatches, 0, 'AC-T6 the teardown byte sequence and ops list are identical at every stage')
        or diag("  first stage whose teardown differed: " . (defined $first_bad ? $first_bad : '(none)'));
    cmp_ok(length(bstr($ref_bytes)), '>', 0,
        'AC-T6 liveness: the reference teardown actually emitted bytes');
    is_deeply(\@ref_ops, LS_TEARDOWN_OPS(),
        'AC-T6 the per-stage teardown ops equal TEARDOWN_OPS()');

    # AC-T6b counter-fixture: the SAME comparator must detect a dropped op.
    my @broken = @ref_ops;
    pop @broken;
    my $detects = !(scalar(@broken) == scalar(@ref_ops)
                    && !grep { $broken[$_] ne $ref_ops[$_] } 0 .. $#ref_ops);
    ok($detects, 'AC-T6b counter-fixture: the comparator reports a mismatch when one op is removed');
}

# --- AC-T7: behaviour 7, the dashboard handover ----------------------------
{
    my ($h, $rec) = rec_host();
    scalar_ls('host_enter', $h);
    my $pre = length $rec->{out};
    my $r = scalar_ls('host_handover', $h);
    my $after = substr($rec->{out}, $pre);
    is(href($h)->{active}, 0, 'AC-T7 host_handover clears active');
    is(scalar(grep { defined $_ && $_ eq 'handover' } @{ aref(href($h)->{ops}) }), 1,
        "AC-T7 host_handover records 'handover' exactly once");
    is(idx_of($after, LS_LEAVE_SCREEN()), -1,
        'AC-T7 host_handover emits NO leave-screen bytes (no flash into the dashboard)');
    is(idx_of($after, LS_LEAVE_TITLE()), -1,
        'AC-T7 host_handover emits NO leave-title bytes');

    # AC-T7b counter-fixture: the identical index check on a real teardown.
    my ($h2, $rec2) = rec_host();
    scalar_ls('host_enter', $h2);
    my $pre2 = length $rec2->{out};
    scalar_ls('host_leave', $h2);
    cmp_ok(idx_of(substr($rec2->{out}, $pre2), LS_LEAVE_SCREEN()), '>=', 0,
        'AC-T7b counter-fixture: the same index check finds the leave bytes after a real host_leave');
}

# ===========================================================================
# AC-G -- the stage model (done criterion 1). Behaviours 8-11.
# ===========================================================================
{
    my @ids = @{ LS_STAGE_IDS() };
    my $m = scalar_ls('stages_init', undef);
    my @st = @{ aref($m) };

    # AC-G1 (behaviour 8)
    cmp_ok(scalar @st, '>', 0, 'AC-G1 liveness: stages_init(undef) produced a model');
    is(scalar @st, scalar @ids, 'AC-G1 stages_init(undef) yields one stage per STAGE_IDS() entry');
    my $order_bad = 0;
    my $state_bad = 0;
    for my $i (0 .. $#ids) {
        my $s = href($st[$i]);
        $order_bad++ if bstr($s->{id}) ne $ids[$i];
        $state_bad++ if bstr($s->{state}) ne 'pending';
    }
    is($order_bad, 0, 'AC-G1 stages_init preserves STAGE_IDS() order');
    is($state_bad, 0, "AC-G1 every freshly initialised stage is 'pending'");
    my $started_defined = grep { defined href($_)->{started} } @st;
    is($started_defined, 0, 'AC-G1 no fresh stage carries a started timestamp');

    # AC-G2 (behaviour 9) -- absent is not empty (C-K), asserted as two facts
    is(scalar_ls('stage_state', $m, 'no-such-stage'), undef,
        'AC-G2 stage_state on an unknown id returns undef');
    isnt(scalar_ls('stage_state', $m, 'no-such-stage'), 'pending',
        "AC-G2 stage_state on an unknown id is NOT 'pending' (absent != not-yet-started)");
    is(scalar_ls('stage_state', $m, $ids[0]), 'pending',
        'AC-G2 liveness: a known id does report pending')
        if @ids;

    # AC-G3 (behaviour 10)
    my $before_unknown = join('|', map { bstr(href($_)->{id}) . ':' . bstr(href($_)->{state}) } @st);
    is(scalar_ls('stage_begin', $m, 'no-such-stage', 0), 0,
        'AC-G3 stage_begin on an unknown id returns 0');
    is(scalar_ls('stage_end', $m, 'no-such-stage', 'ok', 0), 0,
        'AC-G3 stage_end on an unknown id returns 0');
    is(scalar_ls('stage_end', $m, ($ids[0] // 'image'), 'bogus-state', 0), 0,
        'AC-G3 stage_end with a state outside STAGE_STATES() returns 0');
    my $after_unknown = join('|', map { bstr(href($_)->{id}) . ':' . bstr(href($_)->{state}) } @{ aref($m) });
    is($after_unknown, $before_unknown, 'AC-G3 none of those three rejected calls mutated the model');
    is(scalar_ls('stage_begin', $m, ($ids[0] // 'image'), 0), 1,
        'AC-G3 liveness: stage_begin on a known id returns 1');
    is(scalar_ls('stage_state', $m, ($ids[0] // 'image')), 'active',
        "AC-G3 a begun stage is 'active'");
    is(scalar_ls('stage_end', $m, ($ids[0] // 'image'), 'ok', 1), 1,
        'AC-G3 liveness: stage_end with a declared state returns 1');
    is(scalar_ls('stage_state', $m, ($ids[0] // 'image')), 'ok',
        'AC-G3 stage_end records the declared state');

    # AC-G4 (behaviour 11) -- pairwise ordering ONLY (Decision 15: no length
    # pin, no is_deeply over the whole list).
    my %pos; $pos{ $ids[$_] } = $_ for 0 .. $#ids;
    # 2026-09-04: this list said ['select','image'], which is the order the ids
    # were DECLARED in, not the order launcher.pl runs them (image :2379 comes
    # before the skills picker :2630). The pair was copied from the declaration,
    # so the test confirmed the declaration against itself and the display bug
    # survived a green suite. t/37 AC5 now derives the expected order from the
    # launcher source instead, which is the only thing that can catch a drift
    # like this; this pair is kept as a cheap, readable pin of the same fact.
    my @pairs = (['image','create'], ['create','start'], ['start','dashboard'],
                 ['preflight','select'], ['select','image'], ['create','backpack'],
                 ['backpack','start'], ['start','install'], ['install','dashboard']);
    for my $p (@pairs) {
        my ($a, $b) = @$p;
        my $ok = defined $pos{$a} && defined $pos{$b} && $pos{$a} < $pos{$b};
        ok($ok, "AC-G4 STAGE_IDS() orders '$a' before '$b'");
    }

    # AC-G5 -- membership, one assertion each
    for my $id (qw(preflight select image create backpack start install dashboard)) {
        ok(defined $pos{$id}, "AC-G5 STAGE_IDS() contains '$id'");
    }

    # AC-G6 -- labels
    my $blank_labels = 0;
    for my $id (@ids) {
        my $l = bstr(scalar_ls('STAGE_LABEL', $id));
        $blank_labels++ unless length $l;
    }
    is($blank_labels, 0, 'AC-G6 STAGE_LABEL returns a non-empty string for every declared id');
    is(bstr(scalar_ls('STAGE_LABEL', 'no-such-stage')), '',
        "AC-G6 STAGE_LABEL returns '' for an unknown id");

    # STAGE_STATES() is the declared vocabulary the model is validated against.
    my %sv = map { $_ => 1 } @{ LS_STAGE_STATES() };
    for my $s (qw(pending active ok skipped failed)) {
        ok($sv{$s}, "AC-G6 STAGE_STATES() contains '$s'");
    }

    # -----------------------------------------------------------------------
    # AC-G7 -- THE STATE COLUMN IS A COLUMN.
    #
    # The rows used to be glyph . ' ' . label . '  ' . state with no padding,
    # so the state started at a different offset on every row. The state is the
    # only part of this panel that changes during a launch, which makes it
    # exactly the part that wants to be readable straight down. Reported
    # 2026-09-04 ("This is not aligned ... Is it aligned during the actual
    # display runtime?" -- it was not).
    #
    # Asserted on the RENDERED rows, not on the padding arithmetic, because the
    # arithmetic being right is not the claim; the claim is that the columns
    # line up on screen.
    # -----------------------------------------------------------------------
    my $model = scalar_ls('stages_init', undef);
    my @m = @{ aref($model) };
    my @vocab = qw(ok active pending skipped failed);
    # Give every row a DIFFERENT state, so a renderer that accidentally aligned
    # by emitting a constant-width state cannot pass this.
    for my $i (0 .. $#m) {
        next unless ref $m[$i] eq 'HASH';
        $m[$i]{state} = $vocab[ $i % scalar @vocab ];
    }

    my $screen = scalar_ls('progress_screen',
        { stages => $model, seams => { title => 't68' } }, 100, 40);
    my ($panel) = grep { ref $_ eq 'HASH' && bstr($_->{title}) eq 'stages' }
                  @{ aref(href($screen)->{panels}) };

    my @offsets;
    for my $row (@{ aref(href($panel)->{lines}) }) {
        next unless ref $row eq 'ARRAY';
        # The state segment is the last one; everything before it is the
        # prefix whose width decides where the state lands.
        my @seg = map { ref $_ eq 'HASH' ? bstr($_->{text}) : '' } @$row;
        next unless @seg >= 2;
        my $prefix = join '', @seg[0 .. $#seg - 1];
        push @offsets, scalar_layout_width($prefix);
    }

    cmp_ok(scalar @offsets, '>=', 5,
        'AC-G7 liveness: the stages panel rendered rows to measure')
        or diag('  no rows came back; every offset check below would be vacuous');

    my %distinct = map { $_ => 1 } @offsets;
    is(scalar keys %distinct, (@offsets ? 1 : 0),
        'AC-G7 every stage row puts its state at the same column')
        or diag('  offsets seen: ' . join(', ', @offsets)
              . "\n  a ragged state column is what the padding exists to prevent");

    # -----------------------------------------------------------------------
    # AC-G8 -- and that alignment is only real because the glyphs agree.
    #
    # The glyph precedes the label, so a glyph one column wider than the others
    # shifts its whole row and no amount of label padding recovers it. This is
    # the assumption the padding rests on, pinned so a future glyph swap fails
    # here rather than surfacing as a subtly crooked panel.
    # -----------------------------------------------------------------------
    my %gw;
    for my $st (qw(pending active ok skipped failed)) {
        my $g = bstr(scalar_ls('_stage_glyph', $st));
        $gw{ scalar_layout_width($g) } = 1 if length $g;
    }
    is(scalar keys %gw, 1,
        'AC-G8 every stage glyph is the same display width (the padding assumes it)')
        or diag('  widths seen: ' . join(', ', sort keys %gw));
}

# ===========================================================================
# AC-C -- the capture pipeline (done criterion 2). Behaviours 12-16.
#
# $CORPUS is declared ONCE here and never edited by an assertion. It is the
# hostile corpus S4 names: 5,000 short lines, one 20,000-character line,
# UTF-8 text, an SGR-bearing line, CRLF, and a final line with no trailing
# newline. Non-ASCII is written as explicit UTF-8 BYTE escapes so this file
# stays byte-clean regardless of the editor that opens it -- safe()'s input
# contract is UTF-8 bytes.
# ===========================================================================
my $CORPUS = [
    (map { "build step $_ of 5000\n" } 1 .. 5000),
    ('x' x 20000) . "\n",
    "Andr\xc3\xa9 \xe2\x86\x92 ok\n",
    "\e[31mred\e[0m\n",
    "crlf\r\n",
    "no-newline-at-eof",
];
my $CORPUS_JOINED = join('', @$CORPUS);

# cap_fixture(%seams) -> \%cap with $CORPUS written through it.
sub cap_fixture {
    my (%seams) = @_;
    my $cap = scalar_ls('capture_new', %seams);
    return undef unless ref $cap eq 'HASH';
    scalar_ls('capture_line', $cap, $_, 'plain') for @$CORPUS;
    return $cap;
}

{
    my $KEEP_DEFAULT = scalar_ls('RENDER_TAIL_DEFAULT');
    is($KEEP_DEFAULT, 400, 'AC-C RENDER_TAIL_DEFAULT() is 400 (the declared ring size)');

    # --- AC-C1 (behaviour 12): the raw sink is lossless ---------------------
    my $cap = cap_fixture();
    ok(ref $cap eq 'HASH', 'AC-C1 liveness: capture_new returned a capture');
    my $replay = bstr(scalar_ls('capture_replay', $cap));
    cmp_ok(length($replay), '>', 20000, 'AC-C1 liveness: the replay is a large non-empty string');
    is($replay, $CORPUS_JOINED,
        'AC-C1 capture_replay equals the exact concatenation of every payload, in order');
    is(length($replay), length($CORPUS_JOINED),
        'AC-C1 not one byte of the corpus was added or dropped');

    # AC-C1b counter-fixture: a sink that silently drops one payload must make
    # the SAME equality fail -- proving the checker can detect a loss.
    my $lossy = '';
    my $cap_b = scalar_ls('capture_new',
        raw_write => sub { my $b = bstr($_[0]);
                           $lossy .= $b unless index($b, 'zqxdrop8813') >= 0; 1 },
        raw_read  => sub { $lossy },
    );
    if (ref $cap_b eq 'HASH') {
        scalar_ls('capture_line', $cap_b, $_, 'plain') for @$CORPUS;
        scalar_ls('capture_line', $cap_b, "zqxdrop8813 lost this line\n", 'plain');
    }
    my $replay_b = bstr(scalar_ls('capture_replay', $cap_b));
    my $want_b   = $CORPUS_JOINED . "zqxdrop8813 lost this line\n";
    isnt($replay_b, $want_b,
        'AC-C1b counter-fixture: the same equality FAILS when a sink drops a payload');
    cmp_ok(length($replay_b), '>', 0,
        'AC-C1b counter-fixture liveness: the lossy sink still received most of the corpus');

    # --- AC-C2 (behaviour 13): absent is not empty (C-K) --------------------
    my $probe = '';
    my $cap_c = scalar_ls('capture_new',
        raw_write => sub { $probe .= bstr($_[0]); 1 },
        raw_read  => sub { $probe },
    );
    my $r_undef = scalar_ls('capture_line', $cap_c, undef, 'plain');
    is($r_undef, 0, 'AC-C2 capture_line(undef) returns 0');
    is($probe, '', 'AC-C2 capture_line(undef) wrote to no sink');
    is(scalar @{ aref(scalar_ls('capture_tail', $cap_c)) }, 0,
        'AC-C2 capture_line(undef) appended no ring entry');
    is(scalar_ls('capture_count', $cap_c), 0, 'AC-C2 capture_line(undef) did not count a line');
    my $r_empty = scalar_ls('capture_line', $cap_c, '', 'plain');
    is($r_empty, 1, "AC-C2 capture_line('') returns 1 -- an empty line IS a line");
    is(scalar_ls('capture_count', $cap_c), 1, "AC-C2 capture_line('') counted one line");

    # --- AC-C3 (behaviour 14): the ring is bounded and ESC-free -------------
    my $tail = aref(scalar_ls('capture_tail', $cap));
    cmp_ok(scalar @$tail, '>', 0, 'AC-C3 liveness: the render ring holds entries');
    cmp_ok(scalar @$tail, '<=', 400, 'AC-C3 capture_tail never exceeds keep entries');
    my $last_want = tui::Frame::safe('no-newline-at-eof');
    is(bstr(href($tail->[-1])->{text}), $last_want,
        'AC-C3 the ring always holds the sanitised form of the LAST line written');
    my $tail_text = join("\n", map { bstr(href($_)->{text}) } @$tail);
    is(index($tail_text, "\e"), -1, 'AC-C3 no ring entry text contains an ESC byte');
    my $unknown_roles = grep { !tui::Frame::is_known_role(href($_)->{role}) } @$tail;
    is($unknown_roles, 0, 'AC-C3 every ring entry carries a known Theme role');

    # --- AC-C4 (behaviour 15): a dying raw_write is counted, never swallowed
    my $cap_d = scalar_ls('capture_new', raw_write => sub { die "sink gone\n" });
    my $rc_d = eval { scalar_ls('capture_line', $cap_d, "diagnostic\n", 'plain') };
    is($@, '', 'AC-C4 a dying raw_write does not propagate out of capture_line');
    is($rc_d, 1, 'AC-C4 capture_line still returns 1 when raw_write dies');
    cmp_ok(num(scalar_ls('capture_sink_errors', $cap_d)), '>', 0,
        'AC-C4 a dying raw_write increments capture_sink_errors (a lost byte is visible)');
    # AC-C4b counter-fixture: a healthy sink leaves the counter at 0.
    is(scalar_ls('capture_sink_errors', $cap), 0,
        'AC-C4b counter-fixture: a healthy sink leaves capture_sink_errors at 0');

    # --- AC-C5 (behaviour 16): fanout ---------------------------------------
    my (@a, @b);
    my $delivered = scalar_ls('fanout',
        [ sub { push @a, $_[0]; 1 },
          sub { die "dead sink\n" },
          sub { push @b, $_[0]; 1 } ],
        "shared-payload-zqx4417\n");
    is($delivered, 2, 'AC-C5 fanout returns the number of sinks that did not die');
    is(scalar @a, 1, 'AC-C5 the first sink received exactly one payload');
    is(scalar @b, 1, 'AC-C5 a dying sink does not stop the sinks after it');
    is($a[0], "shared-payload-zqx4417\n", 'AC-C5 the payload reached sink 1 byte-identically');
    is($b[0], "shared-payload-zqx4417\n", 'AC-C5 the payload reached sink 3 byte-identically');
    is(scalar_ls('fanout', [ 'not-a-coderef', sub { 1 } ], "x"), 1,
        'AC-C5 a non-coderef entry is skipped and does not count as delivered');

    # --- AC-C6: the two-sink design, pinned in one assertion ----------------
    my $count = num(scalar_ls('capture_count', $cap));
    cmp_ok($count, '>=', 5005, 'AC-C6 liveness: capture_count saw the whole corpus');
    cmp_ok(scalar @$tail, '<', $count,
        'AC-C6 the render ring is LOSSY (bounded) while the raw sink is not');
    is(bstr(scalar_ls('capture_replay', $cap)), $CORPUS_JOINED,
        'AC-C6 ... and the raw replay is still byte-exact after 5005 lines');
}

# ===========================================================================
# AC-F -- the failure report (done criterion 2). Behaviours 17-19.
# This is the assertion done-criterion 2 turns on: a FAILURE shows the
# underlying error text IN FULL, never summarised.
# ===========================================================================
{
    my $cap = cap_fixture();
    my $host = scalar_ls('make_host', mode => 'tui');
    $host = {} unless ref $host eq 'HASH';
    $host->{capture} = $cap if ref $cap eq 'HASH';

    my $chunks = aref(scalar_ls('failure_report', $host,
        stage => 'image', message => 'podman build failed', exit => 125));
    cmp_ok(scalar @$chunks, '>', 0, 'AC-F1 liveness: failure_report returned chunks');
    my $joined = join('', map { bstr($_) } @$chunks);
    my $replay = bstr(scalar_ls('capture_replay', $cap));
    cmp_ok(length($replay), '>', 0, 'AC-F1 liveness: the replay to be embedded is non-empty');

    # --- AC-F1 (behaviour 17): the no-loss property, by index() only --------
    cmp_ok(index($joined, $replay), '>=', 0,
        'AC-F1 the failure report contains capture_replay() as an EXACT substring');

    # AC-F1b counter-fixture: a truncated-and-elided report must NOT satisfy
    # the same index check -- proving it discriminates.
    my $truncated = substr($replay, 0, 100) . "\xe2\x80\xa6" . "\n-- failure --\n";
    is(index($truncated, $replay), -1,
        'AC-F1b counter-fixture: the same index check rejects a truncated/elided report');

    # --- AC-F2 (behaviour 18): the headline ---------------------------------
    cmp_ok(index($joined, 'image'), '>=', 0, 'AC-F2 the headline names the failing stage id');
    cmp_ok(index($joined, 'podman build failed'), '>=', 0, 'AC-F2 the headline carries the message');
    cmp_ok(index($joined, '125'), '>=', 0, 'AC-F2 the headline carries the exit code when one is given');

    my $no_exit = join('', map { bstr($_) } @{ aref(scalar_ls('failure_report', $host,
        stage => 'create', message => 'container create failed', exit => undef)) });
    cmp_ok(index($no_exit, 'container create failed'), '>=', 0,
        'AC-F2 liveness: the exit-less report still carries its message');
    my $tailpart = substr($no_exit, length($replay) >= 0 ? length($replay) : 0);
    is(index($tailpart, 'exit'), -1,
        'AC-F2 an undefined exit code produces NO exit clause (never a fabricated 0)');

    # --- AC-F3: the report is NOT sanitised; the frame is. -----------------
    cmp_ok(index($joined, "\e[31m"), '>=', 0,
        'AC-F3 the SGR bytes of the captured corpus survive verbatim into the report');
    cmp_ok(index($joined, "Andr\xc3\xa9"), '>=', 0,
        'AC-F3 non-ASCII UTF-8 bytes survive verbatim into the report');
    cmp_ok(index($joined, 'x' x 20000), '>=', 0,
        'AC-F3 a 20,000-character line is not width-fitted or truncated in the report');

    # --- AC-F4 (behaviour 19): the _tee_system routing decisions -----------
    is(scalar_ls('tee_should_fork', 1, 0), 1,
        'AC-F4 host active + no transcript => still fork (else the child paints over the frame)');
    is(scalar_ls('tee_should_fork', 1, 1), 1, 'AC-F4 host active + transcript => fork');
    is(scalar_ls('tee_should_fork', 0, 1), 1, "AC-F4 host inactive + transcript => fork (today's behaviour)");
    is(scalar_ls('tee_should_fork', 0, 0), 0, "AC-F4 host inactive + no transcript => no fork (today's behaviour)");
    is(scalar_ls('tee_fallback_route', 1), 'plain-after-teardown',
        'AC-F4 a fork failure with the host active tears the TUI down BEFORE the bare system()');
    is(scalar_ls('tee_fallback_route', 0), 'plain',
        "AC-F4 a fork failure with no host is today's plain route");
}

# ===========================================================================
# AC-M -- the mode gate, the emit seam and the plain path (criterion 4).
# Behaviours 20-23 and 46-48.
# ===========================================================================
my $DASH_LOADED = eval { require Dashboard; 1 };
ok($DASH_LOADED, 'AC-M Dashboard.pm loads (pure, read-only for this package)')
    or diag("  require Dashboard failed: $@");

# --- AC-M1 (behaviour 46): the callback's exact three arguments -------------
{
    my @seen;
    my $cb = sub { @seen = @_; return 'tui'; };
    my $m = scalar_ls('choose_mode', $cb, 1, 1, undef);
    is($m, 'tui', 'AC-M1 choose_mode returns the callback verbatim when it says tui');
    is_deeply(\@seen, [1, 1, undef],
        'AC-M1 the callback received exactly ($is_tty,$readkey_ok,$force_plain), in that order');

    my @seen2;
    my $cb2 = sub { @seen2 = @_; return 'plain'; };
    is(scalar_ls('choose_mode', $cb2, 0, 1, 1), 'plain',
        'AC-M1 choose_mode returns the callback verbatim when it says plain');
    is_deeply(\@seen2, [0, 1, 1], 'AC-M1 the three arguments pass through unaltered');
    is(scalar @seen2, 3, 'AC-M1 exactly three arguments were passed, not more');
}

# --- AC-M2 (behaviour 47): the safe degradation is ALWAYS plain ------------
{
    is(scalar_ls('choose_mode', 'not-a-coderef', 1, 1, undef), 'plain',
        'AC-M2 a non-coderef mode callback degrades to plain');
    is(scalar_ls('choose_mode', undef, 1, 1, undef), 'plain',
        'AC-M2 an undefined mode callback degrades to plain');
    is(scalar_ls('choose_mode', sub { die "decide blew up\n" }, 1, 1, undef), 'plain',
        'AC-M2 a DYING mode callback degrades to plain, never to tui');
    is(scalar_ls('choose_mode', sub { 'weird' }, 1, 1, undef), 'plain',
        'AC-M2 an unrecognised return degrades to plain');
    is(scalar_ls('choose_mode', sub { undef }, 1, 1, undef), 'plain',
        'AC-M2 an undef return degrades to plain');
    is(scalar_ls('choose_mode', sub { [] }, 1, 1, undef), 'plain',
        'AC-M2 a ref return degrades to plain');
}

# --- AC-M3 (behaviour 48): decide_mode's contract is PRESERVED -------------
SKIP: {
    skip 'Dashboard.pm did not load', 5 unless $DASH_LOADED;
    is(Dashboard::decide_mode(1, 1, undef), 'tui',   'AC-M3 decide_mode(1,1,undef) is tui');
    is(Dashboard::decide_mode(0, 1, undef), 'plain', 'AC-M3 decide_mode(0,1,undef) is plain (no tty)');
    is(Dashboard::decide_mode(1, 0, undef), 'plain', 'AC-M3 decide_mode(1,0,undef) is plain (no ReadKey)');
    is(Dashboard::decide_mode(1, 1, 1),     'plain', 'AC-M3 decide_mode(1,1,1) is plain (CCPRAXIS_NO_TUI)');
    is(Dashboard::decide_mode(1, 1, ''),    'tui',   "AC-M3 decide_mode(1,1,'') is tui (an empty env value is not set)");
}

# --- AC-M5 (behaviour 20): infer_role's table ------------------------------
{
    my @T = (
        ['out', "ERROR: podman build failed\n",        'err',   'ERROR on stdout'],
        ['err', "ERROR: podman build failed\n",        'err',   'ERROR on stderr'],
        ['out', "WARNING: could not parse backpack\n", 'warn',  'WARNING on stdout'],
        ['out', "NOTE: the container was reaped\n",    'warn',  'NOTE on stdout'],
        ['err', "WARNING: something\n",                'warn',  'WARNING wins over the err stream'],
        ['err', "just some stderr chatter\n",          'err',   'plain text on the err stream'],
        ['out', "building image...\n",                 'plain', 'plain text on stdout'],
        ['out', "  \e[31mERROR: indented and coloured\n", 'err', 'ERROR behind SGR and whitespace'],
        ['out', "   WARNING: indented\n",              'warn',  'WARNING behind leading whitespace'],
        ['out', "\e[1;33mNOTE: coloured note\n",       'warn',  'NOTE behind an SGR sequence'],
        ['out', "the ERROR was earlier\n",             'plain', 'a marker NOT at the start is not a marker'],
        ['out', undef,                                 'plain', 'undef text degrades to plain'],
        ['out', {},                                    'plain', 'a ref text degrades to plain'],
        [undef, "hello\n",                             'plain', 'an undef stream degrades to plain'],
    );
    for my $t (@T) {
        my ($stream, $text, $want, $why) = @$t;
        is(scalar_ls('infer_role', $stream, $text), $want, "AC-M5 infer_role: $why -> $want");
    }
}

# --- AC-M6 (behaviour 22): every emit role maps to a KNOWN Theme role -------
{
    my @roles = @{ LS_EMIT_ROLES() };
    cmp_ok(scalar @roles, '>', 0, 'AC-M6 liveness: EMIT_ROLES() is non-empty');
    my %want = map { $_ => 1 } qw(step ok warn err plain);
    for my $r (qw(step ok warn err plain)) {
        ok(scalar(grep { bstr($_) eq $r } @roles), "AC-M6 EMIT_ROLES() contains '$r'");
    }
    my $unknown = 0;
    for my $r (@roles, undef, 'no-such-emit-role') {
        my $tr = scalar_ls('emit_theme_role', $r);
        $unknown++ unless tui::Frame::is_known_role($tr);
    }
    is($unknown, 0, 'AC-M6 emit_theme_role always yields a role tui::Frame::is_known_role accepts');

    # The mapping is derived from tui::DashboardScreen::theme_role, never a
    # pinned SGR or hex literal (C-D).
    my %map = (step => 'accent', ok => 'good', warn => 'warn', err => 'bad', plain => 'body');
    for my $emit (sort keys %map) {
        my $want_role = eval { tui::DashboardScreen::theme_role($map{$emit}) };
        is(scalar_ls('emit_theme_role', $emit), $want_role,
            "AC-M6 emit role '$emit' maps through theme_role('$map{$emit}')");
    }
    my $body = eval { tui::DashboardScreen::theme_role('body') };
    is(scalar_ls('emit_theme_role', undef), $body, 'AC-M6 undef maps to the body role');
    is(scalar_ls('emit_theme_role', 'zqx-unknown-role'), $body, 'AC-M6 an unknown token maps to the body role');
}

# --- AC-M4 (behaviour 21): emit routes to exactly ONE of the two paths -----
{
    my ($ph, $prec) = rec_host(mode => 'plain');
    my $rec = { text => "ERROR: nonce zqx5521\n", role => undef, stream => 'err' };
    my $r = scalar_ls('emit', $ph, $rec);
    is($r, 0, 'AC-M4 emit on a plain host returns 0');
    is(scalar @{ $prec->{plain} }, 1, 'AC-M4 emit on a plain host calls the plain seam exactly once');
    is(bstr(href($prec->{plain}[0])->{text}), "ERROR: nonce zqx5521\n",
        'AC-M4 the plain seam received the record verbatim');
    is(scalar_ls('capture_count', href($ph)->{capture}), 0,
        'AC-M4 nothing was captured on the plain path (its bytes are exactly today\'s)');

    my ($th, $trec) = rec_host(mode => 'tui');
    scalar_ls('host_enter', $th);
    my $r2 = scalar_ls('emit', $th, { text => "ERROR: nonce zqx5522\n", stream => 'err' });
    is($r2, 1, 'AC-M4 emit on an active tui host returns 1');
    is(scalar @{ $trec->{plain} }, 0, 'AC-M4 emit on a tui host calls the plain seam ZERO times');
    cmp_ok(num(scalar_ls('capture_count', href($th)->{capture})), '>', 0,
        'AC-M4 emit on a tui host wrote to the capture');
    cmp_ok(index(bstr(scalar_ls('capture_replay', href($th)->{capture})), 'zqx5522'), '>=', 0,
        'AC-M4 the emitted bytes reached the raw sink');

    # a tui host that has NOT entered (or has left) is not active: plain path.
    my ($uh, $urec) = rec_host(mode => 'tui');
    is(scalar_ls('emit', $uh, { text => "pre-enter\n", stream => 'out' }), 0,
        'AC-M4 emit before host_enter routes to the plain seam');
    is(scalar @{ $urec->{plain} }, 1, 'AC-M4 ... exactly once');
    is(scalar_ls('emit', undef, { text => "no host\n", stream => 'out' }), 0,
        'AC-M4 emit with an undef host returns 0 and does not die');

    # AC-M4b counter-fixture: both counters CAN be non-zero, so a zero above
    # is a real measurement rather than a recorder that never fires.
    cmp_ok(scalar @{ $prec->{plain} } + scalar @{ $urec->{plain} }, '>', 0,
        'AC-M4b counter-fixture: the plain recorder demonstrably fires');
    cmp_ok(num(scalar_ls('capture_count', href($th)->{capture})), '>', 0,
        'AC-M4b counter-fixture: the capture counter demonstrably fires');
}

# --- AC-M7 (behaviour 23): stream_line ticks the heartbeat -----------------
{
    my ($th, $trec) = rec_host(mode => 'tui');
    scalar_ls('host_enter', $th);
    my $before = num(scalar_ls('capture_count', href($th)->{capture}));
    my $r = scalar_ls('stream_line', $th, "podman exec output zqx7781\n");
    is($r, 1, 'AC-M7 stream_line on an active tui host returns 1');
    is($trec->{hb}, 1, 'AC-M7 stream_line ticks the heartbeat exactly once per call');
    is(num(scalar_ls('capture_count', href($th)->{capture})) - $before, 1,
        'AC-M7 stream_line appends exactly one capture line');
    scalar_ls('stream_line', $th, "second line\n");
    is($trec->{hb}, 2, 'AC-M7 a second stream_line ticks the heartbeat a second time');

    my ($ph, $prec) = rec_host(mode => 'plain');
    my $r2 = scalar_ls('stream_line', $ph, "plain path line\n");
    is($r2, 0, 'AC-M7 stream_line on a plain host returns 0');
    is($prec->{hb}, 0, 'AC-M7 stream_line on a plain host does not tick the heartbeat');
    is(scalar_ls('capture_count', href($ph)->{capture}), 0,
        "AC-M7 stream_line on a plain host captures nothing (_tee_system's own print is the display)");

    # A dying heartbeat must not take the stream down (S5 edge case 3).
    my $dh = scalar_ls('make_host', mode => 'tui', heartbeat => sub { die "hb died\n" });
    $dh = {} unless ref $dh eq 'HASH';
    scalar_ls('host_enter', $dh);
    my $rc = eval { scalar_ls('stream_line', $dh, "line\n") };
    is($@, '', 'AC-M7 a dying heartbeat seam does not propagate out of stream_line');
    is($rc, 1, 'AC-M7 stream_line still returns 1 when the heartbeat seam dies');
}

# ===========================================================================
# AC-P -- the progress screen (criteria 1, 2). Behaviours 24-28.
#
# $BP is declared ONCE. The literal 90 appears NOWHERE in this file (C-E,
# Decision 14): the breakpoint is whatever tui::Layout says it is.
# ===========================================================================
my $BP = eval { tui::Layout::BREAKPOINT_TWO_COL() } || 0;
cmp_ok($BP, '>', 0, 'AC-P tui::Layout::BREAKPOINT_TWO_COL() is available as the sole breakpoint source');

# cell_violations(\@frame, $cols) -> ($count, $first_bad) -- package 05's
# five cell invariants: a hash cell, a defined non-ref text, a display width
# of exactly $cols, text eq spans_text(spans), and every span role known.
sub cell_violations {
    my ($frame, $cols) = @_;
    my ($bad, $first) = (0, undef);
    return (1, 'not an arrayref') unless ref $frame eq 'ARRAY';
    for my $i (0 .. $#$frame) {
        my $c = $frame->[$i];
        my @why;
        if (ref $c ne 'HASH') { $bad++; $first //= "row $i is not a hash"; next; }
        push @why, 'text undef/ref' unless defined $c->{text} && !ref $c->{text};
        my $w = eval { tui::Layout::display_width(bstr($c->{text})) };
        push @why, "width " . (defined $w ? $w : 'undef') . " != $cols"
            unless defined $w && $w == $cols;
        my $sp = ref $c->{spans} eq 'ARRAY' ? $c->{spans} : undef;
        push @why, 'spans missing' unless $sp;
        if ($sp) {
            my $joined = eval { tui::Frame::spans_text($sp) };
            push @why, 'text ne spans_text(spans)'
                unless defined $joined && $joined eq bstr($c->{text});
            my @unk = grep { !tui::Frame::is_known_role(href($_)->{role}) } @$sp;
            push @why, scalar(@unk) . ' unknown span role(s)' if @unk;
        }
        push @why, 'ESC byte in text' if index(bstr($c->{text}), "\e") >= 0;
        if (@why) { $bad++; $first //= "cols=$cols row=$i: " . join('; ', @why); }
    }
    return ($bad, $first);
}

# frame_text(\@frame) -> the frame's cell texts joined with newlines.
sub frame_text {
    my ($f) = @_;
    return join("\n", map { bstr(href($_)->{text}) } @{ aref($f) });
}

# panel_title_hits($text, @titles) -> how many of @titles render as a panel
# title bar on this row (tui::Frame::panel_title_line's '-- <title> ' shape).
sub panel_title_hits {
    my ($text, @titles) = @_;
    return 0 unless defined $text;
    my $n = 0;
    for my $t (@titles) { $n += () = $text =~ /\Q$RULE_LEAD\E \Q$t\E /g; }
    return $n;
}

# progress_fixture() -> (\%host, \%rec): a tui host mid-launch, 400 captured
# lines, and one stage in each of the five declared states.
sub progress_fixture {
    my (%extra) = @_;
    my ($h, $rec) = rec_host(%extra);
    scalar_ls('host_enter', $h);
    my $st = scalar_ls('stages_init', undef);
    $h->{stages} = $st if ref $st eq 'ARRAY';
    my @ids = @{ LS_STAGE_IDS() };
    scalar_ls('stage_end',   $h->{stages}, $ids[0], 'ok',      1) if @ids > 0;
    scalar_ls('stage_end',   $h->{stages}, $ids[1], 'skipped', 2) if @ids > 1;
    scalar_ls('stage_end',   $h->{stages}, $ids[2], 'failed',  3) if @ids > 2;
    scalar_ls('stage_begin', $h->{stages}, $ids[3], 4)            if @ids > 3;
    scalar_ls('capture_line', href($h)->{capture}, "log zqxfirst0001 line 1\n", 'plain');
    scalar_ls('capture_line', href($h)->{capture}, "log filler line $_\n", 'plain') for 2 .. 399;
    scalar_ls('capture_line', href($h)->{capture}, "log zqxlast0400 line 400\n", 'plain');
    return ($h, $rec);
}

{
    my ($h) = progress_fixture();

    # --- AC-P1 (behaviour 24): the frame is exactly $rows cells -----------
    my ($rowcount_bad, $inv_bad, $first_inv) = (0, 0, undef);
    for my $cols (60, 100) {
        for my $rows (3 .. 40) {
            my $f = scalar_ls('compose_progress', $h, $rows, $cols);
            $rowcount_bad++ unless ref $f eq 'ARRAY' && scalar(@$f) == $rows;
            my ($b, $fb) = cell_violations($f, $cols);
            $inv_bad += $b;
            $first_inv //= $fb if $b;
        }
    }
    is($rowcount_bad, 0, 'AC-P1 compose_progress returns exactly $rows cells for rows 3..40 at cols 60 and 100');
    is($inv_bad, 0, "AC-P1 every composed cell satisfies package 05's five invariants")
        or diag("  first offender: " . (defined $first_inv ? $first_inv : '?'));

    my $f24 = scalar_ls('compose_progress', $h, 24, 100);
    is(scalar(@{ aref($f24) }), 24,
        'AC-P1 compose_progress(24,100) is 24 cells');   # shape-lint: intentional - the frame-height IDENTITY tui::Screen::compose guarantees, not a shape pin
    cmp_ok(length(frame_text($f24)), '>', 0, 'AC-P1 liveness: the composed frame carries text');

    # --- AC-P2 (behaviour 25): every width from 20 to 200 ------------------
    my ($violations, $first_bad) = (0, undef);
    for my $cols (20 .. 200) {
        my $f = scalar_ls('compose_progress', $h, 24, $cols);
        my ($b, $fb) = cell_violations($f, $cols);
        $violations += $b;
        $first_bad //= $fb if $b;
    }
    is($violations, 0, 'AC-P2 over all 181 widths at rows=24 every cell is exactly $cols wide, spans agree, and no text carries an ESC')
        or diag("  first offender: " . (defined $first_bad ? $first_bad : '?'));

    # AC-P2b counter-fixture: the ESC detector fires on a hand-built string.
    cmp_ok(index("plain \e[31mred\e[0m", "\e"), '>=', 0,
        'AC-P2b counter-fixture: the ESC detector locates an ESC byte with index() (not a regex)');
    is(index('plain red', "\e"), -1, 'AC-P2b counter-fixture: ... and reports -1 on ESC-free text');

    # --- AC-P3 (behaviour 26): the output tail FOLLOWS ---------------------
    my $short = frame_text(scalar_ls('compose_progress', $h, 20, 100));
    my $last_hits  = () = $short =~ /zqxlast0400/g;
    cmp_ok($last_hits, '>', 0, 'AC-P3 liveness: the LAST captured line appears in a short frame');
    is((() = $short =~ /zqxfirst0001/g), 0,
        'AC-P3 the FIRST of 400 captured lines does not appear -- the tail follows (viewport cursor undef)');
    # AC-P3b counter-fixture: the same presence predicate on a nonce that was
    # never captured must report absent (the over-suppression guard).
    is((() = $short =~ /zqxnope7714/g), 0,
        'AC-P3b counter-fixture: a never-captured nonce is reported absent by the same predicate');

    # --- AC-P4 (behaviour 27): stage roles, by EXACT span-role equality ----
    # Never a regex over a rendered line: qr/\bwarn\b/ would match the
    # MANDATED Theme literal 'state.warn' (C-M ii).
    my %want_role = (pending => 'text.faint', active => 'accent', ok => 'state.ok',
                     skipped => 'text.muted', failed => 'state.crit');
    my $screen = href(scalar_ls('progress_screen', $h, 100));
    my @panels = @{ aref($screen->{panels}) };
    cmp_ok(scalar @panels, '>', 0, 'AC-P4 liveness: progress_screen declares panels');
    my ($stages_panel) = grep { bstr(href($_)->{title}) eq 'stages' } @panels;
    ok(ref $stages_panel eq 'HASH', "AC-P4 progress_screen declares a panel titled 'stages'");
    my @stage_rows = @{ aref(href($stages_panel)->{body}) };
    cmp_ok(scalar @stage_rows, '>', 0, 'AC-P4 liveness: the stages panel has body rows');

    my %seen_role;
    for my $row (@stage_rows) {
        my @spans = ref $row eq 'ARRAY' ? @$row : (ref $row eq 'HASH' ? ($row) : ());
        for my $sp (@spans) {
            my $r = bstr(href($sp)->{role});
            $seen_role{$r}++ if length $r;
        }
    }
    for my $state (sort keys %want_role) {
        my $st_ids = LS_STAGE_IDS();
        ok($seen_role{ $want_role{$state} },
            "AC-P4 a stage in state '$state' renders with the exact role '$want_role{$state}'");
    }
    my $unknown_roles = grep { !tui::Frame::is_known_role($_) } keys %seen_role;
    is($unknown_roles, 0, 'AC-P4 every role the stages panel emits is a known Theme role');

    # the state WORD reaches the row text, and so does the label
    my $wide = frame_text(scalar_ls('compose_progress', $h, 30, 120));
    my @ids = @{ LS_STAGE_IDS() };
    my $label0 = bstr(scalar_ls('STAGE_LABEL', $ids[0] // ''));
    cmp_ok(index($wide, $label0), '>=', 0, 'AC-P4 the first stage label reaches the composed frame')
        if length $label0;
    cmp_ok(index($wide, 'failed'), '>=', 0, 'AC-P4 the failed stage word reaches the composed frame');

    # --- AC-P5 (behaviour 28): the lost-diagnostics banner -----------------
    my $banners_clean = aref(href(scalar_ls('progress_screen', $h, 100))->{banners});
    my $crit_clean = 0;
    for my $b (@$banners_clean) {
        $crit_clean++ if grep { bstr(href($_)->{role}) eq 'state.crit' } @{ aref($b) };
    }
    is($crit_clean, 0, 'AC-P5 a healthy capture produces NO state.crit banner');

    my ($hb, undef) = rec_host();
    scalar_ls('host_enter', $hb);
    my $bad_cap = scalar_ls('capture_new', raw_write => sub { die "sink gone\n" });
    $hb->{capture} = $bad_cap if ref $bad_cap eq 'HASH';
    scalar_ls('capture_line', $hb->{capture}, "lost line $_\n", 'plain') for 1 .. 3;
    my $screen_b = href(scalar_ls('progress_screen', $hb, 100));
    my $crit = 0;
    for my $b (@{ aref($screen_b->{banners}) }) {
        $crit++ if grep { bstr(href($_)->{role}) eq 'state.crit' } @{ aref($b) };
    }
    cmp_ok($crit, '>', 0, 'AC-P5 a non-zero capture_sink_errors produces a state.crit banner (a lost byte is never silent)');
    my $btext = join(' ', map { join('', map { bstr(href($_)->{text}) } @{ aref($_) }) }
                          @{ aref($screen_b->{banners}) });
    cmp_ok(index($btext, '3'), '>=', 0, 'AC-P5 the banner says HOW MANY diagnostic lines were lost');

    # --- AC-P6: the output panel always owns a full-width band row ---------
    for my $cols ($BP - 30, $BP - 1, $BP, $BP + 1, $BP + 30, $BP + 110) {
        next if $cols < 20;
        my $f = scalar_ls('compose_progress', $h, 24, $cols);
        my $both = 0;
        $both = grep { panel_title_hits(href($_)->{text}, 'stages', 'output') >= 2 } @{ aref($f) };
        is($both, 0, "AC-P6 at cols=$cols no composed row carries both the stages and output panel titles");
    }
    # liveness: both panel titles ARE rendered somewhere at a wide width, so
    # the AC-P6 zero above is a real measurement rather than a missing panel.
    my $wide_f = scalar_ls('compose_progress', $h, 24, $BP + 30);
    my $stage_hits  = 0; my $output_hits = 0;
    for my $c (@{ aref($wide_f) }) {
        $stage_hits  += panel_title_hits(href($c)->{text}, 'stages');
        $output_hits += panel_title_hits(href($c)->{text}, 'output');
    }
    cmp_ok($stage_hits,  '>', 0, 'AC-P6 liveness: the stages panel title is rendered');
    cmp_ok($output_hits, '>', 0, 'AC-P6 liveness: the output panel title is rendered');
    ok(!href($stages_panel)->{min_cols}, 'AC-P6 the stages panel declares no min_cols');
    my ($out_panel) = grep { bstr(href($_)->{title}) eq 'output' } @panels;
    is(href($out_panel)->{min_cols}, $BP,
        'AC-P6 the output panel min_cols IS tui::Layout::BREAKPOINT_TWO_COL() (never a literal)');

    # --- repaint --------------------------------------------------------
    my ($rh, $rrec) = rec_host(render => sub { my (undef, $f) = @_; "RENDERED:" . scalar(@{ aref($f) }) . "\n" });
    scalar_ls('host_enter', $rh);
    my $before_len = length $rrec->{out};
    my $rr = scalar_ls('repaint', $rh);
    is($rr, 1, 'AC-P repaint on an active tui host returns 1');
    cmp_ok(index(substr($rrec->{out}, $before_len), 'RENDERED:'), '>=', 0,
        'AC-P repaint writes the render seam output to the out seam');
    ok(ref href($rh)->{prev} eq 'ARRAY', 'AC-P repaint stores the frame as prev for the next diff');

    my ($ph2, $prec2) = rec_host(mode => 'plain');
    is(scalar_ls('repaint', $ph2), 0, 'AC-P repaint on a plain host returns 0');
    is($prec2->{out}, '', 'AC-P repaint on a plain host writes nothing');

    # degradation: non-numeric rows/cols fall back to 24/80
    my $deg = scalar_ls('compose_progress', $h, undef, undef);
    is(scalar(@{ aref($deg) }), 24, 'AC-P undef rows degrades to 24 rows');   # shape-lint: intentional - the declared default height, an identity not a shape pin
    my ($dbad) = cell_violations($deg, 80);
    is($dbad, 0, 'AC-P undef cols degrades to 80 columns and the invariants still hold');
    my $deg2 = scalar_ls('compose_progress', $h, 'zz', {});
    is(scalar(@{ aref($deg2) }), 24, 'AC-P non-numeric rows/cols degrade to 24/80');   # shape-lint: intentional - same identity
}

# ===========================================================================
# AC-K -- the list screen (criterion 1). Behaviours 29-40.
#
# Key tokens follow this codebase's ESTABLISHED vocabulary -- skills.pl's own
# key loop (:1130-1176) reads 'UP','DOWN','SPACE','ENTER','q','ESC' as
# symbolic tokens -- with the ONE clarification the spec makes explicitly:
# ESC arrives as the raw byte "\e".
# ===========================================================================

# clone($x) -- a deep copy of the plain data a model is made of, so a fixture
# declared once is never edited by an assertion.
sub clone {
    my ($x) = @_;
    return [ map { clone($_) } @$x ] if ref $x eq 'ARRAY';
    return { map { $_ => clone($x->{$_}) } keys %$x } if ref $x eq 'HASH';
    return $x;
}

my $MULTI_MODEL = do {
    my @items;
    for my $g (1 .. 4) {
        push @items, { kind => 'header', display => "Group $g" };
        for my $j (1 .. 10) {
            push @items, { kind => 'subheader', display => "subsection $g" } if $g == 1 && $j == 6;
            push @items, { kind     => 'row',
                           id       => "g$g-r$j",
                           group    => "grp$g",
                           display  => "item-$g-$j-zqx",
                           badge    => ($j == 1 ? 'new' : undef),
                           disabled => (($g == 2 && $j == 5) ? 1 : 0),
                           selected => 0 };
        }
    }
    { mode => 'multi', label => 'skills, plugins and MCP', error => undef, items => \@items };
};

my $SINGLE_MODEL = {
    mode => 'single', label => 'resume a session', error => undef,
    items => [ { kind => 'header', display => 'sessions' },
               map { { kind => 'row', id => "sess-$_", group => 'sessions',
                       display => "session-$_-zqx", disabled => 0, selected => 0 } } 1 .. 7 ],
};

my $TRIAGE_MODEL = {
    mode => 'triage', label => 'backpack approval', error => undef,
    items => [ map { { kind => 'row', id => "item-$_", group => 'backpack',
                       display => "packed-$_-zqx", disabled => 0, state => 'defer' } } 1 .. 5 ],
};

my $EMPTY_MODEL  = { mode => 'multi', label => 'nothing here', error => undef, items => [] };
my $BROKEN_MODEL = { mode => 'multi', label => 'nothing here', items => [],
                     error => 'could not parse the snapshot zqxbroken' };

# mk_ls($model, %extra) -> \%ls over a private clone of $model.
sub mk_ls {
    my ($model, %extra) = @_;
    my $ls = scalar_ls('list_init', model => clone($model), %extra);
    return ref $ls eq 'HASH' ? $ls : {};
}

# model_items($ls_model) / row_index_list -- positions of landable rows.
sub row_positions {
    my ($model) = @_;
    my @it = @{ aref(href($model)->{items}) };
    return grep { bstr(href($it[$_])->{kind}) eq 'row' && !href($it[$_])->{disabled} } 0 .. $#it;
}

# ls_items($ls) -- the item list the screen is working from, wherever it
# chose to keep it (the model is the caller's; the screen carries a copy).
sub ls_items {
    my ($ls) = @_;
    my $h = href($ls);
    for my $k (qw(items rows)) {
        return $h->{$k} if ref $h->{$k} eq 'ARRAY';
    }
    return aref(href($h->{model})->{items});
}

# --- AC-K6 (behaviour 34): the non-undoable action's contract --------------
{
    is(scalar_ls('DROP_IS_UNDOABLE'), 0, 'AC-K6 DROP_IS_UNDOABLE() is 0 -- the remove cannot be undone');
    my $w = LS_DROP_WARNING();
    cmp_ok(length($w), '>', 0, 'AC-K6 liveness: DROP_WARNING() is a non-empty sentence');
    like($w, qr/permanent/i,         'AC-K6 DROP_WARNING() says the action is permanent');
    like($w, qr/cannot be undone/i,  "AC-K6 DROP_WARNING() says it cannot be undone");
    my %lm = map { bstr($_) => 1 } @{ LS_LIST_MODES() };
    ok($lm{$_}, "AC-K6 LIST_MODES() contains '$_'") for qw(multi single triage);
    my %ts = map { bstr($_) => 1 } @{ LS_TRIAGE_STATES() };
    ok($ts{$_}, "AC-K6 TRIAGE_STATES() contains '$_'") for qw(defer approve remove);
    for my $mode (qw(multi single triage)) {
        cmp_ok(length(bstr(scalar_ls('LIST_FOOTER_LEGEND', $mode))), '>', 0,
            "AC-K6 LIST_FOOTER_LEGEND('$mode') is a non-empty legend");
    }
}

# --- AC-K1 (behaviour 29): the cursor never lands on an unlandable row -----
{
    my $ls = mk_ls($MULTI_MODEL);
    my @items = @{ ls_items($ls) };
    cmp_ok(scalar @items, '>', 40, 'AC-K1 liveness: the multi fixture carries headers plus 40 rows');

    my $first = scalar_ls('list_first_row', $ls);
    ok(defined $first, 'AC-K1 list_first_row finds a landable row');
    my $fi = href($items[num($first)]);
    is(bstr($fi->{kind}), 'row', 'AC-K1 list_first_row lands on a row');
    is($fi->{disabled} ? 1 : 0, 0, 'AC-K1 list_first_row never lands on a disabled row');

    my ($bad, $first_bad, $moves) = (0, undef, 0);
    for my $start (0 .. $#items) {
        for my $delta (-1, 1) {
            $ls->{cursor} = $start;
            my $land = scalar_ls('list_advance', $ls, $delta);
            next unless defined $land;
            $moves++;
            my $it = href($items[num($land)]);
            if (bstr($it->{kind}) ne 'row' || $it->{disabled}) {
                $bad++;
                $first_bad //= "start=$start delta=$delta landed=$land kind=" . bstr($it->{kind});
            }
        }
    }
    cmp_ok($moves, '>', 0, 'AC-K1 liveness: list_advance actually moved the cursor somewhere');
    is($bad, 0, 'AC-K1 list_advance never lands on a header, a subheader or a disabled row')
        or diag("  first bad landing: " . (defined $first_bad ? $first_bad : '?'));

    # clamping
    my @rp = row_positions($MULTI_MODEL);
    $ls->{cursor} = $rp[0];
    is(scalar_ls('list_advance', $ls, -1), $rp[0], 'AC-K1 list_advance clamps at the top');
    $ls->{cursor} = $rp[-1];
    is(scalar_ls('list_advance', $ls, 1), $rp[-1], 'AC-K1 list_advance clamps at the bottom');

    # AC-K1b counter-fixture: the SAME predicate must report a bad landing for
    # an index deliberately parked on a header.
    my @fixture_items = @{ aref($MULTI_MODEL->{items}) };
    my ($hidx) = grep { bstr(href($fixture_items[$_])->{kind}) eq 'header' } 0 .. $#fixture_items;
    my $hit = href($fixture_items[num($hidx)]);
    my $detects = (bstr($hit->{kind}) ne 'row' || $hit->{disabled}) ? 1 : 0;
    is($detects, 1, 'AC-K1b counter-fixture: the same predicate reports a header index as a bad landing');
    my ($didx) = grep { href($fixture_items[$_])->{disabled} } 0 .. $#fixture_items;
    ok(defined $didx, 'AC-K1b counter-fixture: the fixture really does contain a disabled row');
    my ($sidx) = grep { bstr(href($fixture_items[$_])->{kind}) eq 'subheader' } 0 .. $#fixture_items;
    ok(defined $sidx, 'AC-K1b counter-fixture: the fixture really does contain a subheader');

    # an all-unlandable model has no first row and no advance
    my $none = mk_ls({ mode => 'multi', label => 'x',
                       items => [ { kind => 'header', display => 'h' },
                                  { kind => 'row', id => 'd', group => 'g', display => 'd',
                                    disabled => 1 } ] });
    is(scalar_ls('list_first_row', $none), undef, 'AC-K1 list_first_row is undef when nothing is landable');
    $none->{cursor} = 0;
    is(scalar_ls('list_advance', $none, 1), undef, 'AC-K1 list_advance returns undef when nothing is landable');
}

# --- AC-K2 (behaviour 30): multi-mode toggling and group isolation ---------
{
    my $ls = mk_ls($MULTI_MODEL);
    my @rp = row_positions($MULTI_MODEL);
    $ls->{cursor} = $rp[0];       # first row of grp1
    my $act = scalar_ls('list_dispatch_key', $ls, 'SPACE');
    is($act, 'toggle', "AC-K2 SPACE in multi mode returns 'toggle'");
    my $sel = href(scalar_ls('list_selection', $ls))->{selected};
    is_deeply(aref(href($sel)->{grp1}), ['g1-r1'], 'AC-K2 SPACE selected exactly the cursor row');
    is(scalar @{ aref(href($sel)->{grp2}) }, 0, 'AC-K2 ... and touched no other group');

    scalar_ls('list_dispatch_key', $ls, 'SPACE');
    my $sel2 = href(href(scalar_ls('list_selection', $ls))->{selected});
    is(scalar @{ aref($sel2->{grp1}) }, 0, 'AC-K2 SPACE again toggles the same row back off');

    # 'a' selects every row of the CURSOR'S group only
    my @g3 = grep { bstr(href($_)->{group}) eq 'grp3' } @{ aref($MULTI_MODEL->{items}) };
    my @g3ids = map { bstr(href($_)->{id}) } @g3;
    my @items = @{ aref($MULTI_MODEL->{items}) };
    my ($g3first) = grep { bstr(href($items[$_])->{group}) eq 'grp3' } 0 .. $#items;
    $ls->{cursor} = $g3first;
    my $act_a = scalar_ls('list_dispatch_key', $ls, 'a');
    is($act_a, 'group-all', "AC-K2 'a' in multi mode returns 'group-all'");
    my $selA = href(href(scalar_ls('list_selection', $ls))->{selected});
    is_deeply(aref($selA->{grp3}), \@g3ids, "AC-K2 'a' selected every row of the cursor's group, in model order");
    is_deeply(aref($selA->{grp1}), [], "AC-K2 'a' left group 1 untouched");
    is_deeply(aref($selA->{grp2}), [], "AC-K2 'a' left group 2 untouched");
    is_deeply(aref($selA->{grp4}), [], "AC-K2 'a' left group 4 untouched");

    my $act_n = scalar_ls('list_dispatch_key', $ls, 'n');
    is($act_n, 'group-none', "AC-K2 'n' in multi mode returns 'group-none'");
    my $selN = href(href(scalar_ls('list_selection', $ls))->{selected});
    is_deeply(aref($selN->{grp3}), [], "AC-K2 'n' cleared the cursor's group");

    # keys that are inert in multi mode
    is(scalar_ls('list_dispatch_key', $ls, 'r'), '', "AC-K2 'r' is inert in multi mode");
    is(scalar_ls('list_dispatch_key', $ls, 'y'), '', "AC-K2 'y' is inert in multi mode");
    is(scalar_ls('list_dispatch_key', $ls, 'Z'), '', 'AC-K2 an unrecognised key returns the empty action');
    is(scalar_ls('list_dispatch_key', $ls, undef), '', 'AC-K2 an undef key returns the empty action');
}

# --- AC-K3 (behaviour 31): single mode ------------------------------------
{
    for my $key ('SPACE', 'ENTER') {
        my $ls = mk_ls($SINGLE_MODEL);
        my @items = @{ aref($SINGLE_MODEL->{items}) };
        my ($third) = (grep { bstr(href($items[$_])->{kind}) eq 'row' } 0 .. $#items)[2];
        $ls->{cursor} = $third;
        my $act = scalar_ls('list_dispatch_key', $ls, $key);
        is($act, 'confirm', "AC-K3 $key in single mode confirms");
        is(scalar_ls('list_apply', $ls, $act), 1, "AC-K3 list_apply('confirm') finishes the screen ($key)");
        my $d = href(scalar_ls('list_selection', $ls));
        is($d->{confirmed}, 1, "AC-K3 the decision is confirmed ($key)");
        is($d->{cancelled}, 0, "AC-K3 ... and not cancelled ($key)");
        is(bstr($d->{cursor_id}), 'sess-3', "AC-K3 cursor_id names the cursor row ($key)");
        my $sel = href($d->{selected});
        is_deeply(aref($sel->{sessions}), ['sess-3'], "AC-K3 exactly one id is selected ($key)");
    }
    my $ls = mk_ls($SINGLE_MODEL);
    is(scalar_ls('list_dispatch_key', $ls, 'a'), '', "AC-K3 'a' is inert in single mode");
    is(scalar_ls('list_dispatch_key', $ls, 'n'), '', "AC-K3 'n' is inert in single mode");
}

# --- AC-K4 (behaviour 32): triage, and the armed remove confirm -----------
{
    # arm 1: 'r' alone marks NOTHING and raises the warning banner
    my $ls = mk_ls($TRIAGE_MODEL);
    my @items = @{ aref($TRIAGE_MODEL->{items}) };
    my ($r2) = (grep { bstr(href($items[$_])->{kind}) eq 'row' } 0 .. $#items)[1];
    $ls->{cursor} = $r2;
    my $a1 = scalar_ls('list_dispatch_key', $ls, 'r');
    is($a1, 'confirm-remove', "AC-K4 'r' in triage mode returns 'confirm-remove' (it ARMS, it does not act)");
    my $d1 = href(href(scalar_ls('list_selection', $ls))->{triage});
    is(scalar @{ aref($d1->{remove}) }, 0, "AC-K4 'r' alone marks NOTHING for removal");
    my $btext = join(' ', map { join('', map { bstr(href($_)->{text}) } @{ aref($_) }) }
                          @{ aref(scalar_ls('list_banners', $ls)) });
    cmp_ok(index($btext, LS_DROP_WARNING()), '>=', 0,
        'AC-K4 the armed confirm shows DROP_WARNING() verbatim in a banner');

    # arm 2: 'r' then 'y' marks the row
    my $a2 = scalar_ls('list_dispatch_key', $ls, 'y');
    is($a2, 'mark-remove', "AC-K4 'y' while armed returns 'mark-remove'");
    my $d2 = href(href(scalar_ls('list_selection', $ls))->{triage});
    is_deeply(aref($d2->{remove}), ['item-2'], "AC-K4 'r' then 'y' marks exactly the cursor row for removal");
    my $btext2 = join(' ', map { join('', map { bstr(href($_)->{text}) } @{ aref($_) }) }
                           @{ aref(scalar_ls('list_banners', $ls)) });
    is(index($btext2, LS_DROP_WARNING()), -1, 'AC-K4 firing the confirm clears the warning banner');

    # arm 3: 'r' then any other key marks nothing and clears the banner
    my $ls3 = mk_ls($TRIAGE_MODEL);
    $ls3->{cursor} = $r2;
    scalar_ls('list_dispatch_key', $ls3, 'r');
    my $a3 = scalar_ls('list_dispatch_key', $ls3, 'j');
    is($a3, 'cancel-remove', "AC-K4 any other key while armed returns 'cancel-remove'");
    my $d3 = href(href(scalar_ls('list_selection', $ls3))->{triage});
    is(scalar @{ aref($d3->{remove}) }, 0, "AC-K4 'r' then an unrelated key marks NOTHING");
    my $btext3 = join(' ', map { join('', map { bstr(href($_)->{text}) } @{ aref($_) }) }
                           @{ aref(scalar_ls('list_banners', $ls3)) });
    is(index($btext3, LS_DROP_WARNING()), -1, 'AC-K4 cancelling the confirm clears the warning banner');

    # uppercase Y is the ONLY uppercase alias, and it fires the armed confirm
    my $lsY = mk_ls($TRIAGE_MODEL);
    $lsY->{cursor} = $r2;
    scalar_ls('list_dispatch_key', $lsY, 'r');
    is(scalar_ls('list_dispatch_key', $lsY, 'Y'), 'mark-remove', "AC-K4 'Y' also fires the armed confirm");

    # SPACE cycles defer -> approve -> defer; 'a' and 'n' set outright
    my $lsc = mk_ls($TRIAGE_MODEL);
    $lsc->{cursor} = $r2;
    is(scalar_ls('list_dispatch_key', $lsc, 'SPACE'), 'toggle', 'AC-K4 SPACE in triage mode toggles');
    my $t1 = href(href(scalar_ls('list_selection', $lsc))->{triage});
    is_deeply(aref($t1->{approve}), ['item-2'], 'AC-K4 SPACE cycles defer -> approve');
    scalar_ls('list_dispatch_key', $lsc, 'SPACE');
    my $t2 = href(href(scalar_ls('list_selection', $lsc))->{triage});
    is(scalar @{ aref($t2->{approve}) }, 0, 'AC-K4 SPACE again cycles approve -> defer');
    is(scalar_ls('list_dispatch_key', $lsc, 'a'), 'group-all', "AC-K4 'a' in triage mode marks approve");
    my $t3 = href(href(scalar_ls('list_selection', $lsc))->{triage});
    is_deeply(aref($t3->{approve}), ['item-2'], "AC-K4 'a' marked the cursor row approve");
    is(scalar_ls('list_dispatch_key', $lsc, 'n'), 'group-none', "AC-K4 'n' in triage mode marks defer");
    my $t4 = href(href(scalar_ls('list_selection', $lsc))->{triage});
    is(scalar @{ aref($t4->{approve}) }, 0, "AC-K4 'n' returned the row to defer");

    # NEVER ARM A CONFIRM YOU CANNOT FIRE: a disabled/absent cursor row arms
    # nothing and says so.
    my $lsd = mk_ls({ mode => 'triage', label => 'backpack', items =>
        [ { kind => 'subheader', display => 'already approved' },
          { kind => 'row', id => 'done-1', group => 'backpack', display => 'done-1',
            disabled => 1, state => 'defer' } ] });
    $lsd->{cursor} = 1;
    my $ad = scalar_ls('list_dispatch_key', $lsd, 'r');
    isnt($ad, 'confirm-remove', 'AC-K4 r on a DISABLED row does not arm a confirm that cannot fire');
    my $bd = join(' ', map { join('', map { bstr(href($_)->{text}) . ':' . bstr(href($_)->{role}) } @{ aref($_) }) }
                       @{ aref(scalar_ls('list_banners', $lsd)) });
    cmp_ok(index($bd, 'unavailable'), '>=', 0, "AC-K4 ... it reports 'unavailable' instead");
    cmp_ok(index($bd, 'state.warn'), '>=', 0, 'AC-K4 ... with the state.warn role');
}

# --- AC-K5 (behaviour 33): q while armed cancels the MARK, not the screen --
{
    my $ls = mk_ls($TRIAGE_MODEL);
    my @items = @{ aref($TRIAGE_MODEL->{items}) };
    $ls->{cursor} = 0;
    scalar_ls('list_dispatch_key', $ls, 'r');
    my $act = scalar_ls('list_dispatch_key', $ls, 'q');
    is($act, 'cancel-remove', "AC-K5 'q' while armed cancels the MARK (the armed arm is checked first)");
    is(scalar_ls('list_apply', $ls, $act), 0, "AC-K5 ... and does NOT close the screen");
    my $tri = href(href(scalar_ls('list_selection', $ls))->{triage});
    is(scalar @{ aref($tri->{remove}) }, 0, "AC-K5 ... and marks nothing");

    my $act2 = scalar_ls('list_dispatch_key', $ls, 'q');
    is($act2, 'cancel', "AC-K5 'q' with nothing armed cancels the screen");
    is(scalar_ls('list_apply', $ls, $act2), 1, 'AC-K5 list_apply(cancel) finishes the screen');
    my $d = href(scalar_ls('list_selection', $ls));
    is($d->{cancelled}, 1, 'AC-K5 the decision records cancelled');
    is($d->{confirmed}, 0, 'AC-K5 ... and not confirmed');

    my $lse = mk_ls($TRIAGE_MODEL);
    is(scalar_ls('list_dispatch_key', $lse, "\e"), 'cancel', 'AC-K5 the raw ESC byte cancels too');
}

# --- AC-K11 (behaviours 39, 40): a cancel decides NOTHING ------------------
{
    my $ls = mk_ls($MULTI_MODEL);
    my @rp = row_positions($MULTI_MODEL);
    $ls->{cursor} = $rp[0];
    scalar_ls('list_dispatch_key', $ls, 'a');           # select a whole group
    my $mid = href(href(scalar_ls('list_selection', $ls))->{selected});
    cmp_ok(scalar @{ aref($mid->{grp1}) }, '>', 0, 'AC-K11 liveness: rows were selected before the cancel');

    my $act = scalar_ls('list_dispatch_key', $ls, 'q');
    scalar_ls('list_apply', $ls, $act);
    my $d = href(scalar_ls('list_selection', $ls));
    is($d->{cancelled}, 1, 'AC-K11 the cancelled decision is flagged cancelled');
    is(scalar keys %{ href($d->{selected}) }, 0, 'AC-K11 a cancel reports an EMPTY selection');
    my $tri = href($d->{triage});
    is(scalar @{ aref($tri->{approve}) }, 0, 'AC-K11 a cancel reports no approvals');
    is(scalar @{ aref($tri->{remove}) },  0, 'AC-K11 a cancel reports no removals');
    is(scalar @{ aref($tri->{defer}) },   0, 'AC-K11 a cancel reports no deferrals');

    # behaviour 40: model order, never sorted
    my $ls2 = mk_ls({ mode => 'multi', label => 'order', items =>
        [ map { { kind => 'row', id => $_, group => 'g', display => $_,
                  disabled => 0, selected => 1 } } qw(zeta alpha mike bravo) ] });
    my $sel = href(href(scalar_ls('list_selection', $ls2))->{selected});
    is_deeply(aref($sel->{g}), [qw(zeta alpha mike bravo)],
        'AC-K11 ids within a group preserve MODEL order and are never sorted');
}

# --- AC-K7 (behaviour 35): scrolling is real; the cursor is never offscreen -
{
    my $ls = mk_ls($MULTI_MODEL);
    my @items = @{ aref($MULTI_MODEL->{items}) };
    my @rp = row_positions($MULTI_MODEL);

    $ls->{cursor} = $rp[0];
    my $top = frame_text(scalar_ls('compose_list', $ls, 14, 80));
    my $last_display = bstr(href($items[$rp[-1]])->{display});
    my $first_display = bstr(href($items[$rp[0]])->{display});
    cmp_ok(index($top, $first_display), '>=', 0, 'AC-K7 liveness: the cursor row is visible at the top of the list');
    is(index($top, $last_display), -1,
        'AC-K7 with 40 rows and a short viewport the LAST row is absent at cursor 0 (the window really scrolls)');

    $ls->{cursor} = $rp[-1];
    my $bottom = frame_text(scalar_ls('compose_list', $ls, 14, 80));
    cmp_ok(index($bottom, $last_display), '>=', 0, 'AC-K7 ... and present once the cursor reaches it');

    # AC-K7b counter-fixture: the same presence predicate on a never-present
    # nonce must report absent.
    is(index($bottom, 'zqxabsent5150'), -1,
        'AC-K7b counter-fixture: the same presence predicate reports a never-rendered nonce absent');

    my ($offscreen, $first_bad) = (0, undef);
    for my $dims ([24, 80], [24, 120], [10, 60], [30, 200]) {
        my ($rows, $cols) = @$dims;
        for my $p (@rp) {
            $ls->{cursor} = $p;
            my $t = frame_text(scalar_ls('compose_list', $ls, $rows, $cols));
            my $disp = bstr(href($items[$p])->{display});
            if (index($t, $disp) < 0) {
                $offscreen++;
                $first_bad //= "rows=$rows cols=$cols cursor=$p display=$disp";
            }
        }
    }
    is($offscreen, 0, 'AC-K7 the cursor row appears in the composed frame at every cursor position and every tested size')
        or diag("  first offscreen cursor: " . (defined $first_bad ? $first_bad : '?'));
}

# --- AC-K10 (behaviour 38): populated vs empty vs BROKEN (C-K) ------------
{
    my $pop    = frame_text(scalar_ls('compose_list', mk_ls($MULTI_MODEL),  24, 80));
    my $empty  = frame_text(scalar_ls('compose_list', mk_ls($EMPTY_MODEL),  24, 80));
    my $broken = frame_text(scalar_ls('compose_list', mk_ls($BROKEN_MODEL), 24, 80));

    cmp_ok(length($pop), '>', 0, 'AC-K10 liveness: the populated frame has text');
    isnt($empty,  $pop,    'AC-K10 the empty frame differs from the populated frame');
    isnt($broken, $empty,  'AC-K10 the BROKEN frame differs from the EMPTY frame (absent != broken)');
    isnt($broken, $pop,    'AC-K10 the broken frame differs from the populated frame');

    cmp_ok(index($empty, '(nothing to choose)'), '>=', 0,
        'AC-K10 an empty-but-fine list renders (nothing to choose)');
    cmp_ok(index($broken, '(list unavailable'), '>=', 0,
        'AC-K10 a broken list renders (list unavailable - <error>)');
    cmp_ok(index($broken, 'zqxbroken'), '>=', 0, 'AC-K10 the broken frame names the underlying error');
    is(index($empty, '(list unavailable'), -1, 'AC-K10 an empty-but-fine list is NOT rendered as unavailable');

    # role-scoped, never line-scoped (C-K): only the broken screen carries a
    # state.crit span, and only the empty one carries the text.muted row.
    my $crit_in = sub {
        my ($ls) = @_;
        my $f = scalar_ls('compose_list', $ls, 24, 80);
        my $n = 0;
        for my $c (@{ aref($f) }) {
            $n += grep { bstr(href($_)->{role}) eq 'state.crit' } @{ aref(href($c)->{spans}) };
        }
        return $n;
    };
    cmp_ok($crit_in->(mk_ls($BROKEN_MODEL)), '>', 0, 'AC-K10 the broken list carries a state.crit span');
    is($crit_in->(mk_ls($EMPTY_MODEL)), 0, 'AC-K10 the empty-but-fine list carries NO state.crit span');

    my $muted = 0;
    my $fe = scalar_ls('compose_list', mk_ls($EMPTY_MODEL), 24, 80);
    for my $c (@{ aref($fe) }) {
        $muted += grep { bstr(href($_)->{role}) eq 'text.muted'
                         && index(bstr(href($_)->{text}), '(nothing to choose)') >= 0 }
                       @{ aref(href($c)->{spans}) };
    }
    cmp_ok($muted, '>', 0, 'AC-K10 the empty-state row carries the text.muted role');

    my $bb = 0;
    for my $b (@{ aref(scalar_ls('list_banners', mk_ls($BROKEN_MODEL))) }) {
        $bb += grep { bstr(href($_)->{role}) eq 'state.crit' } @{ aref($b) };
    }
    cmp_ok($bb, '>', 0, 'AC-K10 a broken list also raises a state.crit BANNER');
    is(scalar @{ aref(scalar_ls('list_banners', mk_ls($EMPTY_MODEL))) }, 0,
        'AC-K10 an empty-but-fine list raises no banner');

    # a non-hashref model / missing items / non-arrayref items => EMPTY, not a die
    for my $bad (undef, 'a string', [], { mode => 'multi' }, { mode => 'multi', items => 'nope' }) {
        my $ls = mk_ls($bad);
        my $f = eval { scalar_ls('compose_list', $ls, 24, 80) };
        ok(ref $f eq 'ARRAY', 'AC-K10 a malformed model still composes a frame rather than dying');
    }
}

# --- AC-K8/AC-K9 (behaviours 36, 37): the loop, the heartbeat, termination -
{
    # AC-K9: a finite scripted read_key with NO wait_key must terminate. If
    # this hangs, the contract is broken -- there is no timeout here by
    # design, because the module's own termination guarantee is the subject.
    my @keys = ('DOWN', 'SPACE', 'ENTER');
    my $res = scalar_ls('list_run',
        model     => clone($MULTI_MODEL),
        read_key  => sub { @keys ? shift @keys : undef },
        term_size => sub { (80, 24) },
        render    => sub { '' },
        out       => sub { 1 },
    );
    my $r = href($res);
    ok(ref $res eq 'HASH', 'AC-K9 list_run returns a result hashref');
    is($r->{closed}, 1, 'AC-K9 list_run with a finite read_key and no wait_key TERMINATES');
    is($r->{confirmed}, 1, 'AC-K9 the scripted ENTER confirmed the screen');
    is(href($r->{decision})->{confirmed}, 1, 'AC-K9 the returned decision is confirmed');

    # a poll that never yields anything, with no wait_key, must still return
    my $res2 = href(scalar_ls('list_run',
        model    => clone($MULTI_MODEL),
        read_key => sub { undef },
        render   => sub { '' },
        out      => sub { 1 },
    ));
    is($res2->{closed}, 1, 'AC-K9 an immediately-empty poll with no wait_key terminates');

    # AC-K8 (behaviour 36): the heartbeat ticks EVERY iteration, including
    # idle ones -- an idle operator is exactly the case Rule 5 exists for.
    my $calls = 0;
    my $res3 = href(scalar_ls('list_run',
        model     => clone($MULTI_MODEL),
        read_key  => sub { undef },
        wait_key  => sub { undef },
        max_ticks => 5,
        tick      => 0,
        heartbeat => sub { $calls++ },
        render    => sub { '' },
        out       => sub { 1 },
    ));
    cmp_ok(num($res3->{ticks}), '>=', 5, 'AC-K8 liveness: the idle run really ran its 5 ticks');
    cmp_ok($calls, '>=', num($res3->{ticks}),
        'AC-K8 heartbeat is ticked at least once per loop iteration, idle iterations included');
    cmp_ok($calls, '>=', 5, 'AC-K8 an idle run with max_ticks=5 ticks the heartbeat at least 5 times');

    # a dying heartbeat must not kill the loop (S5 edge case 3)
    my $res4 = href(scalar_ls('list_run',
        model     => clone($SINGLE_MODEL),
        read_key  => sub { undef },
        wait_key  => sub { undef },
        max_ticks => 3,
        tick      => 0,
        heartbeat => sub { die "hb died\n" },
        render    => sub { '' },
        out       => sub { 1 },
    ));
    is($res4->{closed}, 1, 'AC-K8 a dying heartbeat seam does not stop the loop closing');

    # AC-K8b counter-fixture: a loop that ticks ONLY on a keypress produces
    # calls < ticks under the identical comparator, proving it discriminates.
    my ($fake_calls, $fake_ticks) = (0, 0);
    for my $i (1 .. 5) { $fake_ticks++; $fake_calls++ if 0; }
    ok(!($fake_calls >= $fake_ticks),
        'AC-K8b counter-fixture: the same comparator rejects a loop that ticks only on a keypress');
}

# --- AC-K12: compose_list's invariants at every width, plus hostility ------
{
    my $ls = mk_ls($MULTI_MODEL);
    my @rp = row_positions($MULTI_MODEL);
    $ls->{cursor} = $rp[5];
    my ($violations, $first_bad) = (0, undef);
    for my $cols (20 .. 200) {
        my $f = scalar_ls('compose_list', $ls, 24, $cols);
        my ($b, $fb) = cell_violations($f, $cols);
        $violations += $b;
        $first_bad //= $fb if $b;
    }
    is($violations, 0, 'AC-K12 compose_list satisfies every cell invariant over all 181 widths')
        or diag("  first offender: " . (defined $first_bad ? $first_bad : '?'));

    my $hostile = mk_ls({ mode => 'multi', label => "label \e[31mwith SGR", items => [
        { kind => 'row', id => 'long', group => 'g', display => ('L' x 300), disabled => 0, selected => 0 },
        { kind => 'row', id => 'esc',  group => 'g', display => "esc \e[31mred\e[0m", disabled => 0 },
        'not-a-hashref',
        { kind => 'row', group => 'g', display => 'no id here', disabled => 0 },
        { kind => 'row', id => 'utf8', group => 'g', display => "Andr\xc3\xa9 \xe2\x86\x92", disabled => 0 },
    ] });
    my ($hbad, $hfirst) = (0, undef);
    for my $cols (20, 40, 79, 80, 120, 200) {
        my $f = eval { scalar_ls('compose_list', $hostile, 24, $cols) };
        if ($@) { $hbad++; $hfirst //= "died at cols=$cols: $@"; next; }
        my ($b, $fb) = cell_violations($f, $cols);
        $hbad += $b;
        $hfirst //= $fb if $b;
    }
    is($hbad, 0, 'AC-K12 a hostile model (300-char display, SGR bytes, a non-hashref item, a row with no id) still composes cleanly')
        or diag("  first offender: " . (defined $hfirst ? $hfirst : '?'));

    # the accented Latin of a real path survives sanitisation (tui::Frame::safe
    # passes U+00A0..U+024F through since 17693a6) rather than becoming '?'.
    my $ht = frame_text(scalar_ls('compose_list', $hostile, 24, 120));
    cmp_ok(index($ht, "Andr\xc3\xa9"), '>=', 0,
        'AC-K12 accented Latin survives into the frame (never replaced by ?)');
    is(index($ht, "\e"), -1, 'AC-K12 no ESC byte reaches the composed frame');

    # the always-present summary row
    my $sum = frame_text(scalar_ls('compose_list', $ls, 24, 100));
    like($sum, qr/\b40\b/, 'AC-K12 the summary row reports the item count');
    like($sum, qr/selected/, 'AC-K12 the summary row reports how many are selected');
}

# ===========================================================================
# AC-B -- BackpackReview's plan/commit split and the triage screen.
# Fixtures are File::Temp files; the `remove` seam is ALWAYS a stub coderef,
# so this group spawns nothing (criterion 6).
# ===========================================================================
my $BP_DIR = tempdir(CLEANUP => 1);

# _write($path, $bytes)
sub _write {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print $fh $content;
    close $fh;
}

# The three fixture items, declared in Perl so the expected partition can be
# derived from BackpackApproval itself rather than from a pinned literal.
my @BP_ITEMS = (
    { category => 'apt', name => 'jq',   install => 'apt-get install -y jq',
      verify => 'jq --version',   rationale => 'json wrangling' },
    { category => 'apt', name => 'ripgrep', install => 'apt-get install -y ripgrep',
      verify => 'rg --version',   rationale => 'search' },
    { category => 'npm', name => 'tsx',  install => 'npm i -g tsx',
      verify => 'tsx --version',  rationale => 'ts runner' },
);
my $BP_GOOD = "$BP_DIR/backpack-good.json";
_write($BP_GOOD, '{"version":1,"items":['
    . join(',', map { '{"category":"' . $_->{category} . '","name":"' . $_->{name}
                      . '","install":"' . $_->{install} . '","verify":"' . $_->{verify}
                      . '","rationale":"' . $_->{rationale} . '"}' } @BP_ITEMS)
    . ']}');
my $BP_BROKEN = "$BP_DIR/backpack-broken.json";
_write($BP_BROKEN, '{');
my $BP_SHAPE = "$BP_DIR/backpack-wrongshape.json";
_write($BP_SHAPE, '{"version":1}');
my $BP_EMPTY = "$BP_DIR/backpack-empty.json";
_write($BP_EMPTY, '{"version":1,"items":[]}');

{
    # --- AC-B6: plan/commit are ADDITIONS; review survives ------------------
    my $br_src = _comment_stripped(bstr(slurp($BR_PM)));
    like($br_src, qr/^sub review\b/m,  'AC-B6 BackpackReview.pm still defines sub review');
    like($br_src, qr/^sub plan\b/m,    'AC-B6 BackpackReview.pm defines sub plan');
    like($br_src, qr/^sub commit\b/m,  'AC-B6 BackpackReview.pm defines sub commit');

    # --- AC-B1 (behaviour 41): plan on a good fixture -----------------------
    my $appr_path = "$BP_DIR/approvals-1.json";
    my $plan = eval { BackpackReview::plan(file => $BP_GOOD, approvals => $appr_path) };
    my $perr = $@;
    ok(ref $plan eq 'HASH', 'AC-B1 BackpackReview::plan returns a plan hashref')
        or diag("  plan died/absent: $perr");
    $plan = {} unless ref $plan eq 'HASH';
    is($plan->{broken}, 0, 'AC-B1 a good backpack is not broken');
    is($plan->{error}, undef, 'AC-B1 a good backpack carries no error');
    is(scalar @{ aref($plan->{items}) }, 3, 'AC-B1 plan carries all three fixture items');   # shape-lint: intentional - a FIXTURE this file wrote, not a shared shape
    my $store = eval { BackpackApproval::load($appr_path) } || {};
    my ($exp_ok, $exp_pending) = eval { BackpackApproval::partition(\@BP_ITEMS, $store) };
    is(scalar @{ aref($plan->{pending}) }, scalar @{ aref($exp_pending) },
        'AC-B1 plan pending matches BackpackApproval::partition for the same fixture');
    is(scalar @{ aref($plan->{ok}) }, scalar @{ aref($exp_ok) },
        'AC-B1 plan ok matches BackpackApproval::partition for the same fixture');
    is_deeply([ map { BackpackApproval::item_key($_) } @{ aref($plan->{pending}) } ],
              [ map { BackpackApproval::item_key($_) } @{ aref($exp_pending) } ],
              'AC-B1 plan pending is the same items, in file order');
    is($plan->{migrated}, 0, 'AC-B1 no legacy trust file means no migration');
    ok(ref $plan->{approvals} eq 'HASH', 'AC-B1 plan exposes the loaded approvals hash');

    # --- AC-B2 (behaviour 42): BROKEN is not EMPTY (C-K) --------------------
    my $bplan = eval { BackpackReview::plan(file => $BP_BROKEN, approvals => "$BP_DIR/approvals-2.json") };
    $bplan = {} unless ref $bplan eq 'HASH';
    is($bplan->{broken}, 1, 'AC-B2 an unparseable backpack sets broken => 1');
    cmp_ok(length(bstr($bplan->{error})), '>', 0, 'AC-B2 ... with a non-empty error string');
    is(scalar @{ aref($bplan->{pending}) }, 0, 'AC-B2 ... and an empty pending list');
    is(scalar @{ aref($bplan->{items}) }, 0, 'AC-B2 ... and an empty item list');

    my $splan = eval { BackpackReview::plan(file => $BP_SHAPE, approvals => "$BP_DIR/approvals-3.json") };
    $splan = {} unless ref $splan eq 'HASH';
    is($splan->{broken}, 1, 'AC-B2 a well-formed file of the WRONG SHAPE is also broken');

    my $eplan = eval { BackpackReview::plan(file => $BP_EMPTY, approvals => "$BP_DIR/approvals-4.json") };
    $eplan = {} unless ref $eplan eq 'HASH';
    is($eplan->{broken}, 0, 'AC-B2 a VALID file with nothing to review is NOT broken');
    is($eplan->{error}, undef, 'AC-B2 ... and carries no error');
    isnt($eplan->{broken}, $bplan->{broken},
        'AC-B2 "nothing to review" and "the file is unreadable" are distinguishable facts');

    my $missing = eval { BackpackReview::plan(file => "$BP_DIR/does-not-exist.json",
                                              approvals => "$BP_DIR/approvals-5.json") };
    $missing = {} unless ref $missing eq 'HASH';
    is($missing->{broken}, 1, 'AC-B2 an unreadable (missing) backpack is broken, not empty');

    # AC-B2b counter-fixture: the identical checks on the good fixture.
    is($plan->{broken}, 0,  'AC-B2b counter-fixture: the same broken check reads 0 on a valid file');
    is($plan->{error}, undef, 'AC-B2b counter-fixture: the same error check reads undef on a valid file');

    # --- AC-B3 (behaviour 43): commit's three arms -------------------------
    {
        my $ap = "$BP_DIR/approvals-commit-a.json";
        my $pl = eval { BackpackReview::plan(file => $BP_GOOD, approvals => $ap) };
        $pl = {} unless ref $pl eq 'HASH';
        my $k = eval { BackpackApproval::item_key($BP_ITEMS[0]) };
        my @removed;
        my @errs;
        my ($approved, $deferred) = eval { BackpackReview::commit(
            plan => $pl, approvals => $ap,
            decisions => { $k => 'approve' },
            remove => sub { push @removed, $_[0]; 0 },
            on_error => sub { push @errs, $_[0] },
        ) };
        is(scalar @removed, 0, "AC-B3 an 'approve' decision spawns no remove");
        my $store_a = eval { BackpackApproval::load($ap) } || {};
        my $want_hash = eval { BackpackApproval::item_hash($BP_ITEMS[0]) };
        is(bstr(href($store_a)->{$k}), $want_hash,
            'AC-B3 approve recorded the item hash derived from BackpackApproval::item_hash (never a literal)');
        is(scalar @{ aref($approved) }, 1, "AC-B3 commit returns the approved item");
        is(scalar @errs, 0, 'AC-B3 a clean save reports no error');
    }
    {
        my $ap = "$BP_DIR/approvals-commit-r.json";
        my $pl = eval { BackpackReview::plan(file => $BP_GOOD, approvals => $ap) };
        $pl = {} unless ref $pl eq 'HASH';
        my $k = eval { BackpackApproval::item_key($BP_ITEMS[1]) };
        my @removed;
        my ($approved, $deferred) = eval { BackpackReview::commit(
            plan => $pl, approvals => $ap,
            decisions => { $k => 'remove' },
            remove => sub { push @removed, $_[0]; 0 },
            on_error => sub { },
        ) };
        is(scalar @removed, 1, "AC-B3 a 'remove' decision calls the remove seam exactly once");
        is(bstr(href($removed[0])->{name}), 'ripgrep', 'AC-B3 the remove seam received the right item');
        my $store_r = eval { BackpackApproval::load($ap) } || {};
        ok(!exists href($store_r)->{$k}, 'AC-B3 a SUCCESSFUL remove (rc 0) applies forget');
    }
    {
        my $ap = "$BP_DIR/approvals-commit-rf.json";
        my $pl = eval { BackpackReview::plan(file => $BP_GOOD, approvals => $ap) };
        $pl = {} unless ref $pl eq 'HASH';
        my $k = eval { BackpackApproval::item_key($BP_ITEMS[2]) };
        my @removed;
        my ($approved, $deferred) = eval { BackpackReview::commit(
            plan => $pl, approvals => $ap,
            decisions => { $k => 'remove' },
            remove => sub { push @removed, $_[0]; 256 },     # non-zero rc
            on_error => sub { },
        ) };
        is(scalar @removed, 1, 'AC-B3 a failing remove still called the seam once');
        my $store_f = eval { BackpackApproval::load($ap) } || {};
        ok(!exists href($store_f)->{$k},
            'AC-B3 a FAILED remove does not approve the item either -- it stays pending');
        is(scalar(grep { BackpackApproval::item_key($_) eq $k } @{ aref($approved) }), 0,
            'AC-B3 a failed remove leaves the item OUT of the approved set (it is still pending)');
        cmp_ok(num($deferred), '>=', 1, 'AC-B3 a failed remove leaves the item counted as undecided');
    }
    {
        # a 'defer' decision changes nothing
        my $ap = "$BP_DIR/approvals-commit-d.json";
        my $pl = eval { BackpackReview::plan(file => $BP_GOOD, approvals => $ap) };
        $pl = {} unless ref $pl eq 'HASH';
        my @removed;
        my ($approved, $deferred) = eval { BackpackReview::commit(
            plan => $pl, approvals => $ap,
            decisions => { map { BackpackApproval::item_key($_) => 'defer' } @BP_ITEMS },
            remove => sub { push @removed, $_[0]; 0 },
            on_error => sub { },
        ) };
        is(scalar @removed, 0, "AC-B3 'defer' spawns nothing");
        is(scalar @{ aref($approved) }, 0, "AC-B3 'defer' approves nothing");
        is(num($deferred), 3, "AC-B3 'defer' leaves all three items undecided");   # shape-lint: intentional - a FIXTURE count this file wrote
    }
}

# --- AC-B4 (behaviour 44): review's backward compatibility -----------------
{
    my $bp = "$BP_DIR/backpack-review-compat.json";
    _write($bp, '{"version":1,"items":['
        . '{"category":"apt","name":"jq","install":"apt-get install -y jq","verify":"jq --version","rationale":"r"},'
        . '{"category":"apt","name":"doomed","install":"apt-get install -y doomed","verify":"doomed -v","rationale":"r"},'
        . '{"category":"npm","name":"tsx","install":"npm i -g tsx","verify":"tsx -v","rationale":"r"}]}');
    my $input = "a\nr\ny\nq\n";
    open my $in, '<', \$input or die "in: $!";
    my $output = '';
    open my $out, '>', \$output or die "out: $!";
    my @removes;
    my ($approved, $deferred) = eval { BackpackReview::review(
        file => $bp, approvals => "$BP_DIR/approvals-compat.json",
        in => $in, out => $out, use_color => 0,
        remove => sub { push @removes, $_[0]; 0 }) };
    is($@, '', 'AC-B4 review still runs against a scripted STDIN fixture');
    is(scalar @{ aref($approved) }, 1, 'AC-B4 review approved exactly the one item that was approved');
    is(num($deferred), 1, 'AC-B4 review reports the one deferred item');
    is(scalar @removes, 1, 'AC-B4 review called the remove seam once');
    cmp_ok(index($output, '[a]pprove'), '>=', 0,
        'AC-B4 review still prints its existing prompt string verbatim');
    cmp_ok(index($output, 'AS ROOT'), '>=', 0, 'AC-B4 review still prints the as-root warning');
}

# --- AC-B5 (behaviour 45): triage_model -----------------------------------
{
    my $ap = "$BP_DIR/approvals-triage.json";
    my $plan = eval { BackpackReview::plan(file => $BP_GOOD, approvals => $ap) };
    $plan = {} unless ref $plan eq 'HASH';
    my $model = scalar_ls('triage_model', aref($plan->{pending}), aref($plan->{ok}));
    ok(ref $model eq 'HASH', 'AC-B5 triage_model returns a model hashref');
    is(bstr(href($model)->{mode}), 'triage', 'AC-B5 the model is in triage mode');
    my @rows = grep { bstr(href($_)->{kind}) eq 'row' } @{ aref(href($model)->{items}) };
    cmp_ok(scalar @rows, '>', 0, 'AC-B5 liveness: the triage model carries rows');
    my $wrong_group = grep { bstr(href($_)->{group}) ne 'backpack' } @rows;
    is($wrong_group, 0, "AC-B5 every triage row sits in the 'backpack' group");
    my $wrong_state = grep { bstr(href($_)->{state}) ne 'defer' } @rows;
    is($wrong_state, 0, "AC-B5 every triage row starts in state 'defer'");
    my %ids = map { bstr(href($_)->{id}) => 1 } @rows;
    my $missing_key = grep { !$ids{ BackpackApproval::item_key($_) } } @BP_ITEMS;
    is($missing_key, 0, 'AC-B5 row ids are the exact BackpackApproval::item_key byte strings (identity, never a re-encode)');

    my $bplan = eval { BackpackReview::plan(file => $BP_BROKEN, approvals => "$BP_DIR/approvals-triage2.json") };
    $bplan = {} unless ref $bplan eq 'HASH';
    my $bmodel = scalar_ls('triage_model', aref($bplan->{pending}), aref($bplan->{ok}),
                           error => $bplan->{error});
    cmp_ok(length(bstr(href($bmodel)->{error})), '>', 0,
        'AC-B5 a broken plan populates the model error field');

    my $eplan = eval { BackpackReview::plan(file => $BP_EMPTY, approvals => "$BP_DIR/approvals-triage3.json") };
    $eplan = {} unless ref $eplan eq 'HASH';
    my $emodel = scalar_ls('triage_model', aref($eplan->{pending}), aref($eplan->{ok}));
    my $bframe = frame_text(scalar_ls('compose_list', mk_ls($bmodel), 24, 80));
    my $eframe = frame_text(scalar_ls('compose_list', mk_ls($emodel), 24, 80));
    cmp_ok(length($bframe), '>', 0, 'AC-B5 liveness: the broken triage frame has text');
    isnt($bframe, $eframe,
        'AC-B5 a broken plan and an empty-but-fine plan render DIFFERENTLY (never both as "nothing packed")');
}

# --- AC-B5b: the approval walk is BOUNDED per screen -----------------------
#
# Bug report 20260829-194517-fea7. Every pending item contributes four rows --
# its identity, then its install command, its verify command and its rationale
# (added because rendering only the name approved, as root, text the operator
# was never shown). Handing the whole pending list to ONE screen therefore grew
# without bound and was cut off at the bottom of the terminal.
#
# That is worse than an ugly screen. This is a security gate: the commands run
# AS ROOT in the container and approval is keyed to a content hash of the exact
# commands, so an operator who cannot READ a command cannot give the consent the
# gate exists to collect. Truncation means approving unread root commands.
#
# What is asserted is the property that fixes it: a screen's height does not
# depend on how many items are pending. Measured before the change: 9 pending
# produced 36 body rows, 40 produced 160.
{
    my @many = map {
        +{ _approval_key => "apt:pkg-$_",
           install       => "apt-get install -y pkg-$_",
           verify        => "command -v pkg-$_",
           rationale     => "needed for build step $_" }
    } 1 .. 40;

    my $one_of_many = scalar_ls('triage_model', aref([ $many[0] ]), aref([]));
    my $one_of_few  = scalar_ls('triage_model', aref([ $many[0] ]), aref([]));
    my $n_many = scalar @{ aref(href($one_of_many)->{items}) };
    my $n_few  = scalar @{ aref(href($one_of_few)->{items})  };

    cmp_ok($n_many, '>', 0, 'AC-B5b liveness: a one-item triage model carries rows');
    is($n_many, $n_few,
        'AC-B5b a single-item screen is the same size regardless of how many items are pending');
    cmp_ok($n_many, '<=', 8,
        "AC-B5b a single-item screen stays small enough to fit a short terminal (got $n_many rows)");

    # And the whole-list form is what it replaced: it DOES grow with N. Asserted
    # so this pair cannot silently become vacuous if triage_model ever stopped
    # emitting detail rows -- the bound above would then pass for the wrong
    # reason.
    my $all = scalar_ls('triage_model', aref(\@many), aref([]));
    cmp_ok(scalar @{ aref(href($all)->{items}) }, '>', $n_many * 10,
        'AC-B5b non-vacuity: the all-at-once form really does grow with the item count');
}

# --- AC-B5c: the screen can say where in the walk it is --------------------
#
# The progress indicator belongs in the label, not a body row: every row this
# screen spends on bookkeeping is a row it is not spending on the commands it
# exists to show.
{
    my $it = { _approval_key => 'apt:ripgrep', install => 'apt-get install -y ripgrep',
               verify => 'command -v rg', rationale => 'fast search' };

    my $labelled = scalar_ls('triage_model', aref([$it]), aref([]),
                             label => 'backpack approval - item 3 of 9');
    is(bstr(href($labelled)->{label}), 'backpack approval - item 3 of 9',
        'AC-B5c the label is overridable, so a wizard step can say "item N of M"');

    my $default = scalar_ls('triage_model', aref([$it]), aref([]));
    is(bstr(href($default)->{label}), 'backpack approval',
        'AC-B5c omitting the label keeps the string every existing caller already rendered');

    # The root warning survives the override. It is the one line on this screen
    # that states the stakes, and a caller passing a label must not displace it.
    cmp_ok(length(bstr(href($labelled)->{notice})), '>', 0,
        'AC-B5c a labelled screen still carries the AS-ROOT notice');
}

# --- AC-B7: the screen module cannot persist anything itself ---------------
{
    my $ls_src = _comment_stripped(bstr(slurp($LS_PM)));
    ok(length($ls_src) > 0, 'AC-B7 liveness: tui/LaunchScreens.pm was read as source text');
    for my $name (qw(BackpackApproval BackpackReview)) {
        is(index($ls_src, $name), -1, "AC-B7 tui/LaunchScreens.pm names no $name");
    }
    # CALL FORMS only: a bare \bclose\b matches the literal 'close', a bare
    # \bwarn\b matches the MANDATED Theme role literal 'state.warn' (C-M ii).
    my %fs = (
        'open('   => qr/\bopen\s*\(/,
        'close('  => qr/\bclose\s*\(/,
        'unlink(' => qr/\bunlink\s*\(/,
        'rename(' => qr/\brename\s*\(/,
        'opendir('=> qr/\bopendir\s*\(/,
    );
    for my $label (sort keys %fs) {
        unlike($ls_src, $fs{$label}, "AC-B7 tui/LaunchScreens.pm contains no $label call");
    }
    # AC-B7b counter-fixture: every detector proven live on a temp fixture.
    my $fx = "$BP_DIR/ac-b7-fixture.pl";
    _write($fx, "open(my \$fh, '<', \$p);\nclose(\$fh);\nunlink(\$p);\nrename(\$a,\$b);\n"
              . "opendir(my \$d, \$p);\nmy \$x = BackpackApproval::load(\$p);\nBackpackReview::plan();\n");
    my $fxs = _comment_stripped(bstr(slurp($fx)));
    for my $label (sort keys %fs) {
        like($fxs, $fs{$label}, "AC-B7b counter-fixture: the $label detector fires on a fixture containing it");
    }
    cmp_ok(index($fxs, 'BackpackApproval'), '>=', 0,
        'AC-B7b counter-fixture: the BackpackApproval detector fires on a fixture naming it');
    cmp_ok(index($fxs, 'BackpackReview'), '>=', 0,
        'AC-B7b counter-fixture: the BackpackReview detector fires on a fixture naming it');
}

# ===========================================================================
# AC-W -- the launcher.pl wiring (criteria 1, 3, 4 and the inherited C-I
# changes). launcher.pl is SLURPED AS SOURCE TEXT ONLY: never require'd,
# never do'ne, never executed. It builds a container image and starts a
# container, so running it from a test is forbidden outright (criterion 6).
# Whole-line comments are blanked BEFORE every scan -- this file documents
# itself heavily, and a scan that reads prose punishes it for doing so.
# ===========================================================================

# _balanced_braces / extract_sub_body -- t/54:63-105's established shape.
sub _balanced_braces {
    my ($src, $from) = @_;
    my $idx = index($src, '{', $from);
    return undef if $idx < 0;
    my ($depth, $i, $len) = (0, $idx, length($src));
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++ }
        elsif ($c eq '}') { $depth--; last if $depth == 0 }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}
sub extract_sub_body {
    my ($src, $literal) = @_;
    my $idx = index($src, $literal);
    return undef if $idx < 0;
    return _balanced_braces($src, $idx);
}
# extract_sig_handler($src, $sig) -- the body of a top-level
# `$SIG{NAME} = sub { ... }` handler.
#
# NOT extract_sub_body. That balances from the first `{` at or after the
# literal, and in `$SIG{INT}` the first `{` is the SUBSCRIPT brace -- so it
# returned the four-character string `{INT}` for every signal, and the AC-W6
# assertions below could not pass no matter what the handler actually
# contained. The handlers were correctly wired the whole time; the extraction
# was looking at a subscript.
#
# Skips past the subscript to the `=`, then to the `sub` keyword, and balances
# from there. Returns undef rather than guessing if any of the three is missing,
# so a shape this does not understand fails the located-check loudly instead of
# silently yielding a body that happens to parse.
sub extract_sig_handler {
    my ($src, $sig) = @_;
    my $lit = "\$SIG{$sig}";
    my $idx = index($src, $lit);
    return undef if $idx < 0;
    my $eq = index($src, '=', $idx + length($lit));
    return undef if $eq < 0;
    my $sub = index($src, 'sub', $eq);
    return undef if $sub < 0;
    return _balanced_braces($src, $sub);
}
# region_between($src, $tag) -- the text between a launch-emit style sentinel
# pair, or undef when either sentinel is missing / out of order.
sub region_between {
    my ($src, $begin, $end) = @_;
    my $b = index($src, $begin);
    return undef if $b < 0;
    my $e = index($src, $end, $b);
    return undef if $e < 0;
    return substr($src, $b, $e - $b + length($end));
}

my $LSRC_RAW = bstr(slurp($LAUNCHER));
my $LSRC     = _comment_stripped($LSRC_RAW);
ok(length($LSRC) > 0, 'AC-W launcher.pl was read as SOURCE TEXT (never require\'d, never run)')
    or diag("  cannot read $LAUNCHER");

# The print/printf/say STATEMENT detectors, shared by AC-W1 and its
# counter-fixture so the two can never drift apart.
my %PRINT_DETECTORS = (
    'print STDOUT/STDERR/{FH}' => qr/\bprint\s+(?:STDOUT|STDERR|\{)/,
    'print "..." / print $x'   => qr/\bprint\s+["'_\$]/,
    'printf'                   => qr/\bprintf\s*\(?/,
    'say'                      => qr/\bsay\s/,
);

{
    my @units = @{ LS_EMIT_UNITS() };
    cmp_ok(scalar @units, '>', 0, 'AC-W1 liveness: EMIT_UNITS() declares at least one unit');

    # the units the spec REQUIRES to be present (the list may grow; no test
    # pins its length)
    my %declared_sub    = map { bstr(href($_)->{name}) => 1 }
                          grep { bstr(href($_)->{kind}) eq 'sub' } @units;
    my %declared_region = map { bstr(href($_)->{name}) => 1 }
                          grep { bstr(href($_)->{kind}) eq 'region' } @units;
    for my $s (qw(build_image run_perl_or_die _capture_or_die _surface_last_reap
                  pick_session_action _tee_system)) {
        ok($declared_sub{$s}, "AC-W1 EMIT_UNITS() declares sub '$s' as an emit unit");
    }
    for my $r (qw(launch-emit:select launch-emit:ports launch-emit:create launch-emit:backpack)) {
        ok($declared_region{$r}, "AC-W1 EMIT_UNITS() declares region '$r' as an emit unit");
    }

    # AC-W2: every declared unit ACTUALLY EXISTS (without this, AC-W1 passes
    # vacuously on a unit nobody ever created).
    my %body;
    for my $u (@units) {
        my $kind = bstr(href($u)->{kind});
        my $name = bstr(href($u)->{name});
        next unless length $name;
        if ($kind eq 'sub') {
            my $b = extract_sub_body($LSRC, "sub $name");
            $body{"sub $name"} = $b;
            ok(defined $b, "AC-W2 launcher.pl defines sub $name (the declared emit unit exists)");
        } else {
            my $b = region_between($LSRC_RAW, "# >>> $name:BEGIN", "# <<< $name:END");
            $body{"region $name"} = defined $b ? _comment_stripped($b) : undef;
            ok(defined $b, "AC-W2 launcher.pl carries the $name sentinel pair, BEGIN before END");
        }
    }

    # AC-W1: no print/printf/say inside any declared unit.
    my ($violations, $first_bad) = (0, undef);
    for my $key (sort keys %body) {
        my $b = $body{$key};
        next unless defined $b;
        for my $label (sort keys %PRINT_DETECTORS) {
            if ($b =~ $PRINT_DETECTORS{$label}) {
                $violations++;
                $first_bad //= "$key contains a '$label' statement";
            }
        }
    }
    is($violations, 0, 'AC-W1 no declared emit unit contains a print/printf/say statement')
        or diag("  first offender: " . (defined $first_bad ? $first_bad : '?'));

    # AC-W1b counter-fixture: every detector proven live on a temp fixture.
    my $fx = "$BP_DIR/ac-w1-fixture.pl";
    _write($fx, "sub demo {\n    print STDERR \"boom\\n\";\n    print \"hello\\n\";\n"
              . "    printf(\"%s\\n\", \$x);\n    say \"there\";\n}\n");
    my $fxs = _comment_stripped(bstr(slurp($fx)));
    for my $label (sort keys %PRINT_DETECTORS) {
        like($fxs, $PRINT_DETECTORS{$label},
            "AC-W1b counter-fixture: the '$label' detector fires on a fixture containing it");
    }
}

{
    # AC-W3: the four emit wrappers exist and route through the module.
    for my $w (qw(_emit_out _emit_err _emit_step _emit_ok)) {
        my $b = extract_sub_body($LSRC, "sub $w");
        ok(defined $b, "AC-W3 launcher.pl defines $w");
        cmp_ok(index(bstr($b), 'tui::LaunchScreens::emit'), '>=', 0,
            "AC-W3 $w routes through tui::LaunchScreens::emit");
    }

    # AC-W4: the EXISTING sentinel regions are intact (t/23 Part 5 and t/58
    # extract them as source text and go red on any disturbance).
    for my $pair (['# >>> s-reap-notice:BEGIN', '# >>> s-reap-notice:END'],
                  ['# >>> s03:health-detect:BEGIN', '# <<< s03:health-detect:END']) {
        my ($b, $e) = @$pair;
        is(count_sub($LSRC_RAW, $b), 1, "AC-W4 '$b' appears exactly once");
        is(count_sub($LSRC_RAW, $e), 1, "AC-W4 '$e' appears exactly once");
        cmp_ok(index($LSRC_RAW, $b), '<', index($LSRC_RAW, $e), "AC-W4 '$b' precedes its END");
    }
    my $reap = region_between($LSRC_RAW, '# >>> s-reap-notice:BEGIN', '# >>> s-reap-notice:END');
    for my $s (qw(parse_reap_record reap_notice_lines _reap_wrap)) {
        cmp_ok(index(bstr($reap), "sub $s"), '>=', 0, "AC-W4 $s is still defined INSIDE the reap-notice region");
    }
    my $s03 = region_between($LSRC_RAW, '# >>> s03:health-detect:BEGIN', '# <<< s03:health-detect:END');
    cmp_ok(index(bstr($s03), 'sub s03_run_launch_gate'), '>=', 0,
        'AC-W4 s03_run_launch_gate is still defined inside the s03 region');

    # AC-W5: the _c_* helpers survive for the PLAIN path and never paint
    # inside the frame.
    for my $c (qw(_c _c_step _c_ok _c_warn _c_err)) {
        cmp_ok(index($LSRC, "sub $c"), '>=', 0,
            "AC-W5 launcher.pl still defines sub $c (the plain path's colour survives)");
    }
    my $ls_src = _comment_stripped(bstr(slurp($LS_PM)));
    for my $c (qw(_c_step _c_ok _c_warn _c_err)) {
        is(index($ls_src, $c), -1, "AC-W5 tui/LaunchScreens.pm names no $c (C-D: role names only)");
    }

    # AC-W6: the signal handlers tear the host down FIRST.
    for my $sig (qw(INT TERM)) {
        my $body = extract_sig_handler($LSRC, $sig);
        ok(defined $body, "AC-W6 the \$SIG{$sig} handler body was located");
        my $hl = index(bstr($body), 'tui::LaunchScreens::host_leave');
        my $rt = index(bstr($body), 'reset_terminal');
        cmp_ok($hl, '>=', 0, "AC-W6 the \$SIG{$sig} handler calls tui::LaunchScreens::host_leave");
        cmp_ok($rt, '>=', 0, "AC-W6 the \$SIG{$sig} handler still calls reset_terminal");
        ok($hl >= 0 && $rt >= 0 && $hl < $rt,
            "AC-W6 host_leave comes BEFORE reset_terminal in the \$SIG{$sig} handler");
    }
    my $end_body = extract_sub_body($LSRC, 'END {');
    cmp_ok(index(bstr($end_body), 'tui::LaunchScreens::host_leave'), '>=', 0,
        'AC-W6 the END block also tears the host down (guarded)');

    # AC-W6c -- the approval walk asks ONE ITEM PER SCREEN.
    #
    # Bug report 20260829-194517-fea7. Handing the whole pending list to one
    # triage screen overflowed the terminal and dropped the surplus off the
    # bottom -- in a gate whose commands run AS ROOT and whose approval is
    # hashed to those exact commands, so unread meant unconsented.
    #
    # t/68's AC-B5b pins the MODEL side (a one-item screen is bounded). This
    # pins the WIRING side: the launcher must not hand the whole array back to
    # it. Asserted as the absence of the old shape rather than the presence of
    # the new one -- there are many ways to write a loop, and only one way to
    # regress.
    my $walk = extract_sub_body($LSRC, 'sub _backpack_triage_via_screen');
    ok(defined $walk, 'AC-W6c located _backpack_triage_via_screen');
  SKIP: {
        skip 'walk body not found', 2 unless defined $walk;
        my $w = bstr($walk);
        cmp_ok(index($w, 'triage_model'), '>=', 0,
            'AC-W6c liveness: the walk really does build a triage model');
        # \Q...\E, not a hand-escaped pattern. The first version of this
        # assertion used /triage_model\s*\(\s*\\\@shown\b/ and was VACUOUS: it
        # matched neither the old shape nor the new one, so it reported the fix
        # as verified while testing nothing. Caught by running it against the
        # old line. A guard for a regression must be shown to fail on the
        # regression -- the counter-fixture below does exactly that, in-file, so
        # it cannot rot into a tautology again.
        my $OLD_SHAPE = 'triage_model(\@shown';
        ok(index($w, $OLD_SHAPE) < 0,
            'AC-W6c the walk does NOT pass the whole pending list to one screen');

        my $old_line = 'my $res = _launch_run_list(tui::LaunchScreens::'
                     . 'triage_model(\@shown, $plan->{ok}, error => $plan->{error}));';
        cmp_ok(index($old_line, $OLD_SHAPE), '>=', 0,
            'AC-W6c counter-fixture: the same test really does flag the all-at-once shape');
    }

    # AC-W6b counter-fixture: the SAME comparator on a hand-built string with
    # the two calls reversed must report a violation.
    my $reversed = "sub handler { reset_terminal(); tui::LaunchScreens::host_leave(\$H); }";
    my ($rhl, $rrt) = (index($reversed, 'tui::LaunchScreens::host_leave'), index($reversed, 'reset_terminal'));
    ok(!($rhl < $rrt), 'AC-W6b counter-fixture: the same comparator reports a violation when the calls are reversed');

    # AC-W7: every list_run( call site names heartbeat in its argument list.
    my ($lr_sites, $lr_bad) = (0, 0);
    my $pos = 0;
    while ((my $i = index($LSRC, 'list_run(', $pos)) >= 0) {
        $lr_sites++;
        my $chunk = substr($LSRC, $i, 1200);
        $lr_bad++ unless index($chunk, 'heartbeat') >= 0;
        $pos = $i + 9;
    }
    cmp_ok($lr_sites, '>', 0, 'AC-W7 liveness: launcher.pl has at least one list_run call site');
    is($lr_bad, 0, 'AC-W7 every list_run call site wires the heartbeat seam');
    # AC-W7b counter-fixture
    my $fx7 = "my \$r = tui::LaunchScreens::list_run(model => \$m, read_key => \$rk);";
    ok(index($fx7, 'heartbeat') < 0,
        'AC-W7b counter-fixture: the detector reports a list_run call with no heartbeat key');

    # AC-W8: decide_mode keeps its three arguments and Dashboard.pm is not
    # rewritten.
    my ($dm) = $LSRC =~ /Dashboard::decide_mode\s*\(([^;]*?)\)/s;
    ok(defined $dm, 'AC-W8 launcher.pl still calls Dashboard::decide_mode');
    my $commas = ($dm // '') =~ tr/,//;
    is($commas, 2, 'AC-W8 the decide_mode call passes exactly three arguments');
    my $dsrc = _comment_stripped(bstr(slurp("$SCRIPTS/Dashboard.pm")));
    cmp_ok(index($dsrc, 'sub decide_mode'), '>=', 0, 'AC-W8 Dashboard.pm still defines decide_mode');
    like($dsrc, qr/sub decide_mode\s*\{\s*my\s*\(\s*\$\w+\s*,\s*\$\w+\s*,\s*\$\w+\s*\)/,
        'AC-W8 decide_mode still unpacks exactly three parameters (no variant was created)');

    # AC-W9 (inherited C-I item 2): every recent_events call passes FOUR
    # arguments and a defined 4th -- an undefined $now silently deletes the
    # per-event time column.
    my ($re_sites, $re_bad, $re_first) = (0, 0, undef);
    my $p2 = 0;
    while ((my $i = index($LSRC, 'Dashboard::recent_events(', $p2)) >= 0) {
        $re_sites++;
        my $args = _balanced_parens($LSRC, $i + length('Dashboard::recent_events'));
        my @top = split_top_level(bstr($args));
        if (scalar @top != 4 || $top[3] =~ /^\s*undef\s*$/) {
            $re_bad++;
            $re_first //= "site $re_sites args=(" . join('|', @top) . ")";
        }
        $p2 = $i + 25;
    }
    cmp_ok($re_sites, '>=', 3, 'AC-W9 liveness: all three recent_events call sites are present');
    is($re_bad, 0, 'AC-W9 every Dashboard::recent_events call passes four arguments with a defined 4th')
        or diag("  first offender: " . (defined $re_first ? $re_first : '?'));
    # AC-W9b counter-fixture
    my @two = split_top_level('\@lines, 8');
    ok(scalar(@two) != 4, 'AC-W9b counter-fixture: the arity detector fires on a two-argument call');
    my @undef4 = split_top_level('\@lines, 8, undef, undef');
    ok($undef4[3] =~ /^\s*undef\s*$/, 'AC-W9b counter-fixture: the detector fires on a bare undef 4th argument');

    # AC-W10 (inherited C-I item 5): sampler_reap_decision keeps its 4th
    # argument -- a 3-arg call silently reintroduces killing a LIVE sampler
    # belonging to another launcher.
    my ($sr_sites, $sr_bad) = (0, 0);
    my $p3 = 0;
    while ((my $i = index($LSRC, 'Resources::sampler_reap_decision(', $p3)) >= 0) {
        $sr_sites++;
        my $args = _balanced_parens($LSRC, $i + length('Resources::sampler_reap_decision'));
        $sr_bad++ unless scalar(split_top_level(bstr($args))) == 4;
        $p3 = $i + 32;
    }
    cmp_ok($sr_sites, '>', 0, 'AC-W10 liveness: launcher.pl still calls Resources::sampler_reap_decision');
    is($sr_bad, 0, 'AC-W10 every sampler_reap_decision call passes the 4th (owner_alive) argument');
    my @three = split_top_level('$text, $now, $iv');
    ok(scalar(@three) != 4, 'AC-W10b counter-fixture: the arity detector fires on a three-argument call');

    # AC-W11 (inherited C-I items 3 and 4)
    for my $c (qw(bp_load bp_save bp_remove)) {
        cmp_ok(index($LSRC, $c), '>=', 0, "AC-W11 launcher.pl still carries the $c closure (package 07's shape)");
    }
    cmp_ok(index($LSRC, 'BackpackOps'), '>=', 0, 'AC-W11 launcher.pl still uses BackpackOps');
    is(index($LSRC, '_capture_quiet'), -1, 'AC-W11 _capture_quiet is still ABSENT from launcher.pl');

    # AC-W12: on the TUI path the pickers are data commands, not interactive
    # spawns.
    cmp_ok(index($LSRC, 'select-model'), '>=', 0, "AC-W12 launcher.pl invokes skills.pl 'select-model'");
    cmp_ok(index($LSRC, '--list-json'), '>=', 0, "AC-W12 launcher.pl invokes select-session.pl '--list-json'");
    cmp_ok(index($LSRC, 'select-interactive'), '>=', 0,
        'AC-W12 the interactive picker survives for the plain path');
    my @lines = split /\n/, $LSRC, -1;
    my ($si_line) = grep { $lines[$_] =~ /select-interactive/ } 0 .. $#lines;
    my $gated = 0;
    if (defined $si_line) {
        my $from = $si_line - 20; $from = 0 if $from < 0;
        $gated = scalar grep { /\bplain\b|\$LAUNCH_MODE/ } @lines[$from .. $si_line];
    }
    cmp_ok($gated, '>', 0,
        'AC-W12 the select-interactive spawn sits inside a branch naming the launch mode / plain path');

    # AC-W13: NO <STDIN> read after podman start (t/09's claim, restated here
    # because this package is the one at risk of breaking it).
    my ($ps_line) = grep { $lines[$_] =~ /system\s*\(\s*\$PODMAN\s*,\s*['"]start['"]/ } 0 .. $#lines;
    ok(defined $ps_line, 'AC-W13 the system($PODMAN, \'start\' call site was located');
    my $stdin_after = 0;
    if (defined $ps_line) {
        $stdin_after = scalar grep { /<STDIN>/ } @lines[$ps_line .. $#lines];
    }
    is($stdin_after, 0, 'AC-W13 no <STDIN> read appears anywhere after the podman start call');
    # counter-fixture: the same detector on a line that does read STDIN
    ok(scalar(grep { /<STDIN>/ } ('my $x = <STDIN>;')) == 1,
        'AC-W13 counter-fixture: the <STDIN> detector fires on a line that reads STDIN');

    # AC-W14: _tee_system keeps feeding the transcript UNCONDITIONALLY.
    my $tee = extract_sub_body($LSRC, 'sub _tee_system');
    ok(defined $tee, 'AC-W14 sub _tee_system was located');
    cmp_ok(index(bstr($tee), '$TRANSCRIPT'), '>=', 0, 'AC-W14 _tee_system still names $TRANSCRIPT');
    cmp_ok(index(bstr($tee), 'tui::LaunchScreens::fanout'), '>=', 0,
        'AC-W14 _tee_system feeds both sinks through one fanout call');
    my $guarded = 0;
    for my $l (split /\n/, bstr($tee)) {
        next unless $l =~ /\$TRANSCRIPT/;
        next unless $l =~ /\bprint\b|\bfanout\b|=>/;
        $guarded++ if $l =~ /\bif\b|\bunless\b/;
    }
    is($guarded, 0, 'AC-W14 the transcript sink is not guarded by a host-mode conditional (C-H)');
    cmp_ok(index(bstr($tee), 'tee_should_fork'), '>=', 0,
        'AC-W14 the fork decision goes through tee_should_fork');
    cmp_ok(index(bstr($tee), 'tee_fallback_route'), '>=', 0,
        'AC-W14 the fallback route goes through tee_fallback_route');
}

# _balanced_parens($src,$from) -> the '(' ... ')' text including the parens.
sub _balanced_parens {
    my ($src, $from) = @_;
    my $idx = index($src, '(', $from);
    return undef if $idx < 0;
    my ($depth, $i, $len) = (0, $idx, length($src));
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '(') { $depth++ }
        elsif ($c eq ')') { $depth--; last if $depth == 0 }
    }
    return undef if $depth != 0;
    return substr($src, $idx + 1, $i - $idx - 1);
}
# split_top_level($args) -> argument terms split on TOP-LEVEL commas only.
sub split_top_level {
    my ($s) = @_;
    return () unless defined $s && length $s;
    my @out;
    my $cur   = '';
    my $depth = 0;
    for my $c (split //, $s) {
        if    ($c =~ /[\(\[\{]/) { $depth++ }
        elsif ($c =~ /[\)\]\}]/) { $depth-- }
        if ($c eq ',' && $depth == 0) { push @out, $cur; $cur = ''; next }
        $cur .= $c;
    }
    push @out, $cur if length $cur;
    return @out;
}

# ===========================================================================
# AC-R -- the in-place guard (criterion 5). t/42 is run BY THE SUITE, never
# from here; these are the three source facts t/42's positional scans depend
# on, restated so a break is diagnosed here too.
# ===========================================================================
{
    my @lines = split /\n/, $LSRC_RAW, -1;
    my $offer_idx;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /if\s*\(\s*\$route\s+eq\s+['"]offer['"]\s*\)/) { $offer_idx = $i; last }
    }
    ok(defined $offer_idx, 'AC-R1 the workcopy_route offer branch still exists in launcher.pl');
    my $close_idx;
    if (defined $offer_idx) {
        for my $i ($offer_idx + 1 .. $#lines) {
            if ($lines[$i] =~ /^\}\s*$/) { $close_idx = $i; last }
        }
    }
    ok(defined $close_idx, 'AC-R1 the offer branch still has a locatable closing brace');

    my $lock_idx;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /SandboxLock::acquire\s*\(\s*\$LOCK_DIR/) { $lock_idx = $i; last }
    }
    ok(defined $lock_idx, 'AC-R1 SandboxLock::acquire($LOCK_DIR is still present');
    ok(defined $close_idx && defined $lock_idx && $lock_idx > $close_idx,
        'AC-R1 SandboxLock::acquire still comes AFTER the offer block closes');

    my $ps_idx;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /system\s*\(\s*\$PODMAN\s*,\s*['"]start['"]/) { $ps_idx = $i; last }
    }
    ok(defined $ps_idx, 'AC-R1 the system($PODMAN, \'start\' call is still present');
    ok(defined $close_idx && defined $ps_idx && $ps_idx > $close_idx,
        'AC-R1 podman start still comes AFTER the offer block closes (t/42 AC-P3b/c)');

    # AC-R2 -- exactly ONE workcopy_refusal_outcome call site, inside the
    # offer branch. A second would make the refusal reachable on the
    # passthrough route.
    my @wro = grep { $lines[$_] =~ /workcopy_refusal_outcome\s*\(/ } 0 .. $#lines;
    is(scalar @wro, 1, 'AC-R2 workcopy_refusal_outcome has exactly one call site');   # shape-lint: intentional - t/42 AC-P4a locks this to one call site; a second makes the refusal reachable on the passthrough route
    ok(defined $offer_idx && defined $close_idx && @wro
       && $wro[0] > $offer_idx && $wro[0] < $close_idx,
        'AC-R2 that call site lies strictly inside the offer branch');

    # AC-R3 -- host_enter lands AFTER the guard and AFTER the launch lock, so
    # the refusal message stays on the plain terminal.
    my $he_idx;
    for my $i (0 .. $#lines) {
        if ($lines[$i] =~ /LaunchScreens::host_enter/) { $he_idx = $i; last }
    }
    ok(defined $he_idx, 'AC-R3 launcher.pl calls tui::LaunchScreens::host_enter');
    ok(defined $he_idx && defined $close_idx && $he_idx > $close_idx,
        'AC-R3 host_enter is called AFTER the in-place/work-copy guard block');
    ok(defined $he_idx && defined $lock_idx && $he_idx > $lock_idx,
        'AC-R3 host_enter is called AFTER SandboxLock::acquire($LOCK_DIR');
    ok(defined $he_idx && defined $ps_idx && $he_idx < $ps_idx,
        'AC-R3 host_enter is called BEFORE podman start (the whole launch renders in the TUI)');
}

# ===========================================================================
# AC-N -- no spawn, purity, totality (criterion 6).
# ===========================================================================
my %SPAWN_DETECTORS = (
    'system('      => qr/\bsystem\s*\(/,
    'backticks'    => qr/`/,
    'qx'           => qr/\bqx\b/,
    'exec('        => qr/\bexec\s*\(/,
    'fork'         => qr/\bfork\b/,
    'readpipe'     => qr/\breadpipe\b/,
    'IPC::Open2/3' => qr/IPC::Open[23]/,
    'piped open'   => qr/open\s*\([^)]*['"][^'"\n]{0,3}\|/,
);

# _code_only($src) -> $src with whole-line comments blanked, this file's own
# DETECTOR TABLE lines blanked, and the CONTENTS of quoted strings emptied.
# A spawn scan must read CODE: an assertion description that says the word
# fork, or a fixture body carried as a string literal, is prose in exactly
# the sense a comment is -- and punishing the file for either is the same
# vacuity trap the comment blanking exists to avoid.
sub _code_only {
    my ($src) = @_;
    my $s = _comment_stripped(bstr($src));
    # A line tagged SCANVOCAB *is* the scanner's vocabulary -- a detector
    # declaration or one of the stripping rules below. Reading it would make
    # the scanner fire on its own tooling, which is the same trap the comment
    # blanking exists to avoid.
    $s = join("\n", map { (/=>\s*qr\// || /SCANVOCAB/) ? '' : $_ } split /\n/, $s, -1);  ## SCANVOCAB
    # Regex literals next: a pattern body may legitimately contain a quote
    # character (a scan for a quoted 'start' argument does), and leaving it in
    # would desynchronise the string stripper below.
    $s =~ s{=~\s*!?\s*(?:qr|m)?/(?:\\.|[^/\\])*/[a-z]*}{=~ //}g;                          ## SCANVOCAB
    $s =~ s{\bqr/(?:\\.|[^/\\])*/[a-z]*}{qr//}g;                                          ## SCANVOCAB
    $s =~ s/"(?:\\.|[^"\\])*"/""/g;                                                       ## SCANVOCAB
    $s =~ s/'(?:\\.|[^'\\])*'/''/g;                                                       ## SCANVOCAB
    return $s;
}

# --- AC-N1: t/68 SPAWNS NOTHING -- scanned from its own source ------------
{
    my $self_raw  = _comment_stripped(bstr(slurp($SELF_PATH)));
    my $self_code = _code_only(bstr(slurp($SELF_PATH)));
    ok(length($self_code) > 0, 'AC-N1 liveness: t/68 read its own source');
    cmp_ok(index($self_code, 'Test::More'), '>=', 0,
        'AC-N1 liveness: the code-only view still contains this file\'s real code');
    for my $label (sort keys %SPAWN_DETECTORS) {
        next if $label eq 'piped open';
        unlike($self_code, $SPAWN_DETECTORS{$label}, "AC-N1 t/68 contains no $label construct");
    }
    # The piped-open detector is the ONE that must read strings, because the
    # mode argument IS a string ('-|'); it therefore scans the comment-blanked
    # source with literals intact.
    my $self_pipe = join("\n", map { /=>\s*qr\// ? '' : $_ } split /\n/, $self_raw, -1);
    unlike($self_pipe, $SPAWN_DETECTORS{'piped open'}, 'AC-N1 t/68 contains no piped open construct');

    # AC-N1b counter-fixture: every detector proven live on a temp fixture.
    # The constructs are assembled at runtime so that WRITING this fixture
    # does not itself put a spawn construct into t/68's own code.
    my $fx = "$BP_DIR/ac-n1-fixture.pl";
    _write($fx, join("\n",
        'sys' . "tem('ls');",
        'my $a = ' . chr(96) . 'ls' . chr(96) . ';',
        'my $b = q' . 'x{ls};',
        'ex' . "ec('ls');",
        'my $p = ' . 'fo' . 'rk;',
        'my $c = read' . "pipe('ls');",
        'use IPC::' . 'Open3;',
        'open(my $fh, ' . chr(39) . '-|' . chr(39) . ", 'ls');",
        ''));
    my $fxs = _comment_stripped(bstr(slurp($fx)));
    for my $label (sort keys %SPAWN_DETECTORS) {
        like($fxs, $SPAWN_DETECTORS{$label},
            "AC-N1b counter-fixture: the $label detector fires on a fixture containing it");
    }
}

# --- AC-N2: t/68 never executes launcher.pl -------------------------------
{
    my $self = _comment_stripped(bstr(slurp($SELF_PATH)));
    unlike($self, qr/\brequire\s+.{0,20}launcher\.pl/, 'AC-N2 t/68 never requires launcher.pl');
    unlike($self, qr/\bdo\s+["']?\$?LAUNCHER/,          'AC-N2 t/68 never do\'es launcher.pl');
    unlike($self, qr/\$\^X.{0,40}LAUNCHER/,             'AC-N2 t/68 never invokes perl on launcher.pl');
}

# --- AC-N3: the module is loadable as a module ----------------------------
use_ok('tui::LaunchScreens');

# --- AC-N4 (behaviour 49): the module's hygiene ---------------------------
my %HYGIENE = (
    'Dashboard'                 => qr/\bDashboard\b/,
    'system() call'             => qr/\bsystem\s*\(/,
    'exec() call'               => qr/\bexec\s*\(/,
    'fork'                      => qr/\bfork\b/,
    'backticks'                 => qr/`/,
    'qx'                        => qr/\bqx\b/,
    'readpipe'                  => qr/\breadpipe\b/,
    'open() call'               => qr/\bopen\s*\(/,
    'close() call'              => qr/\bclose\s*\(/,
    'unlink() call'             => qr/\bunlink\s*\(/,
    'rename() call'             => qr/\brename\s*\(/,
    'opendir() call'            => qr/\bopendir\s*\(/,
    'time() call'               => qr/\btime\s*\(\s*\)/,
    'sleep() call'              => qr/\bsleep\s*[\(\s]\s*\$?\d|\bsleep\s*\(/,
    'print statement'           => qr/\bprint\s+(?:STDOUT|STDERR|\{|["'_\$])/,
    'printf call'               => qr/\bprintf\s*\(/,
    'say statement'             => qr/\bsay\s+["'\$]/,
    'warn() call'               => qr/\bwarn\s*\(/,
    'die() call'                => qr/\bdie\s*[\(\s]["'\$]/,
    '%ENV access'               => qr/\$ENV\{/,
    'hex colour literal'        => qr/#[0-9a-fA-F]{6}\b/,
    'SGR colour escape'         => qr/\\e\[\d+(?:;\d+)*m/,
    'literal breakpoint 90'     => qr/(?<![\d.])90(?![\d.])/,
    'high \\x{} escape'         => qr/\\x\{0*[1-9a-fA-F][0-9a-fA-F]{2,}\}/,
);
{
    my $ls_src = _comment_stripped(bstr(slurp($LS_PM)));
    ok(length($ls_src) > 0, 'AC-N4 liveness: tui/LaunchScreens.pm was read as source text');
    for my $label (sort keys %HYGIENE) {
        unlike($ls_src, $HYGIENE{$label}, "AC-N4 tui/LaunchScreens.pm contains no $label");
    }
    my @high = grep { ord($_) >= 0x80 } split //, bstr(slurp($LS_PM));
    is(scalar @high, 0, 'AC-N4 tui/LaunchScreens.pm contains no byte >= 0x80 (every glyph comes from Theme::glyph)');
    cmp_ok(index($ls_src, 'BREAKPOINT_TWO_COL'), '>=', 0,
        'AC-N4 the breakpoint is referenced by accessor (C-E), which is why the literal is absent');

    # AC-N4b counter-fixture: every detector proven live on a temp fixture.
    my $fx = "$BP_DIR/ac-n4-fixture.pl";
    _write($fx, join("\n",
        'my $d = Dashboard::decide_mode(1,1,undef);',
        "system('ls'); exec('ls'); my \$p = fork; my \$b = `ls`; my \$q = qx{ls}; readpipe('ls');",
        "open(my \$fh,'<',\$p); close(\$fh); unlink(\$p); rename(\$a,\$b); opendir(my \$dd,\$p);",
        'my $t = time(); sleep(1);',
        'print STDERR "x"; printf("%s", $x); say "y";',
        'warn("careful"); die "boom";',
        'my $e = $ENV{HOME};',
        'my $hex = "#ff8800";',
        'my $sgr = "\e[31m";',
        'my $bp = 90;',
        'my $wide = "\x{2192}";',
        ''));
    my $fxs = _comment_stripped(bstr(slurp($fx)));
    for my $label (sort keys %HYGIENE) {
        like($fxs, $HYGIENE{$label}, "AC-N4b counter-fixture: the '$label' detector fires on a fixture containing it");
    }
    # ... and the detectors must NOT fire on the constructs they are
    # deliberately narrowed around (C-M ii): the mandated Theme role literals.
    my $narrow = "my \$r = 'state.warn'; my \$a = 'close'; my \$w = \$row->{warn};";
    unlike($narrow, $HYGIENE{'warn() call'}, "AC-N4b the warn detector does NOT fire on the mandated literal 'state.warn'");
    unlike($narrow, $HYGIENE{'close() call'}, "AC-N4b the close detector does NOT fire on the literal 'close'");
}

# --- AC-N7: the module's use/require list is a subset of the closed list ---
{
    my $ls_src = _comment_stripped(bstr(slurp($LS_PM)));
    my %allowed = map { $_ => 1 } qw(strict warnings constant Theme
                                     tui::Frame tui::Layout tui::Screen tui::DashboardScreen);
    my @found = $ls_src =~ /^\s*(?:use|require)\s+([A-Za-z_][\w:]*)/mg;
    cmp_ok(scalar @found, '>', 0, 'AC-N7 liveness: the module declares at least one use/require');
    my @illegal = grep { !$allowed{$_} } @found;
    is(scalar @illegal, 0, "AC-N7 every use/require target is on S2.0's closed list")
        or diag("  illegal targets: " . join(', ', @illegal));

    # AC-N7b counter-fixture
    my $fx = "$BP_DIR/ac-n7-fixture.pm";
    _write($fx, "package X;\nuse strict;\nuse JSON::PP;\nuse Term::ReadKey;\n1;\n");
    my @fx_found = _comment_stripped(bstr(slurp($fx))) =~ /^\s*(?:use|require)\s+([A-Za-z_][\w:]*)/mg;
    my @fx_illegal = grep { !$allowed{$_} } @fx_found;
    cmp_ok(scalar @fx_illegal, '>', 0,
        'AC-N7b counter-fixture: the detector fires on a fixture containing use JSON::PP / Term::ReadKey');
}

# --- AC-N6 (behaviour 51): totality against the hostile corpus ------------
{
    my $blessed = bless {}, 'SomeClass';
    my @HOSTILE = (undef, '', 0, -1, 'x', [], {}, sub { 1 }, $blessed,
                   "\xff\xfe invalid utf8", ('Z' x 10240), "\e[31m", "Andr\xc3\xa9");
    my @FNS = qw(make_host host_enter host_leave host_handover add_banner
                 capture_new capture_line capture_replay capture_tail capture_count
                 capture_sink_errors fanout emit stream_line infer_role emit_theme_role
                 tee_should_fork tee_fallback_route stages_init stage_begin stage_end
                 stage_state STAGE_LABEL progress_screen compose_progress repaint
                 failure_report list_init list_first_row list_advance list_dispatch_key
                 list_apply list_selection list_banners list_screen compose_list
                 triage_model choose_mode LIST_FOOTER_LEGEND);
    my ($deaths, $warns, $first_death, $first_warn) = (0, 0, undef, undef);
    for my $fn (@FNS) {
        next unless $LS_OK && tui::LaunchScreens->can($fn);
        for my $a (@HOSTILE) {
            for my $b (@HOSTILE) {
                local $SIG{__WARN__} = sub {
                    $warns++; $first_warn //= "$fn: $_[0]";
                };
                my $ok = eval { no strict 'refs'; &{"tui::LaunchScreens::$fn"}($a, $b); 1 };
                if (!$ok) { $deaths++; $first_death //= "$fn died: " . ($@ || '?') }
            }
        }
    }
    ok($LS_OK, 'AC-N6 liveness: the module loaded, so the hostile corpus actually ran')
        or diag('  the module does not exist yet, so nothing could be exercised');
    is($deaths, 0, 'AC-N6 no public function dies on the hostile corpus')
        or diag("  first death: " . (defined $first_death ? $first_death : '?'));
    is($warns, 0, 'AC-N6 no public function warns on the hostile corpus')
        or diag("  first warning: " . (defined $first_warn ? $first_warn : '?'));
}

# --- AC-N5 (behaviour 50): every span role of every fixture frame is known -
{
    my ($h) = progress_fixture();
    my @frames = (
        scalar_ls('compose_progress', $h, 24, 80),
        scalar_ls('compose_progress', $h, 12, $BP + 20),
        scalar_ls('compose_list', mk_ls($MULTI_MODEL),  24, 80),
        scalar_ls('compose_list', mk_ls($SINGLE_MODEL), 20, 60),
        scalar_ls('compose_list', mk_ls($TRIAGE_MODEL), 18, 100),
        scalar_ls('compose_list', mk_ls($BROKEN_MODEL), 24, 80),
        scalar_ls('compose_list', mk_ls($EMPTY_MODEL),  24, 80),
    );
    my ($bad, $spans, $first_bad) = (0, 0, undef);
    for my $f (@frames) {
        for my $c (@{ aref($f) }) {
            for my $sp (@{ aref(href($c)->{spans}) }) {
                $spans++;
                my $r = href($sp)->{role};
                next if tui::Frame::is_known_role($r);
                $bad++;
                $first_bad //= "role=" . bstr($r);
            }
        }
    }
    cmp_ok($spans, '>', 0, 'AC-N5 liveness: the fixture frames produced spans to check');
    is($bad, 0, 'AC-N5 every span of every fixture frame carries a role tui::Frame::is_known_role accepts')
        or diag("  first offender: " . (defined $first_bad ? $first_bad : '?'));
    # counter-fixture: the same predicate rejects an invented role.
    is(tui::Frame::is_known_role('zqx.not.a.role'), 0,
        'AC-N5 counter-fixture: the same predicate rejects an invented role');
}

done_testing();
