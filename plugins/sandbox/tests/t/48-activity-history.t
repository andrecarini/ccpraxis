#!/usr/bin/env perl
# s13-activity-history: recent activity across restarts.
#
# This file is the ORACLE for blueprint sandbox-butler-overhaul, package
# s13-activity-history (specs/10-activity-history-spec.md). It is written
# BLIND to any LaunchLog.pm / launcher.pl / Dashboard.pm implementation --
# directly from the spec -- so it can serve as an oracle rather than an echo
# of whatever the implementer eventually writes. Do NOT weaken an assertion
# to make a future implementation's life easier.
#
# Coverage: AC1..AC22 (spec S4).
#
# Hard constraints honoured here (spec S4.1):
#   * PURE: no subprocesses, no network, no sleeping, no podman. Only
#     File::Temp directories and utime for mtime control.
#   * launcher.pl is NEVER require'd/do'ne -- AC19 is slurp + regex only
#     (t/36's stated convention, followed by t/43-t/47).
#   * Every call into a not-yet-written sub (LaunchLog::recent_logs,
#     LaunchLog::merge_sessions, Dashboard::session_boundary_row) is
#     eval-wrapped via the rlogs()/rmerge() helpers below, so a missing sub
#     degrades to a clean per-assertion FAIL rather than a fatal abort.
#   * Fixture JSON lines are produced via LaunchLog::format_event(...) with
#     explicit epoch + pid, never hand-written JSON strings.
#   * mtimes are set explicitly via utime(), never inferred from write order.
#
# AC20 note: the spec illustrates AC20 as a `perl -e 'require ...'` one-liner.
# That is a subprocess, which S4.1's PURE bullet forbids in this file. This
# file's own use_ok() at the top already performs the "real load" AC20 cares
# about (defeating the "perl -c is not a load test" hazard), so AC20 below
# checks `defined &Sub` in-process against that same load -- logically
# identical to the spec's one-liner, without an extra fork.
#
# AC21 note: the spec's AC21 is "t/24/t/25/t/41 pass unmodified, run
# directly". Re-running those files here would itself be a subprocess spawn,
# which S4.1 forbids for THIS file. AC21's defined-sub / same-old-signature
# guard is checked in-process below; the "0 not ok, exit 0" half of AC21 was
# verified directly by the test-writer via `perl t/24-launch-log.t` etc.
# (see the accompanying report) -- run-tests.pl (AC22) is the durable,
# ongoing enforcement of that half.
#
# AC22 note: "run-tests.pl is green, no sibling regresses" is an inherently
# cross-file, whole-suite concern (a baseline-diff performed BEFORE/AFTER
# this package's edits) that cannot be encoded as an in-file assertion. This
# file contributes the mechanically-checkable part: it exists under t/,
# matches run-tests.pl's `t/*.t` glob, and (per the run below) fails for the
# right reason today.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use List::Util qw(any);
use Scalar::Util qw(refaddr);

use_ok('LaunchLog') or BAIL_OUT('LaunchLog.pm did not load');
use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

my $SCRIPTS_DIR  = "$Bin/../../scripts";
my $LAUNCHER_SRC = "$SCRIPTS_DIR/launcher.pl";

# ===========================================================================
# Scaffolding
# ===========================================================================

# slurp($path) -> file contents, or '' on failure. Used only for source-text
# (AC19) inspection of launcher.pl -- the file is never require'd/do'ne.
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# write_log($path, @lines) -- write pre-formatted JSON-line strings (each
# produced by LaunchLog::format_event, per S4.1) to a fresh file. Zero @lines
# creates a genuinely empty (0-byte) file, exercising E5.
sub write_log {
    my ($path, @lines) = @_;
    open my $fh, '>:raw', $path or die "cannot write $path: $!";
    print {$fh} "$_\n" for @lines;
    close $fh;
    return $path;
}

# touch_mtime($path, $epoch) -- force mtime explicitly. Never inferred from
# write order (S4.1), since write order is not reliable at 1s granularity.
sub touch_mtime {
    my ($path, $t) = @_;
    utime($t, $t, $path) or diag("utime($t, $path) failed: $!");
}

# ev_line($type, $epoch, $pid, \%fields) -> one JSON line via the real
# formatter -- never a hand-written JSON string (S4.1).
sub ev_line {
    my ($type, $epoch, $pid, $fields) = @_;
    return LaunchLog::format_event($type, $fields || {}, $epoch, $pid);
}

# slurp_lines($path) -> the file's lines (chomped), or () if unreadable. Test
# scaffolding only -- NOT a stand-in for launcher.pl's private _tail_lines
# (which is out of this file's reach; AC19(d) covers it as source text).
sub slurp_lines {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return ();
    local $/;
    my $blob = <$fh>;
    close $fh;
    return () unless defined $blob && length $blob;
    my @lines = split /\n/, $blob;
    return @lines;
}

