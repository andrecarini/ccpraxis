#!/usr/bin/env perl
# b02-durable-checkpoint-commits — the immutable test oracle.
#
# Derived ONLY from specs/03-durable-checkpoint-commits-spec.md (AC-1..AC-29):
#   * bp-checkpoint.pl  — parse_write_set / commit_message / checkpoint / resolve_root
#                         + the CLI contract (§2.1-§2.8)
#   * bp-orchestrator.pl — the ckpt_int tunable, the $opt->{checkpoint} seam, the
#                         CHECKPOINT tick section and its two triggers (§2.9-§2.12)
#   * orchestrator-protocol/SKILL.md — the documented discipline (§2.13)
#
# Style follows t/20-deps-check.t (init_git / git_commit_all fixtures), t/08 + t/11
# (mk_bp + a real BpOrch::run driven by a fake clock) and t/20-orchestrator-broken-
# env-turns.t (sc()/hv() call guards). Every call that may not exist yet is funnelled
# through a guard so a missing sub is ONE failing assertion, never an aborted file.
#
# House rules honoured here: no `bash`/`sh -c` anywhere (there is no shell in this
# container), every git call is list-form `git -C <root> ...`, and every git fixture
# lives under File::Temp::tempdir(CLEANUP => 1) — /project is NEVER used as a repo.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use HostCaps qw(git_path);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/../../scripts/bp-orchestrator.pl";

my $J      = JSON::PP->new->canonical;
my $UJ     = JSON::PP->new->utf8->canonical;
# `require bp-orchestrator.pl` above runs its BEGIN block, which sets
# MSYS2_ARG_CONV_EXCL='*' on Windows -- so from line 27 onward THIS PROCESS has
# MSYS argv path-translation disabled. A bare tempdir() yields /tmp/XXXX; perl
# resolves it fine, but `git -C /tmp/XXXX/repo1` hands native git.exe a POSIX
# path it resolves against the current DRIVE instead, looking for
# C:\tmp\XXXX\repo1. Symptom was `fatal: cannot change to '/tmp/...'` and a die
# that took the whole file down after assertion 45 -- while the directory
# demonstrably existed (verified by probe: ROOT_exists=1 dir_exists=1).
#
# This is the drive-root landmine the user-global CLAUDE.md documents: opting
# out of conversion is only safe TOGETHER WITH hand-translating your own paths.
# The orchestrator opts out; this file never translated. HostCaps::git_path is
# the translation, applied at each git call site.
# Anchored in the native temp dir, NOT merely translated at the call sites.
# git_path() below covers this file's OWN git calls, but the code under test
# (BpOrch::checkpoint) runs git against the root it is handed and does no
# translation of its own -- correct for the Linux container it ships to. So the
# root itself has to be natively resolvable, or 58 assertions fail inside the
# production code rather than in the fixture. Measured both ways: anchoring ->
# green; call-site translation alone -> 58 failures.
my $ROOT   = tempdir(HostCaps::tempdir_args(), CLEANUP => 1);
my $NOW    = time;
my $SCRIPT = "$Bin/../../scripts/bp-checkpoint.pl";
my $ORCH   = "$Bin/../../scripts/bp-orchestrator.pl";
my $SKILL  = "$Bin/../../skills/orchestrator-protocol/SKILL.md";
my $TDIR   = "$Bin";

# A pinned epoch for every message/timestamp assertion (§2.7 gmtime form).
use constant EPOCH  => 1785000000;              # 2026-07-25T17:20:00Z
use constant EPOCH_ISO => '2026-07-25T17:20:00Z';

use Config ();
# Absolute path to this perl, for shebang lines in generated scripts. NOT $^X:
# on Git-for-Windows perl $^X is the bare string "perl", so `#!perl` is not a
# resolvable interpreter and git refuses the hook outright with
# "cannot spawn .git/hooks/pre-commit: No such file or directory". Config's
# perlpath is absolute on every platform this suite runs on.
my $PERL = $Config::Config{perlpath};

# ---------------------------------------------------------------------------
# Call guards (t/20-orchestrator-broken-env-turns.t:30-32)
# ---------------------------------------------------------------------------
# scalar call guard: returns the value, or a "DIED: ..." string on exception.
sub sc { my $c = shift; my $r = eval { $c->() }; return $@ ? 'DIED: ' . ((split /\n/, $@)[0]) : $r }
# hashref-field guard: returns $h->{$k} when $h is a hash, else a diagnostic string.
sub hv { my ($h, $k) = @_; return ref($h) eq 'HASH' ? $h->{$k} : "NOT-A-HASH($h)" }
# arrayref guard: always yields an arrayref so is_deeply can report the difference.
sub av { my ($a) = @_; return ref($a) eq 'ARRAY' ? $a : [ "NOT-AN-ARRAYREF(" . (defined $a ? $a : 'undef') . ")" ] }

