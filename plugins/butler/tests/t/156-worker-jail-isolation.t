#!/usr/bin/env perl
# b33-worker-jail-isolation oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b33-worker-jail-isolation-spec.md
# section 5, acceptance criteria C1..C12 (mapped 1:1 to ledger DC-1..DC-9, see the spec's own
# "Criterion mapping" table).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/scripts/bp-jail.pl does not exist at the
# time this file was authored. Every assertion below that depends on it running is expected to
# fail on MISSING BEHAVIOUR: `bash -c 'exec timeout N "$BP_JAIL_BIN" ...'` against a nonexistent
# file exits 127 with bash's own "No such file or directory" diagnostic, never a perl/harness
# error of this file. Assertions labelled FIXTURE-SANITY are deliberate harness self-checks,
# expected to pass even with the script absent -- they are the evidence that the red below is
# attributable to the missing script and not to broken scaffolding. C12 is expected to PASS right
# now: it asserts environment facts (spec section 2) that are already true of this container and
# do not depend on bp-jail.pl at all.
#
# INTERNAL-LAYOUT ASSUMPTION: the spec's own worked proof (section 2) shows the jailed tree
# mounted at `/work` inside the chroot (`/bin/ls / -> bin lib lib64 work`,
# `/bin/cat /work/mine.txt -> worker file`). Tests that need to address a file INSIDE the jail by
# path use `/work/...` on that authority, not as an invented convention.
#
# HARNESS RULES (mirroring 155-worker-backend-dispatcher.t):
#   * %CLEAN_ENV strips every ambient BP_*/PATH-adjacent var this suite controls explicitly.
#   * All fixtures (fake project root, jail root) are synthesized under a tempdir rooted at
#     /root -- overlayfs, never /project (9p; chmod is a no-op there -- spec section 2/7).
#   * The one exception is C12's chmod-on-/project probe, which by definition must touch real
#     /project. It writes/removes a single throwaway file under
#     /project/.ccpraxis-local-data/ (gitignored per project CLAUDE.md, so it cannot dirty `git
#     status`) and is wrapped so cleanup always runs, even on a failed assertion.
#   * Foreground jail invocations are wrapped in `timeout 30` as a safety net only -- no assertion
#     depends on it; a script that hangs must not hang this suite.
#   * C11 uses a fork + bounded poll-loop protocol (ready-file), never an unbounded wait.
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

(my $ROOT_SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $BP_JAIL = "$ROOT_SCRIPTS/bp-jail.pl";

diag("subject under test: $BP_JAIL "
     . (-e $BP_JAIL
        ? "(present)"
        : "(ABSENT -- every criterion below that runs it is expected to fail on MISSING BEHAVIOUR)"));

# A jail-isolation test must control its own environment completely.
my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $REAL_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# TEST_BASE must be overlayfs (chmod honoured), never /project (9p). /root itself is part of the
# root overlayfs in this container (only /root/.claude is a separate 9p mount) -- verified below
# as FIXTURE-SANITY, not assumed.
my $TEST_BASE = tempdir((-d '/root' && -w '/root') ? (DIR => '/root') : (), CLEANUP => 1);
my $rn = 0;

# =====================================================================================
# Scaffolding: generic file helpers
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

sub jail_tree_paths {
    my ($dir) = @_;
    my @out;
    return @out unless -d $dir;
    File::Find::find({ wanted => sub { push @out, $File::Find::name }, no_chdir => 1 }, $dir);
    return @out;
}
sub grep_file_contents {
    my ($dir, $pattern) = @_;
    my @hits;
    return @hits unless -d $dir;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        return unless -r $_;
        local $/;
        open my $fh, '<', $_ or return;
        binmode $fh;
        my $content = <$fh>;
        close $fh;
        push @hits, $_ if defined($content) && $content =~ $pattern;
    } }, $dir);
    return @hits;
}
# Broad best-effort search for a BpLog::event(-shaped) JSON line naming $needle, anywhere under
# $dir. The spec does not pin bp-jail.pl's log path, so this searches every *.log/*.jsonl file
# under the whole fixture area rather than a single guessed location -- see report notes.
sub find_bplog_hits {
    my ($dir, $needle) = @_;
    my @hits;
    return @hits unless -d $dir;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        return unless /\.(log|jsonl?)$/;
        open my $fh, '<', $_ or return;
        while (my $line = <$fh>) {
            next unless index($line, $needle) >= 0;
            my $rec = eval { JSON::PP::decode_json($line) };
            next unless ref($rec) eq 'HASH' && exists $rec->{ts} && exists $rec->{type};
            push @hits, $line;
        }
        close $fh;
    } }, $dir);
    return @hits;
}