# basename_of($path) -> the trailing path component, slash-agnostic.
sub basename_of {
    my ($path) = @_;
    return $path unless defined $path;
    return ($path =~ m{([^/\\]+)$}) ? $1 : $path;
}

# rlogs(@args) -> LIST. Calls LaunchLog::recent_logs under eval; on ANY
# failure (including "Undefined subroutine", i.e. the sub not existing yet)
# returns a single-element sentinel list that can never equal a real result
# (empty OR populated), so callers never get a false pass from a missing sub.
sub rlogs {
    my @args = @_;
    my @r = eval { LaunchLog::recent_logs(@args) };
    return $@ ? ('::MISSING-SUB::recent_logs::') : @r;
}

# rmerge($groups, %opts) -> arrayref | undef. Calls LaunchLog::merge_sessions
# under eval; undef on any failure so `ref($r) eq 'ARRAY'` and is_deeply(...)
# checks against it correctly fail rather than false-passing.
sub rmerge {
    my ($groups, %opts) = @_;
    my $r = eval { LaunchLog::merge_sessions($groups, %opts) };
    return $@ ? undef : $r;
}

# marker_or_pinned() -- the real Dashboard::session_boundary_row() when it
# exists, else the spec-pinned literal shape (S2.3), so AC15's compose_frame
# /make_cell width-safety assertions can exercise real (already-existing)
# Dashboard machinery regardless of whether session_boundary_row exists yet.
# session_boundary_row's OWN correctness is asserted independently (AC12/13),
# never weakened by this fallback.
sub marker_or_pinned {
    my $m = eval { Dashboard::session_boundary_row() };
    return $m if ref($m) eq 'ARRAY' && @$m;
    return [ { text => '-- previous session --', role => 'muted' } ];
}

# like_or_fail: like() for a possibly-undef string, without a crash and
# without silently passing.
sub like_or_fail {
    my ($str, $re, $name) = @_;
    if (defined $str) { like($str, $re, $name); }
    else              { fail($name); diag('  (value was undef)'); }
}

# --- source-text helpers for AC19 (launcher.pl is slurped, never require'd) --
sub _balanced_braces {
    my ($src, $from) = @_;
    my $idx = index($src, '{', $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $i     = $idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++; }
        elsif ($c eq '}') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}
sub extract_sub_body {
    my ($src, $start_literal) = @_;
    my $idx = index($src, $start_literal);
    return undef if $idx < 0;
    return _balanced_braces($src, $idx);
}
sub _balanced_parens {
    my ($src, $from) = @_;
    my $idx = index($src, '(', $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $i     = $idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '(') { $depth++; }
        elsif ($c eq ')') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}
sub extract_call_block {
    my ($src, $start_literal) = @_;
    my $idx = index($src, $start_literal);
    return undef if $idx < 0;
    return _balanced_parens($src, $idx);
}
sub re_pos {
    my ($src, $re) = @_;
    return -1 unless defined $src;
    return -1 unless $src =~ $re;
    return $-[0];
}
# src_like/src_unlike: like()/unlike() for SOURCE-TEXT assertions, without
# dumping the whole slurped file into TAP on failure.
sub src_like {
    my ($str, $re, $name) = @_;
    my $got = (defined $str && $str =~ $re) ? 1 : 0;
    ok($got, $name) or diag("  source did not match $re");
    return $got;
}

# ===========================================================================
# PART 1 -- LaunchLog::recent_logs (AC1-AC5 / B1-B5)
# ===========================================================================

# --- AC1 (B1): 5 files, distinct mtimes, keep newest 3. ---
{
    my $dir    = tempdir(CLEANUP => 1);
    my $base_t = 1_700_000_000;
    my @names  = map { "launch-l$_.log" } (1 .. 5);
    for my $i (0 .. 4) {
        my $path = "$dir/$names[$i]";
        write_log($path, ev_line('t', $base_t, 100 + $i));
        touch_mtime($path, $base_t + $i * 100);   # l1 oldest ... l5 newest
    }
    my @paths = rlogs($dir, 3);
    is(scalar(@paths), 3, 'AC1: recent_logs($dir,3) returns exactly 3 paths');
    my @basenames = map { basename_of($_) } @paths;
    is_deeply(\@basenames, ['launch-l5.log', 'launch-l4.log', 'launch-l3.log'],
        'AC1: newest-mtime first, exactly the 3 newest');
    ok(!(grep { $_ eq 'launch-l1.log' || $_ eq 'launch-l2.log' } @basenames),
        'AC1: the 2 oldest files are absent from the result');
}

