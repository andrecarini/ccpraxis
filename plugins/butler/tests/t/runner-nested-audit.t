#!/usr/bin/env perl
# platform: any
# Oracle for blueprint tooling-fixes, package 10 (Decision 28): a sweep
# exports a marker to its test children; a runner started under it skips its
# own repo / wake-lock / butler-state audit and prints one notice line in
# place of it, while the enclosing sweep's own audit still catches a stray
# path left anywhere inside its window, nested run included. Derived from
# .ccpraxis-local-data/blueprints/tooling-fixes/specs/
# 10-nested-runner-audit-spec.md sections 2-4 (AC1-AC16, Amendment 1).
# Nothing here reads scripts/run-tests.pl's own source for behavior; the
# marker name (CCPRAXIS_SWEEP_OWNS_AUDIT), its three-part validity check
# (equals HOME byte-exact, names an existing directory, basename has the
# sweep-template shape) and the pinned notice text are taken from the
# spec's contract sections alone.
#
# EVERYTHING RUNS AGAINST A TEMP, GIT-INIT'D FAKE REPO, NEVER THE REAL TREE.
# Every runner invocation below is a COPY of the real scripts/run-tests.pl
# (plus run-tests-container.pl and TestPlatform.pm, which it unconditionally
# requires) living under a fresh File::Temp tree, mirroring the
# build_fake_repo/run_fake_sweep pattern this blueprint's sandbox oracle
# already established -- duplicated here deliberately (this file's own
# scaffolding, not a shared import) because that pattern's subs are private
# to the file that defines them. Every spawn is bounded by a fork plus a
# polling reap-with-grace, passes an explicit throwaway HOME, and passes
# throwaway BUTLER_STATE_DIR / CCPRAXIS_CONTINUITY_ACTIVE_DIR so the
# butler-state half of any audit never touches the operator's real, live
# dirs. The marker itself is controlled explicitly per spawn (deleted, or
# set to a named value) rather than ever left to whatever this test process
# itself happens to have inherited.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Basename qw(dirname basename);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use File::Temp ();
use Cwd qw(abs_path);
use POSIX ();

use lib "$Bin/../lib";
use HostCaps ();
use RunnerStateHarness qw(repo_root reap_with_grace slurp_raw);

my $BOUND = 60;   # generous: every fixture below is tiny, but a fork+exec
                   # wave plus git init/commit both cost real wall time here.

# The sweep-shape regex, derived from the same template text the spec (2.1,
# check 3) and scripts/run-tests.pl's own $SWEEP_TEMPLATE both use
# ('ccpraxis-sweep-XXXXXX' -> prefix + 6 chars from [A-Za-z0-9_]). Restated
# here as a literal, deliberately: the oracle pins today's naming
# convention (spec section 4, "Writing the literal template ... is
# intended").
my $SWEEP_SHAPE_RX = qr/\Accpraxis-sweep-[A-Za-z0-9_]{6}\z/;

# ---------------------------------------------------------------------------
# Scaffolding (inline: this file's own write set is itself alone).
# ---------------------------------------------------------------------------

# build_fake_repo(%fixtures) -> $repo_abs
# %fixtures maps a bare basename (must end .t) to file content, written
# under $repo/plugins/x/tests/t/. Copies the real run-tests.pl and the two
# files it unconditionally `require`s, git-inits, and commits everything so
# the repo starts CLEAN -- any file appearing afterwards is genuinely new.
sub build_fake_repo {
    my (%fixtures) = @_;
    my $repo = _new_bare_repo();
    my $ttdir = repo_plugin_tests_dir($repo);
    make_path($ttdir);
    for my $name (sort keys %fixtures) {
        _write_file(File::Spec->catfile($ttdir, $name), $fixtures{$name});
    }
    _git_commit_all($repo);
    return $repo;
}

# build_fake_repo_with_files(%files) -> $repo_abs
# %files maps a repo-relative path (forward-slash, e.g.
# 'inner/tests/t/x.t') to content. Used where a fixture must live OUTSIDE
# plugins/*/tests/t/ -- a nested-run target the outer full sweep must not
# also collect directly.
sub build_fake_repo_with_files {
    my (%files) = @_;
    my $repo = _new_bare_repo();
    for my $rel (sort keys %files) {
        my @parts = split m{/}, $rel;
        my $path = File::Spec->catfile($repo, @parts);
        make_path(dirname($path));
        _write_file($path, $files{$rel});
    }
    _git_commit_all($repo);
    return $repo;
}

sub _new_bare_repo {
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
    return $repo;
}

sub _write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "cannot write fixture $path: $!";
    print {$fh} $content;
    close $fh;
}

