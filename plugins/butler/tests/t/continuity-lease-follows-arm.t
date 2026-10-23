#!/usr/bin/env perl
# platform: any
# ORACLE for package 04-continuity-command (blueprint hook-continuity-remake),
# L1-L7 of specs/04-continuity-command-spec.md 2.5: the wake-lock follows the
# NEW BpHook arm state, through legacy_dir(), store_root_for() and
# new_store_active() -- none of which exist yet. Runs in-process, using the
# same $PLATFORM, $STATE_ROOT, spawn/kill_pid/powershell_available seams as
# the sibling continuity-lease-held coverage (Decision 45, unedited and untouched by this file).
#
# EVERY CALL TO A NOT-YET-WRITTEN SUB goes through LZ(), which turns
# "Undefined subroutine" into a plain undef instead of dying -- see
# continuity-command-verbs.t's OC() for the identical technique. The already-
# implemented any_active/converge/state/sync are called directly.
#
# THIS FILE NEVER TOUCHES THE REAL REGISTRY OR A REAL WAKE-LOCK: every
# directory is a File::Temp tempdir, CCPRAXIS_CONTINUITY_ACTIVE_DIR and
# BUTLER_STATE_DIR are scrubbed and reset at the top, and the one subprocess
# test (L7) sets CCPRAXIS_NO_WAKELOCK=1.
#
# Runs standalone: perl, given this file's own path under plugins/butler/tests/t/
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";

my $CMD = "$S/butler-continuity.pl";

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
# Deliberate: L1-L6 prove converge()'s real spawn DECISION through an injected `spawn` stub, so the
# guard that short-circuits it must be off here (run-tests.pl exports it). Only L7 sets it back.
delete $ENV{CCPRAXIS_NO_WAKELOCK};

# ---------------------------------------------------------------------------
# Isolation guard (R4 item 11): pin HOME/USERPROFILE to a decoy tempdir for
# the rest of this file, as defense in depth against any fallback path that
# might otherwise resolve the operator's real profile (see
# continuity-command-verbs.t for the concrete case this guards against: an
# `ask` call missing CLAUDE_PROJECT_DIR walking up to the real HOME). L6
# below still exercises HOME/USERPROFILE resolution correctly, using `local`
# to override this decoy within its own block and restore it after.
# ---------------------------------------------------------------------------
my $FAKE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FAKE_HOME = "$FAKE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($FAKE_HOME);
$ENV{HOME}        = $FAKE_HOME;
$ENV{USERPROFILE} = $FAKE_HOME;

# ---------------------------------------------------------------------------
# LZ(name, @args) -- call BpContinuityLease::<name> without ever crashing
# this file when the sub does not exist yet (legacy_dir, store_root_for,
# new_store_active are all new in this package).
# ---------------------------------------------------------------------------
sub LZ {
    my ($name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"BpContinuityLease::$name"} }
    my $ret;
    my $ok = eval { $ret = $code->(@args); 1 };
    return $ok ? $ret : undef;
}

my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) { next unless $pid; kill('TERM', $pid) }
    if (@KILL_PIDS) {
        select(undef, undef, undef, 0.3);
        for my $pid (@KILL_PIDS) { next unless $pid; kill('KILL', $pid) if kill(0, $pid) }
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { waitpid($pid, 0) } }
    }
    $? = 0;
}
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

sub fresh_home {
    my $t = tempdir(CLEANUP => 1);
    (my $base = "$t/home") =~ s{\\}{/}g;
    make_path($base);
    return $base;
}

sub fresh_legacy {
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/legacy") =~ s{\\}{/}g;
    make_path("$d/pending");
    return $d;
}

