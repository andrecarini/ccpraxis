#!/usr/bin/env perl
# b32-worker-backend-dispatcher oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b32-worker-backend-dispatcher-spec.md
# §2 (contracts), §3 (behaviours) and §4 (acceptance criteria A1..A16).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/scripts/bp-worker.pl does not exist at the
# time this file was authored. Every assertion that depends on the script running is therefore
# expected to fail on MISSING BEHAVIOUR: `bash -c 'exec "$BP_WORKER_BIN" ...'` against a nonexistent
# file exits 127 with bash's own "No such file or directory" diagnostic, never a perl/harness error
# of this file. Assertions labelled FIXTURE-SANITY are deliberate harness self-checks, expected to
# pass even with the script absent -- they are the evidence that the red below is attributable to
# the missing script and not to broken scaffolding. A3 is expected to PASS right now: it only
# checks that the (already-existing) coordinator-protocol/SKILL.md Task paragraph is verbatim
# present -- it does not depend on bp-worker.pl at all.
#
# HARNESS RULES (mirroring 64-ledger-guard.t):
#   * %CLEAN_ENV strips every ambient BP_*/PATH-adjacent var this suite controls explicitly, so an
#     inherited value from the coordinator session running this very suite cannot produce a false
#     pass or a false red.
#   * All fixtures are synthesized under File::Temp. No live blueprint under
#     .ccpraxis-local-data/blueprints/*/ is read or written.
#   * Output is captured via temp files / pipes, never by reopening STDOUT onto an in-memory scalar
#     (Git-for-Windows perl "Bad file descriptor"; project CLAUDE.md landmine).
#   * Foreground dispatches are wrapped in `timeout 20` as a safety net only -- no assertion depends
#     on it; a script that hangs must not hang this suite.
#   * Background dispatches (A7 marker mid-flight capture, A13 SIGTERM) use a fork + bounded
#     poll-loop protocol (ready-file / go-file) with generous but FINITE waits (a handful of
#     seconds), never an unbounded wait. If bp-worker.pl never runs (absent), the ready-file never
#     appears, the bounded wait simply times out, and the affected assertions fail for the right
#     reason (missing behaviour) rather than hanging.
#   * done_testing(), not a hand-counted plan.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps ();
use Test::More;
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG);
use Fcntl;

(my $ROOT_SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
(my $ROOT_HOOKS   = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $ROOT_SKILLS  = "$Bin/../../skills")  =~ s{\\}{/}g;
my $BP_WORKER   = "$ROOT_SCRIPTS/bp-worker.pl";
my $TRACK_HOOK  = "$ROOT_HOOKS/track-dispatch.sh";
my $SKILL_MD    = "$ROOT_SKILLS/coordinator-protocol/SKILL.md";

my $ROOT = tempdir(CLEANUP => 1);
my $fxn  = 0;
my $rn   = 0;

diag("subject under test: $BP_WORKER "
     . (-e $BP_WORKER
        ? "(present)"
        : "(ABSENT -- every AC assertion below that runs it is expected to fail on MISSING BEHAVIOUR)"));

my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };
my $bg_supported = ($^O eq 'linux' || $^O eq 'darwin') ? 1 : 0;

# A hook/dispatcher test must control its own environment completely.
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $REAL_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# =====================================================================================
# Scaffolding: file helpers
# =====================================================================================
sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}
sub read_file {
    my ($path) = @_;
    open my $r, '<', $path or die "read $path: $!";
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return defined $c ? $c : '';
}
sub slurp_if_exists { my ($p) = @_; return -e $p ? read_file($p) : undef; }

# =====================================================================================
# Scaffolding: the fake backend, first on PATH. Controlled entirely via env vars so one
# script serves every executing-path scenario (success, failure, huge output, blocking).
# =====================================================================================
my $FAKEBIN = "$ROOT/fakebin";
mkdir $FAKEBIN or die "mkdir $FAKEBIN: $!";
my $FAKE_OPENCODE = "$FAKEBIN/opencode";
write_file($FAKE_OPENCODE, <<'SH');
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_LOG:-}" ]; then
  { printf 'PID=%s ARGS=' "$$"; printf '[%s]' "$@"; printf '\n'; } >> "$FAKE_LOG"
fi
if [ -n "${FAKE_PIDFILE:-}" ]; then
  printf '%s' "$$" > "$FAKE_PIDFILE"
fi
if [ -n "${FAKE_READY:-}" ]; then
  : > "$FAKE_READY"
fi
if [ -n "${FAKE_GO:-}" ]; then
  i=0
  while [ ! -f "$FAKE_GO" ] && [ "$i" -lt 400 ]; do
    sleep 0.05
    i=$((i+1))
  done
fi
cat >/dev/null 2>&1
n="${FAKE_LINES:-0}"
if [ "$n" -gt 0 ]; then
  i=1
  while [ "$i" -le "$n" ]; do
    printf 'line %d\n' "$i"
    i=$((i+1))
  done
