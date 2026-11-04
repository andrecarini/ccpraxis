#!/usr/bin/env perl
# platform: any
# ORACLE for package 16-cutover's fix-batch (reports/16-cutover/fix-batch.md,
# Decision 79), the parts fixed by an IMPLEMENTER rather than by editing an
# existing test: F1, F2, F3, F4, F5, F7, F12. F6 (ledger stamping) is in the
# sibling file stop-gate-stamping.t; F8/F11 are edits to existing tests and
# are left untouched here.
#
# Written from fix-batch.md / review.md / redteam.md ONLY. Every hook run
# goes through GuardHarness (fresh BUTLER_STATE_DIR/CCPRAXIS_DATA_DIR/HOME
# per case, real payload on stdin, never the operator's real state) or a
# bounded, hermetic subprocess with its own tempdir env. No test spawns an
# immortal daemon: BpContinuityLease::_spawn_daemon already refuses to fork a
# real process from a *.t file, and every subprocess this file starts of its
# own is bounded and reaped.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use GuardHarness;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep time);

(my $BUTLER  = "$Bin/../..") =~ s{\\}{/}g;
(my $SCRIPTS = "$BUTLER/scripts") =~ s{\\}{/}g;
require "$SCRIPTS/BpHook/BindDispatch.pm";
require "$SCRIPTS/BpHook/Guards/Common.pm";
require "$SCRIPTS/BpHook/Guards/TrackDispatch.pm";
require "$SCRIPTS/BpHook/ArmOnEntry.pm";
require "$SCRIPTS/BpContinuityLease.pm";

# ---------------------------------------------------------------------------
# small shared helpers
# ---------------------------------------------------------------------------
sub slurp {
    my ($p) = @_;
    return undef unless -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my $sidn = 0;
sub next_sid { return sprintf('cutover-%04x', ++$sidn) }

sub write_json {
    my ($path, $data) = @_;
    (my $dir = $path) =~ s{[^/\\]*\z}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>:raw', $path or die "open $path: $!";
    print {$fh} JSON::PP->new->utf8->canonical->encode($data);
    close $fh;
    return;
}

# fwd($p) -- backslash -> forward slash, no trailing slash.
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p =~ s{/+\z}{}; return $p }

