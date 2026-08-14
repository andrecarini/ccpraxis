#!/usr/bin/env perl
# 150-continuity-gate.t -- g01-explicit-continuity-arming, THE STOP GATE:
# gate-continuity.sh plus its reap, and the mark-wakeup.sh extension that
# feeds it.
#
# Spec: specs/g01-explicit-continuity-arming-spec.md SS2.3 (registry/reap),
# SS2.4 (mark-wakeup.sh extension), SS2.5 (gate-continuity.sh pseudocode),
# SS3 behaviors 9-15, SS4 AC-5/AC-6/AC-9/AC-10/AC-11. Written BLIND to
# plugins/butler/hooks/gate-continuity.sh (does not exist) and to lib.sh's
# continuity additions -- every expectation is transcribed from the spec's
# pseudocode and acceptance criteria, not inferred from any implementation.
#
# THE ASSERTION THIS PACKAGE MOST NEEDS is section E below (AC-5 / criterion
# 2 / criterion 6's "stale/abandoned arm reaped without its owner returning"):
# a marker owned by a session id that NEVER appears again in this file is
# reaped by a DIFFERENT session's Stop. This is the ledger's own cited defect
# (lib.sh:398-409 -- three markers 55h old survived three consecutive stops
# because the per-session TTL check only ran for the session whose id
# matched, and a dead session never returns to reap its own).
#
# AC-6 (criterion 3): no fixture in this file ever stubs or requires
# bp-drive-next.pl or branches on BP_LEDGER's presence to decide GATE
# behavior (BP_LEDGER is asserted only as the top-of-file short-circuit,
# section D, which is the opposite of a director consult) -- proving this is
# the new, director-free gate, not a re-arming of gate-drive-loop.sh.
#
# NEVER points at real state: CCPRAXIS_CONTINUITY_ACTIVE_DIR and
# CCPRAXIS_DATA_DIR are always fresh File::Temp tempdirs.
#
# Every hook payload below is built with JSON::PP->new->canonical->encode,
# never string interpolation -- see 142-reporter-registration.t's own header
# note on why a hand-interpolated payload is a malformed-fixture hazard.
#
# Runs standalone: perl plugins/butler/tests/t/150-continuity-gate.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP;

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $GATE  = "$HOOKS/gate-continuity.sh";

ok(-f $MARK,  'A1: mark-wakeup.sh exists') or BAIL_OUT('hook missing');
ok(-f $GATE,  'A2: gate-continuity.sh exists') or BAIL_OUT('new gate missing -- nothing else here can run');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub new_project {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

sub run_mark {
    my ($payload, %opt) = @_;
    my $env = '';
    $env .= "CCPRAXIS_CONTINUITY_ACTIVE_DIR='$opt{cdir}' " if defined $opt{cdir};
    $env .= "CCPRAXIS_DRIVE_ACTIVE_DIR='$opt{ddir}' "      if defined $opt{ddir};
    my $out = `${env}bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub run_gate {
    my ($payload, %opt) = @_;
    my $env = '';
    $env .= "CCPRAXIS_CONTINUITY_ACTIVE_DIR='$opt{cdir}' " if defined $opt{cdir};
    $env .= "CCPRAXIS_CONTINUITY_STOP_OK=1 "                if $opt{stop_ok};
    $env .= "CCPRAXIS_CONTINUITY_TTL_H=$opt{ttl_h} "        if defined $opt{ttl_h};
    $env .= "BP_LEDGER='$opt{bp_ledger}' "                  if defined $opt{bp_ledger};
    my $out = `${env}bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub stop_payload {
    my ($cwd, $sid) = @_;
    return JSON::PP->new->canonical->encode({ session_id => $sid, cwd => $cwd });
}

sub task_dispatch_payload {
    my ($cwd, $sid) = @_;
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Task',
        tool_input => { description => 'do something', prompt => 'go' },
    });
}

sub backgrounded_bash_payload {
    my ($cwd, $sid) = @_;
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => 'sleep 300', run_in_background => JSON::PP::true },
    });
}

sub marker_path { my ($cdir, $sid) = @_; return "$cdir/$sid"; }

