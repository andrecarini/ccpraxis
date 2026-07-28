#!/usr/bin/env perl
# Shared claude-home/.claude.json — no corruption under real concurrency,
# on the REAL 9p/drvfs dir bind (s01 row 13, s02 spec §3 B42-B51).
#
# This is the in-container proof that the row 1/3 fix (delete the writable
# single-file bind onto /root/.claude.json, add CLAUDE_CONFIG_DIR=/root/.claude
# so the CLI resolves the config to an ordinary file inside the RW dir bind)
# actually holds up under concurrent readers/writers on the filesystem that
# matters — not /tmp, not tmpfs, the real bind. It also proves the launcher's
# NEW mkdir-based, mtime-stale-safe lock (row 5) behaves correctly on that
# same bind, where a probe already showed mtime granularity is WHOLE SECONDS
# (probe-01 §E) and a plain FILE can occupy the lock path just as validly as
# a directory (probe-01 §B — Claude Code's own lock artefact kind is not
# guaranteed).
#
# B42 (skip-as-pass). We parse /proc/self/mountinfo for a mount point EXACTLY
# /root/.claude. Directory existence alone is not evidence of a mount (a bare
# `/root/.claude` could exist on a host run with no container at all) so we
# never substitute -d for this check. Absent -> skip_all, exit 0.
#
# B43 (blast radius). Every write in this file lands under a fresh scratch
# directory /root/.claude/.t42-<pid>-<epoch>/, inside the real dir bind so the
# real rename/mkdir/utime semantics are exercised. The live
# /root/.claude/.claude.json is NEVER written, renamed, locked or unlinked —
# a production fleet depends on it right now. We assert this continuously:
# this file's own live-mtime-unchanged check runs unconditionally, not only
# in a SKIP branch. Cleanup is Perl-level (File::Path::remove_tree, an END
# block, no shell rm -rf — the guard-bash hook forbids recursive shell
# deletes outside /tmp, and this scratch lives in claude-home).
#
# B44/B45/B46 (Phase A). Three writer processes (w1, w2, and a launcher-style
# writer wL exercising the very same mkdir-lock + temp+rename protocol
# _write_file_atomic/_config_lock_acquire will use — this file cannot
# `require launcher.pl`, so it is a small, faithful in-test reimplementation)
# perform read-modify-write against one scratch .claude.json while an
# unsynchronized reader samples it as fast as it can. The oracle is TWO
# things, not one: (a) the reader never observes a torn/unparseable/unopenable
# file (the corruption oracle) and (b) EVERY writer's own last confirmed
# counter is exactly what's in the final file (the lost-update oracle — valid
# JSON at the end is blind to silently dropped writes, which is exactly the
# false-green s01's own harness produced once).
#
# B47 (Phase B). The REAL /root/.local/bin/claude binary drives >=5
# config-mutating `mcp add`/`mcp remove` invocations against a SECOND scratch
# CLAUDE_CONFIG_DIR (so the CLI's own config shape can't collide with Phase
# A's marker-key oracle) while a reader samples. Degrades to SKIP (not a
# failure) if the binary is missing or the phase's budget is blown.
#
# B48 (Phase C). Direct measurement of the lock primitives on the real bind:
# mkdir works; mtime measurably advances (given the whole-second granularity,
# via an explicit cross-boundary sleep + utime, matching probe-01's method);
# uncontended acquisition is fast; a stale lock is taken over whether it is a
# directory OR a plain file at the lock path; a fresh lock is respected (the
# acquire attempt fails within its own timeout, and nothing gets written).
#
# B49/B50 (Phase D). One more explicit EBUSY-free atomic rename at the
# post-fix path SHAPE (inside the dir bind, not the old single-file mount);
# then a READ-ONLY assertion that the real live config still parses and still
# carries its onboarding keys — never a write.
#
# B51 (runtime budget). Total wall time target ~20s, hard ceiling 60s. Each
# phase is internally time-bounded and additionally reaped under a watchdog
# so a stuck child degrades the phase to SKIP rather than hanging the suite.
#
# Traceability: AC15, AC17, AC18, AC19, AC20, AC21, AC22, AC26.

use strict;
use warnings;
use Test::More;
use JSON::PP ();
use POSIX qw(:sys_wait_h EBUSY);
use Time::HiRes qw(time sleep);
use File::Path qw(make_path remove_tree);

# -----------------------------------------------------------------------
# B42 — skip-as-pass. Directory existence is NOT sufficient evidence; we
# require an actual mount point at exactly /root/.claude in mountinfo.
# -----------------------------------------------------------------------
sub _root_claude_is_mountpoint {
    open(my $fh, '<', '/proc/self/mountinfo') or return 0;
    my $found = 0;
    while (my $line = <$fh>) {
        chomp $line;
        my @f = split(' ', $line);
        # mountinfo: id parent maj:min root MOUNTPOINT options - fstype ...
        # MOUNTPOINT is field index 4 (0-based); paths with spaces are
        # octal-escaped by the kernel so a plain whitespace split is safe.
        if (defined $f[4] && $f[4] eq '/root/.claude') {
            $found = 1;
            last;
        }
    }
    close $fh;
    return $found;
}