sub _git_commit_all {
    my ($repo) = @_;
    my $gp = HostCaps::git_path($repo);
    system('git', '-C', $gp, 'init', '-q') == 0
        or die "git init failed in $repo";
    system('git', '-C', $gp, 'add', '-A') == 0
        or die "git add failed in $repo";
    system('git', '-C', $gp, '-c', 'user.email=oracle@ccpraxis.test',
           '-c', 'user.name=oracle', 'commit', '-q', '-m', 'fake repo: initial commit') == 0
        or die "git commit failed in $repo";
}

sub repo_plugin_tests_dir {
    my ($repo) = @_;
    return File::Spec->catdir($repo, qw(plugins x tests t));
}

# make_valid_marker() -> $path
# Builds a fresh, existing, sweep-shaped directory suitable for use as BOTH
# HOME and CCPRAXIS_SWEEP_OWNS_AUDIT in a spawn -- the "valid marker" the
# spec (section 3, Amendment 1) defines: same string for both, naming an
# existing directory whose basename matches $SWEEP_SHAPE_RX. A distinct
# root tempdir per call keeps two calls from ever colliding.
sub make_valid_marker {
    my $root = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    return File::Temp::tempdir('ccpraxis-sweep-XXXXXX', DIR => $root, CLEANUP => 1);
}

# run_fake_sweep(repo=>.., args=>[..], env=>{..}, marker=>.., timeout=>N)
#   -> {rc,out,err,timed_out}
# Mirrors RunnerStateHarness::run_runner_bounded, except the script path is
# the FAKE repo's own copy, env{HOME} is REQUIRED (this process's real HOME
# is never allowed to leak to the child by omission), and the marker is
# ALWAYS decided explicitly here: the child's inherited
# CCPRAXIS_SWEEP_OWNS_AUDIT is deleted first, then set to marker=>$value if
# given -- never left at whatever this test process itself was started
# with, so a sweep running THIS file cannot contaminate what "marker
# deleted" means for the fixture under test.
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
        delete $ENV{CCPRAXIS_SWEEP_OWNS_AUDIT};
        if (exists $args{marker} && defined $args{marker}) {
            $ENV{CCPRAXIS_SWEEP_OWNS_AUDIT} = $args{marker};
        }
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

sub read_report {
    my ($dir, $name) = @_;
    my $path = File::Spec->catfile($dir, $name);
    return undef unless -f $path;
    return slurp_raw($path);
}

# read_marker_reports($dir) -> list of { marker, home, tmpdir, dir_exists }
# Globs every marker-seen-<pid>.txt written by marker_report_source() under
# $dir and parses its MARKER=/HOME=/TMPDIR=/DIR_EXISTS= lines. The PID
# suffix is what lets two fixture files in one run (AC1) each leave their
# own report without colliding.
sub read_marker_reports {
    my ($dir) = @_;
    my @out;
    opendir(my $dh, $dir) or return @out;
    for my $name (sort readdir($dh)) {
        next unless $name =~ /^marker-seen-\d+\.txt\z/;
        my $content = slurp_raw(File::Spec->catfile($dir, $name));
        next unless defined $content;
        my %fields;
        for my $line (split /\n/, $content) {
            if ($line =~ /^(MARKER|HOME|TMPDIR|DIR_EXISTS)=(.*)\z/) {
                $fields{lc($1)} = $2;
            }
        }
        push @out, {
            marker     => $fields{marker},
            home       => $fields{home},
            tmpdir     => $fields{tmpdir},
            dir_exists => $fields{dir_exists},
        };
    }
    closedir $dh;
    return @out;
}

sub pid_alive {
    my ($pid) = @_;
    return 0 unless defined $pid && $pid =~ /^\d+$/;
    return kill(0, $pid) ? 1 : 0;
}

# The pinned notice (spec 2.2, Amendment 1): no longer carries "=1" -- the
# marker's value is now a live, per-child sandbox path, not a fixed literal,
# so the notice names the variable without a value.
my $NOTICE_RX = qr/^\Qaudit: skipped -- the enclosing sweep owns the repo, wake-lock and butler-state audit (CCPRAXIS_SWEEP_OWNS_AUDIT)\E$/m;

sub count_matches {
    my ($text, $rx) = @_;
    my @m = ($text =~ /$rx/g);
    return scalar @m;
}

my @KILL_ON_EXIT;
END {
    for my $pid (@KILL_ON_EXIT) {
        next unless pid_alive($pid);
        kill('KILL', $pid);
    }
}

# ---------------------------------------------------------------------------
# Fixture sources
# ---------------------------------------------------------------------------

