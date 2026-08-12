#!/usr/bin/env perl
# t/98-write-guard-primitive.t — immutable oracle for BpWrite::guarded_write,
# the a01-write-integrity-reread-under-lock primitive (spec §2.3-2.4, §8).
# Covers AC1-AC8. `bp-write-guard.pl` does not exist yet -> the require below
# fails, caught with eval (house pattern, t/17), so every BpWrite:: call dies
# with "Undefined subroutine" -- the RIGHT failure reason for a not-yet-built
# primitive.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use Fcntl qw(:flock);

my $SCRIPT = "$Bin/../../scripts/bp-write-guard.pl";
my $LOADED = do {
    local $@;
    eval { require $SCRIPT };
    !$@;
};
my $REQUIRE_ERROR = $@;

my $J = JSON::PP->new->canonical;

# ── fixture helpers ──────────────────────────────────────────────────────────
sub write_file { my ($p, $b) = @_; open my $fh, '>:raw', $p or die "write $p: $!"; print $fh $b; close $fh; }
sub read_file  { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $x = <$fh>; close $fh; $x; }

# Generic stdout/stderr capture around an arbitrary coderef. NEVER reopen
# STDOUT/STDERR onto an in-memory scalar (Git-for-Windows perl: "Bad file
# descriptor") -- redirect to real temp files instead (t/17-drive-next.t:118).
sub capture_call {
    my ($code) = @_;
    my ($ofh, $opath) = tempfile('t98-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('t98-errXXXXXX', TMPDIR => 1); close $efh;
    open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDOUT, '>:raw', $opath or do { open STDOUT, '>&', $oldout; die "reopen STDOUT: $!" };
    open STDERR, '>:raw', $epath or do { open STDERR, '>&', $olderr; die "reopen STDERR: $!" };
    $| = 1;
    my ($rv, $died);
    { local $@; $rv = eval { $code->() }; $died = $@; }
    open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
    open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
    my $out = do { open my $r, '<:raw', $opath or die; local $/; my $x = <$r>; close $r; defined $x ? $x : '' };
    my $err = do { open my $r, '<:raw', $epath or die; local $/; my $x = <$r>; close $r; defined $x ? $x : '' };
    unlink $opath, $epath;
    return ($rv, $out, $err, $died);
}

sub log_events {
    my ($path) = @_;
    return () unless defined $path && -f $path;
    my @lines = split /\n/, (read_file($path) // '');
    return map { eval { $J->decode($_) } } grep { length } @lines;
}

# ═════════════════════════════════════════════════════════════════════════
# AC1 — single definition, requireable, argument hash / return hashref
# ═════════════════════════════════════════════════════════════════════════
ok($LOADED, 'AC1: bp-write-guard.pl requires cleanly as package BpWrite')
    or diag("require died with: $REQUIRE_ERROR");
ok(defined &BpWrite::guarded_write, 'AC1: BpWrite::guarded_write is defined')
    or diag('BpWrite::guarded_write is not a defined subroutine yet');

# ═════════════════════════════════════════════════════════════════════════
# AC1/AC2/AC5(happy path) — behavior 5: written outcome + file on disk
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/target.txt";
    write_file($path, "before");

    my $r = eval { BpWrite::guarded_write({
        site   => 'ac1_happy',
        path   => $path,
        mutate => sub { my ($state) = @_; return ("$state-after", undef); },
    }) };
    diag("guarded_write died: $@") if $@;

    is(ref($r), 'HASH', 'AC1: guarded_write returns a hashref');
    is($r->{ok}, 1, 'AC1/behavior5: happy path ok=1');
    is($r->{outcome}, 'written', 'AC1/behavior5: happy path outcome=written');
    is($r->{path}, $path, 'AC1: result carries the target path');
    is(read_file($path), 'before-after', 'AC1/behavior5: file on disk contains the new bytes');
    is($BpWrite::LAST_RESULT->{outcome}, 'written',
        'AC1/§2.3: $BpWrite::LAST_RESULT mirrors the returned hashref (house precedent LAST_EXEC_ERROR)');

    # behavior 11 / AC2: lock released after this successful exit path.
    open my $lk, '>', "$path.lock" or die "open lock: $!";
    ok(flock($lk, LOCK_EX | LOCK_NB),
        'AC2/behavior11: lock file is free immediately after a WRITTEN outcome (released after read-back)');
    close $lk;
}

# ═════════════════════════════════════════════════════════════════════════
# AC2 — lock held before read (behavior 1): AFTER_LOCK_HOOK mutates the file;
# the primitive's own `read` must see that mutation, proving read runs AFTER
# the lock is acquired and AFTER the hook, not against a stale pre-lock value.
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/target.txt";
    write_file($path, "original");

    local $BpWrite::AFTER_LOCK_HOOK = sub { write_file($path, "mutated-by-hook"); };

    my $seen;
    my $r = eval { BpWrite::guarded_write({
        site   => 'ac2_order',
        path   => $path,
        mutate => sub { my ($state) = @_; $seen = $state; return ("$state-appended", undef); },
    }) };
    diag("guarded_write died: $@") if $@;

    is($seen, 'mutated-by-hook',
        'AC2/behavior1: read() observes the AFTER_LOCK_HOOK mutation -> lock held before read, hook fires before read');
    is($r->{outcome}, 'written', 'AC2: happy path after the hook mutation');
    is(read_file($path), 'mutated-by-hook-appended',
        'AC2: final bytes are mutate() applied to the RE-READ state, not a stale pre-lock read');
}

