#!/usr/bin/env perl
# bp-keepawake.pl — the wake-lock, shared by every long-running butler driver.
#
# WHY THIS FILE EXISTS AS A FILE.
#
# The keep-awake mechanism was implemented in bp-drive-next.pl, for the SOLO
# driver — the path where a human is sitting in the session and would notice a
# suspended host. The FLEET orchestrator, which runs headless coordinators for
# hours with nobody watching, held no wake-lock at all. The lock existed on the
# path that needs it least and was absent from the one that needs it most.
#
# That is not hypothetical. 3c661a0 records a host suspending mid-run: a
# watchdog armed for 1800s reported 7962s elapsed (2h13m). It fixed solo only.
#
# The obvious fix — copy the six helpers into bp-orchestrator.pl — is the same
# mistake this repo has already paid for twice: match_any lives in two files and
# needed t/108 to guard the copies, and the token floor lived in three places
# (one of them an invisible default), which is exactly how the keeper silently
# ran a 1-hour floor for hours after the gate had moved to ten minutes. So the
# wake-lock gets ONE definition and both drivers call it.
#
# WHAT IT ACTUATES. The sandbox plugin's keep-awake.ps1, rather than
# re-deriving the P/Invoke. Both plugins ship from the same tree, so the relative
# path holds in the clone, in the live install, and under the container's
# marketplace mount.
#
# THIS BLOCK USED TO REPEAT THE HELPER'S CLAIM that ES_DISPLAY_REQUIRED is
# load-bearing on Modern Standby. MEASURED FALSE 2026-09-17 and dropped from the
# helper: the machine entered connected standby with that request held and
# refreshing, for "Reason: Idle Timeout", which no ES_* flag addresses. The
# reasoning now lives in ONE place -- keep-awake.ps1's header -- rather than
# being restated here, because a claim copied into a second file is a claim that
# gets corrected in only one of them. Read it there.
#
# WE PASS -PidFile, AND THE REASON MATTERS — the opposite choice leaked 2.7 GB.
#
# The original comment here said we deliberately did NOT pass it, because "it
# would write its own Windows pid over ours". That is exactly backwards, and it
# was measured on 2026-08-13: 52 orphaned keep-awake PowerShells, ~52 MB each,
# holding 2.7 GB and 52 simultaneous ES_CONTINUOUS wake-locks.
#
# FORK MEASUREMENT (ledger 07-one-keepawake-helper, 2026-11-04): on this host's
# Git-for-Windows perl ($^O cygwin), fork() gives a REAL MSYS child that
# waitpid reaps with the correct exit status, also after that child execs a
# native binary (powershell.exe). It is a real, independent OS process id,
# not a value confined to the forking process.
#
# What stayed true in 2026-08-13, and still matters: the fork return value is
# an MSYS pid, and everything that later reads keepawake.pid back -- tasklist
# in _pid_alive, stop_helper's image/cmdline checks, taskkill, and the
# helper's own pid-file identity -- works exclusively in WINPIDs (reviewer
# M1, step6: measured, a FRESH perl's kill(0, <another MSYS fork pid>) DOES
# return a true/false answer across processes; it is only waitpid that is
# limited to the forking process). An MSYS pid written to that file would be
# a number none of those WINPID-only readers could ever use, which is why
# the parent writes nothing (see spawn's closing comment below) regardless
# of which fork model is in play. Writing it into keepawake.pid produced 52
# orphaned keep-awake PowerShells, ~52 MB each, holding 2.7 GB and 52
# simultaneous ES_CONTINUOUS wake-locks. Each invocation concluded "no live
# lock" and spawned another one, and the release path could not kill the old
# one either, for the same reason. The mechanism leaked one PowerShell per
# invocation, forever.
#
# The helper's own $PID is a REAL Windows pid, valid across processes, and
# keep-awake.ps1 removes the file on exit — so a stale file means a dead helper
# and correctly triggers a respawn. That is the identity we need. Ours never was.
#
# Degrades honestly: no Windows, no helper, or a failed fork means no lock and a
# logged warning — never a false claim of holding one. That failure mode is the
# whole reason 3c661a0 exists (the production spawn/kill defaults were empty
# subs, so the director REPORTED managing a lock while holding none).

package BpKeepAwake;
use strict;
use warnings;
use File::Basename qw(dirname);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use Errno ();
use Cwd ();

# __FILE__ in drive-letter form (the claude-sandbox shim starts launcher.pl,
# and therefore KeepAwake.pm's require of THIS file, by a C:\ path) is
# rewritten to MSYS form (lower-cased drive letter, forward slashes) BEFORE
# Cwd::abs_path ever sees it, rather than trusting abs_path to do that
# translation itself. (Measured on this host, redteam-step6.md NIT-4:
# abs_path of an EXISTING forward-slash drive-letter string already resolves
# correctly, e.g. abs_path('C:/Development/ccpraxis') ->
# '/c/Development/ccpraxis' -- so this rewrite is cheap insurance against an
# unmeasured input shape, not a response to a reproduced failure.) Getting
# this wrong would leave helper_path() pointing at a path that does not
# exist (07-one-keepawake-helper spec 2.1).
my $DIR = dirname(do {
    (my $f = __FILE__) =~ s{\\}{/}g;
    if ($f =~ m{^([A-Za-z]):/(.*)$} && -d '/' . lc($1)) {
        $f = '/' . lc($1) . '/' . $2;
    }
    Cwd::abs_path($f) // $f;
});
require "$DIR/BpAwakeConst.pm" unless defined &BpAwakeConst::AC_STALE;

# STARTING_GRACE_SECONDS — how long a pid file with no pid in it counts as "a
# helper is coming up" rather than "nothing is here".
#
# THE HOLE THIS CLOSES, MEASURED 2026-09-15: fifteen live keep-awake.ps1
# helpers from a single registry, and the machine kept awake by all of them.
# spawn() returns as soon as the fork+exec is away, but keep-awake.ps1 does not
# write its own pid until PowerShell has started — of the order of a second, and
# more on a loaded box. Every apply() inside that window saw no pid file at all,
# concluded "no lock here", and spawned another. The idempotence check was
# perfect and simply had nothing to look at yet.
#
# So spawning now CLAIMS the pid file first, and an unfilled claim is read as
# "starting". 30s is far beyond any plausible PowerShell start and far short of
# the 900s lease, so a helper that truly failed to come up is still replaced
# long before its absence could matter.
our $STARTING_GRACE_SECONDS = 30;