sub shquote { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'"; }
sub git_cmd {
    my ($dir, @args) = @_;
    my $cmd = join(' ', 'git', '-C', shquote($dir), map { shquote($_) } @args);
    my $out = `$cmd 2>&1`;
    my $rc = $? >> 8;
    return ($rc, defined $out ? $out : '');
}

# =====================================================================================
# Scaffolding: fake project root. git repo with:
#   in-scope/mine.txt        tracked, committed, then given an UNCOMMITTED modification
#   in-scope/todelete.txt    tracked, committed (deletion target for C8)
#   in-scope/brand-new.txt   NEVER committed (untracked new file, for C3)
#   out-of-scope/todelete.txt  tracked, committed (deletion target for C8, must NOT propagate)
#   out-of-scope/other.txt     tracked, committed (modification target for C9, must NOT propagate)
#   .gitignore covering .ccpraxis-local-data/, deploy_key, .claude/
#   .ccpraxis-local-data/claude-home/.credentials.json  gitignored secret (never committed)
#   deploy_key, .claude/settings.json                    gitignored secrets (never committed)
# =====================================================================================
sub mk_fake_project {
    my $proj = tempdir(DIR => $TEST_BASE, CLEANUP => 1);
    git_cmd($proj, 'init', '-q');
    git_cmd($proj, 'config', 'user.email', 'bp-jail-test@example.invalid');
    git_cmd($proj, 'config', 'user.name', 'bp-jail-test');

    write_file("$proj/.gitignore", ".ccpraxis-local-data/\ndeploy_key\n.claude/\n");
    write_file("$proj/in-scope/mine.txt", "original in-scope content\n");
    write_file("$proj/in-scope/todelete.txt", "in-scope delete me\n");
    write_file("$proj/out-of-scope/todelete.txt", "out-of-scope keep me\n");
    write_file("$proj/out-of-scope/other.txt", "out-of-scope original\n");
    git_cmd($proj, 'add', '-A');
    git_cmd($proj, 'commit', '-q', '-m', 'baseline');

    write_file("$proj/.ccpraxis-local-data/claude-home/.credentials.json",
               qq({"secret":"do-not-leak"}\n));
    write_file("$proj/deploy_key", "FAKE PRIVATE KEY MATERIAL\n");
    write_file("$proj/.claude/settings.json", "{}\n");

    # current working state: an uncommitted modification + a never-committed new file (C3).
    write_file("$proj/in-scope/mine.txt", "original in-scope content\nUNCOMMITTED EDIT\n");
    write_file("$proj/in-scope/brand-new.txt", "never committed, brand new\n");

    return $proj;
}

# =====================================================================================
# Scaffolding: run bp-jail.pl, foreground (bounded by `timeout 30` as a safety net).
# =====================================================================================
sub run_jail {
    my ($args, %envover) = @_;
    my $errfile = "$TEST_BASE/stderr." . (++$rn) . ".txt";
    local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, %envover,
                  BP_JAIL_BIN => fwd($BP_JAIL), ERRPATH => fwd($errfile));
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 30 "$BP_JAIL_BIN" "$@" 2>"$ERRPATH"', 'bash', @$args)
        or die "bash: $!";
    binmode $fh;
    my $out = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    my $err = -e $errfile ? read_file($errfile) : '';
    return ($rc, defined $out ? $out : '', $err);
}

# Background variant: forks, execs bp-jail.pl directly (no `timeout`, so the pid returned really
# is the bp-jail.pl process and can be signalled -- mirrors run_worker_bg in
# 155-worker-backend-dispatcher.t A13).
sub run_jail_bg {
    my ($args, %envover) = @_;
    my $outfile = "$TEST_BASE/bgout." . (++$rn) . ".txt";
    my $errfile = "$TEST_BASE/bgerr." . (++$rn) . ".txt";
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, %envover, BP_JAIL_BIN => fwd($BP_JAIL),
                      OUTPATH => fwd($outfile), ERRPATH => fwd($errfile));
        exec('bash', '-c', 'exec "$BP_JAIL_BIN" "$@" >"$OUTPATH" 2>"$ERRPATH"', 'bash', @$args);
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

my $bg_supported = ($^O eq 'linux' || $^O eq 'darwin') ? 1 : 0;

# =====================================================================================
# FIXTURE-SANITY -- pass with or without bp-jail.pl. Proves the red below is "script missing",
# not "harness broken", and proves TEST_BASE really is overlayfs (the whole premise of every
# jail-root assertion in this file).
# =====================================================================================
{
  SKIP: {
    # On a filesystem that carries no POSIX modes (NTFS via Git-Bash perl) this
    # cannot distinguish overlayfs from 9p because it cannot observe a mode at
    # all. That is missing coverage, not a broken fixture.
    skip 'this filesystem does not carry POSIX modes, so the overlayfs-vs-9p '
       . 'distinction cannot be observed here', 1 unless chmod_works();
    my $probe = "$TEST_BASE/chmod-probe.txt";
    write_file($probe, "x\n");
    chmod 0600, $probe;
    my $mode = (stat($probe))[2] & 07777;
    is(sprintf('%o', $mode), '600', 'FIXTURE-SANITY: TEST_BASE (under /root) honours chmod 600 -- confirms overlayfs, not 9p')
        or diag("TEST_BASE=$TEST_BASE got mode=" . sprintf('%o', $mode));
    unlink $probe;
  }

    my $proj = mk_fake_project();
    ok(-d "$proj/.git", 'FIXTURE-SANITY: mk_fake_project() produces a git repo');
    my (undef, $ls) = git_cmd($proj, 'ls-files');
    like($ls, qr/in-scope\/mine\.txt/, 'FIXTURE-SANITY: baseline tracked file is committed');
    unlike($ls, qr/credentials/, 'FIXTURE-SANITY: the gitignored secret is not tracked by git');
    my (undef, $status) = git_cmd($proj, 'status', '--porcelain');
    like($status, qr/in-scope\/mine\.txt/, 'FIXTURE-SANITY: the uncommitted edit to mine.txt shows as dirty');
    like($status, qr/brand-new\.txt/, 'FIXTURE-SANITY: the never-committed new file shows as untracked');
    unlike($status, qr/credentials|deploy_key|\.claude/, 'FIXTURE-SANITY: gitignored paths do not appear in git status at all');
    remove_tree($proj, { safe => 0 });

  SKIP: {
    skip "this OS ($^O) does not support the fork/kill protocol C11 uses", 1 unless $bg_supported;
    ok($bg_supported, 'FIXTURE-SANITY: this OS supports the fork/kill protocol used by C11');
  }
}

