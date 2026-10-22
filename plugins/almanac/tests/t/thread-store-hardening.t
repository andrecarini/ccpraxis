#!/usr/bin/env perl
# platform: any
# Follow-ups to blueprint where-things-go package 02-thread-store's red-team
# and review (todos 20261002-052851-1c470000 and 20261002-052851-a6890000):
#
#   redteam S3  -- a failing legacy migration no longer refuses read-only verbs
#   redteam S4  -- global-counts root dedup folds case on case-insensitive FSes
#   redteam S5  -- the root union one refresh visits is bounded
#   redteam S6  -- one unreadable thread does not fail `list` for every thread
#   redteam N2  -- migration re-run carries a newer source edit; late open
#                  tasks are not buried in an archived thread
#   redteam N3  -- "BP/x" and "bp./x" are one link on a case-folding FS
#   redteam N4 / review S6 -- package_ids skips ledger names a link cannot
#                  name, and check_health reports an invalid link
#   review S5   -- the inbox's blocked-task scan isolates one unreadable thread
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use Cwd ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
unshift @INC, $S;
my $THREAD_PL = "$S/almanac-thread.pl";

my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{CLAUDE_CODE_SESSION_ID};
delete local $ENV{CLAUDE_CONFIG_DIR};
my $BSD = tempdir(CLEANUP => 1); $BSD =~ s{\\}{/}g;
local $ENV{BUTLER_STATE_DIR} = $BSD;

require Almanac::Store;
require Almanac::Thread;
require Almanac::PackageLink;
require Almanac::GlobalCounts;
require "$S/almanac-inbox.pl";

my $FOLD = ($^O =~ /\A(?:MSWin32|cygwin|msys)\z/) ? 1 : 0;

