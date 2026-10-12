#!/usr/bin/env perl
# platform: any
# REPURPOSED (blueprint where-things-go, package 02-thread-store): the old
# flat-tasklist ordering oracle is retired along with almanac-task.pl's CLI.
# This file is now the oracle for AC2 (specs/02-thread-store-spec.md,
# behaviour 7): ten concurrent `add` processes on one thread all exit 0 and
# leave exactly ten tasks with ten distinct ids and ten distinct ranks;
# two consecutive `show --json` calls report the same order; concurrent
# `status` calls on DIFFERENT tasks each append exactly one log entry with
# contiguous, gapless, non-duplicate sequence ids. Non-concurrent CRUD
# output-format correctness lives in almanac-task-crud.t; CRUD behaviour
# lives in thread-store.t. See specs/02-thread-store-spec.md section 3
# (behaviour 7) and AC2.
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
use Time::HiRes ();

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
# the EXACT argv of every run_cli()/spawn_concurrent() call below so this
# file's existing fixtures keep working once that gate exists -- pure
# migration, not new behaviour.
# ---------------------------------------------------------------------------
(my $TO_BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
my $TO_BPHOOK_PM = "$TO_BUTLER_SCRIPTS/BpHook.pm";
require $TO_BPHOOK_PM unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
my $TO_BSD = tempdir(CLEANUP => 1); $TO_BSD =~ s{\\}{/}g;
local $ENV{BUTLER_STATE_DIR} = $TO_BSD;
my $TO_TICKET_SEQ = 0;
sub _mint_thread_ticket {
    my (@argv) = @_;
    local $ENV{BUTLER_STATE_DIR} = $TO_BSD;
    BpHook::write_ticket(
        { session_id => 'FIXTURE-SESSION', tool_use_id => 'FT' . (++$TO_TICKET_SEQ),
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
    local $ENV{BUTLER_STATE_DIR} = $TO_BSD;
    _mint_thread_ticket(@args);
    system(qq{perl "$THREAD_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}
sub field0 { my ($t, $k) = @_; return undef unless defined $t; return $1 if $t =~ /^\Q$k\E:\s(\S+)$/m; return undef }
sub decode_json_or_undef { my ($t) = @_; return eval { JSON::PP->new->decode($t) } }

sub bounded_wait_for_file {
    my ($path, $deadline_s) = @_;
    my $deadline = Time::HiRes::time() + $deadline_s;
    while (!-e $path) {
        return 0 if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.02);
    }
    return 1;
}

# spawn_concurrent(\@arg_lists, $workdir) -- launches one background child
# per arg list (never wait/waitpid'd: each writes its own done.<n> sentinel
# with RC=<n> and stdout captured), returns once every child has signalled
# done (bounded) or times out individual children.
my $CHILD_PL;
sub write_child_once {
    return $CHILD_PL if $CHILD_PL;
    my $dir = tempdir(CLEANUP => 1);
    $dir =~ s{\\}{/}g;
    $CHILD_PL = "$dir/ordering-child.pl";
    open(my $fh, '>', $CHILD_PL) or die $!;
    print {$fh} <<'CHILD';
#!/usr/bin/env perl
use strict; use warnings;
my ($workdir, $n, $thread_pl, @rest) = @ARGV;
my $argstr = join(' ', map { qq{"$_"} } @rest);
my $out = `perl "$thread_pl" $argstr`;
my $rc = $? >> 8;
open(my $of, '>', "$workdir/out.$n") or die $!;
print {$of} $out;
close $of;
open(my $df, '>', "$workdir/done.$n") or die $!;
print {$df} "RC=$rc\n";
close $df;
exit 0;
CHILD
    close $fh;
    return $CHILD_PL;
}
sub spawn_concurrent {
    my ($workdir, @arg_lists) = @_;
    write_child_once();
    my $n = 0;
    for my $args (@arg_lists) {
        $n++;
        _mint_thread_ticket(@$args);
        my @argv = ($workdir, $n, $THREAD_PL, @$args);
        my $argstr = join(' ', map { qq{"$_"} } @argv);
        system(qq{perl "$CHILD_PL" $argstr > "$workdir/spawn-log.$n" 2>&1 &});
    }
    my @results;
    for my $i (1 .. $n) {
        unless (bounded_wait_for_file("$workdir/done.$i", 60)) {
            push @results, { rc => undef, out => undef, timeout => 1 };
            next;
        }
        my $donetext = slurp_text("$workdir/done.$i") // '';
        my ($rc) = $donetext =~ /RC=(\d+)/;
        push @results, { rc => $rc, out => slurp_text("$workdir/out.$i") };
    }
    return @results;
}

ok(-f $THREAD_PL, 'almanac-thread.pl exists') or diag('not present yet; every assertion below is expected to fail for exactly that reason');

# =============================================================================
# AC2 -- ten concurrent `add` processes.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'conc1', '--root', $ROOT);
    my $workdir = tempdir(CLEANUP => 1);
    $workdir =~ s{\\}{/}g;
    my @arg_lists = map { [ 'add', 'conc1', '--title', "task $_", '--root', $ROOT ] } (1 .. 10);
    my @results = spawn_concurrent($workdir, @arg_lists);

    is(scalar(@results), 10, 'AC2: ten children reported done');
    my @bad = grep { !defined($_->{rc}) || $_->{rc} != 0 } @results;
    is(scalar(@bad), 0, 'AC2: all ten concurrent add processes exit 0')
        or diag(join("\n", map { "rc=" . ($_->{rc} // '(timeout)') } @bad));

    my $r = run_cli('show', 'conc1', '--json', '--root', $ROOT);
    my $j1 = decode_json_or_undef($r->{out});
    if (ref($j1) eq 'HASH') {
        is(scalar(@{ $j1->{tasks} }), 10, 'AC2: the thread holds exactly ten tasks');
        my @ids = map { $_->{id} } @{ $j1->{tasks} };
        my %seen_id;
        $seen_id{$_}++ for @ids;
        is(scalar(grep { $seen_id{$_} > 1 } keys %seen_id), 0, 'AC2: ten distinct task ids (no collision)');
        my @ranks = map { $_->{rank} } @{ $j1->{tasks} };
        my %seen_rank;
        $seen_rank{$_}++ for grep { defined } @ranks;
        is(scalar(grep { $seen_rank{$_} > 1 } keys %seen_rank), 0, 'AC2: ten distinct ranks (no collision)');
    }

    my $r2 = run_cli('show', 'conc1', '--json', '--root', $ROOT);
    my $j2 = decode_json_or_undef($r2->{out});
    if (ref($j1) eq 'HASH' && ref($j2) eq 'HASH') {
        my @ids1 = map { $_->{id} } @{ $j1->{tasks} };
        my @ids2 = map { $_->{id} } @{ $j2->{tasks} };
        is_deeply(\@ids2, \@ids1, 'AC2: two consecutive show --json calls report the same order');
    }
}

# =============================================================================
# AC2 -- concurrent `status` calls on DIFFERENT tasks each append exactly
# one entry; log ids are exactly 00000001..0000000N, no gap, no duplicate.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'conc2', '--root', $ROOT);
    my @ids;
    for (1 .. 5) {
        my $r = run_cli('add', 'conc2', '--title', "t$_", '--root', $ROOT);
        push @ids, field0($r->{out}, 'task');
    }
    my $workdir = tempdir(CLEANUP => 1);
    $workdir =~ s{\\}{/}g;
    my @arg_lists = map { [ 'status', 'conc2', $ids[$_], 'doing', '--root', $ROOT ] } (0 .. 4);
    my @results = spawn_concurrent($workdir, @arg_lists);
    my @bad = grep { !defined($_->{rc}) || $_->{rc} != 0 } @results;
    is(scalar(@bad), 0, 'AC2: all five concurrent status processes (different tasks) exit 0')
        or diag(join("\n", map { "rc=" . ($_->{rc} // '(timeout)') } @bad));

    my $r = run_cli('show', 'conc2', '--json', '--root', $ROOT);
    my $j = decode_json_or_undef($r->{out});
    if (ref($j) eq 'HASH') {
        my @statusentries = grep { $_->{event} eq 'task-status' } @{ $j->{log} };
        is(scalar(@statusentries), 5, 'AC2: exactly five task-status entries (one per concurrent status change)');
        my %by_task;
        $by_task{$_->{task}}++ for @statusentries;
        is(scalar(grep { $by_task{$_} != 1 } keys %by_task), 0, 'AC2: each task got exactly one task-status entry');
        my @seq_ids = map { $_->{id} } @{ $j->{log} };
        my @sorted = sort { $a cmp $b } @seq_ids;
        is_deeply(\@seq_ids, \@sorted, 'AC2: log ids are in ascending order')
            if @seq_ids == @sorted;
        my $n = scalar(@seq_ids);
        my @expected = map { sprintf('%08d', $_) } (1 .. $n);
        is_deeply([sort @seq_ids], \@expected, 'AC2: log ids are exactly 00000001..0000000N, no gap, no duplicate');
    }
}

done_testing();
