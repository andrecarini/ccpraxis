#!/usr/bin/env perl
# 135-bp-watch-doctrine.t — IMMUTABLE ORACLE for w01-bp-watch's doctrine
# surface: criterion 10 (registers as a legitimate wake-up), criterion 10a
# (self-contained arm, no forgettable re-arm), the --keepawake lease refresh,
# and the bp-watchdog.pl supersession (criterion 8/§2.3/§3.6) plus the
# docs-consistency check (criterion 11, checks:docs-consistency).
#
# Spec: specs/w01-bp-watch-spec.md §2.2 (--keepawake), §2.3 (bp-watchdog.pl
# supersession), §2.4/§2.5 (SKILL.md updates), §3 behaviors 12-14, §4
# AC10/AC10a/AC11.
#
# AC10a IS PARTIAL BY DESIGN (spec §3.5, package ledger 2026-08-13T20:22:11Z
# entry). This file asserts ONLY what w01 actually guarantees — a single arm
# whose --max-seconds covers the whole dispatch, with no routine tick to
# forget (already pinned as behavior 11 in t/134's B5/F5/D3 timing
# assertions) — and the doctrine text naming the residual. It does NOT assert
# that an agent always re-arms after a genuine BOUND exit; that is explicitly
# NOT closed by this package (handed to w02) and asserting it here would be
# inventing behavior the spec does not claim.
#
# Runs standalone: perl plugins/butler/tests/t/135-bp-watch-doctrine.t
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $WATCH     = "$Bin/../../scripts/bp-watch.pl";
my $WATCHDOG  = "$Bin/../../scripts/bp-watchdog.pl";
my $MARK      = "$Bin/../../hooks/mark-wakeup.sh";
my $DS_SKILL  = "$Bin/../../skills/drive-solo/SKILL.md";
my $RP_SKILL  = "$Bin/../../skills/reporter/SKILL.md";

sub slurp {
    my ($p) = @_;
    return '' unless -f $p;
    local (@ARGV, $/) = ($p);
    return scalar <>;
}

# ===========================================================================
# A. AC11/criterion 11 — docs-consistency: neither SKILL.md still instructs
#    arming bp-watchdog.pl (it is superseded, §3.6), and both now instruct
#    arming bp-watch.pl instead. Currently RED: as of this writing,
#    drive-solo/SKILL.md still arms bp-watchdog.pl and neither file mentions
#    bp-watch.pl at all — that is exactly the not-yet-implemented state this
#    oracle exists to fail against.
# ===========================================================================
{
    my $ds = slurp($DS_SKILL);
    ok(length $ds, 'A0: drive-solo/SKILL.md is readable');
    unlike($ds, qr/bp-watchdog\.pl\s+--(sleep|arm)/,
       'A1 CANONICAL: drive-solo/SKILL.md no longer instructs arming bp-watchdog.pl '
     . '(behavior 14) — it is superseded, not left beside the new tool (criterion 8/§3.6)');
    like($ds, qr/bp-watch\.pl\s+--arm/,
       'A2: drive-solo/SKILL.md instructs arming bp-watch.pl instead');
    like($ds, qr/--package\b/,
       'A3: the drive-solo arm command uses Mode A (--package), per spec §2.4');
    like($ds, qr/--keepawake\b/,
       'A4: the drive-solo arm command includes --keepawake, per spec §2.2/§3.4');
}
{
    my $rp = slurp($RP_SKILL);
    ok(length $rp, 'A5: reporter/SKILL.md is readable');
    unlike($rp, qr/bp-watchdog\.pl/,
       'A6: reporter/SKILL.md never mentions bp-watchdog.pl at all (it never armed it, and '
     . 'must not gain that instruction now either)');
    like($rp, qr/bp-watch\.pl\s+--arm/,
       'A7 CANONICAL: reporter/SKILL.md instructs arming bp-watch.pl in Mode B (behavior 14 '
     . 'positive half — a mechanism nobody is told to arm protects nothing)');
    like($rp, qr/--blueprint\b/,
       'A8: the reporter arm command uses Mode B (--blueprint alone), per spec §2.5');
    like($rp, qr/--pid-file\b/,
       'A9: the reporter arm command supplies --pid-file <bpdir>/runs/.orchestrator, per '
     . 'spec §2.5');
    unlike($rp, qr/--keepawake/,
       'A10: reporter/SKILL.md does NOT arm --keepawake — the reporter surface holds no '
     . 'wake-lock today and this package does not invent one for it (spec §3.4)');
}

# ===========================================================================
# B. AC11 — the existing "re-dispatch the wedged worker instead" doctrine
#    line survives, now reached through bp-watch.pl's WORKERS-GONE/
#    STATUS-CHANGE-silence path rather than bp-watchdog.pl's STALLED verdict.
# ===========================================================================
{
    my $ds = slurp($DS_SKILL);
    like($ds, qr/re-dispatch the wedged worker/i,
       'B1: drive-solo/SKILL.md retains the "re-dispatch the wedged worker instead" doctrine '
     . 'line — the escape hatch was gated behind a detector that never fired; fixing the '
     . 'detector makes it reachable, it must not also disappear');
}

