#!/usr/bin/env perl
# 143-reporter-stop-gate.t — g03-reporter-stop-gate, PILLARS 2 and 4: the gate
# FIRES for a registered reporter and does NOT fire for a non-reporter, both
# directions exercised end to end; and the refusal names the REPORTER's own
# remedy, never the driver's.
#
# Spec: specs/g03-reporter-stop-gate-spec.md §1.4 (Decision 4 -> DC3), §2.2
# (gate-drive-loop.sh reporter branch), §3 behaviors 2-8, §4 AC2/AC3/AC4/AC8.
#
# AC8, quoted directly, is the governing discipline for this whole file: "an
# oracle that only greps gate-drive-loop.sh's source for the string
# 'reporter' passes trivially and proves nothing; explicitly forbidden, per
# the task's own g02 precedent." Every assertion below invokes mark-wakeup.sh
# and gate-drive-loop.sh as REAL subprocesses with constructed JSON payloads
# on stdin and reads the REAL exit code -- never a source grep as the oracle
# for behavior (source is only inspected in section H, to pin the vocabulary
# of the message, never as a substitute for exercising it).
#
# NON-VACUITY. Every BLOCK assertion is paired with an exit-code check AND
# (where the fixture claims content) a content check, per the dispatch
# prompt's instruction that a gate oracle is especially exposed to "passing
# because the hook exited early and printed nothing".
#
# Runs standalone: perl plugins/butler/tests/t/143-reporter-stop-gate.t
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;

my $HOOKS = "$Bin/../../hooks";
my $MARK  = "$HOOKS/mark-wakeup.sh";
my $GATE  = "$HOOKS/gate-drive-loop.sh";
my $RS    = "$Bin/../../scripts/bp-runstate.pl";

ok(-f $MARK, 'A1: mark-wakeup.sh exists') or BAIL_OUT('hook missing');
ok(-f $GATE, 'A2: gate-drive-loop.sh exists') or BAIL_OUT('hook missing');
ok(-f $RS,   'A3: bp-runstate.pl exists') or BAIL_OUT('state machine missing');

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
sub new_project {
    my $root = tempdir(CLEANUP => 1);
    make_path("$root/.ccpraxis-local-data");
    return $root;
}

sub run_mark {
    my ($payload, $rdir) = @_;
    my $out = `CCPRAXIS_REPORTER_ACTIVE_DIR='$rdir' bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub run_gate {
    my ($payload, %opt) = @_;
    my $env = '';
    $env .= "CCPRAXIS_REPORTER_ACTIVE_DIR='$opt{rdir}' " if defined $opt{rdir};
    $env .= "CCPRAXIS_REPORTER_STOP_OK=1 "               if $opt{reporter_stop_ok};
    $env .= "CCPRAXIS_DRIVE_STOP_OK=1 "                  if $opt{drive_stop_ok};
    $env .= "CCPRAXIS_REPORTER_TTL_H=$opt{ttl_h} "       if defined $opt{ttl_h};
    my $out = `${env}bash "$GATE" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

# Built with a real JSON encoder (not string interpolation) so $cmd's
# embedded quotes are escaped exactly as the real harness escapes them --
# see 142-reporter-registration.t's own header note; the same fixture defect
# (unescaped quotes producing a malformed document) applied here too.
sub reporter_arm_payload {
    my ($cwd, $sid) = @_;
    my $cmd = q{perl "${CLAUDE_PLUGIN_ROOT}"/scripts/bp-watch.pl --arm --blueprint bp-x }
            . q{--pid-file bp-x/runs/.orchestrator --max-seconds 1800};
    return JSON::PP->new->canonical->encode({
        session_id => $sid, cwd => $cwd, tool_name => 'Bash',
        tool_input => { command => $cmd },
    });
}

sub stop_payload { my ($cwd, $sid) = @_; return qq({"session_id":"$sid","cwd":"$cwd"}); }

# Register a reporter session THROUGH the real mark-wakeup.sh subprocess
# (AC8's own requirement), returning the project root and RDIR to reuse.
sub registered_reporter {
    my ($sid) = @_;
    $sid //= 'sess-stop-under-test';
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);
    my ($mrc) = run_mark(reporter_arm_payload($root, $sid), $rdir);
    return ($root, $rdir, $sid, $mrc);
}

sub pause_reporter {
    my ($root, $pid, $until, %opt) = @_;
    my $reason = $opt{reason} // 'bp-watch.pl armed';
    return system(qq{perl "$RS" pause --surface reporter --watcher-pid $pid --until $until }
                . qq{--reason "$reason" --root "$root" >/dev/null 2>&1});
}

sub runstate_reporter_path {
    my ($root) = @_;
    return "$root/.ccpraxis-local-data/.subagent-guard/run-state.reporter.json";
}