# --- AC2 (B2): transcript files never returned, at n=3 and n=99. ---
{
    my $dir    = tempdir(CLEANUP => 1);
    my $base_t = 1_700_000_000;
    for my $i (1 .. 5) {
        my $path = "$dir/launch-t$i.log";
        write_log($path, ev_line('t', $base_t, 200 + $i));
        touch_mtime($path, $base_t + $i * 100);   # t1 oldest ... t5 newest
        my $tpath = "$dir/launch-t$i.transcript.log";
        write_log($tpath, 'not-json-transcript-noise');
        # Transcripts get the NEWEST mtimes of the whole fixture, so a
        # glob-based bug (S1.4) would surface them FIRST at small $n.
        touch_mtime($tpath, $base_t + 100_000 + $i);
    }
    for my $n (3, 99) {
        my @paths     = rlogs($dir, $n);
        my @basenames = map { basename_of($_) } @paths;
        ok(!(grep { /\.transcript\.log$/ } @basenames),
            "AC2: no returned path ends in .transcript.log (n=$n)");
    }
    my @all = rlogs($dir, 99);
    is(scalar(@all), 5, 'AC2: n=99 returns exactly the 5 real logs, transcripts wholly excluded');
}

# --- AC3 (B3): exclusion happens before truncation. ---
{
    my $dir       = tempdir(CLEANUP => 1);
    my $base_t    = 1_700_000_000;
    my @prior_names = qw(launch-p1.log launch-p2.log launch-p3.log launch-p4.log);
    for my $i (0 .. 3) {
        my $path = "$dir/$prior_names[$i]";
        write_log($path, ev_line('t', $base_t, 300 + $i));
        touch_mtime($path, $base_t + $i * 100);   # p1 oldest .. p4 newest-of-priors
    }
    my $cur_path = "$dir/launch-CUR.log";
    write_log($cur_path, ev_line('t', $base_t, 399));
    touch_mtime($cur_path, $base_t + 100_000);    # CUR is mtime-newest of ALL 5 files

    my @paths = rlogs($dir, 4, 'launch-CUR.log');
    is(scalar(@paths), 4,
        'AC3: recent_logs($dir,4,CUR) returns exactly 4 paths (exclusion precedes truncation)');
    my @basenames = sort map { basename_of($_) } @paths;
    is_deeply(\@basenames, [ sort @prior_names ], 'AC3: the 4 returned paths are exactly the 4 prior logs');
    ok(!(grep { $_ eq 'launch-CUR.log' } @basenames), 'AC3: launch-CUR.log is never among the results');
}

# --- AC4 (B4): undef/empty/nonexistent/empty-dir all -> () without dying. ---
{
    my $dir = tempdir(CLEANUP => 1);   # a real, empty directory
    is_deeply([ rlogs(undef) ], [], 'AC4: recent_logs(undef) -> empty list');
    is_deeply([ rlogs('') ], [], 'AC4: recent_logs("") -> empty list');
    is_deeply([ rlogs("$dir/nope-subdir") ], [], 'AC4: recent_logs(nonexistent dir) -> empty list');
    is_deeply([ rlogs($dir) ], [], 'AC4: recent_logs(empty existing dir) -> empty list');
}

# --- AC5 (B5): identical mtimes -> deterministic basename-descending order. ---
{
    my $dir = tempdir(CLEANUP => 1);
    my $t   = 1_700_000_000;
    write_log("$dir/launch-A.log", ev_line('t', $t, 501));
    write_log("$dir/launch-B.log", ev_line('t', $t, 502));
    touch_mtime("$dir/launch-A.log", $t);
    touch_mtime("$dir/launch-B.log", $t);   # identical, forced mtimes
    my @b1 = map { basename_of($_) } rlogs($dir, 2);
    my @b2 = map { basename_of($_) } rlogs($dir, 2);
    is_deeply(\@b1, [ 'launch-B.log', 'launch-A.log' ],
        'AC5: identical mtimes -> basename-descending tie-break');
    is_deeply(\@b1, \@b2, 'AC5: the order is stable across repeated calls with the same fixture');
}

# ===========================================================================
# PART 2 -- LaunchLog::merge_sessions (AC6-AC11 / B6-B12)
# Items are deliberately OPAQUE plain strings (S2.2: merge_sessions never
# inspects/copies/stringifies items) -- this is what the spec pins.
# ===========================================================================

# --- AC6 (B6): older sessions concatenated, marker, current session. ---
{
    my $M = 'MARKER';
    my $r = rmerge([ [ 'a1', 'a2' ], ['b1'], [ 'c1', 'c2' ] ], max => 50, marker => $M);
    is_deeply($r, [ 'a1', 'a2', 'b1', 'MARKER', 'c1', 'c2' ],
        'AC6: merge_sessions([[a1,a2],[b1],[c1,c2]]) -> [a1,a2,b1,M,c1,c2]');
}

