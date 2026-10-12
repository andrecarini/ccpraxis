#!/usr/bin/env perl
# platform: any
# REPURPOSED (blueprint where-things-go, package 02-thread-store): the old
# focus-surface oracle (focus/focused/unfocus) is retired along with
# almanac-task.pl's CLI. This file is now the oracle for:
#  - AC11/behaviour 18: EVERY almanac-task.pl CLI verb (including the old
#    focus/focused/unfocus verbs) and no-verb-at-all exit 2 printing exactly
#    the one retirement line; `require`/`do`-ing the file still defines
#    Almanac::Task::list_tasks and prints nothing (library half survives);
#  - AC10/behaviour 17 (the focus half): a project with ONLY focus records
#    (no tasklist entries) migrates to nothing but still empties the focus
#    store; a migrated project's task-focus store holds zero records
#    afterwards (focus records are dropped, not converted, per spec 2.5
#    step 5).
# CRUD and ordering now live in almanac-task-crud.t / almanac-task-ordering.t
# (both repurposed onto almanac-thread.pl); migration's main shape lives in
# thread-store.t. See specs/02-thread-store-spec.md sections 2.5, 2.10 and
# AC10/AC11.
#
# HOUSE PATTERN for not-yet-built/not-yet-changed code: every CLI call is
# wrapped in run_cli()/run_thread_cli() so a missing script/module or an
# unretired old CLI is a caught, reported failure for THIS assertion, not an
# abort of the whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use Cwd ();
use Encode ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $TASK_PL   = "$S/almanac-task.pl";
my $THREAD_PL = "$S/almanac-thread.pl";

my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{CLAUDE_CODE_SESSION_ID};

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

sub run_task_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$TASK_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    return { rc => $rc, out => (slurp_text($outpath) // ''), err => (slurp_text($errpath) // '') };
}
sub run_thread_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$THREAD_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    return { rc => $rc, out => (slurp_text($outpath) // ''), err => (slurp_text($errpath) // '') };
}

BEGIN {
    my $dir = "$Bin/../../scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}

my $RETIREMENT_LINE = "almanac: 'almanac task' is retired; use 'almanac thread' instead\n";

ok(-f $TASK_PL, 'almanac-task.pl still exists (library half must survive)')
    or diag('almanac-task.pl is missing entirely; every assertion below is expected to fail for that reason');

# =============================================================================
# AC11/behaviour 18 -- every old verb, and no verb, exits 2 with EXACTLY the
# retirement line on STDERR, nothing on STDOUT.
# =============================================================================
{
    my $ROOT = mkroot();
    my @old_invocations = (
        [],
        ['list'],
        ['show'],
        ['add', '--title', 'x'],
        ['insert-at', '1', '--title', 'x'],
        ['insert-before', 'id1', '--title', 'x'],
        ['insert-after', 'id1', '--title', 'x'],
        ['move-first', 'id1'],
        ['move-last', 'id1'],
        ['reorder', 'id1', 'id2'],
        ['status', 'id1', 'doing'],
        ['edit', 'id1', '--title', 'x'],
        ['focus', 'id1'],
        ['focused'],
        ['unfocus'],
    );
    for my $argv (@old_invocations) {
        my $label = @$argv ? join(' ', @$argv) : '(no verb)';
        my $r = run_task_cli(@$argv, '--root', $ROOT);
        is($r->{rc}, 2, "AC11: 'almanac-task.pl $label' exits 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is($r->{err}, $RETIREMENT_LINE, "AC11: 'almanac-task.pl $label' prints exactly the retirement line to STDERR");
        is($r->{out}, '', "AC11: 'almanac-task.pl $label' prints nothing to STDOUT");
    }
}

# =============================================================================
# AC11/behaviour 18 -- `require`/`do`-ing the file defines
# Almanac::Task::list_tasks and prints nothing / does not exit.
# =============================================================================
{
    my $WORK = tempdir(CLEANUP => 1);
    $WORK =~ s{\\}{/}g;
    my $child = "$WORK/do-child.pl";
    open(my $fh, '>', $child) or die "fixture: cannot write $child: $!";
    print {$fh} <<'DOCHILD';
#!/usr/bin/env perl
use strict; use warnings;
my ($task_pl) = @ARGV;
do $task_pl;
print "DIE=" . (defined $@ && length $@ ? $@ : '(none)') . "\n" if $@;
print "SURVIVED\n";
print "LIST-TASKS-DEFINED=" . (defined &Almanac::Task::list_tasks ? 1 : 0) . "\n";
exit 0;
DOCHILD
    close $fh;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    system(qq{perl "$child" "$TASK_PL" > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    my $out = slurp_text($outpath) // '';
    my $err = slurp_text($errpath) // '';
    is($rc, 0, 'AC11: a child that `do`s almanac-task.pl and returns exits 0 (no exit() during load)')
        or diag("stdout: $out\nstderr: $err");
    is($err, '', 'AC11: loading almanac-task.pl in-process prints nothing to STDERR');
    like($out, qr/^SURVIVED$/m, 'AC11: the child survives the `do` of almanac-task.pl');
    like($out, qr/^LIST-TASKS-DEFINED=1$/m, 'AC11: Almanac::Task::list_tasks is defined after loading the library half');
    my @lines = grep { length } split /\n/, $out;
    my @unexpected = grep { !/^(SURVIVED|LIST-TASKS-DEFINED=|DIE=)/ } @lines;
    is(scalar(@unexpected), 0, 'AC11: loading the file itself emits no STDOUT of its own')
        or diag('unexpected: ' . join(' | ', @unexpected));
}

# =============================================================================
# AC10 -- a source with ONLY focus records (no tasklist entries) migrates:
# the focus store ends up empty, and no legacy thread is created (nothing to
# migrate from the tasklist side).
# =============================================================================
{
    require Almanac::Store;
    my $ROOT = mkroot();
    my $focus_store = Almanac::Store->open(scope => 'project', type => 'task-focus', root => $ROOT);
    $focus_store->create(id => 'sess-focus-only', fields => { focused_at => '2026-01-01T00:00:00Z' }, order => ['focused_at']);

    my $r = run_thread_cli('list', '--root', $ROOT);
    is($r->{rc}, 0, 'AC10 (focus-only source): list (triggers migration) exits 0') or diag($r->{err});

    my $focus_store2 = Almanac::Store->open(scope => 'project', type => 'task-focus', root => $ROOT);
    is(scalar(@{ $focus_store2->ids }), 0, 'AC10 (focus-only source): the task-focus store is empty after migration');

    my $almanac = norm_path_local($ROOT) . '/.ccpraxis-local-data/almanac';
    ok(!-f "$almanac/thread/legacy-tasklist-done.md", 'AC10 (focus-only source): no legacy-tasklist-done thread is created');
    ok(!-f "$almanac/thread/legacy-tasklist-open.md", 'AC10 (focus-only source): no legacy-tasklist-open thread is created');
}

sub norm_path_local {
    my ($p) = @_;
    my $abs = Cwd::abs_path($p);
    $abs = $p unless defined $abs;
    $abs = Encode::decode('UTF-8', $abs) unless utf8::is_utf8($abs);
    $abs =~ s{\\}{/}g;
    $abs =~ s{/\z}{};
    return $abs;
}

done_testing();