# Read it through this rather than as $BpKeepAwake::STARTING_GRACE_SECONDS from
# another file. This is `require`d at RUNTIME, so a fully-qualified read
# elsewhere compiles before the `our` exists and perl warns "used only once:
# possible typo" — a warning that is indistinguishable from a real typo, which
# is the whole reason not to leave it standing.
sub starting_grace_seconds { return $STARTING_GRACE_SECONDS }

# should_be_on($phase) -> 0|1
# active / pause-pending -> hold the lock; settled -> release it.
# A timed pause still holds it: the whole point is to be awake when it ends.
sub should_be_on {
    my ($phase) = @_;
    return (defined $phase && ($phase eq 'active' || $phase eq 'pause-pending')) ? 1 : 0;
}

# helper_path() -> the keep-awake.ps1 path, canonical (no ".." segment).
#
# m2 (reviewer-step6.md): without this, the joined path carries
# "butler/scripts/../../sandbox/scripts/keep-awake.ps1" verbatim into every
# caller -- PowerShell resolves the ".." fine, but it changes the shape of
# every helper's -File argument from what a pre-07 caller produced, and
# stop_helper's cmdline match compares that argument AS STRING. Resolving it
# here, once, keeps every caller's -File (and any comparison against it)
# identical to the canonical form a pre-07 helper already carries.
# Cwd::abs_path returning undef (the usual "doesn't exist yet" case, though
# not expected here) falls back to the raw joined path rather than losing it.
sub helper_path {
    my $raw = "$DIR/../../sandbox/scripts/keep-awake.ps1";
    my $abs = Cwd::abs_path($raw);
    return defined $abs ? $abs : $raw;
}

# POSIX -> Windows form, for every path handed to powershell.exe.
#
# Hand-translated where possible, on purpose: powershell.exe accepts
# forward-slash drive-letter form whether or not MSYS2 path conversion is
# active, so that result is correct under EITHER conversion state — the
# technique CLAUDE.md prefers, because it cannot be broken by a caller's
# environment. Do NOT "simplify" this by setting MSYS2_ARG_CONV_EXCL instead:
# the opt-out and the translation are one technique, and splitting them is how
# paths end up created at the drive root.
#
# THE /tmp HOLE (137a741, restated here for the sandbox's launcher.pl, which
# this package -- 07-one-keepawake-helper, moving the launcher's own
# wake-lock spawn onto these two subs -- now lets us drop in favour of them):
# the hand-translation above only ever rewrote a `/<drive>/` prefix. A path
# under an MSYS mount such as /tmp (File::Spec->tmpdir()) is not
# `/<drive>/`-shaped, so it passed through unrewritten, reached
# powershell.exe bare, and Windows resolved the leading `/` against the
# current drive -- C:\tmp\..., a directory that usually does not exist. The
# helper could not write its pidfile, exited, and was respawned once a
# minute. Cygwin::posix_to_win_path is the MSYS runtime's own answer for
# "where does this MSYS path actually live", so step 5 below asks it for
# anything that isn't already handled by steps 2-4, and falls back to the
# untranslated POSIX string -- never a guess at a translation we have not
# measured -- when it has none.
#
# _winify_translate($abs) -> the Windows form of an already-absolute path.
# Steps 4-6 of the header's rule: a /<drive>/... prefix is hand-translated
# (unchanged from today); any other leading-/ path (an MSYS mount such as
# /tmp) is handed to Cygwin::posix_to_win_path when available, falling back
# to the untranslated absolute path when that isn't defined or returns
# nothing; a relative/unresolvable input is returned as-is (today's result).
sub _winify_translate {
    my ($abs) = @_;
    $abs =~ s{\\}{/}g;
    if ($abs =~ s{^/([a-zA-Z])/}{\u$1:/}) { return $abs }   # /<drive>/... -> X:/...
    if ($abs =~ m{^/[a-zA-Z]$}) {                            # bare drive root, e.g. "/c"
        (my $d = $abs) =~ s{^/([a-zA-Z])$}{\u$1:/};
        return $d;
    }
    if ($abs =~ m{^/} && defined &Cygwin::posix_to_win_path) {
        my $w = Cygwin::posix_to_win_path($abs, 1);
        if (defined $w && length $w) {
            $w =~ s{\\}{/}g;
            return $w;
        }
    }
    return $abs;
}

sub winify {
    my ($p) = @_;
    return $p unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    (my $slashed = $p) =~ s{\\}{/}g;
    # A POSIX-absolute input (/tmp/..., /c/..., any MSYS mount) is translated
    # AS GIVEN, never re-resolved through abs_path first: abs_path can rewrite
    # a path through its MOUNT TABLE (this host's /tmp maps onto a real
    # Windows directory), and feeding Cygwin's own translator the
    # mount-relative form vs. the resolved form picks a DIFFERENT (8.3 vs
    # long) component name for the SAME file -- measured on this host.
    # native_path (MountSpec.pm) never abs_path's its input either, so leaving
    # an absolute $p untouched here is what keeps the two in agreement (same
    # rule; butler does not load MountSpec).
    return _winify_translate($slashed) if $slashed =~ m{^/};
    # A drive-letter or relative input IS resolved through abs_path: this is
    # the only way an 8.3 short name (a real caller can hand one in -- this
    # host's own $ENV{TEMP} is short-form) resolves to the long form a
    # cmdline-matching caller (stop_helper's reused-pid guard) needs to
    # compare against. abs_path returning undef happens only when the path
    # does not exist, which leaves $slashed as-is. When it DOES exist,
    # abs_path resolves even an already-correct drive-letter string to its
    # POSIX form (measured, redteam-step6.md NIT-4:
    # abs_path('C:/Development/ccpraxis') -> '/c/Development/ccpraxis'), and
    # _winify_translate below converts that straight back to the SAME
    # drive-letter string -- which is why an already-correct 'C:/x/y' still
    # comes back unchanged.
    my $abs = Cwd::abs_path($slashed);
    return _winify_translate(defined $abs ? $abs : $slashed);
}

