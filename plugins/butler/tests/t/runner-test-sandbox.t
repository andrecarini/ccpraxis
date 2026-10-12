#!/usr/bin/env perl
# platform: any
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 } # this file names the real lease module in prose while
# proving a FAKE stand-in leftover process is caught; it never arms the real thing.
#
# Package 21-test-sandbox (hook-continuity-remake): scripts/run-tests.pl gets a
# per-test-file throwaway sandbox (HOME/USERPROFILE/APPDATA/LOCALAPPDATA/TEMP/
# TMP/TMPDIR/BUTLER_STATE_DIR/CCPRAXIS_CONTINUITY_ACTIVE_DIR), a pre/post-sweep
# audit that fails the sweep on a new repo path or a surviving fake
# keep-lease-style process, skip_all files reported as SKIPPED rather than
# silently green, and the same treatment for a single-file invocation. None of
# that exists yet -- this file is the oracle for it.
#
# EVERYTHING RUNS AGAINST A TEMP, GIT-INIT'D FAKE REPO, NEVER THE REAL TREE AND
# NEVER THE REAL HOME. The fake repo carries its own copy of
# scripts/run-tests.pl (plus the two files it unconditionally requires:
# scripts/run-tests-container.pl and plugins/butler/tests/lib/TestPlatform.pm)
# so that copy's own ROOT_ABS computation resolves to the fake repo, not this
# one -- any git-status audit or stray-file write it performs lands there, not
# here. Fixtures report what they saw through custom env vars
# (FIXTURE_REPORT_DIR / FIXTURE_REPO_ROOT) rather than $Bin arithmetic, since
# those two names sit outside the sandbox's own reserved-name set and so pass
# through whatever the (not yet built) sandboxing does to HOME et al.
#
# Every invocation is bounded by a fork+timeout wrapper mirroring
# RunnerStateHarness::run_runner_bounded (reused directly, along with its own
# repo_root() and slurp_raw()); nothing here uses system()/backticks/qx() on a
# literal sibling .t -- every spawn below targets a .pl (the fake repo's own
# copy of run-tests.pl) or an inline perl one-liner, never a repo .t file.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use POSIX ();

use lib "$Bin/../lib";
use HostCaps ();
use RunnerStateHarness qw(repo_root reap_with_grace slurp_raw);

my $BOUND = 60;   # generous: the fake repo's sweep is tiny, but git init/commit
                   # and a forked worker wave both cost real wall time on this host.

# ---------------------------------------------------------------------------
# Scaffolding (inline: this package's write set is this single file).
# ---------------------------------------------------------------------------

# build_fake_repo(%fixtures) -> $repo_abs
# %fixtures maps a bare basename (must end .t) to file content, written under
# $repo/plugins/x/tests/t/. Copies the real run-tests.pl and the two files it
# unconditionally `require`s, git-inits, and commits everything so the repo
# starts CLEAN -- any file appearing afterwards is genuinely new.
sub build_fake_repo {
    my (%fixtures) = @_;

    my $repo = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $real_root = repo_root();

    make_path(File::Spec->catdir($repo, 'scripts'));
    copy(File::Spec->catfile($real_root, 'scripts', 'run-tests.pl'),
         File::Spec->catfile($repo, 'scripts', 'run-tests.pl'))
        or die "cannot copy run-tests.pl: $!";
    copy(File::Spec->catfile($real_root, 'scripts', 'run-tests-container.pl'),
         File::Spec->catfile($repo, 'scripts', 'run-tests-container.pl'))
        or die "cannot copy run-tests-container.pl: $!";

    make_path(File::Spec->catdir($repo, qw(plugins butler tests lib)));
    copy(File::Spec->catfile($real_root, qw(plugins butler tests lib TestPlatform.pm)),
         File::Spec->catfile($repo, qw(plugins butler tests lib TestPlatform.pm)))
        or die "cannot copy TestPlatform.pm: $!";

    my $ttdir = repo_plugin_tests_dir($repo);
    make_path($ttdir);
    for my $name (sort keys %fixtures) {
        my $path = File::Spec->catfile($ttdir, $name);
        open my $fh, '>', $path or die "cannot write fixture $path: $!";
        print {$fh} $fixtures{$name};
        close $fh;
    }

    my $gp = HostCaps::git_path($repo);
    system('git', '-C', $gp, 'init', '-q') == 0
        or die "git init failed in $repo";
    system('git', '-C', $gp, 'add', '-A') == 0
        or die "git add failed in $repo";
    system('git', '-C', $gp, '-c', 'user.email=oracle@ccpraxis.test',
           '-c', 'user.name=oracle', 'commit', '-q', '-m', 'fake repo: initial commit') == 0
        or die "git commit failed in $repo";

    return $repo;
}

