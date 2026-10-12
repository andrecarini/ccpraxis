#!/usr/bin/env perl
# platform: any
# ORACLE for blueprint where-things-go, package 01-inbox-rename: the new
# almanac-inbox.pl file itself (load-time BEGIN block / module shape, AC5,
# AC6), the legacy-store migration (AC13-AC19), the hard cutover of
# almanac-decision.pl as a direct invocation / require target (AC21), the
# "nothing aliases" sweep (AC24), and the whole-repo lint for user-facing
# "decision" meaning an inbox item (AC31-AC33). Derived ONLY from
# specs/01-inbox-rename-spec.md sections 2.1, 2.2, 2.6, 2.7 and acceptance
# criteria AC5, AC6, AC13-AC24, AC31-AC33 -- NOT from reading almanac-inbox.pl,
# which this package's write set had not written yet at authoring time.
#
# AMENDMENT (tooling-backlog package 13, Decision 71/65; cross-blueprint
# supersession per where-things-go Decision 62): AC5's expectations below were
# narrowly updated, by a test-writer dispatch, to match almanac-inbox.pl's
# ACTUAL fixed BEGIN block after package 13 fixed bug 20261001-184636-75fe
# (a relative __FILE__) via Cwd::abs_path(__FILE__). This is the one
# deliberate, pre-specified exception to the "derived only from the spec"
# rule above -- every other section of this file is unchanged and remains
# spec-derived, oracle, not-implementation-derived.
#
# HOUSE PATTERN for a not-yet-built script: every call into the CLI or the
# module is wrapped in eval{} / run_cli() so "Undefined subroutine" / "Can't
# open perl script" is a caught, reported failure for THIS assertion rather
# than an abort of the whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Find ();
use Cwd ();
use Encode ();
use Digest::SHA qw(sha256_hex);
use POSIX qw(WNOHANG);
use Time::HiRes ();

my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{BP_PROJECT_ROOT};
delete local $ENV{BP_LEDGER};
delete local $ENV{CLAUDE_CODE_SESSION_ID};

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
(my $PLUGIN_ROOT = "$Bin/../..") =~ s{\\}{/}g;
(my $BUTLER_ROOT = "$Bin/../../../butler") =~ s{\\}{/}g;
(my $REPO_ROOT   = "$Bin/../../../..") =~ s{\\}{/}g;
# File::Find::find builds $File::Find::name by string-concatenating the root
# it is given with each relative path it discovers -- it does NOT resolve
# ".." itself. $Bin is .../plugins/almanac/tests/t, so an un-resolved root
# here would make every $File::Find::name contain the literal substring
# "/tests/t/../.." forever, which permanently matches the m{/tests/}
# exclusion filter below and silently empties the whole scan. Canonicalize
# before using these as File::Find roots -- and canonicalize $S too, since
# $INBOX_PL/$DECISION_PL/$ALMANAC_PL (built from it below) are compared via
# string `eq` against canonical $File::Find::name values elsewhere in this
# file (e.g. the `$f eq $DECISION_PL` exclusion in the AC31 scan-file
# collector), and that comparison silently fails if the two sides are
# canonicalized inconsistently.
for my $root_ref (\$S, \$PLUGIN_ROOT, \$BUTLER_ROOT, \$REPO_ROOT) {
    my $abs = Cwd::abs_path($$root_ref);
    if (defined $abs) {
        $abs =~ s{\\}{/}g;
        $$root_ref = $abs;
    }
}
my $INBOX_PL    = "$S/almanac-inbox.pl";
my $DECISION_PL = "$S/almanac-decision.pl";
my $ALMANAC_PL  = "$S/almanac.pl";