# ---------------------------------------------------------------------------
# Local scaffolding (the spec is silent on fixture mechanics; these are ours).
# ---------------------------------------------------------------------------
sub spit { my ($p, $c) = @_; open my $f, '>:raw', $p or die "spit $p: $!"; print $f $c; close $f; return $p }
sub slurp_raw { my ($p) = @_; open my $f, '<:raw', $p or return undef; local $/; my $c = <$f>; close $f; return $c }
sub slurp { my ($p) = @_; return slurp_raw($p) // '' }

# run_child(@cmd) -> ($merged_output, $exit).  Fork/exec, list form, stderr merged
# into the captured stream so an EXPECTED git failure never sprays the TAP stream.
# (Same shape as the helper's own _git, §2.6 — no shell, ever.)
sub run_child {
    my (@cmd) = @_;
    my $pid = open(my $fh, '-|');
    return ('fork-failed', -1) unless defined $pid;
    unless ($pid) {
        open(STDERR, '>&', \*STDOUT) or close(STDERR);
        exec(@cmd);
        exit 127;
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    return ((defined $out ? $out : ''), ($? == -1 ? -1 : $? >> 8));
}
sub git_out { my ($dir, @args) = @_; return run_child('git', '-C', git_path($dir), @args) }
sub run_cli { my (@args) = @_; return run_child($^X, $SCRIPT, @args) }

# ---- git fixture helpers, copied from t/20-deps-check.t:49-63 --------------
sub init_git {
    my ($dir) = @_;
    system('git', '-C', git_path($dir), 'init', '-q') == 0
        or die "git init failed in $dir";
}

sub git_commit_all {
    my ($dir, $msg) = @_;
    $msg //= 'fixture commit';
    system('git', '-C', git_path($dir), 'add', '-A') == 0
        or die "git add failed in $dir";
    system('git', '-C', git_path($dir), '-c', 'user.email=t@t', '-c', 'user.name=t',
           'commit', '-q', '-m', $msg) == 0
        or die "git commit failed in $dir";
}

my $repo_n = 0;
# mk_repo(files => { 'src/a.txt' => 'x' }) -> a temp repo with ONE seeded commit.
sub mk_repo {
    my (%o) = @_;
    my $dir = "$ROOT/repo" . (++$repo_n);
    make_path($dir);
    init_git($dir);
    write_rel($dir, $_, $o{files}{$_}) for sort keys %{ $o{files} || {} };
    git_commit_all($dir, 'seed');
    return $dir;
}
sub write_rel {
    my ($dir, $rel, $content) = @_;
    my $p = "$dir/$rel";
    (my $d = $p) =~ s{/[^/]+\z}{};
    make_path($d) if length $d && !-d $d;
    return spit($p, $content);
}
sub count_commits {
    my ($dir) = @_;
    my ($o, $e) = git_out($dir, 'rev-list', '--count', 'HEAD');
    $o =~ s/\s+//g;
    return $e == 0 && $o =~ /^\d+$/ ? $o + 0 : -1;
}
sub head_fmt { my ($dir, $fmt) = @_; my ($o, $e) = git_out($dir, 'log', '-1', "--format=$fmt");
               return $e == 0 ? $o : "GIT-FAILED($e): $o" }
sub head_files {
    my ($dir) = @_;
    my ($o, $e) = git_out($dir, 'diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD');
    return [ "GIT-FAILED($e)" ] if $e != 0;
    return [ sort grep { /\S/ } split /\n/, $o ];
}
sub porcelain { my ($dir) = @_; my ($o, $e) = git_out($dir, 'status', '--porcelain');
                return $e == 0 ? $o : "GIT-FAILED($e): $o" }

# capture_stderr(\&code) -> ($stderr_text, $result_or_DIED)
sub capture_stderr {
    my ($code) = @_;
    my $cap = "$ROOT/stderr." . (++$repo_n) . ".cap";
    open(my $save, '>&', \*STDERR) or return ('CANNOT-DUP-STDERR', undef);
    unless (open(STDERR, '>', $cap)) { open(STDERR, '>&', $save); return ('CANNOT-REDIRECT-STDERR', undef) }
    my $r = eval { $code->() };
    my $err = $@;
    open(STDERR, '>&', $save);
    close $save;
    return ((slurp_raw($cap) // ''), ($err ? 'DIED: ' . ((split /\n/, $err)[0]) : $r));
}

# ---- helper-call guards ----------------------------------------------------
sub pws  { my ($ws) = @_; return av(sc(sub { BpCheckpoint::parse_write_set($ws) })) }
sub cmsg { my ($a)  = @_; my $r = sc(sub { BpCheckpoint::commit_message($a) });
           return defined $r ? $r : 'UNDEF' }
sub ck   { my (%a)  = @_; return sc(sub { BpCheckpoint::checkpoint({ %a }) }) }
sub ck_err {
    my (%a) = @_;
    return eval { BpCheckpoint::checkpoint({ %a }); 1 } ? '' : ((split /\n/, ($@ // 'died'))[0] // 'died');
}
# one canonical JSON line -> hashref (CLI contract §2.8)
sub jline {
    my ($out) = @_;
    my @l = grep { /\S/ } split /\n/, ($out // '');
    my $o = @l == 1 ? eval { $UJ->decode($l[0]) } : undef;
    return $o if ref($o) eq 'HASH';
    my $sample = @l ? substr($l[0], 0, 90) : '<no output>';
    return { status => "NO-SINGLE-JSON-LINE(" . scalar(@l) . "): $sample" };
}

# ---------------------------------------------------------------------------
# Load the helper with STDOUT captured (AC-1: `require` must print NOTHING and
# must not run the CLI). Test::More dup'd its own output handle at load time, so
# this redirect cannot disturb the TAP stream.
# ---------------------------------------------------------------------------
my ($REQ_OK, $REQ_ERR, $REQ_OUT) = (0, '', '');
{
    my $cap = "$ROOT/require-stdout.txt";
    if (open(my $save, '>&', \*STDOUT)) {
        if (open(STDOUT, '>', $cap)) {
            $REQ_OK  = eval { require $SCRIPT; 1 } ? 1 : 0;
            $REQ_ERR = $REQ_OK ? '' : ((split /\n/, ($@ // 'unknown'))[0] // 'unknown');
            open(STDOUT, '>&', $save);
        }
        close $save;
    }
    $REQ_OUT = slurp_raw($cap) // '';
}

# ===========================================================================
# PASS 1 — the helper's pure surface (§2.1, §2.2, §2.7). No filesystem.
# ===========================================================================

# ---- AC-1: require-ability, silence, and the four public subs -------------
ok($REQ_OK, "AC-1 require '$SCRIPT' succeeds and returns true" . ($REQ_OK ? '' : " [$REQ_ERR]"));
is($REQ_OUT, '', 'AC-1 require prints nothing on STDOUT (the CLI is guarded by `unless (caller)`)');
ok(BpCheckpoint->can('parse_write_set'), 'AC-1 BpCheckpoint::parse_write_set is defined');
ok(BpCheckpoint->can('commit_message'),  'AC-1 BpCheckpoint::commit_message is defined');
ok(BpCheckpoint->can('checkpoint'),      'AC-1 BpCheckpoint::checkpoint is defined');
ok(BpCheckpoint->can('resolve_root'),    'AC-1 BpCheckpoint::resolve_root is defined');
{
    my ($out, $exit) = run_child($^X, '-e', "require q{$SCRIPT}; print STDOUT q{REQ-OK}");
    is($exit, 0,        'AC-1 requiring the helper in a clean interpreter exits 0 (no top-level side effects)');
    is($out,  'REQ-OK', 'AC-1 a clean-interpreter require emits nothing of its own on STDOUT/STDERR');
}

# ---- AC-2: parse_write_set matches the §2.2 rule table ---------------------
is_deeply(pws('a/b.pl:c/d/: :e/*.md'), ['a/b.pl', 'c/d', 'e/*.md'],
          'AC-2 trims, drops the empty entry, strips the trailing slash, keeps the glob verbatim');
is_deeply(pws('   a/b.pl   '), ['a/b.pl'],            'AC-2 rule 1: leading/trailing whitespace is trimmed');
is_deeply(pws('a::b'),         ['a', 'b'],            'AC-2 rule 2: an entry empty after trim is dropped');
is_deeply(pws('x/y///'),       ['x/y'],               'AC-2 rule 3: one OR MORE trailing slashes are stripped');
is_deeply(pws('docs/*.md:src/?.pl:t/[0-9]*.t'), ['docs/*.md', 'src/?.pl', 't/[0-9]*.t'],
          'AC-2 rule 4: * ? [ globs pass through verbatim (git wildmatch, never Perl, never a shell)');
is_deeply(pws('plugins/butler/scripts/bp-orchestrator.pl'), ['plugins/butler/scripts/bp-orchestrator.pl'],
          'AC-2 rule 5: a plain path passes through verbatim');
is_deeply(pws('/etc/passwd:../../x:~/y'), [],
          'AC-2 rule 7: absolute, .. -escaping and ~ entries are all dropped');
is_deeply(pws('a/../b'), [],                          'AC-2 rule 7: an embedded `..` path segment is dropped');
is_deeply(pws('..'),     [],                          'AC-2 rule 7: a bare `..` entry is dropped');
is_deeply(pws('a..b'),   ['a..b'],                    'AC-2 rule 7 is about `..` PATH SEGMENTS, not the substring');
is_deeply(pws("a\nb"),   [],                          'AC-2 rule 8: an entry containing a newline is dropped');
is_deeply(pws("ok/x:a\0b"), ['ok/x'],                 'AC-2 rule 8: an entry containing a NUL is dropped');
is_deeply(pws(undef),    [],                          'AC-2 parse_write_set(undef) -> [] (total, never dies)');
is_deeply(pws(''),       [],                          "AC-2 parse_write_set('') -> []");
is_deeply(pws('a:b:a'),  ['a', 'b'],                  'AC-2 duplicates removed, first wins, input order kept');
is_deeply(pws('a/:a'),   ['a'],                       'AC-2 dedup happens after trailing-slash normalisation');

# ---- AC-3: the _ws_prefixes trap (§1.3) -----------------------------------
is_deeply(pws('plugins/x/:*'), ['plugins/x'],
          "AC-3 the _ws_prefixes trap: 'plugins/x/:*' keeps ONLY plugins/x (the bare * is dropped)");
is_deeply(pws('*'),  [], "AC-3 write set '*' -> [] (never the whole tree)");
is_deeply(pws('**'), [], "AC-3 write set '**' -> []");
is_deeply(pws('.'),  [], "AC-3 write set '.' -> []");
is_deeply(pws('./'), [], "AC-3 write set './' -> []");
is_deeply(pws('/'),  [], "AC-3 write set '/' -> []");
is_deeply(pws('*/'), [], "AC-3 write set '*/' -> []");
{
    my @empties;
    for my $ws ('a::b', ' : ', 'x/', '*', './', '/', '**', 'a/:*:', ':', '::', 'p/q/:') {
        push @empties, "[$ws]"
            if grep { !defined($_) || $_ eq '' || /^NOT-AN-ARRAYREF/ } @{ pws($ws) };
    }
    is_deeply(\@empties, [], 'AC-3 NO returned element is ever the empty string (an empty pathspec = everything)');
}

# ---- AC-4: commit_message (§2.7) ------------------------------------------
is(cmsg({ pkg => 'p', status => 'running', step => 4 }), 'wip(p): running @ step 4',
   'AC-4 step >= 1 -> `wip(<pkg>): <status> @ step <n>`');
is(cmsg({ pkg => 'p', status => 'running', step => 1 }), 'wip(p): running @ step 1',
   'AC-4 step 1 is already the step form');
is(cmsg({ pkg => 'b02-durable-checkpoint-commits', status => 'in-progress', step => 12 }),
   'wip(b02-durable-checkpoint-commits): in-progress @ step 12',
   'AC-4 the package name and status are used verbatim');
is(cmsg({ pkg => 'p', status => 'running', step => 0, now => EPOCH }), 'wip(p): running @ ' . EPOCH_ISO,
   'AC-4 step 0 -> the UTC timestamp form derived from `now`');
is(cmsg({ pkg => 'p', status => 'running', now => EPOCH }), 'wip(p): running @ ' . EPOCH_ISO,
   'AC-4 step undef -> the UTC timestamp form');
is(cmsg({ pkg => 'p', status => 'running', step => 'abc', now => EPOCH }), 'wip(p): running @ ' . EPOCH_ISO,
   'AC-4 a non-numeric step -> the UTC timestamp form');
is(cmsg({ pkg => 'p', status => '', step => 4 }), 'wip(p): unknown @ step 4',
   "AC-4 an empty status -> the literal 'unknown'");
is(cmsg({ pkg => 'p', step => 4 }), 'wip(p): unknown @ step 4',
   "AC-4 an undefined status -> the literal 'unknown'");
is(cmsg({ pkg => 'p', status => "run\nning", step => 4 }), 'wip(p): unknown @ step 4',
   "AC-4 a status containing a newline -> the literal 'unknown'");
{
    my $m = cmsg({ pkg => 'p', status => 'running', step => 4 });
    ok($m =~ /^wip\(/ && $m !~ /\n/,                'AC-4 the message is a single line with no trailing newline');
    ok($m =~ /^wip\(/ && $m !~ /Co-?Authored-?By/i, 'AC-4 the message never carries a Co-Authored-By trailer');
    ok($m =~ /^wip\(/ && $m !~ /Generated with/i,   'AC-4 the message never carries a "Generated with" trailer');
    ok($m =~ /^wip\(/ && $m !~ /\x{1F916}/,         'AC-4 the message never carries a robot-emoji attribution');
}

# ===========================================================================
# PASS 2 — checkpoint() against REAL throwaway git repos (§2.4, §2.5).
# Every repo lives under $ROOT (File::Temp, CLEANUP => 1). Never /project.
# ===========================================================================

# ---- AC-5 / AC-6 / AC-7: the happy path -----------------------------------
{
    my $dir = mk_repo(files => { 'src/live.txt' => "one\n", 'other/out.txt' => "keep\n" });
    write_rel($dir, 'src/live.txt', "one\ntwo\n");                 # dirty, inside the write set
    my $before = count_commits($dir);

    my $r = ck(root => $dir, pkg => 'b02-x', write_set => 'src/', status => 'in-progress',
               step => 3, now => EPOCH);

    is(hv($r, 'ok'),        1,           'AC-5 dirty tracked file inside the write set -> ok=1');
    is(hv($r, 'status'),    'committed', 'AC-5 status=committed');
    is(hv($r, 'committed'), 1,           'AC-5 committed=1');
    is(hv($r, 'reason'),    undef,       'AC-5 a successful commit carries no reason');
    is(hv($r, 'exit'),      0,           'AC-5 exit=0 (what the CLI would exit with)');
    like((hv($r, 'sha') // ''), qr/^[0-9a-f]{40}$/, 'AC-5 sha is 40 lowercase hex');
    is(count_commits($dir), $before + 1, 'AC-5 rev-list --count HEAD increased by EXACTLY 1');
    is(hv($r, 'sha'), (head_fmt($dir, '%H') =~ s/\s+\z//r), 'AC-5 the returned sha IS the new HEAD');

    my $msg = cmsg({ pkg => 'b02-x', status => 'in-progress', step => 3, now => EPOCH });
    is(hv($r, 'message'), $msg, 'AC-5 the result carries the commit message it used');

    my $b = head_fmt($dir, '%B'); $b =~ s/\n+\z//;
    my @body_lines = split /\n/, $b;
    is($b, $msg,                        'AC-6 the commit %B is exactly commit_message(...)');
    ok($b =~ /^wip\(/ && @body_lines == 1,
       'AC-6 the commit body is ONE line (no trailers, no body)');
    ok($b =~ /^wip\(/ && $b !~ /Co-?Authored-?By/i,
       'AC-6 the commit message has no Co-Authored-By trailer');
    ok($b =~ /^wip\(/ && $b !~ /Generated with/i,
       'AC-6 the commit message has no "Generated with" trailer');
    is((head_fmt($dir, '%an|%ae') =~ s/\s+\z//r), 'butler|butler@localhost',
       'AC-6 author name/email are butler / butler@localhost');
    is((head_fmt($dir, '%cn|%ce') =~ s/\s+\z//r), 'butler|butler@localhost',
       'AC-6 committer name/email are butler / butler@localhost');

    is_deeply(head_files($dir), ['src/live.txt'],
              'AC-7 the commit touches ONLY write-set paths');

    # ---- AC-8: an immediately repeated checkpoint finds a clean tree -------
    my $c1 = count_commits($dir);
    my $r2 = ck(root => $dir, pkg => 'b02-x', write_set => 'src/', status => 'in-progress',
                step => 3, now => EPOCH + 60);
    is(hv($r2, 'ok'),        1,            'AC-8 clean tree -> ok=1 (a no-op is not an error)');
    is(hv($r2, 'status'),    'clean',      'AC-8 status=clean');
    is(hv($r2, 'committed'), 0,            'AC-8 committed=0');
    is(hv($r2, 'reason'),    'clean-tree', "AC-8 reason='clean-tree'");
    is(hv($r2, 'sha'),       undef,        'AC-8 no sha when nothing was committed');
    is(hv($r2, 'exit'),      1,            'AC-8 exit=1 (nothing committed, non-error)');
    is(count_commits($dir),  $c1,          'AC-8 rev-list --count HEAD unchanged');
}

# ---- AC-9: a dirty file OUTSIDE the write set is never captured -----------
{
    my $dir = mk_repo(files => { 'src/in.txt' => "a\n", 'other/out.txt' => "b\n" });
    write_rel($dir, 'src/in.txt',    "a\nchanged\n");
    write_rel($dir, 'other/out.txt', "b\nchanged\n");
    my $before = count_commits($dir);

    my $r = ck(root => $dir, pkg => 'b02-x', write_set => 'src/', status => 'running', step => 1, now => EPOCH);
    is(hv($r, 'status'), 'committed',           'AC-9 the inside-the-write-set change commits');
    is(count_commits($dir), $before + 1,        'AC-9 exactly one new commit');
    is_deeply(head_files($dir), ['src/in.txt'], 'AC-9 the commit contains ONLY the inside file');
    like(porcelain($dir), qr/^.. other\/out\.txt$/m,
         'AC-9 the outside file is STILL dirty after the checkpoint');

    # ... and again with the outside file already STAGED in the shared index.
    my $dir2 = mk_repo(files => { 'src/in.txt' => "a\n", 'other/out.txt' => "b\n" });
    write_rel($dir2, 'src/in.txt',    "a\nchanged\n");
    write_rel($dir2, 'other/out.txt', "b\nchanged\n");
    my ($ao, $ae) = git_out($dir2, 'add', '--', 'other/out.txt');
    is($ae, 0, 'AC-9 fixture: the outside file was pre-staged in the index');
    my $before2 = count_commits($dir2);
    my $r2 = ck(root => $dir2, pkg => 'b02-x', write_set => 'src/', status => 'running', step => 1, now => EPOCH);
    is(hv($r2, 'status'), 'committed',            'AC-9 (pre-staged) the inside change still commits');
    is(count_commits($dir2), $before2 + 1,        'AC-9 (pre-staged) exactly one new commit');
    is_deeply(head_files($dir2), ['src/in.txt'],
              'AC-9 a PRE-STAGED outside file is still absent from the commit (cross-blueprint bleed guard)');
    like(porcelain($dir2), qr/^M. other\/out\.txt$/m,
         'AC-9 (pre-staged) the outside file remains staged-but-uncommitted afterwards');
}

# ---- AC-10: an untracked NEW file inside the write set is included --------
{
    my $dir = mk_repo(files => { 'src/keep.txt' => "k\n" });
    write_rel($dir, 'src/new.txt', "brand new\n");                 # untracked, inside
    my $before = count_commits($dir);
    my $r = ck(root => $dir, pkg => 'b02-x', write_set => 'src/', status => 'running', step => 2, now => EPOCH);
    is(hv($r, 'status'), 'committed',            'AC-10 an untracked new file inside the write set commits');
    is(count_commits($dir), $before + 1,         'AC-10 exactly one new commit');
    is_deeply(head_files($dir), ['src/new.txt'], 'AC-10 the untracked new file IS in the commit');
}

# ---- AC-11: unmatched pathspecs ------------------------------------------
{
    my $dir = mk_repo(files => { 'src/in.txt' => "a\n" });
    write_rel($dir, 'src/in.txt', "a\nb\n");
    my $before = count_commits($dir);
    my $r = ck(root => $dir, pkg => 'b02-x', write_set => 'src/:nope/', status => 'running',
               step => 1, now => EPOCH);
    is(hv($r, 'status'), 'committed',          'AC-11 the existing entry still commits alongside a missing one');
    is(count_commits($dir), $before + 1,       'AC-11 exactly one new commit');
    is_deeply(av(hv($r, 'unmatched')), ['nope'],  'AC-11 the nonexistent entry is reported in unmatched');
    is_deeply(av(hv($r, 'staged')),    ['src'],   'AC-11 staged holds only the pathspec git accepted');
    is_deeply(av(hv($r, 'pathspecs')), ['src', 'nope'], 'AC-11 pathspecs is what parse_write_set returned');

    my $dir2 = mk_repo(files => { 'src/in.txt' => "a\n" });
    write_rel($dir2, 'src/in.txt', "a\nb\n");
    my $before2 = count_commits($dir2);
    my $r2 = ck(root => $dir2, pkg => 'b02-x', write_set => 'nope/:alsonope', status => 'running',
                step => 1, now => EPOCH);
    is(hv($r2, 'ok'),        1,                          'AC-11 all-unmatched -> ok=1 (not an error)');
    is(hv($r2, 'status'),    'clean',                    'AC-11 all-unmatched -> status=clean');
    is(hv($r2, 'committed'), 0,                          'AC-11 all-unmatched -> committed=0');
    is(hv($r2, 'reason'),    'all-pathspecs-unmatched',  "AC-11 reason='all-pathspecs-unmatched'");
    is(hv($r2, 'exit'),      1,                          'AC-11 all-unmatched -> exit=1');
    is(count_commits($dir2), $before2,                   'AC-11 all-unmatched -> commit count unchanged');
}

# ---- AC-12: the whole-tree write set is refused ---------------------------
{
    my $dir = mk_repo(files => { 'src/in.txt' => "a\n", 'other/out.txt' => "b\n" });
    write_rel($dir, 'src/in.txt',     "a\ndirty\n");
    write_rel($dir, 'other/out.txt',  "b\ndirty\n");
    write_rel($dir, 'top.txt',        "untracked dirt\n");
    my $before = count_commits($dir);
    my $r = ck(root => $dir, pkg => 'b02-x', write_set => '*', status => 'running', step => 1, now => EPOCH);
    is(hv($r, 'ok'),        1,                  "AC-12 write set '*' -> ok=1");
    is(hv($r, 'status'),    'clean',            "AC-12 write set '*' -> status=clean");
    is(hv($r, 'committed'), 0,                  "AC-12 write set '*' -> committed=0");
    is(hv($r, 'reason'),    'no-safe-pathspec', "AC-12 write set '*' -> reason='no-safe-pathspec'");
    is(hv($r, 'exit'),      1,                  "AC-12 write set '*' -> exit=1");
    is_deeply(av(hv($r, 'pathspecs')), [],      "AC-12 write set '*' yields no pathspecs at all");
    is_deeply(av(hv($r, 'dropped')),   ['*'],   "AC-12 the dropped entry is reported in `dropped`");
    is(count_commits($dir), $before,            'AC-12 commit count UNCHANGED — the whole tree was NOT staged');
    like(porcelain($dir), qr/^.. src\/in\.txt$/m, 'AC-12 the dirty tree is still dirty (nothing was captured)');
}

# ---- AC-13: a root that is not a git repo (the /project shape) ------------
{
    my $plain = "$ROOT/not-a-repo";
    make_path($plain);
    write_rel($plain, 'src/x.txt', "hi\n");
    my ($errtext, $r) = capture_stderr(sub { BpCheckpoint::checkpoint({
        root => $plain, pkg => 'b02-x', write_set => 'src/', status => 'running', step => 1, now => EPOCH }) });
    is(ck_err(root => $plain, pkg => 'b02-x', write_set => 'src/', status => 'running', now => EPOCH), '',
       'AC-13 checkpoint() against a non-repo root does NOT die (structured return, never an exception)');
    is(hv($r, 'ok'),     0,            'AC-13 non-repo root -> ok=0');
    is(hv($r, 'status'), 'error',      'AC-13 non-repo root -> status=error');
    is(hv($r, 'reason'), 'not-a-repo', "AC-13 non-repo root -> reason='not-a-repo'");
    is(hv($r, 'exit'),   3,            'AC-13 non-repo root -> exit=3 (git error)');
    is($errtext, '',                   "AC-13 git's stderr is captured, never sprayed on the caller's STDERR");
}

# ---- AC-14: a rejecting pre-commit hook ----------------------------------
{
    my $dir = mk_repo(files => { 'src/in.txt' => "a\n" });
    my $hook = "$dir/.git/hooks/pre-commit";
    make_path("$dir/.git/hooks") unless -d "$dir/.git/hooks";
    spit($hook, "#!$PERL\nprint STDERR \"pre-commit says no\\n\";\nexit 1;\n");   # no bash in this container
    chmod 0755, $hook;
    write_rel($dir, 'src/in.txt', "a\ndirty\n");
    my $before = count_commits($dir);
    my $r = ck(root => $dir, pkg => 'b02-x', write_set => 'src/', status => 'running', step => 1, now => EPOCH);
    is(ck_err(root => $dir, pkg => 'b02-x', write_set => 'src/', status => 'running', now => EPOCH), '',
       'AC-14 a rejecting pre-commit hook does not raise an exception');
    is(hv($r, 'ok'),        0,               'AC-14 hook rejection -> ok=0');
    is(hv($r, 'status'),    'error',         'AC-14 hook rejection -> status=error');
    is(hv($r, 'reason'),    'commit-failed', "AC-14 hook rejection -> reason='commit-failed'");
    is(hv($r, 'committed'), 0,               'AC-14 hook rejection -> committed=0');
    is(hv($r, 'exit'),      3,               'AC-14 hook rejection -> exit=3');
    my $detail = ref($r) eq 'HASH' ? ($r->{detail} // '') : undef;
    ok(defined($detail) && length($detail),  'AC-14 detail carries the first line of the git output');
    ok(defined($detail) && length($detail) && length($detail) <= 200 && $detail !~ /\n/,
       'AC-14 detail is a single line trimmed to <= 200 chars');
    is(count_commits($dir), $before,         'AC-14 no new commit was created');
}

# ===========================================================================
# PASS 3 — the CLI contract (§2.8). Always `system`/exec LIST form, never a shell.
# ===========================================================================
{
    ok(-f $SCRIPT, 'AC-15 bp-checkpoint.pl exists and is runnable as a script');

    my $dir = mk_repo(files => { 'src/in.txt' => "a\n" });
    write_rel($dir, 'src/in.txt', "a\ndirty\n");
    my $before = count_commits($dir);

    # --key=value form
    my ($o1, $x1) = run_cli('--pkg=cli-a', '--write-set=src/', '--root=' . $dir, '--status=running',
                            '--step=2', '--now=' . EPOCH);
    is($x1, 0, 'AC-15 CLI exits 0 when it committed');
    is(hv(jline($o1), 'status'), 'committed', 'AC-15 CLI prints one JSON line whose status is committed');
    is(count_commits($dir), $before + 1, 'AC-15 the CLI really made the commit');

    # --key value form, now on a clean tree
    my ($o2, $x2) = run_cli('--pkg', 'cli-a', '--write-set', 'src/', '--root', $dir,
                            '--status', 'running', '--step', '2', '--now', EPOCH);
    is($x2, 1, 'AC-15 CLI exits 1 on a clean tree (nothing committed, non-error)');
    is(hv(jline($o2), 'status'), 'clean', 'AC-15 CLI clean-tree JSON status is clean');
    is(hv(jline($o2), 'reason'), 'clean-tree', 'AC-15 CLI clean-tree JSON reason is clean-tree');
    is(count_commits($dir), $before + 1, 'AC-15 the clean-tree CLI run added no commit');

    # missing --pkg -> usage (the `unlike` half proves the 2 came from the CLI's own
    # usage guard and not from perl failing to open a missing script).
    my ($o3, $x3) = run_cli('--write-set=src/', '--root=' . $dir);
    ok($x3 == 2 && $o3 !~ /Can't open perl script/,
       'AC-15 CLI exits 2 when --pkg is missing (usage)');
    my ($o3b, $x3b) = run_cli('--pkg=cli-a', '--write-set=src/', '--root=' . $dir, '--bogus');
    ok($x3b == 2 && $o3b !~ /Can't open perl script/,
       'AC-15 CLI exits 2 on an unknown option (usage)');

    # a non-repo root -> git error
    my $plain = "$ROOT/cli-not-a-repo";
    make_path($plain);
    my ($o4, $x4) = run_cli('--pkg=cli-a', '--write-set=src/', '--root=' . $plain);
    is($x4, 3, 'AC-15 CLI exits 3 against a non-repo root');
    is(hv(jline($o4), 'status'), 'error',      'AC-15 CLI non-repo JSON status is error');
    is(hv(jline($o4), 'reason'), 'not-a-repo', 'AC-15 CLI non-repo JSON reason is not-a-repo');
}

# ===========================================================================
# PASS 4 — the orchestrator: tunable, seam, triggers, logging (§2.9-§2.12).
# ===========================================================================

my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });
my $bpn = 0;

# write_ledger($dir, $pkg, $status, $write_set, $boxes) — $boxes ticked pipeline boxes.
sub write_ledger {
    my ($dir, $pkg, $status, $ws, $boxes) = @_;
    $boxes //= 0;
    my $body = "\n## Pipeline\n" . join('', map { "- [x] step $_\n" } 1 .. $boxes) . "- [ ] next\n";
    spit("$dir/packages/$pkg.md",
         "---\npackage: $pkg\nblueprint: T\nstatus: $status\nwrite_set: $ws\ntest_paths: $ws\n"
       . "last_updated: 2026-06-24T00:00:00Z\n---\n# $pkg\n\n## Next action\n\ngo\n" . $body);
    return "$dir/packages/$pkg.md";
}

# mk_bp([[name, deps, status, write_set, boxes], ...], \%registry) -> blueprint dir
sub mk_bp {
    my ($pkgs, $registry) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    make_path("$dir/packages");
    make_path("$dir/runs");
    open my $b, '>', "$dir/blueprint.md" or die "blueprint: $!";
    print $b "# T\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->[0] | d | $_->[1] | sonnet | $_->[2] |\n" for @$pkgs;
    close $b;
    write_ledger($dir, $_->[0], $_->[2], $_->[3], $_->[4]) for @$pkgs;
    spit("$dir/runs/registry.json", $J->encode({ packages => $registry })) if $registry;
    spit("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 100 * 3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
    return $dir;
}

# `flat` is deliberately far above any simulated span so the existing watchdog
# never cold-relaunches the "wedged" (live but quiet) package out of @live before
# the checkpoint interval elapses (spec §4 harness rules).
sub tun {
    my ($dir, %o) = @_;
    return { ceil5 => 85, ceil7 => 90, drain => 600, max_par => 5, cap => 5, flat => 10_000_000,
             watch_tick => 0, keeper_int => 100_000, keeper_bo => 120, thresh_min => 60, jit_lo => 0,
             jit_hi => 0, tele_retry => 3, usage_fail => 60, busy_path => "$dir/busy", harvest => 'audit',
             resolve_cap => 1, corr_cap => 1, judge_to => 100_000, judge_spawn_cap => 3, %o };
}

# bump a ledger's mtime STRICTLY forward (a rewrite alone may land in the same
# second; the fake clock may sit behind the fixture's real mtime).
sub touch_forward {
    my ($f) = @_;
    my $m = (stat $f)[9] // time;
    utime $m + 2, $m + 2, $f;
}

sub grow_jsonl {
    my ($dir, $pkg, $clock) = @_;
    my $f = "$dir/runs/$pkg.jsonl";
    open my $w, '>>', $f or return;
    print $w "x";
    close $w;
    utime $clock, $clock, $f;
}

sub log_events {
    my ($dir) = @_;
    my $c = slurp_raw("$dir/runs/orchestrator.log");
    return () unless defined $c;
    return map { eval { $UJ->decode($_) } || {} } grep { /\S/ } split /\n/, $c;
}
sub log_of { my ($dir, $type) = @_; return grep { ($_->{type} // '') eq $type } log_events($dir) }

# drive(...) — ONE BpOrch::run() across several ticks with a fake clock (§2.11:
# %ckpt is loop-scope, so repeated once=>1 calls could never observe a periodic
# checkpoint). The sleep seam advances the clock, runs an optional per-tick world
# mutation, and finally dies "STOP\n" — t/20's `once => 0` + sleep-sentinel shape.
sub drive {
    my (%o) = @_;
    my $dir   = $o{dir};
    my $step  = $o{step} // 100;
    my $stop  = $o{stop} // 2;
    my $clock = $NOW;
    my $ticks = 0;
    my (@calls, @launched);
    my $err;

    my %opt = (
        blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
        tunables  => ($o{tunables} || tun($dir)),
        once      => ($o{once} ? 1 : 0),
        now       => sub { $clock },
        sleep     => sub {
            $ticks++;
            $clock += $step;
            $o{on_tick}->($dir, $ticks, $clock) if $o{on_tick};
            die "STOP\n" if $ticks >= $stop;
        },
        http_get  => sub { { status => 200, content => $USAGE_OK } },
        http_post => sub { { status => 200, content => '{}' } },
        launch    => sub { my ($a) = @_;
                           push @launched, { pkg => $a->{pkg}, kind => $a->{kind}, clock => $clock };
                           return $o{launch} ? $o{launch}->($a, $clock) : 0 },
        pid_alive => ($o{pid_alive} || sub { (defined $_[0] && $_[0] >= 777_000) ? 1 : 0 }),
        spawn_judge => sub { 0 },
    );
    unless ($o{no_checkpoint}) {
        $opt{checkpoint} = sub {
            my ($a) = @_;
            push @calls, { (ref($a) eq 'HASH' ? %$a : (BAD_ARG => "$a")), _clock => $clock };
            die "recorder boom\n" if $o{die_in_recorder};
            return ref($o{result}) eq 'CODE'  ? $o{result}->($a)
                 : ref($o{result}) eq 'HASH'  ? $o{result}
                 : { ok => 1, status => 'committed', committed => 1, sha => ('a' x 40),
                     message => 'wip(x): running @ step 1' };
        };
    }
    $opt{project_root} = $o{project_root} if exists $o{project_root};

    eval { BpOrch::run(\%opt); 1 } or $err = $@;
    return { dir => $dir, calls => \@calls, launched => \@launched, ticks => $ticks,
             err => ($err // ''), log => slurp("$dir/runs/orchestrator.log") };
}
sub ck_pkgs { my ($r) = @_; return [ map { $_->{pkg} // 'NO-PKG' } @{ $r->{calls} } ] }

my $LIVE_REG = { livep => { attempt => 1, pid => 777_001, status => 'running', session_id => 'sid-l' } };
my $WS_RAW   = 'src/live/:docs/live.md';        # a RAW ledger string, colon and all

# ---- AC-16: the ckpt_int tunable (§2.10) ----------------------------------
{
    {
        delete local $ENV{BP_CHECKPOINT_INTERVAL};
        is(hv(sc(sub { BpOrch::_tunables_base() }), 'ckpt_int'), 300,
           'AC-16 _tunables_base()->{ckpt_int} defaults to 300');
    }
    {
        local $ENV{BP_CHECKPOINT_INTERVAL} = 7;
        is(hv(sc(sub { BpOrch::_tunables_base() }), 'ckpt_int'), 7,
           'AC-16 BP_CHECKPOINT_INTERVAL=7 makes ckpt_int 7');
    }
    {
        delete local $ENV{BP_CHECKPOINT_INTERVAL};
        my $runs = "$ROOT/tun-runs";
        make_path($runs);
        spit("$runs/.tunables", '{"ckpt_int":1,"max_par":3}');
        my $t = sc(sub { BpOrch::_tunables($runs) });
        is(hv($t, 'ckpt_int'), 300, 'AC-16 a runs/.tunables carrying ckpt_int is IGNORED (whitelist contract)');
        is(hv($t, 'max_par'),  3,   'AC-16 the whitelisted max_par from the same .tunables IS applied');
    }
    my $dir = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2]], $LIVE_REG);
    my $r = drive(dir => $dir, once => 1, tunables => tun($dir));    # tunables literal has NO ckpt_int
    is($r->{err}, '', 'AC-16 a tick with an injected tunables hash lacking ckpt_int still completes (no-regression)');
}

# ---- AC-17: the first observation SEEDS, it never commits -----------------
{
    my $dir = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2]], $LIVE_REG);
    my $r = drive(dir => $dir, once => 1, tunables => tun($dir, ckpt_int => 1));
    is($r->{err}, '', 'AC-17 the first tick completes without dying');
    is(scalar @{ $r->{calls} }, 0,
       'AC-17 first tick with a live package -> ZERO checkpoint calls (seed only, no commit storm)');
}

# ---- AC-18: the periodic floor -------------------------------------------
{
    my $dir = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2]], $LIVE_REG);
    my $r = drive(dir => $dir, stop => 2, step => 100, tunables => tun($dir, ckpt_int => 5),
                  on_tick => sub { grow_jsonl($_[0], 'livep', $_[2]) });
    is($r->{err}, "STOP\n", 'AC-18 the periodic run ended on the harness sentinel (2 ticks, one run())');
    is(scalar @{ $r->{calls} }, 1, 'AC-18 a tick at seed + ckpt_int -> EXACTLY ONE checkpoint call');
    my $c = $r->{calls}[0] || {};
    is(hv($c, 'trigger'),   'periodic',    "AC-18 trigger='periodic' (the interval elapsed, the ledger did not move)");
    is(hv($c, 'pkg'),       'livep',       'AC-18 args carry pkg');
    is(hv($c, 'write_set'), $WS_RAW,       'AC-18 args carry the RAW ledger write_set string');
    is(hv($c, 'status'),    'in-progress', 'AC-18 args carry the ledger status');
    is(hv($c, 'step'),      2,             'AC-18 args carry step = the ticked-checkbox count');
    is(hv($c, 'now'),       $NOW + 100,    'AC-18 args carry now = the injected clock for that tick');

    # ... and a run whose ticks all stay below seed + ckpt_int commits nothing,
    # even though the coordinator's jsonl keeps growing (jsonl_size is NOT a trigger).
    my $dir2 = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2]], $LIVE_REG);
    my $r2 = drive(dir => $dir2, stop => 4, step => 100, tunables => tun($dir2, ckpt_int => 100_000),
                   on_tick => sub { grow_jsonl($_[0], 'livep', $_[2]) });
    is($r2->{ticks}, 4, 'AC-18 the below-interval run really executed 4 ticks');
    is(scalar @{ $r2->{calls} }, 0, 'AC-18 ticks below seed + ckpt_int -> ZERO checkpoint calls');
}

# ---- AC-19: the ledger-advance trigger ------------------------------------
{
    my $dir = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2]], $LIVE_REG);
    my $r = drive(dir => $dir, stop => 2, step => 1, tunables => tun($dir, ckpt_int => 100_000),
                  on_tick => sub {
                      my ($d, $n, $clock) = @_;
                      return unless $n == 1;
                      write_ledger($d, 'livep', 'in-progress', $WS_RAW, 3);   # one more ticked box
                      touch_forward("$d/packages/livep.md");
                  });
    is(scalar @{ $r->{calls} }, 1,
       'AC-19 a ledger advance below the interval -> EXACTLY ONE checkpoint call');
    is(hv(($r->{calls}[0] || {}), 'trigger'), 'ledger', "AC-19 trigger='ledger'");
    is(hv(($r->{calls}[0] || {}), 'step'),    3,        'AC-19 the call carries the NEW checkbox count');

    # a status change is equally an advance
    my $dir2 = mk_bp([['livep', '-', 'pending', $WS_RAW, 2]], $LIVE_REG);
    my $r2 = drive(dir => $dir2, stop => 2, step => 1, tunables => tun($dir2, ckpt_int => 100_000),
                   on_tick => sub {
                       my ($d, $n, $clock) = @_;
                       return unless $n == 1;
                       write_ledger($d, 'livep', 'in-progress', $WS_RAW, 2);
                       touch_forward("$d/packages/livep.md");
                   });
    is(scalar @{ $r2->{calls} }, 1, 'AC-19 a status change below the interval -> exactly one checkpoint call');
    is(hv(($r2->{calls}[0] || {}), 'trigger'), 'ledger', "AC-19 status change -> trigger='ledger'");
    is(hv(($r2->{calls}[0] || {}), 'status'),  'in-progress', 'AC-19 the call carries the NEW ledger status');
}

# ---- AC-20: both triggers on the same tick -> ONE call, trigger 'both' ----
{
    my $dir = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2]], $LIVE_REG);
    my $r = drive(dir => $dir, stop => 2, step => 100, tunables => tun($dir, ckpt_int => 5),
                  on_tick => sub {
                      my ($d, $n, $clock) = @_;
                      return unless $n == 1;
                      write_ledger($d, 'livep', 'in-progress', $WS_RAW, 4);
                      touch_forward("$d/packages/livep.md");
                  });
    is(scalar @{ $r->{calls} }, 1,
       'AC-20 interval elapsed AND ledger advanced -> EXACTLY ONE checkpoint call (one commit)');
    is(hv(($r->{calls}[0] || {}), 'trigger'), 'both', "AC-20 trigger='both'");
}

# ---- AC-21: only LIVE coordinators are checkpointed ----------------------
{
    my $dir = mk_bp([['livep',  '-', 'in-progress', 'src/live/',  2],
                     ['deadp',  '-', 'in-progress', 'src/dead/',  2],
                     ['donep',  '-', 'done',        'src/done/',  2],
                     ['nopidp', '-', 'in-progress', 'src/nopid/', 2],
                     ['freshp', '-', 'pending',     'src/fresh/', 0]],
                    { livep  => { attempt => 1, pid => 777_001, status => 'running', session_id => 'sid-l' },
                      deadp  => { attempt => 1, pid => 555_001, status => 'running', session_id => 'sid-d' },
                      donep  => { attempt => 1, pid => 777_002, status => 'running', session_id => 'sid-o' },
                      nopidp => { attempt => 1,                 status => 'running', session_id => 'sid-n' } });
    my $r = drive(dir => $dir, stop => 3, step => 100, tunables => tun($dir, ckpt_int => 5),
                  on_tick => sub { grow_jsonl($_[0], $_, $_[2]) for qw(livep deadp donep nopidp) });
    my %seen = map { $_ => 1 } @{ ck_pkgs($r) };
    cmp_ok(scalar @{ $r->{calls} }, '>=', 1, 'AC-21 control: the one genuinely live package IS checkpointed');
    is_deeply([sort keys %seen], ['livep'], 'AC-21 ONLY the live package was checkpointed');
    ok(!$seen{deadp},  'AC-21 zero calls for a package whose pid_alive is false');
    ok(!$seen{donep},  'AC-21 zero calls for a package with a terminal ledger status (done)');
    ok(!$seen{nopidp}, 'AC-21 zero calls for a package with no registry pid');
    ok(!$seen{freshp}, 'AC-21 zero calls for a package that was never launched');
}
{
    # "launched during that same tick" — the seam registers a LIVE pid, so the
    # package is live from the NEXT tick on; it must not be checkpointed on the
    # tick it was launched (nor on its seed tick).
    my $dir = mk_bp([['newp', '-', 'pending', 'src/new/', 0]]);
    my $r = drive(dir => $dir, stop => 3, step => 100, tunables => tun($dir, ckpt_int => 5),
                  launch => sub { BpOrch::update_registry_pkg("$dir/runs", 'newp',
                                     { pid => 777_010, status => 'running', attempt => 1, session_id => 'sid-w' }); 0 },
                  on_tick => sub { grow_jsonl($_[0], 'newp', $_[2]) });
    my @launch_clocks = map { $_->{clock} } @{ $r->{launched} };
    is(scalar(grep { $_ == $NOW } @launch_clocks), 1, 'AC-21 fixture: the package was launched on tick 1');
    is(scalar(grep { ($_->{now} // -1) == $NOW } @{ $r->{calls} }), 0,
       'AC-21 a package launched during THAT tick is not checkpointed on its launch tick');
    is(scalar(grep { ($_->{now} // -1) == $NOW + 100 } @{ $r->{calls} }), 0,
       'AC-17 the tick that first observes it live only SEEDS');
    is(scalar @{ $r->{calls} }, 1, 'AC-18 it is checkpointed once the interval elapses (tick 3)');
}

# ---- AC-22 / AC-24: logging of committed vs clean outcomes ---------------
{
    my $dir = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2]], $LIVE_REG);
    my $r = drive(dir => $dir, stop => 2, step => 100, tunables => tun($dir, ckpt_int => 5),
                  result => { ok => 1, status => 'committed', committed => 1, sha => ('b' x 40),
                              message => 'wip(livep): in-progress @ step 2' });
    my @ev = log_of($dir, 'checkpoint');
    is(scalar @ev, 1, 'AC-22 a committed result logs exactly one "checkpoint" event');
    my $e = @ev ? $ev[0] : {};
    is(hv($e, 'package'), 'livep',      'AC-22 the checkpoint event carries package');
    is(hv($e, 'trigger'), 'periodic',   'AC-22 the checkpoint event carries trigger');
    is(hv($e, 'sha'),     ('b' x 40),   'AC-22 the checkpoint event carries the sha from the result');
    is(scalar(log_of($dir, 'checkpoint_failed')), 0, 'AC-22 a committed result logs no checkpoint_failed');

    my $dir2 = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2]], $LIVE_REG);
    my $r2 = drive(dir => $dir2, stop => 2, step => 100, tunables => tun($dir2, ckpt_int => 5),
                   result => { ok => 1, status => 'clean', committed => 0, reason => 'clean-tree' });
    is(scalar @{ $r2->{calls} }, 1, 'AC-24 fixture: the checkpoint seam was called once');
    is(scalar(log_of($dir2, 'checkpoint')), 0,        'AC-24 a clean result logs NO checkpoint event');
    is(scalar(log_of($dir2, 'checkpoint_failed')), 0, 'AC-24 a clean result logs NO checkpoint_failed event');
}

# ---- AC-23: failures are logged and the tick carries on ------------------
{
    my $dir = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2],
                     ['pend',  '-', 'pending',     'src/pend/', 0]], $LIVE_REG);
    my $r = drive(dir => $dir, stop => 2, step => 100, tunables => tun($dir, ckpt_int => 5),
                  result => { ok => 0, status => 'error', committed => 0, reason => 'not-a-repo',
                              detail => 'fatal: not a git repository' });
    is($r->{err}, "STOP\n", 'AC-23 run() returned normally (only the harness sentinel), it never aborted');
    my @ev = log_of($dir, 'checkpoint_failed');
    is(scalar @ev, 1, 'AC-23 a failing result logs exactly one "checkpoint_failed" event');
    my $e = @ev ? $ev[0] : {};
    is(hv($e, 'package'), 'livep',      'AC-23 checkpoint_failed carries package');
    is(hv($e, 'reason'),  'not-a-repo', "AC-23 checkpoint_failed carries the result's reason");
    like((hv($e, 'detail') // ''), qr/not a git repository/, 'AC-23 checkpoint_failed carries the detail');
    is(scalar(log_of($dir, 'checkpoint')), 0, 'AC-23 a failing result logs no success event');

    my $ck_clock = @{ $r->{calls} } ? ($r->{calls}[0]{now} // -1) : -1;
    is(scalar(grep { $_->{pkg} eq 'pend' && $_->{clock} == $ck_clock } @{ $r->{launched} }), 1,
       'AC-23 the LAUNCH section still ran on the very tick the checkpoint failed');
    is(scalar(grep { $_->{pkg} eq 'pend' } @{ $r->{launched} }), 2,
       'AC-23 the ready package was launched on both ticks (the tick never short-circuits)');

    # ... and a checkpoint closure that DIES is caught and classified.
    my $dir2 = mk_bp([['livep', '-', 'in-progress', $WS_RAW, 2],
                      ['pend',  '-', 'pending',     'src/pend/', 0]], $LIVE_REG);
    my $r2 = drive(dir => $dir2, stop => 2, step => 100, tunables => tun($dir2, ckpt_int => 5),
                   die_in_recorder => 1);
    is($r2->{err}, "STOP\n", 'AC-23 a checkpoint closure that dies does not propagate out of run()');
    my @ev2 = log_of($dir2, 'checkpoint_failed');
    is(scalar @ev2, 1, 'AC-23 a dying closure logs exactly one checkpoint_failed');
    is(hv((@ev2 ? $ev2[0] : {}), 'reason'), 'exception', "AC-23 a dying closure is classified reason='exception'");
    like((hv((@ev2 ? $ev2[0] : {}), 'detail') // ''), qr/recorder boom/,
         'AC-23 the exception detail is the first line of $@');
    is(scalar(grep { $_->{pkg} eq 'pend' } @{ $r2->{launched} }), 2,
       'AC-23 the rest of the tick still executes after a dying checkpoint closure');
}

# ---- AC-25: end-to-end through the DEFAULT closure ------------------------
{
    my $repo = mk_repo(files => { 'src/live/w.txt' => "committed\n" });
    write_rel($repo, 'src/live/w.txt', "committed\nin flight\n");     # dirty write-set file
    my $before = count_commits($repo);

    my $dir = mk_bp([['livep', '-', 'in-progress', 'src/live/', 2]], $LIVE_REG);
    my $r = drive(dir => $dir, stop => 2, step => 100, tunables => tun($dir, ckpt_int => 5),
                  no_checkpoint => 1, project_root => $repo,
                  on_tick => sub { grow_jsonl($_[0], 'livep', $_[2]) });
    is($r->{err}, "STOP\n", 'AC-25 the default-closure run ended on the harness sentinel');
    is(count_commits($repo), $before + 1,
       'AC-25 the DEFAULT closure made exactly one real commit in project_root');
    like(head_fmt($repo, '%B'), qr/^\Qwip(livep): \E/,
         'AC-25 the real commit message starts with wip(<pkg>): ');
    is_deeply(head_files($repo), ['src/live/w.txt'], 'AC-25 the real commit contains the dirty write-set file');
    is(scalar(log_of($dir, 'checkpoint')), 1, 'AC-25 the default closure produced a checkpoint log record');
}

# ---- AC-26: done-criterion (e) — a coordinator dying mid-step ------------
{
    my $repo = mk_repo(files => { 'src/live/w.txt' => "committed\n" });
    write_rel($repo, 'src/live/w.txt', "committed\nhalf-written step\n");
    my $before = count_commits($repo);

    my %alive = (777_001 => 1);
    my $dir = mk_bp([['livep', '-', 'in-progress', 'src/live/', 2]], $LIVE_REG);
    my $r = drive(dir => $dir, stop => 3, step => 100, tunables => tun($dir, ckpt_int => 50),
                  no_checkpoint => 1, project_root => $repo,
                  pid_alive => sub { (defined $_[0] && $alive{$_[0]}) ? 1 : 0 },
                  on_tick => sub {
                      my ($d, $n, $clock) = @_;
                      grow_jsonl($d, 'livep', $clock);
                      if ($n == 2) {                        # the coordinator dies mid-step
                          delete $alive{777_001};
                          write_rel($repo, 'src/live/w.txt', "committed\nhalf-written step\nmore\n");
                      }
                  });
    is($r->{err}, "STOP\n", 'AC-26 the run survived the coordinator death (ticks T, T+int, T+int+1)');
    is(count_commits($repo), $before + 1,
       'AC-26 exactly one WIP commit exists — made at T+ckpt_int, while the coordinator was still live');
    like(head_fmt($repo, '%B'), qr/^\Qwip(livep): \E/, 'AC-26 that commit is the packages WIP checkpoint');
    is_deeply(head_files($repo), ['src/live/w.txt'],
              'AC-26 the in-flight write-set file is inside that prior WIP commit');
    unlike(slurp("$dir/packages/livep.md"), qr/^status:\s*(?:done|blocked|parked)\s*$/m,
           'AC-26 the packages ledger status never became terminal (it died mid-step)');
}

# ===========================================================================
# PASS 5 — source/doc contracts and the preserved baseline (§2.13, house rules).
# ===========================================================================

# ---- AC-27: no AI-authorship trailer, no shell ---------------------------
{
    my $src  = slurp_raw($SCRIPT) // '';
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;      # comment lines stripped
    my $orch = slurp_raw($ORCH)   // '';
    my $doc  = slurp_raw($SKILL)  // '';

    ok(length($src) && $src !~ /Co-?Authored-?By/i,
       'AC-27 bp-checkpoint.pl exists and contains no Co-Authored-By');
    ok(length($orch) && $orch !~ /Co-?Authored-?By/i,
       'AC-27 bp-orchestrator.pl contains no Co-Authored-By');
    ok(length($doc) && $doc !~ /Co-?Authored-?By/i,
       'AC-27 orchestrator-protocol/SKILL.md contains no Co-Authored-By');
    ok(length($src) && $code !~ /bash/i,
       'AC-27 bp-checkpoint.pl never mentions bash in code (there is no bash in this container)');
    ok(length($src) && $code !~ /\bsh\s+-c\b/,
       'AC-27 bp-checkpoint.pl never shells out via sh -c');
    ok(length($src) && $code !~ /(?:^|[^\w\-])cd\s+\S/m,
       'AC-27 bp-checkpoint.pl never cd-chains (git is always invoked as `git -C <root>`)');
}

# ---- AC-28: SKILL.md documents the discipline (§2.13) -------------------
{
    my $doc = slurp_raw($SKILL) // '';
    like($doc, qr/^name:\s*orchestrator-protocol\s*$/m, 'AC-28 SKILL.md frontmatter still reads name: orchestrator-protocol');
    my ($sec) = $doc =~ /^(###[^\n]*[Cc]heckpoint[^\n]*\n.*?)(?=^#{1,3}\s|\z)/ms;
    $sec = '' unless defined $sec;
    ok(length $sec, 'AC-28 SKILL.md has a ### section about checkpoint commits');
    like($sec, qr/BP_CHECKPOINT_INTERVAL/,          'AC-28 the section names the BP_CHECKPOINT_INTERVAL knob');
    like($sec, qr/\b300\b|interval/i,               'AC-28 the section describes the periodic-interval trigger');
    like($sec, qr/ledger/i,                         'AC-28 the section describes the ledger-advance trigger');
    like($sec, qr/\Qwip(\E/,                        'AC-28 the section shows the literal wip( message shape');
    like($sec, qr/write.set/i,                      'AC-28 the section states that only the write set is staged');
    like($sec, qr/rebase -i|reset --soft/,          'AC-28 the section explains how to squash the WIP commits');
    like($sec, qr/checkpoint_failed/,               'AC-28 the section names the checkpoint_failed log event');
    like($sec, qr/rebuild/i,                        'AC-28 the section covers recovery after a container rebuild');
}

# ---- AC-29: the pre-existing baseline is untouched ----------------------
{
    my @baseline = qw(
        01-contract.t 02-preflight.t 03-govern.t 04-log.t 05-keeper.t 06-orchestrator.t
        07-http.t 08-orchestrator-scenarios.t 09-gate.t 10-judges.t 11-simulation.t
        12-wait-for-decision.t 13-answer-decision.t 14-hooks-selftest.t
        15-orchestrate-shutdown-clear.t 16-oauth-sandbox-preflight.t 17-drive-next.t
        18-usage-governor.t 19-drive-integration.t 20-deps-check.t
        20-orchestrator-broken-env-turns.t );
    my @missing = grep { !-f "$TDIR/$_" } @baseline;
    is_deeply(\@missing, [], 'AC-29 all 21 pre-existing test files are still present');
    ok(-f "$TDIR/21-durable-checkpoint-commits.t", 'AC-29 the new assertions live in a NEW file');
    opendir(my $dh, $TDIR) or die "opendir $TDIR: $!";
    my @all = sort grep { /\.t$/ } readdir $dh;
    closedir $dh;
    cmp_ok(scalar @all, '>=', scalar(@baseline) + 1, 'AC-29 the suite gained a file rather than replacing one');
    my @polluted = grep { (slurp_raw("$TDIR/$_") // '') =~ /BpCheckpoint|bp-checkpoint|ckpt_int/ } @baseline;
    is_deeply(\@polluted, [],
              'AC-29 no pre-existing test file was edited to carry this package assertions');
}

done_testing();