sub repo_plugin_tests_dir {
    my ($repo) = @_;
    return File::Spec->catdir($repo, qw(plugins x tests t));
}

# run_fake_sweep(repo=>.., args=>[..], env=>{..}, timeout=>N) -> {rc,out,err,timed_out}
# Mirrors RunnerStateHarness::run_runner_bounded exactly, except the script
# path is the FAKE repo's own copy, and env{HOME} is REQUIRED -- this process's
# real HOME is never allowed to leak to the child by omission.
sub run_fake_sweep {
    my (%args) = @_;
    my $repo    = $args{repo} or die 'run_fake_sweep: repo required';
    my $arglist = $args{args} // [];
    my $env     = $args{env}  // {};
    die "run_fake_sweep: env{HOME} is required (never inherit the real HOME)\n"
        unless defined $env->{HOME} && length $env->{HOME};
    my $script  = File::Spec->catfile($repo, 'scripts', 'run-tests.pl');

    my $out_fh = File::Temp->new(UNLINK => 0);
    my $err_fh = File::Temp->new(UNLINK => 0);
    my $out_path = "$out_fh";
    my $err_path = "$err_fh";
    close $out_fh;
    close $err_fh;

    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        # tooling-fixes 10 (Decision 28): delete the marker this test file's
        # OWN process may itself have inherited from an enclosing sweep,
        # before anything else runs -- this file's whole audit oracle (AC-2,
        # AC-4, M4, M5, M6, M7) exists to exercise the REAL audit, and a
        # sweep running this very file would otherwise leave
        # CCPRAXIS_SWEEP_OWNS_AUDIT=1 armed, making the fake sweep below skip
        # its own audit and go green for the wrong reason.
        delete $ENV{CCPRAXIS_SWEEP_OWNS_AUDIT};
        for my $k (keys %$env) { $ENV{$k} = $env->{$k} }
        open(STDOUT, '>', $out_path) or POSIX::_exit(97);
        open(STDERR, '>', $err_path) or POSIX::_exit(98);
        exec($^X, $script, @$arglist) or POSIX::_exit(99);
    }
    my ($rc, $timed_out) = reap_with_grace($pid, timeout => ($args{timeout} // $BOUND));
    my $out = slurp_raw($out_path) // '';
    my $err = slurp_raw($err_path) // '';
    unlink $out_path, $err_path;
    return { rc => $rc, out => $out, err => $err, timed_out => $timed_out, pid => $pid };
}

# Fixture sources. Every one reports through $ENV{FIXTURE_REPORT_DIR} and/or
# $ENV{FIXTURE_REPO_ROOT}, both set explicitly by the caller below, never
# derived from $Bin/dirname arithmetic inside the fixture itself.

sub home_probe_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
use File::Path qw(make_path);
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my $home = defined $ENV{HOME} ? $ENV{HOME} : '';
open(my $fh, '>', "$report/home-seen.txt") or die "$!";
print {$fh} $home;
close $fh;
if (length $home) {
    my $dir = "$home/.claude/butler-state";
    make_path($dir);
    open(my $w, '>', "$dir/x") or die "$!";
    print {$w} "touched\n";
    close $w;
}
print "ok 1 - home probe fixture ran\n";
exit 0;
SRC
}

sub stray_writer_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $root = $ENV{FIXTURE_REPO_ROOT};
die "FIXTURE_REPO_ROOT not set\n" unless defined $root && length $root;
open(my $fh, '>', "$root/stray-marker-file.txt") or die "$!";
print {$fh} "stray\n";
close $fh;
print "ok 1 - stray-writer fixture ran\n";
exit 0;
SRC
}

sub skip_all_source {
    my ($reason) = @_;
    $reason //= 'fixture: deliberately skipped';
    return <<"SRC";
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
use Test::More;
plan skip_all => '$reason';
SRC
}

# leftover_process_source() -- forks, execs a real "perl -e 'sleep(60)'" child
# whose own argv literally carries the fake stand-in name (the ledger's own
# example), records that child's pid to
# "$FIXTURE_REPORT_DIR/leftover-pid.txt", and exits WITHOUT waiting --
# orphaning it exactly the way a real leaked helper is orphaned.
sub leftover_process_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my $pid = fork();
die "fork failed: $!" unless defined $pid;
if ($pid == 0) {
    # Close the inherited stdout/stderr BEFORE exec: run-tests.pl's own
    # run_one() captures this fixture through a backtick pipe, which does not
    # see EOF until every process holding the write end closes it -- without
    # this, the orphaned grandchild below holds that pipe open for its whole
    # sleep, and the SWEEP ITSELF hangs on this one file instead of moving on.
    open(STDIN,  '<', '/dev/null');
    open(STDOUT, '>', '/dev/null');
    open(STDERR, '>', '/dev/null');
    exec($^X, '-e', 'sleep(60)', 'keep-awake.ps1') or exit(127);
}
open(my $fh, '>', "$report/leftover-pid.txt") or die "$!";
print {$fh} $pid;
close $fh;
print "ok 1 - leftover-process fixture ran, leaving a background process alive\n";
exit 0;
SRC
}

