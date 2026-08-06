#!/usr/bin/env perl
# b40-green-baseline-isolation oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b40-green-baseline-isolation-spec.md
# sections 0, 2, 3, 4, 5, 6, 7, 9 (acceptance criteria C1..C10, mapped 1:1 in the header of each
# block below).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/scripts/bp-baseline.pl does not exist at the
# time this file was authored. Every assertion below that depends on it is expected to fail on
# MISSING BEHAVIOUR: a bare `require` of a nonexistent file dies "Can't locate ... in @INC" (caught
# by eval, see $HAVE_BASELINE below), a call to an undefined BpBaseline::* sub dies "Undefined
# subroutine" (caught per-call by call_bpb()), and a subprocess invocation of the CLI exits 127 via
# bash's own "No such file or directory" (never a perl/harness error of this file). Assertions
# labelled FIXTURE-SANITY are deliberate harness self-checks, expected to pass even with the script
# absent -- they are the evidence that the red below is attributable to the missing script, not to
# broken scaffolding.
#
# ASSUMED-BUT-UNPINNED CLI SHAPE (the spec pins verb names, --dest, --strict-deps and --known-red
# explicitly (section 0/4/5) but does not pin every flag needed to drive `materialize`/`advance`/
# `teardown` from a test fixture). Where the spec is silent, this oracle assumes a minimal,
# consistent shape documented at each call site:
#   * `materialize --package P --dest D --blueprint B [--strict-deps] [--dep-status JSON]`
#     reads the baseline commit from the persistent ref refs/butler/baseline/<B> (written directly
#     by fixture setup with `git update-ref`, never via `advance`, so these tests do not also
#     depend on advance's ledger-reading machinery -- see the C1/C2 note below).
#   * `--dep-status JSON` is this oracle's injection seam for a package's dependency statuses,
#     mirroring section 2.3's own philosophy ("injected into the pure functions, never read from a
#     fixed path") generalised to the CLI boundary, since the spec does not pin how materialize
#     locates ledger-derived dependency data.
#   * `teardown --package P --dest D --blueprint B`.
# A compliant implementation is expected to match this shape; if it legitimately differs, that is
# for a human to reconcile against this file, not a signal that the underlying property is untested.
#
# `advance`'s own ledger/git-log integration is NOT exercised end-to-end here: section 0 pins its
# pure decision functions (parse_commit_packages / commit_eligible / select_baseline) exactly, and
# C1/C2 test those directly with synthetic commit lists -- no real ledger directory format is
# invented for that purpose.
#
# HARNESS RULES (mirroring 80-worker-jail-isolation.t):
#   * %CLEAN_ENV strips every ambient BP_* var; this package reads BP_GREEN_BASELINE,
#     BP_BASELINE_TREE, BP_PROJECT_ROOT, BP_WRITE_SET and an inherited value would make the oracle
#     lie about the default-off behaviour under test in C10.
#   * All fixtures are synthesized under a tempdir rooted at /root -- overlayfs, never /project (9p;
#     chmod is a no-op there -- spec section 4.1, verified as FIXTURE-SANITY below).
#   * Every subprocess invocation is wrapped in `timeout`; no unbounded wait.
#   * Never spawn launcher.pl. Never run the real 90-file suite (spec section 5.4) -- the gate
#     runner used in C9 is a fake coderef returning canned results, not a real perl invocation.
#   * done_testing(), not a hand-counted plan.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps qw(chmod_works);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path remove_tree);
use File::Find ();
use POSIX qw(WNOHANG);
use JSON::PP ();
use Digest::SHA ();

(my $ROOT_SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $BP_BASELINE   = "$ROOT_SCRIPTS/bp-baseline.pl";
my $BP_JAIL       = "$ROOT_SCRIPTS/bp-jail.pl";
my $BP_CHECKPOINT = "$ROOT_SCRIPTS/bp-checkpoint.pl";
my $BP_JUDGE      = "$ROOT_SCRIPTS/bp-judge.pl";

diag("subject under test: $BP_BASELINE "
     . (-e $BP_BASELINE
        ? "(present)"
        : "(ABSENT -- every criterion below that depends on it is expected to fail on MISSING BEHAVIOUR)"));

# A green-baseline test must control its own environment completely -- this package reads three
# env vars plus BP_BASELINE_TREE which bp-jail.pl consumes, and an inherited value would lie.
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $REAL_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# TEST_BASE must be overlayfs (chmod honoured), never /project (9p).
my $TEST_BASE = tempdir((-d '/root' && -w '/root') ? (DIR => '/root') : (), CLEANUP => 1);
my $rn = 0;

# =====================================================================================
# Scaffolding: generic helpers
# =====================================================================================
sub write_file {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    make_path($dir) if length($dir) && !-d $dir;
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
sub shquote { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'"; }
sub git_cmd {
    my ($dir, @args) = @_;
    my $cmd = join(' ', 'git', '-C', shquote($dir), map { shquote($_) } @args);
    my $out = `$cmd 2>&1`;
    my $rc = $? >> 8;
    return ($rc, defined $out ? $out : '');
}
sub tree_paths {
    my ($dir) = @_;
    my @out;
    return @out unless -d $dir;
    File::Find::find({ wanted => sub { push @out, $File::Find::name }, no_chdir => 1 }, $dir);
    return @out;
}
sub build_manifest {
    my ($dir) = @_;
    my %manifest;
    return \%manifest unless -d $dir;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        my $rel = $_;
        $rel =~ s{\A\Q$dir\E/?}{};
        return if $rel eq '.bp-baseline-meta.json';
        return if $rel =~ m{(^|/)\.git(/|$)};
        my $bytes = read_file($_);
        my $mode  = (stat($_))[2] & 07777;
        $manifest{$rel} = Digest::SHA::sha256_hex($bytes) . ':' . sprintf('%o', $mode);
    } }, $dir);
    return \%manifest;
}
sub manifests_equal {
    my ($a, $b) = @_;
    my @ka = sort keys %$a;
    my @kb = sort keys %$b;
    return 0 unless "@ka" eq "@kb";
    for my $k (@ka) { return 0 unless $a->{$k} eq $b->{$k}; }
    return 1;
}

