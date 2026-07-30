#!/usr/bin/env perl
# s12-lifecycle-relaunch-recovery: the [l] relaunch/recover control + the
# shared recovery seam.
#
# This file is the ORACLE for blueprint sandbox-butler-overhaul, package
# s12-lifecycle-relaunch-recovery (specs/09-lifecycle-relaunch-spec.md). It is
# written BLIND to any Dashboard.pm / launcher.pl implementation -- directly
# from the spec -- so it can serve as an oracle rather than an echo of whatever
# the implementer eventually writes. Do NOT weaken an assertion to make a
# future implementation's life easier.
#
# Coverage: AC-1..AC-29 (spec S4).
#   * AC-30 is DELIBERATELY ABSENT. It is conditional on the R2 write-set
#     expansion for t/46-lifecycle-stop.t, which has NOT been granted
#     (spec S8: "If the expansion is NOT granted ... t/47 must then contain no
#     assertion about footer_legend"). This file therefore makes NO assertion
#     whatsoever about footer_legend's tier strings or its key list.
#   * AC-29 (whole-suite-green gate) is largely a coordinator-side check, as
#     t/46's AC-22 and t/45's AC-27 were. What IS encoded here is the
#     mechanically checkable part: this file is discovered by run-tests.pl,
#     and t/46 is still present as a declared immutable oracle.
#
# Hard constraints honoured here:
#   * NO real podman: every machine/container interaction goes through an
#     injected seam fake (build_seams(), below). No system/qx/backtick/exec
#     against podman anywhere in this file.
#   * NO real sleeping, NO network, NO subprocesses: every clock is a fake
#     incrementing counter (build_seams()'s now/sleep_for, drive3()'s $clock).
#   * launcher.pl is NEVER require'd/do'ne -- AC-27/AC-28 are source-text
#     slurp + regex only (t/36's stated convention, followed by t/43/t/44/
#     t/45/t/46, and spec S6/E2: launcher.pl is not loadable by a test).
#   * Every call into a not-yet-written sub (recover_plan,
#     classify_container_state, run_recover_stages, _recover_stage_catalog,
#     and the CHANGED dispatch_key/confirm_prompt/_status_alert/
#     launch_blocked_msg behaviours) is wrapped in eval, so a missing sub
#     degrades to a clean per-assertion FAIL rather than a fatal abort.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;

use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

my $TESTS_DIR     = "$Bin/..";
my $SCRIPTS_DIR   = "$Bin/../../scripts";
my $DASHBOARD_SRC = "$SCRIPTS_DIR/Dashboard.pm";
my $LAUNCHER_SRC  = "$SCRIPTS_DIR/launcher.pl";

# ===========================================================================
# Scaffolding
# ===========================================================================

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# --- source-text helpers (Dashboard.pm / launcher.pl are never require'd for
#     these particular assertions; both are read as plain text). -----------
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

# re_pos($src,$re) -> byte offset of the first match, or -1.
sub re_pos {
    my ($src, $re) = @_;
    return -1 unless defined $src;
    return -1 unless $src =~ $re;
    return $-[0];
}

# block_after($src,$re) -> the balanced { ... } block that follows the first
# match of $re. Used to pull `<seam_name> => sub { ... }` out of a hash literal.
sub block_after {
    my ($src, $re) = @_;
    my $i = re_pos($src, $re);
    return undef if $i < 0;
    return _balanced_braces($src, $i);
}