sub green_fixture_source {
    return "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - plain fixture pass\\n\";\nexit 0;\n";
}

# --- fixture sources added for the review fix-round (M1-M7, m1, m4) --------

# readonly_blocker_source() -- reports its own HOME, then creates a file
# inside it and chmod 0444s it (the shape a git object file takes), so the
# sweep's own sandbox teardown has to remove a directory holding a read-only
# file (M1).
sub readonly_blocker_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
use File::Path qw(make_path);
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my $home = defined $ENV{HOME} ? $ENV{HOME} : '';
open(my $fh, '>', "$report/home-seen.txt") or die "$!";
print {$fh} $home;
close $fh;
if (length $home) {
    my $dir = "$home/blocker";
    make_path($dir);
    my $obj = "$dir/git-object-like-file";
    open(my $w, '>', $obj) or die "$!";
    print {$w} "read-only payload\n";
    close $w;
    chmod(0444, $obj) or die "cannot chmod $obj read-only: $!";
}
print "ok 1 - readonly-blocker fixture ran\n";
exit 0;
SRC
}

# git_config_probe_source() -- reports the GIT_CONFIG_GLOBAL value the test
# sees, then attempts a `git config --global` write, proving whether that
# write can reach the real ~/.gitconfig (M2).
sub git_config_probe_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my $gcg = defined $ENV{GIT_CONFIG_GLOBAL} ? $ENV{GIT_CONFIG_GLOBAL} : '<UNSET>';
open(my $fh, '>', "$report/git-config-global-seen.txt") or die "$!";
print {$fh} $gcg;
close $fh;
system('git', 'config', '--global', 'user.email', 'fixture-m2@example.invalid');
system('git', 'config', '--global', 'test.fixturemarker', 'written-by-fixture-m2');
print "ok 1 - git-config-probe fixture ran\n";
exit 0;
SRC
}

# ambient_env_probe_source() -- reports what the test sees for each of the
# ambient ccpraxis path variables named in M3, so the test file can check
# they were unset or sandboxed rather than passed straight through.
sub ambient_env_probe_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my @VARS = qw(BP_LEDGER BP_DIR BP_PROJECT_ROOT CCPRAXIS_DATA_DIR CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR ALMANAC_HOME);
open(my $fh, '>', "$report/ambient-env-seen.txt") or die "$!";
for my $v (@VARS) {
    my $val = defined $ENV{$v} ? $ENV{$v} : '<UNSET>';
    print {$fh} "$v=$val\n";
}
close $fh;
print "ok 1 - ambient-env-probe fixture ran\n";
exit 0;
SRC
}

# real_state_writer_source() -- writes a marker file directly into whatever
# "real" butler-state / continuity-active directories the test passes it
# through the non-reserved FIXTURE_REAL_* channel names (M4), bypassing
# whatever sandboxed value the runner hands the test through the reserved
# BUTLER_STATE_DIR / CCPRAXIS_CONTINUITY_ACTIVE_DIR names themselves.
sub real_state_writer_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
use File::Path qw(make_path);
for my $v (qw(FIXTURE_REAL_BUTLER_STATE FIXTURE_REAL_CONTINUITY_ACTIVE)) {
    my $dir = $ENV{$v};
    next unless defined $dir && length $dir;
    make_path($dir) unless -d $dir;
    open(my $fh, '>', "$dir/m4-marker.txt") or die "$!";
    print {$fh} "written by m4 fixture ($v)\n";
    close $fh;
}
print "ok 1 - real-state-writer fixture ran\n";
exit 0;
SRC
}

# inflight_writer_source() -- creates a stray file at exactly the path
# another (fixture) in-flight package's write_set claims (M6).
sub inflight_writer_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
use File::Path qw(make_path);
my $root = $ENV{FIXTURE_REPO_ROOT};
die "FIXTURE_REPO_ROOT not set\n" unless defined $root && length $root;
make_path("$root/new-path-outside-tests");
open(my $fh, '>', "$root/new-path-outside-tests/stray-attributed.txt") or die "$!";
print {$fh} "stray, but attributed\n";
close $fh;
print "ok 1 - inflight-writer fixture ran\n";
exit 0;
SRC
}