# winify for a path that does NOT exist yet (an output file). abs_path returns
# undef for a missing leaf, which would leave a POSIX "/c/..." or "/tmp/..."
# string to hand a native binary — and Windows resolves a leading "/" against
# the current drive, creating it at the DRIVE ROOT. That is the 576-stray
# incident in CLAUDE.md, so resolve the parent directory (which does exist)
# and re-attach the basename -- the translation itself then runs on that
# FULL joined path, never on the parent alone (a drive-root parent such as
# "/c" has no trailing slash for the /<drive>/ rule to match).
sub winify_out {
    my ($p) = @_;
    return $p unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    $p =~ s{\\}{/}g;
    my ($dir, $leaf) = $p =~ m{^(.*)/([^/]+)$} ? ($1, $2) : ('.', $p);
    my $abs_dir = Cwd::abs_path($dir);
    return winify($p) unless defined $abs_dir;   # parent missing too: best effort, as today
    # The parent's existence is only a GATE here (so a bogus directory still
    # falls back above). A POSIX-absolute $p is translated AS GIVEN -- see
    # winify's header on why re-resolving through abs_path first can change
    # which 8.3-vs-long component Cygwin's own translator picks for the SAME
    # file, which would stop this from matching MountSpec::native_path for
    # the identical input. A drive-letter or relative $p uses the RESOLVED
    # parent instead, so a short (8.3) name a real caller hands in (this
    # host's own $ENV{TEMP} is short-form) resolves to the long form a
    # cmdline-matching caller needs (stop_helper's reused-pid guard,
    # lease-refresher-hygiene.t's regression case).
    return _winify_translate($p) if $p =~ m{^/};
    $abs_dir =~ s{\\}{/}g;
    return _winify_translate("$abs_dir/$leaf");
}

# lease_seconds(\%opts?) -> non-negative integer. Pure. $opts->{lease_seconds}
# when it is a non-negative integer (as a string, /^\d+$/ -- "-1" and "x" are
# refused, not parsed); BpAwakeConst::HELPER_LEASE() otherwise, including when
# $opts is undef or not a HASH ref. Existing two-argument spawn() callers pass
# no %opts at all, so they keep today's 900s lease unchanged.
sub lease_seconds {
    my ($opts) = @_;
    return BpAwakeConst::HELPER_LEASE() unless ref $opts eq 'HASH';
    my $v = $opts->{lease_seconds};
    return BpAwakeConst::HELPER_LEASE() unless defined $v && $v =~ /^\d+$/;
    return 0 + $v;
}

# rotate_log($log_f, $max_bytes?) -> 1|0. Never dies. Renames $log_f to
# "$log_f.1" (replacing any existing .1) when its size exceeds $max_bytes
# (default 1 MiB), so a live helper's -LogFile stays bounded regardless of
# caller (spec B3). Anything that isn't "a file bigger than the ceiling" --
# missing, undef, exactly at the ceiling -- is left alone and returns 0.
sub rotate_log {
    my ($log_f, $max_bytes) = @_;
    $max_bytes = 1024 * 1024 unless defined $max_bytes && $max_bytes =~ /^\d+$/ && $max_bytes > 0;
    return 0 unless defined $log_f && length $log_f;
    my $sz = -s $log_f;
    return 0 unless defined $sz && $sz > $max_bytes;
    return rename($log_f, "$log_f.1") ? 1 : 0;
}

# Detect whether powershell.exe is resolvable.
#
# BY SEARCHING PATH, NOT BY RUNNING IT. The previous form answered this question
# by actually spawning `powershell.exe -Command "exit 0"` -- so the act of asking
# cost a powershell.exe plus the conhost.exe Windows attaches to it. Combined
# with the ordering bug in apply() (probe before idempotence check), that is what
# buried the operator's machine in processes on 2026-08-13 and forced a restart.
#
# Resolvability is a property of PATH, and PATH can be read. Nothing needs to be
# executed to answer it.
#
# Memoized: within one process the answer cannot change, and this is called from
# a path that runs on every director tick.
my $_PS_AVAILABLE;
sub ps_available {
    # Windows-only concern; in the Linux sandbox this is a documented no-op.
    return 0 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    return $_PS_AVAILABLE if defined $_PS_AVAILABLE;

    # PATHEXT is irrelevant here -- we look for an explicit .exe. Split on the
    # host separator: MSYS perl reports a ';'-joined PATH on Windows, but a
    # ':'-joined one is possible under some shells, so accept either.
    my $path = $ENV{PATH} // '';
    my @dirs = split /;/, $path;
    @dirs = split /:/, $path if @dirs <= 1;
    for my $d (@dirs) {
        next unless length $d;
        $d =~ s{\\}{/}g;
        $d =~ s{/+$}{};
        if (-x "$d/powershell.exe" || -e "$d/powershell.exe") {
            return $_PS_AVAILABLE = 1;
        }
    }
    return $_PS_AVAILABLE = 0;
}