fi
exit "${FAKE_EXIT:-0}"
SH
chmod 0755, $FAKE_OPENCODE or die "chmod $FAKE_OPENCODE: $!";
my $PATH_WITH_FAKE    = "$FAKEBIN:$REAL_PATH";
# A16 needs a PATH on which `opencode` genuinely does not resolve. Using the
# inherited PATH is NOT sufficient and was a latent defect: the moment a real
# opencode exists anywhere on it, bp-worker.pl finds and RUNS it, and the
# "binary absent -> exit 8" case silently becomes a live dispatch (observed:
# rc=124, a timeout, instead of 8). That is not hypothetical — b34 installs the
# OpenCode CLI into the container by design, so this test would have started
# failing for everyone the moment b34 landed.
# Two wrong answers were tried first, both recorded so they are not retried:
#   1. An EMPTY PATH — breaks the harness itself ("Can't exec bash").
#   2. Dropping any DIRECTORY containing an `opencode` executable — works only while
#      opencode lives somewhere incidental. b34 installs it to /usr/bin BY DESIGN, and
#      dropping /usr/bin takes bash with it. Same failure as (1), one step later.
# So mirror PATH into a temp dir as symlinks, omitting exactly one name. Everything
# else still resolves; `opencode` provably does not.
sub _mk_path_without_opencode {
    my ($real_path) = @_;
    my $dir = File::Temp::tempdir('bp79-noopencode-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my %seen;
    for my $d (split /:/, $real_path) {
        next unless -d $d;
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..' || $e eq 'opencode';
            next if $seen{$e}++;
            symlink("$d/$e", "$dir/$e");
        }
        closedir $dh;
    }
    return $dir;
}
# Only attempt the PATH mirror where symlink() works. See the same guard and the
# same reasoning in t/81: this helper symlinks EVERY entry of EVERY PATH
# directory, which on Windows means tens of thousands of failing calls against
# System32 — 15+ minutes at file scope, before a single assertion, looking for
# all the world like a deadlock. Without symlinks the mirror would be empty
# anyway, i.e. not a PATH-minus-one-binary but a PATH with nothing on it.
my $PATH_WITHOUT_FAKE = HostCaps::symlink_works()
    ? _mk_path_without_opencode($REAL_PATH)
    : undef;

# =====================================================================================
# Scaffolding: BP_DIR fixture builders.
#   mk_bp($blueprint_backend)      -> creates packages/ runs/ reports/ + blueprint.md
#   add_pkg($bp, $pkg, $backend)   -> writes packages/$pkg.md (--- YAML frontmatter)
#   env_for($bp, $proj, $pkg)      -> the bp-launch.sh env contract
# =====================================================================================
sub mk_bp {
    my ($blueprint_backend) = @_;
    my $n  = ++$fxn;
    my $bp = "$ROOT/bp$n";
    mkdir $bp or die "mkdir $bp: $!";
    mkdir "$bp/$_" or die "mkdir $bp/$_: $!" for qw(packages runs reports);
    my $proj = "$ROOT/proj$n";
    mkdir $proj or die "mkdir $proj: $!";

    my @L;
    push @L, '```';
    push @L, 'blueprint: sandbox-butler-overhaul';
    push @L, 'created: 2026-08-01T00:00:00Z';
    push @L, 'status: running   # spike';
    push @L, "worker_backend: $blueprint_backend   # fixture"
        if defined $blueprint_backend && length $blueprint_backend;
    push @L, '```';
    push @L, '';
    push @L, '## Overview';
    push @L, '';
    push @L, 'Fixture blueprint for 79-worker-backend-dispatcher.t.';
    push @L, '';
    write_file("$bp/blueprint.md", join("\n", @L) . "\n");

    return ($bp, $proj);
}

sub add_pkg {
    my ($bp, $pkg, $backend, %opt) = @_;
    my @L;
    push @L, '---';
    push @L, "package: $pkg";
    push @L, 'blueprint: sandbox-butler-overhaul';
    push @L, 'status: running';
    push @L, "worker_backend: $backend   # fixture"
        if defined $backend && length $backend;
    push @L, 'last_updated: 2026-08-01T00:00:00Z';
    push @L, '---';
    push @L, '';
    push @L, "# Package $pkg";
    push @L, '';
    push @L, '## Next action';
    push @L, '';
    push @L, 'Fixture only.';
    push @L, '';
    my $content = join("\n", @L) . "\n";
    $content .= $opt{extra} if defined $opt{extra};
    write_file("$bp/packages/$pkg.md", $content);
    return "$bp/packages/$pkg.md";
}

sub env_for {
    my ($bp, $proj, $pkg) = @_;
    return (BP_DIR => $bp, BP_PACKAGE => $pkg,
            BP_LEDGER => "$bp/packages/$pkg.md", BP_PROJECT_ROOT => $proj);
}
sub marker_path_for { my ($bp, $pkg) = @_; return "$bp/runs/$pkg.active-worker" }
sub reports_dir_for  { my ($bp, $pkg) = @_; return "$bp/reports/$pkg" }

sub write_prompt {
    my ($text) = @_;
    my $pf = "$ROOT/prompt." . (++$rn) . ".txt";
    write_file($pf, $text);
    return $pf;
}