# ===========================================================================
# B. AC2 (-> DC2): a registered reporter with NO bp-runstate.pl call at all
#    (state file absent -> inert) is REFUSED on Stop. Exit code asserted, not
#    merely stderr content.
# ===========================================================================
{
    my ($root, $rdir, $sid, $mrc) = registered_reporter('sess-b');
    is($mrc, 0, 'B0 setup: registration call itself never blocks');

    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir);
    is($rc, 2, 'B1 CANONICAL (-> AC2): a registered reporter session, with NOTHING declared '
             . 'to bp-runstate.pl --surface reporter, is REFUSED on Stop -- exit 2, not a '
             . 'warning');
}

# ===========================================================================
# C. THE OTHER DIRECTION (Pillar 2's "both directions"): an UNREGISTERED
#    session (never called mark-wakeup.sh with the arm shape at all) is NOT
#    gated by the reporter branch -- it must fall through cleanly. Same
#    project shape as B, only the registration step is omitted.
#
#    NON-VACUITY NOTE: this assertion currently passes VACUOUSLY (the gate
#    has no reporter branch at all yet, pre-implementation, so of course an
#    unregistered session is not blocked). It stops being vacuous the moment
#    a reporter branch exists: an implementation that gates on the wrong
#    signal (e.g. "any Stop with a --root that has a .subagent-guard dir")
#    would wrongly fire here too, and this is the assertion that catches it.
# ===========================================================================
{
    my $root = new_project();
    my $rdir = tempdir(CLEANUP => 1);   # RDIR exists but has no marker in it
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-c-unregistered'), rdir => $rdir);
    is($rc, 0, 'C1 CANONICAL (Pillar 2, other direction): a session that never registered as '
             . 'a reporter is NOT gated -- the reporter branch must be provably inert for '
             . 'ordinary/non-reporter sessions, not merely permissive by coincidence');
}

# ===========================================================================
# D. AC3 (-> DC2/DC4): after a REAL `pause --surface reporter` call with a
#    live pid and a future deadline, the SAME session's next Stop is ALLOWED.
#
#    NON-VACUITY NOTE: D0 (the setup pause call) is EXPECTED to fail today —
#    bp-runstate.pl has no --surface flag yet (exit 3, "unknown option"),
#    which is exactly what file 144 pins directly. D1 therefore currently
#    passes VACUOUSLY (no reporter branch exists yet to block anything). Once
#    both land, D0 turns green for real and D1 becomes the meaningful
#    assertion: a wrong implementation that ignores the verified pause and
#    blocks anyway would flip D1 to rc==2 and fail it.
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-d');
    my $until = time() + 300;
    my $prc = pause_reporter($root, $$, $until);
    is($prc, 0, 'D0 setup: a real `pause --surface reporter --watcher-pid $$` call succeeds '
              . 'against this test process\'s own live pid');

    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir);
    is($rc, 0, 'D1 CANONICAL (-> AC3): the SAME registered session, after declaring a live '
             . 'verified pause on the reporter surface, is ALLOWED to stop');
}

# ===========================================================================
# E. AC3 continued -- staleness reversion. Editing the SAME record to carry a
#    dead pid (t/112's own technique, chosen there specifically because a
#    killed child's pid semantics are unreliable on this host) reproduces the
#    refusal on the NEXT Stop, without re-testing effective()'s internals.
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-e');
    my $until = time() + 300;
    pause_reporter($root, $$, $until);
    my ($rc0) = run_gate(stop_payload($root, $sid), rdir => $rdir);
    is($rc0, 0, 'E0 setup: allowed while the pause is live (same shape as D)');

    my $sp = runstate_reporter_path($root);
    SKIP: {
        skip 'reporter surface state file not yet produced (registration/surface not built)', 2
            unless -f $sp;
        my $j = JSON::PP->new;
        my $rec = eval { $j->decode(do { open my $f, '<', $sp or die; local $/; <$f> }) };
        skip 'reporter surface state file unreadable', 2 unless ref $rec eq 'HASH';
        $rec->{watcher_pid} = 999999;   # a pid astronomically unlikely to be alive
        open my $w, '>', $sp or die "rewrite $sp: $!";
        print {$w} $j->encode($rec);
        close $w;

        my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir);
        is($rc, 2, 'E1 CANONICAL (-> AC3 stale-pause reversion): once the watcher_pid in the '
                 . 'reporter-surface record is dead, the SAME session'."'".'s next Stop is '
                 . 'REFUSED again -- reusing effective() unmodified, not reimplemented here');
    }
}