# spawn($pid_file, \%owner?, \%opts?) -> pid | undef. DIES if the helper is
# missing or fork fails. %owner keys: owner_winpid, owner_desc -- see
# owner_desc_clean and winpid_of. Never pass $$, getppid() or a fork return
# value as owner_winpid: those are MSYS pids, meaningless to the helper's
# -OwnerWinPid (a WINPID namespace). %opts: lease_seconds (see lease_seconds()).
#
# The return value is the fork() return value itself: a real MSYS pid of the
# child this process just created. waitpid works only in the calling process
# -- the OS only lets a process reap ITS OWN child -- but kill and kill(0,
# $pid) work from ANY MSYS process against this same pid (07-one-keepawake-
# helper fork measurement, header above, and reviewer-step6.md's
# cross-process kill(0) probe). It is never a WINPID.
sub spawn {
    my ($pid_f, $owner, $opts) = @_;
    $owner //= {};
    return undef unless $^O =~ /^(MSWin32|msys|cygwin)$/;

    # A TEST MUST NEVER SPAWN A REAL, IMMORTAL OS WAKE-LOCK.
    #
    # Measured 2026-08-14, on the operator's machine, mid-session: 67 live
    # powershell.exe, 53 of them keep-awake.ps1 helpers whose -PidFile pointed
    # into TEST fixture directories (bp/, bp2/, bp-orphan/, bp-done/ under a
    # File::Temp root). bp-orchestrator.pl:2250 calls apply() with only a `log`
    # seam -- no `spawn` seam -- so the REAL spawn runs, and t/orchestrator-decision-core.t
    # drives that path. Every run of the butler suite leaked several helpers that
    # then slept forever. Running the suite repeatedly is what filled the machine.
    #
    # This is the same rule CLAUDE.md already states for launcher.pl ("never let
    # a test spawn it unguarded"), one level over: the wake-lock helper is an OS
    # process that outlives the test that made it.
    #
    # $0 is the script perl is running, and every test here is a .t run directly
    # (there is no prove on this host). Tests that legitimately exercise spawning
    # inject their own seam and never reach this sub, so nothing is lost -- and a
    # test that DID reach the real spawn was, by definition, leaking.
    return undef if $ENV{CCPRAXIS_NO_WAKELOCK};
    return undef if defined $0 && $0 =~ /\.t\z/;

    my $ps1 = helper_path();
    unless (-f $ps1) { die "keep-awake helper missing: $ps1\n" }
    require POSIX;
    # -LogFile: sits beside the pid file, so it lands in .drive-solo/ with the
    # rest of the run's state and is found by anyone already looking there.
    #
    # It answers the one question the previous instrumentation could not. When
    # the machine sleeps mid-run, either the wake-lock was held and Windows
    # slept anyway, or the lock had already been reaped and the sleep proves
    # nothing about ES_SYSTEM_REQUIRED. Nothing on disk distinguished those:
    # run.md has no timestamps, and the pid file's mtime is overwritten by the
    # very heartbeat whose history we would need. A RELEASE line now says
    # which, and a gap in HOLD lines is itself evidence.
    my $log_f = $pid_f;
    $log_f =~ s{keepawake\.pid$}{keepawake.log};
    # Rotated in the PARENT, before fork -- every caller's log is kept bounded
    # (a HOLD line a minute is ~115 KB/day), not just the launcher's own.
    rotate_log($log_f);
    # Read in the PARENT, before fork: see owner_started_before.
    my $owner_ticks = owner_started_before($owner);
    my $pid = fork();
    die "fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        # -LeaseSeconds: butler's callers (the orchestrator's per-tick apply(),
        # and drive-solo's) REFRESH the pid file on every tick that finds a live
        # lock, so this path is safe to lease -- and leasing it means an orphan
        # from a crashed driver, a forced restart or a WSL VM kill self-expires
        # within the lease instead of holding the display awake until reboot.
        #
        # The lease is opt-in precisely because launcher.pl's dashboard holder
        # passes lease_seconds => 0 and keeps hold-until-killed.
        my @extra;
        if (defined $owner->{owner_winpid} && $owner->{owner_winpid} =~ /^[1-9]\d*$/) {
            push @extra, '-OwnerWinPid', $owner->{owner_winpid};
            push @extra, '-OwnerStartedBeforeTicks', $owner_ticks if defined $owner_ticks;
        }
        my $clean_desc = owner_desc_clean($owner->{owner_desc});
        push @extra, '-OwnerDesc', $clean_desc if defined $clean_desc;
        exec('powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
             '-WindowStyle', 'Hidden', '-File', winify($ps1),
             '-PidFile', winify_out($pid_f),
             '-LeaseSeconds', lease_seconds($opts),
             '-LogFile', winify_out($log_f),
             @extra)
            or POSIX::_exit(127);
    }
    # The parent writes NOTHING. The pid namespaces don't match: the fork
    # return value is an MSYS pid, while -OwnerWinPid, tasklist and taskkill
    # all take WINPIDs -- so writing the MSYS pid here would give later
    # invocations a value none of those WINPID-only readers can validate
    # against, the leak described in the header. The helper writes its own
    # real Windows pid into $pid_f a moment from now, and removes it on exit.
    return $pid;
}

# child_alive($pid) -> 1 | 0 | undef. Liveness of a helper THIS PROCESS
# forked -- the pid spawn() just returned, never a WINPID. undef when $pid is
# undef, non-numeric or <= 0 (nothing to judge). waitpid(..., WNOHANG) answers
# exactly: 0 still running, == $pid once it has exited (reaping it in the same
# call). -1 means it is not ours to wait for any more (already reaped, or it
# never was our child); a signal-0 probe in the same MSYS namespace as the
# handle decides then. Never calls tasklist, CIM or any external process --
# that liveness question is answered elsewhere (stop_helper), for a WINPID.
sub child_alive {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    require POSIX;
    my $w = waitpid($pid, POSIX::WNOHANG());
    return 1 if $w == 0;
    return 0 if $w == $pid;
    return kill(0, $pid) ? 1 : 0;
}

# stop_child($pid, $pid_f) -> 1|0. Kills a helper THIS PROCESS forked (SIGKILL
# so it's immediate; waitpid reaps it, since it's a direct fork of ours) and
# clears the pid file. Returns 1 only when a kill was attempted (a positive
# integer pid); either way the pid file is unlinked if it exists. No logging
# here -- the caller logs, same as launcher.pl's _keepawake_stop did.
sub stop_child {
    my ($pid, $pid_f) = @_;
    my $killed = 0;
    if (defined $pid && $pid =~ /^\d+$/ && $pid > 0) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $killed = 1;
    }
    unlink $pid_f if defined $pid_f && -f $pid_f;
    return $killed;
}