# Almanac::Store/Record/Lock are shared infra (package 08, unaffected by this
# rename; spec 2.7: "Store.pm needs no code change") -- require them directly
# so fixture helpers below do not depend on almanac-inbox.pl existing.
unshift @INC, $S;
eval { require Almanac::Store; require Almanac::Lock };
diag("shared Almanac infra failed to load: $@") if $@;

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub slurp_raw {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_raw {
    my ($p, $bytes) = @_;
    open my $fh, '>:raw', $p or die "fixture: cannot write $p: $!";
    print {$fh} $bytes;
    close $fh;
}
sub read_all_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}
sub norm_root {
    my ($p) = @_;
    my $abs = Cwd::abs_path($p);
    $abs = $p unless defined $abs;
    $abs =~ s{\\}{/}g;
    $abs =~ s{/\z}{};
    $abs =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    return $abs;
}
sub mk_root { my $t = tempdir(CLEANUP => 1); return norm_root($t); }

sub run_cli {
    my ($pl, @args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $pid = fork();
    die "run_cli: fork() failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $outpath) or POSIX::_exit(126);
        open(STDERR, '>', $errpath) or POSIX::_exit(126);
        exec($^X, $pl, @args) or POSIX::_exit(127);
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;
    my $out = slurp_raw($outpath);
    my $err = slurp_raw($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}
sub run_inbox { return run_cli($INBOX_PL, @_) }

sub field2 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}

sub inbox_dir_for    { return norm_root($_[0]) . '/.ccpraxis-local-data/almanac/inbox' }
sub decision_dir_for { return norm_root($_[0]) . '/.ccpraxis-local-data/almanac/decision' }

sub md_files_in {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return @f;
}

# snapshot_dir($dir) -> { exists, entries => { relpath => "sha256" } } --
# recursive, over every regular file (records AND their sidecars).
sub snapshot_dir {
    my ($dir) = @_;
    return { exists => 0, entries => {} } unless -d $dir;
    my %seen;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full; next }
            my $bytes = slurp_raw($full);
            (my $rel = $full) =~ s{\\}{/}g;
            $rel =~ s{\A\Q$dir\E/}{};
            $seen{$rel} = defined($bytes) ? sha256_hex($bytes) : undef;
        }
        closedir $dh;
    }
    return { exists => 1, entries => \%seen };
}

sub open_decision_store {
    my ($root) = @_;
    return Almanac::Store->open(scope => 'project', type => 'decision', root => $root);
}

# ---------------------------------------------------------------------------
# precondition
# ---------------------------------------------------------------------------
ok(-f $INBOX_PL, 'precondition: almanac-inbox.pl exists at plugins/almanac/scripts/almanac-inbox.pl')
    or diag('almanac-inbox.pl is not present yet -- every assertion below that depends on it is '
          . 'expected to fail for exactly that reason.');