sub mk_marker {
    my ($p, $age) = @_;
    open my $fh, '>', $p or die $!;
    print {$fh} "x\n";
    close $fh;
    if ($age) { my $t = time - $age; utime($t, $t, $p) }
    return $p;
}

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# ===========================================================================
# L1 -- a fresh new-store arm makes any_active/converge see it as active
# ===========================================================================
{
    my $home = fresh_home();
    my $legacy = fresh_legacy(); # empty
    local $ENV{BUTLER_STATE_DIR}               = $home;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();

    my $sid = 'l1sess';
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'L1 setup: BpHook::arm succeeds');

    is(BpContinuityLease::any_active($legacy), 1,
       'L1: any_active(legacy_dir) is 1 while a fresh new-store arm exists');

    local $BpContinuityLease::PLATFORM = 'windows';
    my @spawned;
    my ($verdict, $holder) = BpContinuityLease::converge($legacy,
        spawn => sub { push @spawned, $_[0]; 9001 },
        powershell_available => sub { 1 });
    is($verdict, 'held',    'L1: converge returns held');
    is($holder,  'spawned', 'L1: and spawned, through the spawn seam');
}

# ===========================================================================
# L2 -- two armed sessions share one lease; the last disarm releases it
# ===========================================================================
{
    my $home = fresh_home();
    my $legacy = fresh_legacy();
    local $ENV{BUTLER_STATE_DIR}               = $home;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();
    local $BpContinuityLease::PLATFORM         = 'windows';

    my ($sid1, $sid2) = ('l2a', 'l2b');
    BpHook::arm($sid1, role => 'manual', by => 'on');
    BpHook::arm($sid2, role => 'manual', by => 'on');

    # converge's HELD branch calls refresh() then ensure_daemon($legacy, %opts)
    # -- the refresher decision alone (spec 2.5: "converge's held branch only
    # ensures the refresher, and apply happens on the refresher's tick"). Its
    # spawn seam is called as spawn($dir), same contract as
    # the sibling continuity-lease-held coverage's own converge case ("spawn => sub { push
    # @daemons, $_[0]; 7777 }") -- NOT BpKeepAwake::apply's spawn seam, which
    # is called with a PID-FILE PATH and is expected to write a real pid into
    # it. Feeding ensure_daemon's spawn seam something that tries to open
    # $_[0] (here, the directory itself) as a file for writing dies, which
    # ensure_daemon swallows and reports as 'refused' -- silently skipping the
    # write that would otherwise make a keepawake.pid claim exist, and this is
    # a seam-contract collision, not a real path to the wake-lock helper.
    my @daemons;
    my %held_seams = (
        spawn                 => sub { push @daemons, $_[0]; 9002 },
        powershell_available  => sub { die "converge's held branch must not even ask about powershell\n" },
    );

    BpHook::disarm($sid1, actor => 'agent', reason => 'a b');
    my ($v1, $h1) = BpContinuityLease::converge($legacy, %held_seams);
    is($v1, 'held', 'L2: disarming ONE of two armed sessions still leaves converge held');

    # BpKeepAwake::apply is the thing that actually claims/kills a real
    # wake-lock helper, and per spec 2.5 that only happens on the refresher's
    # tick (daemon_loop -> sync(..., active=>1)), never from converge's held
    # branch directly. To exercise the kill_pid seam on release we simulate
    # that a real helper claim already exists -- exactly as
    # the sibling continuity-lease-held coverage's own converge case does (manually writing
    # keepawake.pid before the release-side converge call) -- rather than
    # relying on the held branch above to have written one.
    my $pf = "$legacy/keepawake.pid";
    open my $w, '>', $pf or die $!;
    print {$w} "424242\n";
    close $w;

    my @killed;
    my %release_seams = (
        kill_pid              => sub { push @killed, $_[0] },
        powershell_available  => sub { 1 },
        spawn                 => sub { die "must not spawn on release\n" },
    );

    BpHook::disarm($sid2, actor => 'agent', reason => 'a b');
    my ($v2, $h2) = BpContinuityLease::converge($legacy, %release_seams);
    is($v2, 'released', 'L2: after the last disarm converge returns released');
    is($h2, 'idle',      'L2: and the holder is idle');
    is(scalar(@killed), 1, 'L2: the kill seam fires exactly once');
}