# log_tail($log_f) -> the helper's own log's last non-blank line (<= 200
# chars, CR/LF stripped), read from the last 4096 bytes in :raw mode. undef
# for undef, a missing file, an empty file, or no non-blank line.
#
# MINOR-2 (redteam-step6.md): a graceful shutdown appends POWER-REQUEST-
# RELEASED and EXIT after its own RELEASE reason=... line, so the literal
# last line is never the interesting one -- every graceful exit would report
# "EXIT wake-lock released" as its cause in keepawake_died, burying the
# actual reason (owner-gone, pidfile-gone, ...) that survives in the file.
# When a RELEASE line is present in this window, prefer the LAST one over
# whatever (if anything) follows it; otherwise fall back to the literal last
# non-blank line, unchanged for a log with no RELEASE at all (a SIGKILL stop,
# per redteam-step6.md NIT-3).
sub log_tail {
    my ($log_f) = @_;
    return undef unless defined $log_f && -s $log_f;
    open(my $fh, '<:raw', $log_f) or return undef;
    my $size = -s $fh;
    seek($fh, $size > 4096 ? $size - 4096 : 0, 0);
    my @l = grep { /\S/ } <$fh>;
    close $fh;
    return undef unless @l;
    my @release = grep { /\bRELEASE\b/ } @l;
    my $last = @release ? $release[-1] : $l[-1];
    $last =~ s/[\r\n]+\z//;
    return substr($last, 0, 200);
}

# reap_orphan($pid_f, %seams) -> ($result, $winpid) | (). On dashboard/driver
# entry, stop a helper left running by a previously-crashed process (its
# wake-lock would otherwise persist forever). %seams forward unchanged to
# stop_helper (image_of, taskkill, cmdline_of, wait_seconds).
#
# Off the Windows family there is no helper mechanism at all: just clear a
# stale pid file, if any, with no external calls.
sub reap_orphan {
    my ($pid_f, %seams) = @_;
    unless ($^O =~ /^(MSWin32|msys|cygwin)$/) {
        unlink $pid_f if defined $pid_f && -e $pid_f;
        return ();
    }
    return () unless defined $pid_f && -f $pid_f;
    my $winpid = read_pid($pid_f);
    unless (defined $winpid && $winpid =~ /^[1-9]\d*$/) {
        unlink $pid_f;
        return ();
    }
    my $result = stop_helper($winpid, pid_f => $pid_f, %seams);
    unlink $pid_f;
    return ($result, $winpid);
}

# winpid_of($msys_pid) -> positive int | undef -- reads /proc/<pid>/winpid, the
# only reliable way to map an MSYS pid to the Windows pid Windows tools accept.
# Never falls back to the MSYS pid; returns undef off Windows.
sub winpid_of {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /^\d+$/;
    return undef unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    open(my $fh, '<', "/proc/$pid/winpid") or return undef;
    my $line = <$fh>;
    close $fh;
    return undef unless defined $line;
    $line =~ s/\s+//g;
    return ($line =~ /^[1-9]\d*$/) ? $line : undef;
}

sub self_winpid { return winpid_of($$) }

# owner_started_before(\%owner, $self_winpid?, $now?) -> FILETIME ticks string | undef
#
# The bound keep-awake.ps1 -OwnerStartedBeforeTicks checks the pinned owner
# against: our own clock reading, as UTC FILETIME ticks, taken in the parent
# before fork. If the owner dies before the helper pins its WINPID and Windows
# reuses that WINPID, the new holder was created after this reading and the
# helper rejects it rather than pinning an impostor (todo
# 20261002-002528-33130000).
#
# Only for a self-owned helper (owner_winpid is our own WINPID): "now" in a
# process that is alive is a valid upper bound on its own start, but says
# nothing about a foreign pid. Pure arithmetic, no spawn: asking PowerShell
# for the owner's exact start time (-OwnerStartTicks) instead puts a
# powershell.exe on the handover path, which was measured, against a control
# run, to break lease-refresher-hygiene.t's timing bounds under load.
sub owner_started_before {
    my ($owner, $self, $now) = @_;
    return undef unless ref $owner eq 'HASH';
    my $w = $owner->{owner_winpid};
    return undef unless defined $w && $w =~ /^[1-9]\d{0,9}$/;
    $self //= self_winpid();
    return undef unless defined $self && "$self" eq "$w";
    unless (defined $now) { require Time::HiRes; $now = Time::HiRes::time() }
    return undef unless !ref($now) && $now =~ /\A\d+(?:\.\d+)?\z/;
    # UTC FILETIME ticks (100ns units since 1601-01-01). This used to be
    # restated rather than shared with KeepAwake.pm's own filetime_ticks
    # (sandbox); that sub is gone (07-one-keepawake-helper DC2 deletes it),
    # so this is now the only copy of the arithmetic.
    return sprintf('%.0f', ($now + 11644473600) * 10_000_000);
}

# owner_desc_clean($s) -> string | undef -- sanitises an owner description so
# neither MSYS2 argv conversion nor Windows argv quoting can alter it: no ':',
# '/', space or quote survive. ASCII by construction (audit finding 22).
sub owner_desc_clean {
    my ($s) = @_;
    return undef unless defined $s && length $s;
    $s =~ s/[^A-Za-z0-9._,=#+-]/_/g;
    return substr($s, 0, 100);
}

# _production_image_of($winpid) -> image name | undef (undef = no such process)
sub _production_image_of {
    my ($winpid) = @_;
    return undef unless defined $winpid && $winpid =~ /^\d+$/;
    my $out = do {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        `tasklist /FI "PID eq $winpid" /FO CSV /NH 2>&1`;
    };
    return undef unless defined $out;
    for my $line (split /\r?\n/, $out) {
        next unless length $line;
        my @f = $line =~ /"([^"]*)"/g;
        next unless @f >= 2;
        return $f[0] if $f[1] eq $winpid;
    }
    return undef;
}

# _production_taskkill($winpid, $tree_flag) -- both streams captured and
# discarded; never redirected to NUL (house rule), nothing reaches the
# caller's STDOUT/STDERR because hooks call this path (AC-8).
sub _production_taskkill {
    my ($winpid, $tree) = @_;
    return unless defined $winpid && $winpid =~ /^\d+$/;
    my @cmd = ('taskkill.exe', '/PID', $winpid, '/F');
    push @cmd, '/T' if $tree;
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    my $cmdline = join(' ', map { qq{"$_"} } @cmd);
    my $out = `$cmdline 2>&1`;
    return;
}