# =============================================================================
# AC5 -- the BEGIN block is byte-identical to the FIXED shape (bug
# 20261001-184636-75fe fixed, per tooling-backlog package 13, via
# Cwd::abs_path(__FILE__) instead of a possibly-relative __FILE__), a
# `require $TASK_PL;` line exists, and Cwd::abs_path is actually used to
# resolve the sibling path (confirming the fix landed, not just a mention).
#
# SECOND AMENDMENT (2026-10-12): the pinned line now normalises separators
# BEFORE abs_path, the shape turn-cap-consistency.t C9 requires of every source
# (a raw `Cwd::abs_path(__FILE__)` is what C9 bans). The two oracles pinned
# contradictory lines; AC5's intent -- __FILE__ resolved through abs_path,
# never left relative -- is unchanged.
# =============================================================================
{
    my $EXPECT_BEGIN = <<'BLOCK';
my $TASK_PL;
BEGIN {
    my $dir = do { (my $f = __FILE__) =~ s{\\}{/}g; Cwd::abs_path($f) // $f };
    $dir =~ s{\\}{/}g;
    $dir = ($dir =~ m{/}) ? ($dir =~ s{/[^/]+\z}{}r) : '.';
    unshift @INC, $dir;
    $TASK_PL = "$dir/almanac-task.pl";
}
BLOCK
    if (-f $INBOX_PL) {
        my $src = slurp_raw($INBOX_PL) // '';
        ok(index($src, $EXPECT_BEGIN) >= 0, 'AC5: the file contains the fixed BEGIN block verbatim (bug 20261001-184636-75fe fixed via Cwd::abs_path)')
            or diag('BEGIN block not found verbatim');
        like($src, qr/^require\s+\$TASK_PL;\s*$/m, 'AC5: the file contains a `require $TASK_PL;` line');
        like($src, qr/\(my \$f = __FILE__\)[^\n]*Cwd::abs_path\(\$f\)/, 'AC5: the file resolves __FILE__ through Cwd::abs_path (the fix for bug 75fe)');
    } else {
        fail($_) for (
            'AC5: the file contains the fixed BEGIN block verbatim (bug 20261001-184636-75fe fixed via Cwd::abs_path)',
            'AC5: the file contains a `require $TASK_PL;` line',
            'AC5: the file resolves __FILE__ through Cwd::abs_path (the fix for bug 75fe)',
        );
    }
}

# =============================================================================
# AC13 -- first use migrates A/decision -> A/inbox, one unanswered + one
# answered record plus sidecars, byte-for-byte (sha256) preserved; `list`
# reports both; A/decision no longer exists afterward.
# =============================================================================
my ($P13, $id_unans, $id_ans);
{
    $P13 = mk_root();
    eval {
        my $store = open_decision_store($P13);
        my $r1 = $store->create(id => 'legacy-unanswered', fields => { title => 'needs an answer', status => 'unanswered', created => '2024-01-01T00:00:00Z' },
                                 order => [qw(title status created)]);
        my $r2 = $store->create(id => 'legacy-answered', fields => { title => 'already answered', status => 'unanswered', created => '2024-01-01T00:00:00Z' },
                                 order => [qw(title status created)]);
        $store->update('legacy-answered', expect => { rev => $r2->{rev}, fields => $r2->{fields} },
                        set => { status => 'answered', answer => 'yes', answered_at => '2024-01-02T00:00:00Z' });
        $id_unans = 'legacy-unanswered';
        $id_ans   = 'legacy-answered';
    };
    ok(!$@, 'AC13 fixture: A/decision seeded with one unanswered and one answered record') or diag("error: $@");

    my $before_files = { map { $_ => 1 } md_files_in(decision_dir_for($P13)) };
    ok(scalar(keys %$before_files) >= 2, 'AC13 fixture: at least the two .md record files exist in A/decision')
        or diag('decision dir contents: ' . join(',', keys %$before_files));

    my $pre_snapshot = snapshot_dir(decision_dir_for($P13));

    my $r = run_inbox('list', '--root', $P13);
    is($r->{rc}, 0, 'AC13: almanac-inbox.pl list --root P (first use) exits 0') or diag("stderr: $r->{err}");
    like($r->{out}, qr/\Q$id_unans\E/, 'AC13: list reports the unanswered item\'s id') if defined $id_unans;
    like($r->{out}, qr/\Q$id_ans\E/, 'AC13: list reports the answered item\'s id') if defined $id_ans;
    like($r->{out}, qr/status:\sunanswered/, 'AC13: list reports an unanswered status');
    like($r->{out}, qr/status:\sanswered/, 'AC13: list reports an answered status');
    like($r->{out}, qr/answer:\syes/, 'AC13: list reports the answered item\'s answer');

    ok(!-e decision_dir_for($P13), 'AC13: A/decision no longer exists after the first use');
    ok(-d inbox_dir_for($P13), 'AC13: A/inbox exists after the first use');

    my $post_snapshot = snapshot_dir(inbox_dir_for($P13));
    is_deeply([ sort keys %{ $post_snapshot->{entries} } ], [ sort keys %{ $pre_snapshot->{entries} } ],
        'AC13: A/inbox holds the same relative file set as A/decision held before migration');
    is_deeply($post_snapshot->{entries}, $pre_snapshot->{entries},
        'AC13: every migrated file is byte-identical (sha256) to its pre-migration self');
}

# =============================================================================
# AC14 -- a second `list` is a pure no-op: identical stdout, and a full
# snapshot of A is unchanged by it.
# =============================================================================
{
    SKIP: {
        skip 'AC13 fixture did not complete', 3 unless defined $P13;
        my $r1 = run_inbox('list', '--root', $P13);
        (my $A = norm_root($P13)) .= '/.ccpraxis-local-data/almanac';
        my $snap_before = snapshot_dir($A);
        my $r2 = run_inbox('list', '--root', $P13);
        is($r2->{rc}, 0, 'AC14: the second list exits 0') or diag("stderr: $r2->{err}");
        is($r2->{out}, $r1->{out}, 'AC14: the second list\'s stdout is identical to the first (post-migration) list\'s');
        my $snap_after = snapshot_dir($A);
        is_deeply($snap_after, $snap_before, 'AC14: a full (name, sha) snapshot of A is unchanged by the second list');
    }
}

# =============================================================================
# AC15 -- library entry point: Almanac::Inbox::open_inbox(root => P) on a
# fresh A/decision-only fixture migrates and returns a store whose dir ends
# /inbox; A/decision is absent afterward.
# =============================================================================
{
    my $P15 = mk_root();
    eval {
        my $store = open_decision_store($P15);
        $store->create(fields => { title => 'lib migration target', status => 'unanswered', created => '2024-01-01T00:00:00Z' },
                        order => [qw(title status created)]);
    };
    ok(!$@, 'AC15 fixture: A/decision seeded with one record') or diag("error: $@");

    eval { require $INBOX_PL if -f $INBOX_PL };
    diag("almanac-inbox.pl failed to load: $@") if $@ && -f $INBOX_PL;

    my $store15 = eval { Almanac::Inbox::open_inbox(root => $P15) };
    ok(!$@, 'AC15: Almanac::Inbox::open_inbox(root => P) does not die') or diag("error: $@");
    if (defined $store15 && ref($store15)) {
        like($store15->dir, qr{/inbox\z}, 'AC15: the returned store\'s dir ends /inbox');
    } else {
        fail('AC15: the returned store\'s dir ends /inbox');
    }
    ok(!-e decision_dir_for($P15), 'AC15: A/decision is absent after the library open');
}

# =============================================================================
# AC16 -- both A/decision and A/inbox present: every inbox verb exits 2 with
# detail half_migrated; stdout empty; neither dir changes; a questions.md
# placed in the fixture is still there, unrenamed.
# =============================================================================
{
    my $P16 = mk_root();
    eval {
        my $dstore = open_decision_store($P16);
        $dstore->create(fields => { title => 'half-migrated decision', status => 'unanswered', created => '2024-01-01T00:00:00Z' },
                         order => [qw(title status created)]);
        my $istore = Almanac::Store->open(scope => 'project', type => 'inbox', root => $P16);
        $istore->create(fields => { title => 'half-migrated inbox', status => 'unanswered', created => '2024-01-01T00:00:00Z' },
                         order => [qw(title status created)]);
    };
    ok(!$@, 'AC16 fixture: both A/decision and A/inbox exist, each with one record') or diag("error: $@");
    make_path("$P16/.ccpraxis-local-data/.subagent-guard");
    write_raw("$P16/.ccpraxis-local-data/.subagent-guard/questions.md", "- untouched?\n");

    my $dec_snap_before = snapshot_dir(decision_dir_for($P16));
    my $inb_snap_before = snapshot_dir(inbox_dir_for($P16));

    for my $call (['list'], ['file', '--title', 'x'], ['answer', 'nosuch', '--answer', 'y']) {
        my $r = run_inbox(@$call, '--root', $P16);
        is($r->{rc}, 2, "AC16: almanac-inbox.pl @$call exits 2 when both dirs exist") or diag("stdout=$r->{out} stderr=$r->{err}");
        is($r->{out}, '', "AC16: almanac-inbox.pl @$call -- stdout empty");
        is(field2($r->{err}, 'kind'), 'refused', "AC16: almanac-inbox.pl @$call -- kind: refused");
        is(field2($r->{err}, 'detail'), 'half_migrated', "AC16: almanac-inbox.pl @$call -- detail: half_migrated");
        like($r->{err}, qr/\Aalmanac inbox: both .* exist; merge or remove one by hand, then retry\n/,
            "AC16: almanac-inbox.pl @$call -- STDERR starts with the half_migrated hint line");
    }

    is_deeply(snapshot_dir(decision_dir_for($P16)), $dec_snap_before, 'AC16: A/decision is unchanged after the refusals');
    is_deeply(snapshot_dir(inbox_dir_for($P16)), $inb_snap_before, 'AC16: A/inbox is unchanged after the refusals');
    ok(-f "$P16/.ccpraxis-local-data/.subagent-guard/questions.md", 'AC16: questions.md is still present, unrenamed');
}

# =============================================================================
# AC17 -- a record lock in A/decision held by another live process: `list`
# exits 2, detail record_locked, path names that record; A/decision
# byte-unchanged; A/inbox absent. After release, `list` migrates normally.
# =============================================================================
{
    my $P17 = mk_root();
    my $locked_id;
    eval {
        my $store = open_decision_store($P17);
        my $r = $store->create(fields => { title => 'lock target', status => 'unanswered', created => '2024-01-01T00:00:00Z' },
                                order => [qw(title status created)]);
        $locked_id = $r->{id};
    };
    ok(!$@ && defined $locked_id, 'AC17 fixture: A/decision has one record to lock') or diag("error: $@");

    SKIP: {
        skip 'AC17 fixture did not complete', 5 unless defined $locked_id;
        my $record_path = decision_dir_for($P17) . "/$locked_id.md";
        my $harness = tempdir(CLEANUP => 1);
        (my $barrier = "$harness/barrier") =~ s{\\}{/}g;
        (my $release = "$harness/release") =~ s{\\}{/}g;
        my $child_script = "$harness/child.pl";
        open(my $cfh, '>', $child_script) or die "cannot write $child_script: $!";
        print {$cfh} <<'PERL';
use strict; use warnings;
my ($alm_dir, $target, $barrier_file, $release_file) = @ARGV;
unshift @INC, $alm_dir;
require Almanac::Lock;
my ($lock, $err) = Almanac::Lock->acquire($target, verb => 'test-hold');
open(my $bfh, '>', $barrier_file); close $bfh;
my $deadline = time() + 25;
until (-e $release_file || time() > $deadline) { select(undef, undef, undef, 0.05) }
$lock->release if $lock;
PERL
        close $cfh;

        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            exec($^X, $child_script, $S, $record_path, $barrier, $release);
            POSIX::_exit(127);
        }
        my $deadline = Time::HiRes::time() + 20;
        until (-e $barrier || Time::HiRes::time() > $deadline) { Time::HiRes::sleep(0.02) }
        ok(-e $barrier, 'AC17 fixture: the child process signalled it holds the record lock');

        my $dec_snap_before = snapshot_dir(decision_dir_for($P17));
        my $r = run_inbox('list', '--root', $P17);
        is($r->{rc}, 2, 'AC17: list exits 2 while the record is locked by another process') or diag("stdout=$r->{out} stderr=$r->{err}");
        is(field2($r->{err}, 'detail'), 'record_locked', 'AC17: ...detail: record_locked');
        like($r->{err}, qr/\Q$locked_id\E/, 'AC17: the error names the locked record\'s path');
        is_deeply(snapshot_dir(decision_dir_for($P17)), $dec_snap_before, 'AC17: A/decision is byte-unchanged while locked');
        ok(!-d inbox_dir_for($P17), 'AC17: A/inbox was not created while locked');

        open(my $rfh, '>', $release) or die "cannot write $release: $!";
        close $rfh;
        waitpid($pid, 0);

        my $r2 = run_inbox('list', '--root', $P17);
        is($r2->{rc}, 0, 'AC17: after the lock is released, list migrates and exits 0') or diag("stderr: $r2->{err}");
        ok(!-e decision_dir_for($P17), 'AC17: A/decision no longer exists after the successful migration');
    }
}