# ===========================================================================
# L3 -- staleness and naming filters on the new store
# ===========================================================================
{
    my $home = fresh_home();
    my $legacy = fresh_legacy();
    local $ENV{BUTLER_STATE_DIR}               = $home;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();

    my $root = BpHook::state_dir();
    make_path("$root/armed");

    my $sid = 'l3stale';
    BpHook::arm($sid, role => 'manual', by => 'on');
    my $armed_file = "$root/armed/$sid";
    my $old = time - 13 * 3600;
    utime($old, $old, $armed_file);

    is(LZ('new_store_active', $root), 0, 'L3: a 13h-old arm file does not count');
    ok(-f $armed_file, 'L3: and it is NOT deleted');

    unlink $armed_file;
    BpHook::arm($sid, role => 'manual', by => 'on');
    is(LZ('new_store_active', $root), 1, 'L3: a fresh arm file counts');

    open my $dot, '>', "$root/armed/.hidden" or die $!;
    close $dot;
    open my $tmp, '>', "$root/armed/.$sid.tmp.1234" or die $!;
    close $tmp;
    # Removing the real one leaves only dotted/temp names -- neither may count.
    unlink $armed_file;
    is(LZ('new_store_active', $root), 0, 'L3: dotted or temp names in armed/ never count on their own');
}

# ===========================================================================
# L4 (batch C, spec 16-cutover C-6, reason SW): the legacy registry is
# retired from any_active outright -- a fresh legacy-registry marker ALONE,
# with the new store empty, no longer holds the lease. A live new-store arm
# (with a live transcript) is what holds it now, exactly as L1 already
# proved; this block adds the negative half the old L4 never covered.
# ===========================================================================
{
    my $home = fresh_home();
    my $legacy = fresh_legacy();
    local $ENV{BUTLER_STATE_DIR}               = $home;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();
    local $BpContinuityLease::PLATFORM         = 'windows';

    mk_marker("$legacy/legacysess");
    is(BpContinuityLease::any_active($legacy), 0,
       'L4 (-> C-6, SW): any_active is 0 with the new store empty and ONLY a legacy marker present');
    my ($v, $h) = BpContinuityLease::converge($legacy,
        spawn => sub { die "must not spawn -- nothing is armed in the new store\n" },
        powershell_available => sub { 1 });
    is($v, 'released', 'L4 (-> C-6, SW): and converge releases -- the legacy marker grants nothing');

    # Positive case: arm the NEW store for the same dir and see the lease
    # follow it, exactly as C-6 requires.
    my $sid = 'l4newstore';
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'L4 setup: BpHook::arm succeeds');
    is(BpContinuityLease::any_active($legacy), 1,
       'L4 (-> C-6): any_active is 1 once the NEW store has a live armed session');

    unlink "$legacy/legacysess";
    is(BpContinuityLease::any_active($legacy), 1,
       'L4: removing the (already-inert) legacy marker changes nothing -- the new store still holds');
    BpHook::disarm($sid, actor => 'agent', reason => 'a b');
    is(BpContinuityLease::any_active($legacy), 0, 'L4: disarming the new-store session releases (any_active is 0)');
}

# ===========================================================================
# L5 -- store_root_for(): no seam, deterministic
# ===========================================================================
{
    my $home = fresh_home();
    my $t = tempdir(CLEANUP => 1);
    (my $dirA = "$t/A") =~ s{\\}{/}g;
    make_path($dirA);

    {
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $dirA;
        local $ENV{BUTLER_STATE_DIR}               = '';
        delete $ENV{BUTLER_STATE_DIR};
        is(LZ('store_root_for', $dirA), undef,
           'L5: CCPRAXIS_CONTINUITY_ACTIVE_DIR set, BUTLER_STATE_DIR empty -> store_root_for(A) is undef');
    }

    {
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $dirA;
        local $ENV{BUTLER_STATE_DIR}               = $home;
        is(LZ('store_root_for', $dirA), "$home/continuity",
           'L5: with both set, store_root_for(A) is $BUTLER_STATE_DIR/continuity');
    }

    {
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $dirA;
        local $ENV{BUTLER_STATE_DIR}               = $home;
        my (undef, $otherdir) = tempfile(DIR => $t, OPEN => 0);
        my $other = "$otherdir-other";
        make_path($other);
        is(LZ('store_root_for', $other), undef,
           'L5: store_root_for() of any OTHER directory is undef');
    }
}

