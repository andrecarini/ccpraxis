#!/usr/bin/env perl
# 134-bp-watch-cli.t — IMMUTABLE ORACLE for w01-bp-watch's CLI surface
# (plugins/butler/scripts/bp-watch.pl, `unless (caller)` block).
#
# Spec: specs/w01-bp-watch-spec.md §2.2 (CLI/exit codes), §3 (behaviors 1-6,
# 9-11, 14), §4 (AC1-3, AC5, AC6, AC9).
#
# EXIT CODES ARE THE SIGNAL (spec §2.2), not bp-watchdog.pl's always-0
# convention — a gate-drive-loop.sh-style consumer needs a cheap $?. Every
# assertion here is paired with BOTH an exit-code check and a content check
# where the behavior claims a narration line, per the dispatch prompt's
# "pair content assertions with exit-code assertions" instruction.
#
# bp-watch.pl DOES NOT EXIST YET. run_watch() below refuses to invoke a
# missing script (returns (undef, '') instead of shelling out to a path perl
# itself would fail to open) specifically so a coincidental exit code from
# perl's own "can't open script" failure (frequently 2) can NEVER be
# misread as a real WORKERS-GONE verdict — that would be a false pass for
# the wrong reason, exactly what NON-VACUITY forbids.
#
# Runs standalone: perl plugins/butler/tests/t/134-bp-watch-cli.t
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::HiRes qw(time);

my $WATCH = "$Bin/../../scripts/bp-watch.pl";

sub run_watch {
    my (@args) = @_;
    return (undef, '', undef) unless -f $WATCH;
    my $cmd = join(' ', 'perl', qq("$WATCH"), map { qq("$_") } @args);
    my $t0  = time;
    my $out = `$cmd 2>&1`;
    my $dt  = time - $t0;
    return ($? >> 8, $out, $dt);
}

sub write_ledger {
    my ($dir, $id, $status_line) = @_;
    make_path("$dir/packages");
    my $body = "---\npackage: $id\n";
    $body .= "$status_line\n" if defined $status_line;
    $body .= "---\n\nbody\n";
    open my $fh, '>', "$dir/packages/$id.md" or die "write $id.md: $!";
    print {$fh} $body;
    close $fh;
}

sub new_bp {
    my ($bpname) = @_;
    $bpname //= 'bpx';
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/.ccpraxis-local-data";
    my $bp   = "$data/blueprints/$bpname";
    make_path("$bp/packages");
    make_path("$bp/runs");
    return ($data, $bp, $bpname);
}

# ===========================================================================
# A. AC3 / criterion 3 — --max-seconds is REQUIRED, no default. bp-watchdog.pl's
#    universal 1800 default is EXACTLY the habit that produced the origin bug
#    (dozens of forgettable 30-minute re-arms). Omitting it must be a USAGE
#    error (64), never a silent fallback to any value.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: pending');
    my ($rc, $out) = run_watch('--arm', '--package', "$bpname/p1", '--data', $data);
    is($rc, 64,
       'A1 CANONICAL: omitting --max-seconds entirely is a USAGE ERROR (exit 64), never a '
     . 'silent default — this is the exact habit that produced dozens of forgettable '
     . '30-minute re-arms across one long dispatch (2026-08-06 #11)');
}
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: pending');
    my ($rc) = run_watch('--arm', '--package', "$bpname/p1", '--max-seconds', 'notanumber', '--data', $data);
    is($rc, 64, 'A2: a non-numeric --max-seconds value is ALSO a usage error (64), not '
              . 'silently coerced to 0 or ignored');
}
{
    # 64 (usage) must be DISTINGUISHABLE from 65 (unverifiable subject) — a
    # broken invocation must never read as a real verdict about a real subject.
    my ($data) = new_bp();
    my ($rc) = run_watch('--bogus-flag-xyz', '--max-seconds', '5', '--data', $data);
    is($rc, 64, 'A3: an unrecognised flag is a usage error (64), distinct from 65');
}

# ===========================================================================
# B. AC5/invariant 1 + AC2 — behavior 1: a package's status flips to 'done'
#    mid-run -> exits 0 (TERMINAL) promptly, well under the bound, naming the
#    package and the new status.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');

    my $pid = fork();
    if (defined $pid && $pid == 0) {
        sleep 1;
        write_ledger($bp, 'p1', 'status: done');
        exit 0;
    }
    my ($rc, $out, $dt) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '20', '--poll', '1', '--data', $data
    );
    waitpid($pid, 0) if defined $pid && $pid > 0;

    is($rc, 0, 'B1 behavior1: exits 0 when the watched package\'s status flips to done');
    like($out, qr/TERMINAL/i, 'B2: stdout names the TERMINAL condition');
    like($out, qr/p1/, 'B3: stdout names the package');
    like($out, qr/done/, 'B4: stdout names the new status');
    ok(defined $dt && $dt < 20,
       'B5 CANONICAL — exits on a CONDITION, not a timer: elapsed time is well under the '
     . '20s bound (real condition fired around t=1s), never waiting out the full bound when '
     . 'the condition already resolved');
}