# Plant a marker directly (bypassing arm/mark-wakeup), for fixtures that need
# precise control over mtime/content -- mirrors 143-reporter-stop-gate.t's
# own direct-plant technique for TTL/staleness fixtures.
sub plant_marker {
    my ($cdir, $sid, %opt) = @_;
    make_path($cdir);
    my $path = marker_path($cdir, $sid);
    open my $fh, '>', $path or die "plant $path: $!";
    print {$fh} ($opt{content} // "agent 2026-01-01T00:00:00Z\n");
    close $fh;
    if (defined $opt{age_hours}) {
        my $t = time() - int($opt{age_hours} * 3600);
        utime($t, $t, $path) or diag("utime failed: $!");
    }
    return $path;
}

# ===========================================================================
# B. Behavior 11 / AC-9: an armed session's Stop, immediately after a Task
#    dispatch recorded via the EXTENDED mark-wakeup.sh, is ALLOWED --
#    .wakeup-pending consumed.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-b');

    my ($mrc, $mout) = run_mark(task_dispatch_payload($root, 'sess-b'), cdir => $cdir);
    is($mrc, 0, 'B0 setup: mark-wakeup.sh never blocks on a Task dispatch');
    ok(-f marker_path($cdir, 'sess-b') . '.wakeup-pending',
       'B1 CANONICAL (-> SS2.4): a Task dispatch writes the continuity wake-up-pending file, '
     . 'INDEPENDENT of any .drive-solo directory existing -- this session has none');

    my ($rc, $out) = run_gate(stop_payload($root, 'sess-b'), cdir => $cdir);
    is($rc, 0, 'B2 CANONICAL (-> AC-9/behavior 10): the armed session'."'".'s Stop, right after '
             . 'a Task dispatch, is ALLOWED');
    ok(!-f marker_path($cdir, 'sess-b') . '.wakeup-pending',
       'B3 CANONICAL: the wake-up-pending file is CONSUMED (removed) by the allowing Stop');
}

# ===========================================================================
# C. Behavior 11 / AC-9 continued, backgrounded Bash variant.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-c');

    my ($mrc) = run_mark(backgrounded_bash_payload($root, 'sess-c'), cdir => $cdir);
    is($mrc, 0, 'C0 setup: mark-wakeup.sh never blocks on a backgrounded Bash call');
    ok(-f marker_path($cdir, 'sess-c') . '.wakeup-pending',
       'C1 CANONICAL: a run_in_background:true Bash call ALSO writes the continuity '
     . 'wake-up-pending file, independent of .drive-solo');

    my ($rc, $out) = run_gate(stop_payload($root, 'sess-c'), cdir => $cdir);
    is($rc, 0, 'C2 CANONICAL (-> AC-9): armed session'."'".'s Stop after a backgrounded Bash '
             . 'call is ALLOWED');
}

# ===========================================================================
# C2. Negative pairing for B/C: a FOREGROUND Bash call must NOT write the
#     wake-up-pending file -- the same false-positive discipline
#     mark-wakeup.sh already applies for the drive-solo path.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-c2');
    my $payload = JSON::PP->new->canonical->encode({
        session_id => 'sess-c2', cwd => $root, tool_name => 'Bash',
        tool_input => { command => 'ls', run_in_background => JSON::PP::false },
    });
    my ($mrc) = run_mark($payload, cdir => $cdir);
    is($mrc, 0, 'C2a setup: mark-wakeup.sh never blocks on a foreground Bash call');
    ok(!-f marker_path($cdir, 'sess-c2') . '.wakeup-pending',
       'C2b CANONICAL: a FOREGROUND Bash call (run_in_background:false) does NOT write the '
     . 'continuity wake-up-pending file -- proves the trigger is the boolean, not merely '
     . '"any Bash call"');
}

# ===========================================================================
# D. AC-6 (criterion 3): armed session's Stop with NO wake-up recorded is
#    BLOCKED, up to 3 consecutive times, then auto-allowed on the 4th with
#    .stop-blocks reset (behavior 13 / AC-10). No fixture in this section
#    stubs bp-drive-next.pl or reads BP_LEDGER as a branching signal for
#    behavior (only as the top-of-file coordinator short-circuit, section G).
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-d');

    my ($rc1, $out1) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc1, 2, 'D1 CANONICAL (-> behavior 9/AC-6): 1st Stop with no wake-up pending is '
              . 'BLOCKED -- exit 2');
    like($out1, qr/(?:dispatch|background)/i,
       'D1a: the block text names a remedy verb (dispatch/background)');
    like($out1, qr/disarm/i, 'D1b: the block text names disarm as a remedy');
    like($out1, qr/stop-ok/, 'D1c: the block text names the one-shot .stop-ok escape hatch');

    my ($rc2) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc2, 2, 'D2: 2nd consecutive Stop also blocked');
    my ($rc3) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc3, 2, 'D3: 3rd consecutive Stop also blocked');
    my ($rc4, $out4) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc4, 0, 'D4 CANONICAL (-> AC-10/behavior 13): the 4th consecutive Stop is ALLOWED -- '
              . 'the block is bounded, never a trap');
    ok(!-f marker_path($cdir, 'sess-d') . '.stop-blocks',
       'D5 CANONICAL: .stop-blocks is RESET (removed) once the bound is hit');

    my ($rc5) = run_gate(stop_payload($root, 'sess-d'), cdir => $cdir);
    is($rc5, 2, 'D6 CANONICAL: after the reset, the counter starts over -- the 5th call '
              . '(1st after reset) is blocked again, proving D4 was a bounded escape, not a '
              . 'permanent disarm');
}