# marker_report_source() -- reports what the fixture itself sees for
# CCPRAXIS_SWEEP_OWNS_AUDIT, HOME and TMPDIR, plus whether -d holds for the
# marker value, into a per-pid report file under FIXTURE_REPORT_DIR. Used by
# AC1, AC2 and the AC16 harvest step.
sub marker_report_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my $marker = exists $ENV{CCPRAXIS_SWEEP_OWNS_AUDIT} ? $ENV{CCPRAXIS_SWEEP_OWNS_AUDIT} : '<UNSET>';
my $home   = exists $ENV{HOME} ? $ENV{HOME} : '<UNSET>';
my $tmpdir = exists $ENV{TMPDIR} ? $ENV{TMPDIR} : '<UNSET>';
my $exists = ($marker ne '<UNSET>' && -d $marker) ? 1 : 0;
open(my $fh, '>', "$report/marker-seen-$$.txt") or die "$!";
print {$fh} "MARKER=$marker\nHOME=$home\nTMPDIR=$tmpdir\nDIR_EXISTS=$exists\n";
close $fh;
print "ok 1 - marker-report fixture ran\n";
exit 0;
SRC
}

sub green_source {
    return "#!/usr/bin/env perl\n# platform: any\nprint \"ok 1 - plain fixture pass\\n\";\nexit 0;\n";
}

sub red_source {
    return "#!/usr/bin/env perl\n# platform: any\nprint \"not ok 1 - forced failure\\n\";\nexit 1;\n";
}

sub stray_root_writer_source {
    my ($basename) = @_;
    return <<SRC;
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my \$root = \$ENV{FIXTURE_REPO_ROOT};
die "FIXTURE_REPO_ROOT not set\\n" unless defined \$root && length \$root;
open(my \$fh, '>', "\$root/$basename") or die "\$!";
print {\$fh} "stray\\n";
close \$fh;
print "ok 1 - stray-writer fixture ran\\n";
exit 0;
SRC
}

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
    open(my $fh, '>', "$dir/nested-m4-marker.txt") or die "$!";
    print {$fh} "written by nested-audit real-state fixture ($v)\n";
    close $fh;
}
print "ok 1 - real-state-writer fixture ran\n";
exit 0;
SRC
}

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

# nester_source() -- spawns the SAME fake repo's own scripts/run-tests.pl
# against <fake-repo>/inner (bounded: fork + timed waitpid + kill, never an
# unbounded wait), reports the nested run's stdout and rc into
# FIXTURE_REPORT_DIR, and exits 0 exactly when the nested run exited 0. Lives
# under plugins/x/tests/t/ (so the outer full sweep collects it); the nested
# TARGET lives under <fake-repo>/inner/tests/t/, which the outer sweep's own
# glob never reaches. Deliberately does NOT touch %ENV before the exec: HOME
# and CCPRAXIS_SWEEP_OWNS_AUDIT reach the nested runner exactly as the
# OUTER run_one() set them for this fixture process, unmutated -- this is
# what "the nested run inherits the marker through run_one()" means (AC9).
sub nester_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Cwd qw(abs_path);
use POSIX qw(WNOHANG);
my $report = $ENV{FIXTURE_REPORT_DIR};
die "FIXTURE_REPORT_DIR not set\n" unless defined $report && length $report;
my $repo_root = abs_path(File::Spec->catdir($Bin, File::Spec->updir, File::Spec->updir,
                                             File::Spec->updir, File::Spec->updir));
my $script = File::Spec->catfile($repo_root, 'scripts', 'run-tests.pl');
my $inner  = File::Spec->catdir($repo_root, 'inner');
my $out_path = "$report/nested-stdout.txt";

# NOTE: no %ENV mutation here. HOME and CCPRAXIS_SWEEP_OWNS_AUDIT pass
# through to the exec'd nested runner exactly as this process's own
# run_one() set them -- the inheritance path AC9 proves.
my $pid = fork();
die "fork failed: $!" unless defined $pid;
if ($pid == 0) {
    open(STDOUT, '>', $out_path) or POSIX::_exit(97);
    open(STDERR, '>&', \*STDOUT) or POSIX::_exit(98);
    exec($^X, $script, $inner) or POSIX::_exit(99);
}
my $deadline = time() + 40;
my $reaped = 0;
my $nested_rc;
while (time() < $deadline) {
    my $r = waitpid($pid, WNOHANG);
    if ($r == $pid) { $reaped = 1; $nested_rc = $? >> 8; last }
    select(undef, undef, undef, 0.1);
}
unless ($reaped) {
    kill('TERM', $pid);
    my $waited = 0;
    while ($waited < 2) {
        my $r = waitpid($pid, WNOHANG);
        last if $r == $pid;
        select(undef, undef, undef, 0.1);
        $waited += 0.1;
    }
    if ((waitpid($pid, WNOHANG) // 0) != $pid) {
        kill('KILL', $pid);
        waitpid($pid, 0);
    }
    $nested_rc = defined($?) ? ($? >> 8) : -1;
}
open(my $rfh, '>', "$report/nested-rc.txt") or die "$!";
print {$rfh} (defined $nested_rc ? $nested_rc : '');
close $rfh;
print "ok 1 - nester fixture ran, nested rc was " . (defined $nested_rc ? $nested_rc : 'undef') . "\n";
exit((defined($nested_rc) && $nested_rc == 0) ? 0 : 1);
SRC
}