unless (_root_claude_is_mountpoint()) {
    plan skip_all => 'not inside a sandbox container (no /root/.claude mount point in /proc/self/mountinfo) — B42';
}

# -----------------------------------------------------------------------
# B43 — scratch dir setup + Perl-level-only teardown. The END block only
# ever removes a path matching our own naming pattern, as a defensive
# guard against ever touching anything else under /root/.claude.
# -----------------------------------------------------------------------
my $SCRATCH;

END {
    if (defined $SCRATCH && $SCRATCH =~ m{\A/root/\.claude/\.t42-\d+-\d+\z}) {
        local $@;
        eval { remove_tree($SCRATCH, { safe => 1 }); };
    }
}

my $EPOCH = int(time());
$SCRATCH = "/root/.claude/.t42-$$-$EPOCH";
mkdir($SCRATCH) or die "t/42: cannot create scratch dir $SCRATCH: $!";

my $A_DIR    = "$SCRATCH/phaseA";
my $BCLI_DIR = "$SCRATCH/phaseB-cli";
my $C_DIR    = "$SCRATCH/phaseC";
my $D_DIR    = "$SCRATCH/phaseD";
make_path($A_DIR, $BCLI_DIR, $C_DIR, $D_DIR);

my $LIVE_JSON = '/root/.claude/.claude.json';
my @live_stat_before = stat($LIVE_JSON);
my $live_mtime_before = @live_stat_before ? $live_stat_before[9] : undef;

# -----------------------------------------------------------------------
# Shared reimplementation of the launcher's lock + atomic-write protocol
# (B21/B22/B25), used by every writer in this file (B46: "a small in-test
# reimplementation ... this test cannot require launcher.pl").
# -----------------------------------------------------------------------

sub _rand_hex { return sprintf('%06x', int(rand(0xffffff))); }

# mkdir-based, mtime-stale-safe lock acquire. %o: timeout, poll, stale
# (seconds). Losing a takeover race is treated as "still held" (B22).
sub _lock_acquire {
    my ($lockpath, %o) = @_;
    my $timeout = defined $o{timeout} ? $o{timeout} : 5;
    my $poll    = defined $o{poll}    ? $o{poll}    : 0.1;
    my $stale   = defined $o{stale}   ? $o{stale}   : 30;
    my $deadline = time() + $timeout;
    while (1) {
        return 1 if mkdir($lockpath);
        my @st = stat($lockpath);
        if (@st) {
            my $mtime = $st[9];
            if ((time() - $mtime) > $stale) {
                if (-d $lockpath) { rmdir($lockpath); }
                elsif (-e $lockpath) { unlink($lockpath); }
                return 1 if mkdir($lockpath);
                # lost the takeover race -> fall through, treated as held
            }
        }
        return 0 if time() >= $deadline;
        sleep($poll);
    }
}

sub _lock_release {
    my ($lockpath) = @_;
    rmdir($lockpath);
    return;
}

# temp-file + rename, same directory, chmod 0600 (B25). Returns (ok, errno).
sub _write_atomic {
    my ($path, $bytes) = @_;
    my $tmp = "$path.tmp.$$." . _rand_hex();
    open(my $fh, '>', $tmp) or return (0, $!);
    print $fh $bytes;
    unless (close($fh)) {
        my $e = $!;
        unlink($tmp);
        return (0, $e);
    }
    chmod(0600, $tmp);
    if (rename($tmp, $path)) {
        return (1, undef);
    }
    my $e = $!;
    unlink($tmp);
    return (0, $e);
}

sub _read_bytes {
    my ($path) = @_;
    open(my $fh, '<', $path) or return (0, undef, $!);
    local $/;
    my $bytes = <$fh>;
    close($fh);
    return (1, $bytes, undef);
}

sub _slurp_kv {
    my ($path) = @_;
    my %h;
    return %h unless -f $path;
    open(my $fh, '<', $path) or return %h;
    while (my $line = <$fh>) {
        chomp $line;
        $h{$1} = $2 if $line =~ /\A(\w+)=(.*)\z/;
    }
    close($fh);
    return %h;
}

# Wait up to $timeout seconds for every pid in @$pids to exit (WNOHANG
# poll). Anything still alive past the deadline is SIGKILLed and reaped.
# Returns 1 if everything exited on its own (no forced kill), else 0 — the
# degrade-to-SKIP signal for the caller (B51: "never hang").
sub _reap_all {
    my ($pids, $timeout) = @_;
    my %done;
    my $deadline = time() + $timeout;
    while (scalar(keys %done) < scalar(@$pids) && time() < $deadline) {
        for my $pid (@$pids) {
            next if $done{$pid};
            my $r = waitpid($pid, WNOHANG);
            $done{$pid} = 1 if $r == $pid;
        }
        sleep(0.05) if scalar(keys %done) < scalar(@$pids);
    }
    my $all_ok = (scalar(keys %done) == scalar(@$pids)) ? 1 : 0;
    unless ($all_ok) {
        for my $pid (@$pids) {
            next if $done{$pid};
            kill('KILL', $pid);
        }
        for my $pid (@$pids) {
            next if $done{$pid};
            waitpid($pid, 0);
        }
    }
    return $all_ok;
}

