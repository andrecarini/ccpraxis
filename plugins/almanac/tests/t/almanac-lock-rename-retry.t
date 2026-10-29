#!/usr/bin/env perl
# platform: windows
# A rename() that fails because another process holds the destination open
# is retried against a bounded deadline instead of being reported as a bare
# write failure: the retryable errno set (EACCES/EBUSY/EPERM/ETXTBSY) is an
# ALLOWLIST, everything else fails on the first attempt, the retry itself
# never blocks forever, and the two deadlines (lock acquisition vs. rename
# retry) are sized so one cannot cause the other to misfire.
#
# Covers AC-15 .. AC-18 and AC-20 of specs/01-lock-primitive-spec.md.
#
# AC-15 in particular needs a genuinely NATIVE Windows process holding the
# target open -- this host's own perl opens files with FILE_SHARE_DELETE, so
# a holder written in it would NOT block a rename and the assertion would
# pass for nothing. A real powershell.exe child, launched as a separate OS
# process, stands in for "some other real program has this file open".
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use Time::HiRes ();
use Errno ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
use lib "$Bin/../../scripts";
my $A       = "$S/almanac-bug.pl";
my $LOCK_PM = "$S/Almanac/Lock.pm";
ok(-f $A, 'almanac-bug.pl exists') or BAIL_OUT('script missing');
ok(-f $LOCK_PM, 'Almanac::Lock module file exists at plugins/almanac/scripts/Almanac/Lock.pm')
    or diag('Almanac::Lock.pm is not present yet -- every rename_with_retry/write_atomic '
          . 'assertion below is expected to fail for exactly that reason.');

my $LOAD_ERR;
eval { require Almanac::Lock; 1 } or do { $LOAD_ERR = $@ };
ok(!defined $LOAD_ERR, 'Almanac::Lock loads with no compile/runtime error')
    or diag("load error: $LOAD_ERR");

# Loaded exactly ONCE for the whole file (per the `do $A` convention
# frontmatter-injection.t:429 already uses -- `unless (caller)` is false
# under `do FILE`, so its CLI dispatch is never entered here) -- repeating
# `do $A` per-block only produces harmless-but-noisy "Subroutine redefined"
# warnings.
do $A;
die "could not load almanac-bug.pl in-process: $@" if $@;

# --- live-store sanity (house convention, spec section 6.3) -----------------
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIVE_STORE = "$REPO/.ccpraxis-local-data/bug-reports";
sub count_reports_in {
    my ($dir) = @_;
    return 0 unless -d $dir;
    opendir(my $dh, $dir) or return 0;
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return scalar @f;
}
my $live_before = count_reports_in($LIVE_STORE);
# Decision 120(c): presence in the real gitignored live store is never REQUIRED -- only that this suite leaves its count unchanged (checked below).

# =============================================================================
# Scaffolding
# =============================================================================

my $WORK = tempdir(CLEANUP => 1);
$WORK =~ s{\\}{/}g;

sub slurp_or {
    my ($path) = @_;
    return '(missing)' unless -e $path;
    open(my $fh, '<:raw', $path) or return "(unreadable: $!)";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

sub bounded_wait_for_file {
    my ($path, $deadline_s) = @_;
    my $t0 = Time::HiRes::time();
    my $deadline = $t0 + $deadline_s;
    while (!-e $path) {
        return 0 if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.02);
    }
    return 1;
}

# Fixed arity, deliberately -- see almanac-lock-bounded-acquire.t's
# try_acquire() for why: `eval { ... }` returns an EMPTY list on death, and
# appending a third value to an empty list would silently shift every later
# positional assignment.
sub try_rename_with_retry {
    my (@args) = @_;
    my ($ok, $err) = eval { Almanac::Lock::rename_with_retry(@args) };
    my $died = $@;
    return ($ok, $err, $died);
}

my $file_n = 0;
sub new_from_file {
    my $p = "$WORK/rename-from-" . (++$file_n) . ".tmp";
    open my $fh, '>', $p or die "fixture: cannot write $p: $!";
    print {$fh} "payload $file_n\n";
    close $fh;
    return $p;
}

sub always_fail_with {
    my ($errno_val) = @_;
    return sub { $! = $errno_val; return 0 };
}