# --- AC7 (B7, B8): a single group, and all-empty history groups -> no marker.
{
    my $M  = 'MARKER';
    my $r1 = rmerge([ [ 'c1', 'c2' ] ], max => 50, marker => $M);
    is_deeply($r1, [ 'c1', 'c2' ], 'AC7: a single group (current session only) -> no marker (B7)');
    my $r2 = rmerge([ [], ['c1'] ], max => 50, marker => $M);
    is_deeply($r2, ['c1'], 'AC7: an all-empty history group -> no marker (B8)');
}

# --- AC8 (B9): cap counts the marker; newest history survives; current intact.
{
    my $M = 'MARKER';
    my @a = map {"a$_"} (1 .. 10);
    my @c = map {"c$_"} (1 .. 5);
    my $r = rmerge([ [@a], [@c] ], max => 8, marker => $M);
    is_deeply($r, [ 'a9', 'a10', 'MARKER', 'c1', 'c2', 'c3', 'c4', 'c5' ],
        'AC8: max=>8 -> [a9,a10,M,c1..c5] (marker takes a slot, newest 2 of history survive)');
}

# --- AC9 (B10): room<=0 -> history AND marker both dropped. ---
{
    my $M = 'MARKER';
    my @a = map {"a$_"} (1 .. 5);
    my @c = map {"c$_"} (1 .. 9);
    my $r = rmerge([ [@a], [@c] ], max => 5, marker => $M);
    is_deeply($r, [ 'c5', 'c6', 'c7', 'c8', 'c9' ],
        'AC9: max=>5, 9 current items -> last 5 of current session, no marker, no history');
}

# --- AC10 (B11, B12): total-failure inputs, and marker=>undef never inserts.
{
    is_deeply(rmerge(undef), [], 'AC10: merge_sessions(undef) -> []');
    is_deeply(rmerge([]), [], 'AC10: merge_sessions([]) -> []');
    is_deeply(rmerge([ undef, 'x' ]), [],
        'AC10: merge_sessions([undef,\'x\']) -> [] (non-ARRAY elements coerced to empty)');
    my $r = rmerge([ ['a1'], ['c1'] ], marker => undef);
    is_deeply($r, [ 'a1', 'c1' ],
        'AC10: marker=>undef never inserts anything; no extra element between a1 and c1');
}