# transient_wakelock_source() -- spawns (and does not wait for) a detached
# process whose argv carries a wake-lock stand-in name, but which exits on
# its own after one second -- short enough that a pre/post-sweep double
# snapshot ~2s apart should never see it in both (M5, second half).
sub transient_wakelock_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $pid = fork();
die "fork failed: $!" unless defined $pid;
if ($pid == 0) {
    open(STDIN,  '<', '/dev/null');
    open(STDOUT, '>', '/dev/null');
    open(STDERR, '>', '/dev/null');
    exec($^X, '-e', 'sleep(1)', 'bp-keepawake.pl') or exit(127);
}
print "ok 1 - transient-wakelock fixture ran\n";
exit 0;
SRC
}

# crash_zero_tests_source() -- prints a bare "1..0" plan (Test::More's own
# shape for "no tests run", the exact pattern the review names) and exits
# 255, without ever calling plan skip_all -- so _skip_all_reason's regex
# should NOT treat this as a legitimate skip (m1).
sub crash_zero_tests_source {
    return "#!/usr/bin/env perl\n# platform: any\nprint \"1..0\\n\";\nexit 255;\n";
}

# interrupt_probe_source() -- reports its HOME immediately, then sleeps far
# longer than this test needs so the sweep can be SIGTERM'd mid-run (m4,
# second half: an interrupted run must leave no sandbox directory behind).
sub interrupt_probe_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my $home = defined $ENV{HOME} ? $ENV{HOME} : '';
open(my $fh, '>', "$report/home-seen.txt") or die "$!";
print {$fh} $home;
close $fh;
sleep(20);
print "ok 1 - interrupt-probe fixture ran (should never print; sweep should be killed first)\n";
exit 0;
SRC
}

sub read_ambient_env_report {
    my ($dir) = @_;
    my $raw = read_report($dir, 'ambient-env-seen.txt');
    return {} unless defined $raw && length $raw;
    my %h;
    for my $line (split /\n/, $raw) {
        $h{$1} = $2 if $line =~ /^(\S+)=(.*)$/;
    }
    return \%h;
}

sub pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/;
    return kill(0, $pid) ? 1 : 0;
}

# spawn_named_bg_process($name, $secs) -> $pid
# Forks and execs a detached "perl -e 'sleep($secs)' $name" directly from
# THIS file (not through a fixture .t), for review-round scenarios (M5) that
# need a process alive/gone BEFORE the fake sweep even starts, not one the
# fixture itself spawns mid-run. $name becomes the child's own argv, which is
# how the runner's real wake-lock audit is expected to recognise it (the same
# technique leftover_process_source() already uses for AC-4).
sub spawn_named_bg_process {
    my ($name, $secs) = @_;
    $secs //= 20;
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', '/dev/null');
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec($^X, '-e', "sleep($secs)", $name) or exit(127);
    }
    return $pid;
}

my @KILL_ON_EXIT;   # pids of every fixture-orphaned process this file learns about;
                    # killed unconditionally in the END block below.
END {
    for my $pid (@KILL_ON_EXIT) {
        next unless pid_alive($pid);
        kill('KILL', $pid);
    }
}

sub read_report {
    my ($dir, $name) = @_;
    my $path = File::Spec->catfile($dir, $name);
    return undef unless -f $path;
    return slurp_raw($path);
}

# ---------------------------------------------------------------------------
# AC-1: a fixture writing $HOME/.claude/butler-state/x lands under the
# runner's own per-file sandbox, not under the HOME the runner was started
# with -- proven for both a full default sweep AND an explicit single-file
# target (the ledger's "single-file run gets the same sandbox" clause).
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('home-probe.t' => home_probe_source());
    my $fixture_path = File::Spec->catfile(repo_plugin_tests_dir($repo), 'home-probe.t');

    for my $case (
        { label => 'full default sweep', args => [] },
        { label => 'explicit single-file target', args => [$fixture_path] },
    ) {
        my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
        my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

        # Deliberately NO --keep-sandbox here -- AC-1 is about ISOLATION
        # (does the write land somewhere other than the outer HOME), not
        # about lifecycle (AC-5 owns that). Requiring the flag here would
        # make this block depend on --keep-sandbox parsing too, muddying
        # which missing behavior a red result points at.
        my $res = run_fake_sweep(
            repo    => $repo,
            args    => [@{ $case->{args} }],
            env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
            timeout => $BOUND,
        );

        is($res->{rc}, 0,
            "AC-1 ($case->{label}): the home-probe fixture itself runs cleanly")
            or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

        my $outer_marker = File::Spec->catfile($outer_home, qw(.claude butler-state x));
        ok(!-e $outer_marker,
            "AC-1 ($case->{label}): the HOME the runner was STARTED with is never written to "
          . "(no .claude/butler-state/x appears under it)")
            or diag("outer HOME leaked into: $outer_marker");

        my $seen_home = read_report($report_dir, 'home-seen.txt');
        ok(defined $seen_home && length $seen_home,
            "AC-1 ($case->{label}): the fixture reported the HOME it actually ran under");

        if (defined $seen_home && length $seen_home) {
            isnt($seen_home, $outer_home,
                "AC-1 ($case->{label}): the fixture's own HOME differs from the runner's "
              . "starting HOME -- it ran inside a per-file sandbox, not the outer one");
        } else {
            fail("AC-1 ($case->{label}): the fixture's own HOME differs from the runner's "
               . 'starting HOME (no HOME was reported at all)');
        }
    }
}