# =============================================================================
# AC18 -- A/decision exists as a regular file: exit 2, detail
# legacy_not_directory, nothing changed.
# =============================================================================
{
    my $P18 = mk_root();
    make_path("$P18/.ccpraxis-local-data/almanac");
    write_raw(decision_dir_for($P18), "not a directory\n");
    my $before = slurp_raw(decision_dir_for($P18));

    my $r = run_inbox('list', '--root', $P18);
    is($r->{rc}, 2, 'AC18: list exits 2 when A/decision is a regular file') or diag("stdout=$r->{out} stderr=$r->{err}");
    is(field2($r->{err}, 'detail'), 'legacy_not_directory', 'AC18: ...detail: legacy_not_directory');
    like($r->{err}, qr/\Aalmanac inbox: .* is not a directory; move it aside by hand, then retry\n/,
        'AC18: STDERR starts with the legacy_not_directory hint line');
    is(slurp_raw(decision_dir_for($P18)), $before, 'AC18: the file is unchanged');
    ok(!-d inbox_dir_for($P18), 'AC18: A/inbox was not created');
}

# =============================================================================
# AC19 -- no legacy dir at all: `list` on a fresh project exits 0 and creates
# nothing under A (no A/inbox, no migration lock file).
# =============================================================================
{
    my $P19 = mk_root();
    my $r = run_inbox('list', '--root', $P19);
    is($r->{rc}, 0, 'AC19: list on a project with no legacy dir exits 0') or diag("stderr: $r->{err}");
    ok(!-d inbox_dir_for($P19), 'AC19: A/inbox was not created');
    ok(!-e "$P19/.ccpraxis-local-data/almanac/.inbox-migration.lock", 'AC19: no migration lock file was created');
    ok(!-e "$P19/.ccpraxis-local-data/almanac/.inbox-migration.lock.holder", 'AC19: no migration lock holder file was created');
}