# =====================================================================================
# Scaffolding: run the dispatcher, foreground (bounded by `timeout 20` as a safety net).
# Returns (rc, stdout, stderr).
# =====================================================================================
sub run_worker {
    my ($args, %envover) = @_;
    my $errfile = "$ROOT/stderr." . (++$rn) . ".txt";
    local %ENV = (%CLEAN_ENV, PATH => $PATH_WITH_FAKE, %envover,
                  BP_WORKER_BIN => fwd($BP_WORKER), ERRPATH => fwd($errfile));
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 20 "$BP_WORKER_BIN" "$@" 2>"$ERRPATH"', 'bash', @$args)
        or die "bash: $!";
    binmode $fh;
    my $out = do { local $/; <$fh> };
    close $fh;
    my $rc  = $? >> 8;
    my $err = -e $errfile ? read_file($errfile) : '';
    return ($rc, defined $out ? $out : '', $err);
}

# Background variant: forks, execs the dispatcher with stdout/stderr redirected to files.
# Returns ($pid, $outfile, $errfile). Caller must eventually wait_pid_timeout() it.
sub run_worker_bg {
    my ($args, %envover) = @_;
    my $outfile = "$ROOT/bgout." . (++$rn) . ".txt";
    my $errfile = "$ROOT/bgerr." . (++$rn) . ".txt";
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        local %ENV = (%CLEAN_ENV, PATH => $PATH_WITH_FAKE, %envover,
                      BP_WORKER_BIN => fwd($BP_WORKER),
                      OUTPATH => fwd($outfile), ERRPATH => fwd($errfile));
        exec('bash', '-c', 'exec "$BP_WORKER_BIN" "$@" >"$OUTPATH" 2>"$ERRPATH"', 'bash', @$args);
        POSIX::_exit(127);
    }
    return ($pid, $outfile, $errfile);
}
sub wait_for_file {
    my ($path, $timeout) = @_;
    my $elapsed = 0;
    while (!-e $path && $elapsed < $timeout) {
        select(undef, undef, undef, 0.05);
        $elapsed += 0.05;
    }
    return -e $path ? 1 : 0;
}
sub wait_pid_timeout {
    my ($pid, $timeout) = @_;
    my $elapsed = 0;
    while ($elapsed < $timeout) {
        my $r = waitpid($pid, WNOHANG);
        return $? if $r == $pid;
        select(undef, undef, undef, 0.05);
        $elapsed += 0.05;
    }
    kill('KILL', $pid);
    waitpid($pid, 0);
    return $?;
}
sub pid_alive { my ($pid) = @_; return kill(0, $pid) ? 1 : 0; }

sub nonblank_lines { return grep { /\S/ } split /\n/, $_[0] }

# =====================================================================================
# FIXTURE SANITY -- pass with or without bp-worker.pl. Proves the red below is "script
# missing", not "harness broken".
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    my $lp = add_pkg($bp, 'fixture-pkg', undef);
    ok(-d "$bp/packages" && -d "$bp/runs" && -d "$bp/reports", 'FIXTURE-SANITY: bp fixture has packages/runs/reports');
    my $bpmd = read_file("$bp/blueprint.md");
    like($bpmd, qr/^worker_backend: opencode\b/m, 'FIXTURE-SANITY: blueprint.md header carries worker_backend at column 0');
    unlike($bpmd, qr/^---\s*$/m, 'FIXTURE-SANITY: blueprint.md uses the FENCED shape, not --- frontmatter');
    my $pkgmd = read_file($lp);
    like($pkgmd, qr/\A---\n/, 'FIXTURE-SANITY: package ledger opens with --- frontmatter');
    ok(-x $FAKE_OPENCODE, 'FIXTURE-SANITY: fake opencode is executable');
    # Both of these are preconditions for LATER groups, which already skip
    # themselves when unmet. Asserting them here turned an absent dependency
    # into a reported defect; a skip names the coverage that was lost instead.
  SKIP: {
    skip 'jq is not installed on this host -- the A7 byte-identity group is NOT exercised', 1
        unless $have_jq;
    pass('FIXTURE-SANITY: jq is available on this host (A7 byte-identity group will run)');
  }
  SKIP: {
    skip "this OS ($^O) does not support the fork/kill protocol A7/A13 use", 1 unless $bg_supported;
    pass('FIXTURE-SANITY: this OS supports the fork/kill protocol used by A7/A13');
  }
}