# ===========================================================================
# F1 (review B1, blocker) -- a dispatch bind-dispatch DENIES must leave no
# track-dispatch worker marker. Fixture: 2 in-flight members (bp1/01-a,
# bp1/02-b), a driver-armed session, one Task/Agent PreToolUse payload run
# through BOTH real wrapper files, exactly as hooks.json's parallel group
# does.
# ===========================================================================
{
    my $sid  = next_sid();
    my $base = fwd(GuardHarness::fresh_state());
    GuardHarness::arm($sid, 'driver');

    my $projroot = fwd(tempdir(CLEANUP => 1));
    my $data     = "$projroot/.ccpraxis-local-data";
    make_path($data);
    write_json("$data/.drive-solo/inflight.json", {
        packages => [
            { blueprint => 'bp1', package => '01-a', ledger => 'x', since => time() },
            { blueprint => 'bp1', package => '02-b', ledger => 'y', since => time() },
        ],
    });
    # Bug 20261104-164548-2d3a: bind-dispatch no longer counts a member whose
    # ledger is missing or terminal, so both members get a live ledger.
    make_path("$data/blueprints/bp1/packages");
    for my $pk ('01-a', '02-b') {
        open my $lfh, '>:raw', "$data/blueprints/bp1/packages/$pk.md" or die "open ledger $pk: $!";
        print {$lfh} "---\npackage: $pk\nblueprint: bp1\nstatus: running\nwrite_set: src/$pk/\n---\n";
        close $lfh;
    }
    my $L = $data; $L =~ s{.*/}{};   # basename, as BindDispatch::_ledger_line uses

    my $tuid = 'toolu_f1_001';
    my $payload_noledger = {
        session_id => $sid, hook_event_name => 'PreToolUse', tool_name => 'Task',
        tool_use_id => $tuid,
        tool_input  => { subagent_type => 'bp-implementer', prompt => 'Implement the failing edge case.' },
    };
    my %env = (BP_PROJECT_ROOT => $projroot, CCPRAXIS_DATA_DIR => $data);

    my $bind_res  = GuardHarness::run_wrapper('bind-dispatch', $payload_noledger, env => \%env);
    is($bind_res->{rc}, 2, 'F1: 2 members, no Ledger line -> bind-dispatch denies (rc 2)');

    my $marker = "$data/.drive-solo/workers/$tuid";
    GuardHarness::run_wrapper('track-dispatch', $payload_noledger, env => \%env);
    ok(!-e $marker, 'F1: ...and track-dispatch on the SAME denied payload leaves no workers/<tuid> marker')
        or diag("marker exists: " . (slurp($marker) // '<unreadable>'));

    # Same, but WITH a valid "Ledger: <path>" line -> bind-dispatch allows,
    # and the marker is present (allowed dispatches keep today's behaviour).
    my $tuid2 = 'toolu_f1_002';
    my $payload_valid = {
        session_id => $sid, hook_event_name => 'PreToolUse', tool_name => 'Task',
        tool_use_id => $tuid2,
        tool_input  => { subagent_type => 'bp-implementer',
                          prompt => "Implement it.\nLedger: $L/blueprints/bp1/packages/01-a.md\n" },
    };
    my $bind_res2 = GuardHarness::run_wrapper('bind-dispatch', $payload_valid, env => \%env);
    is($bind_res2->{rc}, 0, 'F1: 2 members, a valid Ledger line -> bind-dispatch allows (rc 0)');
    GuardHarness::run_wrapper('track-dispatch', $payload_valid, env => \%env);
    my $marker2 = "$data/.drive-solo/workers/$tuid2";
    ok(-f $marker2, 'F1: ...and the allowed dispatch DOES get a workers/<tuid> marker (unchanged from today)');

    # 1 member: bind-dispatch always allows -> marker behaviour unchanged.
    write_json("$data/.drive-solo/inflight.json", {
        packages => [ { blueprint => 'bp1', package => '01-a', ledger => 'x', since => time() } ],
    });
    my $tuid3 = 'toolu_f1_003';
    my $payload_one = {
        session_id => $sid, hook_event_name => 'PreToolUse', tool_name => 'Task',
        tool_use_id => $tuid3,
        tool_input  => { subagent_type => 'bp-implementer', prompt => 'Anything at all.' },
    };
    my $bind_res3 = GuardHarness::run_wrapper('bind-dispatch', $payload_one, env => \%env);
    is($bind_res3->{rc}, 0, 'F1: 1 member -> bind-dispatch always allows');
    GuardHarness::run_wrapper('track-dispatch', $payload_one, env => \%env);
    ok(-f "$data/.drive-solo/workers/$tuid3", 'F1: ...and the marker is written exactly as before (1-member path unchanged)');
}

# ===========================================================================
# F7 (red-team L2, L3) -- bind-dispatch: the same member named twice (once
# relative, once absolute) counts as one and binds; a Ledger: line ending in
# CR still matches.
# ===========================================================================
{
    my $sid  = next_sid();
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');

    my $projroot = fwd(tempdir(CLEANUP => 1));
    my $data     = "$projroot/.ccpraxis-local-data";
    make_path($data);
    write_json("$data/.drive-solo/inflight.json", {
        packages => [
            { blueprint => 'bp1', package => '01-a', ledger => 'x', since => time() },
            { blueprint => 'bp1', package => '02-b', ledger => 'y', since => time() },
        ],
    });
    my $L = $data; $L =~ s{.*/}{};
    my %env = (BP_PROJECT_ROOT => $projroot, CCPRAXIS_DATA_DIR => $data);

    my $rel = "$L/blueprints/bp1/packages/01-a.md";
    my $abs = "$data/blueprints/bp1/packages/01-a.md";
    my $payload_dup = {
        session_id => $sid, hook_event_name => 'PreToolUse', tool_name => 'Task',
        tool_use_id => 'toolu_f7_dup',
        tool_input  => { subagent_type => 'bp-implementer',
                          prompt => "Implement it.\nLedger: $rel\nLedger: $abs\n" },
    };
    my $res_dup = GuardHarness::run_wrapper('bind-dispatch', $payload_dup, env => \%env);
    is($res_dup->{rc}, 0,
        'F7 (L2): the SAME member named twice (relative + absolute Ledger: lines) binds rather than "too many"')
        or diag($res_dup->{out});

    my $payload_cr = {
        session_id => $sid, hook_event_name => 'PreToolUse', tool_name => 'Task',
        tool_use_id => 'toolu_f7_cr',
        tool_input  => { subagent_type => 'bp-implementer',
                          prompt => "Implement it.\r\nLedger: $rel\r\n" },
    };
    my $res_cr = GuardHarness::run_wrapper('bind-dispatch', $payload_cr, env => \%env);
    is($res_cr->{rc}, 0, 'F7 (L3): a Ledger: line ending in CR (CRLF prompt) still matches and binds')
        or diag($res_cr->{out});
}

# ===========================================================================
# F2 (red-team H1) -- a driver session with an off/<sid> record must be
# denied at arm-on-entry when it calls the director's `next` again, and must
# arm nothing; after an explicit `on` (BpHook::arm(..., by => 'on')), `next`
# proceeds and arms the session.
# ===========================================================================
{
    my $sid   = next_sid();
    my $state = fwd(GuardHarness::fresh_state());

    BpHook::disarm($sid, actor => 'agent', reason => 'done for now');
    ok(BpHook::latest_is_off($sid), 'F2 setup: the session now has an off/<sid> record');

    my $payload_next = {
        session_id => $sid, hook_event_name => 'PreToolUse', tool_name => 'Bash',
        tool_input => { command => 'perl /c/x/plugins/butler/scripts/bp-drive-next.pl next' },
    };
    my $res = GuardHarness::run_wrapper('arm-on-entry', $payload_next, env => {});
    is($res->{rc}, 2, 'F2: an off session calling the director\'s `next` again is DENIED')
        or diag($res->{err});
    like($res->{err}, qr/butler-continuity on/,
        'F2: ...and the denial tells the agent to run `butler-continuity on` first');
    ok(!-e "$state/continuity/armed/$sid", 'F2: ...and nothing was armed');

    # Explicit `on` (what the fix's denial line instructs the agent to run).
    ok(BpHook::arm($sid, role => 'driver', by => 'on'), 'F2: BpHook::arm(..., by => "on") succeeds');
    ok(!BpHook::latest_is_off($sid), 'F2: ...and clears the off record');

    my $res2 = GuardHarness::run_wrapper('arm-on-entry', $payload_next, env => {});
    is($res2->{rc}, 0, 'F2: once back on, `next` proceeds (rc 0)');
    ok(-e "$state/continuity/armed/$sid", 'F2: ...and the session is (still) armed');
}

# ===========================================================================
# F12 (review m7) -- when bp-dispatch-log's append fails (an unwritable
# dispatch-log directory: a plain FILE sits where the directory would be
# created), track-dispatch's COORDINATOR pre-branch still exits 0, writes no
# partial dispatch-log record, and still writes the driver-independent
# active-worker marker (the load-bearing property AC26 already required).
# ===========================================================================
{
    GuardHarness::fresh_state();
    my $root = fwd(tempdir(CLEANUP => 1));
    my $bpdir = "$root/bp1";
    make_path("$bpdir/runs");
    # Block the dispatch-log directory: a FILE occupies the path a
    # directory would need, so _mkdir_p's first mkdir() fails -- no chmod
    # needed (portable to this Windows host, unlike a permission bit).
    open(my $blockfh, '>', "$root/.ccpraxis-local-data") or die $!;
    close $blockfh;

    my %env = (BP_LEDGER => "$bpdir/packages/p.md", BP_DIR => $bpdir, BP_PACKAGE => 'p',
               BP_PROJECT_ROOT => $root, BP_BLUEPRINT => 'bp1');
    my $payload = {
        session_id => next_sid(), hook_event_name => 'PreToolUse', tool_name => 'Task',
        tool_use_id => 'toolu_f12', tool_input => { subagent_type => 'butler:bp-implementer' },
    };
    my $res = GuardHarness::run_wrapper('track-dispatch', $payload, env => \%env);
    is($res->{rc}, 0, 'F12: an unwritable dispatch-log dir -> track-dispatch coordinator pre still exits 0');
    ok(-f "$bpdir/runs/p.active-worker", 'F12: ...and the active-worker marker is STILL written');
    ok(!-d "$root/.ccpraxis-local-data/.dispatch-log", 'F12: ...and no dispatch-log record was written (the dir never came into being)');
}

# ===========================================================================
# F5 (red-team M1 + L5) -- bp-ledger.pl widen-write-set refuses a widening
# that overlaps another in-flight package's write set, naming it; a disjoint
# widening still succeeds; a case-variant overlap is refused on this
# case-insensitive host (msys/MSWin32).
# ===========================================================================
{
    my $LEDGER_PL = "$SCRIPTS/bp-ledger.pl";
    my $TEMPLATE  = "$BUTLER/../blueprint/templates/package-ledger.md";
    ok(-f $LEDGER_PL && -f $TEMPLATE, 'F5 sanity: bp-ledger.pl and the ledger template exist')
        or BAIL_OUT('missing inputs for F5');

    sub f5_run_cli {
        my (@args) = @_;
        my $dir = tempdir(CLEANUP => 1);
        my $out = "$dir/out";
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            open STDOUT, '>', $out or _exit(126); open STDERR, '>&', \*STDOUT or _exit(126);
            exec($^X, $LEDGER_PL, @args) or _exit(127);
        }
        waitpid($pid, 0);
        return ($? >> 8, slurp($out) // '');
    }

    my $data = fwd(tempdir(CLEANUP => 1));
    my $bp   = "$data/blueprints/bp1";
    make_path("$bp/packages");
    my $led_a = "$bp/packages/01-a.md";
    my $led_b = "$bp/packages/02-b.md";
    my ($rc_a) = f5_run_cli('create', '--ledger', $led_a, '--package', '01-a', '--blueprint', 'bp1',
                             '--template', $TEMPLATE, '--write-set', 'src/a/');
    my ($rc_b) = f5_run_cli('create', '--ledger', $led_b, '--package', '02-b', '--blueprint', 'bp1',
                             '--template', $TEMPLATE, '--write-set', 'src/b/');
    is($rc_a, 0, 'F5 sanity: 01-a ledger created'); is($rc_b, 0, 'F5 sanity: 02-b ledger created');

    open my $bfh, '>:raw', "$bp/blueprint.md" or die $!;
    print {$bfh} "# bp1\n\n| # | Decision | Decided by | Date |\n|---|---|---|---|\n"
               . "| 1 | 01-a also edits src/b/shared.txt. | driver | 2026-09-25 |\n"
               . "| 2 | 01-a also edits src/c/only.txt. | driver | 2026-09-25 |\n"
               . "| 3 | 01-a also edits SRC/B/other.txt. | driver | 2026-09-25 |\n";
    close $bfh;

    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/inflight.json", {
        packages => [
            { blueprint => 'bp1', package => '01-a', ledger => $led_a, since => time() },
            { blueprint => 'bp1', package => '02-b', ledger => $led_b, since => time() },
        ],
    });

    my $before = slurp($led_a);
    my ($rc1, $out1) = f5_run_cli('widen-write-set', '--ledger', $led_a, '--decision', '1',
                                    '--path', 'src/b/shared.txt');
    isnt($rc1, 0, 'F5: widening 01-a onto 02-b\'s in-flight write set is refused')
        or diag($out1);
    like($out1, qr/02-b/, 'F5: ...and the refusal names the conflicting package');
    is(slurp($led_a), $before, 'F5: ...and the ledger is byte-unchanged');

    my ($rc2, $out2) = f5_run_cli('widen-write-set', '--ledger', $led_a, '--decision', '2',
                                    '--path', 'src/c/only.txt');
    is($rc2, 0, 'F5: a disjoint widening (src/c/) still succeeds') or diag($out2);

    my $before3 = slurp($led_a);
    my ($rc3, $out3) = f5_run_cli('widen-write-set', '--ledger', $led_a, '--decision', '3',
                                    '--path', 'SRC/B/other.txt');
    isnt($rc3, 0, 'F5: a case-VARIANT overlap (SRC/B/ vs 02-b\'s src/b/) is refused on this host')
        or diag($out3);
    is(slurp($led_a), $before3, 'F5: ...and the ledger is byte-unchanged for the case-variant refusal too');
}

