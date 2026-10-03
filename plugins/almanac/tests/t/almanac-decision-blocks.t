#!/usr/bin/env perl
# platform: any
# Immutable oracle for the traversal surface of the pending-decisions script
# (blueprint almanac-records, package 08-pending-decisions): answering a
# decision surfaces every task whose blocked_on names it (DC-TRAV), a
# since-obsoleted task is reported as a dangling reference rather than a
# failure (DC-DANG), and the ownership boundary with package 07 (this file
# only reads Almanac::Task::list_tasks, it never writes blocked_on). CRUD
# lives in the sibling almanac-decision-crud.t. See
# specs/08-pending-decisions-spec.md section 3.4.
#
# HOUSE PATTERN for a not-yet-built script: every call into the CLI or the
# module is wrapped in eval{} / run_cli() so "Undefined subroutine" / "Can't
# open perl script" is a caught, reported failure for THIS assertion rather
# than an abort of the whole file.
#
# REPURPOSED (blueprint where-things-go, package 02-thread-store):
# almanac-task.pl's CLI is retired; blocked_tasks()'s B1/B2/B3 fixtures now
# create their tasks through almanac-thread.pl (a thread named `blk`), since
# almanac-inbox.pl::blocked_tasks() already scans BOTH the flat task store
# (B7's ownership-boundary grep is unchanged -- it still names
# Almanac::Task::list_tasks for the flat half) AND every thread's tasks
# (almanac-inbox.pl:403-428); a thread task's key is the compound
# "<threadname>/<taskid>" (almanac-inbox.pl:419), never a bare task id, so
# every comparison below uses that compound key.
#
# EDITED further for blueprint where-things-go, package 03-thread-sessions
# (Decision 18 F6): a hard ticket gate lands on every almanac-thread.pl
# write verb -- run_thread() mints one for the exact argv of each call.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use Cwd ();
use Encode ();
use JSON::PP ();
use Scalar::Util qw(refaddr);
use POSIX ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $INBOX_PL = "$S/almanac-inbox.pl";
my $TASK_PL     = "$S/almanac-task.pl";
my $THREAD_PL   = "$S/almanac-thread.pl";

# blueprint where-things-go, package 03-thread-sessions (Decision 18 F6): a
# hard ticket gate lands on every almanac-thread.pl write verb. run_thread()
# mints one for the EXACT argv of each call so this file's fixtures keep
# working once that gate exists -- pure migration, not new behaviour.
(my $DB_BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
my $DB_TICKET_SEQ = 0;

my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{BP_PROJECT_ROOT};
delete local $ENV{CLAUDE_CODE_SESSION_ID};
my $DB_BSD = tempdir(CLEANUP => 1); $DB_BSD =~ s{\\}{/}g;
local $ENV{BUTLER_STATE_DIR} = $DB_BSD;
require "$DB_BUTLER_SCRIPTS/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;

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

sub slurp_text {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:encoding(UTF-8)', $p or return undef;
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

sub norm_path {
    my ($p) = @_;
    my $abs = Cwd::abs_path($p);
    $abs = $p unless defined $abs;
    $abs = Encode::decode('UTF-8', $abs) unless utf8::is_utf8($abs);
    $abs =~ s{\\}{/}g;
    $abs =~ s{/\z}{};
    $abs =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    return $abs;
}

sub read_all_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}

# run_cli($pl, @args) -> { rc, out, err } -- real process, temp-file captures,
# NEVER a shell string. A shell string built by quoting each argument with
# bare double quotes mangles any argument that itself contains a double
# quote -- fork()+exec(LIST) hands argv straight to the OS with no shell in
# between, exactly the discipline bp-worker.pl already uses for its own
# child spawn. STDOUT/STDERR are reopened onto files in the CHILD only
# (never an in-memory scalar, per CLAUDE.md's Windows landmine list; the
# parent's own STDOUT/STDERR stay untouched throughout).
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
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}
sub run_dec  { return run_cli($INBOX_PL, @_) }
sub run_task { return run_cli($TASK_PL, @_) }
sub _mint_thread_ticket {
    my (@argv) = @_;
    local $ENV{BUTLER_STATE_DIR} = $DB_BSD;
    BpHook::write_ticket(
        { session_id => 'FIXTURE-SESSION', tool_use_id => 'FT' . (++$DB_TICKET_SEQ),
          transcript_path => undef, cwd => '/fixture' },
        'almanac-thread', [ @argv ]);
}
sub run_thread {
    _mint_thread_ticket(@_);
    return run_cli($THREAD_PL, @_);
}