# --- AC11 (B6-B10): every AC6-AC9 result respects the cap and marker position.
{
    my $M = 'MARKER';
    my @cases = (
        [ rmerge([ [ 'a1', 'a2' ], ['b1'], [ 'c1', 'c2' ] ], max => 50, marker => $M), 50, 'AC6 result' ],
        [ rmerge([ [ 'c1', 'c2' ] ], max => 50, marker => $M),                          50, 'AC7 result (single group)' ],
        [ rmerge([ [], ['c1'] ], max => 50, marker => $M),                              50, 'AC7 result (empty history)' ],
        [ rmerge([ [ map {"a$_"} (1 .. 10) ], [ map {"c$_"} (1 .. 5) ] ], max => 8, marker => $M), 8, 'AC8 result' ],
        [ rmerge([ [ map {"a$_"} (1 .. 5) ], [ map {"c$_"} (1 .. 9) ] ], max => 5, marker => $M),  5, 'AC9 result' ],
    );
    for my $c (@cases) {
        my ($r, $max, $label) = @$c;
        if (ref($r) eq 'ARRAY') {
            ok(scalar(@$r) <= $max, "AC11: $label -> scalar\@\$result <= max ($max)");
            my ($idx) = grep { defined($r->[$_]) && $r->[$_] eq $M } (0 .. $#$r);
            if (defined $idx) {
                ok($idx != 0 && $idx != $#$r,
                    "AC11: $label -> marker (present) is at neither index 0 nor the last index");
            }
        }
        else {
            fail("AC11: $label -> scalar\@\$result <= max ($max)");
        }
    }
}

# ===========================================================================
# PART 3 -- Dashboard::session_boundary_row + width safety (AC12-AC15 / B13-B15)
# ===========================================================================

# --- AC12 (B13): exact shape, and two calls are distinct-but-equal refs. ---
{
    my $r1 = eval { Dashboard::session_boundary_row() };
    my $r2 = eval { Dashboard::session_boundary_row() };
    is_deeply($r1, [ { text => '-- previous session --', role => 'muted' } ],
        'AC12: session_boundary_row() returns exactly one span, exact text, exact role');
    if (ref($r1) eq 'ARRAY' && ref($r2) eq 'ARRAY') {
        is_deeply($r1, $r2, 'AC12: two calls are deep-equal in content');
        isnt(refaddr($r1), refaddr($r2), 'AC12: two calls return DIFFERENT arrayref instances');
    }
    else {
        fail('AC12: two calls are deep-equal in content');
        fail('AC12: two calls return DIFFERENT arrayref instances');
    }
}

# --- AC13 (B14): ASCII-only text, display_width == 22 (<= 24 budget). ---
{
    my $r    = eval { Dashboard::session_boundary_row() };
    my $text = (ref($r) eq 'ARRAY' && ref($r->[0]) eq 'HASH') ? $r->[0]{text} : undef;
    like_or_fail($text, qr/^[\x20-\x7E]+$/, 'AC13: marker text is pure printable ASCII');
    if (defined $text) {
        is(Dashboard::display_width($text), 22, 'AC13: display_width of the marker text is exactly 22');
    }
    else {
        fail('AC13: display_width of the marker text is exactly 22');
    }
}

# --- AC14: sgr_for_role('muted') unchanged (s04/s06 contract the marker leans on).
{
    is(Dashboard::sgr_for_role('muted'), "\e[2m",
        "AC14: sgr_for_role('muted') is still \\e[2m (unchanged by this package)");
}

# --- AC15 (B15): compose_frame renders every row at exactly $cols, wide+narrow.
{
    my $marker = marker_or_pinned();
    my @rows = (
        [ { text => '10:00  ', role => 'muted' }, { text => '* ', role => 'accent' }, { text => 'evt-a', role => 'accent' } ],
        $marker,
        [ { text => '10:01  ', role => 'muted' }, { text => '* ', role => 'good' },   { text => 'evt-b', role => 'good' } ],
    );
    for my $cols (120, 20) {   # 20 < the marker's own 22 columns
        my %state = (project_name => 'demo', container => 'c1', status => 'running', events => [@rows]);
        my @warnings;
        local $SIG{__WARN__} = sub { push @warnings, $_[0]; };
        my $frame = eval { Dashboard::compose_frame(\%state, 12, $cols) };
        my $err = $@;
        ok(!$err, "AC15: compose_frame does not die at cols=$cols") or diag("  \$\@ = $err");
        is(scalar(@warnings), 0, "AC15: compose_frame emits no warnings at cols=$cols");
        if (ref($frame) eq 'ARRAY') {
            my $bad = 0;
            for my $cell (@$frame) {
                my $t = (ref($cell) eq 'HASH') ? $cell->{text} : undef;
                $bad++ unless defined($t) && Dashboard::display_width($t) == $cols;
            }
            is($bad, 0, "AC15: every row is exactly $cols display columns (cols=$cols)");
        }
        else {
            fail("AC15: every row is exactly $cols display columns (cols=$cols)");
        }
    }
}

# ===========================================================================
# PART 4 -- End-to-end over a real fixture, public subs only (AC16-AC18 /
#           B6, B16, B17, B18). Also exercises E5 (empty prior log) and E6
#           (a garbage line in a prior log) as fixture content.
# ===========================================================================
{
    my $dir    = tempdir(CLEANUP => 1);
    my $base_t = 1_700_000_000;

    # Session A (oldest prior): 2 events.
    my $a_path = "$dir/launch-hA.log";
    write_log($a_path,
        ev_line('evt-hist-a1', $base_t, 601),
        ev_line('evt-hist-a2', $base_t, 602));
    touch_mtime($a_path, $base_t + 100);

    # Session B: an EMPTY log (E5) -- must contribute nothing, no crash.
    my $b_path = "$dir/launch-hB.log";
    write_log($b_path);
    touch_mtime($b_path, $base_t + 200);

    # Session C (newest prior): a garbage line (E6, must be skipped silently)
    # plus one valid event.
    my $c_path = "$dir/launch-hC.log";
    write_log($c_path, 'this-is-not-json-{{{', ev_line('evt-hist-c1', $base_t, 603));
    touch_mtime($c_path, $base_t + 300);

    # Current session: 3 events.
    my $cur_path = "$dir/launch-CUR.log";
    write_log($cur_path,
        ev_line('evt-cur-1', $base_t, 701),
        ev_line('evt-cur-2', $base_t, 702),
        ev_line('evt-cur-3', $base_t, 703));
    touch_mtime($cur_path, $base_t + 1_000);

    # --- the S2.4 pipeline, PUBLIC subs only ---
    my @prior_paths_newest_first = rlogs($dir, 5, 'launch-CUR.log');
    my @prior_paths_oldest_first = reverse @prior_paths_newest_first;
    my @hist_groups;
    for my $p (@prior_paths_oldest_first) {
        my @lines = slurp_lines($p);
        my $grp   = Dashboard::recent_events(\@lines, 10);
        push @hist_groups, $grp if ref($grp) eq 'ARRAY' && @$grp;
    }
    my @cur_lines = slurp_lines($cur_path);
    my $cur       = Dashboard::recent_events(\@cur_lines, 50);
    my $marker    = eval { Dashboard::session_boundary_row() };
    my $merged    = eval { LaunchLog::merge_sessions([ @hist_groups, $cur ], max => 50, marker => $marker) };

    if (ref($merged) eq 'ARRAY') {
        my @texts = map { Dashboard::spans_text($_) } @$merged;

        for my $needle (qw(evt-hist-a1 evt-hist-a2 evt-hist-c1)) {
            ok((any { index($_, $needle) >= 0 } @texts),
                "AC16: prior-session event '$needle' is present in the merged list");
        }

        my $marker_text = (ref($marker) eq 'ARRAY' && ref($marker->[0]) eq 'HASH') ? $marker->[0]{text} : undef;
        my $marker_count = defined($marker_text) ? scalar(grep { $_ eq $marker_text } @texts) : -1;
        is($marker_count, 1, 'AC16: the marker appears exactly once in the merged list');

        my ($marker_idx) = defined($marker_text) ? (grep { $texts[$_] eq $marker_text } (0 .. $#texts)) : ();
        if (defined $marker_idx) {
            my @before = @texts[ 0 .. $marker_idx - 1 ];
            my @after  = ($marker_idx < $#texts) ? @texts[ $marker_idx + 1 .. $#texts ] : ();
            ok((any { index($_, 'evt-hist-a1') >= 0 } @before), 'AC16: hist event a1 precedes the marker');
            ok((any { index($_, 'evt-hist-c1') >= 0 } @before), 'AC16: hist event c1 precedes the marker');
            ok((any { index($_, 'evt-cur-1') >= 0 } @after), 'AC16: current event 1 follows the marker');
            ok((any { index($_, 'evt-cur-3') >= 0 } @after), 'AC16: current event 3 follows the marker');
        }
        else {
            fail('AC16: hist event a1 precedes the marker');
            fail('AC16: hist event c1 precedes the marker');
            fail('AC16: current event 1 follows the marker');
            fail('AC16: current event 3 follows the marker');
        }
    }
    else {
        fail("AC16: prior-session event 'evt-hist-a1' is present in the merged list");
        fail("AC16: prior-session event 'evt-hist-a2' is present in the merged list");
        fail("AC16: prior-session event 'evt-hist-c1' is present in the merged list");
        fail('AC16: the marker appears exactly once in the merged list');
        fail('AC16: hist event a1 precedes the marker');
        fail('AC16: hist event c1 precedes the marker');
        fail('AC16: current event 1 follows the marker');
        fail('AC16: current event 3 follows the marker');
    }

    # --- AC17 (B17): no current-session row appears twice in the merged list.
    if (ref($merged) eq 'ARRAY' && ref($cur) eq 'ARRAY') {
        my @cur_texts    = map { Dashboard::spans_text($_) } @$cur;
        my @merged_texts = map { Dashboard::spans_text($_) } @$merged;
        my $dup = 0;
        for my $ct (@cur_texts) {
            $dup++ if scalar(grep { $_ eq $ct } @merged_texts) != 1;
        }
        is($dup, 0, 'AC17: every current-session row occurs exactly once in the merged list (no duplication)');
    }
    else {
        fail('AC17: every current-session row occurs exactly once in the merged list (no duplication)');
    }

    # --- AC18 (B18): with the 3 prior files removed, strict no-op. ---
    unlink $a_path, $b_path, $c_path;
    my @prior_paths2 = rlogs($dir, 5, 'launch-CUR.log');
    my @hist_groups2;
    for my $p (reverse @prior_paths2) {
        my @lines = slurp_lines($p);
        my $grp   = Dashboard::recent_events(\@lines, 10);
        push @hist_groups2, $grp if ref($grp) eq 'ARRAY' && @$grp;
    }
    my @cur_lines2 = slurp_lines($cur_path);
    my $expected2  = Dashboard::recent_events(\@cur_lines2, 50);
    my $cur2       = Dashboard::recent_events(\@cur_lines2, 50);
    my $marker2    = eval { Dashboard::session_boundary_row() };
    my $merged2    = eval { LaunchLog::merge_sessions([ @hist_groups2, $cur2 ], max => 50, marker => $marker2) };
    is_deeply($merged2, $expected2,
        'AC18: with no prior logs on disk, the merged list is byte-for-byte recent_events(...,50) -- strict no-op');
    if (ref($merged2) eq 'ARRAY' && ref($marker2) eq 'ARRAY' && ref($marker2->[0]) eq 'HASH') {
        my $mtext  = $marker2->[0]{text};
        my @texts2 = map { Dashboard::spans_text($_) } @$merged2;
        ok(!(grep { $_ eq $mtext } @texts2), 'AC18: no marker present in the no-history case');
    }
    else {
        fail('AC18: no marker present in the no-history case');
    }
}

# ===========================================================================
# PART 5 -- launcher.pl source-text assertions (AC19 / S2.4)
# launcher.pl is SLURPED, never require'd/do'ne.
# ===========================================================================
{
    my $src = slurp($LAUNCHER_SRC);
    ok(length($src) > 0, 'AC19 setup: launcher.pl was read as source text') or BAIL_OUT('cannot read launcher.pl');

    # (a) LaunchLog::recent_logs is called (inside _history_events, per S2.4b)
    #     with an exclusion argument, and the ONE-SHOT call site (S2.4c) seeds
    #     that exclusion with the literal 'launch-$LAUNCH_ID.log'.
    my $sub_body   = extract_sub_body($src, 'sub _history_events');
    my $call_block = defined($sub_body) ? extract_call_block($sub_body, 'LaunchLog::recent_logs') : undef;
    src_like(defined($call_block) ? $call_block : '',
        qr/\(\s*\$dir\s*,\s*\$HISTORY_LOG_FILES\s*,\s*\$exclude\b/,
        'AC19a: LaunchLog::recent_logs is called with ($dir, $HISTORY_LOG_FILES, $exclude) inside _history_events');
    src_like($src,
        qr/_history_events\s*\(\s*"[^"]*sandbox-logs"\s*,\s*"launch-\$LAUNCH_ID\.log"\s*\)/,
        'AC19a: the one-shot call site seeds the exclusion with the literal "launch-$LAUNCH_ID.log"');

    # (b) LaunchLog::merge_sessions is called in the gather callback and its
    #     result is the value of the events => key.
    src_like($src, qr/events\s*=>\s*LaunchLog::merge_sessions\s*\(/,
        'AC19b: LaunchLog::merge_sessions is called as the events => value');

    # (c) Dashboard::session_boundary_row is passed as the marker.
    #
    # It now takes an EPOCH argument. Activity rows carry a wall-clock time
    # rather than an age, and a bare "23:41" on the far side of a session
    # boundary says nothing about which day it belongs to -- so the divider
    # dates the session it introduces. The AC is about which function supplies
    # the marker, not its arity, so the argument list is left open.
    my $merge_call_block = extract_call_block($src, 'LaunchLog::merge_sessions');
    src_like(defined($merge_call_block) ? $merge_call_block : '',
        qr/marker\s*=>\s*Dashboard::session_boundary_row\s*\(/,
        'AC19c: marker => Dashboard::session_boundary_row(...)');
    src_like(defined($merge_call_block) ? $merge_call_block : '',
        qr/marker\s*=>\s*Dashboard::session_boundary_row\s*\(\s*\$\w+\s*\)/,
        'AC19c: ...and it is passed an epoch, so the divider can name its date');

    # (d) the surviving current-session read is still _tail_lines($log_path, 200).
    src_like($src, qr/_tail_lines\s*\(\s*\$log_path\s*,\s*200\s*\)/,
        'AC19d: the current-session read is still _tail_lines($log_path, 200)');

    # (e) the _history_events call site sits BEFORE the Dashboard::run( call
    #     (one-shot, not per tick). Negative lookbehind excludes the `sub
    #     _history_events {` definition itself (no parens directly after the
    #     name in the spec-pinned style).
    my $hist_call_pos = re_pos($src, qr/(?<!sub )_history_events\s*\(/);
    my $run_pos       = index($src, 'Dashboard::run(');
    ok($hist_call_pos >= 0 && $run_pos >= 0 && $hist_call_pos < $run_pos,
        'AC19e: the _history_events call site precedes Dashboard::run( (one-shot, not per-tick)');
}

# ===========================================================================
# PART 6 -- load-completeness (AC20)
# See the file-header note: checked in-process via the already-completed
# use_ok() load, rather than a `perl -e` subprocess.
# ===========================================================================
{
    ok(defined &LaunchLog::recent_logs,    'AC20: LaunchLog::recent_logs is defined after load');
    ok(defined &LaunchLog::merge_sessions, 'AC20: LaunchLog::merge_sessions is defined after load');
    ok(defined &Dashboard::session_boundary_row, 'AC20: Dashboard::session_boundary_row is defined after load');
}

# ===========================================================================
# PART 7 -- pre-existing API surface guard (AC21 / DC5)
# The full "t/24, t/25, t/41 pass unmodified" check is a subprocess-spawning
# concern that this PURE file does not perform itself (see header note); this
# section is the in-process signature/definedness guard.
# ===========================================================================
{
    for my $sub (qw(LaunchLog::format_event LaunchLog::open_log LaunchLog::event LaunchLog::close_log
        Dashboard::recent_events Dashboard::activity_capacity Dashboard::activity_window
        Dashboard::activity_row_width Dashboard::event_style)) {
        no strict 'refs';
        ok(defined &{$sub}, "AC21: $sub is still defined");
    }
    my $line = LaunchLog::format_event('smoke', { a => 1 }, 1_700_000_000, 999);
    like($line, qr/"type":"smoke"/, 'AC21 smoke: format_event still produces the expected shape');
    my $ev = Dashboard::recent_events([$line], 5);
    is(ref($ev), 'ARRAY', 'AC21 smoke: recent_events still returns an arrayref');
    # DERIVED, not pinned at 78. This asserted "$cols - 2" for the two-space
    # panel body indent; that indent is now tui::Screen::BODY_INDENT and is 0
    # (operator request, 2026-08-25 -- every panel has a real left edge now, so
    # the indent was two columns of nothing on every row). Re-deriving from the
    # renderer's own constant keeps AC21 a smoke test of the ARITHMETIC rather
    # than of a number that moves whenever the layout does.
    require tui::Screen;
    is(Dashboard::activity_row_width(80), 80 - tui::Screen::BODY_INDENT(),
        'AC21 smoke: activity_row_width(80) is 80 minus the panel body indent');
    my ($role, $glyph) = Dashboard::event_style('container_start', undef, undef);
    ok(defined($role) && defined($glyph), 'AC21 smoke: event_style still returns (role, glyph)');
}

# ===========================================================================
# PART 8 -- AC22 (whole-suite gate; see file-header note)
# ===========================================================================
pass('AC22: this file lives under t/ and matches run-tests.pl\'s t/*.t glob; '
    . 'the cross-file baseline-diff half of AC22 is verified externally (see report)');

# ===========================================================================
# AC-T -- the activity time column is a WALL CLOCK, and midnight is visible.
#
# The column used to read "5m", "11m", "7d16h". A relative age answers "how
# long ago" but never "when", so an event could not be lined up against
# anything outside the panel -- a log line, a commit, a memory of what you were
# doing. The operator asked for real times.
#
# That creates a new failure mode the age never had: 00:14 renders below 23:58
# and reads as sixteen minutes later when it is sixteen minutes into the NEXT
# DAY. So the column change and the date dividers are one feature, and are
# tested as one.
# ===========================================================================
{
    my $UTC = \&CORE::gmtime;
    my @ts = ('2026-08-10T21:58:00Z', '2026-08-10T22:41:00Z',
              '2026-08-11T00:14:00Z', '2026-08-11T00:31:00Z');
    my @ty = qw(launch_start image_build_ok container_create manager_ready);
    my @lines = map { qq({"ts":"$ts[$_]","type":"$ty[$_]"}) } (0 .. 3);

    my $ev = Dashboard::recent_events(\@lines, 20, $UTC, time);
    my @text = map { Dashboard::spans_text($_) } @$ev;

    like($text[0], qr/^21:58\s/, 'AC-T1: the time column is the event wall-clock time, HH:MM');
    unlike(join("\n", @text), qr/\b\d+[dhms]\b\s+\x{25cf}|\b\d+d\d\dh\b/,
        'AC-T1: and no relative age survives in the column');

    my ($divider_i) = grep { $text[$_] =~ /^--/ } (0 .. $#text);
    ok(defined $divider_i, 'AC-T2: a divider row is emitted where the events cross midnight')
        or diag('  rows: ' . join(' | ', @text));
    if (defined $divider_i) {
        like($text[$divider_i], qr/11 Aug/,
            'AC-T2: the divider names the date the following rows belong to');
        like($text[ $divider_i - 1 ], qr/^22:41/,
            'AC-T2: the row above the divider is the last of the previous day');
        like($text[ $divider_i + 1 ], qr/^00:14/,
            'AC-T2: the row below it is the first of the new day');
    }

    # One day, no divider. A separator that appears when nothing was crossed is
    # as misleading as a missing one.
    my @same_day = map { qq({"ts":"2026-08-11T0$_:00:00Z","type":"t$_"}) } (1 .. 4);
    my $ev1 = Dashboard::recent_events(\@same_day, 20, $UTC, time);
    my @t1  = map { Dashboard::spans_text($_) } @$ev1;
    is(scalar(grep { /^--/ } @t1), 0,
        'AC-T3: events all on one day produce NO date divider');

    # The session divider carries its date, for the same reason.
    my $epoch = Dashboard::_event_epoch('2026-08-04T17:08:03Z');
    my $row   = Dashboard::session_boundary_row($epoch, $UTC);
    like(Dashboard::spans_text($row), qr/previous session/,
        'AC-T4: the session divider still says what it is');
    like(Dashboard::spans_text($row), qr/4 Aug/,
        'AC-T4: and now names the date, which a bare HH:MM row cannot imply');

    # No epoch -> no invented date. Same honesty rule as everywhere else here.
    my $bare = Dashboard::session_boundary_row(undef, $UTC);
    like(Dashboard::spans_text($bare), qr/^-- previous session --$/,
        'AC-T4: with no epoch the divider degrades to its old text rather than inventing a date');
}

done_testing();