# podman_invocations($body) -> \@chunks, one per `$PODMAN` occurrence, each
# chunk running up to the NEXT `$PODMAN` occurrence. Adjacency in this array is
# exactly "no other podman call in between" (AC-28c).
sub podman_invocations {
    my ($body) = @_;
    return [] unless defined $body;
    my @pos;
    my $p = 0;
    while ((my $i = index($body, '$PODMAN', $p)) >= 0) { push @pos, $i; $p = $i + 7; }
    my @inv;
    for my $k (0 .. $#pos) {
        my $end = ($k < $#pos) ? $pos[$k + 1] : length($body);
        push @inv, substr($body, $pos[$k], $end - $pos[$k]);
    }
    return \@inv;
}

# --- the pinned recover stage catalog (spec 2.4). Nothing else in the
#     implementation may hardcode these; this test file pins them so the
#     catalog itself is an oracle. --------------------------------------
my @CATALOG = (
    { id => 'machine-status',     label => 'check podman machine' },
    { id => 'machine-start',      label => 'start podman machine' },
    { id => 'container-start',    label => 'start container' },
    { id => 'heartbeat-reattach', label => 're-attach heartbeat' },
);
sub pinned_plan {
    my ($capable) = @_;
    return [ map { { %$_ } } ($capable ? @CATALOG : @CATALOG[2, 3]) ];
}

# plan_for(\%state): use the real recover_plan when it exists, otherwise fall
# back to the SPEC-PINNED plan so that the run_recover_stages assertions below
# still exercise the driver instead of collapsing into recover_plan's absence.
# recover_plan's own correctness is asserted independently by AC-9.
sub plan_for {
    my ($state) = @_;
    my $p = eval { Dashboard::recover_plan($state) };
    return $p if ref($p) eq 'ARRAY' && @$p;
    return pinned_plan(ref($state) eq 'HASH' ? $state->{machine_capable} : 0);
}

# --- seam harness for Dashboard::run_recover_stages ------------------------
# build_seams(%over) -> (\%seams, \@calls, \@progress, \@logs)
#
# @calls records seam invocation ORDER as bare tags ('machine_status',
# 'machine_start', 'container_start', 'container_create',
# 'heartbeat_reattach') -- pushed by the wrapper BEFORE delegating, so a dying
# override still leaves a call record (spec 2.6's per-stage sequencing: the
# seam call happens before its outcome is known). That ordered array is how
# the ORDER criteria (AC-11, AC-13, AC-14) are asserted.
#
# container_create is NOT wired by default -- that is production (R1, spec
# 2.8: "NOT WIRED ... Absent from the production seam hash"). Tests that want
# R1 branch A pass one explicitly.
#
# now/sleep_for are a FAKE incrementing clock, never real wall-clock time.
# The spec does not give run_recover_stages a clock seam; they are supplied
# defensively so that an implementation which does wait cannot make this file
# sleep for real.
#
# ABSENT is a sentinel: build_seams(container_start => ABSENT) omits that key
# from %seams entirely (simulating the seam not being supplied at all).
use constant ABSENT => 'ABSENT-SEAM-MARKER';

sub build_seams {
    my (%over) = @_;
    my @calls;
    my @progress;
    my @logs;
    my %default_impl = (
        machine_status     => sub { { ok => 1, state => 'running', detail => 'machine running' } },
        machine_start      => sub { { ok => 1, detail => 'machine started' } },
        container_start    => sub { { ok => 1, detail => 'container started' } },
        heartbeat_reattach => sub { { ok => 1, detail => 'heartbeat ok' } },
    );
    my %seams;
    for my $tag (qw(machine_status machine_start container_start container_create heartbeat_reattach)) {
        my $impl;
        if (exists $over{$tag}) {
            next if !ref($over{$tag}) && $over{$tag} eq ABSENT;
            $impl = $over{$tag};
        }
        else {
            next unless exists $default_impl{$tag};   # container_create: absent by default
            $impl = $default_impl{$tag};
        }
        $seams{$tag} = sub { push @calls, $tag; return $impl->(@_); };
    }
    my $t = 1000;   # fake clock -- NEVER real time
    $seams{now}       = $over{now}       // sub { $t };
    $seams{sleep_for} = $over{sleep_for} // sub { $t += $_[0]; };
    $seams{status_cb} = exists $over{status_cb} ? $over{status_cb} : sub { push @progress, $_[0]; };
    $seams{log_cb}    = exists $over{log_cb}    ? $over{log_cb}    : sub { push @logs, [ $_[0], $_[1] ]; };
    return (\%seams, \@calls, \@progress, \@logs);
}

# run_recover_stages does NOT EXIST YET. rr()/rre() wrap every call in eval so
# a missing sub degrades to a clean per-assertion FAIL rather than a fatal
# "Undefined subroutine" aborting the whole file.
sub rr  { my (%o) = @_; my $r = eval { Dashboard::run_recover_stages(%o) }; return ref($r) eq 'HASH' ? $r : undef; }
sub rre { my (%o) = @_; my $r = eval { Dashboard::run_recover_stages(%o) }; my $e = $@; return ($r, $e); }

# field($h,$k) -> $h->{$k} if $h is a hashref, else undef. The companion
# accessor to rr(): it lets assertions dereference a possibly-undef result
# WITHOUT a second-order crash.
sub field { my ($h, $k) = @_; return (ref($h) eq 'HASH') ? $h->{$k} : undef; }

sub stage_of {
    my ($result, $id) = @_;
    return undef unless ref($result) eq 'HASH' && ref($result->{stages}) eq 'ARRAY';
    my ($s) = grep { ref($_) eq 'HASH' && defined $_->{id} && $_->{id} eq $id } @{ $result->{stages} };
    return $s;
}
sub stage_count { my ($r) = @_; return (ref(field($r, 'stages')) eq 'ARRAY') ? scalar(@{ $r->{stages} }) : -1; }

# like_or_fail: assert $re against a possibly-undef string without a crash and
# without silently passing.
sub like_or_fail {
    my ($str, $re, $name) = @_;
    if (defined $str) { like($str, $re, $name); }
    else              { fail($name); diag('  (value was undef)'); }
}
sub unlike_or_fail {
    my ($str, $re, $name) = @_;
    if (defined $str) { unlike($str, $re, $name); }
    else              { fail($name); diag('  (value was undef)'); }
}

# src_like/src_unlike: like()/unlike() for SOURCE-TEXT assertions. Identical
# strictness, but a failure does not dump the whole slurped file into the TAP
# stream (a failing like() against launcher.pl is ~300 KB of diag).
sub src_like {
    my ($str, $re, $name) = @_;
    my $got = (defined $str && $str =~ $re) ? 1 : 0;
    ok($got, $name) or diag("  source did not match $re");
    return $got;
}
sub src_unlike {
    my ($str, $re, $name) = @_;
    my $got = (defined $str && $str =~ $re) ? 1 : 0;
    ok(!$got, $name) or diag("  source unexpectedly matched $re");
    return !$got;
}

# ===========================================================================
# PART 1 -- dispatch_key: the [l] binding (AC-1..AC-4 / B1-B4)
# ===========================================================================

# --- AC-1 (B1): l/L arm the relaunch confirm; every pre-existing pin holds. ---
{
    is_deeply([ eval { Dashboard::dispatch_key('l', '') } ], ['confirm-relaunch', 'relaunch'],
        'AC-1: l -> confirm-relaunch/relaunch');
    is_deeply([ eval { Dashboard::dispatch_key('L', '') } ], ['confirm-relaunch', 'relaunch'],
        'AC-1: L -> confirm-relaunch/relaunch');

    # Every pre-existing pin from t/46:189-250 / t/25:459-491, byte-for-byte.
    is_deeply([Dashboard::dispatch_key('s', '')], ['confirm-stop-runs', 'stop-runs'],
        'AC-1: s -> confirm-stop-runs/stop-runs (unchanged)');
    is_deeply([Dashboard::dispatch_key('S', '')], ['confirm-stop-runs', 'stop-runs'],
        'AC-1: S -> confirm-stop-runs/stop-runs (unchanged)');
    is_deeply([Dashboard::dispatch_key('x', '')], ['confirm-full-shutdown', 'full-shutdown'],
        'AC-1: x -> confirm-full-shutdown/full-shutdown (unchanged)');
    is_deeply([Dashboard::dispatch_key('X', '')], ['confirm-full-shutdown', 'full-shutdown'],
        'AC-1: X -> confirm-full-shutdown/full-shutdown (unchanged)');
    is_deeply([Dashboard::dispatch_key('c', '')], ['launch', ''], 'AC-1: c -> launch (unchanged)');
    is_deeply([Dashboard::dispatch_key('C', '')], ['launch', ''], 'AC-1: C -> launch (unchanged)');
    is_deeply([Dashboard::dispatch_key("\r", '')], ['launch', ''], 'AC-1: CR -> launch (unchanged)');
    is_deeply([Dashboard::dispatch_key("\n", '')], ['launch', ''], 'AC-1: LF -> launch (unchanged)');
    is_deeply([Dashboard::dispatch_key('r', '')], ['refresh', ''], 'AC-1: r -> refresh (unchanged)');
    is_deeply([Dashboard::dispatch_key('R', '')], ['refresh', ''], 'AC-1: R -> refresh (unchanged)');
    is_deeply([Dashboard::dispatch_key('q', '')], ['quit', ''], 'AC-1: q -> quit (unchanged)');
    is_deeply([Dashboard::dispatch_key('Q', '')], ['quit', ''], 'AC-1: Q -> quit (unchanged)');
    is_deeply([Dashboard::dispatch_key('UP', '')], ['scroll-up', ''], 'AC-1: UP -> scroll-up (unchanged)');
    is_deeply([Dashboard::dispatch_key('DOWN', '')], ['scroll-down', ''], 'AC-1: DOWN -> scroll-down (unchanged)');
    is_deeply([Dashboard::dispatch_key('k', '')], ['scroll-up', ''], 'AC-1: k -> scroll-up (unchanged)');
    is_deeply([Dashboard::dispatch_key('j', '')], ['scroll-down', ''], 'AC-1: j -> scroll-down (unchanged)');
    is_deeply([Dashboard::dispatch_key('z', '')], ['', ''], 'AC-1: unknown key -> inert (unchanged)');
    is_deeply([Dashboard::dispatch_key("\e", '')], ['', ''], 'AC-1: lone ESC -> inert (unchanged)');
    is_deeply([Dashboard::dispatch_key(undef, undef)], ['', ''],
        'AC-1: undef key/pending normalize to empty string -> inert (unchanged)');
}

# --- AC-2 (B2): y/Y with relaunch armed fires and clears pending. ---
{
    is_deeply([ eval { Dashboard::dispatch_key('y', 'relaunch') } ], ['relaunch', ''],
        'AC-2: y while relaunch armed -> fire relaunch, pending cleared');
    is_deeply([ eval { Dashboard::dispatch_key('Y', 'relaunch') } ], ['relaunch', ''],
        'AC-2: Y while relaunch armed -> fire relaunch, pending cleared');
}

# --- AC-3 (B3): any other key with relaunch armed cancels it. ---
{
    for my $k ('n', 'UP', 'j', 'q', 'c', 'r', 's', 'x', 'l', "\e") {
        my $disp = ($k eq "\e") ? 'ESC' : $k;
        is_deeply([ eval { Dashboard::dispatch_key($k, 'relaunch') } ], ['cancel-relaunch', ''],
            "AC-3: key '$disp' while relaunch armed -> cancel-relaunch, pending cleared");
    }
}

# --- AC-4 (B4): three-way independence + the :1612 whitelist. ---
{
    is_deeply([ eval { Dashboard::dispatch_key('l', 'stop-runs') } ], ['cancel-stop-runs', ''],
        'AC-4: l while stop-runs armed cancels it (does NOT re-arm relaunch)');
    is_deeply([ eval { Dashboard::dispatch_key('l', 'full-shutdown') } ], ['cancel-full-shutdown', ''],
        'AC-4: l while full-shutdown armed cancels it (does NOT re-arm relaunch)');
    is_deeply([ eval { Dashboard::dispatch_key('s', 'relaunch') } ], ['cancel-relaunch', ''],
        'AC-4: s while relaunch armed cancels it (does NOT fire/re-arm stop-runs)');
    is_deeply([ eval { Dashboard::dispatch_key('x', 'relaunch') } ], ['cancel-relaunch', ''],
        'AC-4: x while relaunch armed cancels it (does NOT fire/re-arm full-shutdown)');
    is_deeply([Dashboard::dispatch_key('y', '')], ['', ''],
        'AC-4: bare y with nothing armed fires nothing (inert)');
    is_deeply([Dashboard::dispatch_key('y', 'bogus-token')], ['', ''],
        'AC-4: y with an unrecognized pending token is inert (whitelist gained ONLY "relaunch")');
    is_deeply([Dashboard::dispatch_key('y', 'shutdown')], ['', ''],
        'AC-4: y with the legacy "shutdown" token is still inert (whitelist unchanged apart from relaunch)');
    is_deeply([ eval { Dashboard::dispatch_key('y', 'stop-runs') } ], ['stop-runs', ''],
        'AC-4: the stop-runs confirm still fires independently');
    is_deeply([ eval { Dashboard::dispatch_key('y', 'full-shutdown') } ], ['full-shutdown', ''],
        'AC-4: the full-shutdown confirm still fires independently');
}

# ===========================================================================
# PART 2 -- the confirm surface: confirm_prompt + compose_frame footer role
#           (AC-5, AC-6 / B5, B6)
# ===========================================================================

# --- AC-5 (B5): the relaunch confirm prompt at every width. ---
{
    my @pins = (
        [qr/relaunch|re-attach/i, 'names relaunch/re-attach'],
        [qr/machine/i,            'names the machine'],
        [qr/container/i,          'names the container'],
        [qr/\[y\] confirm/,       'carries "[y] confirm"'],
        [qr/cancel/i,             'mentions cancel'],
        [qr/nothing is deleted/i, 'promises nothing is deleted'],
    );
    for my $cols (40, 80, 200) {
        my $p = eval { Dashboard::confirm_prompt('relaunch', $cols) };
        ok(defined $p, "AC-5: confirm_prompt('relaunch', $cols) is defined");
        for my $pin (@pins) {
            my ($re, $what) = @$pin;
            like_or_fail($p, $re, "AC-5: relaunch prompt $what at cols=$cols");
        }
    }
    is(eval { Dashboard::confirm_prompt('', 80) }, undef,
        "AC-5: confirm_prompt('', 80) is still undef");
    is(eval { Dashboard::confirm_prompt('shutdown', 80) }, undef,
        "AC-5: confirm_prompt('shutdown', 80) (legacy token) is still undef");
}

# --- AC-6 (B6): compose_frame's footer role for pending => 'relaunch'. ---
{
    my %base = (project_name => 'demo', container => 'c1', status => 'running', events => []);

    my %sr = (%base, pending => 'relaunch');
    my $fr = Dashboard::compose_frame(\%sr, 12, 80);
    is($fr->[-1]{role}, 'footer-alert', "AC-6: pending='relaunch' -> footer role is footer-alert");
    my $prompt = eval { Dashboard::confirm_prompt('relaunch', 80) };
    if (defined $prompt) {
        like($fr->[-1]{text}, qr/\Q$prompt\E/,
            "AC-6: pending='relaunch' -> footer text carries the relaunch confirm prompt");
    }
    else {
        fail("AC-6: pending='relaunch' -> footer text carries the relaunch confirm prompt");
    }

    # The two s11 tokens behave identically (no regression).
    for my $tok ('stop-runs', 'full-shutdown') {
        my %s = (%base, pending => $tok);
        my $f = Dashboard::compose_frame(\%s, 12, 80);
        is($f->[-1]{role}, 'footer-alert', "AC-6: pending='$tok' -> footer role is still footer-alert");
    }

    # No pending -> the ordinary footer role.
    my %none = (%base, pending => '');
    my $fn = Dashboard::compose_frame(\%none, 12, 80);
    is($fn->[-1]{role}, 'footer', 'AC-6: no pending -> footer role');
    like($fn->[-1]{text}, qr/\[q\] quit/, 'AC-6: no pending -> the command legend is shown');

    # NO NEW ROLE: the set of roles a relaunch frame uses must be exactly the
    # set an s11 full-shutdown frame uses.
    my %sx = (%base, pending => 'full-shutdown');
    my $fx = Dashboard::compose_frame(\%sx, 12, 80);
    my %rl; $rl{ $_->{role} } = 1 for @$fr;
    my %rx; $rx{ $_->{role} } = 1 for @$fx;
    is_deeply([sort keys %rl], [sort keys %rx],
        'AC-6: a relaunch frame introduces NO new row role (identical role set to a full-shutdown frame)');

    # NO NEW SGR ENTRY: every role in the relaunch frame already resolves.
    for my $role (sort keys %rl) {
        my $sgr = eval { Dashboard::sgr_for_role($role) };
        ok(defined $sgr, "AC-6: role '$role' resolves through the EXISTING sgr_for_role table");
    }
}

# ===========================================================================
# PART 3 -- alert-path surfacing: _status_alert + launch_blocked_msg
#           (AC-7, AC-8 / B7, B8)
# ===========================================================================
sub alert_of { my ($st) = @_; return eval { Dashboard::_status_alert($st) }; }

# --- AC-7 (B7): the spec 2.3 table, all six rows, and no [c] anywhere. ---
{
    # Row 1 -- machine_state 'stopped' wins over everything else.
    my $r1 = alert_of({ machine_state => 'stopped', status => 'unknown' });
    like_or_fail($r1, qr/podman machine/i, 'AC-7 row1: machine_state stopped -> names the podman machine');
    like_or_fail($r1, qr/stopped/i,        'AC-7 row1: machine_state stopped -> says stopped');
    like_or_fail($r1, qr/\[l\]/,           'AC-7 row1: machine_state stopped -> offers [l]');
    unlike_or_fail($r1, qr/\[c\]/,         'AC-7 row1: machine_state stopped -> never offers [c]');

    # Row 2 -- container_gone with a KNOWN, non-'unknown' status.
    my $r2 = alert_of({ container_gone => 1, status => 'exited' });
    like_or_fail($r2, qr/not running/,           'AC-7 row2: gone + exited -> "not running"');
    like_or_fail($r2, qr/\[l\]/,                 'AC-7 row2: gone + exited -> offers [l]');
    like_or_fail($r2, qr/re-run claude-sandbox/, 'AC-7 row2: gone + exited -> names re-run claude-sandbox');
    unlike_or_fail($r2, qr/\[c\]/,               'AC-7 row2: gone + exited -> never offers [c]');

    # Row 3 -- container_gone otherwise (status unknown / not yet known).
    for my $st ('unknown', '') {
        my $lbl = ($st eq '') ? 'empty' : $st;
        my $r3 = alert_of({ container_gone => 1, status => $st });
        like_or_fail($r3, qr/unreachable/, "AC-7 row3: gone + status '$lbl' -> \"unreachable\"");
        like_or_fail($r3, qr/\[l\]/,       "AC-7 row3: gone + status '$lbl' -> offers [l]");
        like_or_fail($r3, qr/\[r\]/,       "AC-7 row3: gone + status '$lbl' -> offers [r]");
        unlike_or_fail($r3, qr/\[c\]/,     "AC-7 row3: gone + status '$lbl' -> never offers [c]");
    }

    # Row 4 -- healthy / transient / not-yet-known statuses stay silent.
    for my $st ('', '?', 'running', 'created', 'restarting') {
        my $lbl = ($st eq '') ? 'empty' : $st;
        is(alert_of({ status => $st }), undef, "AC-7 row4: status '$lbl' -> undef (no banner)");
    }

    # Row 5 -- status 'unknown' without container_gone.
    my $r5 = alert_of({ status => 'unknown' });
    like_or_fail($r5, qr/unreachable/,                'AC-7 row5: status unknown -> "unreachable"');
    like_or_fail($r5, qr/podman down or host asleep/, 'AC-7 row5: status unknown -> names "podman down or host asleep"');
    like_or_fail($r5, qr/\[l\]/,                      'AC-7 row5: status unknown -> offers [l]');
    like_or_fail($r5, qr/\[r\]/,                      'AC-7 row5: status unknown -> offers [r]');
    unlike_or_fail($r5, qr/\[c\]/,                    'AC-7 row5: status unknown -> never offers [c]');

    # Row 6 -- any other status.
    for my $st ('exited', 'paused', 'dead') {
        my $r6 = alert_of({ status => $st });
        like_or_fail($r6, qr/(is|not) running/,       "AC-7 row6: status '$st' -> says (is|not) running");
        like_or_fail($r6, qr/\[l\]/,                  "AC-7 row6: status '$st' -> offers [l]");
        like_or_fail($r6, qr/re-run claude-sandbox/,  "AC-7 row6: status '$st' -> names re-run claude-sandbox");
        unlike_or_fail($r6, qr/\[c\]/,                "AC-7 row6: status '$st' -> never offers [c]");
    }

    # Every substring pinned by t/25:212-261 survives.
    is(alert_of({ status => 'running' }), undef, 'AC-7 (t/25 pin): running -> no alert');
    is(alert_of({ status => '' }),        undef, 'AC-7 (t/25 pin): empty/unknown-yet -> no alert');
    like_or_fail(alert_of({ status => 'exited' }),  qr/not running/,  'AC-7 (t/25 pin): exited -> "not running"');
    like_or_fail(alert_of({ status => 'unknown' }), qr/unreachable/,  'AC-7 (t/25 pin): unknown -> "unreachable"');
    like_or_fail(alert_of({ container_gone => 1, status => 'exited' }),  qr/not running/,
        'AC-7 (t/25 pin): container_gone+exited -> "not running"');
    like_or_fail(alert_of({ container_gone => 1, status => 'unknown' }), qr/unreachable/,
        'AC-7 (t/25 pin): container_gone+unknown -> "unreachable"');
    like_or_fail(alert_of({ status => 'exited' }), qr/re-run claude-sandbox/,
        'AC-7 (t/25 pin): exited banner still names the real relaunch path');
    for my $dead ({ status => 'exited' },
                  { container_gone => 1, status => 'exited' },
                  { container_gone => 1, status => 'unknown' }) {
        my $msg = alert_of($dead);
        unlike_or_fail($msg, qr/relaunch.*\[c\]|\[c\].*relaunch/i,
            'AC-7 (t/25 pin): [c] is never called the relaunch key');
    }
}

# --- AC-8 (B8): the machine-down banner, launch_blocked_msg, can_launch. ---
{
    my $m = alert_of({ machine_state => 'stopped', status => 'unknown' });
    like_or_fail($m, qr/podman machine/i, 'AC-8: machine-down banner names the podman machine');
    like_or_fail($m, qr/\[l\]/,           'AC-8: machine-down banner offers [l]');

    # Textually DISTINCT from the container-removed / unreachable banners.
    my $gone = alert_of({ container_gone => 1, status => 'unknown' });
    my $unk  = alert_of({ status => 'unknown' });
    if (defined $m && defined $gone) {
        isnt($m, $gone, 'AC-8: the machine-down banner is textually distinct from the container-gone banner');
    }
    else { fail('AC-8: the machine-down banner is textually distinct from the container-gone banner'); }
    if (defined $m && defined $unk) {
        isnt($m, $unk, 'AC-8: the machine-down banner is textually distinct from the unreachable banner');
    }
    else { fail('AC-8: the machine-down banner is textually distinct from the unreachable banner'); }

    my $lb = eval { Dashboard::launch_blocked_msg() };
    like_or_fail($lb, qr/container is down/,     'AC-8: launch_blocked_msg keeps /container is down/');
    like_or_fail($lb, qr/\[l\]/,                 'AC-8: launch_blocked_msg offers [l]');
    like_or_fail($lb, qr/re-run claude-sandbox/, 'AC-8: launch_blocked_msg names re-run claude-sandbox');
    unlike_or_fail($lb, qr/\[c\]/,               'AC-8: launch_blocked_msg never offers [c]');
    unlike_or_fail($lb, qr/\[s\] stop/,          'AC-8: launch_blocked_msg is not the command legend');

    # can_launch is UNCHANGED (spec 2.3) -- every t/25:266-274 input.
    ok( Dashboard::can_launch({ status => 'running' }),    'AC-8: can_launch running -> yes (unchanged)');
    ok(!Dashboard::can_launch({ status => 'exited' }),     'AC-8: can_launch exited -> no (unchanged)');
    ok(!Dashboard::can_launch({ status => 'stopped' }),    'AC-8: can_launch stopped -> no (unchanged)');
    ok(!Dashboard::can_launch({ status => 'created' }),    'AC-8: can_launch created -> no (unchanged)');
    ok(!Dashboard::can_launch({ status => 'restarting' }), 'AC-8: can_launch restarting -> no (unchanged)');
    ok(!Dashboard::can_launch({ status => '' }),           'AC-8: can_launch not-yet-known -> no (unchanged)');
    ok(!Dashboard::can_launch({ status => 'running', container_gone => 1 }),
        'AC-8: can_launch gone overrides a stale running status -> no (unchanged)');
    # A stopped machine must not accidentally make can_launch permissive.
    ok(!Dashboard::can_launch({ status => 'exited', machine_state => 'stopped' }),
        'AC-8: can_launch ignores machine_state (still no on a dead container)');
}

# ===========================================================================
# PART 4 -- the pure layer: recover_plan + classify_container_state
#           (AC-9, AC-10 / B9, B10)
# ===========================================================================

# --- AC-9 (B9): recover_plan's pinned ordered ids/labels. ---
{
    is_deeply(scalar(eval { Dashboard::recover_plan({ machine_capable => 1 }) }), pinned_plan(1),
        'AC-9: recover_plan({machine_capable=>1}) -> the 4 pinned stages, in catalog order');
    for my $case ([ '{}', {} ], [ 'undef', undef ], [ "'x'", 'x' ],
                  [ '{machine_capable=>0}', { machine_capable => 0 } ],
                  [ 'arrayref', [] ]) {
        my ($label, $in) = @$case;
        is_deeply(scalar(eval { Dashboard::recover_plan($in) }), pinned_plan(0),
            "AC-9: recover_plan($label) -> container-start + heartbeat-reattach only");
    }

    # Ordering is load-bearing (spec 2.4): machine-status BEFORE container-start,
    # heartbeat-reattach IMMEDIATELY after container-start.
    my $p4 = eval { Dashboard::recover_plan({ machine_capable => 1 }) };
    if (ref($p4) eq 'ARRAY') {
        is_deeply([ map { $_->{id} } @$p4 ],
            [qw(machine-status machine-start container-start heartbeat-reattach)],
            'AC-9: the 4-stage plan ids are in exactly the pinned order');
    }
    else { fail('AC-9: the 4-stage plan ids are in exactly the pinned order'); }
    my $p2 = eval { Dashboard::recover_plan({}) };
    if (ref($p2) eq 'ARRAY') {
        is_deeply([ map { $_->{id} } @$p2 ], [qw(container-start heartbeat-reattach)],
            'AC-9: the 2-stage plan ids are in exactly the pinned order');
    }
    else { fail('AC-9: the 2-stage plan ids are in exactly the pinned order'); }

    # Repeat-stable.
    is_deeply(scalar(eval { Dashboard::recover_plan({ machine_capable => 1 }) }),
              scalar(eval { Dashboard::recover_plan({ machine_capable => 1 }) }),
        'AC-9: recover_plan is repeat-stable (identical output on repeat calls)');

    # Fresh hashrefs: mutating one call's result cannot affect the next.
    my $a = eval { Dashboard::recover_plan({ machine_capable => 1 }) };
    if (ref($a) eq 'ARRAY' && ref($a->[0]) eq 'HASH') {
        $a->[0]{id}    = 'MUTATED';
        $a->[0]{label} = 'MUTATED';
    }
    is_deeply(scalar(eval { Dashboard::recover_plan({ machine_capable => 1 }) }), pinned_plan(1),
        'AC-9: recover_plan returns FRESH hashrefs (a mutated result does not leak into the next call)');

    # Never dies.
    my $died = 0;
    for my $in (undef, {}, 'x', [], \'scalarref', { machine_capable => undef }) {
        eval { Dashboard::recover_plan($in); 1 } or do { $died = 1 if $@ =~ /^(?!Undefined subroutine)/ && $@ !~ /Undefined subroutine/ };
    }
    ok(!$died, 'AC-9: recover_plan never dies on undef/non-hashref/odd input');
}

# --- AC-10 (B10): classify_container_state's full truth table. ---
{
    my @table = (
        ['running', 'stopped', 'running'],
        ['exited',  'running', 'stopped'],
        ['created', 'unknown', 'stopped'],
        ['paused',  'running', 'stopped'],
        ['dead',    'absent',  'stopped'],
        ['',        'running', 'absent'],
        ['unknown', 'running', 'absent'],
        [undef,     'n/a',     'absent'],
        ['',        'n/a',     'absent'],
        ['unknown', 'n/a',     'absent'],
        ['',        'stopped', 'unknown'],
        ['unknown', 'unknown', 'unknown'],
        ['',        'absent',  'unknown'],
        ['unknown', 'stopped', 'unknown'],
        [undef,     'stopped', 'unknown'],
        [undef,     undef,     'unknown'],
    );
    for my $row (@table) {
        my ($raw, $mach, $want) = @$row;
        my $rl = defined $raw  ? "'$raw'"  : 'undef';
        my $ml = defined $mach ? "'$mach'" : 'undef';
        is(scalar(eval { Dashboard::classify_container_state($raw, $mach) }), $want,
            "AC-10: classify_container_state($rl, $ml) -> $want");
    }

    # Normalisation: case-folded and whitespace-trimmed (spec 2.5).
    is(scalar(eval { Dashboard::classify_container_state('RUNNING', 'stopped') }), 'running',
        "AC-10: classify_container_state('RUNNING', ...) is case-folded -> running");
    is(scalar(eval { Dashboard::classify_container_state("  running \n", 'stopped') }), 'running',
        'AC-10: classify_container_state trims surrounding whitespace -> running');
    is(scalar(eval { Dashboard::classify_container_state('UNKNOWN', 'RUNNING') }), 'absent',
        "AC-10: both arguments are case-folded ('UNKNOWN'/'RUNNING' -> absent)");

    # Returns exactly one of the four vocabulary words, never dies.
    my %vocab = map { $_ => 1 } qw(running stopped absent unknown);
    my $bad = 0;
    for my $raw (undef, '', ' ', 'running', 'unknown', 'exited', 'Weird State') {
        for my $mach (undef, '', 'running', 'stopped', 'absent', 'unknown', 'n/a', 'garbage') {
            my $got = eval { Dashboard::classify_container_state($raw, $mach) };
            $bad++ unless defined $got && $vocab{$got};
        }
    }
    is($bad, 0, 'AC-10: classify_container_state always returns one of running|stopped|absent|unknown, never dies');
}

# ===========================================================================
# PART 5 -- run_recover_stages: ORDER, branches, failure, channels
#           (AC-11..AC-20 / B11-B20)
# ===========================================================================

# --- AC-11 (B11): cold path -- full order, all four stages ok. ---
{
    my %state = (machine_capable => 1, status => 'exited');
    my ($seams, $calls, $progress, $logs) = build_seams(
        machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
    );
    my $plan = plan_for(\%state);
    my $r = rr(plan => $plan, mode => 'recover', reason => 'in-tui-relaunch', state => \%state, %$seams);

    is_deeply($calls, [qw(machine_status machine_start container_start heartbeat_reattach)],
        'AC-11: cold path -- exact seam-call ORDER');
    is(field($r, 'ok'), 1, 'AC-11: result.ok == 1');
    is(field($r, 'failed_stage'), undef, 'AC-11: failed_stage is undef');
    is(field($r, 'error'), undef, 'AC-11: error is undef');
    is(field($r, 'mode'), 'recover', 'AC-11: result.mode is "recover"');
    is(field($r, 'reason'), 'in-tui-relaunch', 'AC-11: result.reason is carried through');
    is(field($r, 'timed_out'), 0, 'AC-11: result.timed_out == 0');
    is(stage_count($r), 4, 'AC-11: all four stages recorded');
    for my $id (qw(machine-status machine-start container-start heartbeat-reattach)) {
        my $s = stage_of($r, $id);
        is(field($s, 'state'), 'ok', "AC-11: stage '$id' state is ok");
    }
    like_or_fail(field($r, 'summary'), qr/machine started/i,   'AC-11: summary names the machine start');
    like_or_fail(field($r, 'summary'), qr/container started/i, 'AC-11: summary names the container start');
    like_or_fail(field($r, 'summary'), qr/re-attached/i,       'AC-11: summary names the re-attach');
}

# --- AC-12 (B12): idempotent / already-healthy path. ---
{
    my %state = (machine_capable => 1, status => 'running');
    my ($seams, $calls) = build_seams(
        machine_status => sub { { ok => 1, state => 'running', detail => 'machine running' } },
    );
    my $plan = plan_for(\%state);
    my $r = rr(plan => $plan, mode => 'recover', reason => 'in-tui-relaunch', state => \%state, %$seams);

    is_deeply($calls, [qw(machine_status heartbeat_reattach)],
        'AC-12: already-healthy -- ONLY machine_status and heartbeat_reattach are called');
    is(field($r, 'ok'), 1, 'AC-12: already-healthy -> ok == 1');
    is(field($r, 'failed_stage'), undef, 'AC-12: already-healthy -> failed_stage undef');
    is(stage_count($r), 4, 'AC-12: all four planned stages are recorded (two of them skipped)');

    my $ms = stage_of($r, 'machine-start');
    is(field($ms, 'state'), 'skipped', 'AC-12: machine-start stage is skipped');
    like_or_fail(field($ms, 'detail'), qr/machine already running/i,
        'AC-12: machine-start detail says the machine is already running');
    my $cs = stage_of($r, 'container-start');
    is(field($cs, 'state'), 'skipped', 'AC-12: container-start stage is skipped');
    like_or_fail(field($cs, 'detail'), qr/container already running/i,
        'AC-12: container-start detail says the container is already running');

    like_or_fail(field($r, 'summary'), qr/already running/i, 'AC-12: summary says already running');
    like_or_fail(field($r, 'summary'), qr/re-attached/i,     'AC-12: summary says re-attached');

    # Pressing [l] twice is safe: a second identical run is identical.
    my ($seams2, $calls2) = build_seams(
        machine_status => sub { { ok => 1, state => 'running', detail => 'machine running' } },
    );
    my $r2 = rr(plan => plan_for(\%state), mode => 'recover', reason => 'in-tui-relaunch',
                state => \%state, %$seams2);
    is_deeply($calls2, [qw(machine_status heartbeat_reattach)],
        'AC-12: a repeated [l] takes the same inert path (idempotent)');
    is(field($r2, 'ok'), 1, 'AC-12: a repeated [l] still reports ok == 1');
}

# --- AC-13 (B13): machine already up, container down. ---
{
    my %state = (machine_capable => 1, status => 'exited');
    my ($seams, $calls) = build_seams(
        machine_status   => sub { { ok => 1, state => 'running', detail => 'machine running' } },
        container_create => sub { { ok => 1, detail => 'created' } },   # wired only to prove it is NOT used
    );
    my $plan = plan_for(\%state);
    my $r = rr(plan => $plan, mode => 'recover', reason => 'in-tui-relaunch', state => \%state, %$seams);

    is_deeply($calls, [qw(machine_status container_start heartbeat_reattach)],
        'AC-13: machine up + container down -- exact seam-call ORDER');
    ok(!(grep { $_ eq 'container_create' } @$calls), 'AC-13: container_create is NEVER called');
    ok(!(grep { $_ eq 'machine_start' } @$calls),    'AC-13: machine_start is NEVER called');
    is(field(stage_of($r, 'machine-start'), 'state'), 'skipped', 'AC-13: machine-start stage is skipped');
    is(field($r, 'ok'), 1, 'AC-13: ok == 1');
    like_or_fail(field($r, 'summary'), qr/container started/i, 'AC-13: summary names the container start');
    like_or_fail(field($r, 'summary'), qr/re-attached/i,       'AC-13: summary names the re-attach');
}

# --- AC-14 (B14): R1 branch A -- absent container, container_create PRESENT. ---
{
    my %state = (machine_capable => 1, status => 'unknown');
    my ($seams, $calls) = build_seams(
        machine_status   => sub { { ok => 1, state => 'running', detail => 'machine running' } },
        container_create => sub { { ok => 1, detail => 'container created' } },
    );
    my $plan = plan_for(\%state);
    my $r = rr(plan => $plan, mode => 'recover', reason => 'launch-detect-broken', state => \%state, %$seams);

    is_deeply($calls, [qw(machine_status container_create heartbeat_reattach)],
        'AC-14: absent container + create seam -- exact seam-call ORDER');
    ok(!(grep { $_ eq 'container_start' } @$calls), 'AC-14: container_start is NEVER called on the absent branch');
    is(field($r, 'ok'), 1, 'AC-14: ok == 1 (s03 can supply a real create through this interface unchanged)');
    is(field($r, 'failed_stage'), undef, 'AC-14: failed_stage is undef');
    is(field(stage_of($r, 'container-start'), 'state'), 'ok', 'AC-14: the container-start stage is ok via create');
    is(field($r, 'reason'), 'launch-detect-broken', 'AC-14: the s03 reason tag is carried through');
}

# --- AC-15 (B15): R1 branch B (production) -- absent container, NO create seam. ---
{
    my %state = (machine_capable => 1, status => 'unknown');
    my ($seams, $calls) = build_seams(
        machine_status   => sub { { ok => 1, state => 'running', detail => 'machine running' } },
        container_create => ABSENT,   # production: the seam is not wired at all (R1)
    );
    my ($r, $err) = rre(plan => plan_for(\%state), mode => 'recover',
                        reason => 'container-gone', state => \%state, %$seams);

    ok(!$err, 'AC-15: run_recover_stages returns normally (no exception) with no container_create seam')
        or diag("  \$\@ = " . ($err // ''));
    ok(!(grep { $_ eq 'container_start' }    @$calls), 'AC-15: container_start is NEVER called');
    ok(!(grep { $_ eq 'container_create' }   @$calls), 'AC-15: container_create is NEVER called (it is absent)');
    ok(!(grep { $_ eq 'heartbeat_reattach' } @$calls), 'AC-15: heartbeat_reattach is NEVER called (sequence stopped)');

    my $cs = stage_of($r, 'container-start');
    is(field($cs, 'state'), 'fail', 'AC-15: the container-start stage is fail (not skipped)');
    is(field($r, 'failed_stage'), 'container-start', "AC-15: failed_stage eq 'container-start'");
    is(field($r, 'ok'), 0, 'AC-15: ok == 0');
    for my $pin ([qr/no longer exists/i, 'says the container no longer exists'],
                 [qr/re-run claude-sandbox/, 'names re-run claude-sandbox'],
                 [qr/rebuild/i, 'names the rebuild']) {
        my ($re, $what) = @$pin;
        like_or_fail(field($cs, 'detail'), $re, "AC-15: the stage detail $what");
    }
    like_or_fail(field($r, 'error'), qr/no longer exists/i,    'AC-15: error says the container no longer exists');
    like_or_fail(field($r, 'error'), qr/re-run claude-sandbox/, 'AC-15: error names re-run claude-sandbox');
    like_or_fail(field($r, 'summary'), qr/no longer exists/i,    'AC-15: summary says the container no longer exists');
    like_or_fail(field($r, 'summary'), qr/re-run claude-sandbox/, 'AC-15: summary names re-run claude-sandbox');

    # Only the stages that RAN are recorded (E6): machine-status, machine-start
    # (skipped), container-start (fail). heartbeat-reattach never ran.
    is(stage_count($r), 3, 'AC-15: only the executed stages are recorded (heartbeat-reattach omitted)');
    is(stage_of($r, 'heartbeat-reattach'), undef, 'AC-15: the unrun heartbeat-reattach stage is omitted entirely');
}

# --- AC-16 (B16): a mid-sequence failure stops the sequence, TUI intact. ---
{
    my %state = (machine_capable => 1, status => 'exited');
    my ($seams, $calls) = build_seams(
        machine_status   => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
        machine_start    => sub { { ok => 0, detail => 'no machine' } },
        container_create => sub { { ok => 1, detail => 'created' } },
    );
    my ($r, $err) = rre(plan => plan_for(\%state), mode => 'recover',
                        reason => 'machine-down', state => \%state, %$seams);

    ok(!$err, 'AC-16: a failing stage never dies out of run_recover_stages')
        or diag("  \$\@ = " . ($err // ''));
    is_deeply($calls, [qw(machine_status machine_start)],
        'AC-16: the sequence stops -- no later seam is called');
    is(stage_count($r), 2, 'AC-16: stages holds exactly the 2 executed stages');
    is(field($r, 'failed_stage'), 'machine-start', "AC-16: failed_stage eq 'machine-start'");
    ok(defined field($r, 'error') && length(field($r, 'error') // ''), 'AC-16: error is a non-empty string');
    like_or_fail(field($r, 'error'), qr/no machine/, "AC-16: error carries the failing stage's detail");
    is(field($r, 'ok'), 0, 'AC-16: ok == 0');
    is(field(stage_of($r, 'machine-start'), 'state'), 'fail', 'AC-16: the machine-start stage is fail');
    like_or_fail(field($r, 'summary'), qr/failed/i,        'AC-16: summary says failed');
    like_or_fail(field($r, 'summary'), qr/machine-start/,  'AC-16: summary names the failing stage id');
}

# --- AC-17 (B17): a bounded machine start that times out. ---
{
    my %state = (machine_capable => 1, status => 'exited');
    my ($seams, $calls) = build_seams(
        machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
        machine_start  => sub { { ok => 0, timeout => 1, detail => 'podman machine start did not finish within 180s' } },
    );
    my $r = rr(plan => plan_for(\%state), mode => 'recover', reason => 'in-tui-relaunch',
               state => \%state, %$seams);

    my $ms = stage_of($r, 'machine-start');
    is(field($ms, 'state'),  'timeout', "AC-17: the machine-start stage state is 'timeout'");
    is(field($ms, 'status'), 'failed',  "AC-17: the machine-start stage status alias is 'failed'");
    is(field($r, 'timed_out'), 1, 'AC-17: result.timed_out == 1');
    is(field($r, 'failed_stage'), 'machine-start', "AC-17: failed_stage eq 'machine-start'");
    is(field($r, 'ok'), 0, 'AC-17: ok == 0');
    is_deeply($calls, [qw(machine_status machine_start)], 'AC-17: the sequence is stopped after the timeout');
    like_or_fail(field($r, 'summary'), qr/timed out/i, 'AC-17: summary matches /timed out/i');
    like_or_fail(field($r, 'summary'), qr/machine/i,   'AC-17: summary names the machine');
}

# --- AC-18 (B18): nothing dies out -- dying seams and dying callbacks. ---
{
    # Each seam in turn as a dying stub. The setup for each case is chosen so
    # that the seam under test is actually reached.
    my @cases = (
        ['machine_status', 'machine-status', { machine_capable => 1, status => 'exited' },
         { }],
        ['machine_start', 'machine-start', { machine_capable => 1, status => 'exited' },
         { machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } } }],
        ['container_start', 'container-start', { machine_capable => 1, status => 'exited' },
         { machine_status => sub { { ok => 1, state => 'running', detail => 'machine running' } } }],
        ['container_create', 'container-start', { machine_capable => 1, status => 'unknown' },
         { machine_status => sub { { ok => 1, state => 'running', detail => 'machine running' } } }],
        ['heartbeat_reattach', 'heartbeat-reattach', { machine_capable => 1, status => 'running' },
         { machine_status => sub { { ok => 1, state => 'running', detail => 'machine running' } } }],
    );
    for my $c (@cases) {
        my ($seam_key, $stage_id, $state, $extra) = @$c;
        my ($seams, $calls) = build_seams(%$extra, $seam_key => sub { die "boom\n" });
        my ($r, $err) = rre(plan => plan_for($state), mode => 'recover',
                            reason => 'in-tui-relaunch', state => $state, %$seams);
        ok(!$err, "AC-18 [$seam_key dies]: run_recover_stages does not die")
            or diag("  \$\@ = " . ($err // ''));
        ok(ref($r) eq 'HASH', "AC-18 [$seam_key dies]: returns a well-formed hashref result");
        my $st = stage_of($r, $stage_id);
        is(field($st, 'state'), 'fail', "AC-18 [$seam_key dies]: stage '$stage_id' is marked fail");
        like_or_fail(field($st, 'detail'), qr/boom/, "AC-18 [$seam_key dies]: the error text is in the stage detail");
        like_or_fail(field($r, 'error'),   qr/boom/, "AC-18 [$seam_key dies]: the error text is in result.error");
        is(field($r, 'failed_stage'), $stage_id, "AC-18 [$seam_key dies]: failed_stage eq '$stage_id'");
        is(field($r, 'ok'), 0, "AC-18 [$seam_key dies]: ok == 0");
    }

    # A garbage (non-hashref) seam return is normalised, never fatal.
    {
        my %state = (machine_capable => 1, status => 'exited');
        my ($seams) = build_seams(
            machine_status  => sub { { ok => 1, state => 'running', detail => 'machine running' } },
            container_start => sub { 'not-a-hashref-but-truthy' },
        );
        my ($r, $err) = rre(plan => plan_for(\%state), mode => 'recover',
                            reason => 'in-tui-relaunch', state => \%state, %$seams);
        ok(!$err, 'AC-18: a seam returning a bare string does not die');
        is(field(stage_of($r, 'container-start'), 'state'), 'ok',
            'AC-18: a truthy non-hashref seam return normalises to ok');
    }

    # A dying status_cb / log_cb cannot abort the run.
    {
        my %state = (machine_capable => 1, status => 'exited');
        my ($ok_seams, $ok_calls) = build_seams(
            machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
        );
        my $good = rr(plan => plan_for(\%state), mode => 'recover', reason => 'in-tui-relaunch',
                      state => \%state, %$ok_seams);

        my ($bad_seams, $bad_calls) = build_seams(
            machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
            status_cb      => sub { die "cb boom\n" },
            log_cb         => sub { die "cb boom\n" },
        );
        my ($bad, $err) = rre(plan => plan_for(\%state), mode => 'recover', reason => 'in-tui-relaunch',
                              state => \%state, %$bad_seams);
        ok(!$err, 'AC-18: a dying status_cb/log_cb does not abort the run')
            or diag("  \$\@ = " . ($err // ''));
        is_deeply($bad_calls, [qw(machine_status machine_start container_start heartbeat_reattach)],
            'AC-18: with dying callbacks, EVERY stage still executes in order');
        is(field($bad, 'ok'), field($good, 'ok'), 'AC-18: dying callbacks leave result.ok unchanged');
        is(field($bad, 'summary'), field($good, 'summary'), 'AC-18: dying callbacks leave result.summary unchanged');
        is_deeply([ map { [ $_->{id}, $_->{state} ] } @{ field($bad, 'stages') || [] } ],
                  [ map { [ $_->{id}, $_->{state} ] } @{ field($good, 'stages') || [] } ],
            'AC-18: dying callbacks leave the stage list unchanged');
    }

    # Missing callbacks entirely (s03's no-TUI path, edge case 15).
    {
        my %state = (machine_capable => 1, status => 'exited');
        my ($seams) = build_seams(
            machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
            status_cb      => undef,
            log_cb         => undef,
        );
        my ($r, $err) = rre(plan => plan_for(\%state), mode => 'recover', reason => 'launch-detect-broken',
                            state => \%state, %$seams);
        ok(!$err, 'AC-18: non-CODE emit/log callbacks degrade to no-ops (no exception)');
        is(field($r, 'ok'), 1, 'AC-18: the result hashref is identical without callbacks');
    }
}

# --- AC-19 (B19): both channels, per stage -- exact counts and payloads. ---
{
    my %state = (machine_capable => 1, status => 'exited');
    my ($seams, $calls, $progress, $logs) = build_seams(
        machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
    );
    my $plan = plan_for(\%state);
    my $n = scalar(@$plan);          # planned
    my $r = rr(plan => $plan, mode => 'recover', reason => 'in-tui-relaunch', state => \%state, %$seams);
    my $k = stage_count($r);         # executed

    is($k, 4, 'AC-19: k == 4 executed stages on the cold path');
    is(scalar(@$progress), 2 * 4 + 1, 'AC-19: status_cb called exactly 2k+1 == 9 times (k=4)');
    is(scalar(@$logs), 4 + 2, 'AC-19: log_cb called exactly k+2 == 6 times (k=4)');

    # --- log channel ---
    is($logs->[0][0], 'lifecycle_start', 'AC-19: the FIRST log event is lifecycle_start');
    is($logs->[0][1]{mode},   'recover',          'AC-19: lifecycle_start.mode is "recover"');
    is($logs->[0][1]{stages}, $n,                 'AC-19: lifecycle_start.stages == the planned count');
    is($logs->[0][1]{reason}, 'in-tui-relaunch',  'AC-19: lifecycle_start.reason is carried');
    for my $v (values %{ $logs->[0][1] }) { ok(!ref($v), 'AC-19: lifecycle_start payload values are scalars'); }

    for my $i (0 .. 3) {
        my ($ev, $f) = @{ $logs->[1 + $i] || [] };
        is($ev, 'lifecycle_stage', "AC-19: stage log no.$i event name is lifecycle_stage");
        is($f->{mode},  'recover',        "AC-19: stage log no.$i .mode is recover");
        is($f->{stage}, $plan->[$i]{id},  "AC-19: stage log no.$i .stage matches plan order");
        is($f->{index}, $i + 1,           "AC-19: stage log no.$i .index is 1-based");
        is($f->{total}, $n,               "AC-19: stage log no.$i .total == the PLANNED count");
        ok((grep { ($f->{state} // '') eq $_ } qw(ok fail skipped timeout)),
            "AC-19: stage log no.$i .state is a pinned enum value");
        ok(defined $f->{detail}, "AC-19: stage log no.$i .detail is defined");
        for my $v (values %$f) { ok(!ref($v), "AC-19: stage log no.$i payload values are scalars (no nested refs)"); }
    }

    my ($lev, $lf) = @{ $logs->[-1] || [] };
    is($lev, 'lifecycle_done', 'AC-19: the LAST log event is lifecycle_done');
    is($lf->{mode},   'recover',         'AC-19: lifecycle_done.mode');
    is($lf->{ok},     1,                 'AC-19: lifecycle_done.ok');
    is($lf->{timed_out}, 0,              'AC-19: lifecycle_done.timed_out');
    is($lf->{reason}, 'in-tui-relaunch', 'AC-19: lifecycle_done.reason');
    ok(defined $lf->{summary} && length($lf->{summary}), 'AC-19: lifecycle_done.summary is a non-empty string');
    ok(exists $lf->{failed_stage}, 'AC-19: lifecycle_done carries a failed_stage key');
    ok(exists $lf->{error},        'AC-19: lifecycle_done carries an error key');
    is($lf->{failed_stage}, '', "AC-19: lifecycle_done.failed_stage is '' when undef (scalar, never undef ref)");
    is($lf->{error},        '', "AC-19: lifecycle_done.error is '' when undef");
    for my $v (values %$lf) { ok(!ref($v), 'AC-19: lifecycle_done payload values are scalars'); }

    # --- interface channel: pre-'running' + post-outcome per stage, then done ---
    for my $i (0 .. 3) {
        my $pre  = $progress->[2 * $i];
        my $post = $progress->[2 * $i + 1];
        is(field($pre, 'state'), 'running', "AC-19: progress no." . (2 * $i) . " is the PRE update (state running)");
        is(field($pre, 'active'), 1,        "AC-19: the pre update for stage $i has active => 1");
        is(field($pre, 'mode'), 'recover',  "AC-19: the pre update for stage $i has mode => recover");
        is(field($pre, 'reason'), 'in-tui-relaunch', "AC-19: the pre update for stage $i carries the reason");
        is(field($pre, 'stage'), $plan->[$i]{id},    "AC-19: the pre update for stage $i names the stage id");
        is(field($pre, 'label'), $plan->[$i]{label}, "AC-19: the pre update for stage $i names the stage label");
        is(field($pre, 'index'), $i + 1,             "AC-19: the pre update for stage $i has a 1-based index");
        is(field($pre, 'total'), $n,                 "AC-19: the pre update for stage $i has total == planned");
        ok(defined field($pre, 'detail'), "AC-19: the pre update for stage $i has a defined detail");
        ok((grep { (field($post, 'state') // '') eq $_ } qw(ok fail skipped timeout)),
            "AC-19: progress no." . (2 * $i + 1) . " is the POST update (outcome state)");
        is(field($post, 'stage'), $plan->[$i]{id}, "AC-19: the post update for stage $i names the same stage id");
        is(field($post, 'index'), $i + 1,          "AC-19: the post update for stage $i has the same index");
    }
    my $final = $progress->[-1];
    is(field($final, 'active'), 0,      'AC-19: the FINAL status_cb has active => 0');
    is(field($final, 'state'), 'done',  'AC-19: the FINAL status_cb has state => done');
    is(field($final, 'mode'), 'recover','AC-19: the FINAL status_cb has mode => recover');
    is(field($final, 'index'), 4,       'AC-19: the FINAL status_cb has index == k');
    is(field($final, 'total'), $n,      'AC-19: the FINAL status_cb has total == planned');
    ok(length(field($final, 'summary') // ''), 'AC-19: the FINAL status_cb has a non-empty summary');
}
{
    # AC-19 (further): a stopped sequence -- k=2 executed of n=4 planned.
    my %state = (machine_capable => 1, status => 'exited');
    my ($seams, $calls, $progress, $logs) = build_seams(
        machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
        machine_start  => sub { { ok => 0, detail => 'no machine' } },
    );
    my $plan = plan_for(\%state);
    my $r = rr(plan => $plan, mode => 'recover', reason => 'machine-down', state => \%state, %$seams);

    is(stage_count($r), 2, 'AC-19 (stopped): k == 2 executed stages');
    is(scalar(@$progress), 2 * 2 + 1, 'AC-19 (stopped): status_cb called exactly 2k+1 == 5 times');
    is(scalar(@$logs), 2 + 2, 'AC-19 (stopped): log_cb called exactly k+2 == 4 times');
    is($logs->[0][1]{stages}, 4, 'AC-19 (stopped): lifecycle_start.stages is the PLANNED count (4), not k');
    is($logs->[1][1]{total}, 4, 'AC-19 (stopped): lifecycle_stage.total is the PLANNED count (4), not k');
    is($logs->[-1][0], 'lifecycle_done', 'AC-19 (stopped): the terminal lifecycle_done is still emitted');
    is($logs->[-1][1]{failed_stage}, 'machine-start', 'AC-19 (stopped): lifecycle_done.failed_stage names the stage');
    like_or_fail($logs->[-1][1]{error}, qr/no machine/, 'AC-19 (stopped): lifecycle_done.error carries the detail');
    is($logs->[-1][1]{ok}, 0, 'AC-19 (stopped): lifecycle_done.ok == 0');
    for my $v (values %{ $logs->[-1][1] }) { ok(!ref($v), 'AC-19 (stopped): lifecycle_done payload values are scalars'); }
    is(field($progress->[-1], 'active'), 0,     'AC-19 (stopped): the FINAL status_cb has active => 0');
    is(field($progress->[-1], 'state'), 'done', 'AC-19 (stopped): the FINAL status_cb has state => done');
    is(field($progress->[-1], 'index'), 2,      'AC-19 (stopped): the FINAL status_cb has index == k (2)');
    ok(length(field($progress->[-1], 'summary') // ''), 'AC-19 (stopped): the FINAL status_cb has a non-empty summary');
}

# --- AC-20 (B20): the dual stage shape -- {id,label,state,detail}+{name,status}. ---
{
    my @scenarios = (
        ['cold path (ok)',    { machine_capable => 1, status => 'exited' },
         { machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } } }],
        ['idempotent (skipped)', { machine_capable => 1, status => 'running' },
         { machine_status => sub { { ok => 1, state => 'running', detail => 'machine running' } } }],
        ['failure (fail)',    { machine_capable => 1, status => 'exited' },
         { machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
           machine_start  => sub { { ok => 0, detail => 'no machine' } } }],
        ['timeout',           { machine_capable => 1, status => 'exited' },
         { machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
           machine_start  => sub { { ok => 0, timeout => 1, detail => 'expired' } } }],
    );
    my %want = (ok => 'ok', skipped => 'skipped', fail => 'failed', timeout => 'failed');
    my %seen;
    for my $sc (@scenarios) {
        my ($label, $state, $over) = @$sc;
        my ($seams) = build_seams(%$over);
        my $r = rr(plan => plan_for($state), mode => 'recover', reason => 'in-tui-relaunch',
                   state => $state, %$seams);
        my $stages = field($r, 'stages');
        ok(ref($stages) eq 'ARRAY' && @$stages, "AC-20 [$label]: stages is a non-empty arrayref");
        my ($missing_keys, $name_mismatch, $status_mismatch) = (0, 0, 0);
        for my $s (@{ $stages || [] }) {
            $missing_keys++ if grep { !exists $s->{$_} } qw(id label state detail name status);
            $name_mismatch++ unless defined $s->{name} && defined $s->{id} && $s->{name} eq $s->{id};
            my $w = $want{ $s->{state} // '' };
            $status_mismatch++ unless defined $w && defined $s->{status} && $s->{status} eq $w;
            $seen{ $s->{state} // '' } = 1;
        }
        is($missing_keys,   0, "AC-20 [$label]: every stage element carries all six keys {id,label,state,detail,name,status}");
        is($name_mismatch,  0, "AC-20 [$label]: every stage element has name eq id");
        is($status_mismatch,0, "AC-20 [$label]: every stage element maps state -> status (ok->ok, skipped->skipped, fail->failed, timeout->failed)");
    }
    # All four state vocabulary words were actually exercised above.
    for my $st (qw(ok skipped fail timeout)) {
        ok($seen{$st}, "AC-20: the '$st' state was exercised by the scenarios above (mapping proven for it)");
    }
    # And the labels come from the catalog, not from a second hardcoding.
    {
        my %state = (machine_capable => 1, status => 'exited');
        my ($seams) = build_seams(
            machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
        );
        my $r = rr(plan => plan_for(\%state), mode => 'recover', reason => 'in-tui-relaunch',
                   state => \%state, %$seams);
        is_deeply([ map { [ $_->{id}, $_->{label} ] } @{ field($r, 'stages') || [] } ],
                  [ map { [ $_->{id}, $_->{label} ] } @{ pinned_plan(1) } ],
            'AC-20: the stage ids/labels are exactly the pinned catalog entries');
    }
}

# ===========================================================================
# PART 6 -- the banner: lifecycle_alert_msg + _alert_msgs (AC-21 / B21)
# ===========================================================================
{
    my $active = eval { Dashboard::lifecycle_alert_msg({ lifecycle => {
        active => 1, mode => 'recover', reason => 'in-tui-relaunch', index => 3, total => 4,
        stage => 'container-start', label => 'start container', state => 'running', detail => '',
    } }) };
    is($active, 'recover 3/4: start container - running',
        'AC-21: the active recover banner matches the pinned format exactly');
    like_or_fail($active, qr/^recover /, 'AC-21: the active recover banner starts with "recover " (never "?")');

    my $done = eval { Dashboard::lifecycle_alert_msg({ lifecycle => {
        active => 0, mode => 'recover', reason => 'in-tui-relaunch',
        summary => 'machine started; container started; re-attached',
    } }) };
    is($done, 'recover done: machine started; container started; re-attached',
        'AC-21: the finished recover banner is "recover done: <summary>"');
    like_or_fail($done, qr/^recover /, 'AC-21: the finished recover banner starts with "recover " (never "?")');

    # s11's two modes are unchanged.
    is(eval { Dashboard::lifecycle_alert_msg({ lifecycle => {
        active => 1, mode => 'stop-runs', index => 1, total => 2,
        stage => 'signal-runs', label => 'signal butler runs', state => 'running' } }) },
        'stop runs 1/2: signal butler runs - running',
        'AC-21: the stop-runs banner is unchanged');
    is(eval { Dashboard::lifecycle_alert_msg({ lifecycle => {
        active => 1, mode => 'full-shutdown', index => 3, total => 4,
        stage => 'stop-container', label => 'stop container', state => 'running' } }) },
        'full shutdown 3/4: stop container - running',
        'AC-21: the full-shutdown banner is unchanged');

    # %mode_label registers 'recover' -- the :2252 fallback is a defence, not
    # the contract (spec 2.6b). Source scan of Dashboard.pm.
    my $dsrc = slurp($DASHBOARD_SRC);
    ok(length($dsrc) > 0, 'AC-21: Dashboard.pm is readable for the %mode_label source scan')
        or diag("expected at $DASHBOARD_SRC");
    my $ml = extract_call_block($dsrc, '%mode_label');
    if (defined $ml) {
        src_like($ml, qr/(['"])recover\1\s*=>/, "AC-21: %mode_label registers a 'recover' key");
    }
    else {
        fail("AC-21: %mode_label registers a 'recover' key (the %mode_label literal was not found)");
    }

    # _alert_msgs still returns the lifecycle banner FIRST.
    my %state = (
        lifecycle => { active => 1, mode => 'recover', reason => 'in-tui-relaunch', index => 3, total => 4,
                       stage => 'container-start', label => 'start container', state => 'running' },
        status => 'exited',
        install_warning => 'backpack install FAILED',
    );
    my @msgs = eval { Dashboard::_alert_msgs(\%state, 20) };
    ok(scalar(@msgs) >= 1, 'AC-21: _alert_msgs returns at least one message with lifecycle+status+install_warning present');
    like_or_fail($msgs[0], qr{^recover 3/4},
        'AC-21: the recover banner is the FIRST (highest-priority) message in _alert_msgs');
}

# ===========================================================================
# PART 7 -- Dashboard::run loop integration (AC-22, AC-23, AC-24 / B22-B24)
# ===========================================================================

# drive3: the drive2 mould (t/46:768-817), wiring the NEW `recover` seam (spec
# 2.7). It captures every individual $out call, and -- crucially for AC-23 --
# an ORDERED event stream segmented by tick boundaries, so "on the tick
# immediately following the recover" is directly assertable. The clock is a
# fake counter; nothing here ever sleeps for real.
sub drive3 {
    my (%args) = @_;
    my @keys  = @{ $args{keys} || [] };
    my $clock = 1000;
    my %eff = (recover_calls => 0, stop_runs_calls => 0, full_shutdown_calls => 0,
               gathers => 0, heartbeats => 0, frames => 0);
    my @out_calls;
    my @events;        # ordered: ['tick-end'] | ['gather'] | ['heartbeat'] | ['recover'] | ['out',$s]
    my $recovered = 0;

    my $rc = eval {
        Dashboard::run(
            beat_interval  => $args{beat_interval}  // 9999,
            state_interval => $args{state_interval} // 999,
            tick_interval  => $args{tick_interval}  // 0.25,
            color          => 0,
            max_ticks      => $args{max_ticks} // 20,
            # AC-37 only. Passed through ONLY when the caller supplied it, so
            # every pre-existing drive3() call site reaches Dashboard::run with
            # a byte-identical argument list.
            (exists $args{recover_cooldown} ? (recover_cooldown => $args{recover_cooldown}) : ()),
            now            => sub { $clock },
            sleep_for      => sub { $clock += $_[0]; push @events, ['tick-end']; },   # fake clock
            read_key       => sub { @keys ? shift @keys : undef },
            term_size      => sub { ($args{cols} // 80, $args{rows} // 24) },
            gather         => sub {
                $eff{gathers}++;
                push @events, ['gather'];
                return { project_name => 'demo', container => 'c1', events => [],
                         status => ($args{status} ? $args{status}->($recovered) : 'running') };
            },
            heartbeat      => sub {
                $eff{heartbeats}++;
                push @events, ['heartbeat'];
                return $args{hb_returns} ? $args{hb_returns}->($recovered) : 'ok';
            },
            spawn          => sub { undef },
            write_signals  => sub { 1 },     # run() must still tolerate this unknown/legacy key
            recover        => sub {
                my ($state, $progress) = @_;
                $eff{recover_calls}++;
                push @events, ['recover'];
                for my $i (1 .. ($args{progress_ticks} // 0)) {
                    $progress->({ active => 1, mode => 'recover', reason => 'in-tui-relaunch',
                                  stage => "stage$i", label => "label$i", index => $i,
                                  total => ($args{progress_ticks} // 0), state => 'running', detail => '' });
                }
                $progress->({ active => 0, mode => 'recover', reason => 'in-tui-relaunch',
                              state => 'done', index => 0, total => 0, summary => 'RECOVERMARK123' });
                $recovered = 1;
                return { mode => 'recover', ok => 1, timed_out => 0, stages => [],
                         reason => 'in-tui-relaunch', failed_stage => undef, error => undef,
                         summary => 'RECOVERMARK123' };
            },
            stop_runs      => sub {
                $eff{stop_runs_calls}++;
                return { mode => 'stop-runs', ok => 1, timed_out => 0, stages => [],
                         machine_stopped => 0, others => [], others_known => 0, summary => 'stop-runs ok' };
            },
            full_shutdown  => sub {
                $eff{full_shutdown_calls}++;
                return { mode => 'full-shutdown', ok => 1, timed_out => 0, stages => [],
                         machine_stopped => 1, others => [], others_known => 1, summary => 'full shutdown ok' };
            },
            enter_raw => sub { $eff{entered} = 1 },
            leave_raw => sub { $eff{left} = ($eff{left} || 0) + 1 },
            keepawake => sub { },
            out       => sub { push @out_calls, $_[0]; push @events, ['out', $_[0]]; $eff{frames}++; },
        );
    };
    $eff{err}       = $@;
    $eff{rc}        = $rc;
    $eff{out}       = join('', @out_calls);
    $eff{out_calls} = \@out_calls;
    $eff{events}    = \@events;
    return \%eff;
}

# segments(\@events) -> \@segments, one per tick (split on the end-of-tick sleep).
sub segments {
    my ($events) = @_;
    my @segs = ([]);
    for my $e (@{ $events || [] }) {
        if ($e->[0] eq 'tick-end') { push @segs, []; }
        else                        { push @{ $segs[-1] }, $e; }
    }
    return \@segs;
}
sub seg_index_of {
    my ($segs, $tag) = @_;
    for my $i (0 .. $#$segs) { return $i if grep { $_->[0] eq $tag } @{ $segs->[$i] }; }
    return -1;
}
sub seg_has { my ($seg, $tag) = @_; return scalar(grep { $_->[0] eq $tag } @{ $seg || [] }); }

# --- AC-22 (B22): the control never exits the loop. ---
{
    my $e = drive3(keys => ['l', 'y', 'q'], max_ticks => 50);
    ok(!$e->{err}, 'AC-22: Dashboard::run does not die with a recover seam wired') or diag("  \$\@ = $e->{err}");
    is($e->{rc}, 0, 'AC-22: l,y,q -> rc 0 (the recover never ends the loop; q does)');
    is($e->{recover_calls}, 1, 'AC-22: the recover seam is called exactly once');
    is($e->{left}, 1, 'AC-22: the terminal is restored exactly once');
}
{
    my $e = drive3(keys => ['l', 'n', 'q'], max_ticks => 50);
    is($e->{recover_calls}, 0, 'AC-22: l,n -> the recover seam is NEVER called (cancel)');
    is($e->{rc}, 0, 'AC-22: l,n,q -> rc 0');
}
{
    my $e = drive3(keys => ['l', 'y'], max_ticks => 3);
    is($e->{rc}, 0, 'AC-22: l,y with max_ticks=3 and no q -> rc 0 (reached max_ticks, not a recover-exit)');
    is($e->{recover_calls}, 1, 'AC-22: the recover seam still fired once even though the loop kept running');
    my $segs = segments($e->{events});
    cmp_ok(scalar(@$segs), '>=', 3, 'AC-22: the loop reached tick 3 after the recover');
}
{
    # The recover fires ONLY through the two-step confirm.
    my $e = drive3(keys => ['y', 'q'], max_ticks => 50);
    is($e->{recover_calls}, 0, 'AC-22: a bare y with nothing armed never fires the recover');
}

# --- AC-23 (B23): the loop resumes -- BOTH $last_state and $last_beat reset. ---
{
    # state_interval 2 / beat_interval 120 with a 0.01s fake tick: over ~15
    # ticks only 0.15s of fake time elapses, so NEITHER cadence can fire on its
    # own. Any gather/heartbeat on the tick after the recover is therefore
    # proof of the forced reset, not of the cadence.
    my $e = drive3(
        keys           => ['l', 'y', (undef) x 10, 'q'],
        state_interval => 2,
        beat_interval  => 120,
        tick_interval  => 0.01,
        max_ticks      => 40,
        hb_returns     => sub { my ($recovered) = @_; return $recovered ? 'ok' : 'gone'; },
    );
    ok(!$e->{err}, 'AC-23: the run completes without dying') or diag("  \$\@ = $e->{err}");
    is($e->{recover_calls}, 1, 'AC-23: the recover seam fired exactly once');

    my $segs = segments($e->{events});
    my $R    = seg_index_of($segs, 'recover');
    cmp_ok($R, '>=', 0, 'AC-23: the recover is locatable in the tick stream');
    ok($R >= 0 && scalar(@$segs) > $R + 1, 'AC-23: at least one full tick follows the recover');

    if ($R >= 0 && @$segs > $R + 1) {
        # (a) gather on the tick IMMEDIATELY after the recover.
        ok(seg_has($segs->[$R + 1], 'gather'),
            'AC-23(a): gather is invoked on the tick immediately after the recover ($last_state reset)');
        # (b) heartbeat likewise -- this is the half a gather-only test misses.
        ok(seg_has($segs->[$R + 1], 'heartbeat'),
            'AC-23(b): heartbeat is invoked on the tick immediately after the recover ($last_beat reset)');

        # Control: neither cadence fires again on any LATER tick, so the two
        # invocations above cannot be the ordinary 2s/120s schedules.
        my $later_gathers    = 0;
        my $later_heartbeats = 0;
        for my $i ($R + 2 .. $#$segs) {
            $later_gathers    += seg_has($segs->[$i], 'gather');
            $later_heartbeats += seg_has($segs->[$i], 'heartbeat');
        }
        is($later_gathers, 0,
            'AC-23(a): no further gather on the 2s cadence (so the post-recover gather was FORCED)');
        is($later_heartbeats, 0,
            'AC-23(b): no further heartbeat on the 120s cadence (so the post-recover heartbeat was FORCED)');

        # (c) the dead-container banner clears within one tick of the recover.
        my $before = join('', map { $_->[1] } grep { $_->[0] eq 'out' } map { @{ $segs->[$_] } } 0 .. $R);
        like($before, qr/unreachable|not running/,
            'AC-23(c): the dead-container banner IS painted while the heartbeat says "gone"');
        my @after;
        for my $i ($R + 1 .. $#$segs) { push @after, map { $_->[1] } grep { $_->[0] eq 'out' } @{ $segs->[$i] }; }
        ok(scalar(@after) > 0, 'AC-23(d): frames keep being emitted after the recover');
        my $after_txt = join('', @after);
        unlike($after_txt, qr/unreachable|not running/,
            'AC-23(c): the dead-container banner is GONE from every frame from the next tick onward');
    }
    else {
        fail('AC-23(a): gather is invoked on the tick immediately after the recover ($last_state reset)');
        fail('AC-23(b): heartbeat is invoked on the tick immediately after the recover ($last_beat reset)');
        fail('AC-23(a): no further gather on the 2s cadence (so the post-recover gather was FORCED)');
        fail('AC-23(b): no further heartbeat on the 120s cadence (so the post-recover heartbeat was FORCED)');
        fail('AC-23(c): the dead-container banner IS painted while the heartbeat says "gone"');
        fail('AC-23(d): frames keep being emitted after the recover');
        fail('AC-23(c): the dead-container banner is GONE from every frame from the next tick onward');
    }
    is($e->{rc}, 0, 'AC-23(d): a later q still returns rc 0');
}

# --- AC-24 (B24): $progress repaints between stages. ---
{
    my $base     = drive3(keys => ['l', 'y', 'q'], max_ticks => 50, progress_ticks => 0);
    my $withprog = drive3(keys => ['l', 'y', 'q'], max_ticks => 50, progress_ticks => 3);
    cmp_ok($withprog->{frames} - $base->{frames}, '>=', 3,
        'AC-24: 3 mid-sequence progress calls -> at least 3 additional $out writes during the drain');

    # ONE named, documented exception (s07-live-status Decision #8,
    # Dashboard.pm:3017-3026): the OSC window-title emit is its OWN $out call and
    # is deliberately NOT wrapped -- an OS window-title escape cannot live inside
    # a TUI frame-sync marker.  window_title() guarantees
    # /\A[\x20-\x7E]{1,80}\z/, so the whole call is exactly this shape.  The
    # pattern is FULLY anchored (\A/\z, not ^/$) so no multi-line render fragment
    # and no merely-OSC-prefixed string can slip through.  The wrap-check itself
    # is unchanged; nothing else is excused.
    my $OSC_TITLE = qr/\A\e\]0;[\x20-\x7E]*\a\z/;
    my $unwrapped = sub {
        return scalar grep { $_ !~ $OSC_TITLE && (!/^\e\[\?2026h/ || !/\e\[\?2026l$/) } @_;
    };
    my $bad = $unwrapped->(@{ $withprog->{out_calls} });
    is($bad, 0, 'AC-24: EVERY $out call except the named OSC window-title emit is wrapped in \\e[?2026h ... \\e[?2026l (synchronized output)');

    # The exception must be NARROW.  Feed the SAME check two deliberately
    # unwrapped synthetic calls: one that is not OSC at all, and one that starts
    # with the OSC introducer but is not a valid title emit (trailing bytes after
    # the BEL).  Both must still be counted bad, and the delta must be exactly 2
    # -- i.e. attributable to the fakes, not to any real call.
    my $bad_aug = $unwrapped->(@{ $withprog->{out_calls} }, "\e[1;1Hnot a frame", "\e]0;fake\aTRAILING");
    is($bad_aug, $bad + 2,
        'AC-24-exception-is-narrow: a deliberately-unwrapped non-OSC $out call AND an OSC-prefixed near-miss are BOTH still caught (the exception is the exact title-emit shape, nothing wider)');
    ok(scalar(@{ $withprog->{out_calls} }) > 0, 'AC-24: frames were actually written');
}
{
    # AC-21 (further, via the loop): [r] clears $state{lifecycle}.
    my $e = drive3(keys => ['l', 'y', 'r', undef, 'q'], max_ticks => 50, progress_ticks => 0);
    my @out_calls = @{ $e->{out_calls} };
    my ($marker_idx) = grep { $out_calls[$_] =~ /RECOVERMARK123/ } 0 .. $#out_calls;
    ok(defined $marker_idx, 'AC-21: the recover summary marker appears in a frame before the refresh');
    if (defined $marker_idx) {
        my $after_r = join('', @out_calls[$marker_idx + 1 .. $#out_calls]);
        unlike($after_r, qr/RECOVERMARK123/, 'AC-21: refresh (r) clears the recover banner from subsequent frames');
    }
    else {
        fail('AC-21: refresh (r) clears the recover banner from subsequent frames (marker never appeared)');
    }
}

# ===========================================================================
# PART 8 -- render invariant (Decision #12, HARD GATE) (AC-25 / B25)
# ===========================================================================
{
    for my $cols (40, 80, 100, 200) {
        my $rows = 24;
        my %st = (
            project_name => 'demo', container => 'claude-demo-abcd1234', status => 'running',
            events => [], beat_age => 1, uptime => 10, pending => 'relaunch',
            lifecycle => {
                active => 1, mode => 'recover', reason => 'in-tui-relaunch', index => 2, total => 4,
                stage => 'machine-start', label => 'start podman machine', state => 'running',
                detail => ('this may take a minute; the dashboard is frozen until podman returns ' x 5),
            },
        );
        my $f = Dashboard::compose_frame(\%st, $rows, $cols);
        is(scalar(@$f), $rows, "AC-25: frame has exactly $rows rows at cols=$cols (recover banner + overlong detail + relaunch confirm)");
        my $bad = grep { Dashboard::display_width($_->{text}) != $cols } @$f;
        is($bad, 0, "AC-25: EVERY cell is exactly $cols DISPLAY columns wide at cols=$cols");

        my @bad_spans = grep { !$_->{spans} || ref($_->{spans}) ne 'ARRAY' || !@{ $_->{spans} } } @$f;
        is(scalar(@bad_spans), 0, "AC-25: every cell has a non-empty spans arrayref at cols=$cols");

        is($f->[-1]{role}, 'footer-alert', "AC-25: the armed relaunch confirm owns the footer row at cols=$cols");

        my $full = Dashboard::render_frame(undef, $f, { color => 0 });
        like($full, qr/^\e\[\?2026h/, "AC-25: render_frame (no prev) opens with the sync-output wrapper at cols=$cols");
        like($full, qr/\e\[\?2026l$/, "AC-25: render_frame (no prev) closes with the sync-output wrapper at cols=$cols");

        my $f2 = Dashboard::compose_frame(\%st, $rows, $cols);   # identical state -> identical frame
        my $diff = Dashboard::render_frame($f, $f2, { color => 0 });
        unlike($diff, qr/\e\[2J/, "AC-25: identical successive frames -> no full clear (per-row diff preserved) at cols=$cols");
        like($diff, qr/^\e\[\?2026h/, "AC-25: the diff render still opens with the sync-output wrapper at cols=$cols");
        like($diff, qr/\e\[\?2026l$/, "AC-25: the diff render still closes with the sync-output wrapper at cols=$cols");

        # NO new row builder / SGR role: the recover+relaunch frame uses exactly
        # the roles an s11 full-shutdown+confirm frame uses.
        my %s11 = (%st, pending => 'full-shutdown',
                   lifecycle => { active => 1, mode => 'full-shutdown', index => 3, total => 4,
                                  stage => 'stop-container', label => 'stop container', state => 'running',
                                  detail => $st{lifecycle}{detail} });
        my $f11 = Dashboard::compose_frame(\%s11, $rows, $cols);
        my %ra; $ra{ $_->{role} } = 1 for @$f;
        my %rb; $rb{ $_->{role} } = 1 for @$f11;
        is_deeply([sort keys %ra], [sort keys %rb],
            "AC-25: the recover/relaunch frame introduces NO new row role at cols=$cols");

        # The banner rides the existing alert row and is the FIRST alert.
        my %st2 = (%st, status => 'exited');
        my $f3 = Dashboard::compose_frame(\%st2, $rows, $cols);
        my @alerts = grep { $_->{role} eq 'alert' } @$f3;
        cmp_ok(scalar(@alerts), '>=', 2, "AC-25: the recover banner + status alert coexist as rows at cols=$cols");
        like($alerts[0]{text}, qr{recover 2/4},
            "AC-25: the recover banner is the FIRST alert row at cols=$cols") if @alerts;
    }

    # Edge case 10: a tiny terminal drops the banner rather than crowding the
    # body/footer -- display-only, and never a crash.
    {
        my %st = (project_name => 'demo', container => 'c1', status => 'running', events => [],
                  pending => 'relaunch',
                  lifecycle => { active => 1, mode => 'recover', index => 1, total => 4,
                                 stage => 'machine-status', label => 'check podman machine', state => 'running' });
        my $f = eval { Dashboard::compose_frame(\%st, 3, 80) };
        ok(ref($f) eq 'ARRAY', 'AC-25: rows<=3 with a recover banner does not crash compose_frame');
        is(scalar(@{ $f || [] }), 3, 'AC-25: rows<=3 still produces exactly $rows rows');
        my $bad = grep { Dashboard::display_width($_->{text}) != 80 } @{ $f || [] };
        is($bad, 0, 'AC-25: rows<=3 still keeps every row exactly $cols display columns');
    }
}

# ===========================================================================
# PART 9 -- Dashboard.pm purity source scan (AC-26 / B26)
#
# NOTE (reported to the coordinator): B26/AC-26 as written also forbid "the
# string `podman`" inside all four subs -- but spec 2.4 PINS the catalog labels
# 'check podman machine' / 'start podman machine' and spec 2.6 PINS the detail
# 'no podman machine on this platform'. The two clauses are mutually
# exclusive; the pinned literals win ("where a literal string is pinned, use it
# byte-for-byte"). The bare-string scan is therefore asserted only where it is
# consistent (recover_plan, classify_container_state); for the other two subs
# the real purity criterion -- no process/shell invocation, no $PODMAN -- is
# asserted instead.
# ===========================================================================
{
    my $src = slurp($DASHBOARD_SRC);
    ok(length($src) > 0, 'AC-26: Dashboard.pm is readable for the purity source scan')
        or diag("expected at $DASHBOARD_SRC");

    for my $sub_name (qw(_recover_stage_catalog recover_plan classify_container_state run_recover_stages)) {
        my $body = extract_sub_body($src, "sub $sub_name");
        if (defined $body) {
            my $stripped = $body;
            $stripped =~ s/#[^\n]*//g;
            src_unlike($stripped, qr/\bsystem\s*\(/, "AC-26: sub $sub_name body contains no system(...)");
            src_unlike($stripped, qr/`/,             "AC-26: sub $sub_name body contains no backtick");
            src_unlike($stripped, qr/\bqx\b/,        "AC-26: sub $sub_name body contains no qx");
            src_unlike($stripped, qr/\bexec\s*\(/,   "AC-26: sub $sub_name body contains no exec(...)");
            src_unlike($stripped, qr/\$PODMAN\b/,    "AC-26: sub $sub_name body never references \$PODMAN");
            src_unlike($stripped, qr/\bopen\s*\(/,   "AC-26: sub $sub_name body opens no handle (no pipe/process)");
        }
        else {
            fail("AC-26: sub $sub_name body contains no system(...) [sub not found in Dashboard.pm yet]");
            fail("AC-26: sub $sub_name body contains no backtick [sub not found]");
            fail("AC-26: sub $sub_name body contains no qx [sub not found]");
            fail("AC-26: sub $sub_name body contains no exec(...) [sub not found]");
            fail("AC-26: sub $sub_name body never references \$PODMAN [sub not found]");
            fail("AC-26: sub $sub_name body opens no handle [sub not found]");
        }
    }

    for my $sub_name (qw(recover_plan classify_container_state)) {
        my $body = extract_sub_body($src, "sub $sub_name");
        if (defined $body) {
            my $stripped = $body;
            $stripped =~ s/#[^\n]*//g;
            src_unlike($stripped, qr/podman/i, "AC-26: sub $sub_name body contains no 'podman' at all");
        }
        else {
            fail("AC-26: sub $sub_name body contains no 'podman' at all [sub not found]");
        }
    }
}

# ===========================================================================
# PART 10 -- launcher.pl wiring: source-text assertions (AC-27, AC-28 / B27)
#
# launcher.pl is NEVER require'd/do'ne here -- these are source-text
# assertions standing in for launcher-side impure behaviour that cannot be
# unit-tested without a real podman/container (spec S10's stated limitation,
# s11's precedent at 08:533).
# ===========================================================================
my $LSRC = slurp($LAUNCHER_SRC);

# --- AC-27 (B27): the recover seam + recover_container wiring. ---
{
    ok(length($LSRC) > 0, 'AC-27: launcher.pl is readable on disk') or BAIL_OUT("cannot read $LAUNCHER_SRC");

    # (a) `recover =>` inside the Dashboard::run( call, AFTER `full_shutdown =>`.
    my $run_call = extract_call_block($LSRC, 'Dashboard::run(');
    ok(defined $run_call, 'AC-27(a): the Dashboard::run( ... ) call block is balanced/extractable');
    if (defined $run_call) {
        src_like($run_call, qr/\bfull_shutdown\s*=>/, 'AC-27(a): the Dashboard::run( block still wires full_shutdown =>');
        src_like($run_call, qr/\brecover\s*=>/,       'AC-27(a): the Dashboard::run( block wires recover =>');
        my $fi = re_pos($run_call, qr/\bfull_shutdown\s*=>/);
        my $ri = re_pos($run_call, qr/\brecover\s*=>/);
        ok($fi >= 0 && $ri > $fi, 'AC-27(a): recover => appears AFTER full_shutdown => in the seam hashref');
    }
    else {
        fail('AC-27(a): the Dashboard::run( block still wires full_shutdown =>');
        fail('AC-27(a): the Dashboard::run( block wires recover =>');
        fail('AC-27(a): recover => appears AFTER full_shutdown => in the seam hashref');
    }

    # (b) sub recover_container reads state/reason/seams from ONE hashref and
    #     delegates to Dashboard::run_recover_stages.
    my $rcb = extract_sub_body($LSRC, 'sub recover_container');
    ok(defined $rcb, 'AC-27(b): sub recover_container exists in launcher.pl');
    if (defined $rcb) {
        src_like($rcb, qr/my\s*\(\s*\$\w+\s*\)\s*=\s*\@_/,     'AC-27(b): recover_container takes a single argument');
        src_like($rcb, qr/->\s*\{\s*['"]?state['"]?\s*\}/,     'AC-27(b): recover_container reads $args->{state}');
        src_like($rcb, qr/->\s*\{\s*['"]?reason['"]?\s*\}/,    'AC-27(b): recover_container reads $args->{reason}');
        src_like($rcb, qr/->\s*\{\s*['"]?seams['"]?\s*\}/,     'AC-27(b): recover_container reads $args->{seams}');
        src_like($rcb, qr/Dashboard::run_recover_stages/,      'AC-27(b): recover_container calls Dashboard::run_recover_stages');
        src_like($rcb, qr/Dashboard::recover_plan/,            'AC-27(b): recover_container gets its plan from Dashboard::recover_plan');
        src_like($rcb, qr/status_cb\s*=>/,                     'AC-27(b): recover_container maps emit -> status_cb');
        src_like($rcb, qr/log_cb\s*=>/,                        'AC-27(b): recover_container maps log -> log_cb');
        src_like($rcb, qr/in-tui-relaunch/,                    'AC-27(b): recover_container defaults reason to the pinned in-tui-relaunch tag');

        # (c) no exit, no SandboxLock::release (landmine 2).
        src_unlike($rcb, qr/\bexit\b/,                 'AC-27(c): recover_container body contains no exit');
        src_unlike($rcb, qr/SandboxLock::release/,     'AC-27(c): recover_container body contains no SandboxLock::release');

        # (d) the production seam set: four seams wired, container_create NOT.
        for my $seam (qw(machine_status machine_start container_start heartbeat_reattach)) {
            src_like($rcb, qr/\b\Q$seam\E\s*=>/, "AC-27(d): the production seam set wires $seam =>");
        }
        src_unlike($rcb, qr/\bcontainer_create\s*=>/,
            'AC-27(d): container_create is NOT wired in production (R1 -- no in-TUI recreate)');
    }
    else {
        fail('AC-27(b): recover_container takes a single argument');
        fail('AC-27(b): recover_container reads $args->{state}');
        fail('AC-27(b): recover_container reads $args->{reason}');
        fail('AC-27(b): recover_container reads $args->{seams}');
        fail('AC-27(b): recover_container calls Dashboard::run_recover_stages');
        fail('AC-27(b): recover_container gets its plan from Dashboard::recover_plan');
        fail('AC-27(b): recover_container maps emit -> status_cb');
        fail('AC-27(b): recover_container maps log -> log_cb');
        fail('AC-27(b): recover_container defaults reason to the pinned in-tui-relaunch tag');
        fail('AC-27(c): recover_container body contains no exit');
        fail('AC-27(c): recover_container body contains no SandboxLock::release');
        fail("AC-27(d): the production seam set wires machine_status =>");
        fail("AC-27(d): the production seam set wires machine_start =>");
        fail("AC-27(d): the production seam set wires container_start =>");
        fail("AC-27(d): the production seam set wires heartbeat_reattach =>");
        fail('AC-27(d): container_create is NOT wired in production (R1 -- no in-TUI recreate)');
    }

    # (e) gather returns a machine_state key.
    src_like($LSRC, qr/\bmachine_state\s*=>/, 'AC-27(e): launcher.pl gather returns a machine_state key');

    # (f) the recover seam closure invalidates the launcher-side gather caches
    #     AFTER the recover_container call (problem 8).
    my $closure = defined $run_call ? block_after($run_call, qr/\brecover\s*=>/) : undef;
    ok(defined $closure, 'AC-27(f): the recover => sub { ... } closure is extractable');
    if (defined $closure) {
        src_like($closure, qr/recover_container\s*\(/,        'AC-27(f): the recover closure calls recover_container(');
        src_like($closure, qr/\$last_inspect\s*=\s*0/,        'AC-27(f): the recover closure sets $last_inspect = 0');
        src_like($closure, qr/\$last_resources\s*=\s*0/,      'AC-27(f): the recover closure sets $last_resources = 0');
        my $ci = re_pos($closure, qr/recover_container\s*\(/);
        my $ii = re_pos($closure, qr/\$last_inspect\s*=\s*0/);
        my $si = re_pos($closure, qr/\$last_resources\s*=\s*0/);
        ok($ci >= 0 && $ii > $ci && $si > $ci,
            'AC-27(f): the cache invalidation happens AFTER the recover_container call');
        src_like($closure, qr/in-tui-relaunch/, 'AC-27(f): the recover closure passes the in-tui-relaunch reason tag');
    }
    else {
        fail('AC-27(f): the recover closure calls recover_container(');
        fail('AC-27(f): the recover closure sets $last_inspect = 0');
        fail('AC-27(f): the recover closure sets $last_resources = 0');
        fail('AC-27(f): the cache invalidation happens AFTER the recover_container call');
        fail('AC-27(f): the recover closure passes the in-tui-relaunch reason tag');
    }
}

# --- AC-28 (B27): the recovery primitives. ---
{
    # (a) _machine_state.
    my $ms = extract_sub_body($LSRC, 'sub _machine_state');
    ok(defined $ms, 'AC-28(a): sub _machine_state exists in launcher.pl');
    if (defined $ms) {
        src_like($ms, qr/machine\s+list\s+--format\s+json/, 'AC-28(a): _machine_state runs `machine list --format json`');
        src_like($ms, qr/_run_timed\s*\(/,                  'AC-28(a): _machine_state bounds the probe with _run_timed');
        src_like($ms, qr/SANDBOX_RECOVER_PROBE_TIMEOUT/,    'AC-28(a): the probe bound is env-overridable');
        src_like($ms, qr/eval\s*\{/,                        'AC-28(a): _machine_state wraps its JSON decode in eval');
        src_like($ms, qr/decode_json/,                      'AC-28(a): _machine_state decodes with decode_json');
        src_like($ms, qr/Running/,                          'AC-28(a): _machine_state reads the Running field');
        src_like($ms, qr/State|Status/,                     'AC-28(a): _machine_state also tolerates State/Status field names');
        for my $word (qw(running stopped absent unknown), 'n/a') {
            src_like($ms, qr/(['"])\Q$word\E\1/, "AC-28(a): _machine_state can return '$word'");
        }
    }
    else {
        for my $name ('runs `machine list --format json`', 'bounds the probe with _run_timed',
                      'the probe bound is env-overridable', 'wraps its JSON decode in eval',
                      'decodes with decode_json', 'reads the Running field',
                      'also tolerates State/Status field names') {
            fail("AC-28(a): _machine_state $name [sub not found]");
        }
        fail("AC-28(a): _machine_state can return each of running/stopped/absent/unknown/n/a [sub not found]");
    }

    my $rcb = extract_sub_body($LSRC, 'sub recover_container');

    # (b) the machine_start seam's bound.
    my $mstart = defined $rcb ? block_after($rcb, qr/\bmachine_start\s*=>/) : undef;
    ok(defined $mstart, 'AC-28(b): the machine_start production seam block is extractable');
    if (defined $mstart) {
        src_like($mstart, qr/_run_timed\s*\(/,                     'AC-28(b): machine_start bounds the start with _run_timed');
        src_like($mstart, qr/SANDBOX_RECOVER_MACHINE_TIMEOUT/,     'AC-28(b): the machine-start bound is env-overridable');
        src_like($mstart, qr/timeout\s*=>\s*1/,                    'AC-28(b): an undef _run_timed return maps to timeout => 1');
        src_like($mstart, qr/machine\s+start/,                     'AC-28(b): machine_start invokes `machine start`');
    }
    else {
        fail('AC-28(b): machine_start bounds the start with _run_timed');
        fail('AC-28(b): the machine-start bound is env-overridable');
        fail('AC-28(b): an undef _run_timed return maps to timeout => 1');
        fail('AC-28(b): machine_start invokes `machine start`');
    }

    # (c) the startup grace: the touch is the NEXT podman invocation after start.
    #     NOTE (red-team step 6, MINOR-2): the "10s startup grace" this used to
    #     cite does not exist -- container/heartbeat.sh:26-27 sets HB=600 and
    #     STARTUP_GRACE=600, i.e. TEN MINUTES, off by 60x. Only the LABEL below
    #     was corrected; the ordering it pins (touch immediately after start, no
    #     other podman call in between) is still correct and still required, and
    #     the assertion is byte-for-byte the one that shipped.
    my $cstart = defined $rcb ? block_after($rcb, qr/\bcontainer_start\s*=>/) : undef;
    ok(defined $cstart, 'AC-28(c): the container_start production seam block is extractable');
    if (defined $cstart) {
        my $inv = podman_invocations($cstart);
        cmp_ok(scalar(@$inv), '>=', 2, 'AC-28(c): the container_start seam makes at least two podman invocations');
        my $adjacent = 0;
        for my $k (0 .. $#$inv - 1) {
            next unless $inv->[$k]     =~ /\bstart\b/;
            next unless $inv->[$k + 1] =~ /touch/;
            next unless $inv->[$k + 1] =~ m{/tmp/\.launcher-alive};
            $adjacent = 1;
            last;
        }
        ok($adjacent,
            'AC-28(c): `touch /tmp/.launcher-alive` is the IMMEDIATELY NEXT podman invocation after the start (heartbeat.sh:26-27 -- HB=600/STARTUP_GRACE=600, a TEN-MINUTE grace)');
        src_like($cstart, qr/log_ev\s*\(\s*['"]container_start['"]/, 'AC-28(c): the container_start seam logs a container_start event');
    }
    else {
        fail('AC-28(c): the container_start seam makes at least two podman invocations');
        fail('AC-28(c): `touch /tmp/.launcher-alive` is the IMMEDIATELY NEXT podman invocation after the start (heartbeat.sh:26-27 -- HB=600/STARTUP_GRACE=600, a TEN-MINUTE grace)');
        fail('AC-28(c): the container_start seam logs a container_start event');
    }

    # heartbeat_reattach rides _heartbeat_once.
    my $hb = defined $rcb ? block_after($rcb, qr/\bheartbeat_reattach\s*=>/) : undef;
    if (defined $hb) {
        src_like($hb, qr/_heartbeat_once/, 'AC-28: the heartbeat_reattach seam calls _heartbeat_once');
    }
    else {
        fail('AC-28: the heartbeat_reattach seam calls _heartbeat_once');
    }

    # (d) the NARROWED pre-loop gone-exit in enter_dashboard.
    my $ed = extract_sub_body($LSRC, 'sub enter_dashboard');
    ok(defined $ed, 'AC-28(d): sub enter_dashboard exists in launcher.pl');
    if (defined $ed) {
        src_like($ed, qr/_heartbeat_once/, 'AC-28(d): enter_dashboard still probes with _heartbeat_once pre-loop');
        my $gi = re_pos($ed, qr/_heartbeat_once\s*\(\s*\)\s*eq\s*['"]gone['"]/);
        if ($gi < 0) { $gi = re_pos($ed, qr/['"]gone['"]/); }
        my $xi = ($gi >= 0) ? index($ed, 'exit', $gi) : -1;
        if ($gi >= 0 && $xi > $gi) {
            my $guard = substr($ed, $gi, $xi - $gi);
            src_like($guard, qr/classify_container_state/,
                'AC-28(d): the pre-loop exit is guarded by Dashboard::classify_container_state');
            src_like($guard, qr/_machine_state/,
                'AC-28(d): the pre-loop exit is guarded by a _machine_state reading');
            src_like($guard, qr/['"]absent['"]/,
                "AC-28(d): the guard exits only for a genuinely 'absent' container");
            src_like($guard, qr/['"]stopped['"]/,
                "AC-28(d): the guard does NOT exit when the machine is 'stopped'");
        }
        else {
            fail('AC-28(d): the pre-loop exit is guarded by Dashboard::classify_container_state');
            fail('AC-28(d): the pre-loop exit is guarded by a _machine_state reading');
            fail("AC-28(d): the guard exits only for a genuinely 'absent' container");
            fail("AC-28(d): the guard does NOT exit when the machine is 'stopped'");
        }
        src_like($ed, qr/recover_available/,
            'AC-28(d): the fall-through path logs a recover_available event instead of exiting');
    }
    else {
        fail('AC-28(d): enter_dashboard still probes with _heartbeat_once pre-loop');
        fail('AC-28(d): the pre-loop exit is guarded by Dashboard::classify_container_state');
        fail('AC-28(d): the pre-loop exit is guarded by a _machine_state reading');
        fail("AC-28(d): the guard exits only for a genuinely 'absent' container");
        fail("AC-28(d): the guard does NOT exit when the machine is 'stopped'");
        fail('AC-28(d): the fall-through path logs a recover_available event instead of exiting');
    }

    # plain_heartbeat_loop's 'gone' exit is explicitly OUT OF SCOPE (spec S9)
    # -- the non-TTY fallback has no [l] and must keep exiting.
    my $ph = extract_sub_body($LSRC, 'sub plain_heartbeat_loop');
    if (defined $ph) {
        src_like($ph, qr/\bexit\b/, 'AC-28: plain_heartbeat_loop keeps its own exit (out of scope, unchanged)');
        src_unlike($ph, qr/classify_container_state/,
            'AC-28: plain_heartbeat_loop is NOT retrofitted with the recover guard (out of scope)');
    }
    else {
        fail('AC-28: plain_heartbeat_loop keeps its own exit (out of scope, unchanged)');
        fail('AC-28: plain_heartbeat_loop is NOT retrofitted with the recover guard (out of scope)');
    }
}

# ===========================================================================
# PART 11 -- suite integration (AC-29)
#
# AC-29's substance ("run-tests.pl shows no NEW red attributable to this
# package") is a coordinator-side, whole-suite check -- the same convention
# t/46 used for its AC-22 and t/45 for its AC-27. What is mechanically
# assertable from inside this file is encoded here: that this file is picked
# up by the runner at all, and that t/46 is still on disk as a declared
# immutable oracle (i.e. this package did not "fix" its red by editing it).
# ===========================================================================
{
    my $runner = slurp("$TESTS_DIR/run-tests.pl");
    ok(length($runner) > 0, 'AC-29: tests/run-tests.pl is readable');
    src_like($runner, qr/glob\("\$Bin\/t\/\*\.t"\)/,
        'AC-29: run-tests.pl discovers every t/*.t, so t/47-lifecycle-relaunch.t joins the suite automatically');
    ok(-f "$Bin/47-lifecycle-relaunch.t", 'AC-29: t/47-lifecycle-relaunch.t is on disk under the discovered path');

    my $t46 = slurp("$Bin/46-lifecycle-stop.t");
    ok(length($t46) > 0, 'AC-29: t/46-lifecycle-stop.t is still present');
    src_like($t46, qr/IMMUTABLE ORACLE/,
        'AC-29: t/46 still declares itself the immutable oracle for s11 (this package did not rewrite it)');
    my $t25 = slurp("$Bin/25-dashboard.t");
    ok(length($t25) > 0, 'AC-29: t/25-dashboard.t is still present');
    src_like($t25, qr/loop: runs to max_ticks rather than a gone-exit/,
        'AC-29: t/25 still pins the non-exit-on-gone behaviour this package depends on (spec S2.9)');

    ok(-f $DASHBOARD_SRC, 'AC-29: Dashboard.pm is on disk');
    ok(-f $LAUNCHER_SRC,  'AC-29: launcher.pl is on disk');
    diag('AC-29: the whole-suite-green gate itself is a coordinator-side check (see this file\'s header).');
}

# ===========================================================================
# PART 12 -- red-team follow-up (step 6): the machine-state PARSE, the driver's
#            tolerance of a non-'stopped' machine reading, the stale-cache
#            skip, and the [l] cooldown.  (AC-31..AC-38)
#
# WHY THIS PART EXISTS. The step-6 red-team review found four MAJOR defects
# that a 651/651 green suite did not catch. All four live in `_machine_state`'s
# SELECTION and FIELD-READ logic and the decisions keyed off it -- and
# AC-28(a) above covers that logic by SOURCE TEXT only. Source text cannot
# tell `return 'running' if ANY machine is running` from `... if OUR machine
# is running`, and it cannot tell a `return 'unknown'` fall-through from a
# `return 'stopped'` one. This part supplies the missing BEHAVIOURAL oracle.
#
# ---------------------------------------------------------------------------
# WHAT THE IMPLEMENTER MUST EXPOSE (a requirement, not a suggestion)
# ---------------------------------------------------------------------------
# `_machine_state` lives in launcher.pl, which no test may require (spec
# S6/E2), so its parse can never be tested behaviourally where it sits. Split
# it: keep the impure shell (run the bounded probe) in launcher.pl, and move
# the PURE parse into a loadable helper:
#
#     Dashboard::classify_machine_state($raw, $capable) -> $state
#
#       $raw     the raw bytes of `podman machine list --format json`.
#                undef / '' are legal inputs: the probe failed or timed out.
#       $capable boolean -- does this platform HAVE a podman machine at all?
#                (false on docker, and on Linux-native podman)
#       $state   EXACTLY one of: running starting stopped absent unknown n/a
#
# The RECOMMENDED implementation is to delegate the selection to
# Resources::parse_machine_list (Resources.pm:97-114), which already picks the
# default machine correctly, already reads `Starting`, and already carries its
# own behavioural oracle in t/44-resources.t -- one parser, one schema
# assumption, one place to fix when podman renames a field. AC-31's control
# below demonstrates the precedent answering the killer case correctly today.
#
# Note for the implementer: AC-28(a) (unchanged, above) pins the TEXT of
# `_machine_state` -- `decode_json`, `Running`, `State|Status` and the five
# vocabulary literals. A delegating shell keeps those assertions green by
# documenting the delegated contract in its header comment; src_like() matches
# plain text. Do NOT weaken AC-28(a) to make the split easier.
# ===========================================================================

# --- machine-list fixtures. Shapes taken from podman's own
#     `machine list --format json` and from t/44's fixtures (44:62,114,117). --
my $MJ_DEFAULT_RUNNING =
    q{[{"Name":"podman-machine-default","Default":true,"Running":true,"Starting":false}]};
# THE KILLER CASE (MAJOR-1): two machines, the NON-default one running, OUR
# default one stopped. `podman machine start` (no name) acts on the default,
# so the reading must describe the default: 'stopped'.
my $MJ_TWO_DEFAULT_STOPPED =
    q{[{"Name":"dev","Default":false,"Running":true,"Starting":false},}
  . q{{"Name":"podman-machine-default","Default":true,"Running":false,"Starting":false}]};
my $MJ_TWO_DEFAULT_STOPPED_FIRST =
    q{[{"Name":"podman-machine-default","Default":true,"Running":false,"Starting":false},}
  . q{{"Name":"dev","Default":false,"Running":true,"Starting":false}]};
my $MJ_TWO_DEFAULT_RUNNING_LAST =
    q{[{"Name":"dev","Default":false,"Running":false,"Starting":false},}
  . q{{"Name":"podman-machine-default","Default":true,"Running":true,"Starting":false}]};
my $MJ_SINGLE_NO_DEFAULT   = q{[{"Name":"only-one","Running":true,"Starting":false}]};
my $MJ_NONHASH_FIRST       = q{["junk",{"Name":"m","Default":true,"Running":true}]};
my $MJ_STARTING            = q{[{"Name":"podman-machine-default","Default":true,"Running":false,"Starting":true}]};
my $MJ_STARTING_NOT_DEFAULT=
    q{[{"Name":"dev","Default":false,"Running":true,"Starting":false},}
  . q{{"Name":"podman-machine-default","Default":true,"Running":false,"Starting":true}]};
my $MJ_SCHEMA_DRIFT        = q{[{"Name":"m","Default":true,"VMState":"Up","LastUp":"2026-07-29T00:00:00Z"}]};
my $MJ_RUNNING_STR_FALSE   = q{[{"Name":"m","Default":true,"Running":"false"}]};
my $MJ_RUNNING_STR_TRUE    = q{[{"Name":"m","Default":true,"Running":"true"}]};
my $MJ_RUNNING_ZERO        = q{[{"Name":"m","Default":true,"Running":0}]};
my $MJ_STATE_RUNNING       = q{[{"Name":"m","Default":true,"State":"running"}]};
my $MJ_STATE_STOPPED       = q{[{"Name":"m","Default":true,"State":"stopped"}]};
my $MJ_STATUS_RUNNING      = q{[{"Name":"m","Default":true,"Status":"Running"}]};
my $MJ_STATUS_STOPPED      = q{[{"Name":"m","Default":true,"Status":"Stopped"}]};
my $MJ_EMPTY               = q{[]};
my $MJ_OBJECT              = q{{"Name":"m","Running":true}};
my $MJ_GARBAGE             = qq{Error: cannot connect to the podman socket\n};

# cms($raw,$capable): classify_machine_state does NOT EXIST YET. eval-wrapped
# (the rr() convention) so a missing sub is a clean per-assertion FAIL rather
# than a fatal abort, and a non-scalar return can never crash an is().
sub cms {
    my ($raw, $capable) = @_;
    my $v = eval { Dashboard::classify_machine_state($raw, $capable) };
    return (defined $v && !ref $v) ? $v : undef;
}

# --- AC-31 (MAJOR-1): the reading describes the DEFAULT machine, never "any". ---
{
    ok(defined &Dashboard::classify_machine_state,
        'AC-31: Dashboard::classify_machine_state is defined -- the PURE, loadable machine-state parse');

    # The killer case, in both element orders: a non-default machine is
    # running and OUR default machine is stopped.
    is(cms($MJ_TWO_DEFAULT_STOPPED, 1), 'stopped',
        "AC-31: two machines, non-default RUNNING + default STOPPED -> 'stopped' (never 'running')");
    is(cms($MJ_TWO_DEFAULT_STOPPED_FIRST, 1), 'stopped',
        "AC-31: same, default listed FIRST -> 'stopped' (selection is by Default, not by position)");
    is(cms($MJ_TWO_DEFAULT_RUNNING_LAST, 1), 'running',
        "AC-31: two machines, default RUNNING but listed LAST -> 'running' (position is irrelevant)");
    is(cms($MJ_DEFAULT_RUNNING, 1), 'running',
        "AC-31: the ordinary single default machine, running -> 'running'");
    is(cms($MJ_SINGLE_NO_DEFAULT, 1), 'running',
        "AC-31: no Default flag anywhere -> the FIRST hash element is read");
    is(cms($MJ_NONHASH_FIRST, 1), 'running',
        "AC-31: a non-hash list element is skipped when falling back to the first element");

    # Control: the in-repo precedent already answers the killer case
    # correctly over the identical bytes. This is why delegation is the
    # recommended fix rather than a second parser.
    my $have_res = eval { require Resources; 1 } ? 1 : 0;
    ok($have_res, 'AC-31: Resources.pm loads (the in-repo precedent for machine selection)');
    if ($have_res) {
        my $pick = eval { Resources::parse_machine_list($MJ_TWO_DEFAULT_STOPPED) };
        is(field($pick, 'name'), 'podman-machine-default',
            'AC-31 [precedent]: Resources::parse_machine_list picks the DEFAULT machine on the killer fixture');
        is(field($pick, 'running'), 0,
            'AC-31 [precedent]: ... and reports it NOT running, which is the answer this parse owes too');
    }
    else {
        fail('AC-31 [precedent]: Resources::parse_machine_list picks the DEFAULT machine on the killer fixture');
        fail('AC-31 [precedent]: ... and reports it NOT running, which is the answer this parse owes too');
    }
}

# --- AC-32 (MAJOR-2): the fall-through is 'unknown', and only a boolean-ish
#     Running is trusted. A confident-but-wrong 'stopped' puts a permanent red
#     "podman machine is stopped" banner over a healthy sandbox
#     (Dashboard.pm _status_alert checks the machine first, unconditionally). --
{
    is(cms($MJ_SCHEMA_DRIFT, 1), 'unknown',
        "AC-32: an element with NONE of Running/Starting/State/Status -> 'unknown', NEVER 'stopped'");
    is(cms($MJ_RUNNING_STR_FALSE, 1), 'stopped',
        qq{AC-32: Running as the STRING "false" reads as stopped (not Perl truthiness)});
    is(cms($MJ_RUNNING_STR_TRUE, 1), 'running',
        qq{AC-32: Running as the STRING "true" reads as running});
    is(cms($MJ_RUNNING_ZERO, 1), 'stopped',
        'AC-32: Running == 0 reads as stopped');
    is(cms($MJ_STATE_RUNNING, 1), 'running',
        qq{AC-32: a v5-shaped element carrying State:"running" -> 'running'});
    is(cms($MJ_STATE_STOPPED, 1), 'stopped',
        qq{AC-32: a v5-shaped element carrying State:"stopped" -> 'stopped'});
    is(cms($MJ_STATUS_RUNNING, 1), 'running',
        qq{AC-32: Status:"Running" -> 'running' (the field read is case-insensitive)});
    is(cms($MJ_STATUS_STOPPED, 1), 'stopped',
        qq{AC-32: Status:"Stopped" -> 'stopped'});

    is(cms($MJ_EMPTY, 1), 'absent',
        "AC-32: an EMPTY machine list -> 'absent' (no machine exists)");
    is(cms($MJ_GARBAGE, 1), 'unknown',
        "AC-32: undecodable probe output -> 'unknown'");
    is(cms($MJ_OBJECT, 1), 'unknown',
        "AC-32: a decodable NON-ARRAY (a JSON object) -> 'unknown'");
    is(cms('', 1), 'unknown',
        "AC-32: EMPTY probe output -> 'unknown'");
    is(cms(undef, 1), 'unknown',
        "AC-32: an UNDEF probe result (the probe died or timed out) -> 'unknown'");

    # n/a is a property of the PLATFORM, decided before the bytes are read.
    is(cms($MJ_DEFAULT_RUNNING, 0), 'n/a',
        "AC-32: a platform with no podman machine (docker / Linux-native) -> 'n/a' even for running-machine JSON");
    is(cms('', 0), 'n/a',
        "AC-32: 'n/a' wins over 'unknown' when the platform has no machine at all");

    # The whole vocabulary, and nothing outside it.
    my %vocab = map { $_ => 1 } qw(running starting stopped absent unknown n/a);
    my @out_of_vocab = grep { my $v = cms($_->[0], $_->[1]); !defined $v || !$vocab{$v} }
        ([$MJ_DEFAULT_RUNNING, 1], [$MJ_TWO_DEFAULT_STOPPED, 1], [$MJ_STARTING, 1],
         [$MJ_SCHEMA_DRIFT, 1], [$MJ_EMPTY, 1], [$MJ_GARBAGE, 1], [$MJ_OBJECT, 1],
         ['', 1], [undef, 1], [$MJ_DEFAULT_RUNNING, 0]);
    is(scalar(@out_of_vocab), 0,
        'AC-32: EVERY reading is one of running/starting/stopped/absent/unknown/n-a -- no other value escapes');
}

# --- AC-33 (MAJOR-3, probe half): 'starting' is read and is its OWN value. ---
{
    is(cms($MJ_STARTING, 1), 'starting',
        "AC-33: a STARTING default machine -> 'starting' (the host-resume case; Running is false while starting)");
    is(cms($MJ_STARTING_NOT_DEFAULT, 1), 'starting',
        "AC-33: the default machine is starting while another runs -> 'starting'");
    # Defined-checked rather than isnt(): an undef (missing-sub) reading must
    # FAIL these, not sail through on undef ne 'stopped'.
    my $st = cms($MJ_STARTING, 1);
    ok(defined $st && $st ne 'stopped',
        "AC-33: a starting machine is NEVER read as 'stopped' (that reading makes [l] fail with rc 125)");
    ok(defined $st && $st ne 'running',
        "AC-33: ... and NEVER as 'running' either -- 'starting' is a distinct value");
}

# --- AC-34 (MAJOR-3, driver half): 'starting' skips machine-start exactly as
#     'running' does. `podman machine start` against a VM that is already
#     running OR ALREADY STARTING exits 125, and that failure would abort the
#     whole recovery at stage 2. -------------------------------------------
{
    my %state = (machine_capable => 1, status => 'exited');
    my ($seams, $calls) = build_seams(
        machine_status => sub { { ok => 1, state => 'starting', detail => 'machine starting' } },
    );
    my $r = rr(plan => plan_for(\%state), mode => 'recover', reason => 'in-tui-relaunch',
               state => \%state, %$seams);

    is_deeply($calls, [qw(machine_status container_start heartbeat_reattach)],
        "AC-34: a 'starting' machine -- machine_start is NEVER invoked, the sequence continues");
    my $ms = stage_of($r, 'machine-start');
    is(field($ms, 'state'), 'skipped', "AC-34: the machine-start stage is 'skipped' (as it is for 'running')");
    like_or_fail(field($ms, 'detail'), qr/starting/i,
        'AC-34: the machine-start detail says the machine is already starting');
    is(field($r, 'ok'), 1, 'AC-34: ok == 1');
    is(field($r, 'failed_stage'), undef, 'AC-34: failed_stage is undef');
    is(stage_count($r), 4, 'AC-34: all four planned stages are still recorded');
    is(field(stage_of($r, 'container-start'), 'state'), 'ok', 'AC-34: container-start actually ran and is ok');
    is(field(stage_of($r, 'heartbeat-reattach'), 'state'), 'ok', 'AC-34: heartbeat-reattach actually ran and is ok');
}

# --- AC-35 (MAJOR-3, driver half): a machine-start FAILURE is fatal only on a
#     CONFIDENT 'stopped' reading. On 'unknown' the recovery must continue --
#     container-start is the authoritative test of whether the machine is up,
#     and an uncertain reading must never block the repair. ------------------
{
    # (a) 'unknown' + failing machine_start -> NOT fatal, sequence continues.
    my %state = (machine_capable => 1, status => 'exited');
    my ($seams, $calls) = build_seams(
        machine_status => sub { { ok => 1, state => 'unknown', detail => 'machine probe inconclusive' } },
        machine_start  => sub { { ok => 0, detail => 'MSTARTFAIL rc 125: VM already running or starting' } },
    );
    my ($r, $err) = rre(plan => plan_for(\%state), mode => 'recover', reason => 'in-tui-relaunch',
                        state => \%state, %$seams);

    ok(!$err, 'AC-35(a): the run does not die') or diag("  \$\@ = " . ($err // ''));
    is_deeply($calls, [qw(machine_status machine_start container_start heartbeat_reattach)],
        "AC-35(a): 'unknown' machine + FAILED machine start -> container_start and heartbeat_reattach STILL run");
    my $ms = stage_of($r, 'machine-start');
    isnt(field($ms, 'state'), 'fail',
        "AC-35(a): the machine-start stage is NOT 'fail' on an uncertain reading (it must not abort the sequence)");
    ok(defined field($ms, 'state') && (field($ms, 'state') eq 'skipped' || field($ms, 'state') eq 'ok'),
        "AC-35(a): the machine-start stage is recorded non-fatally ('skipped' or 'ok')");
    like_or_fail(field($ms, 'detail'), qr/MSTARTFAIL/,
        'AC-35(a): the failed start is still REPORTED -- its detail is carried, not swallowed');
    is(field($r, 'failed_stage'), undef, 'AC-35(a): failed_stage is undef (nothing fatal happened)');
    is(field($r, 'ok'), 1, 'AC-35(a): ok == 1 -- the container came up, which is what [l] exists for');
    is(stage_count($r), 4, 'AC-35(a): all four stages are recorded');
    is(field(stage_of($r, 'container-start'), 'state'), 'ok', 'AC-35(a): container-start ran and is ok');

    # (b) control: a CONFIDENT 'stopped' + failing machine_start IS fatal --
    #     we know the machine is down and we could not start it.
    my %state_b = (machine_capable => 1, status => 'exited');
    my ($seams_b, $calls_b) = build_seams(
        machine_status => sub { { ok => 1, state => 'stopped', detail => 'machine stopped' } },
        machine_start  => sub { { ok => 0, detail => 'MSTARTFAIL no machine' } },
    );
    my $rb = rr(plan => plan_for(\%state_b), mode => 'recover', reason => 'in-tui-relaunch',
                state => \%state_b, %$seams_b);
    is_deeply($calls_b, [qw(machine_status machine_start)],
        "AC-35(b): a CONFIDENT 'stopped' + failed start still stops the sequence");
    is(field(stage_of($rb, 'machine-start'), 'state'), 'fail', "AC-35(b): that stage IS 'fail'");
    is(field($rb, 'failed_stage'), 'machine-start', "AC-35(b): failed_stage eq 'machine-start'");
    is(field($rb, 'ok'), 0, 'AC-35(b): ok == 0');
}

# --- AC-36 (MINOR-3): no stale-cache skip. $state->{status} is the launcher's
#     THROTTLED 10s inspect cache; a container that died inside that window
#     still reads 'running'. The driver must not skip container-start on a
#     reading it knows may be out of date -- the seam re-probes authoritatively.
#
#     HOW THIS IS EXPRESSED, and why. AC-12 above (immutable, passing) pins the
#     opposite for a status of 'running' with no freshness marker, so an
#     unconditional removal of the shortcut cannot be asserted here without
#     breaking it. The testable form is therefore an EXPLICIT staleness signal:
#     state->{status_stale} => 1 means "this status is a cache reading, do not
#     trust it to skip work". An implementer who has launcher.pl set
#     status_stale => 1 on every cached gather gets MINOR-3's production effect
#     (always re-probe) while AC-12 -- which passes no such flag -- keeps
#     passing unchanged. The conflict is reported in testwriter-step7.md. -----
{
    my %state = (machine_capable => 1, status => 'running', status_stale => 1);
    my ($seams, $calls) = build_seams(
        machine_status  => sub { { ok => 1, state => 'running', detail => 'machine running' } },
        container_start => sub { { ok => 1, detail => 'container started' } },
    );
    my $r = rr(plan => plan_for(\%state), mode => 'recover', reason => 'in-tui-relaunch',
               state => \%state, %$seams);

    ok((grep { $_ eq 'container_start' } @$calls),
        'AC-36: a STALE cached status of "running" does NOT skip container-start -- the seam IS invoked');
    is_deeply($calls, [qw(machine_status container_start heartbeat_reattach)],
        'AC-36: the full order still holds with the stale marker set');
    my $cs = stage_of($r, 'container-start');
    isnt(field($cs, 'state'), 'skipped',
        'AC-36: the container-start stage is NOT reported skipped off a stale cache');
    is(field($cs, 'state'), 'ok', 'AC-36: it is reported from the SEAM\'s own outcome instead');
    like_or_fail(field($cs, 'detail'), qr/container started/i,
        'AC-36: the detail is the seam\'s, not the cache\'s "container already running"');
    is(field($r, 'ok'), 1, 'AC-36: ok == 1');
}

# --- AC-37 (MINOR-1): a wall-clock cooldown on the recover ACTION. "ly" is one
#     of the commonest digraphs in English (only/really/finally), so a pasted
#     paragraph fires one full recovery per occurrence, back to back, each
#     freezing the TUI. The cooldown is what makes the deferred paste-bypass
#     risk (R3) priced correctly. The window must be INJECTABLE so this test
#     never sleeps: Dashboard::run takes recover_cooldown => SECONDS, read
#     through the SAME now() seam the loop already uses (drive3's fake clock).
{
    # Control first: with the cooldown disabled, this key sequence really does
    # deliver TWO confirmed recoveries. Without this control the suppression
    # assertion below would pass vacuously.
    my $ctl = drive3(keys => ['l', 'y', undef, 'l', 'y', 'q'], max_ticks => 50,
                     recover_cooldown => 0);
    ok(!$ctl->{err}, 'AC-37 [control]: run does not die with recover_cooldown => 0') or diag("  \$\@ = $ctl->{err}");
    is($ctl->{recover_calls}, 2,
        'AC-37 [control]: with the cooldown at 0, two confirmed [l][y] pairs fire TWO recoveries');

    # Within the window: the second confirmed recover is a NO-OP.
    my $near = drive3(keys => ['l', 'y', undef, 'l', 'y', 'q'], max_ticks => 50,
                      tick_interval => 0.25, recover_cooldown => 30);
    ok(!$near->{err}, 'AC-37: run does not die with a cooldown set') or diag("  \$\@ = $near->{err}");
    is($near->{recover_calls}, 1,
        'AC-37: a second confirmed recover INSIDE the cooldown window is a no-op (the seam is not called again)');
    is($near->{rc}, 0, 'AC-37: the suppressed recover does not end the loop -- a later q still returns rc 0');
    is($near->{left}, 1, 'AC-37: the terminal is still restored exactly once');

    # Past the window: it proceeds. Each fake tick advances 20s, so the second
    # press lands >30s later WITHOUT any real sleeping.
    my $far = drive3(keys => ['l', 'y', undef, undef, undef, 'l', 'y', 'q'], max_ticks => 50,
                     tick_interval => 20, recover_cooldown => 30);
    ok(!$far->{err}, 'AC-37: run does not die across the cooldown boundary') or diag("  \$\@ = $far->{err}");
    is($far->{recover_calls}, 2,
        'AC-37: a recover fired AFTER the cooldown has elapsed proceeds normally');

    # And the cooldown is ON by default -- a caller that passes no window at
    # all still gets amplification protection.
    my $dflt = drive3(keys => ['l', 'y', undef, 'l', 'y', 'q'], max_ticks => 50, tick_interval => 0.25);
    is($dflt->{recover_calls}, 1,
        'AC-37: the cooldown DEFAULT is non-zero -- back-to-back confirms are suppressed without configuring anything');
}

# --- AC-38: launcher.pl keeps only the impure shell (source-text, PART 10
#     convention). This is the wiring half of the seam AC-31..AC-33 test. ----
{
    my $ms = extract_sub_body($LSRC, 'sub _machine_state');
    ok(defined $ms, 'AC-38: sub _machine_state still exists in launcher.pl');
    if (defined $ms) {
        src_like($ms, qr/Dashboard::classify_machine_state|Resources::parse_machine_list/,
            'AC-38: _machine_state delegates its PARSE to a loadable pure helper '
          . '(Dashboard::classify_machine_state, or Resources::parse_machine_list) instead of open-coding a second parser');
    }
    else {
        fail('AC-38: _machine_state delegates its PARSE to a loadable pure helper');
    }
}

done_testing();