# ===========================================================================
# L6 -- legacy_dir() agrees with the old continuity CLI's continuity_active_dir
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $abs = "$t/abs-override") =~ s{\\}{/}g;

    {
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $abs;
        delete local $ENV{HOME};
        delete local $ENV{USERPROFILE};
        is(LZ('legacy_dir'), $abs, 'L6: an absolute override is honoured');
    }
    {
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = 'relative/x';
        delete local $ENV{HOME};
        delete local $ENV{USERPROFILE};
        is(LZ('legacy_dir'), undef, 'L6: a relative override resolves to undef');
    }
    {
        delete local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
        local $ENV{HOME} = '/h/home1';
        delete local $ENV{USERPROFILE};
        is(LZ('legacy_dir'), '/h/home1/.claude/ccpraxis/.continuity-active',
           'L6: HOME alone resolves as the old continuity CLI would');
    }
    {
        delete local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
        delete local $ENV{HOME};
        local $ENV{USERPROFILE} = 'C:\\Users\\l6user';
        is(LZ('legacy_dir'), 'C:/Users/l6user/.claude/ccpraxis/.continuity-active',
           'L6: USERPROFILE alone resolves as the old continuity CLI would');
    }
}

# ===========================================================================
# L7 -- end to end through the CLI, no seam
# ===========================================================================
{
    my $home = fresh_home();
    my $legacy = fresh_legacy();

    sub run_cli {
        my (@args) = @_;
        my (undef, $outfile) = tempfile();
        my (undef, $errfile) = tempfile();
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
            $ENV{BUTLER_STATE_DIR}               = $home;
            $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
            $ENV{CCPRAXIS_NO_WAKELOCK}           = 1;
            # judged-continuity-disarm package 03 (spec sec 4.1): L7's
            # off-confirm call now dispatches the disarm judge after a
            # successful OTP claim; stub it to approve so this file never
            # spawns a real `claude -p` (DC7).
            $ENV{CCPRAXIS_DISARM_JUDGE_STUB}     = 'approve';
            open(STDOUT, '>', $outfile) or POSIX::_exit(126);
            open(STDERR, '>', $errfile) or POSIX::_exit(126);
            exec($^X, $CMD, @args);
            POSIX::_exit(127);
        }
        push @KILL_PIDS, $pid;
        my $deadline = time() + 30;
        my $rc;
        while (time() < $deadline) {
            my $w = waitpid($pid, WNOHANG);
            if ($w == $pid) { $rc = $? >> 8; last }
            sleep(0.05);
        }
        unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
        @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
        return (slurp($outfile), slurp($errfile), $rc);
    }

    my $sid = 'l7sess';
    my $p = { session_id => $sid, tool_use_id => 'tu1', transcript_path => "$home/x.jsonl", cwd => $home };
    # The in-process any_active($legacy) calls below resolve store_root_for()
    # internally, which compares $legacy against legacy_dir() -- computed
    # from CCPRAXIS_CONTINUITY_ACTIVE_DIR, exactly as the child subprocess
    # resolves it. Without setting it here too, legacy_dir() falls back to
    # the real HOME/USERPROFILE, store_root_for($legacy) never matches, and
    # any_active($legacy) can never see the new store this test just armed.
    local $ENV{BUTLER_STATE_DIR}               = $home;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;

    # Guard: this whole file must never resolve to the real registry/state
    # root. If either fell back to $HOME/$USERPROFILE, the assertions above
    # would still "pass" against the operator's own real continuity state.
    (my $abs_home   = $home)   =~ s{\\}{/}g;
    (my $abs_legacy = $legacy) =~ s{\\}{/}g;
    like(BpHook::state_dir(), qr/^\Q$abs_home\E/,
         'L7 guard: state_dir() resolves under this test\'s own tempdir');
    is(BpContinuityLease::legacy_dir(), $abs_legacy,
       'L7 guard: legacy_dir() resolves to this test\'s own tempdir, not the real HOME');

    # package 04-continuity-threads (Decision 36, spec 2.4): bare `on` now
    # refuses R1 (a thread is required). This block is about the wake-lock
    # following BpHook's arm state, not about thread attachment, so it arms
    # via `--role reporter` -- the one `on` form the spec exempts from the
    # thread requirement (spec 2.2.1/2.3 step 2b).
    BpHook::write_ticket($p, 'butler-continuity', ['on', '--role', 'reporter']);

    my ($out1, $err1, $rc1) = run_cli('on', '--role', 'reporter');
    is($rc1, 0, 'L7: on --role reporter exits 0') or diag("stderr: $err1");
    is(BpContinuityLease::any_active($legacy), 1, 'L7: after on, any_active(legacy_dir) is 1');

    # judged-continuity-disarm package 02 (AC-10): agent `off` now only mints
    # a disarm OTP (exit 1), leaving the lease active; the lease goes
    # inactive only once `off-confirm` actually disarms.
    my $p2 = { session_id => $sid, tool_use_id => 'tu2', transcript_path => "$home/x.jsonl", cwd => $home };
    BpHook::write_ticket($p2, 'butler-continuity', ['off', '--reason', 'a b']);
    my ($out2, $err2, $rc2) = run_cli('off', '--reason', 'a b');
    is($rc2, 1, 'L7: off --reason exits 1 (mints a disarm OTP, does not disarm yet)') or diag("stdout: $out2");
    is(BpContinuityLease::any_active($legacy), 1,
       'L7: after off (step one), any_active(legacy_dir) is still 1 (not yet disarmed)');

    my ($otp) = ($err2 =~ /^  butler-continuity off-confirm --otp ([0-9a-f]{8}) --justification '/m);
    ok(defined $otp, 'L7: off printed an 8-hex-char disarm OTP') or diag("stderr: $err2");

    my $p3 = { session_id => $sid, tool_use_id => 'tu3', transcript_path => "$home/x.jsonl", cwd => $home };
    BpHook::write_ticket($p3, 'butler-continuity',
        ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met']);
    my ($out3, $err3, $rc3) = run_cli('off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'goal is met');
    is($rc3, 0, 'L7: off-confirm --otp --justification exits 0') or diag("stderr: $err3");
    is(BpContinuityLease::any_active($legacy), 0, 'L7: after off-confirm, any_active(legacy_dir) is 0');
}

# ===========================================================================
# R4-M2 (redteam MEDIUM-2) -- an armed session whose transcript has had no
# activity for more than 1h does not hold the wake-lock through the
# new-store bridge, in parity with the legacy _marker_is_live check
# (TRANSCRIPT_LIVENESS_SECONDS, 3600s).
# ===========================================================================
{
    my $home = fresh_home();
    my $legacy = fresh_legacy();
    local $ENV{BUTLER_STATE_DIR}               = $home;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();

    my $sid = 'r4m2sess';
    my $tp = "$home/transcript.jsonl";
    open my $fh, '>', $tp or die $!;
    print {$fh} "x\n";
    close $fh;
    my $stale = time() - 3601;   # more than TRANSCRIPT_LIVENESS_SECONDS (1h)
    utime($stale, $stale, $tp);

    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $tp),
       'R4-M2 setup: BpHook::arm succeeds with a stale transcript_path');

    my $root = BpHook::state_dir();
    is(LZ('new_store_active', $root), 0,
       'R4-M2: an arm whose transcript has been quiet for over 1h does not count, in the new store');
}