sub inner_stray_source {
    return <<'SRC';
#!/usr/bin/env perl
# platform: any
use strict;
use warnings;
my $root = $ENV{FIXTURE_REPO_ROOT};
die "FIXTURE_REPO_ROOT not set\n" unless defined $root && length $root;
open(my $fh, '>', "$root/nested-stray.txt") or die "$!";
print {$fh} "stray from inner run\n";
close $fh;
print "ok 1 - inner-stray fixture ran\n";
exit 0;
SRC
}

# ---------------------------------------------------------------------------
# AC1 -- marker export: a fake runner spawned with the marker DELETED runs
# TWO fixture files that each report CCPRAXIS_SWEEP_OWNS_AUDIT, HOME and
# TMPDIR. Each report shows: the marker is not <UNSET>; it equals that
# child's own HOME and TMPDIR; -d held for it; its basename matches the
# sweep shape; and it is not the literal "1". The two files' reported
# values differ (each child gets its own per-file sandbox).
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo(
        'marker-report-a.t' => marker_report_source(),
        'marker-report-b.t' => marker_report_source(),
    );
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
        marker  => undef,   # explicitly deleted for the OUTER process
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC1: the outer runner itself exits 0 (no stray, nothing to audit)')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    my @reports = read_marker_reports($report_dir);
    is(scalar(@reports), 2, 'AC1: both fixture files left a report')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    for my $i (0, 1) {
        my $r = $reports[$i];
        next unless $r;
        isnt($r->{marker}, '<UNSET>', "AC1 (child $i): marker is set, not unset");
        is($r->{marker}, $r->{home}, "AC1 (child $i): marker equals the child's own HOME");
        is($r->{marker}, $r->{tmpdir}, "AC1 (child $i): marker equals the child's own TMPDIR");
        is($r->{dir_exists}, 1, "AC1 (child $i): -d held for the marker value at fixture run time");
        like(defined $r->{marker} ? basename($r->{marker}) : '', $SWEEP_SHAPE_RX,
            "AC1 (child $i): the marker's basename has the sweep-template shape");
        isnt($r->{marker}, '1', "AC1 (child $i): the marker is not the bare literal 1");
    }
    if ($reports[0] && $reports[1]) {
        isnt($reports[0]{marker}, $reports[1]{marker},
            'AC1: the two fixture files get DIFFERENT marker values (each its own sandbox)');
    } else {
        fail('AC1: need two reports to compare for distinctness');
    }
}

# ---------------------------------------------------------------------------
# AC2 -- marker export overrides the inbound value: run_one() always sets
# its OWN per-file sandbox path for a spawned child, never trusting or
# passing through whatever it inherited. Case (a): the outer process is
# spawned with CCPRAXIS_SWEEP_OWNS_AUDIT=1 (the old, now-insecure value).
# Case (b): the outer process is spawned with a valid marker (so the outer
# runner is itself "nested"). In both, the fixture child's reported marker
# equals its own HOME, has the sweep shape, and differs from the inbound
# value the outer process itself received.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('marker-report-2a.t' => marker_report_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir },
        marker  => '1',   # the OUTER process's own inbound marker: the old bare literal
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC2a: the outer runner itself exits 0')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    my @reports = read_marker_reports($report_dir);
    is(scalar(@reports), 1, 'AC2a: the fixture left a report')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    my $r = $reports[0];
    if ($r) {
        is($r->{marker}, $r->{home}, "AC2a: the child's marker equals its own HOME");
        like(defined $r->{marker} ? basename($r->{marker}) : '', $SWEEP_SHAPE_RX,
            'AC2a: the child marker has the sweep-template shape');
        is($r->{dir_exists}, 1, 'AC2a: -d held for the child marker');
        isnt($r->{marker}, '1', "AC2a: the child's marker differs from the outer's inbound literal 1");
    } else {
        fail('AC2a: no report to inspect');
    }
}
{
    my $valid_marker = make_valid_marker();
    my $repo = build_fake_repo('marker-report-2b.t' => marker_report_source());
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $valid_marker, FIXTURE_REPORT_DIR => $report_dir },
        marker  => $valid_marker,   # the OUTER process itself inherits a VALID marker
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC2b: the outer runner itself exits 0')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");

    my @reports = read_marker_reports($report_dir);
    is(scalar(@reports), 1, 'AC2b: the fixture left a report')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    my $r = $reports[0];
    if ($r) {
        is($r->{marker}, $r->{home}, "AC2b: the child's marker equals its own HOME");
        like(defined $r->{marker} ? basename($r->{marker}) : '', $SWEEP_SHAPE_RX,
            'AC2b: the child marker has the sweep-template shape');
        is($r->{dir_exists}, 1, 'AC2b: -d held for the child marker');
        isnt($r->{marker}, $valid_marker,
            "AC2b: the child's marker differs from the OUTER's own inbound marker value "
          . '(run_one() never passes through what it inherited)');
    } else {
        fail('AC2b: no report to inspect');
    }
}