# ===========================================================================
# E. *** THE ASSERTION THIS PACKAGE MOST NEEDS *** -- AC-5 / criterion 2 /
#    criterion 6: a stale marker owned by session X, mtime forced to
#    now-(TTL+1)h, with NO marker for session Y (the one invoking the gate),
#    is REMOVED (with its companions) by session Y's Stop -- and does NOT
#    block Y. Session X's id NEVER appears anywhere else in this file: it is
#    constructed once here and never returns, by design, to prove the reap
#    does not depend on the owner coming back.
# ===========================================================================
{
    my $root_x = new_project();       # X's own (abandoned) project, never revisited
    my $cdir   = tempdir(CLEANUP => 1);
    my $ttl_h  = 12;
    plant_marker($cdir, 'sess-X-abandoned-forever', age_hours => $ttl_h + 1);
    for my $suffix (qw(.wakeup-pending .stop-blocks .stop-ok)) {
        open my $fh, '>', marker_path($cdir, 'sess-X-abandoned-forever') . $suffix or die $!;
        close $fh;
    }
    ok(-f marker_path($cdir, 'sess-X-abandoned-forever'), 'E0a setup: X'."'".'s marker exists, aged past TTL');
    for my $suffix (qw(.wakeup-pending .stop-blocks .stop-ok)) {
        ok(-f marker_path($cdir, 'sess-X-abandoned-forever') . $suffix, "E0b setup: X's $suffix companion exists");
    }
    ok(!-f marker_path($cdir, 'sess-Y-the-reaper'), 'E0c setup: Y has never been armed');

    my $root_y = new_project();       # a DIFFERENT project -- Y's Stop, not X's
    my ($rc, $out) = run_gate(stop_payload($root_y, 'sess-Y-the-reaper'), cdir => $cdir, ttl_h => $ttl_h);

    is($rc, 0, 'E1 CANONICAL (-> AC-5): session Y'."'".'s Stop is NOT blocked -- Y was never '
             . 'armed, so the gate must be a pure no-op for Y regardless of what it reaps');
    ok(!-f marker_path($cdir, 'sess-X-abandoned-forever'),
       'E2 *** THE CANONICAL ASSERTION *** (-> criterion 2/6, closes lib.sh:398-409): X'."'".'s '
     . 'primary marker is GONE after Y'."'".'s Stop -- X never returned; Y'."'".'s Stop is what '
     . 'reaped it. An implementation whose reap only runs for the session whose id matches a '
     . 'marker (the exact historical defect) leaves this file un-removed and fails here.');
    for my $suffix (qw(.wakeup-pending .stop-blocks .stop-ok)) {
        ok(!-f marker_path($cdir, 'sess-X-abandoned-forever') . $suffix,
           "E3 CANONICAL: X's $suffix companion is ALSO removed by the same sweep");
    }
}

# ===========================================================================
# F. Behavior 12 negative pairing / AC-6: an UNARMED session's Stop is a
#    pure no-op beyond the cheap pre-check -- no marker, no companions, no
#    side effects for a session that was never armed at all (own project,
#    own registry, nothing planted).
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);   # exists but empty -- no markers at all
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-f-never-armed'), cdir => $cdir);
    is($rc, 0, 'F1 CANONICAL (-> behavior 11): an unarmed session'."'".'s Stop exits 0 with no '
             . 'side effects');
    ok(!-f marker_path($cdir, 'sess-f-never-armed'),
       'F2: no marker was created for the never-armed session as a side effect');
}

# ===========================================================================
# G. BP_LEDGER short-circuit (spec SS2.5 top-of-file, edge case list): a
#    coordinator's Stop exits 0 UNCONDITIONALLY, even with a live, blocking
#    marker for that exact session id present. This is the ONLY place
#    BP_LEDGER is read in this whole file (AC-6's own discipline).
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-g-coordinator');   # would otherwise block (fresh, no wake-up)
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-g-coordinator'),
                               cdir => $cdir, bp_ledger => '/fake/ledger.md');
    is($rc, 0, 'G1 CANONICAL (-> edge cases SS5): BP_LEDGER set exits 0 unconditionally, '
             . 'before the marker is even consulted -- defense in depth alongside arm'."'".'s '
             . 'own refusal');
}

# ===========================================================================
# H. CCPRAXIS_CONTINUITY_STOP_OK=1 session-wide hatch (behavior 15) -- every
#    Stop of that session allowed unconditionally, marker untouched.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-h');
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-h'), cdir => $cdir, stop_ok => 1);
    is($rc, 0, 'H1 CANONICAL (-> behavior 15): CCPRAXIS_CONTINUITY_STOP_OK=1 allows the stop '
             . 'even with a fresh, otherwise-blocking marker');
}