# =====================================================================================
# A1 / A2 -- default is claude; Task path untouched.
# =====================================================================================
{
    my ($bp, $proj) = mk_bp(undef);
    my $pkg = 'b32-default';
    my $lp  = add_pkg($bp, $pkg, undef);
    my $ledger_before = read_file($lp);
    my $pf = write_prompt("implement the thing\nmore detail\n");

    my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf], env_for($bp, $proj, $pkg));
    is($rc, 0, 'A1: no worker_backend anywhere -> exit 0');
    like($out, qr/^backend: claude$/m, 'A1: stdout contains "backend: claude"');
    like($out, qr/^worker: butler:bp-implementer$/m, 'A1: stdout names the canonical worker');
    like($out, qr/^dispatch: task$/m, 'A1: claude path stdout carries "dispatch: task"');
    is(scalar(nonblank_lines($out)), 4, 'A1: claude path stdout is exactly the 4-line block');

    ok(!-e marker_path_for($bp, $pkg), 'A2: no marker file exists after the claude-path run');
    ok(!-d reports_dir_for($bp, $pkg) || !glob(reports_dir_for($bp, $pkg) . '/*'),
       'A2: no file exists under reports/$BP_PACKAGE/ after the claude-path run');
    is(read_file($lp), $ledger_before, 'A2: $BP_LEDGER is byte-unchanged after the claude-path run');
}

# =====================================================================================
# A3 -- Task path documentation is additive, not replaced. Does not depend on bp-worker.pl.
# =====================================================================================
{
    my $skill = read_file($SKILL_MD);
    ok(length($skill), 'A3: coordinator-protocol/SKILL.md is readable');
    like($skill, qr/Workers are dispatched via Task with /,
         'A3: the verbatim "Workers are dispatched via Task with " sentence is still present');
    like($skill, qr/butler:bp-implementer/,
         'A3: the namespaced-subagent_type rule still names butler:bp-implementer');
    for my $w (qw(bp-scout bp-architect bp-test-writer bp-implementer bp-reviewer bp-redteam bp-ui-prober)) {
        like($skill, qr/butler:\Q$w\E/, "A3: the namespaced form butler:$w is still present");
    }
}

# =====================================================================================
# A4 -- blueprint-level worker_backend applies when the package ledger has no key.
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b32-a4';
    add_pkg($bp, $pkg, undef);
    my $pf = write_prompt("do the a4 thing\n");
    my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf],
                                       env_for($bp, $proj, $pkg), FAKE_EXIT => 0);
    like($out, qr/^backend: opencode$/m, 'A4: blueprint-level worker_backend: opencode resolves for a package with no key');
}

# =====================================================================================
# A5 -- package-level override is scoped to that package only.
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    add_pkg($bp, 'P1', 'claude');
    add_pkg($bp, 'P2', undef);

    my $pf1 = write_prompt("p1 prompt\n");
    my ($rc1, $out1) = run_worker(['--worker', 'implementer', '--prompt-file', $pf1],
                                   env_for($bp, $proj, 'P1'));
    like($out1, qr/^backend: claude$/m, 'A5: package P1 overrides the blueprint to claude');
    is($rc1, 0, 'A5: P1 (claude, non-executing) exits 0');

    my $pf2 = write_prompt("p2 prompt\n");
    my ($rc2, $out2) = run_worker(['--worker', 'implementer', '--prompt-file', $pf2],
                                   env_for($bp, $proj, 'P2'), FAKE_EXIT => 0);
    like($out2, qr/^backend: opencode$/m, 'A5: sibling package P2 (no key) resolves the blueprint-level opencode');
}

# =====================================================================================
# A6 -- an unrecognised worker_backend value fails loudly, at either level.
# =====================================================================================
{
    for my $case (
        { label => 'blueprint-level', bpbackend => 'gpt-5', pkgbackend => undef },
        { label => 'package-level',   bpbackend => undef,   pkgbackend => 'gpt-5' },
    ) {
        my ($bp, $proj) = mk_bp($case->{bpbackend});
        my $pkg = 'b32-a6';
        my $lp = add_pkg($bp, $pkg, $case->{pkgbackend});
        my $ledger_before = read_file($lp);
        my $pf = write_prompt("a6 prompt\n");
        my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf],
                                           env_for($bp, $proj, $pkg));
        is($rc, 4, "A6 ($case->{label}): worker_backend: gpt-5 -> exit 4");
        like($err, qr/gpt-5/, "A6 ($case->{label}): stderr names the offending value gpt-5");
        like($err, qr/claude/, "A6 ($case->{label}): stderr names the recognised set (claude)");
        like($err, qr/opencode/, "A6 ($case->{label}): stderr names the recognised set (opencode)");
        unlike($out, qr/backend: claude/, "A6 ($case->{label}): stdout does not contain backend: claude");
        ok(!-e marker_path_for($bp, $pkg), "A6 ($case->{label}): no marker is produced");
        ok(!-d reports_dir_for($bp, $pkg) || !glob(reports_dir_for($bp, $pkg) . '/*'),
           "A6 ($case->{label}): no report file is produced");
        is(read_file($lp), $ledger_before, "A6 ($case->{label}): ledger byte-unchanged (no log entry)");
    }
}