# =====================================================================================
# EVERYTHING BELOW EXERCISES bp-jail.pl FOR REAL, and bp-jail.pl is Linux-only by
# construction: it asserts over uid, CapEff, mount namespaces and POSIX file modes.
# None of those exist on a Windows host -- `cat` cannot be denied by a permission
# bit the filesystem does not store, and there is no capability set to be empty.
#
# Run here unguarded, C1-C13 produced 49 failures that all said "the jail does not
# isolate" when the truth was "there is no jail here to test". A single skip states
# the second thing. The structural groups above still run, so the file keeps its
# real host-side coverage (46 assertions) instead of being skip_all'd wholesale.
#
# The count is nominal -- this file uses done_testing(), not a fixed plan.
# =====================================================================================
my $JAIL_RUNNABLE = ($^O eq 'linux') && chmod_works();
SKIP: {
    skip 'bp-jail.pl requires Linux namespaces, uid/capability separation and POSIX file '
       . 'modes; none are available on this host, so C1-C13 are NOT exercised here', 49
        unless $JAIL_RUNNABLE;

# =====================================================================================
# C1 (DC-1) -- a jailed command cannot stat/read/glob claude-home/.credentials.json.
# =====================================================================================
{
    my $proj = mk_fake_project();
    my $pkg = 'c1-pkg';
    my $jailroot = "$TEST_BASE/jail-c1";
    my $secret_abs = "$proj/.ccpraxis-local-data/claude-home/.credentials.json";

    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my ($rc1, $out1, $err1) = run_jail(
        ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'cat', $secret_abs],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc1, 5, 'C1: `cat` of the absolute credentials path from inside the jail exits 5 (jailed cmd failed)');
    like($err1 . $out1, qr/No such file or directory/,
         'C1: the failure is ENOENT ("No such file or directory"), not a permission denial');

    my ($rc2, $out2, $err2) = run_jail(
        ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'bash', '-c',
         qq{shopt -s nullglob; files=($proj/.ccpraxis-local-data/claude-home/*); echo "COUNT=\${#files[\@]}"}],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc2, 0, 'C1: the glob probe script itself runs to completion (exit 0)');
    like($out2, qr/COUNT=0/, 'C1: a glob under claude-home/ from inside the jail matches zero paths')
        or diag("rc=$rc2 out=$out2 err=$err2");

    ok(-d $jailroot, 'C1: bp-jail.pl create actually created the jail root')
        or diag('jail root never materialised -- bp-jail.pl is absent or non-conformant');
    my @named = grep { /claude-home/ } jail_tree_paths($jailroot);
    is(scalar(@named), 0, 'C1: no path anywhere physically under the jail root is named claude-home');

    run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    remove_tree($jailroot, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C2 (DC-2) -- the jailed command runs as a non-zero uid with an empty capability set.
# =====================================================================================
{
    my $proj = mk_fake_project();
    my $pkg = 'c2-pkg';
    my $jailroot = "$TEST_BASE/jail-c2";
    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my ($rc, $out, $err) = run_jail(
        ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'bash', '-c',
         q{echo "UID=$(id -u)"; grep '^CapEff:' /proc/self/status}],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc, 0, 'C2: the uid/cap probe command exits 0')
        or diag("err=$err");
    if ($out =~ /^UID=(\d+)\s*$/m) {
        isnt($1, '0', 'C2: the jailed command runs as a non-zero uid');
    } else {
        ok(0, 'C2: the jailed command runs as a non-zero uid (no UID= line captured)');
    }
    like($out, qr/CapEff:\s*0000000000000000/, 'C2: CapEff inside the jail is the empty set');

    run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    remove_tree($jailroot, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C3 (DC-3) -- own tree reflects CURRENT working state: uncommitted edit + never-committed file.
# =====================================================================================
{
    my $proj = mk_fake_project();
    my $pkg = 'c3-pkg';
    my $jailroot = "$TEST_BASE/jail-c3";
    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my ($rc, $out, $err) = run_jail(
        ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'cat',
         '/work/in-scope/mine.txt', '/work/in-scope/brand-new.txt'],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc, 0, 'C3: cat of the jail\'s own working-tree files exits 0')
        or diag("err=$err");
    like($out, qr/UNCOMMITTED EDIT/, 'C3: the uncommitted modification is visible inside the jail (HEAD-only population would fail this)');
    like($out, qr/never committed, brand new/, 'C3: a never-committed new file is visible inside the jail');

    run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    remove_tree($jailroot, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C4 (DC-3a) -- no git in the jail at all, and no file anywhere contains a hidden-path pointer.
# =====================================================================================
{
    my $proj = mk_fake_project();
    my $pkg = 'c4-pkg';
    my $jailroot = "$TEST_BASE/jail-c4";
    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    run_jail(['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'true'],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    ok(-d $jailroot, 'C4: the jail root exists after create+run')
        or diag('jail root never materialised -- bp-jail.pl is absent or non-conformant');
    my @paths = jail_tree_paths($jailroot);
    my @dotgit = grep { m{(^|/)\.git(/|$)} } @paths;
    is(scalar(@dotgit), 0, 'C4: no .git file or directory exists anywhere under the jail');

    # SCOPED TO THE WORK TREE, and the scoping is load-bearing. Scanning the whole jail
    # cannot pass: the /usr farm includes /usr/lib, and an ordinary system shared
    # library — measured, `/usr/lib/x86_64-linux-gnu/libapt-pkg.so.6.0` — contains the
    # literal bytes "/project" in its string table. Nothing to do with this package.
    #
    # Worth recording HOW that was nearly missed: a hand check with `grep -rl /project
    # <jail>` reported CLEAN, because grep goes binary-silent on NUL without -a (this
    # repo's own landmine #5). The Perl scan here reads bytes directly and sees them.
    # A "verification" that used grep without -a would have argued for the wrong fix.
    #
    # DC-3a's stated intent is the copied project tree and a dangling `gitdir:` pointer
    # ("a dead pointer is worse than nothing: it both breaks git and leaks a /project
    # path"), so the work tree is the correct scope. A path string inside an unrelated
    # .so grants no access, and C1 asserts directly that /project and
    # claude-home/.credentials.json are genuinely unreachable (ENOENT). The .git
    # assertion above and the generalised fixture-path assertion below both still scan
    # the ENTIRE jail, so a real pointer leak anywhere is still caught.
    my @leak_literal = grep_file_contents("$jailroot/work", qr{/project\b});
    is(scalar(@leak_literal), 0,
       'C4: no file in the jail WORK TREE contains the literal string "/project" (the dangling-gitdir leak DC-3a names)')
        or diag('leaking files: ' . join(', ', @leak_literal));

    # This fixture's hidden project root is NOT literally "/project" (per this suite's hard
    # constraint against touching the live repo for merge-back tests), so the check above is
    # trivially satisfied by our fixture's path naming alone. The check below generalises the
    # criterion's intent to THIS fixture: no file may point back at $proj either.
    my @leak_fixture = grep_file_contents($jailroot, qr{\Q$proj\E});
    is(scalar(@leak_fixture), 0,
       "C4 (generalised): no file contains this fixture's own hidden project-root path ($proj)");

    run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    remove_tree($jailroot, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C5 (DC-3b) -- coordinator-side git still works after merge-back: git status sees the merged
# change, and a checkpoint commit of it succeeds.
# =====================================================================================
{
    my $proj = mk_fake_project();
    my $pkg = 'c5-pkg';
    my $jailroot = "$TEST_BASE/jail-c5";

    # mk_fake_project() deliberately leaves the tree dirty (uncommitted edit + untracked file,
    # for C3). That would make git-status/commit assertions below pass trivially even if
    # merge-back does nothing, so this test first commits that pre-existing dirt to a clean
    # baseline -- any diff seen afterward can only have come from the jailed write + merge-back.
    git_cmd($proj, 'add', '-A');
    git_cmd($proj, 'commit', '-q', '-m', 'pre-test clean baseline for C5');
    my (undef, $preclean) = git_cmd($proj, 'status', '--porcelain');
    is($preclean, '', 'C5: fixture working tree is clean before the jail ever runs (sanity for what follows)');

    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my ($rc_w) = run_jail(
        ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'bash', '-c',
         'echo "JAILED APPEND" >> /work/in-scope/mine.txt'],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_w, 0, 'C5: the jailed write command exits 0');

    my ($rc_m, $out_m, $err_m) = run_jail(
        ['merge', '--package', $pkg, '--jail-root', $jailroot],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_m, 0, 'C5: merge-back exits 0')
        or diag("out=$out_m err=$err_m");

    my (undef, $status) = git_cmd($proj, 'status', '--porcelain');
    like($status, qr/in-scope\/mine\.txt/, 'C5: git status OUTSIDE the jail sees the merged change to in-scope/mine.txt');

    git_cmd($proj, 'add', '-A');
    my ($ci_rc, $ci_out) = git_cmd($proj, 'commit', '-m', 'checkpoint after merge-back');
    is($ci_rc, 0, 'C5: a checkpoint commit of the merged changes succeeds outside the jail')
        or diag($ci_out);

    run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    remove_tree($jailroot, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C6 (DC-4) -- DNS resolution and an outbound TLS connection succeed from inside the jail.
# Skip cleanly if this sandbox itself has no outbound network (checked OUTSIDE the jail first).
# =====================================================================================
{
    my $net_ok = 0;
    {
        local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH);
        my $code = `timeout 5 curl -sS -o /dev/null -w '%{http_code}' https://www.google.com 2>/dev/null`;
        $net_ok = (defined($code) && $code eq '200') ? 1 : 0;
    }
  SKIP: {
        skip('C6: sandbox has no outbound network (curl to https://www.google.com failed outside the jail) -- cannot exercise DNS/TLS from inside', 2)
            unless $net_ok;

        my $proj = mk_fake_project();
        my $pkg = 'c6-pkg';
        my $jailroot = "$TEST_BASE/jail-c6";
        run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
                  BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

        my ($rc, $out, $err) = run_jail(
            ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'bash', '-c',
             'curl -sS -o /dev/null -w "%{http_code}" https://www.google.com'],
            BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
        is($rc, 0, 'C6: an outbound TLS request from inside the jail exits 0')
            or diag("out=$out err=$err");
        like($out, qr/^200$/, 'C6: the outbound TLS request receives an HTTP 200 (DNS + TLS both succeeded)');

        run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
                  BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
        remove_tree($jailroot, { safe => 0 });
        remove_tree($proj, { safe => 0 });
    }
}

# =====================================================================================
# C7 (DC-5) -- a worker writes both in-scope and out-of-scope files: only in-scope is merged.
# =====================================================================================
{
    my $proj = mk_fake_project();
    my $pkg = 'c7-pkg';
    my $jailroot = "$TEST_BASE/jail-c7";
    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my ($rc_w) = run_jail(
        ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'bash', '-c',
         'echo new-in-scope > /work/in-scope/created.txt; echo new-out-of-scope > /work/out-of-scope/created.txt'],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_w, 0, 'C7: the dual in-scope/out-of-scope write command exits 0');

    my ($rc_m) = run_jail(['merge', '--package', $pkg, '--jail-root', $jailroot],
                            BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_m, 0, 'C7: merge-back exits 0');
    ok(-e "$proj/in-scope/created.txt", 'C7: the in-scope new file IS merged into the project');
    ok(!-e "$proj/out-of-scope/created.txt", 'C7: the out-of-scope new file is NOT merged into the project');

    run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    remove_tree($jailroot, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C8 (DC-5a) -- in-write-set deletions propagate; out-of-write-set deletions do not.
# =====================================================================================
{
    my $proj = mk_fake_project();
    my $pkg = 'c8-pkg';
    my $jailroot = "$TEST_BASE/jail-c8";
    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my ($rc_w) = run_jail(
        ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'rm', '-f',
         '/work/in-scope/todelete.txt', '/work/out-of-scope/todelete.txt'],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_w, 0, 'C8: the dual-deletion command exits 0');

    my ($rc_m) = run_jail(['merge', '--package', $pkg, '--jail-root', $jailroot],
                            BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_m, 0, 'C8: merge-back exits 0');
    ok(!-e "$proj/in-scope/todelete.txt", 'C8: an in-write-set deletion propagates to the project');
    ok(-e "$proj/out-of-scope/todelete.txt", 'C8: an out-of-write-set deletion does NOT propagate to the project');
    is(read_file("$proj/out-of-scope/todelete.txt"), "out-of-scope keep me\n",
       'C8: the out-of-write-set file content is byte-unchanged');

    run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    remove_tree($jailroot, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C9 (DC-6) -- out-of-write-set modifications are reported by path in the merge summary AND
# logged via BpLog::event, never silently dropped.
# =====================================================================================
{
    my $proj = mk_fake_project();
    my $pkg = 'c9-pkg';
    my $jailroot = "$TEST_BASE/jail-c9";
    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my ($rc_w) = run_jail(
        ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'bash', '-c',
         'echo "MODIFIED OUT OF SCOPE" >> /work/out-of-scope/other.txt'],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_w, 0, 'C9: the out-of-write-set modification command exits 0');

    my ($rc_m, $out_m, $err_m) = run_jail(
        ['merge', '--package', $pkg, '--jail-root', $jailroot],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_m, 0, 'C9: merge-back still exits 0 (reporting is not a refusal)');
    like($out_m . $err_m, qr{out-of-scope/other\.txt},
         'C9: the merge summary names the out-of-write-set path out-of-scope/other.txt');
    ok(!-e "$proj/out-of-scope/other.txt" || read_file("$proj/out-of-scope/other.txt") eq "out-of-scope original\n",
       'C9: the out-of-write-set file is not merged despite being reported');

    # Best-effort, broad search: the spec names BpLog::event as the logging mechanism but does
    # not pin bp-jail.pl's log path, so this searches every *.log/*.jsonl under the whole fixture
    # area (jail root, project root, and any sibling files bp-jail.pl may create) rather than a
    # single guessed location. See report notes.
    my @hits = find_bplog_hits($TEST_BASE, 'out-of-scope/other.txt');
    ok(scalar(@hits) > 0,
       'C9: a BpLog::event-shaped record (JSON line with ts+type) names out-of-scope/other.txt somewhere under the fixture area')
        or diag('no matching *.log/*.jsonl record found under ' . $TEST_BASE);

    run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    remove_tree($jailroot, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C10 (DC-7, strengthened per spec section 3.5) -- teardown removes the jail and is idempotent.
# Criterion 7's wording ("prune from .git/worktrees") is satisfied BY CONSTRUCTION: section 3.1
# rules out `git worktree` entirely, so there is no worktree and nothing to prune. We do NOT
# assert a `git worktree prune` call (the spec explicitly forbids adding one just to satisfy the
# wording). Instead we assert the STRONGER property: no entry is EVER created under
# $proj/.git/worktrees, before, during, or after a full create/run/merge/teardown cycle. This is
# a deliberate strengthening, not a skipped criterion.
# =====================================================================================
{
    my $proj = mk_fake_project();
    my $pkg = 'c10-pkg';
    my $jailroot = "$TEST_BASE/jail-c10";

    ok(!-d "$proj/.git/worktrees" || !glob("$proj/.git/worktrees/*"),
       'C10 (section 3.5): no entry under .git/worktrees BEFORE dispatch');

    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    run_jail(['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'true'],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    ok(!-d "$proj/.git/worktrees" || !glob("$proj/.git/worktrees/*"),
       'C10 (section 3.5): no entry under .git/worktrees DURING dispatch (after create+run)');

    run_jail(['merge', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my ($rc_t1) = run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
                             BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_t1, 0, 'C10: teardown exits 0');
    ok(!-e $jailroot, 'C10: the jail root no longer exists after teardown');

    my ($rc_t2) = run_jail(['teardown', '--package', $pkg, '--jail-root', $jailroot],
                             BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');
    is($rc_t2, 0, 'C10: running teardown a SECOND time (already torn down) still exits 0 (idempotent)');
    ok(!-e $jailroot, 'C10: the jail root still does not exist after the second teardown');
    ok(!-d "$proj/.git/worktrees" || !glob("$proj/.git/worktrees/*"),
       'C10 (section 3.5): no entry under .git/worktrees AFTER teardown');

    remove_tree($jailroot, { safe => 0 });
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C11 (DC-8) -- teardown runs even when the jailed command is killed by a signal. We send
# SIGTERM to the `bp-jail.pl run` process itself while its jailed command is mid-flight (the
# survivable case per landmine 7: "use END plus %SIG handlers"). SIGKILL of the PARENT is
# explicitly unsurvivable and is documented in the spec as an accepted degradation (as b32 did),
# so it is deliberately NOT exercised here.
# =====================================================================================
SKIP: {
    skip('C11: this OS does not support the fork/kill protocol used by this test', 4) unless $bg_supported;

    my $proj = mk_fake_project();
    my $pkg = 'c11-pkg';
    my $jailroot = "$TEST_BASE/jail-c11";
    run_jail(['create', '--package', $pkg, '--jail-root', $jailroot],
              BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my $ready = "$jailroot/work/.ready";
    my ($pid, $outfile, $errfile) = run_jail_bg(
        ['run', '--package', $pkg, '--jail-root', $jailroot, '--', 'bash', '-c',
         'touch /work/.ready; sleep 30'],
        BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'in-scope');

    my $became_ready = wait_for_file($ready, 8);
    ok($became_ready, 'C11: the jailed command signalled readiness before being killed')
        or diag("jailroot=$jailroot pid=$pid (bp-jail.pl likely absent, or the /work layout assumption does not hold)");

    kill('TERM', $pid);
    my $status = wait_pid_timeout($pid, 15);
    ok(!pid_alive($pid), 'C11: the bp-jail.pl run process is gone after SIGTERM (bounded wait, not a hang)');
    ok(!-e $jailroot, 'C11: teardown fired (jail root removed) despite the run being killed by a signal mid-command');

    remove_tree($jailroot, { safe => 0 }) if -e $jailroot;
    remove_tree($proj, { safe => 0 });
}

# =====================================================================================
# C12 (DC-9) -- the section 2 preconditions, asserted AS preconditions. Ground truth measured
# by the coordinator today; if any of these flips, the isolation model's assumptions have
# changed and this suite must say so loudly rather than silently protecting nothing.
# =====================================================================================
{
    my $mount_line = `mount 2>/dev/null | grep -F ' on /project '`;
    like($mount_line, qr/\btype 9p\b/, 'C12: /project is mounted as 9p')
        or diag("mount line: $mount_line");

    # chmod-not-honoured on /project: probed via a single throwaway file under the gitignored
    # .ccpraxis-local-data/ directory, cleaned up immediately (wrapped in eval so cleanup always
    # runs, even if an assertion below dies).
    my $probe = "/project/.ccpraxis-local-data/.bp-jail-c12-probe-$$.txt";
    eval {
        write_file($probe, "probe\n");
        chmod 0600, $probe;
        my $mode = (stat($probe))[2] & 07777;
        is(sprintf('%o', $mode), '777', 'C12: chmod 600 on /project reads back 777 (modes NOT honoured on 9p)')
            or diag("got mode=" . sprintf('%o', $mode));
    };
    diag("C12 /project chmod probe died: $@") if $@;
    unlink $probe if -e $probe;

    my $root_probe = "$TEST_BASE/c12-root-probe.txt";
    write_file($root_probe, "probe\n");
    chmod 0600, $root_probe;
    my $root_mode = (stat($root_probe))[2] & 07777;
    is(sprintf('%o', $root_mode), '600', 'C12: chmod 600 under /root reads back 600 (overlayfs honours modes)');
    unlink $root_probe;

    my $unshare_err = `unshare -m true 2>&1`;
    my $unshare_rc = $? >> 8;
    isnt($unshare_rc, 0, 'C12: `unshare -m` fails (not permitted to create a new mount namespace)');
    like($unshare_err, qr/not permitted/i, 'C12: `unshare -m` fails specifically with an EPERM-style message');

    my $capeff_line = `grep '^CapEff:' /proc/self/status`;
    like($capeff_line, qr/^CapEff:\s*([0-9a-fA-F]+)/, 'C12: /proc/self/status carries a CapEff line')
        or diag($capeff_line);
    if ($capeff_line =~ /^CapEff:\s*([0-9a-fA-F]+)/) {
        my $capeff = hex($1);
        my %bit = (CHOWN => 0, DAC_OVERRIDE => 1, DAC_READ_SEARCH => 2, FOWNER => 3,
                    SETGID => 6, SETUID => 7, SYS_CHROOT => 18, SYS_ADMIN => 21, MKNOD => 27);
        for my $cap (qw(CHOWN DAC_OVERRIDE FOWNER SETGID SETUID SYS_CHROOT)) {
            ok((($capeff >> $bit{$cap}) & 1), "C12: CAP_$cap is present in CapEff");
        }
        for my $cap (qw(DAC_READ_SEARCH SYS_ADMIN MKNOD)) {
            ok(!(($capeff >> $bit{$cap}) & 1), "C12: CAP_$cap is ABSENT from CapEff");
        }
    } else {
        ok(0, 'C12: CapEff bit decode (no CapEff line found to decode)') for 1 .. 9;
    }
}

# =====================================================================================
# C13 -- THE JAIL'S ENVIRONMENT BOUNDARY, ASSERTED IN BOTH DIRECTIONS.
#
# b33's isolation is FILESYSTEM isolation: chroot makes the Claude credential
# unreachable on disk, which is what C1 above asserts. It performs no ENVIRONMENT
# isolation -- exec() inherits %ENV wholesale -- and that was harmless only while
# b33's verified premise held: OpenCode needed no credential, so there was no
# OpenCode secret to inherit. b36 broke that premise.
#
# The obvious fix, an allowlist, is WRONG, and this block exists to keep it wrong
# on the record. A jailed worker READS six variables out of ~47 inherited, so
# dropping the other 41 looks like pure gain -- but several of them are SECURITY
# CONTROLS DELIVERED AS ENVIRONMENT. Dropping npm_config_ignore_scripts
# re-enables npm postinstall arbitrary code execution; dropping the DISABLE_*
# set re-enables upgrade / GitHub-app-install / autoupdate inside the jail, which
# is a privilege INCREASE, not a reduction.
#
# So the threat model is bidirectional and both halves are asserted here:
# secrets must not leak IN, and controls must not fall OUT.
# =====================================================================================
{
    my $secret = 'C13-SENTINEL-MUST-NOT-CROSS-THE-JAIL-7f3a1';

    # The two lists are READ FROM bp-jail.pl's source rather than duplicated
    # here. bp-jail.pl has no `package` declaration and a bare `require` would
    # execute its argument parsing, so parse the qw() blocks instead. This also
    # means the test cannot drift from the implementation: adding a name to
    # either list in the script automatically extends the assertions below.
    my $jail_src = read_file($BP_JAIL) // '';
    my @DENY = $jail_src =~ /our\s+\@JAIL_ENV_DENYLIST\s*=\s*qw\(([^)]*)\)/s ? split ' ', $1 : ();
    my @REQD = $jail_src =~ /our\s+\@JAIL_ENV_REQUIRED\s*=\s*qw\(([^)]*)\)/s ? split ' ', $1 : ();
    cmp_ok(scalar(@DENY), '>', 0, 'C13 HARNESS: the denylist was parsed out of bp-jail.pl');
    cmp_ok(scalar(@REQD), '>', 0, 'C13 HARNESS: the required-present list was parsed out of bp-jail.pl');

    my $proj = tempdir((-d '/root' && -w '/root') ? (DIR => '/root') : (), CLEANUP => 1);
    system('git', '-C', $proj, 'init', '-q');
    system('git', '-C', $proj, 'config', 'user.email', 'c13@example.invalid');
    system('git', '-C', $proj, 'config', 'user.name', 'c13');
    write_file("$proj/keep.txt", "hello\n");
    system('git', '-C', $proj, 'add', '-A');
    system('git', '-C', $proj, 'commit', '-q', '-m', 'baseline');

    my $jailroot = tempdir((-d '/root' && -w '/root') ? (DIR => '/root') : (), CLEANUP => 0);
    File::Path::remove_tree($jailroot);

    # Every denied name carries the sentinel; every required name carries a
    # recognisable value, so the two directions are checked in ONE jailed run.
    my %env = (
        BP_PROJECT_ROOT => $proj,
        BP_WRITE_SET    => 'keep.txt',
        (map { ($_ => $secret) } @DENY),
        npm_config_ignore_scripts          => 'true',
        DISABLE_AUTOUPDATER                => '1',
        DISABLE_UPGRADE_COMMAND            => '1',
        DISABLE_INSTALL_GITHUB_APP_COMMAND => '1',
        IS_SANDBOX                         => '1',
    );

    run_jail(['create', '--package', 'c13-pkg', '--jail-root', $jailroot], %env);
    my ($rc, $out, $err) = run_jail(
        ['run', '--package', 'c13-pkg', '--jail-root', $jailroot, '--', 'env'], %env);

    # ---- direction 1: secrets must not leak IN ----
    unlike($out, qr/\Q$secret\E/,
        'C13 (in): no denied credential VALUE reaches the jailed environment');
    for my $name (@DENY) {
        unlike($out, qr/^\Q$name\E=/m,
            "C13 (in): $name is not even NAMED in the jailed environment");
    }

    # ---- direction 2: controls must not fall OUT ----
    # This is the half an allowlist would have broken.
    for my $name (@REQD) {
        like($out, qr/^\Q$name\E=/m,
            "C13 (out): $name SURVIVES into the jail -- dropping it would remove a control, not add one");
    }

    # VACUITY GATE: the probe genuinely saw a populated environment. Without
    # this, an `env` that produced nothing at all would satisfy every unlike()
    # above while telling us precisely nothing.
    cmp_ok(scalar(split /\n/, $out), '>', 3,
        'C13 VACUITY GATE: the jailed `env` returned a populated environment, so the absence checks above mean something');

    system(qq{"$^X" "$BP_JAIL" teardown --package c13-pkg --jail-root "$jailroot"});
    File::Path::remove_tree($jailroot) if -e $jailroot;
    File::Path::remove_tree($proj)     if -e $proj;
}

# =====================================================================================
# b48 -- C21..C23: THE BOUNDARY IS AN ALLOWLIST, PROVEN BY A CANARY.
#
# C13 above asserts the boundary in both directions, but only over NAMED
# variables: the denied credentials are absent and the protective controls are
# present. A denylist passes that test by construction while leaking everything
# it never thought to name -- PERL5OPT (arbitrary code into EVERY perl process,
# and this toolchain is entirely Perl), LD_PRELOAD, NODE_OPTIONS, GIT_CONFIG_*.
#
# So the assertion that matters is about an ARBITRARY variable, not a known-bad
# one. Enumerating known-bad names in the test reproduces the denylist bug in
# the test layer -- the test would pass for exactly the reason the code is wrong.
#
# C22 keeps the OTHER direction honest: the recorded argument against an
# allowlist was that dropping controls-delivered-as-environment is a privilege
# INCREASE (npm_config_ignore_scripts re-enabling postinstall execution, and so
# on). That argument is correct, and it is why the allowlist must NAME those
# controls rather than be minimal.
# =====================================================================================
{
    my $jailroot = File::Temp->newdir(CLEANUP => 1) . "";
    my $proj     = File::Temp->newdir(CLEANUP => 1) . "";

    my $src = do { open my $fh, '<', $BP_JAIL or die "open bp-jail.pl: $!"; local $/; <$fh> };

    # The allowlist must EXIST as a named construct. Parsed from source rather
    # than assumed, in the same style as C13's harness.
    my ($allow_block) = $src =~ /\@JAIL_ENV_ALLOW(?:_EXACT)?\s*=\s*qw\(([^)]*)\)/s;
    ok(defined $allow_block, 'C21 HARNESS: an env ALLOWLIST was parsed out of bp-jail.pl')
        or diag('no @JAIL_ENV_ALLOW / @JAIL_ENV_ALLOW_EXACT found -- boundary is still subtractive');

    SKIP: {
        skip('C21: no allowlist to exercise', 4) unless defined $allow_block;

        my @allow = grep { length } split /\s+/, $allow_block;
        cmp_ok(scalar(@allow), '>', 0, 'C21: the allowlist is non-empty');

        # The protective controls the recorded rationale names must survive --
        # otherwise the allowlist is the privilege increase that argument warned
        # about. Derived from @JAIL_ENV_REQUIRED, never a literal list here.
        my ($reqd_block) = $src =~ /\@JAIL_ENV_REQUIRED\s*=\s*qw\(([^)]*)\)/s;
        my @reqd = grep { length } split /\s+/, ($reqd_block // '');
        my %in_allow = map { $_ => 1 } @allow;
        my @missing  = grep { !$in_allow{$_} } @reqd;
        is(scalar(@missing), 0,
            'C22: every protective control in @JAIL_ENV_REQUIRED is named in the allowlist')
            or diag("dropped controls would be a PRIVILEGE INCREASE: @missing");

        # --- the canary: an ARBITRARY name nobody thought to deny -------------
        local $ENV{BP_JAIL_CANARY}  = 'canary-must-not-cross-9c21f';
        local $ENV{PERL5OPT}        = '-Mstrict';
        local $ENV{LD_PRELOAD}      = '/tmp/nonexistent-b48.so';
        local $ENV{NODE_OPTIONS}    = '--max-old-space-size=64';
        local $ENV{GIT_CONFIG_COUNT} = '1';

        # C23 exercises scrub_jail_env DIRECTLY rather than through `jail run`.
        # The full path needs chroot and a built jail, which is not available in
        # every environment -- and a canary that SKIPS is worthless, since the
        # skip is indistinguishable from the leak it exists to catch ("the
        # condition is the failure state"). Calling the boundary function in a
        # child process is deterministic everywhere and tests the same code the
        # forked child runs immediately before exec.
        # Written to a file rather than passed via -e: shell quoting has mangled
        # multi-line perl in this repo before, and a probe that fails to RUN
        # returns an error string that vacuously satisfies every `unlike` below.
        # (That is not hypothetical -- it happened while writing this block, and
        # only the PATH counterpart assertion caught it.)
        my ($pfh, $pfile) = File::Temp::tempfile('b48-probe-XXXXXX', SUFFIX => '.pl', UNLINK => 1);
        # bp-jail.pl declares no `package`, so its subs live in main::.
        print $pfh <<'PROBE';
require $ARGV[0];
main::scrub_jail_env();
print join("\n", sort keys %ENV), "\n";
PROBE
        close $pfh;

        # stdout ONLY. A deliberately-nonexistent LD_PRELOAD makes ld.so warn on
        # stderr, and folding that into the captured text would let the warning
        # text satisfy the assertions below.
        my $envout = `"$^X" "$pfile" "$BP_JAIL" 2>/dev/null`;
        my $rc = $? >> 8;

        is($rc, 0, 'C23 HARNESS: scrub_jail_env is callable in a child process') or diag($envout);

        unlike($envout, qr/^BP_JAIL_CANARY$/m,
            'C23: an ARBITRARY unnamed variable does not survive the boundary '
            . '(the assertion a denylist cannot pass)')
            or diag("survived:\n$envout");

        for my $vector (qw(PERL5OPT LD_PRELOAD NODE_OPTIONS GIT_CONFIG_COUNT)) {
            unlike($envout, qr/^\Q$vector\E$/m,
                "C23: $vector does not survive the boundary (named regression anchor)");
        }

        like($envout, qr/^PATH$/m,
            'C23 (counterpart): PATH DOES survive -- the allowlist is not simply emptying the environment');
    }

    File::Path::remove_tree($jailroot) if -e $jailroot;
    File::Path::remove_tree($proj)     if -e $proj;
}

}   # end SKIP: the bp-jail.pl behaviour section (C1-C13)

done_testing();