sub mkroot {
    my $r = tempdir(CLEANUP => 1);
    $r =~ s{\\}{/}g;
    make_path("$r/.ccpraxis-local-data/almanac");
    return $r;
}
sub spit {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{/[^/]+\z}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "fixture: cannot write $p: $!";
    print {$fh} $c;
    close $fh;
}
sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub ledger {
    my ($root, $bp, $pkg, $status) = @_;
    spit("$root/.ccpraxis-local-data/blueprints/$bp/packages/$pkg.md", "---\nstatus: $status\n---\n");
}
# Thread write verbs need butler's hook ticket for the exact argv; mint one
# per call the way thread-store.t does.
(my $BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
require "$BUTLER_SCRIPTS/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
my $TICKET_SEQ = 0;
sub run_cli {
    my (@args) = @_;
    BpHook::write_ticket(
        { session_id => 'FIXTURE-SESSION', tool_use_id => 'TH' . (++$TICKET_SEQ),
          transcript_path => undef, cwd => '/fixture' },
        'almanac-thread', [ @args ]);
    my (undef, $out) = tempfile(UNLINK => 1);
    my (undef, $err) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$THREAD_PL" $argstr > "$out" 2> "$err"});
    return { rc => $? >> 8, out => slurp($out), err => slurp($err) };
}
sub corrupt_tasks_of {
    my ($root, $thread) = @_;
    my $st = Almanac::Store->open(scope => 'project', type => Almanac::Thread::tasks_type($thread), root => $root);
    spit($st->dir . "/zz-broken.md", "this is not a record\n");
}
sub err_of { my $e = shift; return ref $e ? ($e->{detail} // $e->{kind}) : "$e" }

# =============================================================================
# N4 / review S6: package_ids filters; add_packages links only valid ids.
# =============================================================================
{
    my $R = mkroot();
    ledger($R, 'bp1', '01-good', 'pending');
    spit("$R/.ccpraxis-local-data/blueprints/bp1/packages/README.md", "x\n");
    spit("$R/.ccpraxis-local-data/blueprints/bp1/packages/has space.md", "x\n");
    my $ids = Almanac::PackageLink::package_ids('bp1', root => $R)->{ids};
    is_deeply($ids, ['01-good', 'README'], 'N4: package_ids keeps grammar-valid ids only (README is a valid segment)')
        or diag explain $ids;
    ok(!grep({ $_ eq 'has space' } @$ids), 'N4: a ledger name with a space is not offered as a package id');

    Almanac::Thread::create_thread('t1', root => $R);
    my $added = eval { Almanac::Thread::add_packages('t1', ['bp1'], root => $R) };
    is($@, '', 'N4: add_packages succeeds');
    my @links = sort map { $_->{link} } @{ Almanac::Thread::tasks('t1', root => $R) };
    is_deeply(\@links, ['bp1/01-good', 'bp1/README'], 'N4: no task linked to an id the grammar rejects');
}

# =============================================================================
# review S6: check_health reports an invalid link (written around the API).
# =============================================================================
{
    my $R = mkroot();
    Almanac::Thread::create_thread('t2', root => $R);
    my $st = Almanac::Store->open(scope => 'project', type => Almanac::Thread::tasks_type('t2'), root => $R);
    $st->insert_last(fields => { title => 'bad', created => '2026-01-01T00:00:00Z', link => 'a/b/c' },
        order => [qw(title created link)]);
    my $h = Almanac::Thread::check_health(root => $R);
    my @inv = grep { $_->{kind} eq 'link_invalid' } @{ $h->{findings} || [] };
    is(scalar(@inv), 1, 'review S6: check_health reports the invalid link as link_invalid');
}

# =============================================================================
# N3: link aliasing on a case-folding filesystem.
# =============================================================================
{
    is(Almanac::PackageLink::link_key('BP/01-x'), $FOLD ? 'bp/01-x' : 'BP/01-x', 'N3: link_key folds case only where the FS does');
    is(Almanac::PackageLink::link_key('bp./01-x.'), $FOLD ? 'bp/01-x' : 'bp./01-x.', 'N3: link_key strips trailing dots only where the FS does');
    SKIP: {
        skip 'N3: case-sensitive filesystem; distinct spellings are distinct ledgers', 2 unless $FOLD;
        my $R = mkroot();
        ledger($R, 'bp', '01-x', 'pending');
        Almanac::Thread::create_thread('t3', root => $R);
        Almanac::Thread::add_task('t3', root => $R, link => 'bp/01-x');
        eval { Almanac::Thread::add_task('t3', root => $R, link => 'BP/01-X') };
        is(err_of($@), 'link_exists', 'N3: a case variant of an existing link is refused link_exists');
        Almanac::Thread::add_packages('t3', ['BP'], root => $R);
        is(scalar(@{ Almanac::Thread::tasks('t3', root => $R) }), 1, 'N3: add_packages via a case variant links nothing twice');
    }
}

# =============================================================================
# S6: one unreadable thread does not fail `list`.
# =============================================================================
{
    my $R = mkroot();
    Almanac::Thread::create_thread('aaa-good', root => $R);
    Almanac::Thread::create_thread('bbb-bad', root => $R);
    Almanac::Thread::add_task('aaa-good', root => $R, title => 'one');
    Almanac::Thread::add_task('bbb-bad', root => $R, title => 'two');
    corrupt_tasks_of($R, 'bbb-bad');
    my $r = run_cli('list', '--root', $R);
    is($r->{rc}, 0, 'S6: list exits 0 with one thread unreadable') or diag($r->{err});
    like($r->{out}, qr/^thread: aaa-good$/m, 'S6: the readable thread is listed');
    like($r->{out}, qr/^thread: bbb-bad\n(?:  .*\n)*  tasks: unreadable$/m, 'S6: the broken thread is listed as unreadable');
}

# =============================================================================
# S3: a failing migration warns for read-only verbs, still refuses writes.
# =============================================================================
{
    my $R = mkroot();
    Almanac::Thread::create_thread('t5', root => $R);
    my $flat = Almanac::Store->open(scope => 'project', type => 'task', root => $R);
    spit($flat->dir . "/broken.md", "garbage\n");
    my $r = run_cli('list', '--root', $R);
    is($r->{rc}, 0, 'S3: list still works when the legacy migration fails') or diag($r->{err});
    like($r->{err}, qr/legacy tasklist migration failed \(kind=malformed/, 'S3: ...and warns with the cause');
    like($r->{out}, qr/^thread: t5$/m, 'S3: ...and lists the threads');
    my $w = run_cli('create', 't6', '--root', $R);
    isnt($w->{rc}, 0, 'S3: a writing verb still refuses while migration fails');
    like($w->{err}, qr/tasklist_migration_failed/, 'S3: ...refused for the migration, not something else') or diag($w->{err});
}

# =============================================================================
# N2: migration re-run carries the newer source; late open tasks resurface.
# =============================================================================
{
    my $R = mkroot();
    my $flat = Almanac::Store->open(scope => 'project', type => 'task', root => $R);
    $flat->create(id => '20260101-000000-aaaa', fields => { title => 'edited later', status => 'pending',
        created => '2026-01-01T00:00:00Z' }, order => [qw(title status created)]);
    # The state an interrupted earlier run leaves: the copy exists, stale.
    Almanac::Thread::create_thread('legacy-tasklist-open', root => $R, owner_kind => 'none', owner_id => '-',
        actor => 'migration', _allow_reserved => 1);
    my $ts = Almanac::Store->open(scope => 'project', type => Almanac::Thread::tasks_type('legacy-tasklist-open'), root => $R);
    $ts->insert_last(id => '20260101-000000-aaaa', fields => { title => 'original', status => 'pending',
        created => '2026-01-01T00:00:00Z' }, order => [qw(title created status)]);
    my $res = eval { Almanac::Thread::migrate_legacy(root => $R) };
    is($@, '', 'N2: migration re-run succeeds');
    is($ts->read('20260101-000000-aaaa')->{fields}{title}, 'edited later', 'N2: the newer source edit reaches the copy');
    ok(!$flat->exists('20260101-000000-aaaa'), 'N2: ...and the source is then removed');

    # Archive it, then a late flat open task appears.
    Almanac::Thread::set_task_status('legacy-tasklist-open', '20260101-000000-aaaa', 'done', root => $R);
    is(Almanac::Thread::read_thread('legacy-tasklist-open', root => $R)->{state}, 'archived', 'N2: fixture: the legacy thread archived');
    $flat->create(id => '20260102-000000-bbbb', fields => { title => 'late', status => 'pending',
        created => '2026-01-02T00:00:00Z' }, order => [qw(title status created)]);
    eval { Almanac::Thread::migrate_legacy(root => $R) };
    is($@, '', 'N2: late migration succeeds');
    my $th = Almanac::Thread::read_thread('legacy-tasklist-open', root => $R);
    is($th->{state}, 'handed-off', 'N2: the archived legacy thread is handed back out for its late open task');
    ok(!defined $th->{archived_at}, 'N2: ...with archived_at cleared');
}

# =============================================================================
# review S5: inbox blocked_tasks isolates one unreadable thread.
# =============================================================================
{
    my $R = mkroot();
    Almanac::Thread::create_thread('aaa', root => $R);
    Almanac::Thread::create_thread('bbb', root => $R);
    Almanac::Thread::add_task('aaa', root => $R, title => 'waits', blocked_on => '20260101-000000-cccc');
    Almanac::Thread::add_task('bbb', root => $R, title => 'x');
    my $rep = Almanac::Inbox::blocked_tasks('20260101-000000-cccc', root => $R);
    is($rep->{available}, 1, 'review S5: fixture sanity: report available');
    is(scalar(@{ $rep->{tasks} }), 1, 'review S5: the blocked thread task is found');
    corrupt_tasks_of($R, 'bbb');
    $rep = Almanac::Inbox::blocked_tasks('20260101-000000-cccc', root => $R);
    is($rep->{available}, 1, 'review S5: one unreadable thread does not blank the report');
    is(scalar(@{ $rep->{tasks} || [] }), 1, 'review S5: ...the other thread\'s blocked task is still reported');
    is_deeply($rep->{unreadable_threads}, ['bbb'], 'review S5: ...and the unreadable thread is named');
}

# =============================================================================
# S4 / S5: global-counts dedup and bound.
# =============================================================================
{
    my $home = tempdir(CLEANUP => 1); $home =~ s{\\}{/}g;
    my $R = mkroot();
    Almanac::Thread::create_thread('g1', root => $R);
    # Drive-letter spellings: Cwd::abs_path keeps the case of a "C:/..." path
    # it is given (a mount-relative /tmp path it would normalise), which is
    # exactly the redteam's measured double-count.
    my $spelled = Cwd::abs_path($R);
    $spelled =~ s{\A/([A-Za-z])/}{uc($1) . ':/'}e;
    my $variant = $FOLD ? lc($spelled) : $spelled;
    spit("$home/.claude/claude-code-vault/.registry-local.json",
        JSON::PP->new->encode({ projects => { p => { path => $variant } } }));
    my $res = Almanac::GlobalCounts::refresh(home => $home, record_root => $spelled);
    ok($res->{ok}, 'S4: refresh ok') or diag explain $res;
    is($res->{counts}{thread}{open}, 1, 'S4: a root reached under two case spellings is counted once');

    my @roots = map { mkroot() } 1 .. 3;
    Almanac::Thread::create_thread("c$_", root => $roots[$_]) for 0 .. 2;
    my $home2 = tempdir(CLEANUP => 1); $home2 =~ s{\\}{/}g;
    no warnings 'once';
    local $Almanac::GlobalCounts::MAX_ROOTS = 2;
    Almanac::GlobalCounts::refresh(home => $home2, record_root => $_) for @roots;
    my $res2 = Almanac::GlobalCounts::refresh(home => $home2);
    is($res2->{counts}{thread}{open}, 2, 'S5: refresh visits at most $MAX_ROOTS roots');
    is(scalar(@{ $res2->{counts}{thread}{projects} }), 2, 'S5: ...and records at most that many, newest kept');
}

# =============================================================================
# pkg04 review S3 (todo 20261002-113836-bd470000): record_event's opt-in
# require_no_doing gate, taken under the thread lock.
# =============================================================================
{
    my $R = mkroot();
    Almanac::Thread::create_thread('t9', root => $R);
    my $t = Almanac::Thread::add_task('t9', root => $R, title => 'busy');
    Almanac::Thread::set_task_status('t9', $t->{id}, 'doing', root => $R);
    eval { Almanac::Thread::record_event('t9', 'handed-off', root => $R, reason => 'bye', require_no_doing => 1) };
    is(err_of($@), 'task_doing', 'bd47: require_no_doing refuses a hand-off while an unlinked task is doing');
    is(Almanac::Thread::read_thread('t9', root => $R)->{state}, 'live', 'bd47: ...and nothing changed');
    Almanac::Thread::set_task_status('t9', $t->{id}, 'pending', root => $R);
    my $th = eval { Almanac::Thread::record_event('t9', 'handed-off', root => $R, reason => 'bye', require_no_doing => 1) };
    is($@, '', 'bd47: with nothing doing the hand-off goes through');
    is($th->{state}, 'handed-off', 'bd47: ...and the thread is handed off');
}

done_testing();