# =====================================================================================
# A7 -- marker byte-identity with track-dispatch.sh: same path, same bytes.
# =====================================================================================
SKIP: {
    skip "jq not available; track-dispatch.sh requires it (bp_hook_require_jq)", 3 unless $have_jq;
    skip "this OS does not support the fork/kill protocol used to capture the marker mid-flight", 3
        unless $bg_supported;

    # (a) what track-dispatch.sh itself writes for subagent_type=butler:bp-implementer.
    my ($bpA, $projA) = mk_bp(undef);
    my $pkgA = 'b32-a7-hook';
    add_pkg($bpA, $pkgA, undef);
    my $markerA = marker_path_for($bpA, $pkgA);
    my $payload = qq({"tool_input":{"subagent_type":"butler:bp-implementer"}});
    {
        local %ENV = (%CLEAN_ENV, env_for($bpA, $projA, $pkgA), BP_ROLE => 'coordinator');
        open(my $f, '-|', 'bash', '-c', 'timeout 20 bash "$0" <<<"$1"', $TRACK_HOOK, $payload)
            or die "bash: $!";
        my $o = do { local $/; <$f> }; close $f;
    }
    my $hook_bytes = slurp_if_exists($markerA);
    ok(defined $hook_bytes, 'A7 baseline: track-dispatch.sh created a marker for butler:bp-implementer')
        or diag("no marker at $markerA");

    # (b) bp-worker.pl, mid-flight, against a blocking fake backend on a FRESH fixture.
    my ($bpB, $projB) = mk_bp('opencode');
    my $pkgB = 'b32-a7-worker';
    add_pkg($bpB, $pkgB, undef);
    my $markerB = marker_path_for($bpB, $pkgB);
    my $pf = write_prompt("a7 prompt\n");
    my $ready = "$ROOT/a7.ready";
    my $go    = "$ROOT/a7.go";
    my ($pid, $outfile, $errfile) = run_worker_bg(
        ['--worker', 'implementer', '--prompt-file', $pf],
        env_for($bpB, $projB, $pkgB), FAKE_READY => fwd($ready), FAKE_GO => fwd($go));
    my $became_ready = wait_for_file($ready, 6);
    ok($became_ready, 'A7: bp-worker.pl reaches the running backend (ready-file appeared)');

    my $worker_bytes = $became_ready ? slurp_if_exists($markerB) : undef;
    is($markerB, "$bpB/runs/$pkgB.active-worker", 'A7: marker path is exactly $BP_DIR/runs/$BP_PACKAGE.active-worker');
    is($worker_bytes, 'butler:bp-implementer', 'A7: marker content mid-flight is exactly "butler:bp-implementer"');
    if (defined $worker_bytes) {
        unlike($worker_bytes, qr/\n\z/, 'A7: marker content carries no trailing newline');
    } else {
        ok(0, 'A7: marker content carries no trailing newline (marker never appeared)');
    }
    if (defined $hook_bytes && defined $worker_bytes) {
        is($worker_bytes, $hook_bytes, 'A7: bp-worker.pl marker bytes are IDENTICAL to track-dispatch.sh marker bytes');
    } else {
        ok(0, 'A7: bp-worker.pl marker bytes are IDENTICAL to track-dispatch.sh marker bytes (one side never wrote)');
    }

    write_file($go, '1') unless -e $go;
    wait_pid_timeout($pid, 10);
}

# =====================================================================================
# A8 -- one write-capable worker at a time.
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b32-a8';
    my $lp = add_pkg($bp, $pkg, undef);
    my $ledger_before = read_file($lp);
    my $marker = marker_path_for($bp, $pkg);
    sysopen(my $mfh, $marker, O_WRONLY|O_CREAT|O_TRUNC) or die "open $marker: $!";
    print $mfh 'butler:bp-implementer';
    close $mfh;
    my $marker_before = read_file($marker);

    my $log = "$ROOT/a8.fakelog";
    my $pf = write_prompt("a8 prompt\n");
    my ($rc, $out, $err) = run_worker(['--worker', 'test-writer', '--prompt-file', $pf],
                                       env_for($bp, $proj, $pkg), FAKE_LOG => fwd($log));
    is($rc, 3, 'A8: second write-capable dispatch (test-writer) with the marker held -> exit 3');
    like($err, qr/BLOCKED/i, 'A8: stderr carries a BLOCKED-style diagnostic');
    is(read_file($marker), $marker_before, 'A8: marker bytes are unchanged');
    ok(!-e $log, 'A8: the fake backend recorded no invocation');
    ok(!-d reports_dir_for($bp, $pkg) || !glob(reports_dir_for($bp, $pkg) . '/*'),
       'A8: no report file is created');
    is(read_file($lp), $ledger_before, 'A8: no dispatch-log line is appended');
}

