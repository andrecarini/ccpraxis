#!/usr/bin/env perl
# 147-worker-tmpdir-isolation.t — oracle for w03-validation-interlock, derived
# ONLY from
# .ccpraxis-local-data/blueprints/butler-and-dashboard-overhaul/specs/w03-validation-interlock-spec.md
# section 2.2 (bp-worker.pl per-invocation TMPDIR) and the package's done
# criteria 2, 4, 5 (behaviors 9, 10, 11; acceptance criteria 2 and 4 part b).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. bp-worker.pl today (read for scaffolding
# purposes only, never for behavior) forks and execs the backend with no
# TMPDIR manipulation and no $BP_DIR/tmp sweep at all -- grep of the file
# confirmed no `TMPDIR`, `DISPATCH_TMP`, `sweep_stale` or `$BP_DIR/tmp`
# anywhere in it. Every assertion below that depends on a per-invocation
# TMPDIR or a sweep is therefore expected to fail on MISSING BEHAVIOUR: the
# fake backend's env-log will show no TMPDIR line, or an inherited/unset one,
# never the fresh per-dispatch directory the spec requires.
#
# HARNESS RULES (mirrors t/79-worker-backend-dispatcher.t's scaffolding
# closely -- same fake backend idiom, same %CLEAN_ENV isolation, same
# `timeout` safety net, same file-based capture never re-opening
# STDOUT/STDERR onto an in-memory scalar):
#   * done_testing(), not a hand-counted plan.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

(my $ROOT_SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $BP_WORKER = "$ROOT_SCRIPTS/bp-worker.pl";

diag("subject under test: $BP_WORKER "
     . (-e $BP_WORKER ? "(present)" : "(ABSENT)"));

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $REAL_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';

sub fwd { (my $p = shift) =~ s{\\}{/}g; return $p; }

my $ROOT = tempdir(CLEANUP => 1);
my $fxn = 0;
my $rn  = 0;

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}
sub read_file {
    my ($path) = @_;
    return '' unless -e $path;
    open my $r, '<', $path or die "read $path: $!";
    binmode $r;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

# =====================================================================================
# Scaffolding: the fake backend. Records the resolved TMPDIR (or a sentinel
# for "unset") into FAKE_ENVLOG, one line per invocation -- this is the ONLY
# observable evidence of what bp-worker.pl handed the child, since the spec's
# own DISPATCH_TMP directory is best-effort removed after waitpid returns.
# =====================================================================================
my $FAKEBIN = "$ROOT/fakebin";
mkdir $FAKEBIN or die "mkdir $FAKEBIN: $!";
my $FAKE_OPENCODE = "$FAKEBIN/opencode";
write_file($FAKE_OPENCODE, <<'SH');
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_ENVLOG:-}" ]; then
  printf 'TMPDIR=%s\n' "${TMPDIR:-<unset>}" >> "$FAKE_ENVLOG"
fi
cat >/dev/null 2>&1
exit "${FAKE_EXIT:-0}"
SH
chmod 0755, $FAKE_OPENCODE or die "chmod $FAKE_OPENCODE: $!";
my $PATH_WITH_FAKE = "$FAKEBIN:$REAL_PATH";

# =====================================================================================
# Scaffolding: BP_DIR fixture (mirrors t/79's mk_bp/add_pkg/env_for shape).
# =====================================================================================
sub mk_bp {
    my $n = ++$fxn;
    my $bp = "$ROOT/bp$n";
    make_path("$bp/$_") for qw(packages runs reports);
    my $proj = "$ROOT/proj$n";
    make_path($proj);
    write_file("$bp/blueprint.md",
        "```\nblueprint: butler-and-dashboard-overhaul\nstatus: running\nworker_backend: opencode\n```\n\n## Overview\n\nFixture for 147.\n");
    return ($bp, $proj);
}
sub add_pkg {
    my ($bp, $pkg) = @_;
    write_file("$bp/packages/$pkg.md",
        "---\npackage: $pkg\nstatus: running\nlast_updated: 2026-08-01T00:00:00Z\n---\n\n# Package $pkg\n\n## Next action\n\nFixture only.\n");
    return "$bp/packages/$pkg.md";
}
sub env_for {
    my ($bp, $proj, $pkg) = @_;
    return (BP_DIR => fwd($bp), BP_PACKAGE => $pkg,
            BP_LEDGER => fwd("$bp/packages/$pkg.md"), BP_PROJECT_ROOT => fwd($proj));
}
sub write_prompt {
    my $pf = "$ROOT/prompt." . (++$rn) . ".txt";
    write_file($pf, "do the thing\n");
    return $pf;
}