# ===========================================================================
# I. One-shot .stop-ok escape hatch (behavior 14) -- consumed on use, session
#    remains armed afterward (marker itself still present).
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    plant_marker($cdir, 'sess-i');
    open my $fh, '>', marker_path($cdir, 'sess-i') . '.stop-ok' or die $!;
    close $fh;

    my ($rc, $out) = run_gate(stop_payload($root, 'sess-i'), cdir => $cdir);
    is($rc, 0, 'I1 CANONICAL (-> behavior 14): the one-shot .stop-ok file allows the stop');
    ok(!-f marker_path($cdir, 'sess-i') . '.stop-ok',
       'I2 CANONICAL: ...and is CONSUMED -- an operator override applies once');
    ok(-f marker_path($cdir, 'sess-i'),
       'I3: the session REMAINS armed afterward -- the primary marker survives the one-shot '
     . 'hatch, unlike a full disarm');
}

# ===========================================================================
# J. TTL reap of the CALLING session's OWN marker (belt-to-braces per SS2.5's
#    per-marker check, distinct from E's cross-session sweep): a session
#    whose OWN marker has aged past the TTL is allowed, and its own marker is
#    removed too.
# ===========================================================================
{
    my $root = new_project();
    my $cdir = tempdir(CLEANUP => 1);
    my $ttl_h = 12;
    plant_marker($cdir, 'sess-j-self-stale', age_hours => $ttl_h + 1);

    my ($rc, $out) = run_gate(stop_payload($root, 'sess-j-self-stale'), cdir => $cdir, ttl_h => $ttl_h);
    is($rc, 0, 'J1 CANONICAL (-> SS2.5 per-marker TTL): a session whose own marker is older '
             . 'than the TTL is ALLOWED to stop');
    ok(!-f marker_path($cdir, 'sess-j-self-stale'),
       'J2: ...and its own now-expired marker is removed too');
}

# ===========================================================================
# K. fix-batch F1: with CCPRAXIS_CONTINUITY_ACTIVE_DIR unset AND $HOME/
#    $USERPROFILE also unset for the gate's own process, bp_continuity_active_dir
#    (lib.sh) cannot resolve a directory at all. The gate must FAIL SAFE --
#    exit 0, no crash, no block -- rather than either guessing $PWD (the
#    pre-fix behavior) or dying. This is the READ-side half of F1's rule:
#    unresolvable degrades to "nothing armed", never a hard failure.
# ===========================================================================
{
    my $root = new_project();
    local %ENV = %ENV;
    delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    delete $ENV{HOME};
    delete $ENV{USERPROFILE};
    my $payload = stop_payload($root, 'sess-k-unresolvable');
    my $out = `bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    my $rc = $? >> 8;
    is($rc, 0, 'K1 CANONICAL (-> fix-batch F1): gate-continuity.sh with no resolvable registry '
             . 'directory anywhere (CCPRAXIS_CONTINUITY_ACTIVE_DIR, $HOME, $USERPROFILE all '
             . 'unset) exits 0 -- fails safe, never blocks, never crashes');
}

# ===========================================================================
# K2. fix-batch F1, DISCRIMINATING probe: K1 alone cannot distinguish "truly
#    unresolvable" from "silently resolved under $PWD, which happened to be
#    empty" -- both exit 0. Call bp_continuity_active_dir DIRECTLY (source
#    lib.sh) with the same env and assert it returns 1 with EMPTY stdout --
#    proves the function itself refuses to guess $PWD, not merely that the
#    gate's overall behavior happens to still be harmless.
# ===========================================================================
{
    local %ENV = %ENV;
    delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    delete $ENV{HOME};
    delete $ENV{USERPROFILE};
    my ($pfh, $ppath) = tempfile(SUFFIX => '.sh');
    print {$pfh} <<"PROBE_EOF";
set -u
source '$HOOKS/lib.sh' 2>/dev/null || exit 3
out=\$(bp_continuity_active_dir)
rc=\$?
printf 'RC=%s OUT=[%s]\\n' "\$rc" "\$out"
PROBE_EOF
    close $pfh;
    my $out = `bash "$ppath" 2>&1`;
    unlink $ppath;
    like($out, qr/RC=1 OUT=\[\]/,
       'K2 CANONICAL (-> fix-batch F1): bp_continuity_active_dir itself returns 1 with EMPTY '
     . 'stdout when CCPRAXIS_CONTINUITY_ACTIVE_DIR, $HOME and $USERPROFILE are all unset -- an '
     . 'implementation that falls back to $PWD (the pre-fix behavior) would print a non-empty '
     . 'path and return 0 here, passing K1 by accident while still failing this');
}

done_testing();