# ===========================================================================
# R6-D53 (Decision 53, hook-continuity-remake blueprint.md): "an idle armed
# session keeps the machine awake for at most ONE HOUR. Idle means its
# transcript has had no activity... The lease counts an armed session only
# while its transcript was written in the last hour, and it no longer
# honours a 12-hour Stop-touch window." TODAY new_store_active ANDs the
# 1h transcript-liveness check with an OUTER ttl_hours() (12h) cutoff on the
# arm file's OWN mtime -- the mtime a Stop gate's G7 step refreshes on every
# Stop of an armed session. That outer cutoff is exactly the "12-hour
# Stop-touch window" Decision 53 retires: a session that has been
# genuinely, continuously active (fresh transcript right now) for MORE than
# 12 hours, whose arm file was written once at session start and never
# touched by any Stop since, is EXCLUDED today purely by that stale mtime,
# even though its transcript proves it is alive this very second. (a) below
# is that failing case. (b) and (c) are controls, already correct today
# (R4-M2 above is (b)'s twin, with an explicit Stop-touch simulation added).
# ===========================================================================
{
    # (a) FAILING today: arm-file mtime > 12h old (an arm() call from long
    # ago, never refreshed by any Stop's G7 touch), transcript written
    # within the last hour -> per Decision 53 this DOES hold the lease.
    my $home = fresh_home();
    local $ENV{BUTLER_STATE_DIR} = $home;
    local $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
    my $root = BpHook::state_dir();

    my $sid = 'd53a-old-arm-fresh-transcript';
    my $tp = "$home/transcript-a.jsonl";
    open my $fh, '>', $tp or die $!;
    print {$fh} "x\n";
    close $fh;    # transcript mtime is "now" -- well within the 1h window

    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $tp),
        'R6-D53(a) setup: arm succeeds');
    my $armed_path = "$root/armed/$sid";
    my $old_mtime = time() - 13 * 3600;    # > the 12h ttl_hours(), never Stop-touched since
    utime($old_mtime, $old_mtime, $armed_path);

    is(LZ('new_store_active', $root), 1,
        'R6-D53(a): a >12h-stale arm-file mtime (never Stop-touched) must NOT exclude a session whose transcript was written within the last hour');
}
{
    # (b) control, already correct today (R4-M2's twin, with the arm file's
    # mtime EXPLICITLY refreshed to simulate a Stop gate's G7 touch, right
    # now): a fresh arm-file mtime does not rescue a >1h-stale transcript.
    my $home = fresh_home();
    local $ENV{BUTLER_STATE_DIR} = $home;
    local $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
    my $root = BpHook::state_dir();

    my $sid = 'd53b-fresh-touch-stale-transcript';
    my $tp = "$home/transcript-b.jsonl";
    open my $fh, '>', $tp or die $!;
    print {$fh} "x\n";
    close $fh;
    my $stale = time() - 3601;    # more than TRANSCRIPT_LIVENESS_SECONDS (1h)
    utime($stale, $stale, $tp);

    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $tp),
        'R6-D53(b) setup: arm succeeds with a stale transcript');
    my $armed_path = "$root/armed/$sid";
    utime(undef, undef, $armed_path);    # simulate a Stop gate's G7 mtime touch, right now

    is(LZ('new_store_active', $root), 0,
        'R6-D53(b) control: a just-Stop-touched (fresh mtime) arm file with a >1h-stale transcript does NOT hold the lease');
}
{
    # (c) control, already correct today: both fresh -> holds.
    my $home = fresh_home();
    local $ENV{BUTLER_STATE_DIR} = $home;
    local $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
    my $root = BpHook::state_dir();

    my $sid = 'd53c-both-fresh';
    my $tp = "$home/transcript-c.jsonl";
    open my $fh, '>', $tp or die $!;
    print {$fh} "x\n";
    close $fh;

    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $tp),
        'R6-D53(c) setup: arm succeeds with a fresh transcript');

    is(LZ('new_store_active', $root), 1,
        'R6-D53(c) control: a fresh arm-file mtime and a fresh transcript DOES hold the lease');
}

# ===========================================================================
# R4-L-unreadable (batch C, spec 16-cutover C-6, reason SW): the
# legacy-OR-new-store composition this case pinned is deleted along with the
# legacy registry itself. any_active is single-source now, so a new store
# that cannot be read (armed/ is a file, not a directory -- a real,
# ENOTDIR-class opendir() failure) answers 0, exactly as an empty store
# would, REGARDLESS of a legacy marker (which is no longer consulted at all).
# ===========================================================================
{
    my $home = fresh_home();
    my $legacy = fresh_legacy();
    local $ENV{BUTLER_STATE_DIR}               = $home;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();

    my $root = BpHook::state_dir();
    make_path($root);
    open my $fh, '>', "$root/armed" or die $!;
    close $fh;

    mk_marker("$legacy/legacysess");   # the legacy registry says armed -- irrelevant now

    is(BpContinuityLease::any_active($legacy), 0,
       'R4-L-unreadable (-> C-6, SW): any_active is 0 when the new store cannot be read, regardless '
     . 'of a legacy marker -- the legacy fallback is gone');
}

done_testing();