sub field0 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\Q$key\E:\s(\S+)$/m;
    return undef;
}

sub field2 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}

sub err_kind { return field2($_[0], 'kind') }

sub decode_json_or_undef {
    my ($text) = @_;
    return eval { JSON::PP->new->decode($text) };
}

sub inbox_dir_for { return norm_path($_[0]) . '/.ccpraxis-local-data/almanac/inbox' }
sub task_dir_for     { return norm_path($_[0]) . '/.ccpraxis-local-data/almanac/task' }
sub thread_tasks_dir_for { return norm_path($_[0]) . "/.ccpraxis-local-data/almanac/thread-tasks-$_[1]" }

sub md_files_in {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return @f;
}

# parse_traversal($text) -> \%out -- decision/tasks_available/tasks_reason/
# blocked_total/dangling_total, plus \@groups (task/status/ref/title) in the
# order the four-line groups appear, per spec section 2.4's output grammar.
sub parse_traversal {
    my ($text) = @_;
    return {} unless defined $text;
    my %out = (
        item            => field0($text, 'item'),
        tasks_available => field0($text, 'tasks_available'),
        tasks_reason    => field0($text, 'tasks_reason'),
        blocked_total   => field0($text, 'blocked_total'),
        dangling_total  => field0($text, 'dangling_total'),
    );
    my @groups;
    while ($text =~ /^blocked_task:\s(\S+)\n\s{2}status:\s(\S+)\n\s{2}ref:\s(\S+)\n\s{2}title:\s(.*)$/mg) {
        push @groups, { task => $1, status => $2, ref => $3, title => $4 };
    }
    $out{groups} = \@groups;
    return \%out;
}

# ---------------------------------------------------------------------------
# live-store sanity + isolation guard -- before
# ---------------------------------------------------------------------------
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIVE_STORE = "$REPO/.ccpraxis-local-data/bug-reports";
sub count_reports_in {
    my ($dir) = @_;
    return 0 unless -d $dir;
    opendir(my $dh, $dir) or return 0;
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return scalar @f;
}
my $live_before = count_reports_in($LIVE_STORE);
# Decision 120(c): presence in the real gitignored live store is never REQUIRED -- only that this suite leaves its count unchanged (checked below).

sub live_almanac_listing {
    my %out;
    for my $t (qw(task task-focus decision)) {
        my $dir = "$REPO/.ccpraxis-local-data/almanac/$t";
        if (-d $dir) {
            opendir(my $dh, $dir) or next;
            $out{$t} = [ sort grep { /\.md\z/ && -f "$dir/$_" } readdir($dh) ];
            closedir $dh;
        } else {
            $out{$t} = undef;
        }
    }
    return \%out;
}
my $live_listing_before = live_almanac_listing();