# ===========================================================================
# C. §2.3/AC8 — bp-watchdog.pl: header-only supersession note, no functional
#    rewrite claimed by this file (t/95-watchdog.t, untouched, is the oracle
#    for that). Points at bp-watch.pl by name.
# ===========================================================================
{
    my $wd = slurp($WATCHDOG);
    ok(length $wd, 'C0: bp-watchdog.pl is readable');
    like($wd, qr/superseded/i,
       'C1 CANONICAL: bp-watchdog.pl\'s header states it is SUPERSEDED — criterion 8 requires '
     . 'the invariant-4 defect be neutralized "here, not left beside the new tool"; a header '
     . 'note that nothing calls it any more is the chosen mechanism (§3.6), not an internal '
     . 'rewrite');
    like($wd, qr/bp-watch\.pl/,
       'C2: the supersession note names bp-watch.pl by name — a superseded note pointing at '
     . 'nothing is not traceable');
}

# ===========================================================================
# D. AC10/criterion 10 — bp-watch.pl armed via run_in_background Bash
#    registers as a legitimate wake-up for gate-drive-loop.sh, BY
#    CONSTRUCTION (mark-wakeup.sh matches ANY backgrounded Bash call by
#    shape, never by binary name — spec §2.4, mark-wakeup.sh:99-108).
#    Reused as a BLACK BOX per spec §3 behavior 12 — do not re-derive its
#    matching logic here, assert the observable effect only. Same fixture
#    shape as t/120-mark-wakeup-agent-dispatch.t.
# ===========================================================================
ok(-f $MARK, 'D0: mark-wakeup.sh exists') or BAIL_OUT('hook missing');

sub new_drive_solo_root {
    my $root = tempdir(CLEANUP => 1);
    my $ds = "$root/.ccpraxis-local-data/.drive-solo";
    make_path($ds);
    # Matches gate-drive-loop.sh's own arming test fixture (spec §3 behavior 12).
    open my $o, '>', "$ds/order.json" or die;
    print {$o} '{"order":["x"],"recorded_at":1}';
    close $o;
    return $root;
}

sub run_mark {
    my ($payload, %env) = @_;
    my $envstr = 'BP_LEDGER= ';
    $envstr = "BP_LEDGER='$env{BP_LEDGER}' " if defined $env{BP_LEDGER};
    my $out = `${envstr}bash "$MARK" <<'PAYLOAD_EOF' 2>&1
$payload
PAYLOAD_EOF`;
    return ($? >> 8, $out);
}

sub bg_bash_watch_payload {
    my ($cwd, $sid) = @_;
    $sid //= 'sess-watch';
    my $cmd = 'perl plugins/butler/scripts/bp-watch.pl --arm --package bp/pkg --max-seconds 900 --keepawake';
    return qq({"session_id":"$sid","cwd":"$cwd","tool_name":"Bash",)
         . qq("tool_input":{"command":"$cmd","run_in_background":true}});
}

{
    my $root = new_drive_solo_root();
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";
    my ($rc, $out) = run_mark(bg_bash_watch_payload($root));
    is($rc, 0, 'D1: mark-wakeup.sh never blocks on a backgrounded bp-watch.pl Bash call');
    ok(-f "$ds/.wakeup-pending",
       'D2 CANONICAL AC10: arming bp-watch.pl via run_in_background Bash records a pending '
     . 'wake-up — criterion 10 satisfied BY CONSTRUCTION, with zero bp-watch.pl-specific code '
     . 'in mark-wakeup.sh (it matches by shape: any backgrounded Bash call)')
        or diag('mark-wakeup.sh did not record a wake-up for a run_in_background Bash call '
              . 'invoking bp-watch.pl');
}
{
    # Counter-fixture: the SAME command, run in the FOREGROUND (no
    # run_in_background), must NOT register — proves D2 is attributable to
    # the backgrounding, not to the command merely mentioning bp-watch.pl.
    my $root = new_drive_solo_root();
    my $ds   = "$root/.ccpraxis-local-data/.drive-solo";
    my $cmd  = 'perl plugins/butler/scripts/bp-watch.pl --arm --package bp/pkg --max-seconds 900';
    my $payload = qq({"session_id":"sess-fg","cwd":"$root","tool_name":"Bash",)
                . qq("tool_input":{"command":"$cmd","run_in_background":false}});
    run_mark($payload);
    ok(!-f "$ds/.wakeup-pending",
       'D3 counter-fixture: a FOREGROUND bp-watch.pl invocation records NOTHING — a foreground '
     . 'Bash call schedules no wake-up regardless of what it invokes');
}