# =============================================================================
# AC24 -- nothing aliases: no skills/decision dir; no `decision` key in
# routes(); no file under plugins/ or scripts/ (tests excluded) defines
# `package Almanac::Decision` or names open_decisions/list_decisions/
# read_decision.
# =============================================================================
{
    ok(!-d "$PLUGIN_ROOT/skills/decision", 'AC24: plugins/almanac/skills/decision does not exist');

    {
        local $@;
        do $ALMANAC_PL if -f $ALMANAC_PL;
        my $routes = eval { Almanac::CLI::routes() };
        if (ref($routes) eq 'HASH') {
            ok(!exists $routes->{decision}, 'AC24: routes() has no decision key');
        } else {
            fail('AC24: routes() has no decision key');
        }
    }

    my @offenders;
    my $visited_count = 0;
    my $visit = sub {
        my $f = $File::Find::name;
        return unless -f $f;
        return if $f =~ m{/tests/};
        return unless $f =~ /\.(?:pl|pm)\z/;
        return if $f eq $DECISION_PL;   # the stub itself: spec 2.6 permits it to exist, empty of symbols
        $visited_count++;
        my @lines = read_all_lines($f);
        for my $i (0 .. $#lines) {
            next if $lines[$i] =~ /^\s*#/;
            if ($lines[$i] =~ /^\s*package\s+Almanac::Decision\s*;/
                || $lines[$i] =~ /\bopen_decisions\b/
                || $lines[$i] =~ /\blist_decisions\b/
                || $lines[$i] =~ /\bread_decision\b/) {
                push @offenders, "$f:" . ($i + 1) . ": $lines[$i]";
            }
        }
    };
    File::Find::find({ wanted => $visit, no_chdir => 1 }, "$REPO_ROOT/plugins");
    File::Find::find({ wanted => $visit, no_chdir => 1 }, "$REPO_ROOT/scripts") if -d "$REPO_ROOT/scripts";
    cmp_ok($visited_count, '>', 10, 'AC24: the alias sweep actually visited a realistic number of .pl/.pm files (sweep not silently empty)')
        or diag("visited_count=$visited_count REPO_ROOT=$REPO_ROOT");
    unless (is(scalar(@offenders), 0, 'AC24: no non-test file defines Almanac::Decision or names open_decisions/list_decisions/read_decision')) {
        diag($_) for @offenders;
    }
}