# ===========================================================================
# C. AC3 — behavior 2: nothing changes, the bound elapses -> exits 1 (BOUND),
#    stdout says liveness is UNKNOWN (never dead, never done — the umbrella
#    rule applied to the timeout path itself).
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my ($rc, $out, $dt) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '3', '--poll', '1', '--data', $data
    );
    is($rc, 1, 'C1 behavior2: nothing changes for the whole bound -> exits 1 (BOUND)');
    like($out, qr/BOUND/i, 'C2: stdout names the BOUND condition');
    like($out, qr/unknown|not known|never .*(dead|done)/i,
        'C3 UMBRELLA-RULE: stdout states liveness is UNKNOWN, never claims dead or done — a '
      . 'bound expiry must never resolve toward "finished"');
    ok(defined $dt && $dt >= 3,
       'C4: the process actually waited out the ~3s bound before concluding (BOUND is real, '
     . 'not an immediate false negative)');
}

# ===========================================================================
# D. AC7/invariant 3 — behavior 3: --expect-pids with a dead pid exits 2
#    (WORKERS-GONE) IMMEDIATELY, without waiting for --max-seconds. The
#    caller's OWN pid ($$, a real Windows pid for the whole run of this test
#    process) is included as a genuinely-alive pid, so a false all-dead
#    reading cannot slip through.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $dead_pid = 999_999;   # house convention for "not running" (t/111, t/112)
    my $own_pid  = $$;
    my ($rc, $out, $dt) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '30', '--poll', '1',
        '--expect-pids', "$dead_pid,$own_pid", '--data', $data
    );
    is($rc, 2, 'D1 behavior3 INVARIANT-3 CANONICAL: ANY one listed pid confirmed dead -> '
             . 'exits 2 (WORKERS-GONE), even though the OTHER listed pid (our own, real, '
             . 'live) is alive — the headline death-detection feature the shipped name-grep '
             . 'bug made impossible to ever fire');
    like($out, qr/WORKERS-GONE/i, 'D2: stdout names the WORKERS-GONE condition');
    ok(defined $dt && $dt < 30,
       'D3: exits well before the 30s bound — death detection fires immediately, not on a '
     . 'timer');
}
{
    # Counter-fixture: BOTH pids alive -> must NOT exit 2, proving D1 is not
    # simply "always exits 2 for --expect-pids".
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $own_pid = $$;
    my ($rc) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '3', '--poll', '1',
        '--expect-pids', "$own_pid", '--data', $data
    );
    isnt($rc, 2, 'D4 counter-fixture: with the ONLY listed pid genuinely alive, exit is NOT '
               . 'WORKERS-GONE — D1\'s exit 2 is attributable to the dead pid, not to the flag '
               . 'being present at all');
}

# ===========================================================================
# E. AC7 — behavior 4: --pid-file re-read on EVERY poll tick. A pid-file
#    holding our own (alive) pid, deleted mid-poll, must NOT fire
#    workers-gone (nothing to compare once absent) and must NOT fire
#    terminal either — it keeps polling to the bound.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $pidfile = "$bp/runs/.orchestrator";
    open my $fh, '>', $pidfile or die; print {$fh} "$$\n"; close $fh;

    my $pid = fork();
    if (defined $pid && $pid == 0) {
        sleep 1;
        unlink $pidfile;
        exit 0;
    }
    my ($rc, $out) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '4', '--poll', '1',
        '--pid-file', $pidfile, '--data', $data
    );
    waitpid($pid, 0) if defined $pid && $pid > 0;

    is($rc, 1, 'E1 behavior4 CANONICAL: a --pid-file that DISAPPEARS mid-poll resolves to '
             . 'BOUND (1) at the end of the window — NOT WORKERS-GONE (2) — because a vanished '
             . 'pid-file means "nothing configured to check", not "confirmed dead"');
    unlike($out, qr/WORKERS-GONE/i,
       'E2: stdout never claims WORKERS-GONE for a pid-file that simply disappeared');
}
{
    # The pid-file being RE-READ (not cached at arm time) matters only if a
    # file that CHANGES mid-poll is picked up. Swap it to a dead pid mid-run
    # and confirm workers-gone DOES fire — proving live re-reads, not a
    # one-shot read at arm time.
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $pidfile = "$bp/runs/.orchestrator";
    open my $fh, '>', $pidfile or die; print {$fh} "$$\n"; close $fh;

    my $pid = fork();
    if (defined $pid && $pid == 0) {
        sleep 1;
        open my $f2, '>', $pidfile or exit 1; print {$f2} "999999\n"; close $f2;
        exit 0;
    }
    my ($rc, $out) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '15', '--poll', '1',
        '--pid-file', $pidfile, '--data', $data
    );
    waitpid($pid, 0) if defined $pid && $pid > 0;

    is($rc, 2, 'E3 CANONICAL — RE-READ EVERY TICK, not cached at arm time: a pid-file whose '
             . 'content CHANGES to a dead pid mid-run is detected as WORKERS-GONE (2) — a '
             . 'cached-at-arm-time implementation would keep trusting the original (live) pid '
             . 'and never notice');
    like($out, qr/WORKERS-GONE/i, 'E4: stdout confirms WORKERS-GONE');
}