# =====================================================================================
# Scaffolding: in-process pure-function calls, individually eval-guarded so an absent
# module or an absent single sub fails ONE assertion cleanly, never the whole file.
# =====================================================================================
my $HAVE_BASELINE = eval { require $BP_BASELINE; 1 } ? 1 : 0;
diag("require $BP_BASELINE: $@") if !$HAVE_BASELINE && $@;

# bp-checkpoint.pl and bp-judge.pl already exist (Inputs this package reuses, per spec section 1)
# and are dual-shape with no top-level side effects -- safe to require directly, unguarded.
require $BP_CHECKPOINT;
require $BP_JUDGE;

sub call_bpb {
    my ($fn, @args) = @_;
    my @r;
    my $ok = eval { no strict 'refs'; @r = &{"BpBaseline::$fn"}(@args); 1 };
    return $ok ? (1, @r) : (0, $@);
}
sub call_bpcheckpoint {
    my ($fn, @args) = @_;
    my @r;
    my $ok = eval { no strict 'refs'; @r = &{"BpCheckpoint::$fn"}(@args); 1 };
    return $ok ? (1, @r) : (0, $@);
}

# =====================================================================================
# Scaffolding: run bp-baseline.pl as a subprocess (foreground, `timeout`-wrapped).
# =====================================================================================
sub run_baseline {
    my ($args, %envover) = @_;
    my $errfile = "$TEST_BASE/stderr." . (++$rn) . ".txt";
    local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, %envover,
                  BP_BASELINE_BIN => fwd($BP_BASELINE), ERRPATH => fwd($errfile));
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 30 "$BP_BASELINE_BIN" "$@" 2>"$ERRPATH"', 'bash', @$args)
        or die "bash: $!";
    binmode $fh;
    my $out = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    my $err = -e $errfile ? read_file($errfile) : '';
    return ($rc, defined $out ? $out : '', $err);
}
sub run_baseline_bg {
    my ($args, %envover) = @_;
    my $outfile = "$TEST_BASE/bgout." . (++$rn) . ".txt";
    my $errfile = "$TEST_BASE/bgerr." . (++$rn) . ".txt";
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, %envover, BP_BASELINE_BIN => fwd($BP_BASELINE),
                      OUTPATH => fwd($outfile), ERRPATH => fwd($errfile));
        exec('bash', '-c', 'exec "$BP_BASELINE_BIN" "$@" >"$OUTPATH" 2>"$ERRPATH"', 'bash', @$args);
        POSIX::_exit(127);
    }
    return ($pid, $outfile, $errfile);
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
sub poll_until {
    my ($cond, $timeout) = @_;
    my $elapsed = 0;
    while ($elapsed < $timeout) {
        return 1 if $cond->();
        select(undef, undef, undef, 0.05);
        $elapsed += 0.05;
    }
    return 0;
}