ok(-f $INBOX_PL, 'almanac-inbox.pl exists at plugins/almanac/scripts/almanac-inbox.pl')
    or diag('almanac-inbox.pl is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

# In-process calls load almanac-inbox.pl ONLY (spec: it brings
# Almanac::Task with it via require of the sibling script at compile time --
# this file must not also `do` almanac-task.pl).
do $INBOX_PL if -f $INBOX_PL;

# =============================================================================
# B7 -- ownership boundary, by grep. Run whether or not the script loaded.
# =============================================================================
{
    if (-f $INBOX_PL) {
        my @lines = read_all_lines($INBOX_PL);
        my @list_tasks_hits = grep { /Almanac::Task::list_tasks/ } @lines;
        my @task_type_hits  = grep { /type\s*=>\s*'task'/ } @lines;
        my @writeish_hits   = grep { /blocked_on/ && /(?:->update\(|->create\(|\bset\s*=>|\bunset\s*=>)/ } @lines;

        ok(@list_tasks_hits >= 1, 'B7: the file calls Almanac::Task::list_tasks');
        unless (ok(@task_type_hits == 0, "B7: the file never opens a Store of type => 'task' directly")) {
            diag($_) for @task_type_hits;
        }
        unless (ok(@writeish_hits == 0, 'B7: no line combines the token blocked_on with a Store write call (set/unset/create/update)')) {
            diag($_) for @writeish_hits;
        }
    } else {
        fail($_) for (
            'B7: the file calls Almanac::Task::list_tasks',
            "B7: the file never opens a Store of type => 'task' directly",
            'B7: no line combines the token blocked_on with a Store write call (set/unset/create/update)',
        );
    }
}

# =============================================================================
# B1/B2/B6 fixture -- built once, shared: two decisions D and D2; four tasks
# T1/T2 blocked on D, T3 blocked on D2, T4 unblocked. Kept at 2 decisions +
# 4 tasks, within the spec's 5-and-5 size budget.
# =============================================================================
my ($ROOT, $D_id, $D2_id, $T1_id, $T2_id, $T3_id, $T4_id);
my (%task_bytes_before, %task_bytes_after_b1, %task_bytes_after_obsolete, %task_bytes_after_b2);
{
    $ROOT = tempdir(CLEANUP => 1);
    $ROOT =~ s{\\}{/}g;

    my $rd1 = run_dec('file', '--title', 'Decision D', '--root', $ROOT);
    $D_id = field0($rd1->{out}, 'id');
    ok(defined $D_id, 'B1 fixture: file D succeeds') or diag("stderr: $rd1->{err}");

    my $rd2 = run_dec('file', '--title', 'Decision D2', '--root', $ROOT);
    $D2_id = field0($rd2->{out}, 'id');
    ok(defined $D2_id, 'B1 fixture: file D2 succeeds') or diag("stderr: $rd2->{err}");

    my $rblk = run_thread('create', 'blk', '--root', $ROOT);
    is($rblk->{rc}, 0, 'B1 fixture: create thread blk succeeds') or diag("stderr: $rblk->{err}");

    my $rt1 = run_thread('add', 'blk', '--title', 'T1', '--blocked-on', $D_id, '--root', $ROOT);
    $T1_id = field0($rt1->{out}, 'task');
    ok(defined $T1_id, 'B1 fixture: add T1 --blocked-on D succeeds') or diag("stderr: $rt1->{err}");

    my $rt2 = run_thread('add', 'blk', '--title', 'T2', '--blocked-on', $D_id, '--root', $ROOT);
    $T2_id = field0($rt2->{out}, 'task');
    ok(defined $T2_id, 'B1 fixture: add T2 --blocked-on D succeeds') or diag("stderr: $rt2->{err}");

    my $rt3 = run_thread('add', 'blk', '--title', 'T3', '--blocked-on', $D2_id, '--root', $ROOT);
    $T3_id = field0($rt3->{out}, 'task');
    ok(defined $T3_id, 'B1 fixture: add T3 --blocked-on D2 succeeds') or diag("stderr: $rt3->{err}");

    my $rt4 = run_thread('add', 'blk', '--title', 'T4', '--root', $ROOT);
    $T4_id = field0($rt4->{out}, 'task');
    ok(defined $T4_id, 'B1 fixture: add T4 (unblocked) succeeds') or diag("stderr: $rt4->{err}");

    my $tdir = thread_tasks_dir_for($ROOT, 'blk');
    for my $id ($T1_id, $T2_id, $T3_id, $T4_id) {
        next unless defined $id;
        $task_bytes_before{$id} = slurp_raw("$tdir/$id.md");
    }

    # -------------------------------------------------------------------
    # B1 -- answer D end to end; the traversal block names exactly T1, T2.
    # -------------------------------------------------------------------
    my $rans = run_dec('answer', $D_id, '--answer', 'yes', '--root', $ROOT);
    is($rans->{rc}, 0, 'B1: answer D --answer yes exits 0') or diag("stderr: $rans->{err}");
    is(field0($rans->{out}, 'changed'), 'yes', 'B1: result block carries changed: yes');

    my $trav1 = parse_traversal($rans->{out});
    is($trav1->{tasks_available}, 'yes', 'B1: traversal block carries tasks_available: yes');
    is($trav1->{tasks_reason}, 'ok', 'B1: traversal block carries tasks_reason: ok');
    is($trav1->{blocked_total}, '2', 'B1: blocked_total: 2');
    is($trav1->{dangling_total}, '0', 'B1: dangling_total: 0');
    is(scalar(@{ $trav1->{groups} }), 2, 'B1: exactly two blocked_task groups are printed');
    if (@{ $trav1->{groups} } == 2) {
        is($trav1->{groups}[0]{task}, "blk/$T1_id", 'B1: T1 is the first blocked_task group (task list order)');
        is($trav1->{groups}[0]{ref}, 'live', 'B1: T1\'s group reports ref: live');
        is($trav1->{groups}[0]{title}, 'T1', 'B1: T1\'s group reports its title');
        is($trav1->{groups}[1]{task}, "blk/$T2_id", 'B1: T2 is the second blocked_task group');
        is($trav1->{groups}[1]{ref}, 'live', 'B1: T2\'s group reports ref: live');
        is($trav1->{groups}[1]{title}, 'T2', 'B1: T2\'s group reports its title');
    } else {
        fail($_) for (
            'B1: T1 is the first blocked_task group (task list order)', 'B1: T1\'s group reports ref: live',
            'B1: T1\'s group reports its title', 'B1: T2 is the second blocked_task group',
            'B1: T2\'s group reports ref: live', 'B1: T2\'s group reports its title',
        );
    }
    my @named = map { $_->{task} } @{ $trav1->{groups} };
    ok(!(grep { $_ eq "blk/$T3_id" } @named), 'B1: T3 (blocked on D2, not D) is absent from the traversal');
    ok(!(grep { $_ eq "blk/$T4_id" } @named), 'B1: T4 (unblocked) is absent from the traversal');

    for my $id ($T1_id, $T2_id, $T3_id, $T4_id) {
        next unless defined $id;
        $task_bytes_after_b1{$id} = slurp_raw("$tdir/$id.md");
    }

    # -------------------------------------------------------------------
    # B2 -- obsolete T2; blocks D now reports it dangling; blocks --json
    # agrees; repeating the same answer is a no-op with the same traversal.
    # -------------------------------------------------------------------
    my $robs = run_thread('status', 'blk', $T2_id, 'obsoleted', '--root', $ROOT);
    is($robs->{rc}, 0, 'B2 fixture: almanac-thread.pl status blk T2 obsoleted exits 0') or diag("stderr: $robs->{err}");
    # Decision 24 (3): T2 is the dangling task, the most interesting one
    # (review m8) -- snapshot it right after its OWN legitimate change (via
    # almanac-thread.pl's own `status` verb) so B6 can guard it across every
    # subsequent decision-script call in this block.
    $task_bytes_after_obsolete{$T2_id} = slurp_raw("$tdir/$T2_id.md") if defined $T2_id;

    my $rblocks = run_dec('blocks', $D_id, '--root', $ROOT);
    is($rblocks->{rc}, 0, 'B2: blocks D exits 0') or diag("stderr: $rblocks->{err}");
    my $trav2 = parse_traversal($rblocks->{out});
    is($trav2->{blocked_total}, '2', 'B2: blocked_total: 2 (T1 and T2 still both present)');
    is($trav2->{dangling_total}, '1', 'B2: dangling_total: 1 (T2 alone)');
    my ($t2grp) = grep { $_->{task} eq "blk/$T2_id" } @{ $trav2->{groups} };
    is(ref($t2grp) eq 'HASH' ? $t2grp->{ref} : undef, 'dangling', 'B2: T2\'s group now reports ref: dangling');
    my ($t1grp) = grep { $_->{task} eq "blk/$T1_id" } @{ $trav2->{groups} };
    is(ref($t1grp) eq 'HASH' ? $t1grp->{ref} : undef, 'live', 'B2: T1\'s group still reports ref: live');

    my $rblocksj = run_dec('blocks', $D_id, '--json', '--root', $ROOT);
    is($rblocksj->{rc}, 0, 'B2: blocks D --json exits 0') or diag("stderr: $rblocksj->{err}");
    my $decoded = decode_json_or_undef($rblocksj->{out});
    ok(ref($decoded) eq 'HASH', 'B2: blocks --json decodes to a hash') or diag("raw: $rblocksj->{out}");
    if (ref($decoded) eq 'HASH') {
        is($decoded->{item}, $D_id, 'B2 --json: item equals D');
        is($decoded->{tasks_available} ? 1 : 0, 1, 'B2 --json: tasks_available is true');
        my $blocked = $decoded->{blocked};
        is(ref($blocked) eq 'ARRAY' ? scalar(@$blocked) : -1, 2, 'B2 --json: blocked has exactly two entries');
        if (ref($blocked) eq 'ARRAY') {
            my ($jt2) = grep { $_->{id} eq "blk/$T2_id" } @$blocked;
            is(ref($jt2) eq 'HASH' ? $jt2->{ref} : undef, 'dangling', 'B2 --json: T2\'s entry reports ref: dangling');
        }
    }

    my $rrepeat = run_dec('answer', $D_id, '--answer', 'yes', '--root', $ROOT);
    is($rrepeat->{rc}, 0, 'B2: repeating answer D --answer yes exits 0') or diag("stderr: $rrepeat->{err}");
    is(field0($rrepeat->{out}, 'changed'), 'no', 'B2: the repeated answer reports changed: no');
    my $trav3 = parse_traversal($rrepeat->{out});
    is($trav3->{blocked_total}, '2', 'B2: the repeated answer\'s traversal still reports blocked_total: 2');
    is($trav3->{dangling_total}, '1', 'B2: the repeated answer\'s traversal still reports dangling_total: 1');

    for my $id ($T1_id, $T2_id, $T3_id, $T4_id) {
        next unless defined $id;
        $task_bytes_after_b2{$id} = slurp_raw("$tdir/$id.md");
    }
}

# =============================================================================
# B3 -- in-process blocked_tasks(D): exact key sets; dangling holds the SAME
# hashref (refaddr) as T2's entry in tasks.
# =============================================================================
{
    my $report = eval { Almanac::Inbox::blocked_tasks($D_id, root => $ROOT) };
    ok(!$@, 'B3: blocked_tasks(D) in-process does not die') or diag("error: $@");
    ok(ref($report) eq 'HASH', 'B3: blocked_tasks returns a hashref') or diag('not a hashref');
    if (ref($report) eq 'HASH') {
        is_deeply([sort keys %$report], [sort qw(item available reason tasks dangling)],
            'B3: the report has exactly item/available/reason/tasks/dangling');
        is($report->{item}, $D_id, 'B3: item equals D');
        is($report->{available}, 1, 'B3: available == 1');
        is($report->{reason}, 'ok', 'B3: reason == ok');
        my $tasks = $report->{tasks};
        is(ref($tasks) eq 'ARRAY' ? scalar(@$tasks) : -1, 2, 'B3: tasks has exactly two entries (T1, T2)');
        if (ref($tasks) eq 'ARRAY') {
            my ($e1) = grep { $_->{task} eq "blk/$T1_id" } @$tasks;
            my ($e2) = grep { $_->{task} eq "blk/$T2_id" } @$tasks;
            ok(defined $e1, 'B3: T1 has a tasks entry');
            ok(defined $e2, 'B3: T2 has a tasks entry');
            is_deeply([sort keys %$e1], [sort qw(task status title ref)], 'B3: a tasks entry has exactly task/status/title/ref') if $e1;
            is($e2->{ref}, 'dangling', 'B3: T2\'s entry reports ref: dangling') if $e2;

            my $dangling = $report->{dangling};
            is(ref($dangling) eq 'ARRAY' ? scalar(@$dangling) : -1, 1, 'B3: dangling has exactly one entry');
            if (ref($dangling) eq 'ARRAY' && defined $e2) {
                is(refaddr($dangling->[0]), refaddr($e2), 'B3: dangling holds the SAME hashref as tasks\' dangling entry (refaddr)');
            }
        } else {
            fail("B3: $_") for ('T1 has a tasks entry', 'T2 has a tasks entry', 'dangling has exactly one entry');
        }
    } else {
        fail("B3: $_") for (
            'the report has exactly item/available/reason/tasks/dangling',
            'item equals D', 'available == 1', 'reason == ok', 'tasks has exactly two entries (T1, T2)',
        );
    }
}

# =============================================================================
# B4 -- section 3.4 items 17, 19: no task store at all; an unknown decision id
# via blocks (CLI, exit 2) and via blocked_tasks (in-process, returns normally).
# =============================================================================
{
    my $ROOT4 = tempdir(CLEANUP => 1);
    $ROOT4 =~ s{\\}{/}g;
    my $rec4 = eval { Almanac::Inbox::file(root => $ROOT4, title => 'B4 decision, no task store') };
    ok(!$@ && defined($rec4), 'B4 fixture: a decision exists, no task store directory was ever created')
        or diag("error: $@");
    my $id4 = ref($rec4) eq 'HASH' ? $rec4->{id} : 'MISSING-B4';
    ok(!-d task_dir_for($ROOT4), 'B4 fixture: the task store directory genuinely does not exist');

    my $rblocks4 = run_dec('blocks', $id4, '--root', $ROOT4);
    is($rblocks4->{rc}, 0, 'B4/item17: blocks D on a root with no task store exits 0') or diag("stderr: $rblocks4->{err}");
    my $trav4 = parse_traversal($rblocks4->{out});
    is($trav4->{tasks_available}, 'yes', 'B4/item17: tasks_available: yes with no task store');
    is($trav4->{blocked_total}, '0', 'B4/item17: blocked_total: 0');
    is($trav4->{dangling_total}, '0', 'B4/item17: dangling_total: 0');

    my $rblocksu = run_dec('blocks', 'no-such-decision-id', '--root', $ROOT4);
    is($rblocksu->{rc}, 2, 'B4/item19: blocks UNKNOWN exits 2') or diag("stderr: $rblocksu->{err}");
    is(err_kind($rblocksu->{err}), 'not_found', 'B4/item19: ...kind: not_found');

    my $reportu = eval { Almanac::Inbox::blocked_tasks('no-such-decision-id', root => $ROOT4) };
    ok(!$@, 'B4/item19: blocked_tasks(UNKNOWN) in-process does not die') or diag("error: $@");
    is(ref($reportu) eq 'HASH' ? $reportu->{available} : undef, 1,
       'B4/item19: blocked_tasks(UNKNOWN) still traverses (available == 1) -- it never checks decision existence');
}

# =============================================================================
# B5 -- section 3.4 item 18: a malformed task store never blocks answering.
# =============================================================================
{
    my $ROOT5 = tempdir(CLEANUP => 1);
    $ROOT5 =~ s{\\}{/}g;
    my $rec5 = eval { Almanac::Inbox::file(root => $ROOT5, title => 'B5 decision') };
    ok(!$@ && defined($rec5), 'B5 fixture: a decision exists') or diag("error: $@");
    my $id5 = ref($rec5) eq 'HASH' ? $rec5->{id} : 'MISSING-B5';

    my $tdir5 = task_dir_for($ROOT5);
    make_path($tdir5);
    write_raw("$tdir5/bad-task.md", "not a frontmatter record at all\n");

    my $ranswer5 = run_dec('answer', $id5, '--answer', 'yes', '--root', $ROOT5);
    is($ranswer5->{rc}, 0, 'B5: answer still exits 0 despite a malformed task store') or diag("stderr: $ranswer5->{err}");
    my $trav5 = parse_traversal($ranswer5->{out});
    is($trav5->{tasks_available}, 'no', 'B5: tasks_available: no');
    is($trav5->{tasks_reason}, 'malformed', 'B5: tasks_reason: malformed');
    is($trav5->{blocked_total}, '0', 'B5: blocked_total: 0');
    is($trav5->{dangling_total}, '0', 'B5: dangling_total: 0');

    my $ddir5 = inbox_dir_for($ROOT5);
    my @dkeys;
    if (open(my $fh, '<', "$ddir5/$id5.md")) {
        local $/;
        my $c = <$fh>;
        close $fh;
        @dkeys = ($c =~ /^status:\s(\S+)$/m);
    }
    is($dkeys[0], 'answered', 'B5: the decision itself was committed as answered on disk') if @dkeys;
    ok(@dkeys, 'B5: the decision record on disk carries a status field') unless @dkeys;

    my $report5 = eval { Almanac::Inbox::blocked_tasks($id5, root => $ROOT5) };
    ok(!$@, 'B5: blocked_tasks() in-process does not die on a malformed task store') or diag("error: $@");
    is(ref($report5) eq 'HASH' ? $report5->{available} : undef, 0, 'B5: blocked_tasks() reports available == 0');
    is(ref($report5) eq 'HASH' ? $report5->{reason} : undef, 'malformed', 'B5: blocked_tasks() reports reason == malformed');
}

# =============================================================================
# B6 -- section 3.4 item 20: traversal never writes -- task files are
# byte-identical across B1's answer and B2's status/blocks/answer calls.
# =============================================================================
{
    for my $id ($T1_id, $T3_id, $T4_id) {
        next unless defined $id;
        is($task_bytes_after_b1{$id}, $task_bytes_before{$id},
           "B6: $id's task file bytes are unchanged by B1's answer call");
    }
    # T2 legitimately changes ONCE, via almanac-task.pl's own `status`
    # verb (B2's obsoleting step) -- never via the decision script's
    # traversal. Bytes before B1's answer and after B1's answer (before
    # obsoleting) must still be identical.
    if (defined $T2_id) {
        is($task_bytes_after_b1{$T2_id}, $task_bytes_before{$T2_id},
           "B6: T2's task file bytes are unchanged by B1's answer call (before it is separately obsoleted)");
    }
    for my $id ($T1_id, $T3_id, $T4_id) {
        next unless defined $id;
        is($task_bytes_after_b2{$id}, $task_bytes_after_b1{$id},
           "B6: $id's task file bytes are unchanged by B2's status/blocks/blocks--json/answer calls");
    }

    # Decision 24 (3) / review m8: T2 -- the dangling task, unguarded by the
    # loops above -- must ALSO be byte-identical from right after it is
    # obsoleted (its own legitimate change) through B2's `blocks`,
    # `blocks --json` and repeated `answer` calls. `blocked_tasks()` reads
    # T2's status but must never rewrite the file just for being dangling.
    if (defined $T2_id) {
        ok(defined($task_bytes_after_obsolete{$T2_id}), 'B6 fixture: T2\'s post-obsolete bytes were captured')
            or diag('task_bytes_after_obsolete{T2} was never set -- see B2\'s fixture');
        is($task_bytes_after_b2{$T2_id}, $task_bytes_after_obsolete{$T2_id},
           "B6: T2's task file bytes are unchanged by B2's blocks/blocks--json/answer calls (captured right after it was obsoleted)");
    } else {
        fail("B6: $_") for (
            'T2\'s post-obsolete bytes were captured',
            "T2's task file bytes are unchanged by B2's blocks/blocks--json/answer calls (captured right after it was obsoleted)",
        );
    }
}

# =============================================================================
# Decision 24 (4) / review m1: blocked_tasks() relies on `if (my $err = $@)`
# to detect that Almanac::Task::list_tasks() failed. Almanac::Store::Error
# overloads only `""` with `fallback => 1`, so a bare instance with no
# `message` key stringifies to '' and is FALSE in boolean context (confirmed
# empirically: a plain `bless({}, 'Almanac::Store::Error')` is boolean-false
# even though it is a real, non-undef reference). `$err` therefore never
# becomes true, the branch that would set `available => 0` is skipped, and
# execution falls through to `for my $t (@$list)` over the now-undef
# `$list` -- which Perl's lenient rvalue array-deref treats as an empty
# list rather than dying. The net effect is NOT a die (so "never dies"
# holds by accident) but a silently WRONG success report: `available => 1,
# reason => 'ok'` on a real, swallowed failure -- arguably worse than
# dying, and exactly the "relies on $@ being true" fragility the review
# names. Both halves are pinned: it must not die, AND it must not lie.
# =============================================================================
{
    my $ROOTM1 = tempdir(CLEANUP => 1);
    $ROOTM1 =~ s{\\}{/}g;
    my $recm1 = eval { Almanac::Inbox::file(root => $ROOTM1, title => 'm1 pin target') };
    ok(!$@ && defined($recm1), 'm1 fixture: a decision exists') or diag("error: $@");
    my $idm1 = ref($recm1) eq 'HASH' ? $recm1->{id} : 'MISSING-M1';

    my $report;
    {
        no warnings 'redefine';
        local *Almanac::Task::list_tasks = sub { die bless({}, 'Almanac::Store::Error') };
        $report = eval { Almanac::Inbox::blocked_tasks($idm1, root => $ROOTM1) };
    }
    ok(!$@, 'm1 (review): blocked_tasks() does not die when list_tasks() throws an error object whose stringification is false')
        or diag("error: " . (defined($@) ? "$@" : '(undef)'));
    is(ref($report) eq 'HASH' ? $report->{available} : undef, 0,
       'm1 (review): ...and reports available == 0 -- never a silently wrong available => 1, reason => ok');
}

# =============================================================================
# REGRESSION (blueprint tooling-backlog, package 13-almanac-decision-
# relative-path; almanac bug 20261001-184636-75fe; no architect spec --
# Decision 65, mechanical fix): almanac-inbox.pl and almanac-task.pl, invoked
# by their everyday RELATIVE path from the repo root, must never fail with
# perl's "Can't locate ... in @INC". almanac-inbox.pl's BEGIN block derives
# $TASK_PL as "$dir/almanac-task.pl" from (possibly relative) __FILE__ and
# `require`s it (almanac-inbox.pl:26-32/44) -- the exact doubled-join defect
# the bug report describes for almanac-decision.pl's sibling require, so
# this is the PRIMARY failing assertion in this file before the fix lands.
# almanac-task.pl's own BEGIN block is bareword-only (no sibling-SCRIPT
# require) and already passes; it is asserted here too so the fix (touching
# every BEGIN block named by the ledger's write_set) cannot regress it.
# =============================================================================
{
    (my $REPO_ROOT = Cwd::abs_path("$Bin/../../../..")) =~ s{\\}{/}g;
    ok(-d "$REPO_ROOT/plugins/almanac/scripts", 'REGRESSION precondition: REPO_ROOT resolves to the repo checkout')
        or BAIL_OUT("REPO_ROOT does not look like the repo root: $REPO_ROOT");

    # run_cli_relative($rel_script, @args) -> { rc, out, err } -- same
    # fork()+exec(LIST) discipline as run_cli() above (no shell string), but
    # the CHILD chdir()s to $REPO_ROOT first and $rel_script is a RELATIVE
    # path resolved against that cwd -- this process's own cwd is never
    # touched. Reproduces the bug report's literal invocation style.
    sub run_cli_relative {
        my ($rel_script, @args) = @_;
        my (undef, $outpath) = tempfile(UNLINK => 1);
        my (undef, $errpath) = tempfile(UNLINK => 1);
        my $pid = fork();
        die "run_cli_relative: fork() failed: $!" unless defined $pid;
        if ($pid == 0) {
            chdir($REPO_ROOT) or POSIX::_exit(125);
            open(STDOUT, '>', $outpath) or POSIX::_exit(126);
            open(STDERR, '>', $errpath) or POSIX::_exit(126);
            exec($^X, $rel_script, @args) or POSIX::_exit(127);
        }
        waitpid($pid, 0);
        my $rc = $? >> 8;
        my $out = slurp_text($outpath);
        my $err = slurp_text($errpath);
        return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
    }

    my $CANT_LOCATE_RE = qr/Can't locate \S+ in \@INC/;

    my $ROOTrel1 = tempdir(CLEANUP => 1); $ROOTrel1 =~ s{\\}{/}g;
    my $ri = run_cli_relative('plugins/almanac/scripts/almanac-inbox.pl', 'list', '--root', $ROOTrel1);
    unlike($ri->{out} . $ri->{err}, $CANT_LOCATE_RE,
        'REGRESSION (75fe): almanac-inbox.pl by RELATIVE path from the repo root never fails "Can\'t locate ... in @INC"')
        or diag("rc=$ri->{rc}\nout:\n$ri->{out}\nerr:\n$ri->{err}");
    is($ri->{rc}, 0, 'REGRESSION (75fe): almanac-inbox.pl "list" on an empty --root exits 0 via relative invocation')
        or diag("out:\n$ri->{out}\nerr:\n$ri->{err}");

    my $ROOTrel2 = tempdir(CLEANUP => 1); $ROOTrel2 =~ s{\\}{/}g;
    my $rt = run_cli_relative('plugins/almanac/scripts/almanac-task.pl', 'list', '--root', $ROOTrel2);
    unlike($rt->{out} . $rt->{err}, $CANT_LOCATE_RE,
        'REGRESSION (75fe): almanac-task.pl by RELATIVE path from the repo root never fails "Can\'t locate ... in @INC"')
        or diag("rc=$rt->{rc}\nout:\n$rt->{out}\nerr:\n$rt->{err}");
}

# =============================================================================
# B8 -- isolation guard, at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "B8: the live bug-reports store's report count is unchanged by this suite ($live_before before, $live_after after)");

    my $live_listing_after = live_almanac_listing();
    is_deeply($live_listing_after, $live_listing_before,
       'B8: the repo\'s own .ccpraxis-local-data/almanac/{task,task-focus,decision} listings are unchanged');
}

done_testing();