# _production_cmdline_of($winpid) -> command line string | undef
#
# The reused-pid guard (S1): tasklist alone answers "is SOME powershell.exe
# running at this pid", which a reused pid satisfies for an operator's own
# PowerShell terminal or Claude Code's own tool process. This asks Windows for
# the full command line so stop_helper can also require that it is actually
# running keep-awake.ps1 against THIS pid file, before ever calling taskkill.
# One CIM query, on this rare release path only -- never inside a hot loop.
sub _production_cmdline_of {
    my ($winpid) = @_;
    return undef unless defined $winpid && $winpid =~ /^\d+$/;
    # [Console]::OutputEncoding=UTF8 is load-bearing, not decoration: without it
    # PowerShell writes its captured stdout in the console's active codepage
    # (measured: single-byte, non-UTF-8), and a path containing a non-ASCII
    # byte (CLAUDE.md: "Andre" with an accented e, this very host's home dir)
    # comes back mangled. Comparing that against the UTF-8 path we already hold
    # then always mismatches -- silently turning every reused-pid guard into
    # 'not-ours' for paths under this account. Measured directly, not guessed.
    my $out = do {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        `powershell.exe -NoProfile -Command "[Console]::OutputEncoding=[Text.Encoding]::UTF8; (Get-CimInstance Win32_Process -Filter 'ProcessId=$winpid').CommandLine" 2>&1`;
    };
    return undef unless defined $out;
    $out =~ s/^\s+//; $out =~ s/\s+$//;
    return length($out) ? $out : undef;
}

# stop_helper($winpid, %seams) -> 'gone' | 'not-ours' | 'still-alive' | 'invalid'
#
# Liveness is answered ONLY by Windows tools here -- no kill( at all. See the
# header: perl's kill(0,$pid) cannot validate a native Windows pid at all, and
# this is the path a Stop-gate hook reaches, so it must never print anything.
#
# %seams: image_of, taskkill, wait_seconds (existing); cmdline_of, pid_f (new,
# S1). The command-line identity check only runs when a caller supplies
# pid_f -- the path to the keepawake.pid file this winpid was read from --
# so existing callers/tests that never had a pid file to check against (unit
# tests seeding only image_of/taskkill) keep today's image-only behaviour.
# Every PRODUCTION caller (kill_pid, replace) always has a pid_f and always
# passes it, so the reused-pid guard is live everywhere it matters: a Stop
# gate release, a settled apply(), and replace's make-before-break swap.
sub stop_helper {
    # image_of defaults to _production_image_of (tasklist), taskkill defaults
    # to _production_taskkill (taskkill.exe). Liveness here comes only from
    # those two Windows tools; perl's own signal-based liveness call is never
    # used in this body.
    my ($winpid, %seams) = @_;
    return 'invalid' unless defined $winpid && $winpid =~ /^[1-9]\d*$/;
    my $image_of   = $seams{image_of}   // \&_production_image_of;
    my $taskkill   = $seams{taskkill}   // \&_production_taskkill;
    my $cmdline_of = $seams{cmdline_of} // \&_production_cmdline_of;
    my $wait_seconds = defined $seams{wait_seconds} ? $seams{wait_seconds} : 10;

    my $img = $image_of->($winpid);
    return 'gone' unless defined $img;
    return 'not-ours' unless lc($img) eq 'powershell.exe';

    if (defined $seams{pid_f}) {
        my $cmd = $cmdline_of->($winpid);
        my $want = lc(winify_out($seams{pid_f}));
        return 'not-ours'
            unless defined $cmd
                && lc($cmd) =~ /keep-awake\.ps1/
                && index(lc($cmd), $want) >= 0;
    }

    $taskkill->($winpid, 0);
    my $deadline = time() + $wait_seconds;
    while (time() < $deadline) {
        return 'gone' unless defined $image_of->($winpid);
        select(undef, undef, undef, 0.25);
    }
    return 'gone' unless defined $image_of->($winpid);

    $taskkill->($winpid, 1);
    my $deadline2 = time() + 2;
    while (time() < $deadline2) {
        return 'gone' unless defined $image_of->($winpid);
        select(undef, undef, undef, 0.25);
    }
    return defined $image_of->($winpid) ? 'still-alive' : 'gone';
}

sub kill_pid {
    my ($pid, $pid_f) = @_;
    return unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    if ($^O =~ /^(MSWin32|msys|cygwin)$/) {
        return stop_helper($pid, defined $pid_f ? (pid_f => $pid_f) : ());
    }
    kill('KILL', $pid);
    waitpid($pid, 0);
    return 'gone';
}

# _log_has_asserted($log_file, $pid) -> 0|1
#
# Reads the helper's OWN keepawake.log and looks for its "pid=$pid ASSERTED"
# line -- the confirmation that SetThreadExecutionState actually returned
# success for THAT pid (keep-awake.ps1's Write-KaLog at :249), not merely that
# the process exists or that its pid file has been overwritten. Best effort:
# a missing or unreadable log reads as "not yet".
sub _log_has_asserted {
    my ($log_f, $pid) = @_;
    return 0 unless defined $log_f && defined $pid && length $pid;
    open my $fh, '<', $log_f or return 0;
    my $text = do { local $/; <$fh> };
    close $fh;
    return 0 unless defined $text;
    return $text =~ /\bpid=\Q$pid\E\s+ASSERTED\b/ ? 1 : 0;
}