# ---------------------------------------------------------------------------
# AC-2: a fixture that creates a stray file directly in the fake repo's own
# root fails the sweep and NAMES the path. (The runner's own
# .ccpraxis-local-data/test-state writes, which happen on every sweep today
# regardless, are explicitly exempted by the contract -- but its exact
# wording for "ignored" isn't pinned by the spec, so this oracle does not
# assert a specific phrase for that half; only that the DELIBERATE stray is
# named and fails the sweep.)
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('stray-writer.t' => stray_writer_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPO_ROOT => $repo },
        timeout => $BOUND,
    );

    isnt($res->{rc}, 0,
        'AC-2: a stray file appearing in the fake repo root FAILS the sweep')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/stray-marker-file\.txt/,
        'AC-2: the failure NAMES the stray path')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
}

# ---------------------------------------------------------------------------
# AC-3: a skip_all file is listed as SKIPPED with its reason, not folded
# silently into a green result.
# ---------------------------------------------------------------------------
{
    my $reason = 'fixture-reason-9f3c: deliberately skipped for the sandbox oracle';
    my $repo = build_fake_repo('skip-me.t' => skip_all_source($reason));
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home },
        timeout => $BOUND,
    );

    is($res->{rc}, 0,
        'AC-3: a skip_all file alone does not fail the sweep')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out}, qr/SKIPPED/,
        'AC-3: the skip_all file is listed as SKIPPED')
        or diag("stdout:\n$res->{out}");
    like($res->{out}, qr/\Q$reason\E/,
        'AC-3: the SKIPPED listing carries the file\'s own skip reason')
        or diag("stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC-4: a fixture that leaves a background process behind, whose own command
# line carries the fake stand-in name, fails the sweep's post-run audit and
# NAMES it. The process is killed unconditionally at the end of this file
# regardless of how these assertions land.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('leftover.t' => leftover_process_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
        timeout => $BOUND,
    );

    my $leftover_pid = read_report($report_dir, 'leftover-pid.txt');
    if (defined $leftover_pid && $leftover_pid =~ /(\d+)/) {
        push @KILL_ON_EXIT, $1;   # unconditional cleanup, whatever the assertions below say
    }

    isnt($res->{rc}, 0,
        'AC-4: a surviving fixture-spawned background process FAILS the sweep\'s audit')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/keep-awake\.ps1/,
        'AC-4: the audit failure NAMES the offending process')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    if (defined $leftover_pid && $leftover_pid =~ /^(\d+)$/) {
        my $pid = $1;
        kill('KILL', $pid);
        my $deadline = time() + 10;
        while (time() < $deadline && pid_alive($pid)) { select(undef, undef, undef, 0.1) }
        ok(!pid_alive($pid), 'AC-4: the leftover process is dead after this file\'s own cleanup');
    } else {
        fail('AC-4: the fixture reported a leftover pid to clean up')
            or diag("report dir contents unavailable; leftover_pid=" . (defined $leftover_pid ? $leftover_pid : '<undef>'));
    }
}

# ---------------------------------------------------------------------------
# AC-5: the per-file sandbox root is removed by default, and kept only with
# --keep-sandbox -- proven by checking whether the reported sandbox HOME
# (which lives inside that root) still exists afterward.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('home-probe-2.t' => home_probe_source());

    my $outer_home_default = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_default     = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $res_default = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home_default, FIXTURE_REPORT_DIR => $report_default },
        timeout => $BOUND,
    );
    my $home_default = read_report($report_default, 'home-seen.txt');
    ok(defined $home_default && length $home_default,
        'AC-5 (default): the fixture reported a sandbox HOME');
    ok((defined $home_default && length $home_default) ? !-e $home_default : 0,
        'AC-5 (default): the reported sandbox HOME no longer exists after the sweep (removed by default)')
        or diag('sandbox HOME still present: ' . (defined $home_default ? $home_default : '<undef>'));

    my $outer_home_keep = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_keep     = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $res_keep = run_fake_sweep(
        repo    => $repo,
        args    => ['--keep-sandbox'],
        env     => { HOME => $outer_home_keep, FIXTURE_REPORT_DIR => $report_keep },
        timeout => $BOUND,
    );
    my $home_keep = read_report($report_keep, 'home-seen.txt');
    ok(defined $home_keep && length $home_keep,
        'AC-5 (--keep-sandbox): the fixture reported a sandbox HOME');
    ok((defined $home_keep && length $home_keep) ? -e $home_keep : 0,
        'AC-5 (--keep-sandbox): the reported sandbox HOME still exists after the sweep')
        or diag('sandbox HOME missing: ' . (defined $home_keep ? $home_keep : '<undef>'));
}