# ===========================================================================
# F4 (red-team M2) -- an ARMED session's Stop gate ensures the lease
# refresher is running: no daemon alive -> spawns exactly one; daemon alive
# -> no spawn; unarmed -> no spawn. The real OS-level fork
# (BpContinuityLease::_spawn_daemon) is glob-stubbed for the whole block, so
# nothing here can leak a real process regardless of what StopGate.pm calls
# through (ensure_daemon/converge both eventually call _spawn_daemon).
# ===========================================================================
{
    require "$SCRIPTS/BpHook/StopGate.pm";

    my @SPAWN_CALLS;
    no warnings 'redefine';
    local *BpContinuityLease::_spawn_daemon = sub { push @SPAWN_CALLS, [@_]; return 424242 };

    sub f4_scenario {
        my (%o) = @_;
        @SPAWN_CALLS = ();
        my $sid    = next_sid();
        my $active = fwd(tempdir(CLEANUP => 1));
        my $state  = fwd(tempdir(CLEANUP => 1));

        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $active;
        local $ENV{BUTLER_STATE_DIR}                = $state;
        local $ENV{CCPRAXIS_NO_WAKELOCK}            = 0;   # let the fix's own gate decide; the real
                                                            # fork is stubbed above regardless.
        delete local $ENV{BP_LEDGER};
        delete local $ENV{BP_ROLE};

        if ($o{armed}) {
            BpHook::arm($sid, role => 'driver', by => 'arm-on-entry');
        }
        if ($o{daemon_alive}) {
            open my $fh, '>', "$active/lease.pid" or die $!;
            print {$fh} "$$\n";
            close $fh;
        }

        my $payload = { session_id => $sid, hook_event_name => 'Stop', background_tasks => [] };
        my $res = GuardHarness::run_module('StopGate', $payload);
        return ($res, scalar(@SPAWN_CALLS));
    }

    my (undef, $n1) = f4_scenario(armed => 1, daemon_alive => 0);
    is($n1, 1, 'F4: armed, no daemon alive -> the Stop gate spawns exactly one refresher');

    my (undef, $n2) = f4_scenario(armed => 1, daemon_alive => 1);
    is($n2, 0, 'F4: armed, daemon already alive -> no spawn (cheap check only)');

    my (undef, $n3) = f4_scenario(armed => 0, daemon_alive => 0);
    is($n3, 0, 'F4: not armed -> no spawn');
}

