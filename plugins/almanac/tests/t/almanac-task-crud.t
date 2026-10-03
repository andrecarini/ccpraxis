#!/usr/bin/env perl
# platform: any
# REPURPOSED (blueprint where-things-go, package 02-thread-store): the old
# flat-tasklist CRUD oracle is retired along with almanac-task.pl's CLI (see
# almanac-task-focus.t for the retirement-pointer assertions). This file is
# now the oracle for almanac-thread.pl's AC1 OUTPUT FORMATS exactly as
# specs/02-thread-store-spec.md section 2.7 pins them, line by line, for
# every verb that produces a "thread result" or "task result" block, plus
# list/show's default and --json forms. Behavioural CRUD correctness (does
# the right thing happen) lives in the sibling thread-store.t; this file is
# about the shape of what gets printed. See specs/02-thread-store-spec.md
# section 2.7 and AC1.
#
# HOUSE PATTERN for not-yet-built code: every CLI call goes through run_cli()
# so a missing script/module is a caught, reported failure for THIS
# assertion, not an abort of the whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use Cwd ();
use Encode ();
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $THREAD_PL = "$S/almanac-thread.pl";

my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{CLAUDE_CODE_SESSION_ID};

# ---------------------------------------------------------------------------
# blueprint where-things-go, package 03-thread-sessions (Decision 18 F6): a
# hard ticket gate lands on every almanac-thread.pl write verb. Mint one for
# the EXACT argv of every run_cli() call below so this file's existing
# fixtures keep working once that gate exists -- pure migration, not new
# behaviour.
# ---------------------------------------------------------------------------
(my $TC_BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
require "$TC_BUTLER_SCRIPTS/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
my $TC_BSD = tempdir(CLEANUP => 1); $TC_BSD =~ s{\\}{/}g;
local $ENV{BUTLER_STATE_DIR} = $TC_BSD;
my $TC_TICKET_SEQ = 0;
sub _mint_thread_ticket {
    my (@argv) = @_;
    local $ENV{BUTLER_STATE_DIR} = $TC_BSD;
    BpHook::write_ticket(
        { session_id => 'FIXTURE-SESSION', tool_use_id => 'FT' . (++$TC_TICKET_SEQ),
          transcript_path => undef, cwd => '/fixture' },
        'almanac-thread', [ @argv ]);
}

sub slurp_text {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:encoding(UTF-8)', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub mkroot { my $r = tempdir(CLEANUP => 1); $r =~ s{\\}{/}g; return $r }

sub run_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    local $ENV{BUTLER_STATE_DIR} = $TC_BSD;
    _mint_thread_ticket(@args);
    system(qq{perl "$THREAD_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}
sub field0 { my ($t, $k) = @_; return undef unless defined $t; return $1 if $t =~ /^\Q$k\E:\s(\S+)$/m; return undef }

ok(-f $THREAD_PL, 'almanac-thread.pl exists') or diag('not present yet; every format assertion below is expected to fail for exactly that reason');

my $ROOT = mkroot();

# ---------------------------------------------------------------------------
# "thread result" block -- create/archive/archive-if-done/event: exactly
# thread/state/path/changed, in that order, nothing else before the next
# blank or EOF.
# ---------------------------------------------------------------------------
sub assert_thread_result_shape {
    my ($out, $label) = @_;
    like($out, qr/\Athread:\s\S+\nstate:\s\S+\npath:\s\S+\nchanged:\s(yes|no)\n?\z/,
        "format: thread result block is exactly thread/state/path/changed, in order ($label)");
}

{
    my $r = run_cli('create', 'fmt1', '--root', $ROOT);
    assert_thread_result_shape($r->{out}, 'create');
}
{
    my $r = run_cli('archive-if-done', 'fmt1', '--root', $ROOT);
    assert_thread_result_shape($r->{out}, 'archive-if-done');
}
{
    my $r = run_cli('archive', 'fmt1', '--root', $ROOT);
    assert_thread_result_shape($r->{out}, 'archive');
}
{
    run_cli('create', 'fmt2', '--root', $ROOT);
    my $r = run_cli('event', 'fmt2', '--event', 'resumed', '--root', $ROOT);
    assert_thread_result_shape($r->{out}, 'event');
}

# ---------------------------------------------------------------------------
# "task result" block -- add/edit/move/status: exactly thread/task/path/
# status/link/rank/rev/changed/thread_state, in that order.
# ---------------------------------------------------------------------------
sub assert_task_result_shape {
    my ($out, $label) = @_;
    like($out,
        qr/\Athread:\s\S+\ntask:\s\S+\npath:\s\S+\nstatus:\s\S+\nlink:\s\S+\nrank:\s\S+\nrev:\s\S+\nchanged:\s(yes|no)\nthread_state:\s\S+\n?\z/,
        "format: task result block is exactly thread/task/path/status/link/rank/rev/changed/thread_state, in order ($label)");
}

my $ROOT2 = mkroot();
run_cli('create', 'fmt3', '--root', $ROOT2);
{
    my $r = run_cli('add', 'fmt3', '--title', 'a', '--root', $ROOT2);
    assert_task_result_shape($r->{out}, 'add');
    is(field0($r->{out}, 'link'), '-', 'format: add result prints link: - for an unlinked task');
}
my $r_add2 = run_cli('add', 'fmt3', '--title', 'a', '--root', $ROOT2);
my $idA = field0($r_add2->{out}, 'task');
{
    my $r = run_cli('edit', 'fmt3', $idA, '--title', 'a2', '--root', $ROOT2);
    assert_task_result_shape($r->{out}, 'edit');
}
{
    my $r = run_cli('move', 'fmt3', $idA, '--first', '--root', $ROOT2);
    assert_task_result_shape($r->{out}, 'move');
}
{
    my $r = run_cli('status', 'fmt3', $idA, 'doing', '--root', $ROOT2);
    assert_task_result_shape($r->{out}, 'status');
    is(field0($r->{out}, 'status'), 'doing', 'format: status result reports the new status');
}

# ---------------------------------------------------------------------------
# reorder -- one "task: <id>" line per task, then total:, then thread_state:.
# ---------------------------------------------------------------------------
{
    my $ROOT3 = mkroot();
    run_cli('create', 'fmt4', '--root', $ROOT3);
    my $id1 = field0(run_cli('add', 'fmt4', '--title', 'x', '--root', $ROOT3)->{out}, 'task');
    my $id2 = field0(run_cli('add', 'fmt4', '--title', 'y', '--root', $ROOT3)->{out}, 'task');
    my $r = run_cli('reorder', 'fmt4', $id2, $id1, '--root', $ROOT3);
    my @lines = split /\n/, $r->{out};
    is($lines[0] // '', "task: $id2", 'format: reorder first task line is the first id given');
    is($lines[1] // '', "task: $id1", 'format: reorder second task line is the second id given');
    is($lines[2] // '', 'total: 2', 'format: reorder prints total: <n> after the task lines');
    like($lines[3] // '', qr/^thread_state:\s\S+$/, 'format: reorder prints thread_state: last');
}

# ---------------------------------------------------------------------------
# add-packages -- thread:, one "added: <id> <bp>/<pkg>" line per task added
# (insertion order), total_added:, thread_state:.
# ---------------------------------------------------------------------------
{
    my $ROOT4 = mkroot();
    run_cli('create', 'fmt5', '--root', $ROOT4);
    my $base = $ROOT4; $base =~ s{\\}{/}g;
    require File::Path;
    File::Path::make_path("$base/.ccpraxis-local-data/blueprints/bp/packages");
    for my $pkg (qw(01-a 02-b)) {
        open(my $fh, '>:raw', "$base/.ccpraxis-local-data/blueprints/bp/packages/$pkg.md") or die $!;
        print {$fh} "---\nstatus: pending\n---\n";
        close $fh;
    }
    my $r = run_cli('add-packages', 'fmt5', 'bp', '--root', $ROOT4);
    my @lines = split /\n/, $r->{out};
    is($lines[0] // '', 'thread: fmt5', 'format: add-packages first line is thread: <name>');
    like($lines[1] // '', qr/^added:\s\S+\sbp\/01-a$/, 'format: add-packages first added line names bp/01-a');
    like($lines[2] // '', qr/^added:\s\S+\sbp\/02-b$/, 'format: add-packages second added line names bp/02-b');
    is($lines[3] // '', 'total_added: 2', 'format: add-packages prints total_added: <n>');
    like($lines[4] // '', qr/^thread_state:\s\S+$/, 'format: add-packages prints thread_state: last');
}

# ---------------------------------------------------------------------------
# list default -- per thread: thread:, then 2-space state/owner/tasks/
# blueprints, then total: <n> at the end.
# ---------------------------------------------------------------------------
{
    my $ROOT5 = mkroot();
    run_cli('create', 'fmtlist', '--root', $ROOT5);
    my $r = run_cli('list', '--root', $ROOT5);
    like($r->{out}, qr/^thread:\sfmtlist\n {2}state:\s\S+\n {2}owner:\s\S+:\S+\n {2}tasks:\s\d+\/\d+\n {2}blueprints:\s\S+\n/m,
        'format: list default block is thread/state/owner/tasks/blueprints, two-space indented');
    like($r->{out}, qr/^total:\s\d+\s*\z/m, 'format: list default ends with total: <n>');
}

# ---------------------------------------------------------------------------
# list --json -- array of objects with the pinned key set.
# ---------------------------------------------------------------------------
{
    my $ROOT6 = mkroot();
    run_cli('create', 'fmtjson', '--root', $ROOT6);
    my $r = run_cli('list', '--json', '--root', $ROOT6);
    my $j = eval { JSON::PP->new->decode($r->{out}) };
    ok(ref($j) eq 'ARRAY', 'format: list --json decodes to an array') or diag("got: $r->{out}\nerr: $r->{err}");
    if (ref($j) eq 'ARRAY' && @$j) {
        my $row = $j->[0];
        for my $k (qw(name state owner_kind owner_id created archived_at blueprints tasks_total tasks_done)) {
            ok(exists $row->{$k}, "format: list --json row has key $k");
        }
        is($row->{archived_at}, undef, 'format: list --json archived_at is null when absent');
    }
}

# ---------------------------------------------------------------------------
# show default -- thread/state/owner/created/blueprints/archived_at/tasks
# header, then one task: block per task, then one log: line per entry.
# ---------------------------------------------------------------------------
{
    my $ROOT7 = mkroot();
    run_cli('create', 'fmtshow', '--root', $ROOT7);
    run_cli('add', 'fmtshow', '--title', 'step one', '--root', $ROOT7);
    my $r = run_cli('show', 'fmtshow', '--root', $ROOT7);
    like($r->{out}, qr/^thread:\sfmtshow$/m, 'format: show prints thread: <name>');
    like($r->{out}, qr/^state:\s\S+$/m, 'format: show prints state:');
    like($r->{out}, qr/^owner:\s\S+:\S+$/m, 'format: show prints owner: <kind>:<id>');
    like($r->{out}, qr/^created:\s\S+$/m, 'format: show prints created:');
    like($r->{out}, qr/^blueprints:\s\S+$/m, 'format: show prints blueprints:');
    like($r->{out}, qr/^archived_at:\s\S+$/m, 'format: show prints archived_at: (- when absent)');
    like($r->{out}, qr/^tasks:\s\d+\/\d+$/m, 'format: show prints tasks: <done>/<total>');
    like($r->{out}, qr/^task:\s\S+\n {2}position:\s\d+\n {2}status:\s\S+\n {2}link:\s\S+\n {2}blocked_on:\s\S+\n {2}title:\s/m,
        'format: show prints one task: block with position/status/link/blocked_on/title');
    like($r->{out}, qr/^log:\s\S+\s\S+\sactor=\S+\ssession=\S+$/m, 'format: show prints a log: line ending with session= (no extra fields on created)');
}

# ---------------------------------------------------------------------------
# show --json -- pinned top-level keys + per-task + per-log-entry shapes.
# ---------------------------------------------------------------------------
{
    my $ROOT8 = mkroot();
    run_cli('create', 'fmtshowjson', '--root', $ROOT8);
    run_cli('add', 'fmtshowjson', '--title', 'step one', '--root', $ROOT8);
    my $r = run_cli('show', 'fmtshowjson', '--json', '--root', $ROOT8);
    my $j = eval { JSON::PP->new->decode($r->{out}) };
    ok(ref($j) eq 'HASH', 'format: show --json decodes to a hash') or diag("got: $r->{out}\nerr: $r->{err}");
    if (ref($j) eq 'HASH') {
        ok(ref($j->{thread}) eq 'HASH', 'format: show --json has a thread hash');
        for my $k (qw(name state owner_kind owner_id created archived_at blueprints)) {
            ok(exists $j->{thread}{$k}, "format: show --json thread has key $k") if ref($j->{thread}) eq 'HASH';
        }
        ok(ref($j->{tasks}) eq 'ARRAY', 'format: show --json has a tasks array');
        if (ref($j->{tasks}) eq 'ARRAY' && @{ $j->{tasks} }) {
            my $t = $j->{tasks}[0];
            for my $k (qw(id position rank title linked link status location blocked_on from_todo body)) {
                ok(exists $t->{$k}, "format: show --json task has key $k");
            }
            is($t->{linked}, JSON::PP::false, 'format: show --json unlinked task has linked: false (a JSON boolean)');
        }
        ok(ref($j->{log}) eq 'ARRAY', 'format: show --json has a log array');
        if (ref($j->{log}) eq 'ARRAY' && @{ $j->{log} }) {
            my $e = $j->{log}[0];
            for my $k (qw(id at session actor event task from to reason)) {
                ok(exists $e->{$k}, "format: show --json log entry has key $k");
            }
        }
    }
}

done_testing();