# =====================================================================================
# Scaffolding: run the dispatcher foreground, bounded by `timeout 25` as a
# safety net only -- no assertion depends on it.
# =====================================================================================
sub run_worker {
    my ($args, %envover) = @_;
    my $errfile = "$ROOT/stderr." . (++$rn) . ".txt";
    local %ENV = (%CLEAN_ENV, PATH => $PATH_WITH_FAKE, %envover,
                  BP_WORKER_BIN => fwd($BP_WORKER), ERRPATH => fwd($errfile));
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 25 "$BP_WORKER_BIN" "$@" 2>"$ERRPATH"', 'bash', @$args)
        or die "bash: $!";
    binmode $fh;
    my $out = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    my $err = read_file($errfile);
    return ($rc, defined $out ? $out : '', $err);
}

# ===========================================================================
# A. Behavior 9 / AC2 (-> DC2): the forked child's TMPDIR is a fresh,
#    previously-nonexistent directory under $BP_DIR/tmp/, and differs from
#    whatever TMPDIR the parent inherited.
# ===========================================================================
{
    my ($bp, $proj) = mk_bp();
    my $pkg = 'pkgA';
    add_pkg($bp, $pkg);
    my $pf = write_prompt();
    my $envlog = "$ROOT/a.envlog";
    my $sentinel_tmpdir = "$ROOT/parent-sentinel-tmpdir";
    make_path($sentinel_tmpdir);

    ok(!-d "$bp/tmp", 'FIXTURE-SANITY: $BP_DIR/tmp does not exist before the first dispatch');

    my ($rc, $out, $err) = run_worker(
        ['--worker', 'scout', '--prompt-file', $pf],
        env_for($bp, $proj, $pkg),
        FAKE_ENVLOG => fwd($envlog), TMPDIR => fwd($sentinel_tmpdir));

    is($rc, 0, 'A1: FIXTURE-SANITY -- the dispatch itself completed (rc=0) against the fake backend')
        or diag("stderr=[$err]");

    my $log = read_file($envlog);
    my ($child_tmpdir) = $log =~ /^TMPDIR=(.*)$/m;
    ok(defined $child_tmpdir && length $child_tmpdir,
       'A2 (-> DC2, behavior 9): the fake backend observed a TMPDIR value at all')
        or diag("envlog=[$log]");

    if (defined $child_tmpdir) {
        like($child_tmpdir, qr{\Q$bp\E/tmp/}, 'A3 (-> DC2): the child TMPDIR lives under $BP_DIR/tmp/');
        like($child_tmpdir, qr/\Q$pkg\E/, 'A4 (-> DC2): the child TMPDIR path includes the package name');
        isnt($child_tmpdir, $sentinel_tmpdir,
             'A5 (-> DC2, behavior 9): the child TMPDIR differs from the parent-inherited sentinel TMPDIR '
           . '-- per-invocation isolation, not a passthrough');
    }
}