# ===========================================================================
# F3 (red-team H2) -- the wake-lock must not be held forever by a ghost arm
# file: a missing transcript counts as live only while the arm file's own
# mtime is under one hour old (Decision 53); gc_sessions removes a ghost arm
# file whose transcript is gone.
# ===========================================================================
{
    my $state  = fwd(tempdir(CLEANUP => 1));
    my $active = fwd(tempdir(CLEANUP => 1));
    local $ENV{BUTLER_STATE_DIR}                = $state;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR}  = $active;
    local $ENV{CCPRAXIS_NO_WAKELOCK}            = 1;

    my $sid1 = next_sid();
    my $armed_dir = "$state/continuity/armed";
    make_path($armed_dir);
    my $ghost_transcript = "$active/nonexistent-transcript.jsonl"; # never created
    my $ghost_file = "$armed_dir/$sid1";
    write_json($ghost_file, { session_id => $sid1, role => 'driver', by => 'arm-on-entry',
                               at => '2026-08-01T00:00:00Z', transcript_path => $ghost_transcript });
    my $two_h_ago = time() - 7200;
    utime($two_h_ago, $two_h_ago, $ghost_file);

    is(BpContinuityLease::any_active($active), 0,
        'F3: a ghost arm file (missing transcript, mtime 2h old) -> any_active is 0');

    my $sid2 = next_sid();
    my $recent_file = "$armed_dir/$sid2";
    write_json($recent_file, { session_id => $sid2, role => 'driver', by => 'arm-on-entry',
                                at => '2026-08-01T00:00:00Z', transcript_path => "$active/also-missing.jsonl" });
    my $ten_min_ago = time() - 600;
    utime($ten_min_ago, $ten_min_ago, $recent_file);

    is(BpContinuityLease::any_active($active), 1,
        'F3: the SAME shape but a 10-minute-old arm file -> any_active is 1 (grace period)');

    unlink $recent_file;

    my $before_gc = -e $ghost_file ? 1 : 0;
    is($before_gc, 1, 'F3 sanity: the ghost arm file exists before gc');
    my $removed = BpHook::gc_sessions();
    ok($removed >= 1, 'F3: gc_sessions() removes at least one session');
    ok(!-e $ghost_file, 'F3: ...and specifically the ghost arm file (transcript gone, mtime past the hour)');
}

done_testing();