# =====================================================================================
# A9 -- read-only workers never take the marker, even while one is held.
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b32-a9';
    add_pkg($bp, $pkg, undef);
    my $marker = marker_path_for($bp, $pkg);

    for my $w (qw(scout architect reviewer redteam)) {
        ok(!-e $marker, "A9: no marker exists before dispatching read-only worker $w");
        my $log = "$ROOT/a9-$w.fakelog";
        my $pf = write_prompt("a9 $w prompt\n");
        my ($rc, $out, $err) = run_worker(['--worker', $w, '--prompt-file', $pf],
                                           env_for($bp, $proj, $pkg),
                                           FAKE_EXIT => 0, FAKE_LOG => fwd($log));
        isnt($rc, 3, "A9: read-only worker $w never exits 3");
        # Positive half of DC-4 (added by the coordinator at the step-3 gate). The
        # negative assertions above and below pass trivially against a bp-worker.pl
        # that does nothing at all — "no marker" is also true when nothing ran. DC-4
        # claims read-only workers *may dispatch*, so the dispatch must be proven to
        # have actually happened. See the repo's "verify behaviour, not presence" rule.
        is($rc, 0, "A9: read-only worker $w dispatches successfully (exit 0)");
        ok(-e $log, "A9: read-only worker $w actually invoked the backend");
        # NB: assign glob() to a list first. `scalar(glob(PAT))` is a stateful
        # ITERATOR, not a count — called once per loop iteration it yields
        # successive matches and then undef, so it passed for the first worker
        # and failed on a later one. (Coordinator bug in the A9 addition; same
        # class as the runs_files scalar-context trap documented in t/67.)
        my @a9_reports = glob(reports_dir_for($bp, $pkg) . '/*');
        ok(-d reports_dir_for($bp, $pkg) && @a9_reports,
           "A9: read-only worker $w produced a report under reports/");
        ok(!-e $marker, "A9: no marker exists after dispatching read-only worker $w");
    }

    # Now with a write-capable marker already present.
    sysopen(my $mfh, $marker, O_WRONLY|O_CREAT|O_TRUNC) or die "open $marker: $!";
    print $mfh 'butler:bp-implementer';
    close $mfh;
    my $held_bytes = read_file($marker);
    for my $w (qw(scout architect)) {
        my $pf = write_prompt("a9-held $w prompt\n");
        my ($rc, $out, $err) = run_worker(['--worker', $w, '--prompt-file', $pf],
                                           env_for($bp, $proj, $pkg), FAKE_EXIT => 0);
        isnt($rc, 3, "A9: read-only worker $w does not exit 3 while a write-capable marker is present");
        is(read_file($marker), $held_bytes, "A9: read-only worker $w leaves the held marker's bytes untouched");
    }
}

# =====================================================================================
# A10 -- each of the three stop signals refuses, and leaves no marker.
# =====================================================================================
{
    for my $sig (
        { label => 'shutdown',  file => '.shutdown' },
        { label => 'forcestop', file => undef },   # filled in with $pkg.force-stop below
        { label => 'paused',    file => '.paused' },
    ) {
        my ($bp, $proj) = mk_bp('opencode');
        my $pkg = 'b32-a10';
        my $lp = add_pkg($bp, $pkg, undef);
        my $ledger_before = read_file($lp);
        my $stopfile = defined $sig->{file} ? "$bp/runs/$sig->{file}" : "$bp/runs/$pkg.force-stop";
        write_file($stopfile, '');
        my $marker = marker_path_for($bp, $pkg);
        my $pf = write_prompt("a10 prompt\n");
        my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf],
                                           env_for($bp, $proj, $pkg));
        is($rc, 5, "A10 ($sig->{label}): stop signal in force -> exit 5");
        like($err, qr/\Q$sig->{label}\E/i, "A10 ($sig->{label}): stderr names the signal");
        ok(!-e $marker, "A10 ($sig->{label}): no marker exists afterwards (phantom-marker hazard)");
        is(read_file($lp), $ledger_before, "A10 ($sig->{label}): no dispatch-log entry is appended");
    }
}

# =====================================================================================
# A11 / A12 -- marker cleared after success, and after worker failure (exit 7).
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b32-a11';
    add_pkg($bp, $pkg, undef);
    my $marker = marker_path_for($bp, $pkg);
    my $pf = write_prompt("a11 prompt\n");
    my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf],
                                       env_for($bp, $proj, $pkg), FAKE_EXIT => 0);
    is($rc, 0, 'A11: a backend exiting 0 -> dispatcher exits 0');
    ok(!-e $marker, 'A11: marker cleared after success');
}
{
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b32-a12';
    my $lp = add_pkg($bp, $pkg, undef);
    my $marker = marker_path_for($bp, $pkg);
    my $pf = write_prompt("a12 prompt\n");
    my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf],
                                       env_for($bp, $proj, $pkg), FAKE_EXIT => 1);
    is($rc, 7, 'A12: a backend exiting non-zero -> dispatcher exits 7');
    ok(!-e $marker, 'A12: marker cleared after worker failure');
    like($out, qr/^report: /m, 'A12: stdout still names the report file');
    if ($out =~ /^report: (\S.*)$/m) {
        ok(-e $1, 'A12: the named report file exists and holds the full output') if defined $1;
    } else {
        ok(0, 'A12: the named report file exists and holds the full output (no report: line found)');
    }
    my $ledger_after = read_file($lp);
    like($ledger_after, qr/^## Dispatch log \(auto\)$/m, 'A12: a dispatch-log entry is still appended after failure');
}