# ===========================================================================
# B. Two sequential invocations get two DIFFERENT dispatch tmp directories
#    (each is unique per invocation, not a single shared per-package root).
# ===========================================================================
{
    my ($bp, $proj) = mk_bp();
    my $pkg = 'pkgB';
    add_pkg($bp, $pkg);
    my $envlog1 = "$ROOT/b1.envlog";
    my $envlog2 = "$ROOT/b2.envlog";

    run_worker(['--worker', 'scout', '--prompt-file', write_prompt()],
               env_for($bp, $proj, $pkg), FAKE_ENVLOG => fwd($envlog1));
    run_worker(['--worker', 'scout', '--prompt-file', write_prompt()],
               env_for($bp, $proj, $pkg), FAKE_ENVLOG => fwd($envlog2));

    my ($t1) = read_file($envlog1) =~ /^TMPDIR=(.*)$/m;
    my ($t2) = read_file($envlog2) =~ /^TMPDIR=(.*)$/m;
    ok(defined $t1 && defined $t2 && length $t1 && length $t2,
       'B0: FIXTURE-SANITY -- both dispatches produced a TMPDIR observation')
        or diag("t1=[" . ($t1//'undef') . "] t2=[" . ($t2//'undef') . "]");
    isnt($t1, $t2,
       'B1 (-> DC2): two sequential bp-worker.pl invocations of the same package get two '
     . 'DIFFERENT dispatch tmp directories -- unique per invocation, not shared')
        if defined $t1 && defined $t2;
}

# ===========================================================================
# C. Behavior 10 / AC4 (-> DC4): a stale leftover DISPATCH_TMP (older than
#    the default 240-minute WORKER_TMP_TTL_MIN) is swept by the NEXT
#    invocation, before it creates its own.
# ===========================================================================
{
    my ($bp, $proj) = mk_bp();
    my $pkg = 'pkgC';
    add_pkg($bp, $pkg);

    my $stale_dir = "$bp/tmp/$pkg.scout.20260101T000000Z.99999";
    make_path($stale_dir);
    write_file("$stale_dir/leftover.txt", "leftover from a crashed dispatch\n");
    my $t = time() - (300 * 60);   # 300 min old > default 240 min TTL
    utime($t, $t, $stale_dir) or die "utime $stale_dir: $!";

    ok(-d $stale_dir, 'FIXTURE-SANITY: the stale leftover directory exists before the next dispatch');

    run_worker(['--worker', 'scout', '--prompt-file', write_prompt()],
               env_for($bp, $proj, $pkg), FAKE_ENVLOG => fwd("$ROOT/c.envlog"));

    ok(!-d $stale_dir,
       'C1 (-> DC4, behavior 10): a stale (300-minute-old) leftover DISPATCH_TMP is swept by the '
     . 'next bp-worker.pl invocation of ANY worker in the same $BP_DIR')
        or diag('a crashed worker'."'".' leftover must not survive indefinitely -- self-healing per w01'."'".'s precedent');
}

# ===========================================================================
# D. Behavior 11 (counter-fixture to C): a leftover DISPATCH_TMP that is
#    YOUNGER than the TTL is NOT swept -- the sweep is bounded, not
#    aggressive enough to delete a genuinely live dispatch's scratch space.
# ===========================================================================
{
    my ($bp, $proj) = mk_bp();
    my $pkg = 'pkgD';
    add_pkg($bp, $pkg);

    my $fresh_dir = "$bp/tmp/$pkg.scout.20260101T000000Z.88888";
    make_path($fresh_dir);
    write_file("$fresh_dir/inprogress.txt", "a live dispatch's scratch file\n");
    my $t = time() - (5 * 60);   # 5 min old, well under the 240-minute TTL
    utime($t, $t, $fresh_dir) or die "utime $fresh_dir: $!";

    run_worker(['--worker', 'scout', '--prompt-file', write_prompt()],
               env_for($bp, $proj, $pkg), FAKE_ENVLOG => fwd("$ROOT/d.envlog"));

    ok(-d $fresh_dir,
       'D1 (-> behavior 11, counter-fixture to C1): a 5-minute-old leftover directory (well under '
     . 'the TTL) survives the next invocation'."'".' sweep -- bounded, not over-aggressive')
        or diag('C1'."'".'s pass must be attributable to staleness, not to the sweep deleting everything');
}

# ===========================================================================
# E. fixbatch step7 / F3 -- sweep_stale_tmp must NOT delete a directory whose
#    owner is verifiably still alive, however stale its mtime looks. Reviewer
#    SF2 / red-team MEDIUM-1: mtime-only staleness can sweep a genuinely live
#    dispatch's scratch space if its toolchain never touches DISPATCH_TMP's
#    own top level again after the first write.
# ===========================================================================
{
    require "$ROOT_SCRIPTS/bp-runstate.pl";
    my ($bp, $proj) = mk_bp();
    my $pkg = 'pkgE';
    add_pkg($bp, $pkg);

    my $live_dir = "$bp/tmp/$pkg.scout.20260101T000000Z.77777";
    make_path($live_dir);
    write_file("$live_dir/inprogress.txt", "a live dispatch's scratch file\n");
    # Owned by THIS test process ($$) -- genuinely alive for the whole of this
    # block, exactly like a real bp-worker.pl parent waiting on its child.
    my $fp = BpRunState::pid_fingerprint($$);
    ok(defined $fp && length $fp,
       'E-setup: FIXTURE-SANITY -- this host can fingerprint its own pid '
     . '(if not, E1/E2 below cannot be meaningful and are skipped)')
        or diag('pid_fingerprint returned undef on this host/OS -- liveness protection cannot be exercised');

  SKIP: {
        skip 'pid_fingerprint unavailable on this host', 2 unless defined $fp && length $fp;

        write_file("$live_dir/.owner", "$$:$fp\n");
        my $t = time() - (300 * 60);   # 300 min old -> past the default 240-min TTL by mtime alone
        utime($t, $t, $live_dir) or die "utime $live_dir: $!";

        run_worker(['--worker', 'scout', '--prompt-file', write_prompt()],
                   env_for($bp, $proj, $pkg), FAKE_ENVLOG => fwd("$ROOT/e.envlog"));

        ok(-d $live_dir,
           'E1 (-> F3): a stale-by-mtime DISPATCH_TMP whose .owner sidecar names a VERIFIABLY LIVE '
         . 'pid (this test process) survives a concurrent invocation'."'".' sweep');

        # Counter-fixture: the SAME directory, once its owner is no longer
        # verifiable (fingerprint mismatch simulating pid reuse / a dead
        # owner), IS swept -- proves E1'"'"'s survival is attributable to the
        # liveness check, not to the sweep having stopped working at all.
        write_file("$live_dir/.owner", "$$:not-the-real-fingerprint\n");
        utime($t, $t, $live_dir) or die "utime $live_dir: $!";
        run_worker(['--worker', 'scout', '--prompt-file', write_prompt()],
                   env_for($bp, $proj, $pkg), FAKE_ENVLOG => fwd("$ROOT/e2.envlog"));
        ok(!-d $live_dir,
           'E2 (counter-fixture to E1): the same stale directory, once its owner sidecar no longer '
         . 'verifies (fingerprint mismatch), IS swept -- E1'."'".'s survival was attributable to '
         . 'verified liveness, not to the sweep being disabled');
    }
}

done_testing();