# ---------------------------------------------------------------------------
# AC3 -- DC1 core: a valid marker, a green fixture creates an untracked
# "nested-stray.txt" in the fake repo root. rc == 0, the exact notice is
# printed exactly once, no AUDIT FAILED appears, and stdout never contains
# the old, insecure "CCPRAXIS_SWEEP_OWNS_AUDIT=1" form.
# ---------------------------------------------------------------------------
{
    my $valid_marker = make_valid_marker();
    my $repo = build_fake_repo('stray-writer.t' => stray_root_writer_source('nested-stray.txt'));

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $valid_marker, FIXTURE_REPO_ROOT => $repo },
        marker  => $valid_marker,
        timeout => $BOUND,
    );
    is($res->{rc}, 0,
        'AC3: marker active -- a green fixture that leaves a stray repo path still exits 0')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    is(count_matches($res->{out}, $NOTICE_RX), 1,
        'AC3: the exact notice line is printed exactly once')
        or diag("stdout:\n$res->{out}");
    unlike($res->{out}, qr/AUDIT FAILED/, 'AC3: no AUDIT FAILED appears')
        or diag("stdout:\n$res->{out}");
    unlike($res->{out}, qr/CCPRAXIS_SWEEP_OWNS_AUDIT=1/,
        'AC3: stdout never contains the old, insecure "...=1" form')
        or diag("stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC4 -- DC1, butler-state and wake-lock halves. A valid marker with a
# fixture writing into the inherited "real" butler-state dir: rc 0, notice
# present, no AUDIT FAILED. A second case leaves a keep-awake-named
# background process alive: rc 0, notice present. The leftover pid is
# killed unconditionally in the END block above.
# ---------------------------------------------------------------------------
{
    my $valid_marker = make_valid_marker();
    my $repo = build_fake_repo('real-state-writer.t' => real_state_writer_source());
    my $real_butler_state  = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $real_continuity    = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => {
            HOME                            => $valid_marker,
            BUTLER_STATE_DIR                => $real_butler_state,
            CCPRAXIS_CONTINUITY_ACTIVE_DIR  => $real_continuity,
            FIXTURE_REAL_BUTLER_STATE       => $real_butler_state,
            FIXTURE_REAL_CONTINUITY_ACTIVE  => $real_continuity,
        },
        marker  => $valid_marker,
        timeout => $BOUND,
    );
    is($res->{rc}, 0,
        'AC4 (butler-state half): marker active -- a write into the real butler-state/continuity '
      . 'dirs during the run does not fail it')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    is(count_matches($res->{out}, $NOTICE_RX), 1,
        'AC4 (butler-state half): the notice is printed exactly once')
        or diag("stdout:\n$res->{out}");
    unlike($res->{out}, qr/AUDIT FAILED/, 'AC4 (butler-state half): no AUDIT FAILED appears')
        or diag("stdout:\n$res->{out}");
}
{
    my $valid_marker = make_valid_marker();
    my $repo = build_fake_repo('leftover.t' => leftover_process_source());
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $valid_marker, FIXTURE_REPORT_DIR => $report_dir },
        marker  => $valid_marker,
        timeout => $BOUND,
    );

    my $leftover_pid = read_report($report_dir, 'leftover-pid.txt');
    if (defined $leftover_pid && $leftover_pid =~ /(\d+)/) {
        push @KILL_ON_EXIT, $1;
    }

    is($res->{rc}, 0,
        'AC4 (wake-lock half): marker active -- a surviving keep-awake-named process does not fail the run')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    is(count_matches($res->{out}, $NOTICE_RX), 1,
        'AC4 (wake-lock half): the notice is printed exactly once')
        or diag("stdout:\n$res->{out}");

    if (defined $leftover_pid && $leftover_pid =~ /^(\d+)$/) {
        kill('KILL', $1);
    }
}