# ---------------------------------------------------------------------------
# AC-6: a normal, side-effect-free fixture stays green and the audit passes
# -- the "nothing here should ever go red" floor.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('plain-pass.t' => green_fixture_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home },
        timeout => $BOUND,
    );

    is($res->{rc}, 0,
        'AC-6: a plain passing fixture with no side effects stays green')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out}, qr/all green/,
        'AC-6: the sweep reports "all green"')
        or diag("stdout:\n$res->{out}");
}

# ===========================================================================
# Review fix-round additions (21-test-sandbox-review.md): M1-M7, m1, m4.
# ===========================================================================

# ---------------------------------------------------------------------------
# M1: a sandbox holding a read-only file (like a git object) is still
# removed after the run.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('readonly-blocker.t' => readonly_blocker_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
        timeout => $BOUND,
    );

    is($res->{rc}, 0,
        'M1: the readonly-blocker fixture itself runs cleanly')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    my $home = read_report($report_dir, 'home-seen.txt');
    ok(defined $home && length $home,
        'M1: the fixture reported its sandbox HOME');

    if (defined $home && length $home) {
        ok(!-e $home,
            'M1: the sandbox is fully removed even though it held a read-only (0444) file')
            or diag("sandbox still present: $home");
    } else {
        fail('M1: the sandbox is fully removed even though it held a read-only (0444) file');
    }

    unlike($res->{out} . $res->{err}, qr/sandbox not fully removed/,
        'M1: no "sandbox not fully removed" warning is printed')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
}

# ---------------------------------------------------------------------------
# M2: GIT_CONFIG_GLOBAL seen by a test is a copy inside its sandbox, and a
# `git config --global` inside a test never changes the real file.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('git-config-probe.t' => git_config_probe_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $real_gitconfig = File::Spec->catfile($outer_home, '.gitconfig');
    open(my $fh, '>', $real_gitconfig) or die "cannot write $real_gitconfig: $!";
    print {$fh} "[user]\n\temail = real-operator\@example.invalid\n";
    close $fh;

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
        timeout => $BOUND,
    );

    is($res->{rc}, 0,
        'M2: the git-config-probe fixture itself runs cleanly')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    my $seen_gcg = read_report($report_dir, 'git-config-global-seen.txt');
    ok(defined $seen_gcg && length $seen_gcg,
        'M2: the fixture reported a GIT_CONFIG_GLOBAL value');

    if (defined $seen_gcg && length $seen_gcg) {
        (my $seen_norm = $seen_gcg) =~ s{\\}{/}g;
        (my $real_norm = $real_gitconfig) =~ s{\\}{/}g;
        isnt($seen_norm, $real_norm,
            'M2: the GIT_CONFIG_GLOBAL the test sees is not the real ~/.gitconfig path')
            or diag("seen: $seen_gcg\nreal: $real_gitconfig");
    } else {
        fail('M2: the GIT_CONFIG_GLOBAL the test sees is not the real ~/.gitconfig path');
    }

    my $real_after = slurp_raw($real_gitconfig) // '';
    unlike($real_after, qr/written-by-fixture-m2/,
        'M2: a `git config --global` write inside the test never lands in the real ~/.gitconfig')
        or diag("real ~/.gitconfig now reads:\n$real_after");
    like($real_after, qr/real-operator/,
        'M2: the real ~/.gitconfig is otherwise untouched')
        or diag("real ~/.gitconfig now reads:\n$real_after");
}