# ===========================================================================
# F. AC8/invariant 4 — behavior 5: --artifact is scoped to the WATCHED
#    SUBJECT'S path(s). Touching an unrelated sibling package's file -> no
#    exit, no line, keeps polling. Touching the configured path -> exit 3.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $watched  = "$bp/packages/p1.md";
    write_ledger($bp, 'sibling', 'status: running');
    my $sibling  = "$bp/packages/sibling.md";

    my $pid = fork();
    if (defined $pid && $pid == 0) {
        sleep 1;
        open my $fh, '>>', $sibling or exit 1; print {$fh} "unrelated write\n"; close $fh;
        exit 0;
    }
    my ($rc, $out) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '3', '--poll', '1',
        '--artifact', $watched, '--data', $data
    );
    waitpid($pid, 0) if defined $pid && $pid > 0;

    is($rc, 1, 'F1 behavior5 INVARIANT-4 CANONICAL: an unrelated SIBLING package\'s file being '
             . 'touched during the window produces NO artifact exit — the scan is scoped to '
             . 'the watched subject\'s own path, never tree-wide (bp-watchdog.pl\'s live '
             . 'defect, neutralized here at the only call site that matters)');
    unlike($out, qr/ARTIFACT/i, 'F2: stdout never claims ARTIFACT for the sibling\'s write');
}
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: running');
    my $watched = "$bp/packages/p1.md";

    my $pid = fork();
    if (defined $pid && $pid == 0) {
        sleep 1;
        open my $fh, '>>', $watched or exit 1; print {$fh} "watched write\n"; close $fh;
        exit 0;
    }
    my ($rc, $out, $dt) = run_watch(
        '--arm', '--package', "$bpname/p1", '--max-seconds', '20', '--poll', '1',
        '--artifact', $watched, '--data', $data
    );
    waitpid($pid, 0) if defined $pid && $pid > 0;

    is($rc, 3, 'F3: touching the CONFIGURED artifact path itself -> exits 3 (ARTIFACT) — F1\'s '
             . 'silence is attributable to subject-scoping, not to artifact-watching being '
             . 'broken entirely');
    like($out, qr/ARTIFACT/i, 'F4: stdout names the ARTIFACT condition');
    ok(defined $dt && $dt < 20, 'F5: exits promptly on the real condition, not the full bound');
}

# ===========================================================================
# G. AC6/invariant 2 — behavior 6: Mode B (--blueprint alone). 5 packages on
#    disk, only 2 have any registry.json entry at all, and that registry.json
#    is DELIBERATELY WRONG (claims both done). Denominator must be 5, and the
#    blueprint must NOT settle — exit 1 (BOUND), never 0 (TERMINAL/SETTLED).
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: done');
    write_ledger($bp, 'p2', 'status: done');
    write_ledger($bp, 'p3', 'status: pending');   # never launched
    write_ledger($bp, 'p4', 'status: pending');   # never launched
    write_ledger($bp, 'p5', 'status: pending');   # never launched
    open my $rfh, '>', "$bp/runs/registry.json" or die;
    print {$rfh} '{"p1":{"status":"done"},"p2":{"status":"done"}}';
    close $rfh;

    my ($rc, $out, $dt) = run_watch(
        '--arm', '--blueprint', $bpname, '--max-seconds', '3', '--poll', '1', '--data', $data
    );
    is($rc, 1,
       'G1 behavior6 INVARIANT-2 CANONICAL: with 3 of 5 packages/*.md never launched (absent '
     . 'from registry.json entirely, which itself falsely claims the other 2 done), the '
     . 'blueprint must NOT settle — exits 1 (BOUND), never 0 (SETTLED). Denominator is read '
     . 'from packages/*.md, never registry.json');
    isnt($rc, 0, 'G2: never a false SETTLED (0) — the umbrella rule (uncertainty never '
               . 'resolves toward finished) applied directly to invariant 2');
}
{
    # Counter-fixture: registry.json REMOVED entirely changes nothing (same
    # answer) — proves the file is never consulted, not merely misread when
    # malformed.
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: done');
    write_ledger($bp, 'p2', 'status: done');
    write_ledger($bp, 'p3', 'status: pending');
    my ($rc) = run_watch(
        '--arm', '--blueprint', $bpname, '--max-seconds', '3', '--poll', '1', '--data', $data
    );
    is($rc, 1, 'G3: same non-settled answer with registry.json entirely ABSENT — the '
             . 'denominator logic does not merely tolerate a wrong registry, it never reads '
             . 'one at all');
}
{
    # Positive case: every packages/*.md entry genuinely terminal -> Mode B
    # settles (exit 0). Without this, G1/G3 alone could pass under an
    # implementation that never settles Mode B at all.
    my ($data, $bp, $bpname) = new_bp();
    write_ledger($bp, 'p1', 'status: done');
    write_ledger($bp, 'p2', 'status: dropped');
    my ($rc, $out) = run_watch(
        '--arm', '--blueprint', $bpname, '--max-seconds', '5', '--poll', '1', '--data', $data
    );
    is($rc, 0, 'G4: Mode B DOES settle (exit 0) when every packages/*.md entry is genuinely '
             . 'terminal — G1/G3\'s non-settlement is attributable to the pending packages, '
             . 'not to Mode B being unable to ever settle');
    like($out, qr/TERMINAL|SETTLED/i, 'G5: stdout names the settled condition');
}