# =====================================================================================
# A13 -- SIGTERM to the dispatcher: marker cleared, exit 143, child not left running.
# =====================================================================================
SKIP: {
    skip "this OS does not support the fork/kill protocol used by this test", 3 unless $bg_supported;

    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b32-a13';
    add_pkg($bp, $pkg, undef);
    my $marker = marker_path_for($bp, $pkg);
    my $pf = write_prompt("a13 prompt\n");
    my $ready = "$ROOT/a13.ready";
    my $pidfile = "$ROOT/a13.pid";
    my ($pid, $outfile, $errfile) = run_worker_bg(
        ['--worker', 'implementer', '--prompt-file', $pf],
        env_for($bp, $proj, $pkg), FAKE_READY => fwd($ready), FAKE_PIDFILE => fwd($pidfile));
    my $became_ready = wait_for_file($ready, 6);
    ok($became_ready, 'A13: the dispatcher reached a running backend before SIGTERM');

    kill('TERM', $pid);
    my $status = wait_pid_timeout($pid, 8);
    my $rc = $status >> 8;
    is($rc, 143, 'A13: the dispatcher exits 143 (128+TERM) after SIGTERM');
    ok(!-e $marker, 'A13: marker does not remain after SIGTERM');

    if (-e $pidfile) {
        my $childpid = read_file($pidfile);
        $childpid =~ s/\D//g;
        my $gone = 1;
        if (length $childpid) {
            my $elapsed = 0;
            while (pid_alive($childpid) && $elapsed < 6) { select(undef, undef, undef, 0.1); $elapsed += 0.1; }
            $gone = !pid_alive($childpid);
        }
        ok($gone, 'A13: the fake backend child process is not left running after SIGTERM');
    } else {
        ok(0, 'A13: the fake backend child process is not left running after SIGTERM (no pidfile written)');
    }
}

# =====================================================================================
# A14 -- stdout is <=15 lines regardless of output size; full text lands on disk.
# =====================================================================================
{
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b32-a14';
    add_pkg($bp, $pkg, undef);
    my $pf = write_prompt("a14 prompt\n");
    my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf],
                                       env_for($bp, $proj, $pkg), FAKE_EXIT => 0, FAKE_LINES => 10000);
    is($rc, 0, 'A14: the huge-output backend still exits 0');
    my @lines = split /\n/, $out;
    ok(scalar(@lines) <= 15, 'A14: stdout is <=15 lines regardless of a 10000-line backend');
    my ($reportpath) = ($out =~ /^report: (\S.*)$/m);
    ok(defined $reportpath, 'A14: stdout names a report: file');
    if (defined $reportpath) {
        ok(-e $reportpath, 'A14: the named report file exists under reports/$BP_PACKAGE/');
        like($reportpath, qr{\Q@{[reports_dir_for($bp,$pkg)]}\E}, 'A14: the report file lives under reports/$BP_PACKAGE/');
        my @rl = split /\n/, read_file($reportpath);
        is(scalar(@rl), 10000, 'A14: the report file contains all 10000 lines');
    } else {
        ok(0, 'A14: the named report file exists under reports/$BP_PACKAGE/ (no report: line found)');
        ok(0, 'A14: the report file contains all 10000 lines (no report: line found)');
    }
}