# ---------------------------------------------------------------------------
# AC5 -- marker does not mask reds: a valid marker with a red fixture.
# rc != 0, RED: names the fixture, and the notice is still printed.
# ---------------------------------------------------------------------------
{
    my $valid_marker = make_valid_marker();
    my $repo = build_fake_repo('red-fixture.t' => red_source());

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $valid_marker },
        marker  => $valid_marker,
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC5: marker active -- a genuinely red fixture still fails the run')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out}, qr/RED:/, 'AC5: RED: appears')
        or diag("stdout:\n$res->{out}");
    like($res->{out}, qr/red-fixture\.t/, 'AC5: the red fixture is named')
        or diag("stdout:\n$res->{out}");
    is(count_matches($res->{out}, $NOTICE_RX), 1,
        'AC5: the notice is still printed even though the run is red')
        or diag("stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC6 -- DC2 core: same setup as AC3 with the marker DELETED. rc != 0,
# AUDIT FAILED: and "new repo path(s) appeared during this sweep (git
# status):" both appear, naming nested-stray.txt, and the notice is absent.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('stray-writer-2.t' => stray_root_writer_source('nested-stray.txt'));
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPO_ROOT => $repo },
        marker  => undef,
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC6: marker deleted -- the same stray-leaving fixture fails the run')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC6: AUDIT FAILED: appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/new repo path\(s\) appeared during this sweep \(git status\):/,
        'AC6: the git-status heading appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/, 'AC6: nested-stray.txt is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, 'AC6: the notice is absent')
        or diag("stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC7 -- DC2, inactive values: the AC6 setup with the marker set to each of
# a battery of values that must all fail the three-part check (2.1) and so
# leave the audit running. (a)-(c): plain scalar values. (d) mismatch:
# marker names a valid sweep-shaped dir that differs from HOME. (e) missing:
# marker equals HOME, sweep-shaped, but the directory has been removed. (f)
# wrong shape: marker equals HOME, exists, but is not sweep-shaped. (g)
# near-miss shape: marker equals HOME, exists, named with the real
# "ccpraxis-sweep-registry-" prefix the runner also uses elsewhere, but not
# matching the exact sweep-dir pattern. Each gives rc != 0, AUDIT FAILED:
# naming nested-stray.txt, and no notice.
# ---------------------------------------------------------------------------
for my $inactive_value ('', '0', 'true') {
    my $label = length($inactive_value) ? $inactive_value : '(empty string)';
    my $repo = build_fake_repo('stray-writer-3.t' => stray_root_writer_source('nested-stray.txt'));
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPO_ROOT => $repo },
        marker  => $inactive_value,
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, "AC7 (marker='$label'): still fails the run exactly as marker-deleted does")
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, "AC7 (marker='$label'): AUDIT FAILED: appears")
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/, "AC7 (marker='$label'): nested-stray.txt is named")
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, "AC7 (marker='$label'): no notice")
        or diag("stdout:\n$res->{out}");
}
{
    # (d) mismatch: marker names a DIFFERENT valid sweep-shaped dir than HOME.
    my $marker_dir = make_valid_marker();
    my $home_dir   = make_valid_marker();
    my $repo = build_fake_repo('stray-writer-3d.t' => stray_root_writer_source('nested-stray.txt'));

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $home_dir, FIXTURE_REPO_ROOT => $repo },
        marker  => $marker_dir,
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC7 (mismatch): marker != HOME -- still fails the run')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC7 (mismatch): AUDIT FAILED: appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/, 'AC7 (mismatch): nested-stray.txt is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, 'AC7 (mismatch): no notice')
        or diag("stdout:\n$res->{out}");
}
{
    # (e) missing: marker == HOME, sweep-shaped, but the dir has been removed.
    my $root = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $gone = File::Temp::tempdir('ccpraxis-sweep-XXXXXX', DIR => $root, CLEANUP => 1);
    rmdir($gone) or die "AC7(e) setup: cannot rmdir $gone: $!";
    my $repo = build_fake_repo('stray-writer-3e.t' => stray_root_writer_source('nested-stray.txt'));

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $gone, FIXTURE_REPO_ROOT => $repo },
        marker  => $gone,
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC7 (missing-dir): marker == HOME but the dir no longer exists -- still fails')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC7 (missing-dir): AUDIT FAILED: appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/, 'AC7 (missing-dir): nested-stray.txt is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, 'AC7 (missing-dir): no notice')
        or diag("stdout:\n$res->{out}");
}
{
    # (f) wrong shape: marker == HOME, exists, but basename isn't sweep-shaped.
    my $root = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $wrong = File::Temp::tempdir('not-a-sweep-XXXXXX', DIR => $root, CLEANUP => 1);
    my $repo = build_fake_repo('stray-writer-3f.t' => stray_root_writer_source('nested-stray.txt'));

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $wrong, FIXTURE_REPO_ROOT => $repo },
        marker  => $wrong,
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC7 (wrong-shape): marker == HOME, exists, but basename is not sweep-shaped -- still fails')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC7 (wrong-shape): AUDIT FAILED: appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/, 'AC7 (wrong-shape): nested-stray.txt is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, 'AC7 (wrong-shape): no notice')
        or diag("stdout:\n$res->{out}");
}
{
    # (g) near-miss shape: the real "ccpraxis-sweep-registry-" prefix the
    # runner also uses, but not matching the exact sweep-dir pattern.
    my $root = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $nearmiss = File::Temp::tempdir('ccpraxis-sweep-registry-XXXXXX', DIR => $root, CLEANUP => 1);
    my $repo = build_fake_repo('stray-writer-3g.t' => stray_root_writer_source('nested-stray.txt'));

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $nearmiss, FIXTURE_REPO_ROOT => $repo },
        marker  => $nearmiss,
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC7 (near-miss shape): a registry-prefixed name is not a sweep-dir match -- still fails')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC7 (near-miss shape): AUDIT FAILED: appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/, 'AC7 (near-miss shape): nested-stray.txt is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, 'AC7 (near-miss shape): no notice')
        or diag("stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC8 -- DC2, control: marker deleted, a green fixture with no side effects.
# rc == 0, "all green", no AUDIT FAILED, no notice. Proves AC6's failure is
# caused by the stray, not by something else this harness does.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('plain-pass.t' => green_source());
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home },
        marker  => undef,
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC8: marker deleted, no side effects -- the run stays green')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out}, qr/all green/, 'AC8: "all green" is reported')
        or diag("stdout:\n$res->{out}");
    unlike($res->{out} . $res->{err}, qr/AUDIT FAILED/, 'AC8: no AUDIT FAILED')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, 'AC8: no notice (nothing to skip -- the audit simply passed)')
        or diag("stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC9 -- DC3 core: the fake repo holds plugins/x/tests/t/nester.t (which
# bounded-spawns the SAME repo's own run-tests.pl against ./inner) and
# inner/tests/t/inner-stray.t (which leaves a stray file in the repo root and
# exits 0). The OUTER runner is spawned with the marker DELETED and no
# target (a full sweep). nester.t itself does not touch HOME or
# CCPRAXIS_SWEEP_OWNS_AUDIT (see nester_source()'s own comment) -- it leaves
# them exactly as the OUTER run_one() set them for this fixture process, so
# the nested runner inherits a genuine, valid, run_one()-issued marker, not
# anything this test constructed by hand. The nested run exits 0 with the
# notice; the outer run still fails the audit, naming the stray the nested
# run's own fixture left behind, and the failure is NOT attributed to
# nester.t itself going red. This is also the end-to-end proof that a real
# run_one()-issued marker passes the 2.1 three-part check.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo_with_files(
        'plugins/x/tests/t/nester.t' => nester_source(),
        'inner/tests/t/inner-stray.t' => inner_stray_source(),
    );
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPORT_DIR => $report_dir, FIXTURE_REPO_ROOT => $repo },
        marker  => undef,
        timeout => $BOUND,
    );

    my $nested_rc  = read_report($report_dir, 'nested-rc.txt');
    my $nested_out = read_report($report_dir, 'nested-stdout.txt');

    is($nested_rc, '0',
        'AC9: the NESTED run (marker inherited active, unmutated by nester.t) exits 0 despite the '
      . "stray its own fixture left")
        or diag('nested stdout: ' . (defined $nested_out ? $nested_out : '<missing>'));
    ok(defined $nested_out && count_matches($nested_out, $NOTICE_RX) == 1,
        'AC9: the NESTED run printed the notice exactly once')
        or diag('nested stdout: ' . (defined $nested_out ? $nested_out : '<missing>'));

    isnt($res->{rc}, 0,
        'AC9: the OUTER run (marker absent for it) still fails even though the nested run reported 0')
        or diag("outer stdout:\n$res->{out}\nouter stderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC9: the OUTER run reports AUDIT FAILED:')
        or diag("outer stdout:\n$res->{out}\nouter stderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/,
        'AC9: the OUTER audit names the stray the NESTED fixture left behind')
        or diag("outer stdout:\n$res->{out}\nouter stderr:\n$res->{err}");
    unlike($res->{out}, qr/RED:[^\n]*nester\.t/,
        'AC9: nester.t itself is NOT listed under RED: -- the outer failure comes from the audit alone')
        or diag("outer stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC10 -- DC3, non-nested half: the outer run with the marker deleted, on a
# fixture that directly creates a stray in the fake repo root, fails with
# AUDIT FAILED: naming it -- proving "any test, nested or not" in this same
# file.
# ---------------------------------------------------------------------------
{
    my $repo = build_fake_repo('direct-stray-writer.t' => stray_root_writer_source('direct-stray-marker.txt'));
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPO_ROOT => $repo },
        marker  => undef,
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC10: a direct (non-nested) stray still fails the outer run')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC10: AUDIT FAILED: appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/direct-stray-marker\.txt/, 'AC10: the stray is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
}

# ---------------------------------------------------------------------------
# AC11 -- B7 early exit: a valid marker, --state=failed with
# CCPRAXIS_TEST_STATE_DIR pointing at an empty temp dir. Stdout is exactly
# the short-circuit message, rc == 0, and no notice is printed (the
# post-audit position is never reached on this path).
# ---------------------------------------------------------------------------
{
    my $valid_marker = make_valid_marker();
    my $repo = build_fake_repo('unused.t' => green_source());
    my $state_dir  = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => ['--state=failed'],
        env     => { HOME => $valid_marker, CCPRAXIS_TEST_STATE_DIR => $state_dir },
        marker  => $valid_marker,
        timeout => $BOUND,
    );
    is($res->{rc}, 0, 'AC11: --state=failed with nothing recorded exits 0')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    is($res->{out}, "no recorded failures -- nothing to run\n",
        'AC11: stdout is exactly the short-circuit message, byte-for-byte')
        or diag("stdout:\n$res->{out}");
    unlike($res->{out}, $NOTICE_RX,
        'AC11: no notice -- this early-exit path never reaches the post-audit position')
        or diag("stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC15 -- the old bypass is closed (red-team MEDIUM-1, Amendment 1): a bare
# CCPRAXIS_SWEEP_OWNS_AUDIT=1 (the OLD, now-insecure value) no longer skips
# the audit, whether or not HOME happens to look sweep-shaped.
# ---------------------------------------------------------------------------
{
    # (a) HOME is itself sweep-shaped -- only the bare "1" marker is wrong.
    my $sweep_shaped_home = make_valid_marker();
    my $repo = build_fake_repo('stray-writer-15a.t' => stray_root_writer_source('nested-stray.txt'));

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $sweep_shaped_home, FIXTURE_REPO_ROOT => $repo },
        marker  => '1',
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC15a: bare marker=1 with a sweep-shaped HOME still fails the run')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC15a: AUDIT FAILED: appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/, 'AC15a: nested-stray.txt is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, 'AC15a: no notice')
        or diag("stdout:\n$res->{out}");
    unlike($res->{out}, qr/\Qaudit: skipped\E/, 'AC15a: no "audit: skipped" text appears at all')
        or diag("stdout:\n$res->{out}");
}
{
    # (b) HOME is an ordinary, non-sweep-shaped throwaway dir, the way an
    # operator's shell would actually look.
    my $outer_home = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $repo = build_fake_repo('stray-writer-15b.t' => stray_root_writer_source('nested-stray.txt'));

    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $outer_home, FIXTURE_REPO_ROOT => $repo },
        marker  => '1',
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC15b: bare marker=1 with an ordinary HOME still fails the run')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC15b: AUDIT FAILED: appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/, 'AC15b: nested-stray.txt is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, 'AC15b: no notice')
        or diag("stdout:\n$res->{out}");
}