# ===========================================================================
# F. AC4 (-> DC3): the refusal names the REPORTER's own remedy, never the
#    driver's. Reusing B's exact refused fixture.
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-f');
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir);
    is($rc, 2, 'F0 setup: refused, same shape as B');

    unlike($out, qr/bp-drive-next\.pl/,
       'F1 CANONICAL (-> AC4): the refusal text NEVER references bp-drive-next.pl -- that '
     . 'is a driver-only concept');
    unlike($out, qr/dispatch the worker/i,
       'F2: the refusal text does NOT tell a reporter to "dispatch the worker" -- the '
     . 'driver\'s own remedy verb, meaningless in a reporter\'s vocabulary');
    unlike($out, qr/consult the director/i,
       'F3: the refusal text does NOT tell a reporter to "consult the director" either');
    like($out, qr/bp-runstate\.pl.*pause.*--surface\s+reporter/s,
       'F4 CANONICAL: the refusal DOES give the reporter-surface pause command');
    like($out, qr/bp-runstate\.pl.*finish.*--surface\s+reporter/s,
       'F5 CANONICAL: the refusal DOES give the reporter-surface finish command');
}

# ===========================================================================
# G. TTL reap (spec §3 behavior 6) — a marker older than the TTL is removed
#    on the next Stop and the session is treated as unregistered from then on.
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-g');
    my $marker = "$rdir/$sid";
  SKIP: {
        skip 'no marker written (registration not yet built)', 2 unless -f $marker;
        # Age the marker file well past the 1-hour TTL used for this fixture.
        my $old = time() - (2 * 3600);
        utime($old, $old, $marker) or diag("utime failed: $!");
        my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir, ttl_h => 1);
        is($rc, 0, 'G1 CANONICAL (spec §3 behavior 6): a marker older than '
                 . 'CCPRAXIS_REPORTER_TTL_H is treated as unregistered -- Stop is ALLOWED');
        ok(!-f $marker, 'G2: ...and the stale marker is REMOVED (TTL reap), mirroring the '
                       . 'driver\'s own marker reap discipline exactly');
    }
}

# ===========================================================================
# H. The escape hatches are INDEPENDENT of the driver's own. Silencing one
#    surface's hatch must never silence the other's (spec §3 behavior 8).
# ===========================================================================
{
    my ($root, $rdir, $sid) = registered_reporter('sess-h1');
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir, drive_stop_ok => 1);
    is($rc, 2, 'H1 CANONICAL: CCPRAXIS_DRIVE_STOP_OK=1 alone does NOT silence the reporter '
             . 'refusal -- the two escape hatches are independent env vars');
}
{
    my ($root, $rdir, $sid) = registered_reporter('sess-h2');
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir, reporter_stop_ok => 1);
    is($rc, 0, 'H2: CCPRAXIS_REPORTER_STOP_OK=1 DOES allow the stop -- H1'."'".'s block is '
             . 'attributable to using the wrong hatch, not to the reporter hatch being broken');
}
{
    my ($root, $rdir, $sid) = registered_reporter('sess-h3');
    open my $fh, '>', "$root/.ccpraxis-local-data/.reporter-stop-ok" or die $!;
    close $fh;
    my ($rc, $out) = run_gate(stop_payload($root, $sid), rdir => $rdir);
    is($rc, 0, 'H3: the one-shot .reporter-stop-ok file allows the stop');
    ok(!-f "$root/.ccpraxis-local-data/.reporter-stop-ok",
       'H4: ...and is CONSUMED — an operator override applies once, never permanently');
}

# ===========================================================================
# I. AC7's second half: a Stop event for a session with NO
#    ${CCPRAXIS_REPORTER_ACTIVE_DIR} directory at all exits 0 having made NO
#    filesystem writes (a naive implementation that unconditionally creates
#    the directory is caught by the mtime/existence check, not merely by
#    the exit code).
#
#    NON-VACUITY NOTE: I1 passes vacuously pre-implementation (nothing blocks
#    anything yet). I2 is NOT vacuous even today: it already catches a wrong
#    implementation that unconditionally `mkdir -p`s the active-dir before
#    checking existence, regardless of whether the block logic itself has
#    landed.
# ===========================================================================
{
    my $root  = new_project();
    my $rdir  = tempdir(CLEANUP => 1);
    my $ghost = "$rdir/does-not-exist-yet";   # deliberately never created
    my ($rc, $out) = run_gate(stop_payload($root, 'sess-i'), rdir => $ghost);
    is($rc, 0, 'I1: a Stop event with NO reporter-active directory at all is ALLOWED');
    ok(!-e $ghost,
       'I2 CANONICAL: ...and the directory is NOT created as a side effect -- a naive '
     . '"mkdir -p $RDIR" placed before the existence check would fail this specifically');
}

done_testing();