# A REAL, separate perl process that shell-backgrounds a REAL, separate,
# NATIVE Windows powershell.exe process, which opens $target exclusively
# (FileShare mode given by the caller: 'None' for AC-15's exact spec
# wording, 'Read' where a caller also needs to read the file concurrently
# without being blocked -- rename still fails either way, since neither
# mode grants the delete-share a rename needs).
sub write_native_holder {
    my ($path) = @_;
    open my $fh, '>', $path or die "fixture: cannot write $path: $!";
    print {$fh} <<'NATIVEHOLDER';
#!/usr/bin/env perl
use strict;
use warnings;
$| = 1;
my ($target, $hold_ms, $readypath, $share_mode, $releasedpath) = @ARGV;
$share_mode = 'None' unless defined $share_mode && length $share_mode;
chomp(my $target_win = `cygpath -w "$target"`);
chomp(my $ready_win  = `cygpath -w "$readypath"`);
if (!length $target_win || !length $ready_win) {
    open(my $rf, '>', $readypath); print {$rf} "CYGPATH-FAIL"; close $rf;
    exit 1;
}
my $ps = "\$fs = [System.IO.File]::Open('$target_win', [System.IO.FileMode]::Open, "
       . "[System.IO.FileAccess]::Read, [System.IO.FileShare]::$share_mode); "
       . "Set-Content -Path '$ready_win' -Value 'HOLDING' -NoNewline; "
       . "Start-Sleep -Milliseconds $hold_ms; "
       . "\$fs.Close()";
{
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    system('powershell.exe', '-NoProfile', '-NonInteractive', '-Command', $ps);
}
if (defined $releasedpath && length $releasedpath) {
    open(my $df, '>', $releasedpath); print {$df} "RELEASED\n"; close $df;
}
exit($? >> 8);
NATIVEHOLDER
    close $fh;
}

# AC-15 and AC-18's first half need a rename() that another process can
# BLOCK by holding the destination open. That is a Windows sharing-mode
# behaviour: a POSIX rename (macOS, Linux) replaces the directory entry no
# matter who has the old file open, so there is nothing there to retry
# against and no powershell.exe to stand in as the holder. Those blocks are
# skipped off Windows; the rest of this file is platform-neutral and runs
# everywhere.
my $NATIVE_HOLDER_OS = ($^O =~ /^(MSWin32|cygwin|msys)$/) ? 1 : 0;
my $NO_NATIVE_HOLDER = 'Windows only: a POSIX rename() is never blocked by another process holding '
                     . 'the destination open, so there is no native holder (powershell.exe) to retry against';

sub powershell_available {
    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    system('powershell.exe', '-NoProfile', '-NonInteractive', '-Command', 'exit 0');
    return ($? == 0) ? 1 : 0;
}

my $NATIVE_HOLDER_PL = "$WORK/native-holder.pl";
write_native_holder($NATIVE_HOLDER_PL);

# =============================================================================
# AC-20 (DC5) -- the two deadlines cannot collide.
# =============================================================================
{
    my $rt = $Almanac::Lock::DEFAULT_RENAME_TIMEOUT_MS;
    my $dt = $Almanac::Lock::DEFAULT_TIMEOUT_MS;
    my $ok = defined($rt) && defined($dt) && ($rt * 2 < $dt);
    ok($ok, 'AC-20: DEFAULT_RENAME_TIMEOUT_MS * 2 < DEFAULT_TIMEOUT_MS -- the two deadlines cannot collide')
        or diag('DEFAULT_RENAME_TIMEOUT_MS=' . (defined $rt ? $rt : '(undef)')
              . ' DEFAULT_TIMEOUT_MS=' . (defined $dt ? $dt : '(undef)'));
}

# =============================================================================
# AC-16 (DC5) -- the retry is bounded and reports a timeout, not a hang.
# =============================================================================
{
    my $from = new_from_file();
    my $to   = "$WORK/ac16-to.md";
    my $on_rename = always_fail_with(Errno::EACCES());
    my $t0 = Time::HiRes::time();
    my ($ok, $err, $died) = try_rename_with_retry($from, $to, rename_timeout_ms => 400, on_rename => $on_rename);
    my $elapsed_ms = (Time::HiRes::time() - $t0) * 1000;
    ok(!$ok, 'AC-16: rename_with_retry does not succeed when on_rename always fails EACCES');
    ok($elapsed_ms <= 3000, sprintf('AC-16: ...and it does not hang (took %.1fms, well under its own 400ms budget plus slack)', $elapsed_ms));
    if ($err) {
        is($err->{kind}, 'rename_timeout', 'AC-16: kind is rename_timeout');
        ok($err->{waited_ms} >= 380, "AC-16: waited_ms ($err->{waited_ms}) >= 380");
        ok($err->{waited_ms} <= 3000, "AC-16: waited_ms ($err->{waited_ms}) <= 3000");
        ok($err->{attempts} >= 10, "AC-16: attempts ($err->{attempts}) >= 10");
    } else {
        fail('AC-16: expected a rename_timeout $err hashref') for 1 .. 4;
        diag("died: $died") if $died;
    }
}