# ---------------------------------------------------------------------------
# M3: BP_LEDGER, BP_DIR, BP_PROJECT_ROOT, CCPRAXIS_DATA_DIR,
# CLAUDE_PROJECT_DIR, CLAUDE_CONFIG_DIR and ALMANAC_HOME are unset or
# sandboxed for the test, even when set in the runner's own environment.
# ---------------------------------------------------------------------------
{
    my @AMBIENT_VARS = qw(
        BP_LEDGER BP_DIR BP_PROJECT_ROOT CCPRAXIS_DATA_DIR
        CLAUDE_PROJECT_DIR CLAUDE_CONFIG_DIR ALMANAC_HOME
    );

    my $repo = build_fake_repo('ambient-env-probe.t' => ambient_env_probe_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my %env = (HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir);
    $env{$_} = "REAL-SENTINEL-$_" for @AMBIENT_VARS;

    my $res = run_fake_sweep(repo => $repo, args => [], env => \%env, timeout => $BOUND);

    is($res->{rc}, 0,
        'M3: the ambient-env-probe fixture itself runs cleanly')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    my $seen = read_ambient_env_report($report_dir);
    for my $v (@AMBIENT_VARS) {
        my $sentinel = "REAL-SENTINEL-$v";
        my $got = $seen->{$v};
        ok(!defined($got) || $got eq '<UNSET>' || $got ne $sentinel,
            "M3: $v is unset or sandboxed for the test (not the runner's own ambient value)")
            or diag("test saw $v=" . (defined $got ? $got : '<not reported>'));
    }
}

# ---------------------------------------------------------------------------
# M4: a write into a fixture 'real' butler-state dir or continuity active
# dir during a sweep is reported by the audit.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('real-state-writer.t' => real_state_writer_source());
    my $outer_home        = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $real_butler_state  = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $real_continuity    = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => {
            HOME                          => $outer_home,
            BUTLER_STATE_DIR              => $real_butler_state,
            CCPRAXIS_CONTINUITY_ACTIVE_DIR => $real_continuity,
            FIXTURE_REAL_BUTLER_STATE      => $real_butler_state,
            FIXTURE_REAL_CONTINUITY_ACTIVE => $real_continuity,
        },
        timeout => $BOUND,
    );

    isnt($res->{rc}, 0,
        'M4: a write into the real butler-state/continuity-active dirs during a sweep fails it')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    (my $bs_marker = File::Spec->catfile($real_butler_state, 'm4-marker.txt')) =~ s{\\}{/}g;
    (my $ca_marker = File::Spec->catfile($real_continuity,   'm4-marker.txt')) =~ s{\\}{/}g;
    my $combined = $res->{out} . $res->{err};
    (my $combined_norm = $combined) =~ s{\\}{/}g;

    ok(index($combined_norm, $bs_marker) >= 0 || index($combined_norm, $ca_marker) >= 0,
        'M4: the audit NAMES the real-dir marker file it caught')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
}

# ---------------------------------------------------------------------------
# M5: the wake-lock audit ignores a keep-awake pid recorded in the real
# keepawake.pid, and a short-lived one gone by the second snapshot.
# ---------------------------------------------------------------------------
{
    # M5a: a pid already recorded in the real keepawake.pid is the
    # operator's own legitimate refresher, not a leak -- it must not fail a
    # sweep that otherwise does nothing wrong.
    my $repo = build_fake_repo('plain-pass-m5a.t' => green_fixture_source());
    my $outer_home       = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $real_butler_state = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $keeper_pid = spawn_named_bg_process('keep-awake.ps1', 30);
    push @KILL_ON_EXIT, $keeper_pid;

    open(my $fh, '>', "$real_butler_state/keepawake.pid") or die "$!";
    print {$fh} $keeper_pid;
    close $fh;

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, BUTLER_STATE_DIR => $real_butler_state },
        timeout => $BOUND,
    );

    is($res->{rc}, 0,
        'M5a: a pid recorded in the real keepawake.pid is exempted from the wake-lock audit')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    kill('KILL', $keeper_pid);
    waitpid($keeper_pid, 0);
}
{
    # M5b: a keep-awake-named process that is already gone by the second
    # snapshot must not fail the sweep either.
    my $repo = build_fake_repo('transient-wakelock.t' => transient_wakelock_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home },
        timeout => $BOUND,
    );

    is($res->{rc}, 0,
        'M5b: a short-lived keep-awake-named process gone by the second snapshot does not fail the audit')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
}

# ---------------------------------------------------------------------------
# M6: a new path inside another in-flight package's write_set is listed as
# not attributed and does not fail the audit.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('inflight-writer.t' => inflight_writer_source());

    my $ledger_dir = File::Spec->catdir($repo, qw(.ccpraxis-local-data blueprints other-bp packages));
    make_path($ledger_dir);
    my $ledger_path = File::Spec->catfile($ledger_dir, 'other-pkg.md');
    open(my $lfh, '>', $ledger_path) or die "cannot write $ledger_path: $!";
    print {$lfh} <<'LEDGER';
---
package: other-pkg
blueprint: other-bp
status: running
write_set: new-path-outside-tests/stray-attributed.txt
---
LEDGER
    close $lfh;

    my $dsdir = File::Spec->catdir($repo, qw(.ccpraxis-local-data .drive-solo));
    make_path($dsdir);
    my $inflight_path = File::Spec->catfile($dsdir, 'inflight.json');
    open(my $ifh, '>', $inflight_path) or die "cannot write $inflight_path: $!";
    print {$ifh} <<'INFLIGHT';
{"packages":[{"blueprint":"other-bp","package":"other-pkg","ledger":".ccpraxis-local-data/blueprints/other-bp/packages/other-pkg.md","since":1}],"updated_at":1}
INFLIGHT
    close $ifh;

    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPO_ROOT => $repo },
        timeout => $BOUND,
    );

    is($res->{rc}, 0,
        "M6: a new path inside another in-flight package's write_set does not fail the audit")
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/not attributed/i,
        'M6: the new path is listed under a non-failing "not attributed" heading')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/stray-attributed\.txt/,
        'M6: the not-attributed path is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
}