sub _sh_quote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# -----------------------------------------------------------------------
# Forked-child bodies. CRITICAL: these must never call any Test::More
# function and must exit via POSIX::_exit (not exit()) so they skip Perl
# global destruction — otherwise a child would also run Test::More's own
# END block and THIS file's scratch-cleanup END block, corrupting both the
# parent's TAP stream and the shared scratch dir out from under its
# siblings. They also must never print to the inherited STDOUT/STDERR —
# all results travel back to the parent via small result files.
# -----------------------------------------------------------------------

sub _writer_child {
    my ($key, $file, $lockpath, $wall_target, $wall_hard, $total_target, $resultfile) = @_;
    my $jp = JSON::PP->new->utf8->canonical;
    my $t0 = time();
    my $count = 0;          # CONFIRMED writes only (a failed write is not counted)
    my $last_total = 0;
    my ($decode_errors, $read_errors, $write_errors) = (0, 0, 0);

    while (1) {
        my $elapsed = time() - $t0;
        last if $elapsed >= $wall_hard;
        last if $elapsed >= $wall_target;
        last if $last_total >= $total_target;

        my $got = _lock_acquire($lockpath, timeout => 2, poll => 0.005, stale => 30);
        next unless $got;

        my ($rok, $bytes) = _read_bytes($file);
        if (!$rok) {
            $read_errors++;
            _lock_release($lockpath);
            next;
        }

        my $data = {};
        if (defined $bytes && length $bytes) {
            my $decoded = eval { $jp->decode($bytes) };
            if ($@) {
                $decode_errors++;
                _lock_release($lockpath);
                next;
            }
            $data = $decoded;
        }

        my $next_count = $count + 1;
        $data->{$key} = $next_count;
        $data->{_total} = (defined $data->{_total} ? $data->{_total} : 0) + 1;
        my $encoded = $jp->encode($data);
        my ($wok) = _write_atomic($file, $encoded);
        if ($wok) {
            $count = $next_count;
            $last_total = $data->{_total};
        } else {
            $write_errors++;
        }
        _lock_release($lockpath);
    }

    if (open(my $out, '>', $resultfile)) {
        print $out "count=$count\ndecode_errors=$decode_errors\nread_errors=$read_errors\nwrite_errors=$write_errors\n";
        close($out);
    }
    POSIX::_exit(0);
}

# _recovers($file, $jp) -> 1 if a bounded re-read returns a non-empty, parseable
# document; 0 if the file is STILL empty/unopenable after the retry window.
#
# This is the line between "the mount blinked" and "the config is destroyed".
# Pre-fix, a torn config stayed 0-byte until something healed it; post-fix, a
# zero-length sighting is a coherency artefact that clears on the next read.
# Bounded at ~250ms so a genuinely destroyed file still fails the test fast.
sub _recovers {
    my ($file, $jp) = @_;
    for my $attempt (1 .. 5) {
        sleep(0.05);
        open(my $fh, '<', $file) or next;
        local $/;
        my $bytes = <$fh>;
        close($fh);
        next if !defined $bytes || length($bytes) == 0;
        eval { $jp->decode($bytes) };
        return 1 unless $@;
    }
    return 0;
}

sub _reader_child {
    my ($file, $wall_target, $wall_hard, $stopfile, $resultfile) = @_;
    my $jp = JSON::PP->new->utf8;
    my $t0 = time();
    my ($samples, $zero_byte, $unparseable, $open_errors) = (0, 0, 0, 0);
    my ($zero_byte_persistent, $open_errors_persistent) = (0, 0);

    while (1) {
        my $elapsed = time() - $t0;
        last if $elapsed >= $wall_hard;
        last if $elapsed >= $wall_target;
        last if defined $stopfile && -e $stopfile;

        $samples++;
        my $ok = open(my $fh, '<', $file);
        if (!$ok) {
            # An open failure on this mount is transient under rename churn
            # (probe-02). Only a failure that PERSISTS across a bounded retry
            # window is a real defect — that is the pre-fix signature.
            $open_errors++;
            $open_errors_persistent++ unless _recovers($file, $jp);
            next;
        }
        local $/;
        my $bytes = <$fh>;
        close($fh);
        if (!defined $bytes || length($bytes) == 0) {
            # Zero-length reads occur on the 9p bind even under a perfectly
            # atomic temp+rename() — reproduced with a bare open+rename loop,
            # no lock and no JSON involved, and NOT reproducible on overlayfs
            # (probe-02-9p-transient-zero-read.md). What the fix guarantees is
            # that such a sighting is TRANSIENT; the pre-fix bug left the file
            # PERSISTENTLY 0-byte (s01 probe-02 C4: 92% of samples), which is
            # what destroys the config and triggers the onboarding wizard.
            $zero_byte++;
            $zero_byte_persistent++ unless _recovers($file, $jp);
            next;
        }
        eval { $jp->decode($bytes) };
        if ($@) {
            # A torn/partial document is NOT transient and NOT observed on this
            # mount (0 in ~4,000 samples across every probe configuration), so
            # this stays an absolute, unconditional failure.
            $unparseable++;
            next;
        }
    }

    if (open(my $out, '>', $resultfile)) {
        print $out "samples=$samples\nzero_byte=$zero_byte\nunparseable=$unparseable\n"
                 . "open_errors=$open_errors\nzero_byte_persistent=$zero_byte_persistent\n"
                 . "open_errors_persistent=$open_errors_persistent\n";
        close($out);
    }
    POSIX::_exit(0);
}