# =============================================================================
# AC-17 (DC5) -- transient is retried, real is not.
# =============================================================================
{
    # (a) EACCES three times then succeeds -> (1, undef), 4 total attempts.
    my $from = new_from_file();
    my $to   = "$WORK/ac17a-to.md";
    my $calls = 0;
    my $on_rename = sub {
        my ($f2, $t2) = @_;
        $calls++;
        if ($calls <= 3) { $! = Errno::EACCES(); return 0 }
        return rename($f2, $t2);
    };
    my ($ok, $err) = try_rename_with_retry($from, $to, rename_timeout_ms => 2000, on_rename => $on_rename);
    ok($ok, 'AC-17a: EACCES three times then success -- overall success');
    ok(!defined($err), 'AC-17a: $err is undef on success') if defined $ok;
    is($calls, 4, 'AC-17a: on_rename was invoked exactly four times (3 failures + 1 success)');
}
{
    # (b) EBUSY once then succeeds -> (1, undef), 2 total attempts.
    my $from = new_from_file();
    my $to   = "$WORK/ac17b-to.md";
    my $calls = 0;
    my $on_rename = sub {
        my ($f2, $t2) = @_;
        $calls++;
        if ($calls <= 1) { $! = Errno::EBUSY(); return 0 }
        return rename($f2, $t2);
    };
    my ($ok, $err) = try_rename_with_retry($from, $to, rename_timeout_ms => 2000, on_rename => $on_rename);
    ok($ok, 'AC-17b: EBUSY once then success -- overall success');
    is($calls, 2, 'AC-17b: on_rename was invoked exactly twice (1 failure + 1 success)');
}
for my $case (
    ['ENOENT', Errno::ENOENT(), 1], # (c) explicitly asserts the message names the errno
    ['ENOSPC', Errno::ENOSPC(), 0],
    ['EXDEV',  Errno::EXDEV(),  0],
    ['EROFS',  Errno::EROFS(),  0], # (e) an arbitrary UNLISTED errno -- proves the set is an allowlist
) {
    my ($label, $errno_val, $check_message) = @$case;
    my $from = new_from_file();
    my $to   = "$WORK/ac17-$label-to.md";
    my $t0 = Time::HiRes::time();
    my ($ok, $err) = try_rename_with_retry($from, $to, rename_timeout_ms => 2000, on_rename => always_fail_with($errno_val));
    my $elapsed_ms = (Time::HiRes::time() - $t0) * 1000;
    ok(!$ok, "AC-17 [$label]: a non-retryable errno is NOT retried");
    if ($err) {
        is($err->{kind}, 'rename_fatal', "AC-17 [$label]: kind is rename_fatal");
        is($err->{attempts}, 1, "AC-17 [$label]: attempts == 1 -- failed on the first try");
        ok($err->{waited_ms} < 250, "AC-17 [$label]: waited_ms ($err->{waited_ms}) < 250 -- immediate, no retry loop entered")
            if defined $err->{waited_ms};
        ok($elapsed_ms < 250, "AC-17 [$label]: wall time (${elapsed_ms}ms) < 250ms -- immediate");
        if ($check_message) {
            like($err->{message}, qr/$label|errno/i, "AC-17 [$label]: the message names the errno");
        }
    } else {
        fail("AC-17 [$label]: expected a rename_fatal \$err hashref") for 1 .. 3;
    }
}