# ═════════════════════════════════════════════════════════════════════════
# AC3 — a `valid` refusal writes nothing (behavior 2)
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/target.txt";
    write_file($path, "untouched");
    my $log = "$dir/orchestrator.log";
    my @mtime_before = stat($path);

    my $r = eval { BpWrite::guarded_write({
        site   => 'ac3_valid_refusal',
        path   => $path,
        log    => $log,
        valid  => sub { return 'stale-world'; },
        mutate => sub { fail('AC3: mutate must never run once valid() has refused'); return (undef, 'unreachable'); },
    }) };
    diag("guarded_write died: $@") if $@;

    is($r->{ok}, 0, 'AC3/behavior2: valid-refusal ok=0');
    is($r->{outcome}, 'refused', 'AC3/behavior2: outcome=refused');
    is($r->{reason}, 'stale-world', 'AC3/behavior2: reason token carried through verbatim');
    is(read_file($path), 'untouched', 'AC3/behavior2: target bytes unchanged');
    my @mtime_after = stat($path);
    is($mtime_after[9], $mtime_before[9], 'AC3/behavior2: target mtime unchanged');

    my @events = grep { ($_->{type} // '') eq 'write_guard' } log_events($log);
    is(scalar(@events), 1, 'AC3: exactly one write_guard log event emitted for this refusal');
    is($events[0]{outcome}, 'refused', 'AC3: logged event carries outcome=refused')
        if @events;
    is($events[0]{reason}, 'stale-world', 'AC3: logged event carries the reason token')
        if @events;

    open my $lk, '>', "$path.lock" or die;
    ok(flock($lk, LOCK_EX | LOCK_NB), 'AC2/behavior11: lock released after a refused (valid) exit path');
    close $lk;
}

# ═════════════════════════════════════════════════════════════════════════
# AC3 — a `mutate` refusal (undef, $reason) behaves identically (behavior 3)
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/target.txt";
    write_file($path, "untouched2");
    my $log = "$dir/orchestrator.log";

    my $r = eval { BpWrite::guarded_write({
        site   => 'ac3_mutate_refusal',
        path   => $path,
        log    => $log,
        mutate => sub { return (undef, 'no-longer-applies'); },
    }) };
    diag("guarded_write died: $@") if $@;

    is($r->{ok}, 0, 'AC3/behavior3: mutate-refusal ok=0');
    is($r->{outcome}, 'refused', 'AC3/behavior3: outcome=refused');
    is($r->{reason}, 'no-longer-applies', 'AC3/behavior3: reason token carried through');
    is(read_file($path), 'untouched2', 'AC3/behavior3: target bytes unchanged');

    my @events = grep { ($_->{type} // '') eq 'write_guard' } log_events($log);
    is(scalar(@events), 1, 'AC3/behavior3: exactly one write_guard log event');
}

# ═════════════════════════════════════════════════════════════════════════
# behavior 4 — mutate returns bytes identical to what was read -> 'unchanged'
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/target.txt";
    write_file($path, "same-bytes");

    my $r = eval { BpWrite::guarded_write({
        site   => 'ac1_unchanged',
        path   => $path,
        mutate => sub { my ($state) = @_; return ($state, undef); },
    }) };
    diag("guarded_write died: $@") if $@;

    is($r->{ok}, 1, 'behavior4: unchanged outcome ok=1');
    is($r->{outcome}, 'unchanged', 'behavior4: outcome=unchanged when mutate returns identical bytes');
    is(read_file($path), 'same-bytes', 'behavior4: target not rewritten (byte-identical short-circuit)');

    open my $lk, '>', "$path.lock" or die;
    ok(flock($lk, LOCK_EX | LOCK_NB), 'AC2/behavior11: lock released after an unchanged exit path');
    close $lk;
}

# ═════════════════════════════════════════════════════════════════════════
# AC4 — read-back failure via AFTER_COMMIT_HOOK (behavior 6). No rollback,
# no retry: the file is left exactly as AFTER_COMMIT_HOOK left it.
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/target.txt";
    write_file($path, "start");
    my $log = "$dir/orchestrator.log";

    local $BpWrite::AFTER_COMMIT_HOOK = sub { write_file($path, "clobbered-after-rename"); };

    my $r = eval { BpWrite::guarded_write({
        site   => 'ac4_readback',
        path   => $path,
        log    => $log,
        mutate => sub { my ($state) = @_; return ("$state-mutated", undef); },
    }) };
    diag("guarded_write died: $@") if $@;

    is($r->{ok}, 0, 'AC4/behavior6: readback-failed ok=0');
    is($r->{outcome}, 'readback-failed', 'AC4/behavior6: outcome=readback-failed, driven deterministically via AFTER_COMMIT_HOOK');
    is(read_file($path), 'clobbered-after-rename',
        'AC4/behavior6: NO ROLLBACK -- the file is left exactly as the post-commit clobber left it');

    my @events = grep { ($_->{type} // '') eq 'write_guard' } log_events($log);
    is(scalar(grep { ($_->{outcome} // '') eq 'readback-failed' } @events), 1,
        'AC4/behavior6: a write_guard log event is emitted for the readback failure');

    open my $lk, '>', "$path.lock" or die;
    ok(flock($lk, LOCK_EX | LOCK_NB), 'AC2/behavior11: lock released after a readback-failed exit path');
    close $lk;
}

# ═════════════════════════════════════════════════════════════════════════
# AC5 — lock acquisition is bounded (behavior 8). Deterministic, NO SLEEP:
# a second, independently-opened filehandle in THIS SAME PROCESS holds
# LOCK_EX on the lock file (flock is per open-file-description, so this is
# denied to guarded_write's own open exactly like a foreign process would be
# -- standard flock semantics, not scheduling-dependent). $BpWrite::NOW_FN
# jumps straight past the deadline on its second call so no real time passes.
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/target.txt";
    write_file($path, "contended");
    my $lock_path = "$path.lock";

    open my $holder, '>', $lock_path or die "open lock: $!";
    ok(flock($holder, LOCK_EX), 'AC5 setup: test process holds the lock via an independent filehandle');

    local $ENV{BP_WRITEGUARD_LOCK_TIMEOUT} = 1;
    my $clock = 1_000_000;
    local $BpWrite::NOW_FN = sub { my $now = $clock; $clock += 1000; return $now; };

    my $r = eval { BpWrite::guarded_write({
        site   => 'ac5_timeout',
        path   => $path,
        mutate => sub { fail('AC5: mutate must never run when the lock could not be acquired'); return (undef, 'unreachable'); },
    }) };
    diag("guarded_write died: $@") if $@;

    is($r->{ok}, 0, 'AC5/behavior8: lock-timeout ok=0');
    is($r->{outcome}, 'lock-timeout', 'AC5/behavior8: outcome=lock-timeout rather than blocking indefinitely');
    is(read_file($path), 'contended', 'AC5: target untouched on a lock-timeout');

    flock($holder, LOCK_UN); close $holder;
}

# ═════════════════════════════════════════════════════════════════════════
# behavior 7 — RENAME_FN failure -> io-error, tmp removed, target byte-unchanged
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/target.txt";
    write_file($path, "io-error-fixture");

    local $BpWrite::RENAME_FN = sub { return 0; };

    my $r = eval { BpWrite::guarded_write({
        site   => 'ac_io_error',
        path   => $path,
        mutate => sub { my ($state) = @_; return ("$state-mutated", undef); },
    }) };
    diag("guarded_write died: $@") if $@;

    is($r->{ok}, 0, 'behavior7: io-error ok=0');
    is($r->{outcome}, 'io-error', 'behavior7: outcome=io-error when RENAME_FN returns false');
    is(read_file($path), 'io-error-fixture', 'behavior7: target byte-unchanged after a failed rename');
    opendir(my $dh, $dir) or die;
    my @tmp_leftover = grep { /\.tmp\.\d+$/ } readdir($dh);
    closedir $dh;
    is_deeply(\@tmp_leftover, [], 'behavior7: no "$path.tmp.$$" leftover after a failed rename');
}

# ═════════════════════════════════════════════════════════════════════════
# AC6 — no STDOUT/STDERR, no die/exit, for every outcome token in §2.3
# ═════════════════════════════════════════════════════════════════════════
{
    my %fixtures = (
        written         => sub {
            my $dir = tempdir(CLEANUP => 1); my $p = "$dir/t.txt"; write_file($p, "a");
            return { site=>'ac6_written', path=>$p, mutate=>sub { my($s)=@_; ("$s-b", undef) } };
        },
        unchanged       => sub {
            my $dir = tempdir(CLEANUP => 1); my $p = "$dir/t.txt"; write_file($p, "a");
            return { site=>'ac6_unchanged', path=>$p, mutate=>sub { my($s)=@_; ($s, undef) } };
        },
        refused         => sub {
            my $dir = tempdir(CLEANUP => 1); my $p = "$dir/t.txt"; write_file($p, "a");
            return { site=>'ac6_refused', path=>$p, mutate=>sub { (undef, 'nope') } };
        },
        'io-error'      => sub {
            my $dir = tempdir(CLEANUP => 1); my $p = "$dir/t.txt"; write_file($p, "a");
            local $BpWrite::RENAME_FN = sub { 0 };
            return { site=>'ac6_io', path=>$p, mutate=>sub { my($s)=@_; ("$s-b", undef) } };
        },
        'readback-failed' => sub {
            my $dir = tempdir(CLEANUP => 1); my $p = "$dir/t.txt"; write_file($p, "a");
            local $BpWrite::AFTER_COMMIT_HOOK = sub { write_file($p, "clobbered") };
            return { site=>'ac6_readback', path=>$p, mutate=>sub { my($s)=@_; ("$s-b", undef) } };
        },
        'lock-timeout'  => sub {
            my $dir = tempdir(CLEANUP => 1); my $p = "$dir/t.txt"; write_file($p, "a");
            open my $holder, '>', "$p.lock" or die; flock($holder, LOCK_EX);
            local $ENV{BP_WRITEGUARD_LOCK_TIMEOUT} = 1;
            my $clock = 1; local $BpWrite::NOW_FN = sub { my $n = $clock; $clock += 1000; $n };
            return { site=>'ac6_timeout', path=>$p, mutate=>sub { ('x', undef) }, _holder => $holder };
        },
    );

    for my $outcome (sort keys %fixtures) {
        my $args = $fixtures{$outcome}->();
        my $holder = delete $args->{_holder};
        my ($r, $out, $err, $died) = capture_call(sub { BpWrite::guarded_write($args) });
        flock($holder, LOCK_UN) if $holder;
        is($out, '', "AC6($outcome): no STDOUT bytes");
        is($err, '', "AC6($outcome): no STDERR bytes");
        ok(!$died, "AC6($outcome): guarded_write does not die") or diag("died with: $died");
        is(ref($r), 'HASH', "AC6($outcome): still returns a hashref rather than dying/exiting");
    }
}

# ═════════════════════════════════════════════════════════════════════════
# AC7 — nested guarded_write returns nested-lock, writes nothing (behavior 9)
# ═════════════════════════════════════════════════════════════════════════
{
    my $dir      = tempdir(CLEANUP => 1);
    my $outer    = "$dir/outer.txt";
    my $inner    = "$dir/inner.txt";
    write_file($outer, "outer-before");
    # inner target deliberately does not exist yet, so any write to it is detectable.

    my $inner_result;
    my $r = eval { BpWrite::guarded_write({
        site   => 'ac7_outer',
        path   => $outer,
        mutate => sub {
            my ($state) = @_;
            $inner_result = eval { BpWrite::guarded_write({
                site   => 'ac7_inner',
                path   => $inner,
                mutate => sub { return ('should-never-be-written', undef); },
            }) };
            return ("$state-after", undef);
        },
    }) };
    diag("guarded_write died: $@") if $@;

    is(ref($inner_result), 'HASH', 'AC7/behavior9: the nested call itself returns (no deadlock)');
    is($inner_result->{ok}, 0, 'AC7/behavior9: nested guarded_write ok=0');
    is($inner_result->{outcome}, 'nested-lock', 'AC7/behavior9: nested guarded_write outcome=nested-lock');
    ok(!-e $inner, 'AC7/behavior9: the nested call wrote NOTHING to its own target');
    is($r->{outcome}, 'written', 'AC7: the OUTER call still completes normally despite the refused nested attempt');
}

# ═════════════════════════════════════════════════════════════════════════
# AC8 — CLI seam (behavior 12)
# ═════════════════════════════════════════════════════════════════════════
{
    my $out = `perl "$SCRIPT" --lock-timeout 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, 'AC8/behavior12: --lock-timeout exits 0');
    chomp(my $line = $out);
    like($line, qr/^\d+$/, 'AC8/behavior12: --lock-timeout prints a bare integer');
    if ($LOADED && defined $BpWrite::LOCK_TIMEOUT_SECS) {
        is($line + 0, $BpWrite::LOCK_TIMEOUT_SECS,
            'AC8/behavior12: --lock-timeout prints exactly $BpWrite::LOCK_TIMEOUT_SECS (single source of truth)');
    }
}
{
    my $out = `perl "$SCRIPT" --lock-path "/tmp/some/file.md" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, 'AC8/behavior12: --lock-path exits 0');
    chomp(my $line = $out);
    is($line, '/tmp/some/file.md.lock', 'AC8/behavior12: --lock-path prints "<f>.lock"');
}
{
    my $out = `perl "$SCRIPT" --bogus-flag 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 2, 'AC8/behavior12: unknown argv exits 2');
}

# ═════════════════════════════════════════════════════════════════════════
# AC8 — cross-language non-drift (behavior 32): bp-lib.sh must derive its
# flock timeout from the CLI seam rather than hardcoding a literal.
# ═════════════════════════════════════════════════════════════════════════
{
    my $lib_sh = "$Bin/../../scripts/bp-lib.sh";
    open my $fh, '<', $lib_sh or die "read bp-lib.sh: $!";
    local $/; my $src = <$fh>; close $fh;

    unlike($src, qr/flock\s+-w\s+\d+/,
        'AC8/behavior32: bp-lib.sh contains no hardcoded "flock -w <digits>" literal');
    like($src, qr/bp-write-guard\.pl.*--lock-timeout/s,
        'AC8/behavior32: registry_merge derives its timeout by calling bp-write-guard.pl --lock-timeout');
}

done_testing();