# replace($dir, \%opts) -> 'replaced' | 'none' | 'refused' | 'timeout'
#
# Starts a NEW helper without claiming or unlinking keepawake.pid -- the new
# helper overwrites it with its own pid unconditionally (Set-Content). The old
# helper is stopped only once BOTH of these hold, so the wake-lock itself is
# never dropped mid-swap (Decision 17(2), MUST-FIX M1: "started" is not
# "holding" -- the pid file is written before Add-Type/SetThreadExecutionState
# even run, so killing $old on pid-change alone can leave nothing holding the
# lock at all if the new helper then fails ASSERT):
#   1. keepawake.pid names something other than $old (the new helper is up), and
#   2. that new helper's own keepawake.log has logged its ASSERTED line (the
#      new helper actually holds the wake-lock).
# If the new helper never asserts within `grace`, $old is left running (it is
# the ONLY thing holding the lock) and the failed new helper is killed instead.
sub replace {
    my ($dir, $opts) = @_;
    $opts //= {};
    my $pid_f = "$dir/keepawake.pid";
    my $log_f = $pid_f;
    $log_f =~ s{keepawake\.pid$}{keepawake.log};
    my $spawn   = $opts->{spawn}         // \&spawn;
    my $killp   = $opts->{kill_pid}      // \&kill_pid;
    my $alive   = $opts->{pid_alive}     // \&_pid_alive;
    my $log     = $opts->{log}           // sub { };
    my $grace   = defined $opts->{grace} ? $opts->{grace} : $STARTING_GRACE_SECONDS;
    my $asserted = $opts->{log_has_asserted} // \&_log_has_asserted;

    my $old = -e $pid_f ? _read_pid($pid_f) : undef;
    return 'none' unless defined $old && $alive->($old);

    my %owner = (owner_winpid => $opts->{owner_winpid}, owner_desc => $opts->{owner_desc});
    my $new_pid = eval { $spawn->($pid_f, \%owner) };
    if ($@ || !defined $new_pid) {
        $log->("WARN keepawake replace refused old=$old");
        return 'refused';
    }

    my $deadline = time() + $grace;
    my $cur;
    while (time() < $deadline) {
        my $r = _read_pid($pid_f);
        if (defined $r && "$r" ne "$old") { $cur = $r; last; }
        select(undef, undef, undef, 0.25);
    }
    unless (defined $cur) {
        $log->("WARN keepawake replace timeout old=$old");
        return 'timeout';
    }

    while (time() < $deadline) {
        if ($asserted->($log_f, $cur)) {
            eval { $killp->($old, $pid_f) };
            $log->("keepawake replaced old=$old new=$cur");
            return 'replaced';
        }
        select(undef, undef, undef, 0.25);
    }
    eval { $killp->($cur, $pid_f) };
    $log->("WARN keepawake replace assert-timeout old=$old new=$cur");
    return 'timeout';
}

# _pid_alive($pid) -> 0|1
#
# perl's kill(0,$pid) is NOT a usable liveness test on Windows for a process
# perl did not create. $pid here is normally a WINPID (read back from a pid
# file keep-awake.ps1 wrote), and Git-for-Windows perl's kill/waitpid operate
# in the MSYS pid namespace -- a different numbering (CLAUDE.md: a pid is only
# meaningful in the namespace that produced it). Asking the MSYS namespace
# about a WINPID can return a true/false answer by coincidence (pid reuse
# across namespaces) but it is never proof either way for an unrelated native
# pid, which is exactly what the keep-awake helper is: a hit here is honoured
# below as a short-circuit (it is cheap and correct for OUR OWN forked
# children, kept live by keepawake-shared.t/keepawake-no-process-storm.t
# which pin it), but a miss falls through to asking Windows, never to a
# negative conclusion.
#
# That was the second half of the 2026-08-13 leak, and it hid behind the first:
# fixing the recorded pid alone changed nothing, because the CHECK was broken
# too. Measured directly — with a real, running helper pid in the file, two
# further invocations still spawned two more locks.
#
# So on Windows, ask Windows. tasklist costs one process per invocation, which
# at this cadence (once per director tick) is nothing next to leaking a 52 MB
# PowerShell forever.
sub _pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/ && $pid > 0;
    return kill(0, $pid) ? 1 : 0 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    return 1 if kill(0, $pid);                 # short-circuit: see header above
    # MSYS2 path conversion rewrites the SWITCHES: `/FI` arrives at tasklist as
    # `C:/Program Files/Git/FI` and it exits with "Invalid argument/option".
    # Measured, not guessed. Scope the opt-out to this one call (CLAUDE.md's
    # sanctioned form) — safe here because we pass no paths at all, so there is
    # nothing for the conversion to have been protecting.
    #
    # NO stderr redirect on purpose either: Git-for-Windows perl runs backticks
    # through sh, where `2>NUL` creates a literal file named NUL that Explorer
    # cannot delete (house rule), and `2>/dev/null` would be wrong if backticks
    # ever went through cmd.exe instead. tasklist's stderr is harmless.
    my $out = do {
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        `tasklist /FI "PID eq $pid" /NH`;
    };
    return 0 unless defined $out;
    return ($out =~ /\b\Q$pid\E\b/) ? 1 : 0;
}

# Public aliases for the two helpers above.
#
# BpContinuityLease needs exactly these facts — "is this recorded pid alive"
# and "what pid is recorded" — and both are already solved HERE, correctly, for
# the one platform that gets them wrong (see _pid_alive's header on why
# kill(0,$pid) lies about a native Windows process). Reaching into the
# underscore names from another package would be worse than either copying or
# exporting; copying is what this repo has paid for three times already. So they
# get a supported spelling instead.
sub pid_alive { return _pid_alive(@_) }
sub read_pid  { return _read_pid(@_)  }

sub _read_pid {
    my ($pid_f) = @_;
    open my $fh, '<', $pid_f or return undef;
    my $t = do { local $/; <$fh> };
    close $fh;
    return ($t && $t =~ /^(\d+)/) ? $1 : undef;
}