# =============================================================================
# AC31/AC32 -- the lint: a pure sub, run both on in-memory strings (AC32,
# proving it can fire and that its allow-list legitimately passes) and on the
# real scan set (AC31).
# =============================================================================
sub lint_decision_mentions {
    my ($text) = @_;
    my $t = $text;
    # allow-list, applied to the whole text (order per spec table 2's ids).
    $t =~ s/\bDecisions?[\s#]+\d+/[ALLOW-A1]/g;
    $t =~ s/(?i)\bsingle[\s#]+decision\b/[ALLOW-A2]/g;
    $t =~ s/\bdispatch[\s#]+decision\b/[ALLOW-A3]/g;
    $t =~ s/\bparity[\s#]+decision\b/[ALLOW-A4]/g;
    $t =~ s/\bunrelated[\s#]+decisions\b/[ALLOW-A5]/g;
    $t =~ s/escalate-product-decisions-only/[ALLOW-A6]/g;
    $t =~ s/\b[A-Za-z_]*LEGACY[A-Za-z_]*\s*=\s*'?decision'?/[ALLOW-A7]/g;
    $t =~ s/\bdecision\s*=>\s*'almanac inbox'/[ALLOW-A8]/g;
    my @hits;
    my @lines = split /\n/, $t, -1;
    for my $i (0 .. $#lines) {
        push @hits, { line => $i + 1, text => $lines[$i] } if $lines[$i] =~ /decision/i;
    }
    return \@hits;
}

{
    # AC32: fires on genuine user-facing mentions.
    for my $bad (
        'pending decision',
        'almanac decision list',
        'Almanac::Decision',
        '/almanac:decision',
        'names no decision',
        "type => 'decision'",
    ) {
        my $hits = lint_decision_mentions($bad);
        ok(scalar(@$hits) >= 1, "AC32: the lint fires on '$bad'") or diag('no hits');
    }
    # AC32: passes the allow-listed forms.
    for my $ok_text (
        'Decision 7',
        "the single decision\n# point",
        "my \$LEGACY_TYPE = 'decision';",
    ) {
        my $hits = lint_decision_mentions($ok_text);
        is(scalar(@$hits), 0, "AC32: the lint passes '$ok_text'") or diag(join(' | ', map { $_->{text} } @$hits));
    }
}

# =============================================================================
# AC31 -- the real scan set: every regular file under plugins/almanac/ except
# tests/ and almanac-decision.pl, plus the three named butler/sandbox files.
# =============================================================================
{
    my @scan_files;
    my $collect = sub {
        my $f = $File::Find::name;
        return unless -f $f;
        return if $f =~ m{/tests/};
        return if $f eq $DECISION_PL;
        push @scan_files, $f;
    };
    File::Find::find({ wanted => $collect, no_chdir => 1 }, "$PLUGIN_ROOT")
        if -d $PLUGIN_ROOT;
    for my $extra (
        "$BUTLER_ROOT/scripts/butler-continuity.pl",
        "$BUTLER_ROOT/skills/continuity/SKILL.md",
        "$REPO_ROOT/scripts/statusline.pl",
    ) {
        push @scan_files, $extra if -f $extra;
    }

    cmp_ok(scalar(@scan_files), '>', 10, 'AC31: the scan set has a realistic number of files (sweep not silently empty)')
        or diag('scan_files=' . scalar(@scan_files) . " PLUGIN_ROOT=$PLUGIN_ROOT");

    my @offenders;
    for my $f (@scan_files) {
        my $bytes = slurp_raw($f);
        next unless defined $bytes;
        my $hits = lint_decision_mentions($bytes);
        push @offenders, map { "$f:$_->{line}: $_->{text}" } @$hits;
    }
    unless (is(scalar(@offenders), 0, 'AC31: no remaining user-facing "decision" mention (meaning an inbox item) across the scan set')) {
        diag($_) for @offenders[0 .. ($#offenders > 40 ? 40 : $#offenders)];
    }
}

# =============================================================================
# AC33 -- plugins/almanac/skills/decision does not exist;
# plugins/almanac/skills/inbox/SKILL.md exists.
# =============================================================================
{
    ok(!-d "$PLUGIN_ROOT/skills/decision", 'AC33: plugins/almanac/skills/decision does not exist');
    ok(-f "$PLUGIN_ROOT/skills/inbox/SKILL.md", 'AC33: plugins/almanac/skills/inbox/SKILL.md exists');
}

done_testing();