# =====================================================================================
# A15 -- dispatch-log append format, heading created once, never duplicated.
# =====================================================================================
{
    # (a) heading absent -> created, preceded by a blank line, not duplicated.
    my ($bp, $proj) = mk_bp('opencode');
    my $pkg = 'b32-a15a';
    my $lp = add_pkg($bp, $pkg, undef);
    my $pf = write_prompt("first line of the a15 prompt\nsecond line, irrelevant\n");
    my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf],
                                       env_for($bp, $proj, $pkg), FAKE_EXIT => 0);
    my $ledger_after = read_file($lp);
    is(() = ($ledger_after =~ /^## Dispatch log \(auto\)$/mg), 1,
       'A15a: exactly one "## Dispatch log (auto)" heading is created');
    like($ledger_after, qr/\n\n## Dispatch log \(auto\)\n/,
         'A15a: the heading is preceded by a blank line');
    like($ledger_after,
         qr/^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \x{00b7} butler:bp-implementer \x{00b7} first line of the a15 prompt$/m,
         'A15a: the appended line matches the log-dispatch.sh format exactly, DESC = first prompt line');

    # (b) heading already present with a prior entry -> not duplicated, new entry appended.
    my ($bp2, $proj2) = mk_bp('opencode');
    my $pkg2 = 'b32-a15b';
    my $lp2 = add_pkg($bp2, $pkg2, undef,
        extra => "\n## Dispatch log (auto)\n- 2026-01-01T00:00:00Z \x{00b7} butler:bp-scout \x{00b7} prior entry\n");
    my $pf2 = write_prompt("a15b prompt line\n");
    my ($rc2, $out2, $err2) = run_worker(['--worker', 'implementer', '--prompt-file', $pf2],
                                          env_for($bp2, $proj2, $pkg2), FAKE_EXIT => 0);
    my $ledger_after2 = read_file($lp2);
    is(() = ($ledger_after2 =~ /^## Dispatch log \(auto\)$/mg), 1,
       'A15b: a pre-existing heading is NOT duplicated');
    like($ledger_after2, qr/butler:bp-scout \x{00b7} prior entry/, 'A15b: the prior entry is preserved');
    like($ledger_after2,
         qr/^- \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \x{00b7} butler:bp-implementer \x{00b7} a15b prompt line$/m,
         'A15b: the new entry is appended after the prior one, in the same format');
}

# =====================================================================================
# A16 -- usage/env guards, and the missing-backend-binary case. None of these leave a
# marker, a report or a log entry.
# =====================================================================================
{
    my ($bp, $proj) = mk_bp(undef);
    my $pkg = 'b32-a16';
    my $lp = add_pkg($bp, $pkg, undef);
    my $marker = marker_path_for($bp, $pkg);

    sub assert_a16_no_side_effects {
        my ($label, $bp, $pkg, $lp, $ledger_before) = @_;
        ok(!-e marker_path_for($bp, $pkg), "$label: no marker created");
        ok(!-d reports_dir_for($bp, $pkg) || !glob(reports_dir_for($bp, $pkg) . '/*'),
           "$label: no report file created");
        is(read_file($lp), $ledger_before, "$label: ledger byte-unchanged (no log entry)");
    }

    my $ledger_before = read_file($lp);
    my $pf_ok = write_prompt("a16 ok prompt\n");

    my ($rc1, $out1, $err1) = run_worker(['--prompt-file', $pf_ok], env_for($bp, $proj, $pkg));
    is($rc1, 2, 'A16: missing --worker -> exit 2');
    ok(length($err1), 'A16: missing --worker prints a stderr diagnostic');
    assert_a16_no_side_effects('A16 (missing --worker)', $bp, $pkg, $lp, $ledger_before);

    my ($rc2, $out2, $err2) = run_worker(['--worker', 'implementer'], env_for($bp, $proj, $pkg));
    is($rc2, 2, 'A16: missing --prompt-file -> exit 2');
    assert_a16_no_side_effects('A16 (missing --prompt-file)', $bp, $pkg, $lp, $ledger_before);

    # Substitutes for "unreadable prompt file": root inside this sandbox bypasses chmod 0000,
    # so a nonexistent path is used instead to exercise the same "cannot read the prompt" guard.
    my ($rc3, $out3, $err3) = run_worker(
        ['--worker', 'implementer', '--prompt-file', "$ROOT/does-not-exist.txt"],
        env_for($bp, $proj, $pkg));
    is($rc3, 2, 'A16: --prompt-file naming a nonexistent path -> exit 2 (stands in for "unreadable")');
    assert_a16_no_side_effects('A16 (nonexistent --prompt-file)', $bp, $pkg, $lp, $ledger_before);

    my ($rc4, $out4, $err4) = run_worker(
        ['--worker', 'nonsense', '--prompt-file', $pf_ok], env_for($bp, $proj, $pkg));
    is($rc4, 2, 'A16: --worker nonsense (outside the closed set) -> exit 2');
    assert_a16_no_side_effects('A16 (--worker nonsense)', $bp, $pkg, $lp, $ledger_before);

    for my $missing (qw(BP_DIR BP_PACKAGE BP_LEDGER BP_PROJECT_ROOT)) {
        my %env = env_for($bp, $proj, $pkg);
        delete $env{$missing};
        my ($rc, $out, $err) = run_worker(['--worker', 'implementer', '--prompt-file', $pf_ok], %env);
        is($rc, 6, "A16: $missing unset -> exit 6");
        like($err, qr/\Q$missing\E/, "A16: $missing unset -> stderr names the missing variable");
    }

    # Resolved-but-absent backend binary: worker_backend: opencode, PATH without the fake bin.
  SKIP: {
    # Without symlinks there is no opencode-free PATH to hand over; passing the
    # undef through would set an EMPTY PATH, and the child then cannot find bash
    # at all ("Can't exec bash"), which killed the file after 141 green
    # assertions. The scenario under test is "the backend binary is missing from
    # an otherwise working PATH" — an unusable PATH is a different scenario.
    skip 'no opencode-free PATH could be built here (symlinks unavailable), so the '
       . 'resolved-but-absent-binary case is NOT exercised', 5
        unless defined $PATH_WITHOUT_FAKE;
    my ($bpX, $projX) = mk_bp('opencode');
    my $pkgX = 'b32-a16-nobin';
    my $lpX = add_pkg($bpX, $pkgX, undef);
    my $ledgerX_before = read_file($lpX);
    my $pfX = write_prompt("a16 nobin prompt\n");
    my ($rcX, $outX, $errX) = run_worker(['--worker', 'implementer', '--prompt-file', $pfX],
                                          env_for($bpX, $projX, $pkgX), PATH => $PATH_WITHOUT_FAKE);
    is($rcX, 8, 'A16: opencode resolved but absent from PATH -> exit 8');
    assert_a16_no_side_effects('A16 (backend binary absent)', $bpX, $pkgX, $lpX, $ledgerX_before);
  }
}

done_testing();