# ---------------------------------------------------------------------------
# M7: the process audit has a non-Windows branch.
# ---------------------------------------------------------------------------
if ($^O =~ /^(MSWin32|cygwin|msys)$/) {
    SKIP: {
        skip('M7: this host is Windows/MSYS, so the process audit\'s non-Windows '
           . '(POSIX ps) branch cannot be exercised without starting the container '
           . 'lane, which this suite refuses to do', 1);
    }
} else {
    my $repo = build_fake_repo('leftover-posix.t' => leftover_process_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
        timeout => $BOUND,
    );

    my $leftover_pid = read_report($report_dir, 'leftover-pid.txt');
    if (defined $leftover_pid && $leftover_pid =~ /(\d+)/) {
        push @KILL_ON_EXIT, $1;
    }

    isnt($res->{rc}, 0,
        'M7 (non-Windows host): a leftover keep-awake-named process still fails the audit via the POSIX branch')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
}

# ---------------------------------------------------------------------------
# m1: a file that crashes with zero tests is RED, not SKIPPED.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('crash-zero-tests.t' => crash_zero_tests_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home },
        timeout => $BOUND,
    );

    isnt($res->{rc}, 0,
        'm1: a file that crashes with zero tests fails the sweep')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, qr/SKIPPED:.*crash-zero-tests\.t/s,
        'm1: the crashing file is not listed as SKIPPED')
        or diag("stdout:\n$res->{out}");
    like($res->{out} . $res->{err}, qr/crash-zero-tests\.t/,
        'm1: the crashing file is named among the failures')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
}

# ---------------------------------------------------------------------------
# m4: sandbox dirs carry a recognisable prefix, and an interrupted run
# leaves none behind where that's testable.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('home-probe-m4.t' => home_probe_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
        timeout => $BOUND,
    );

    my $home = read_report($report_dir, 'home-seen.txt');
    ok(defined $home && length $home,
        'm4: the fixture reported a sandbox HOME');
    if (defined $home && length $home) {
        like($home, qr/ccpraxis-sweep/i,
            'm4: the sandbox path carries a recognisable "ccpraxis-sweep" prefix')
            or diag("sandbox HOME was: $home");
    } else {
        fail('m4: the sandbox path carries a recognisable "ccpraxis-sweep" prefix');
    }
}
{
    SKIP: {
        my $signals_ok = HostCaps::signals_work();
        skip("m4: this host's signal emulation is not reliable enough "
           . '(HostCaps::signals_work reports false) to exercise an interrupted-run cleanup', 2)
            unless $signals_ok;

        my $repo = build_fake_repo('interrupt-probe.t' => interrupt_probe_source());
        my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
        my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
        my $script     = File::Spec->catfile($repo, 'scripts', 'run-tests.pl');

        my $pid = fork();
        die "fork failed: $!" unless defined $pid;
        if ($pid == 0) {
            delete $ENV{CCPRAXIS_SWEEP_OWNS_AUDIT};   # tooling-fixes 10, for uniformity with run_fake_sweep above
            $ENV{HOME} = $outer_home;
            $ENV{FIXTURE_REPORT_DIR} = $report_dir;
            open(STDIN,  '<', '/dev/null');
            open(STDOUT, '>', '/dev/null');
            open(STDERR, '>', '/dev/null');
            exec($^X, $script) or POSIX::_exit(99);
        }

        my $deadline = time() + 20;
        my $home_seen;
        while (time() < $deadline) {
            $home_seen = read_report($report_dir, 'home-seen.txt');
            last if defined $home_seen && length $home_seen;
            select(undef, undef, undef, 0.2);
        }
        ok(defined $home_seen && length $home_seen,
            'm4: the interrupt-probe fixture reported a sandbox HOME before being interrupted')
            or diag('no home-seen.txt appeared within 20s');

        kill('TERM', $pid);
        reap_with_grace($pid, timeout => 15);
        kill('KILL', $pid) if pid_alive($pid);

        if (defined $home_seen && length $home_seen) {
            my $deadline2 = time() + 10;
            while (time() < $deadline2 && -e $home_seen) { select(undef, undef, undef, 0.2) }
            ok(!-e $home_seen,
                'm4: an interrupted (SIGTERM) run leaves no sandbox directory behind')
                or diag("sandbox HOME still present after interrupt: $home_seen");
        } else {
            fail('m4: an interrupted (SIGTERM) run leaves no sandbox directory behind');
        }
    }
}

done_testing();