# =============================================================================
# AC-15 (DC5) -- the retry succeeds against a real, native exclusive holder.
# =============================================================================
{ SKIP: {
    skip("AC-15: $NO_NATIVE_HOLDER", 4) unless $NATIVE_HOLDER_OS;
    my $ps_ok = powershell_available();
    unless ($ps_ok) {
        fail('AC-15: prerequisite -- powershell.exe must be resolvable on this host (a native holder is '
           . 'required here; an MSYS/Cygwin perl holder would not block the rename and this test would '
           . 'pass vacuously). This host reported it is NOT resolvable -- see the diagnostic above.');
        fail('AC-15: _write_atomic returns 1 against a real native exclusive holder');
        fail('AC-15: the target contains the new bytes');
        fail('AC-15: the call took at least 300ms -- it genuinely entered the retry loop');
    } else {
        ok($ps_ok, 'AC-15: prerequisite -- powershell.exe is resolvable on this host');
        my $target15 = "$WORK/ac15-target.md";
        open(my $f15, '>', $target15) or die; print {$f15} "original AC-15 content\n"; close $f15;
        my $ready15    = "$WORK/ac15-ready";
        my $released15 = "$WORK/ac15-released";
        my $log15      = "$WORK/ac15-log";
        system(qq{perl "$NATIVE_HOLDER_PL" "$target15" "1200" "$ready15" "None" "$released15" > "$log15" 2>&1 &});
        my $up = bounded_wait_for_file($ready15, 15);
        ok($up, 'AC-15: the native (powershell) holder confirmed it opened the target exclusively')
            or diag('holder log: ' . slurp_or($log15));

        if ($up) {
            my $new_bytes = "REWRITTEN BY AC-15 at " . time() . "\n";
            my $t0 = Time::HiRes::time();
            my $ok_write = AlmanacBug::_write_atomic($target15, $new_bytes);
            my $elapsed_ms = (Time::HiRes::time() - $t0) * 1000;
            ok($ok_write, 'AC-15: _write_atomic returns 1 against a real native exclusive holder')
                or diag('$AlmanacBug::LAST_ERROR=' . (defined($AlmanacBug::LAST_ERROR) ? $AlmanacBug::LAST_ERROR : '(undef)'));
            is(slurp_or($target15), $new_bytes, 'AC-15: the target contains the new bytes');
            ok($elapsed_ms >= 300,
               sprintf('AC-15: the call took at least 300ms (%.1fms) -- it genuinely entered the retry loop, not a lucky first attempt', $elapsed_ms));
        } else {
            fail('AC-15: _write_atomic returns 1 against a real native exclusive holder');
            fail('AC-15: the target contains the new bytes');
            fail('AC-15: the call took at least 300ms -- it genuinely entered the retry loop');
        }
        # Bounded wait for the native holder to actually finish, so it never
        # still has the file open when File::Temp tries to clean up $WORK.
        bounded_wait_for_file($released15, 10);
    }
} }