# apply($phase, $dir, \%opts) — idempotent. $dir is where keepawake.pid lives.
#
# %opts seams (all optional; production defaults actuate for real):
#   spawn / kill_pid / powershell_available — injectable for tests
#   log — coderef ->($message), so each driver logs to its own place
sub apply {
    my ($phase, $dir, $opts) = @_;
    $opts //= {};
    my $spawn = $opts->{spawn}                // \&spawn;
    my $killp = $opts->{kill_pid}             // \&kill_pid;
    my $ps_ok = $opts->{powershell_available} // \&ps_available;
    my $log   = $opts->{log}                  // sub { };
    my $pid_f = "$dir/keepawake.pid";
    my %owner = (owner_winpid => $opts->{owner_winpid}, owner_desc => $opts->{owner_desc});

    if (should_be_on($phase)) {
        # ORDER IS LOAD-BEARING: idempotence FIRST, availability probe second.
        #
        # It used to be the other way round, and that cost the operator a forced
        # machine restart on 2026-08-13 -- "a zillion powershell processes and
        # conhost processes", terminals unusable. ps_available() is not a cheap
        # predicate: it SPAWNS `powershell.exe -Command "exit 0"`, and Windows
        # gives every one of those its own conhost.exe. Probing before the
        # idempotence check meant the steady state -- lock already alive, nothing
        # to do -- still paid two process creations per call, and _pid_alive's
        # tasklist adds two more. The Stop hook calls the director on EVERY turn
        # end, so "per call" is not rare.
        #
        # Reordering makes the common path spawn nothing at all: if a live lock
        # exists we return before asking whether powershell is even present. The
        # probe now runs only when we are actually about to spawn, which is the
        # only moment its answer can change what we do.
        if (-e $pid_f) {
            my $pid = _read_pid($pid_f);
            if (_pid_alive($pid)) {
                # REFRESH THE LEASE. The pid file is a heartbeat as well as an
                # identity: keep-awake.ps1 polls its mtime and exits once it goes
                # stale (-LeaseSeconds, default 900). Touching it here -- on the
                # very tick that finds a live lock and leaves it alone -- is what
                # says "a run still wants this".
                #
                # Without this the lease would be a bug, not a safety net: it
                # would reap perfectly healthy locks mid-run. With it, the ONLY
                # locks that expire are the ones nobody is refreshing, which is
                # exactly the orphan case -- a driver that crashed, a forced
                # restart, a WSL VM kill. Before the lease, such a lock held
                # ES_DISPLAY_REQUIRED and kept the machine awake until reboot.
                my $now = time;
                utime($now, $now, $pid_f);
                return;
            }

            # An EMPTY pid file is a claim this code made just before spawning,
            # and the helper has not yet written itself into it. That is a lock
            # STARTING, not a lock missing — see $STARTING_GRACE_SECONDS for the
            # fifteen-helper storm that reading it the other way caused.
            #
            # -z, not !defined $pid: a file with unparseable CONTENT is corrupt,
            # not starting. Nothing is coming to fix it, so it is replaced now
            # rather than after a grace period spent waiting for nobody.
            if (-z $pid_f) {
                my $age = time - ((stat($pid_f))[9] // 0);
                return if $age < $STARTING_GRACE_SECONDS;
                $log->("WARN keepawake claim never filled after ${age}s; respawning");
            }

            # Either a recorded pid that is dead, or a claim that expired. Clear
            # it so the atomic claim below can be taken.
            unlink $pid_f;
        }
        return unless $ps_ok->();

        # CLAIM THE FILE ATOMICALLY, THEN SPAWN. O_EXCL is what makes "is a
        # helper already coming up?" and "I am the one starting it" a single
        # indivisible step, so the window between spawning and the helper
        # writing its own pid can no longer be read by anyone else as "nothing
        # here". That window is where the fifteen helpers came from.
        #
        # It does NOT make the whole function atomic, and it is not claimed to:
        # two callers that both find a DEAD pid recorded can both unlink it just
        # above and then both take a fresh claim in turn. Closing that would need
        # a lock around the read-decide-write as a whole. It is left open because
        # the caller-side rule removes it — only the refresher ever asks for a
        # hold, and it is single-instance by flock — and because the outcome
        # there is two helpers, not fifteen, with the loser's lease expiring.
        my $claim;
        unless (sysopen($claim, $pid_f, O_WRONLY | O_CREAT | O_EXCL)) {
            # EEXIST is the ordinary outcome of losing that race, and it is not
            # a problem — stay silent. Anything else (an unwritable registry, a
            # full disk) means no wake-lock will EVER be taken here, which is
            # exactly the kind of failure that must not be invisible.
            $log->("WARN keepawake cannot claim $pid_f: $!") unless $!{EEXIST};
            return;
        }
        close $claim;

        my $started = eval { $spawn->($pid_f, \%owner) };
        $log->("WARN keepawake spawn failed: $@") if $@;

        # A CLAIM NOBODY WILL FILL MUST NOT SURVIVE THE CALL THAT MADE IT.
        # spawn() returns undef when it declined — inside a .t, or under
        # CCPRAXIS_NO_WAKELOCK — and it dies when the fork or the helper file
        # fails. Either way nothing is coming, so leaving the claim would both
        # suppress the next 30s of attempts and, worse, fabricate the appearance
        # of a lease: t/runstate-pause-holds-lease.t pins exactly that ("a pause
        # never fabricates a lease from a test process"), and it caught this.
        unlink $pid_f if !defined $started && -e $pid_f && -z $pid_f;
    } else {
        if (-e $pid_f) {
            my $pid = _read_pid($pid_f);
            # NOT liveness-checked before the kill, deliberately, and this was
            # reconsidered on 2026-08-14 rather than assumed.
            #
            # A stale pid file is the normal residue of a hard kill (the helper
            # removes its own file on exit), and Windows reuses pids -- so the
            # recorded number can belong to an unrelated process. That argues for
            # checking liveness first. Two things outweigh it. Perl cannot signal
            # a native Windows process it did not create -- the same asymmetry
            # _pid_alive exists to work around -- so an unconditional kill against
            # a reused pid is very nearly a no-op here. And _pid_alive costs a
            # tasklist spawn, which is exactly the process pressure the rest of
            # this file was just fixed to stop paying.
            #
            # t/111 and t/17 both pin "release kills the recorded pid" with a
            # synthetic pid; adding the check silently broke both. Changing that
            # contract needs to be a decision, not a side effect of a perf fix.
            if (defined $pid) {
                my $r = eval { $killp->($pid, $pid_f) };
                $log->("WARN keepawake kill failed: $@") if $@;
                if (defined $r && $r =~ /^(?:gone|not-ours|still-alive|invalid)$/) {
                    my $msg = "keepawake stop winpid=$pid result=$r";
                    $msg = "WARN $msg" if $r eq 'still-alive' || $r eq 'not-ours';
                    $log->($msg);
                }
            }
            unlink $pid_f;
        }
    }
}

package main;
1;