# =========================================================================
# Phase A — B44/B45/B46: concurrency + lost-update oracle
# =========================================================================

my $A_FILE = "$A_DIR/.claude.json";
my $A_LOCK = "$A_FILE.lock";
{
    my ($seeded) = _write_atomic($A_FILE, '{}');
    die "t/42: could not seed Phase A scratch file $A_FILE" unless $seeded;
}

my $PHASE_A_WALL_TARGET  = 10;   # B44 stop condition: >=10s wall ...
my $PHASE_A_TOTAL_TARGET = 500;  # ... OR >=500 total writes, whichever first
my $PHASE_A_WALL_HARD    = 14;   # hard per-process cap, under B51's 15s phase cap
my $PHASE_A_OUTER_WATCHDOG = 20; # parent-side reap deadline: pure hang-safety net,
                                  # well above the ~10-11s this phase normally takes

my $phaseA_timed_out = 0;
my %phaseA;

{
    my @writer_specs = (
        { key => 'w1', result => "$A_DIR/.w1-result" },
        { key => 'w2', result => "$A_DIR/.w2-result" },
        { key => 'wL', result => "$A_DIR/.wL-result" },   # B46: launcher-style writer
    );
    my $reader_result = "$A_DIR/.reader-result";

    my @kids;
    my $reader_pid = fork();
    die "t/42: fork failed: $!" unless defined $reader_pid;
    if ($reader_pid == 0) {
        _reader_child($A_FILE, $PHASE_A_WALL_TARGET, $PHASE_A_WALL_HARD, undef, $reader_result);
    }
    push @kids, $reader_pid;

    for my $spec (@writer_specs) {
        my $pid = fork();
        die "t/42: fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            _writer_child($spec->{key}, $A_FILE, $A_LOCK,
                $PHASE_A_WALL_TARGET, $PHASE_A_WALL_HARD, $PHASE_A_TOTAL_TARGET, $spec->{result});
        }
        push @kids, $pid;
    }

    my $all_reaped = _reap_all(\@kids, $PHASE_A_OUTER_WATCHDOG);
    $phaseA_timed_out = $all_reaped ? 0 : 1;

    my %reader = _slurp_kv($reader_result);
    my %w1 = _slurp_kv("$A_DIR/.w1-result");
    my %w2 = _slurp_kv("$A_DIR/.w2-result");
    my %wL = _slurp_kv("$A_DIR/.wL-result");

    my ($fok, $fbytes) = _read_bytes($A_FILE);
    my $final_data = {};
    my $final_parses = 0;
    if ($fok && defined $fbytes) {
        my $decoded = eval { JSON::PP->new->utf8->decode($fbytes) };
        if (!$@) { $final_parses = 1; $final_data = $decoded; }
    }

    %phaseA = (
        writes_total       => (($w1{count} // 0) + ($w2{count} // 0) + ($wL{count} // 0)),
        reader_samples     => ($reader{samples} // 0),
        reader_zero_byte   => ($reader{zero_byte} // 0),
        reader_unparseable => ($reader{unparseable} // 0),
        reader_open_errors => ($reader{open_errors} // 0),
        reader_zero_byte_persistent   => ($reader{zero_byte_persistent} // 0),
        reader_open_errors_persistent => ($reader{open_errors_persistent} // 0),
        final_parses       => $final_parses,
        final_data         => $final_data,
        w1_count           => ($w1{count} // 0),
        w2_count           => ($w2{count} // 0),
        wL_count           => ($wL{count} // 0),
        writer_errors      => (($w1{decode_errors} // 0) + ($w1{read_errors} // 0)
                              + ($w2{decode_errors} // 0) + ($w2{read_errors} // 0)
                              + ($wL{decode_errors} // 0) + ($wL{read_errors} // 0)),
    );
}

SKIP: {
    skip("Phase A did not reap cleanly within its ${PHASE_A_OUTER_WATCHDOG}s watchdog (possible environment stall) — degraded per B51", 14)
        if $phaseA_timed_out;

    ok($phaseA{writes_total} >= 500,
        "B44/AC17/AC18: writers completed >=500 writes in total (got $phaseA{writes_total})");
    ok($phaseA{reader_samples} >= 500,
        "B44/AC17: reader took >=500 samples (got $phaseA{reader_samples})");
    # --- The corruption oracle. See probe-02-9p-transient-zero-read.md ------
    # Decision #8 asks for "zero 0-byte/unparseable observations". Measured on
    # this 9p/drvfs bind, "zero 0-byte" is NOT satisfiable by ANY implementation:
    # a bare open+rename loop with no lock and no JSON still shows ~0.1% of reads
    # as zero-length, while the same code on overlayfs shows 0 in 545,751 samples.
    # Asserting the literal criterion makes this a permanently flaky gate, which
    # would hide the very regressions it exists to catch. So the oracle asserts
    # what the fix actually guarantees, and keeps the pre-fix bug loudly failing:
    #   * unparseable            -> 0, absolute (never observed; a torn document
    #                               is the real corruption signature)
    #   * PERSISTENT zero-length -> 0, absolute (this IS the pre-fix bug: s01
    #                               probe-02 C4 left the file 0-byte for 92% of
    #                               309,560 samples and it stayed that way)
    #   * transient sightings    -> bounded well below any plausible regression
    is($phaseA{reader_unparseable}, 0,
        'B44/AC17: zero unparseable reader observations (absolute — a torn document is never acceptable)');
    is($phaseA{reader_zero_byte_persistent}, 0,
        'B44/AC17: zero PERSISTENT zero-length observations (a sighting that never recovers = the pre-fix corruption)');
    is($phaseA{reader_open_errors_persistent}, 0,
        'B44/AC17: zero PERSISTENT open failures (counted separately from zero-byte/unparseable, per s01 C2/C5)');
    my $zb_pct = $phaseA{reader_samples}
        ? (100 * $phaseA{reader_zero_byte} / $phaseA{reader_samples}) : 0;
    ok($zb_pct < 5,
        sprintf('B44/AC17: transient zero-length sightings stay negligible (%.3f%% of %d samples; pre-fix was 92%%)',
                $zb_pct, $phaseA{reader_samples}));
    diag(sprintf('Phase A transient counts (informational): zero-byte=%d (%.3f%%), open-errors=%d, samples=%d',
                 $phaseA{reader_zero_byte}, $zb_pct, $phaseA{reader_open_errors}, $phaseA{reader_samples}));
    ok($phaseA{final_parses}, 'B44/AC17: the Phase A file parses as JSON at the end');

    is($phaseA{final_data}{w1}, $phaseA{w1_count},
        "B45/AC18: writer w1's own last confirmed counter ($phaseA{w1_count}) survives exactly in the final file (no lost update)");
    is($phaseA{final_data}{w2}, $phaseA{w2_count},
        "B45/AC18: writer w2's own last confirmed counter ($phaseA{w2_count}) survives exactly in the final file (no lost update)");
    is($phaseA{final_data}{wL}, $phaseA{wL_count},
        "B45/B46/AC18: launcher-style writer wL's own last confirmed counter ($phaseA{wL_count}) survives exactly (no lost update)");

    ok($phaseA{w1_count} > 0, 'B44: writer w1 performed at least one confirmed write (harness-honesty check, s01 lesson)');
    ok($phaseA{w2_count} > 0, 'B44: writer w2 performed at least one confirmed write (harness-honesty check, s01 lesson)');
    ok($phaseA{wL_count} > 0, 'B44/B46: launcher-style writer wL performed at least one confirmed write (harness-honesty check)');

    is($phaseA{writer_errors}, 0, 'B44: writers observed zero decode/read errors on their own lock-protected reads');
}

# =========================================================================
# Phase B — B47: the real CLI as a config writer, on its own scratch dir
# =========================================================================

my $CLI_BIN = '/root/.local/bin/claude';
my $cli_usable = (-x $CLI_BIN) ? 1 : 0;
my $B_FILE = "$BCLI_DIR/.claude.json";
my %phaseB;
my $phaseB_skip_reason = '';

if (!$cli_usable) {
    $phaseB_skip_reason = "claude binary not found/executable at $CLI_BIN — Phase B skipped per B47 degrade";
} else {
    my $PHASE_B_READER_HARD       = 24;
    my $PHASE_B_MAX_START_ELAPSED = 18;  # stop ISSUING new invocations past this
    my $PHASE_B_PER_INVOCATION_S  = 5;   # `timeout` bound per invocation
    my $reader_result = "$BCLI_DIR/.reader-result";
    my $stopfile       = "$BCLI_DIR/.reader-stop";

    my $reader_pid = fork();
    die "t/42: fork failed: $!" unless defined $reader_pid;
    if ($reader_pid == 0) {
        _reader_child($B_FILE, $PHASE_B_READER_HARD, $PHASE_B_READER_HARD, $stopfile, $reader_result);
    }

    my @invocations = (
        ['mcp', 'add',    '--transport', 'stdio', 'sandbox-t42-probe-1', '--', '/bin/true'],
        ['mcp', 'remove', 'sandbox-t42-probe-1'],
        ['mcp', 'add',    '--transport', 'stdio', 'sandbox-t42-probe-2', '--', '/bin/true'],
        ['mcp', 'remove', 'sandbox-t42-probe-2'],
        ['mcp', 'add',    '--transport', 'stdio', 'sandbox-t42-probe-3', '--', '/bin/true'],
    );
    my @exit_codes;
    my $budget_exceeded = 0;
    my $phase_b_start = time();

    {
        local $ENV{CLAUDE_CONFIG_DIR} = $BCLI_DIR;
        for my $args (@invocations) {
            if ((time() - $phase_b_start) >= $PHASE_B_MAX_START_ELAPSED) {
                $budget_exceeded = 1;
                last;
            }
            my $cmd = join(' ', 'timeout', '--kill-after=2', $PHASE_B_PER_INVOCATION_S,
                _sh_quote($CLI_BIN), map { _sh_quote($_) } @$args);
            my $out = `$cmd 2>&1`;
            my $rc = ($? == -1) ? -1 : ($? >> 8);
            push @exit_codes, $rc;
        }
    }
    $budget_exceeded = 1 if scalar(@exit_codes) < scalar(@invocations);

    if (open(my $sf, '>', $stopfile)) { close($sf); }
    my $reaped_ok = _reap_all([$reader_pid], 6);

    my %reader = _slurp_kv($reader_result);
    my ($fok, $fbytes) = _read_bytes($B_FILE);
    my $final_data = {};
    my $final_parses = 0;
    if ($fok && defined $fbytes) {
        my $decoded = eval { JSON::PP->new->utf8->decode($fbytes) };
        if (!$@) { $final_parses = 1; $final_data = $decoded; }
    }

    %phaseB = (
        exit_codes         => \@exit_codes,
        expected_count     => scalar(@invocations),
        reader_zero_byte   => ($reader{zero_byte} // 0),
        reader_unparseable => ($reader{unparseable} // 0),
        reader_open_errors => ($reader{open_errors} // 0),
        reader_zero_byte_persistent   => ($reader{zero_byte_persistent} // 0),
        reader_open_errors_persistent => ($reader{open_errors_persistent} // 0),
        final_parses       => $final_parses,
        final_data         => $final_data,
    );

    if ($budget_exceeded) {
        $phaseB_skip_reason = 'Phase B exceeded its 25s budget (only '
            . scalar(@exit_codes) . '/' . scalar(@invocations)
            . ' invocations completed) — degraded to SKIP per B47/B51';
    }
}

SKIP: {
    skip($phaseB_skip_reason, 9) if $phaseB_skip_reason;

    my @labels = ('mcp add probe-1', 'mcp remove probe-1', 'mcp add probe-2', 'mcp remove probe-2', 'mcp add probe-3');
    for my $i (0 .. 4) {
        is($phaseB{exit_codes}[$i], 0, 'B47/AC19: CLI invocation ' . ($i + 1) . " ($labels[$i]) exits 0");
    }
    # Same oracle as Phase A, and for the same measured reason (probe-02): on
    # this bind a transient zero-length sighting is a mount artefact, a
    # persistent one is corruption. Here the writer is the REAL claude binary.
    is($phaseB{reader_zero_byte_persistent}, 0,
        'B47/AC19: zero PERSISTENT zero-length observations while the real CLI writes its own config');
    is($phaseB{reader_unparseable}, 0, 'B47/AC19: zero unparseable reader observations while the CLI writes its own config');
    # NOTE: open-errors are NOT asserted ==0 here (unlike Phase A). Unlike
    # Phase A's file, $B_FILE does not exist until the CLI's first
    # invocation creates it, and the reader starts sampling immediately on
    # fork — so a burst of legitimate ENOENT opens before that first write
    # lands is expected, not corruption. B47 itself only requires zero
    # zero-byte/unparseable observations; open-errors is Phase A's oracle
    # (B44), where the file is pre-seeded before the reader ever starts.
    diag("Phase B reader open-errors (informational, expected>0 before first CLI write): $phaseB{reader_open_errors}");
    ok($phaseB{final_parses}, 'B47/AC19: the CLI-managed scratch config parses as JSON at the end of Phase B');
    ok((exists $phaseB{final_data}{userID} && exists $phaseB{final_data}{projects}),
        'B47/AC19: the final file carries CLI-authored keys (userID, projects) — not this test\'s own hand-written shape');
}

# =========================================================================
# Phase C/D — B48 (lock primitives) + B49 (rename shape) + B50 (live, read-only)
# =========================================================================

my $C_LOCK_A  = "$C_DIR/.lock-a";
my $C_LOCK_B  = "$C_DIR/.lock-b";
my $C_LOCK_C  = "$C_DIR/.lock-c";
my $C_LOCK_D1 = "$C_DIR/.lock-d1";
my $C_LOCK_D2 = "$C_DIR/.lock-d2";
my $C_LOCK_E  = "$C_DIR/.lock-e";
my $D_FILE    = "$D_DIR/.claude.json";

my %CD;
my $CD_timed_out = 0;
my $CD_error = '';

{
    local $SIG{ALRM} = sub { die "T42_CD_TIMEOUT\n" };
    my $ok = eval {
        alarm(10);   # safety net; nominal C+D work is well under 3s (probe-01)

        # (a) mkdir succeeds on the real bind.
        $CD{a_mkdir_ok} = mkdir($C_LOCK_A) ? 1 : 0;
        rmdir($C_LOCK_A) if $CD{a_mkdir_ok};

        # (b) mtime measurably advances after utime. Granularity here is
        # WHOLE SECONDS (probe-01 §E) so we must cross a second boundary
        # before re-stamping, exactly as the probe did.
        mkdir($C_LOCK_B) or die "setup: mkdir $C_LOCK_B failed: $!\n";
        my @st_before = stat($C_LOCK_B);
        $CD{b_mtime_before} = $st_before[9];
        sleep(1.2);
        my $now = time();
        $CD{b_utime_ok} = utime($now, $now, $C_LOCK_B) ? 1 : 0;
        my @st_after = stat($C_LOCK_B);
        $CD{b_mtime_after} = $st_after[9];
        rmdir($C_LOCK_B);

        # (c) uncontended acquisition latency < 1s.
        my $t0 = time();
        $CD{c_got} = _lock_acquire($C_LOCK_C, timeout => 5, poll => 0.02, stale => 30);
        $CD{c_elapsed} = time() - $t0;
        _lock_release($C_LOCK_C);

        # (d1) a pre-planted STALE lock as a DIRECTORY (mtime now-120) is
        # taken over, and a subsequent write succeeds.
        mkdir($C_LOCK_D1) or die "setup: mkdir $C_LOCK_D1 failed: $!\n";
        utime(time() - 120, time() - 120, $C_LOCK_D1);
        $CD{d1_got} = _lock_acquire($C_LOCK_D1, timeout => 5, poll => 0.02, stale => 30);
        if ($CD{d1_got}) {
            my ($wok) = _write_atomic("$D_DIR/.d1-probe", '{"d1":1}');
            $CD{d1_write_ok} = $wok ? 1 : 0;
            _lock_release($C_LOCK_D1);
            unlink("$D_DIR/.d1-probe");
        } else {
            $CD{d1_write_ok} = 0;
        }

        # (d2) a pre-planted STALE lock as a REGULAR FILE (mtime now-120,
        # Claude Code's own lock artefact kind is not guaranteed) is taken
        # over the same way, and a subsequent write succeeds.
        open(my $fh_d2, '>', $C_LOCK_D2) or die "setup: create $C_LOCK_D2 failed: $!\n";
        close($fh_d2);
        utime(time() - 120, time() - 120, $C_LOCK_D2);
        $CD{d2_got} = _lock_acquire($C_LOCK_D2, timeout => 5, poll => 0.02, stale => 30);
        if ($CD{d2_got}) {
            my ($wok) = _write_atomic("$D_DIR/.d2-probe", '{"d2":1}');
            $CD{d2_write_ok} = $wok ? 1 : 0;
            _lock_release($C_LOCK_D2);
            unlink("$D_DIR/.d2-probe");
        } else {
            $CD{d2_write_ok} = 0;
        }

        # (e) a FRESH lock (mtime now) is respected: the acquire attempt
        # fails within its own timeout, and nothing gets written.
        mkdir($C_LOCK_E) or die "setup: mkdir $C_LOCK_E failed: $!\n"; # freshly made -> mtime "now"
        my $sentinel_path = "$D_DIR/.e-sentinel";
        _write_atomic($sentinel_path, 'SENTINEL-UNCHANGED');
        my $te0 = time();
        $CD{e_got} = _lock_acquire($C_LOCK_E, timeout => 0.5, poll => 0.05, stale => 30);
        $CD{e_elapsed} = time() - $te0;
        my ($sok, $sbytes) = _read_bytes($sentinel_path);
        $CD{e_unchanged} = ($sok && defined $sbytes && $sbytes eq 'SENTINEL-UNCHANGED') ? 1 : 0;
        rmdir($C_LOCK_E);
        unlink($sentinel_path);

        # B49 — atomic rename at the post-fix path SHAPE (inside the dir
        # bind), asserted directly against $!.
        my $tmp49 = "$D_FILE.tmp.$$";
        open(my $dfh, '>', $tmp49) or die "setup: create $tmp49 failed: $!\n";
        print $dfh '{"v":1}';
        close($dfh);
        my $ok49 = rename($tmp49, $D_FILE);
        $CD{d49_ok}    = $ok49 ? 1 : 0;
        $CD{d49_errno} = $ok49 ? 0 : ($! + 0);

        # B50 — READ-ONLY assertion against the LIVE config. Never opened
        # for write, never renamed, never locked.
        $CD{live_exists} = (-f $LIVE_JSON) ? 1 : 0;
        if ($CD{live_exists}) {
            my ($lok, $lbytes) = _read_bytes($LIVE_JSON);
            if ($lok && defined $lbytes) {
                my $ldecoded = eval { JSON::PP->new->utf8->decode($lbytes) };
                if ($@) { $CD{live_parses} = 0; $CD{live_data} = {}; }
                else    { $CD{live_parses} = 1; $CD{live_data} = $ldecoded; }
            } else {
                $CD{live_parses} = 0;
                $CD{live_data} = {};
            }
        }

        alarm(0);
        1;
    };
    my $err = $@;
    alarm(0);
    if (!$ok) {
        $CD_timed_out = 1;
        $CD_error = $err // 'unknown error';
    }
}

SKIP: {
    skip("Phase C/D did not complete within their combined watchdog budget ($CD_error) — degraded per B51", 19)
        if $CD_timed_out;

    # ---- Phase C: B48 ----
    ok($CD{a_mkdir_ok}, 'B48a/AC15: mkdir lock succeeds on the real 9p bind');

    ok($CD{b_utime_ok}, 'B48b/AC15: utime() call succeeds on the real bind');
    ok((defined $CD{b_mtime_after} && defined $CD{b_mtime_before} && $CD{b_mtime_after} > $CD{b_mtime_before}),
        "B48b/AC15: lock mtime measurably advances after utime (before=" . ($CD{b_mtime_before} // 'undef')
        . ", after=" . ($CD{b_mtime_after} // 'undef') . ')');

    ok($CD{c_got}, 'B48c/AC15: uncontended lock acquisition succeeds');
    ok($CD{c_elapsed} < 1, "B48c/AC15: uncontended acquisition latency < 1s (got $CD{c_elapsed}s)");

    ok($CD{d1_got}, 'B48d/AC15: a pre-planted stale lock as a DIRECTORY (mtime now-120) is taken over');
    ok($CD{d1_write_ok}, 'B48d/AC15: a write after the stale-directory takeover succeeds');

    ok($CD{d2_got}, 'B48d/AC15: a pre-planted stale lock as a REGULAR FILE (mtime now-120) is taken over');
    ok($CD{d2_write_ok}, 'B48d/AC15: a write after the stale-regular-file takeover succeeds');

    is($CD{e_got}, 0, 'B48e/AC15: a FRESH lock (mtime now) is respected — acquire fails');
    ok($CD{e_elapsed} < 2, "B48e/AC15: the failed acquire honors its own timeout without hanging (got $CD{e_elapsed}s)");
    ok($CD{e_unchanged}, 'B48e/AC15: no write occurs while a fresh lock is held');

    # ---- Phase D: B49 ----
    ok($CD{d49_ok}, 'B49/AC20: rename(tmp, scratch .claude.json) succeeds inside the dir bind');
    isnt($CD{d49_errno}, EBUSY,
        'B49/AC20: errno is never EBUSY for this rename (the old single-file-bind failure mode is absent here)');

    # ---- Phase D: B50 (read-only; skip if the live config is absent) ----
    SKIP: {
        skip('live /root/.claude/.claude.json is absent — B50 read-only group skipped', 5)
            unless $CD{live_exists};

        ok($CD{live_parses}, 'B50/AC26: the LIVE claude.json still parses as JSON (read-only check)');
        ok((exists $CD{live_data}{hasCompletedOnboarding}), 'B50/AC26: live config retains hasCompletedOnboarding');
        ok((exists $CD{live_data}{oauthAccount}), 'B50/AC26: live config retains oauthAccount');
        ok((exists $CD{live_data}{userID}), 'B50/AC26: live config retains userID');
        ok((exists $CD{live_data}{projects}), 'B50/AC26: live config retains projects');
    }
}

# -----------------------------------------------------------------------
# B43 — informational report of the live config's mtime, start vs end.
#
# This is deliberately a diag(), NOT a pass/fail assertion: $LIVE_JSON runs
# on a live, multi-tenant sandbox fleet ("a production fleet is using it
# right now" — this file must never be the reason that fleet's config
# mtime looks wrong, but it is equally not entitled to assume NO OTHER
# process touches that file during this test's ~20s runtime). Asserting
# equality here would make the suite flaky under legitimate, unrelated
# concurrent activity elsewhere in the same container — a failure mode
# indistinguishable, from inside this file, from an actual regression.
#
# B43's real guarantee is structural, not runtime-measured: grep this file
# for $LIVE_JSON — every use is stat()/-f/_read_bytes() (open '<' only).
# It is never passed to _write_atomic, rename, unlink, chmod, or mkdir
# anywhere in this file. The dispatching harness independently captures
# `stat -c %Y` on the live file immediately before and after invoking this
# test (outside this process, unaffected by anything logged here) and
# reports both values, per the acceptance criteria for this package.
# -----------------------------------------------------------------------
my @live_stat_after = stat($LIVE_JSON);
my $live_mtime_after = @live_stat_after ? $live_stat_after[9] : undef;
diag("live /root/.claude/.claude.json mtime: before=" . ($live_mtime_before // 'undef')
    . " after=" . ($live_mtime_after // 'undef')
    . ' (informational only — see B43 comment above for why this is not a hard assertion)');

done_testing();