# =============================================================================
# AC-18 (DC5) -- a rename failure is reported specifically, not as "write failed".
#
# almanac-bug.pl's `AlmanacBug::_write_atomic($path, $bytes)` takes no
# `on_rename` parameter (and AC-19 forbids the string "on_rename" from
# appearing anywhere in almanac-bug.pl at all), so a forced-and-controlled
# rename failure cannot be injected through it directly. Split in two:
#
#  1. a REAL native holder (same technique as AC-15) produces a genuine,
#     retry-exhausting rename failure against _write_atomic, to check that
#     $AlmanacBug::LAST_ERROR is actually populated with a specific reason;
#  2. `AlmanacBug::_write_atomic` is monkey-patched (a test-only substitution
#     of the collaborator, not a claim about production wiring) to isolate
#     exactly the message-composition contract B21 describes: cas_write's
#     "write failed" string becomes "write failed: $LAST_ERROR".
# =============================================================================
{
    SKIP: {
    skip("AC-18 (real holder half): $NO_NATIVE_HOLDER", 6) unless $NATIVE_HOLDER_OS;
    my $ps_ok = powershell_available();
    if ($ps_ok) {
        my $target18 = "$WORK/ac18-target.md";
        open(my $f18, '>', $target18) or die; print {$f18} "original AC-18 content\n"; close $f18;
        my $orig18 = slurp_or($target18);
        my $ready18    = "$WORK/ac18-ready";
        my $released18 = "$WORK/ac18-released";
        my $log18      = "$WORK/ac18-log";
        # Held well past the (undocumented-to-this-caller, but real) default
        # rename retry deadline, so the retry -- once it exists -- genuinely
        # exhausts rather than getting lucky.
        system(qq{perl "$NATIVE_HOLDER_PL" "$target18" "2500" "$ready18" "None" "$released18" > "$log18" 2>&1 &});
        my $up18 = bounded_wait_for_file($ready18, 15);
        ok($up18, 'AC-18: the native holder confirmed it opened the target exclusively (held 2.5s)')
            or diag('holder log: ' . slurp_or($log18));

        if ($up18) {
            $AlmanacBug::LAST_ERROR = '';
            my $ok18 = AlmanacBug::_write_atomic($target18, "SHOULD NOT LAND\n");
            ok(!$ok18, 'AC-18: _write_atomic returns 0 when the rename cannot succeed before its deadline');
            # Wait for the holder to genuinely release before reading the file
            # back -- otherwise a CORRECT retry implementation whose own
            # deadline is shorter than the holder's hold would still see a
            # sharing violation on THIS read, which would be this test's bug,
            # not the implementation's.
            bounded_wait_for_file($released18, 10);
            is(slurp_or($target18), $orig18, 'AC-18: the original bytes are untouched');
            my @leftover = glob("$target18.tmp.*");
            ok(@leftover == 0, 'AC-18: no $p.tmp.* is left behind');
            my $last_error = defined($AlmanacBug::LAST_ERROR) ? $AlmanacBug::LAST_ERROR : '';
            ok(length($last_error) > 0, 'AC-18: $AlmanacBug::LAST_ERROR is set on failure');
            like($last_error, qr/rename/i, 'AC-18: ...and it mentions rename');
            like($last_error, qr/EACCES|EBUSY|EPERM|ETXTBSY|Permission denied|resource busy|\d+/i,
                 'AC-18: ...and it names an errno-ish reason');
        } else {
            fail('AC-18: _write_atomic returns 0 when the rename cannot succeed before its deadline');
            fail('AC-18: the original bytes are untouched');
            fail('AC-18: no $p.tmp.* is left behind');
            fail('AC-18: $AlmanacBug::LAST_ERROR is set on failure');
            fail('AC-18: ...and it mentions rename');
            fail('AC-18: ...and it names an errno-ish reason');
        }
    } else {
        fail('AC-18: prerequisite -- powershell.exe must be resolvable to force a real rename failure');
        fail('AC-18: _write_atomic returns 0 when the rename cannot succeed before its deadline') for 1 .. 5;
    }
    }

    # Part 2: cas_write's message wrapping, isolated from _write_atomic's own
    # mechanics via a test-only substitution of the collaborator.
    my $PROJc = tempdir(CLEANUP => 1);
    (my $projc = $PROJc) =~ s{\\}{/}g;
    my $HOMEc = tempdir(CLEANUP => 1);
    my $cmdc = qq{ALMANAC_HOME="$HOMEc" perl "$A" file --project "$projc" --title "AC18c target" --body "orig"};
    chomp(my $pathc = `$cmdc 2>&1`);
    ok(-f $pathc, 'AC-18 fixture: a report was created for the cas_write message-wrapping check') or diag("path=[$pathc]");

    my $repc = AlmanacBug::load($pathc);
    ok(defined $repc, 'AC-18 fixture: the report loads');

    if (defined $repc) {
        no strict 'refs';
        no warnings 'redefine';
        local *AlmanacBug::_write_atomic = sub {
            $AlmanacBug::LAST_ERROR = 'rename exhausted its retry deadline: EACCES (Permission denied)';
            return 0;
        };
        my $new_rendered = AlmanacBug::_render($repc->{fields}, "updated body for AC-18c");
        my ($cas_ok, $cas_why) = AlmanacBug::cas_write($repc, $new_rendered);
        ok(!$cas_ok, 'AC-18: cas_write returns false when the underlying write fails');
        like($cas_why, qr/write failed:/i, 'AC-18: ...and the message says "write failed:" -- not a bare "write failed"');
        unlike($cas_why, qr/^write failed$/i, 'AC-18: ...specifically not the old bare string');
        like($cas_why, qr/rename/i, 'AC-18: ...and it carries the specific reason (mentions rename)');
    } else {
        fail('AC-18: cas_write returns false when the underlying write fails');
        fail('AC-18: ...and the message says "write failed:" -- not a bare "write failed"');
        fail('AC-18: ...specifically not the old bare string');
        fail('AC-18: ...and it carries the specific reason (mentions rename)');
    }
}

# =============================================================================
# Live-store sanity, again, at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "live store's report count is unchanged by this suite ($live_before before, $live_after after)");
}

done_testing();