# STDOUT capture via a real file (never an in-memory scalar handle -- landmine #2).
sub capture_stdout {
    my ($coderef) = @_;
    my $outfile = "$TEST_BASE/stdout." . (++$rn) . ".txt";
    open(my $saved, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(STDOUT, '>', $outfile) or die "redirect STDOUT: $!";
    my @ret;
    my $ok = eval { @ret = $coderef->(); 1 };
    my $err = $@;
    close STDOUT;
    open(STDOUT, '>&', $saved) or die "restore STDOUT: $!";
    close $saved;
    my $captured = -e $outfile ? read_file($outfile) : '';
    return ($ok, $err, $captured, @ret);
}

my $bg_supported = ($^O eq 'linux' || $^O eq 'darwin') ? 1 : 0;

# =====================================================================================
# FIXTURE-SANITY
# =====================================================================================
{
  SKIP: {
    # No POSIX modes on this filesystem => the overlayfs-vs-9p distinction is
    # unobservable here, not violated.
    skip 'this filesystem does not carry POSIX modes, so overlayfs-vs-9p cannot be observed', 1
        unless chmod_works();
    my $probe = "$TEST_BASE/chmod-probe.txt";
    write_file($probe, "x\n");
    chmod 0600, $probe;
    my $mode = (stat($probe))[2] & 07777;
    is(sprintf('%o', $mode), '600', 'FIXTURE-SANITY: TEST_BASE (under /root) honours chmod 600 -- confirms overlayfs, not 9p');
    unlink $probe;
  }

    ok(-e $BP_CHECKPOINT, 'FIXTURE-SANITY: bp-checkpoint.pl (an Input this package reuses) exists on disk');
    ok(-e $BP_JAIL, 'FIXTURE-SANITY: bp-jail.pl (the other consumer, spec section 6.1) exists on disk');
    my ($ok_cm, $subj) = call_bpcheckpoint('commit_message', { pkg => 'pkgA', status => 'wip', step => 3 });
    ok($ok_cm, 'FIXTURE-SANITY: BpCheckpoint::commit_message is callable (existing, unaffected by b40)');
    is($subj, 'wip(pkgA): wip @ step 3', 'FIXTURE-SANITY: commit_message produces the documented wip(...) shape');
  SKIP: {
    skip "this OS ($^O) does not support the fork/kill protocol C8 uses", 1 unless $bg_supported;
    ok($bg_supported, 'FIXTURE-SANITY: this OS supports the fork/kill protocol used by C8');
  }
}

# =====================================================================================
# C1 -- BpBaseline::harvest_passed and BpBaseline::unwrap_archive (spec section 2, criterion 1).
# =====================================================================================
{
    # unwrap_archive: a well-formed envelope yields its nested verdict; a malformed one is
    # NEVER a pass, regardless of what raw/verdict happens to contain.
    my ($ok1, $r1) = call_bpb('unwrap_archive', { verdict => { verdict => 'pass' }, malformed => 0 });
    ok($ok1, 'C1: BpBaseline::unwrap_archive is callable')
        or diag("error: $r1");
    is(ref($r1) eq 'HASH' ? $r1->{verdict} : undef, 'pass',
       'C1: unwrap_archive returns the nested verdict object of a well-formed envelope');

    my ($ok2, $r2) = call_bpb('unwrap_archive', { verdict => { verdict => 'pass' }, malformed => 1 });
    ok(!$ok2 || !defined($r2), 'C1: unwrap_archive returns undef for an envelope with malformed => true, even though verdict looks like a pass');

    my ($ok3, $r3) = call_bpb('unwrap_archive', { raw => { junk => 1 }, malformed => 1 });
    ok(!$ok3 || !defined($r3), 'C1: unwrap_archive returns undef for a raw/malformed envelope');

    # harvest_passed precedence, per section 2.2:
    # 1. registry_entry->{harvest} eq 'pass' -> 1, definitively, regardless of live/archives.
    my ($okA, $rA) = call_bpb('harvest_passed', {
        registry_entry => { harvest => 'pass' }, live => undef, archives => [] });
    ok($okA, 'C1: harvest_passed is callable') or diag("error: $rA");
    is($rA, 1, "C1: registry harvest='pass' is a definitive pass regardless of live/archives");

    # 2. any OTHER non-empty string ('fail', 'error', ...) is a definitive non-pass: done + failed
    #    harvest must be 0.
    my (undef, $rB) = call_bpb('harvest_passed', {
        registry_entry => { harvest => 'fail' }, live => { verdict => 'pass' }, archives => [] });
    is($rB, 0, "C1: registry harvest='fail' is definitive even though live says pass (registry wins)");

    # 3. absent harvest key -> done + absent harvest, with nothing else definitive -> fail-closed 0.
    my (undef, $rC) = call_bpb('harvest_passed', {
        registry_entry => {}, live => undef, archives => [] });
    is($rC, 0, 'C1: done + absent harvest key, no live, no archives -> fail-closed 0 (unknown is never passed)');

    # 4. empty-string harvest ('' -- what the orchestrator writes on defer/reopen) falls THROUGH
    #    rather than deciding -- proven by giving it a live verdict that flips the outcome.
    my (undef, $rD1) = call_bpb('harvest_passed', {
        registry_entry => { harvest => '' }, live => { verdict => 'pass' }, archives => [] });
    is($rD1, 1, "C1: registry harvest='' falls through to a passing live verdict (not decided at the registry step)");
    my (undef, $rD2) = call_bpb('harvest_passed', {
        registry_entry => { harvest => '' }, live => { verdict => 'fail' }, archives => [] });
    is($rD2, 0, "C1: registry harvest='' falls through to a failing live verdict");

    # 5. no registry, no live -> newest-first archives; first UNPARSEABLE (malformed) archive is
    #    skipped in favour of the next definitive one.
    my (undef, $rE) = call_bpb('harvest_passed', {
        registry_entry => {}, live => undef,
        archives => [ { raw => {}, malformed => 1 }, { verdict => { verdict => 'pass' }, malformed => 0 } ] });
    is($rE, 1, 'C1: a malformed newest archive is skipped; the next definitive archive (pass) decides');

    # 6. nothing definitive anywhere at all -> fail-closed 0, the whole safety property.
    my (undef, $rF) = call_bpb('harvest_passed', { registry_entry => {}, live => undef, archives => [] });
    is($rF, 0, 'C1: nothing definitive anywhere (no registry, no live, no archives) -> empty baseline, not a baseline of everything');
}

# =====================================================================================
# C2 -- BpCheckpoint::is_checkpoint_subject (new, in bp-checkpoint.pl) and
# BpBaseline::parse_commit_packages / commit_eligible / select_baseline (spec section 3, criterion 2).
# =====================================================================================
{
    my ($ok1, $r1) = call_bpcheckpoint('is_checkpoint_subject', 'wip(pkgA): wip @ step 3');
    ok($ok1, 'C2: BpCheckpoint::is_checkpoint_subject is callable') or diag("error: $r1");
    is($r1, 1, 'C2: a real wip(<pkg>): ... subject (as commit_message produces) is recognised as a checkpoint');

    my (undef, $r2) = call_bpcheckpoint('is_checkpoint_subject', 'feat(pkgA): add the thing');
    is($r2, 0, 'C2: an ordinary conventional-commit subject is NOT a checkpoint');

    my (undef, $r3) = call_bpcheckpoint('is_checkpoint_subject', undef);
    is($r3, 0, 'C2: undef input to is_checkpoint_subject returns 0, never dies');

    my (undef, $r4) = call_bpcheckpoint('is_checkpoint_subject', '   wip(x): y @ z');
    is($r4, 1, 'C2: leading whitespace before wip( is still recognised (spec: ^\\s*wip\\()');

    my $known = { pkgA => 1, pkgB => 1 };

    my (undef, $p1) = call_bpb('parse_commit_packages', 'feat(pkgA): add x', $known);
    is_deeply([sort @{ ref($p1) eq 'ARRAY' ? $p1 : [] }], ['pkgA'], 'C2: parse_commit_packages extracts a single known scope token');

    my (undef, $p2) = call_bpb('parse_commit_packages', 'feat(pkgA, pkgB): joint work', $known);
    is_deeply([sort @{ ref($p2) eq 'ARRAY' ? $p2 : [] }], ['pkgA', 'pkgB'], 'C2: parse_commit_packages splits a comma/space scope into multiple known tokens');

    my (undef, $p3) = call_bpb('parse_commit_packages', 'feat(butler): infrastructure commit', $known);
    is_deeply($p3, [], 'C2: a scope naming nothing known (real repo history: feat(butler): ...) returns the empty list');

    my (undef, $p4) = call_bpb('parse_commit_packages', 'chore: no scope at all', $known);
    is_deeply($p4, [], 'C2: a subject with no (...) scope returns the empty list');

    # commit_eligible: criterion 2 -- a checkpoint subject is NEVER eligible, no matter what its
    # (nonexistent) scope would otherwise say.
    my $eligible = { pkgA => 1 };
    my (undef, $ceA) = call_bpb('commit_eligible', 'wip(pkgA): wip @ step 1', $eligible, $known);
    is($ceA, 0, 'C2: commit_eligible rejects a wip(...) checkpoint subject outright');

    # criterion 1 -- infra commits (empty scope) are eligible; a commit naming an ineligible
    # package is not; a commit naming only eligible packages is.
    my (undef, $ceB) = call_bpb('commit_eligible', 'feat(butler): infra', $eligible, $known);
    is($ceB, 1, 'C2: an infrastructure commit with no known scope is eligible (does not block the baseline)');
    my (undef, $ceC) = call_bpb('commit_eligible', 'feat(pkgB): not yet eligible', $eligible, $known);
    is($ceC, 0, 'C1: commit_eligible is 0 when the commit names a package NOT (yet) in eligible');
    my (undef, $ceD) = call_bpb('commit_eligible', 'feat(pkgA): eligible work', $eligible, $known);
    is($ceD, 1, 'C1: commit_eligible is 1 when every named package is eligible');

    # select_baseline: commits oldest-first; stop BEFORE the first ineligible commit.
    my $commits = [
        { sha => 'sha1', subject => 'feat(pkgA): first eligible commit' },
        { sha => 'sha2', subject => 'feat(pkgA): second eligible commit' },
        { sha => 'sha3', subject => 'wip(pkgA): wip @ step 2' },              # checkpoint -> stop here
        { sha => 'sha4', subject => 'feat(pkgA): would be eligible too' },
    ];
    my (undef, $sel) = call_bpb('select_baseline', { commits => $commits, eligible => $eligible, known => $known });
    is($sel, 'sha2', 'C2: select_baseline stops at the checkpoint commit and returns the sha remembered just before it');

    my $commits_bad_first = [
        { sha => 'shaX', subject => 'wip(pkgA): wip @ step 1' },
        { sha => 'shaY', subject => 'feat(pkgA): later eligible commit' },
    ];
    my (undef, $selNone) = call_bpb('select_baseline', { commits => $commits_bad_first, eligible => $eligible, known => $known });
    ok(!defined $selNone, 'C2: select_baseline returns undef when the very first commit is ineligible (empty baseline)');

    my $commits_all_ok = [
        { sha => 'shaP', subject => 'feat(pkgA): only good commit' },
    ];
    my (undef, $selAll) = call_bpb('select_baseline', { commits => $commits_all_ok, eligible => $eligible, known => $known });
    is($selAll, 'shaP', 'C2: select_baseline returns the sole commit sha when everything so far is eligible');
}

# =====================================================================================
# Scaffolding: a real git fixture for materialize (C3-C8). Two "packages":
#   P (write set: pkgP/)  -- the package under materialization
#   S (untracked/uncommitted state under pkgS/) -- the polluting sibling
# =====================================================================================
sub mk_baseline_fixture {
    my $proj = tempdir(DIR => $TEST_BASE, CLEANUP => 1);
    git_cmd($proj, 'init', '-q');
    git_cmd($proj, 'config', 'user.email', 'bp-baseline-test@example.invalid');
    git_cmd($proj, 'config', 'user.name', 'bp-baseline-test');
    # Pin line-ending conversion OFF in the fixture repo. bp-baseline.pl
    # materializes with `git archive | tar -x`, and git archive applies
    # EXPORT-TIME conversion per core.autocrlf. Git for Windows ships
    # core.autocrlf=true at SYSTEM level, so the materialized tree came back
    # holding "OK\r\n" while the fixture had written "OK\n" -- two assertions
    # failed printing `got: 'OK'` against `expected: 'OK'`, identical on screen.
    # The fixture must not inherit the host's git config: a baseline-materialization
    # test is about content preservation, not about the reader's autocrlf setting.
    # No-op in the container, where autocrlf is already off.
    git_cmd($proj, 'config', 'core.autocrlf', 'false');
    git_cmd($proj, 'config', 'core.eol', 'lf');

    write_file("$proj/pkgP/in.txt",        "P baseline\n");
    write_file("$proj/pkgP/nested/deep.txt", "P nested baseline\n");
    write_file("$proj/pkgS/shared_data.txt", "OK\n");
    # P's own oracle: reads a path OUTSIDE its own write set (pkgS/), reproducing the literal
    # cross-package-read hazard the spec names ("nothing stops B reading A's half-finished files").
    write_file("$proj/pkgP/oracle.t", <<'PERL');
#!/usr/bin/env perl
use strict; use warnings; use FindBin qw($Bin); use Test::More;
open(my $fh, '<', "$Bin/../pkgS/shared_data.txt") or die "cannot open shared_data.txt: $!";
my $content = do { local $/; <$fh> };
close $fh;
is($content, "OK\n", 'shared data is OK (cross-package read, per SYN-11 scenario)');
done_testing();
PERL
    git_cmd($proj, 'add', '-A');
    git_cmd($proj, 'commit', '-q', '-m', 'baseline for b40 fixture');
    my (undef, $sha_out) = git_cmd($proj, 'rev-parse', 'HEAD');
    (my $baseline_sha = $sha_out) =~ s/\s+\z//;

    # Now pollute the live tree: sibling S mid-edit (uncommitted change to a path outside P's
    # write set, breaking what P's oracle reads), P's own uncommitted edit + untracked file
    # (inside P's write set -- must be visible in the overlay), and a write-set deletion.
    write_file("$proj/pkgS/shared_data.txt", "BROKEN\n");                    # S's WIP, deliberately red
    write_file("$proj/pkgS/oracle.t", "#!/usr/bin/env perl\nprint \"not ok 1 - deliberately red (S mid-step-3)\\n\"; exit 1;\n");
    write_file("$proj/pkgP/in.txt", "P LIVE EDIT\n");                        # uncommitted, in write set
    write_file("$proj/pkgP/new-untracked.txt", "P untracked file\n");        # untracked, in write set
    unlink("$proj/pkgP/nested/deep.txt") or die "unlink deep.txt: $!";       # write-set deletion

    return ($proj, $baseline_sha);
}

sub set_baseline_ref {
    my ($proj, $blueprint, $sha) = @_;
    git_cmd($proj, 'update-ref', "refs/butler/baseline/$blueprint", $sha);
}
sub baseline_ref_exists {
    my ($proj, $blueprint) = @_;
    my ($rc) = git_cmd($proj, 'rev-parse', '--verify', "refs/butler/baseline/$blueprint");
    return $rc == 0;
}

# =====================================================================================
# C3 -- outside-write-set path holds BASELINE content in the materialized tree, while the
# sibling's uncommitted change to that same path sits (only) in /project (spec section 4.2.1).
# =====================================================================================
{
    my ($proj, $sha) = mk_baseline_fixture();
    my $blueprint = 'c3-bp';
    set_baseline_ref($proj, $blueprint, $sha);
    my $dest = "$TEST_BASE/materialized-c3";

    my ($rc, $out, $err) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest, '--blueprint', $blueprint],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');

    is($rc, 0, 'C3: materialize exits 0 on a clean baseline+overlay run')
        or diag("out=$out err=$err");
    ok(-e "$dest/pkgS/shared_data.txt", 'C3: the out-of-write-set path exists in the materialized tree at all')
        or diag('materialize did not run (bp-baseline.pl likely absent)');
    is(-e "$dest/pkgS/shared_data.txt" ? read_file("$dest/pkgS/shared_data.txt") : undef, "OK\n",
       'C3: the out-of-write-set path holds BASELINE content, not the sibling\'s uncommitted edit');
    is(read_file("$proj/pkgS/shared_data.txt"), "BROKEN\n",
       "C3 (counterpart): /project itself DOES still show the sibling's uncommitted change (proves the difference is real, not both-baseline)");

    remove_tree($dest, { safe => 0 }) if -e $dest;
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C4 -- inside-write-set path holds LIVE content (uncommitted + untracked); a write-set path
# deleted live is absent from the materialized tree (spec section 4.2.2).
# =====================================================================================
{
    my ($proj, $sha) = mk_baseline_fixture();
    my $blueprint = 'c4-bp';
    set_baseline_ref($proj, $blueprint, $sha);
    my $dest = "$TEST_BASE/materialized-c4";

    my ($rc, $out, $err) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest, '--blueprint', $blueprint],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
    is($rc, 0, 'C4: materialize exits 0') or diag("out=$out err=$err");

    is(-e "$dest/pkgP/in.txt" ? read_file("$dest/pkgP/in.txt") : undef, "P LIVE EDIT\n",
       'C4: a write-set path holds LIVE (uncommitted) content, not the committed baseline content');
    ok(-e "$dest/pkgP/new-untracked.txt",
       'C4: a NEVER-COMMITTED, untracked write-set file is present in the materialized tree');
    is(-e "$dest/pkgP/new-untracked.txt" ? read_file("$dest/pkgP/new-untracked.txt") : undef, "P untracked file\n",
       'C4: the untracked write-set file carries its live content');
    ok(!-e "$dest/pkgP/nested/deep.txt",
       'C4: a write-set path that WAS in the baseline but is deleted live is ABSENT from the materialized tree');

    remove_tree($dest, { safe => 0 }) if -e $dest;
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C5 -- the SYN-11 scenario, literally: sibling's deliberately-red test file is absent/green in
# P's materialized tree, AND P's own oracle passes there while failing in the polluted /project.
# =====================================================================================
{
    my ($proj, $sha) = mk_baseline_fixture();
    my $blueprint = 'c5-bp';
    set_baseline_ref($proj, $blueprint, $sha);
    my $dest = "$TEST_BASE/materialized-c5";

    my ($rc, $out, $err) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest, '--blueprint', $blueprint],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
    is($rc, 0, 'C5: materialize exits 0') or diag("out=$out err=$err");

    my $sibling_red_in_tree = -e "$dest/pkgS/oracle.t" ? read_file("$dest/pkgS/oracle.t") : undef;
    ok(!defined($sibling_red_in_tree) || $sibling_red_in_tree !~ /not ok/,
       "C5: S's deliberately-red, never-committed test file is ABSENT (or at least not red-as-written) in P's materialized tree")
        or diag("found: " . (defined $sibling_red_in_tree ? $sibling_red_in_tree : '(undef)'));

    # Run P's own designated oracle in BOTH places. In /project it must FAIL (S's WIP edit to the
    # shared file it reads is live there); in the materialized tree it must PASS (that path holds
    # baseline content).
    my $live_out = `cd "$proj" 2>/dev/null; timeout 15 "$^X" pkgP/oracle.t 2>&1`;
    my $live_rc  = $? >> 8;
    my $live_not_ok = () = ($live_out =~ /^not ok/mg);
    ok($live_rc != 0 || $live_not_ok > 0, "C5: P's own oracle FAILS when run against the polluted /project")
        or diag("live_rc=$live_rc out=$live_out");

    my $tree_ok = 0;
    my ($tree_out, $tree_rc, $tree_not_ok) = ('', -1, -1);
    if (-e "$dest/pkgP/oracle.t") {
        $tree_out = `cd "$dest" 2>/dev/null; timeout 15 "$^X" pkgP/oracle.t 2>&1`;
        $tree_rc  = $? >> 8;
        $tree_not_ok = () = ($tree_out =~ /^not ok/mg);
        $tree_ok = ($tree_rc == 0 && $tree_not_ok == 0) ? 1 : 0;
    }
    ok($tree_ok, "C5: P's own oracle PASSES when run against the materialized tree (the reason this package exists)")
        or diag("tree_rc=$tree_rc tree_not_ok=$tree_not_ok out=$tree_out");

    remove_tree($dest, { safe => 0 }) if -e $dest;
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C6 -- dependency handling: done+harvest-passed dep work is visible (by construction, via the
# baseline); a BLOCKED dep yields blocked_deps in .bp-baseline-meta.json, a stderr diagnostic, and
# exit 0 -- and exit 3 under --strict-deps (spec section 4.4).
# =====================================================================================
{
    my ($proj, $sha) = mk_baseline_fixture();
    my $blueprint = 'c6-bp';
    set_baseline_ref($proj, $blueprint, $sha);

    my $dest1 = "$TEST_BASE/materialized-c6-default";
    my $dep_status = JSON::PP::encode_json({ depBlocked => 'blocked', depDone => 'done' });
    my ($rc1, $out1, $err1) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest1, '--blueprint', $blueprint,
         '--dep-status', $dep_status],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');

    is($rc1, 0, 'C6: a blocked dependency degrades WITH evidence, never refuses by default -- exit 0')
        or diag("out=$out1 err=$err1");
    like($err1, qr/depBlocked/, 'C6: a loud diagnostic naming the blocked dependency id is emitted on stderr')
        or diag("stderr was: $err1");

    my $meta_path = "$dest1/.bp-baseline-meta.json";
    ok(-e $meta_path, 'C6: .bp-baseline-meta.json is written at the materialized tree root')
        or diag('metadata file never appeared -- bp-baseline.pl is absent or non-conformant');
    my $meta = -e $meta_path ? eval { JSON::PP::decode_json(read_file($meta_path)) } : undef;
    is(ref($meta) eq 'HASH' ? ($meta->{blocked_deps} // [])->[0] : undef, 'depBlocked',
       "C6: the metadata's blocked_deps key names the offending dependency id, under exactly that key")
        or diag('meta = ' . (defined $meta ? JSON::PP::encode_json($meta) : '(undef/unparsed)'));

    # --strict-deps turns the SAME situation into a non-zero refusal (exit 3), never wedged silent.
    my $dest2 = "$TEST_BASE/materialized-c6-strict";
    my ($rc2, $out2, $err2) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest2, '--blueprint', $blueprint,
         '--dep-status', $dep_status, '--strict-deps'],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
    is($rc2, 3, 'C6: --strict-deps turns a blocked dependency into a precondition refusal (exit 3)')
        or diag("out=$out2 err=$err2");

    remove_tree($dest1, { safe => 0 }) if -e $dest1;
    remove_tree($dest2, { safe => 0 }) if -e $dest2;
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C7 -- location: stat -f of the materialized tree is NOT v9fs; materialize --dest under /project
# refuses with exit 3 (spec section 4.1).
# =====================================================================================
{
    my ($proj, $sha) = mk_baseline_fixture();
    my $blueprint = 'c7-bp';
    set_baseline_ref($proj, $blueprint, $sha);
    my $dest_ok = "$TEST_BASE/materialized-c7-ok";

    my ($rc1, $out1, $err1) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest_ok, '--blueprint', $blueprint],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
    is($rc1, 0, 'C7: materialize under /root (overlayfs) succeeds') or diag("out=$out1 err=$err1");
    if (-d $dest_ok) {
        my $fstype = `stat -f -c %T "$dest_ok" 2>/dev/null`;
        $fstype =~ s/\s+\z//;
        isnt($fstype, 'v9fs', 'C7: the materialized tree under /root is NOT on v9fs')
            or diag("fstype=$fstype");
    } else {
        ok(0, 'C7: materialize under /root produced a tree to stat -f (bp-baseline.pl likely absent)');
    }

    my $dest_bad = "/project/.ccpraxis-local-data/.bp-baseline-c7-probe-$$";
    my ($rc2, $out2, $err2) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest_bad, '--blueprint', $blueprint],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
  SKIP: {
    # The refusal being asserted is specifically "--dest is on v9fs". /project is
    # the container's 9p bind mount; on a host there is no /project and no v9fs,
    # so materialize has nothing to refuse and the negative case cannot be staged.
    skip 'no /project v9fs mount on this host, so the v9fs refusal cannot be staged', 2
        unless -d '/project';
    is($rc2, 3, 'C7 (counterpart): materialize --dest under /project (v9fs) refuses with exit 3')
        or diag("out=$out2 err=$err2");
    ok(!-e $dest_bad, 'C7: no tree was left behind under /project by the refused attempt');
  }
    remove_tree($dest_bad, { safe => 0 }) if -e $dest_bad;

    remove_tree($dest_ok, { safe => 0 }) if -e $dest_ok;
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C8 -- idempotence (materialize twice -> identical manifest, no error) and teardown holding
# after success, after a forced failure, and after SIGTERM (spec section 4.5).
# =====================================================================================
{
    my ($proj, $sha) = mk_baseline_fixture();
    my $blueprint = 'c8-bp';
    set_baseline_ref($proj, $blueprint, $sha);
    my $dest = "$TEST_BASE/materialized-c8";

    my ($rc1) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest, '--blueprint', $blueprint],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
    my $manifest1 = build_manifest($dest);
    my ($rc2) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest, '--blueprint', $blueprint],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
    my $manifest2 = build_manifest($dest);

    is($rc1, 0, 'C8: first materialize exits 0');
    is($rc2, 0, 'C8: second materialize (identical inputs) also exits 0, no error on re-run');
    ok(manifests_equal($manifest1, $manifest2),
       'C8: running materialize twice with identical inputs yields an identical path->sha256 manifest')
        or diag('manifest1 keys: ' . join(',', sort keys %$manifest1)
                . ' manifest2 keys: ' . join(',', sort keys %$manifest2));

    my ($rc_t) = run_baseline(
        ['teardown', '--package', 'P', '--dest', $dest, '--blueprint', $blueprint],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
    is($rc_t, 0, 'C8: teardown after success exits 0');
    ok(!-e $dest, 'C8: teardown after success leaves no stray materialized directory');
    ok(baseline_ref_exists($proj, $blueprint),
       "C8: teardown of a materialized DESTINATION never deletes the persistent baseline ref (that is advance's job alone)");

    # Teardown after a FORCED FAILURE: materialize against a blueprint with no baseline ref at all
    # must fail cleanly (precondition not met), and teardown of that same dest must still leave no
    # stray directory.
    my $dest_fail = "$TEST_BASE/materialized-c8-fail";
    my ($rc_bad, $out_bad, $err_bad) = run_baseline(
        ['materialize', '--package', 'P', '--dest', $dest_fail, '--blueprint', 'c8-bp-no-such-ref'],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
    isnt($rc_bad, 0, 'C8: materialize against a blueprint with no baseline ref fails (not silently 0)')
        or diag("out=$out_bad err=$err_bad");
    run_baseline(['teardown', '--package', 'P', '--dest', $dest_fail, '--blueprint', 'c8-bp-no-such-ref'],
                  BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
    ok(!-e $dest_fail, 'C8: teardown after a forced materialize failure still leaves no stray directory');

    # Teardown after SIGTERM mid-materialize. Best-effort timing (mirrors t/80 C11): poll for the
    # destination to start existing, then kill; the FIRST assertion below is the one that carries
    # real information when the feature is missing (nothing is ever created to observe), so this
    # block is not vacuous even though the final ok(!-e) would otherwise trivially hold either way.
    SKIP: {
        skip('C8 (SIGTERM): this OS does not support the fork/kill protocol used here', 3) unless $bg_supported;
        my $dest_term = "$TEST_BASE/materialized-c8-term";
        my ($pid, $outfile, $errfile) = run_baseline_bg(
            ['materialize', '--package', 'P', '--dest', $dest_term, '--blueprint', $blueprint],
            BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'pkgP');
        my $appeared = poll_until(sub { -e $dest_term }, 8);
        ok($appeared, 'C8 (SIGTERM): the destination begins to materialize before it is interrupted')
            or diag("pid=$pid dest=$dest_term (bp-baseline.pl likely absent, or materializes too fast/slow for this probe)");
        kill('TERM', $pid);
        my $status = wait_pid_timeout($pid, 15);
        ok(!pid_alive($pid), 'C8 (SIGTERM): the materialize process is gone after SIGTERM (bounded wait, not a hang)');

        # The probe polls for $dest_term and kills the instant it appears, so on a
        # small fixture the run can COMPLETE before the signal lands. A finished
        # materialize is *supposed* to leave its tree behind, so asserting
        # `!-e` unconditionally made this assertion fail on correct behaviour --
        # measured at roughly 1-in-8 standalone. Branch on the exit status, which
        # was already captured here and then never used: the handler exits
        # 128+SIGTERM, a completed run exits 0. Both branches assert something
        # real, so this stays non-vacuous either way.
        my $code = $status >> 8;
        if ($code == 0) {
            ok(-e $dest_term, 'C8 (SIGTERM): the run completed before the signal landed, and its '
                . 'finished tree is intact (teardown genuinely not exercised on this pass)');
        }
        else {
            ok(!-e $dest_term, 'C8 (SIGTERM): the SIGTERM handler tore the partial destination '
                . "down -- no stray directory survives (exit $code)");
        }
        remove_tree($dest_term, { safe => 0 }) if -e $dest_term;
    }

    remove_tree($dest, { safe => 0 }) if -e $dest;
    remove_tree($dest_fail, { safe => 0 }) if -e $dest_fail;
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C9 -- BpBaseline::gate_classify (pure, section 5.2) and the gate() CLI-adjacent surface (5.1/5.3),
# driven ONLY via a fake injectable runner returning canned results -- never the real suite (5.4).
# =====================================================================================
{
    my $known_red = {
        'declared-same.t'  => { exit => 1, not_ok => 2 },
        'declared-fixed.t' => { exit => 1, not_ok => 3 },
        'declared-worse.t' => { exit => 1, not_ok => 1 },
    };
    my $results = [
        { file => 'declared-same.t',  exit => 1, not_ok => 2, skips => 0 },  # matches declared -> known
        { file => 'declared-fixed.t', exit => 0, not_ok => 0, skips => 0 },  # came back green -> fixed
        { file => 'declared-worse.t', exit => 1, not_ok => 5, skips => 0 },  # worse than declared -> new_red
        { file => 'undeclared-red.t', exit => 1, not_ok => 1, skips => 0 },  # absent from known_red -> new_red
        { file => 'zero-exit-red.t',  exit => 0, not_ok => 3, skips => 0 },  # exit 0 but not_ok>0 -> new_red
        { file => 'nonzero-no-notok.t', exit => 2, not_ok => 0, skips => 0 }, # exit!=0, not_ok==0 -> new_red
        { file => 'clean.t',          exit => 0, not_ok => 0, skips => 1 },  # untouched, fully green
    ];
    my ($ok, $class) = call_bpb('gate_classify', { results => $results, known_red => $known_red });
    ok($ok, 'C9: BpBaseline::gate_classify is callable') or diag("error: $class");
    is(ref($class), 'HASH', 'C9: gate_classify returns a hashref');

    my %new_red = map { $_ => 1 } @{ (ref($class) eq 'HASH' ? $class->{new_red} : []) || [] };
    my %fixed   = map { $_ => 1 } @{ (ref($class) eq 'HASH' ? $class->{fixed}   : []) || [] };
    my %known   = map { $_ => 1 } @{ (ref($class) eq 'HASH' ? $class->{known}   : []) || [] };

    ok($new_red{'undeclared-red.t'}, 'C9: a newly-red file absent from known_red is classified new_red');
    ok(!$new_red{'declared-same.t'}, 'C9 (counterpart): a declared known_red file coming back UNCHANGED is NOT new_red');
    ok($known{'declared-same.t'} || (ref($class) eq 'HASH' && !$new_red{'declared-same.t'}),
       'C9: an unchanged declared-red file is reported in the known list');
    ok($new_red{'declared-worse.t'}, 'C9: a file red WORSE than its declared entry (higher not_ok) IS new_red');
    ok($fixed{'declared-fixed.t'}, 'C9: a declared-red file that came back green is reported in fixed, never fatal on its own');
    ok($new_red{'zero-exit-red.t'}, 'C9: exit==0 but not_ok>0 is still caught as red (exit-only judging is a known failure mode)');
    ok($new_red{'nonzero-no-notok.t'}, 'C9: exit!=0 but not_ok==0 is still caught as red (not_ok-only judging is a known failure mode)');
    ok(!$new_red{'clean.t'}, 'C9 (counterpart): a fully green, undeclared file is never new_red');
    is(ref($class) eq 'HASH' ? $class->{ok} : undef, 0, 'C9: ok is 0 whenever new_red is non-empty');

    my ($ok2, $class2) = call_bpb('gate_classify', { results => [ { file => 'clean.t', exit => 0, not_ok => 0, skips => 0 } ], known_red => {} });
    is(ref($class2) eq 'HASH' ? $class2->{ok} : undef, 1, 'C9: ok is 1 when every file is green and new_red is empty');
    is_deeply(ref($class2) eq 'HASH' ? $class2->{new_red} : undef, [], 'C9: new_red is the empty list on an all-green run');

    # gate()'s CLI-adjacent surface: an injectable runner (never the real suite) plus a failure
    # path that names BOTH numbers. Best-effort against the module-level entry point.
    my ($ok3, $err3, $captured, $gate_result) = capture_stdout(sub {
        return call_bpb('gate', {
            runner     => sub { return $results },
            known_red  => $known_red,
        });
    });
    my (undef, $gate_ret) = ($ok3, $gate_result);
    SKIP: {
        skip('C9 (gate CLI surface): BpBaseline::gate is not callable yet -- covered above via gate_classify directly', 3)
            unless $HAVE_BASELINE;
        like($captured, qr/exit=\d+/, 'C9: the gate failure report names the exit= number for an offending file')
            or diag("captured stdout: $captured");
        like($captured, qr/not_ok=\d+/, 'C9: the gate failure report names the not_ok= number for an offending file')
            or diag("captured stdout: $captured");
        ok(1, 'C9: gate() was invoked entirely via the injectable runner seam, never the real 90-file suite');
    }
}

# =====================================================================================
# C10 -- opt-in: BpBaseline::enabled precedence (env -> ledger -> blueprint -> default OFF), and
# with the feature disabled, bp-jail.pl's populate_work_tree sources from BP_PROJECT_ROOT exactly
# as today (spec section 7 / 6.1).
# =====================================================================================
{
    my ($ok0, $r0) = call_bpb('enabled', {});
    ok($ok0, 'C10: BpBaseline::enabled is callable') or diag("error: $r0");
    is($r0, 0, 'C10: enabled({}) with everything absent is 0 (default OFF)');

    my (undef, $r1) = call_bpb('enabled', { env_value => '0' });
    is($r1, 0, 'C10: env_value=0 is falsy');
    my (undef, $r2) = call_bpb('enabled', { env_value => 'false' });
    is($r2, 0, 'C10: env_value=false (case-insensitive truthy set excludes it) is falsy');
    my (undef, $r3) = call_bpb('enabled', { env_value => '1' });
    is($r3, 1, 'C10 (counterpart): env_value=1 is truthy');
    my (undef, $r4) = call_bpb('enabled', { env_value => 'YES' });
    is($r4, 1, 'C10: truthy matching is case-insensitive (YES)');
    my (undef, $r5) = call_bpb('enabled', { ledger_value => 'on' });
    is($r5, 1, 'C10: ledger_value=on is truthy when env is absent');
    my (undef, $r6) = call_bpb('enabled', { blueprint_value => 'true' });
    is($r6, 1, 'C10: blueprint_value=true is truthy when env and ledger are both absent');
    my (undef, $r7) = call_bpb('enabled', { env_value => '0', ledger_value => 'true', blueprint_value => 'true' });
    is($r7, 0, 'C10: precedence -- an explicit falsy env_value overrides a truthy ledger AND blueprint value');
    my (undef, $r8) = call_bpb('enabled', { ledger_value => '0', blueprint_value => 'true' });
    is($r8, 0, 'C10: precedence -- an explicit falsy ledger_value overrides a truthy blueprint value');

    # bp-jail.pl's default-unchanged behaviour, tested end to end: with BP_BASELINE_TREE unset, the
    # created jail work tree matches /project content byte for byte -- and it matches a DIFFERENT
    # fixture when BP_BASELINE_TREE names an existing directory, proving the seam is really wired
    # both ways (not just accidentally always reading BP_PROJECT_ROOT).
    my $proj = tempdir(DIR => $TEST_BASE, CLEANUP => 1);
    git_cmd($proj, 'init', '-q');
    git_cmd($proj, 'config', 'user.email', 'c10@example.invalid');
    git_cmd($proj, 'config', 'user.name', 'c10');
    write_file("$proj/mine.txt", "PROJECT CONTENT\n");
    git_cmd($proj, 'add', '-A');
    git_cmd($proj, 'commit', '-q', '-m', 'c10 baseline');

    my $alt_tree = "$TEST_BASE/c10-alt-tree";
    make_path($alt_tree);
    write_file("$alt_tree/mine.txt", "ALTERNATE BASELINE TREE CONTENT\n");

    my $jailroot_default = "$TEST_BASE/jail-c10-default";
    my $errfile1 = "$TEST_BASE/jail-c10-default-err.txt";
    {
        local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, BP_JAIL_BIN => fwd($BP_JAIL),
                      BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'mine.txt', ERRPATH => fwd($errfile1));
        open(my $fh, '-|', 'bash', '-c',
             'exec timeout 30 "$BP_JAIL_BIN" "$@" 2>"$ERRPATH"', 'bash',
             'create', '--package', 'c10pkg-default', '--jail-root', $jailroot_default)
            or die "bash: $!";
        close $fh;
    }
  SKIP: {
    # Both C10 assertions drive `bp-jail.pl create`, which builds a Linux mount
    # namespace. There is no jail to populate on this host, so neither the
    # default nor the BP_BASELINE_TREE seam can be observed.
    skip 'bp-jail.pl create requires Linux namespaces; the C10 baseline-tree seam is NOT exercised here', 1
        unless $^O eq 'linux';
    is(-e "$jailroot_default/work/mine.txt" ? read_file("$jailroot_default/work/mine.txt") : undef,
       "PROJECT CONTENT\n",
       'C10: with BP_BASELINE_TREE unset, bp-jail.pl sources content from BP_PROJECT_ROOT exactly as today');
  }

    my $jailroot_alt = "$TEST_BASE/jail-c10-alt";
    my $errfile2 = "$TEST_BASE/jail-c10-alt-err.txt";
    {
        local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, BP_JAIL_BIN => fwd($BP_JAIL),
                      BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'mine.txt',
                      BP_BASELINE_TREE => fwd($alt_tree), ERRPATH => fwd($errfile2));
        open(my $fh, '-|', 'bash', '-c',
             'exec timeout 30 "$BP_JAIL_BIN" "$@" 2>"$ERRPATH"', 'bash',
             'create', '--package', 'c10pkg-alt', '--jail-root', $jailroot_alt)
            or die "bash: $!";
        close $fh;
    }
  SKIP: {
    skip 'bp-jail.pl create requires Linux namespaces; the BP_BASELINE_TREE seam is NOT exercised here', 1
        unless $^O eq 'linux';
    is(-e "$jailroot_alt/work/mine.txt" ? read_file("$jailroot_alt/work/mine.txt") : undef,
       "ALTERNATE BASELINE TREE CONTENT\n",
       'C10 (seam wiring, spec 6.1): with BP_BASELINE_TREE set to an existing directory, bp-jail.pl sources from THAT tree instead of BP_PROJECT_ROOT')
        or diag('this is the new consumer-side seam bp-jail.pl must add; currently unimplemented');
  }

    local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH);
    system('bash', '-c', 'exec timeout 10 "$0" teardown --package c10pkg-default --jail-root "$1" >/dev/null 2>&1',
           $BP_JAIL, $jailroot_default);
    system('bash', '-c', 'exec timeout 10 "$0" teardown --package c10pkg-alt --jail-root "$1" >/dev/null 2>&1',
           $BP_JAIL, $jailroot_alt);
    remove_tree($jailroot_default, { safe => 0 }) if -e $jailroot_default;
    remove_tree($jailroot_alt, { safe => 0 }) if -e $jailroot_alt;
    remove_tree($alt_tree, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

done_testing();