# ===========================================================================
# H. AC9/umbrella — a nonexistent subject is UNVERIFIABLE (65), never a false
#    SETTLED (0). Spec §5 edge case.
# ===========================================================================
{
    my ($data, $bp, $bpname) = new_bp();
    my ($rc, $out) = run_watch(
        '--arm', '--package', "$bpname/typo-pkg-does-not-exist", '--max-seconds', '3',
        '--poll', '1', '--data', $data
    );
    is($rc, 65, 'H1 behavior — a package that never existed on disk -> exit 65 '
              . '(UNVERIFIABLE), the "cannot verify" case, never 0/SETTLED');
    isnt($rc, 0, 'H2: never a false positive settle for a subject that cannot be found');
}
{
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/.ccpraxis-local-data";
    make_path($data);
    my ($rc) = run_watch(
        '--arm', '--blueprint', 'no-such-blueprint-at-all', '--max-seconds', '3',
        '--poll', '1', '--data', $data
    );
    is($rc, 65, 'H3: a blueprint dir that does not exist at all -> 65, not 0');
}

# ===========================================================================
# I. AC1 — token-free: no LLM/claude invocation anywhere in the poll path.
#    Neither surface's EXISTING mechanism is removed by this package.
# ===========================================================================
{
    my $src = -f $WATCH ? do { local (@ARGV, $/) = ($WATCH); <> } : undef;
    ok(defined $src, 'I1: bp-watch.pl source is readable') or diag('bp-watch.pl absent');
    if (defined $src) {
        my $code = join "\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1;
        unlike($code, qr/`[^`]*\bclaude\b[^`]*`/i,
           'I2: no backtick invocation of a claude binary anywhere in the source');
        unlike($code, qr/system\s*\([^)]*\bclaude\b/i,
           'I3: no system() invocation of a claude binary anywhere in the source');
        unlike($code, qr/\bexec\s*\([^)]*\bclaude\b/i,
           'I4: no exec() invocation of a claude binary anywhere in the source');
        like($code, qr/unless\s*\(\s*caller\s*\)/,
           'I5: guarded by unless(caller), the house pattern for a require-able library + CLI '
         . '(bp-wait-for-decision.pl, bp-runstate.pl)');
    } else {
        fail('I2: cannot check source (file absent)');
        fail('I3: cannot check source (file absent)');
        fail('I4: cannot check source (file absent)');
        fail('I5: cannot check source (file absent)');
    }
}
{
    my $reporter = "$Bin/../../skills/reporter/SKILL.md";
    my $rs = -f $reporter ? do { local (@ARGV, $/) = ($reporter); <> } : '';
    like($rs, qr/bp-wait-for-decision\.pl/,
       'I6: reporter/SKILL.md still arms bp-wait-for-decision.pl — the existing mechanism is '
     . 'kept ALONGSIDE bp-watch.pl, never replaced (criterion 1)');
}
{
    my $ds = "$Bin/../../skills/drive-solo/SKILL.md";
    my $s  = -f $ds ? do { local (@ARGV, $/) = ($ds); <> } : '';
    like($s, qr/gate-drive-loop\.sh/,
       'I7: drive-solo/SKILL.md still references gate-drive-loop.sh — the Stop gate stays the '
     . 'drive-solo mechanism, unedited, per criterion 1');
}

done_testing();