# ---------------------------------------------------------------------------
# AC16 -- stale marker (closes red-team LOW-3, Amendment 1): a sandbox path
# that a real run_one() issued for a prior child -- matching HOME,
# sweep-shaped -- but since removed (the normal cleanup after that child
# exited) does not bypass the audit. The stale value is harvested the same
# way AC1 does: a one-file fake sweep reports what run_one() assigned it,
# and that sandbox is then confirmed gone (run_one() removes it after the
# child exits, since --keep-sandbox is never passed here).
# ---------------------------------------------------------------------------
{
    my $repo_a = build_fake_repo('marker-report-16.t' => marker_report_source());
    my $outer_home_a = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
    my $report_dir_a = File::Temp::tempdir(HostCaps::tempdir_args(), CLEANUP => 1);

    my $res_a = run_fake_sweep(
        repo    => $repo_a,
        args    => [],
        env     => { HOME => $outer_home_a, FIXTURE_REPORT_DIR => $report_dir_a },
        marker  => undef,
        timeout => $BOUND,
    );
    is($res_a->{rc}, 0, 'AC16 setup: the one-file fake sweep used to harvest a stale marker exits 0')
        or diag("stdout:\n$res_a->{out}\nstderr:\n$res_a->{err}");

    my @reports = read_marker_reports($report_dir_a);
    is(scalar(@reports), 1, 'AC16 setup: exactly one report was harvested')
        or diag("stdout:\n$res_a->{out}\nstderr:\n$res_a->{err}");
    my $stale_marker = $reports[0] ? $reports[0]{marker} : undef;
    ok(defined $stale_marker && length $stale_marker, 'AC16 setup: a marker value was harvested')
        or diag('harvested: ' . (defined $stale_marker ? $stale_marker : '<undef>'));
    ok(defined $stale_marker && !-d $stale_marker,
        'AC16 setup: the harvested sandbox no longer exists (run_one() cleaned it up after the child exited)')
        or diag('harvested marker still exists on disk: ' . (defined $stale_marker ? $stale_marker : '<undef>'));

    my $repo = build_fake_repo('stray-writer-16.t' => stray_root_writer_source('nested-stray.txt'));
    my $res = run_fake_sweep(
        repo    => $repo,
        args    => [],
        env     => { HOME => $stale_marker, FIXTURE_REPO_ROOT => $repo },
        marker  => $stale_marker,
        timeout => $BOUND,
    );
    isnt($res->{rc}, 0, 'AC16: a marker naming a since-removed sandbox does not bypass the audit')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/AUDIT FAILED:/, 'AC16: AUDIT FAILED: appears')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    like($res->{out} . $res->{err}, qr/nested-stray\.txt/, 'AC16: nested-stray.txt is named')
        or diag("stdout:\n$res->{out}\nstderr:\n$res->{err}");
    unlike($res->{out}, $NOTICE_RX, 'AC16: no notice')
        or diag("stdout:\n$res->{out}");
}

done_testing();