# ===========================================================================
# E. --keepawake (AC per §2.2/§3.4) — refreshes the EXISTING bp-keepawake.pl
#    lease (the SAME .drive-solo/keepawake.pid bp-drive-next.pl already
#    manages), on every poll tick, rather than creating a second lock.
#
#    CCPRAXIS_NO_WAKELOCK=1 is exported on every invocation below so the
#    child bp-watch.pl process can never spawn a real OS wake-lock helper —
#    BpKeepAwake::spawn() honours that var unconditionally (bp-keepawake.pl
#    :163). The pre-existing lock file already holds a LIVE pid (our own
#    test process, $$ — a real Windows pid for this process's whole
#    lifetime), so apply()'s idempotence branch (refresh, not respawn) is
#    exactly what should fire, with no spawn ever attempted.
# ===========================================================================
sub write_ledger {
    my ($dir, $id, $status_line) = @_;
    make_path("$dir/packages");
    open my $fh, '>', "$dir/packages/$id.md" or die;
    print {$fh} "---\npackage: $id\n$status_line\n---\n\nbody\n";
    close $fh;
}

sub run_watch_env {
    my (@args) = @_;
    return (undef, '') unless -f $WATCH;
    my $cmd = join(' ', 'env CCPRAXIS_NO_WAKELOCK=1', 'perl', qq("$WATCH"), map { qq("$_") } @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

{
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/.ccpraxis-local-data";
    my $bp   = "$data/blueprints/bpx";
    make_path("$bp/packages");
    write_ledger($bp, 'p1', 'status: running');
    my $ds = "$data/.drive-solo";
    make_path($ds);
    my $lease = "$ds/keepawake.pid";
    open my $fh, '>', $lease or die; print {$fh} "$$\n"; close $fh;
    # Push the mtime into the past so any refresh is unambiguous.
    my $old = time - 500;
    utime($old, $old, $lease);

    run_watch_env('--arm', '--package', 'bpx/p1', '--max-seconds', '3', '--poll', '1',
                  '--keepawake', '--data', $data);

    my $mtime_after = (stat($lease))[9];
    ok(defined $mtime_after, 'E1: the lease file still exists after the watch (never deleted)');
    ok(defined $mtime_after && $mtime_after > $old + 60,
       'E2 CANONICAL: with --keepawake, the EXISTING .drive-solo/keepawake.pid lease\'s mtime '
     . 'is refreshed during the watch (advanced far past its artificially-aged mtime) — closes '
     . 'the gap where a long bp-watch.pl window outlives the 900s lease because nothing else '
     . 'is calling the director while it watches');
}
{
    # Counter-fixture: WITHOUT --keepawake, the same pre-existing lease is
    # left untouched — proves E2's refresh is attributable to the flag, not
    # to some ambient side effect of running bp-watch.pl at all.
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/.ccpraxis-local-data";
    my $bp   = "$data/blueprints/bpx";
    make_path("$bp/packages");
    write_ledger($bp, 'p1', 'status: running');
    my $ds = "$data/.drive-solo";
    make_path($ds);
    my $lease = "$ds/keepawake.pid";
    open my $fh, '>', $lease or die; print {$fh} "$$\n"; close $fh;
    my $old = time - 500;
    utime($old, $old, $lease);

    run_watch_env('--arm', '--package', 'bpx/p1', '--max-seconds', '3', '--poll', '1',
                  '--data', $data);   # no --keepawake

    my $mtime_after = (stat($lease))[9];
    ok(defined $mtime_after && $mtime_after < $old + 60,
       'E3 counter-fixture: WITHOUT --keepawake, the same lease file\'s mtime is left '
     . 'unrefreshed (still near its artificially-aged value) — E2\'s refresh is attributable '
     . 'to the flag, not incidental to running bp-watch.pl at all');
}
{
    # Reporter mode must NOT touch the lease even if it happened to exist —
    # spec §3.4/§2.5: no --keepawake support on the reporter (Mode B, no flag).
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/.ccpraxis-local-data";
    my $bp   = "$data/blueprints/bpx";
    make_path("$bp/packages");
    write_ledger($bp, 'p1', 'status: done');
    my $ds = "$data/.drive-solo";
    make_path($ds);
    my $lease = "$ds/keepawake.pid";
    open my $fh, '>', $lease or die; print {$fh} "$$\n"; close $fh;
    my $old = time - 500;
    utime($old, $old, $lease);

    run_watch_env('--arm', '--blueprint', 'bpx', '--max-seconds', '3', '--poll', '1', '--data', $data);

    my $mtime_after = (stat($lease))[9];
    ok(defined $mtime_after && $mtime_after < $old + 60,
       'E4: Mode B (--blueprint, no --keepawake flag given) never refreshes the lease either — '
     . 'refreshing is opt-in via the flag, never an ambient side effect of any bp-watch.pl run');
}

done_testing();
