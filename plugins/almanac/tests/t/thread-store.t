#!/usr/bin/env perl
# platform: any
# Immutable oracle for the thread store (blueprint where-things-go, package
# 02-thread-store): Almanac::Thread + Almanac::PackageLink + almanac-thread.pl,
# covering AC1, AC3-AC8, AC10 of specs/02-thread-store-spec.md (section 4).
# CRUD output-format detail lives in the sibling almanac-task-crud.t;
# concurrency lives in almanac-task-ordering.t; retirement/focus-migration
# interplay lives in almanac-task-focus.t; todo promote lives in
# almanac-todo-crud.t; doctor/guard/reminder/skills/global-counts live in
# their own sibling suites. See specs/02-thread-store-spec.md.
#
# HOUSE PATTERN for not-yet-built code: every CLI call goes through run_cli()
# (system() + tempfiles), and every direct module call is wrapped in eval{}
# so "Can't locate Almanac/Thread.pm" / "Undefined subroutine" is a caught,
# reported failure for THIS assertion, not an abort of the whole file. Today
# (pre-implementation) almanac-thread.pl, Almanac/Thread.pm and
# Almanac/PackageLink.pm all do not exist -- every assertion below is
# expected to fail for exactly that reason.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
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
# behaviour. Harmless no-op against today's (pre-03) ungated CLI: an
# unconsumed ticket just expires after BpHook's 30s window.
# ---------------------------------------------------------------------------
(my $TS_BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
require "$TS_BUTLER_SCRIPTS/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
my $TS_BSD = tempdir(CLEANUP => 1); $TS_BSD =~ s{\\}{/}g;
local $ENV{BUTLER_STATE_DIR} = $TS_BSD;
my $TS_TICKET_SEQ = 0;
sub _mint_thread_ticket {
    my (@argv) = @_;
    local $ENV{BUTLER_STATE_DIR} = $TS_BSD;
    BpHook::write_ticket(
        { session_id => 'FIXTURE-SESSION', tool_use_id => 'FT' . (++$TS_TICKET_SEQ),
          transcript_path => undef, cwd => '/fixture' },
        'almanac-thread', [ @argv ]);
}

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
sub mkroot {
    my $r = tempdir(CLEANUP => 1);
    $r =~ s{\\}{/}g;
    return $r;
}

# run_cli(@args) -> { rc, out, err }
sub run_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    local $ENV{BUTLER_STATE_DIR} = $TS_BSD;
    _mint_thread_ticket(@args);
    system(qq{perl "$THREAD_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
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
sub err_kind   { return field2($_[0], 'kind') }
sub err_detail { return field2($_[0], 'detail') }

sub decode_json_or_undef {
    my ($text) = @_;
    my $decoded = eval { JSON::PP->new->decode($text) };
    return $decoded;
}
sub show_json {
    my (@args) = @_;
    my $r = run_cli('show', @args, '--json');
    return (decode_json_or_undef($r->{out}), $r);
}
sub list_json {
    my (@args) = @_;
    my $r = run_cli('list', @args, '--json');
    return (decode_json_or_undef($r->{out}), $r);
}

sub almanac_dir { return norm_path($_[0]) . '/.ccpraxis-local-data/almanac' }
sub thread_meta_path { my ($root, $name) = @_; return almanac_dir($root) . "/thread/$name.md" }
sub thread_tasks_dir { my ($root, $name) = @_; return almanac_dir($root) . "/thread-tasks-$name" }
sub thread_log_dir   { my ($root, $name) = @_; return almanac_dir($root) . "/thread-log-$name" }

sub list_md_files {
    my ($dir) = @_;
    return wantarray ? () : 0 unless -d $dir;
    opendir(my $dh, $dir) or return wantarray ? () : 0;
    my @f = sort grep { /\.md\z/ } readdir($dh);
    closedir $dh;
    return @f;
}

# write_blueprint_package($root, $bp, $pkg, $status, %opt{archived=>0|1})
# -- builds the minimal frontmatter ledger PackageLink::resolve reads.
sub write_blueprint_package {
    my ($root, $bp, $pkg, $status, %opt) = @_;
    my $base = $opt{archived}
        ? norm_path($root) . "/.ccpraxis-local-data/blueprints/_archive/$bp/packages"
        : norm_path($root) . "/.ccpraxis-local-data/blueprints/$bp/packages";
    make_path($base);
    open(my $fh, '>:raw', "$base/$pkg.md") or die "fixture: cannot write $base/$pkg.md: $!";
    print {$fh} "---\nstatus: $status\n---\n\n# $pkg\n";
    close $fh;
    return "$base/$pkg.md";
}

# write_legacy_task_store($root, \@tasks) -- seeds the flat Store type 'task'
# directly via Almanac::Store (unmodified, shared interface), exactly the
# shape almanac-task.pl itself would have written, for migration fixtures.
BEGIN {
    my $dir = "$Bin/../../scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}
sub open_legacy_store {
    my ($root, $type) = @_;
    require Almanac::Store;
    return Almanac::Store->open(scope => 'project', type => $type, root => $root);
}
sub seed_legacy_tasklist {
    my ($root, @tasks) = @_; # each: { id, title, status, blocked_on, body }
    my $store = open_legacy_store($root, 'task');
    for my $t (@tasks) {
        my %fields = (title => $t->{title}, created => '2026-01-01T00:00:00Z', status => $t->{status});
        $fields{blocked_on} = $t->{blocked_on} if defined $t->{blocked_on};
        my @order = ('title', 'created', 'status');
        push @order, 'blocked_on' if defined $t->{blocked_on};
        $store->create(id => $t->{id}, fields => \%fields, order => \@order,
            (defined $t->{body} ? (body => $t->{body}) : ()));
    }
    return $store;
}
sub seed_legacy_focus {
    my ($root, $session_id) = @_;
    my $store = open_legacy_store($root, 'task-focus');
    $store->create(id => $session_id, fields => { focused_at => '2026-01-01T00:00:00Z' }, order => ['focused_at']);
    return $store;
}

ok(-f $THREAD_PL, 'almanac-thread.pl exists at plugins/almanac/scripts/almanac-thread.pl')
    or diag('almanac-thread.pl is not present yet -- every assertion below is expected '
          . 'to fail for exactly that reason, not any other.');

# =============================================================================
# AC1 (behaviours 1, 2) -- create: success shape, refusals.
# =============================================================================
{
    my $ROOT = mkroot();
    my $r = run_cli('create', 'foo', '--root', $ROOT);
    is($r->{rc}, 0, 'AC1: create foo exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(field0($r->{out}, 'thread'), 'foo', 'AC1: result block carries thread: foo');
    is(field0($r->{out}, 'state'), 'live', 'AC1: result block carries state: live');
    ok(-f thread_meta_path($ROOT, 'foo'), 'AC1 (behaviour 1): <almanac>/thread/foo.md exists');
    my @logs = list_md_files(thread_log_dir($ROOT, 'foo'));
    is(scalar(@logs), 1, 'AC1 (behaviour 1): exactly one log record exists after create');
    is($logs[0], '00000001.md', 'AC1 (behaviour 1): the log record id is 00000001');
    my $logtext = slurp_text(thread_log_dir($ROOT, 'foo') . '/00000001.md');
    like($logtext // '', qr/^event:\s*created\s*$/m, 'AC1 (behaviour 1): the log entry records event: created');

    my $r2 = run_cli('create', 'foo', '--root', $ROOT);
    is($r2->{rc}, 2, 'AC1 (behaviour 2): create with an existing name exits 2');
    is(err_kind($r2->{err}), 'exists', 'AC1 (behaviour 2): ...with kind: exists');

    for my $case (
        [ 'Foo',               'bad_name' ],
        [ '-x',                'bad_name' ],
        [ 'con',                'bad_name' ],
        [ 'legacy-tasklist-x', 'reserved_name' ],
    ) {
        my ($name, $detail) = @$case;
        my $rr = run_cli('create', $name, '--root', $ROOT);
        is($rr->{rc}, 2, "AC1 (behaviour 2): create '$name' exits 2");
        is(err_kind($rr->{err}), 'usage', "AC1 (behaviour 2): create '$name' kind: usage");
        is(err_detail($rr->{err}), $detail, "AC1 (behaviour 2): create '$name' detail: $detail");
    }
}

# =============================================================================
# AC1 (behaviour 3) -- add appends in order, no log entry for add.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'foo', '--root', $ROOT);
    my $ra = run_cli('add', 'foo', '--title', 'a', '--root', $ROOT);
    is($ra->{rc}, 0, 'AC1 (behaviour 3): add foo --title a exits 0') or diag($ra->{err});
    my $idA = field0($ra->{out}, 'task');
    my $rb = run_cli('add', 'foo', '--title', 'b', '--root', $ROOT);
    my $idB = field0($rb->{out}, 'task');

    my ($show) = show_json('foo', '--root', $ROOT);
    ok(ref($show) eq 'HASH', 'AC1 (behaviour 3): show --json decodes') or diag('not a hashref');
    if (ref($show) eq 'HASH') {
        is(scalar(@{ $show->{tasks} }), 2, 'AC1 (behaviour 3): two tasks are listed');
        is($show->{tasks}[0]{id}, $idA, 'AC1 (behaviour 3): a is position 1');
        is($show->{tasks}[1]{id}, $idB, 'AC1 (behaviour 3): b is position 2');
        is($show->{tasks}[0]{status}, 'pending', 'AC1 (behaviour 3): a is pending');
        is($show->{tasks}[0]{link}, undef, 'AC1 (behaviour 3): a has no link');
        is(scalar(@{ $show->{log} }), 1, 'AC1 (behaviour 3): log still holds only the created entry (add writes none)');
    }
}

# =============================================================================
# AC1 (behaviour 4) -- move/reorder.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'foo', '--root', $ROOT);
    my $idA = field0(run_cli('add', 'foo', '--title', 'a', '--root', $ROOT)->{out}, 'task');
    my $idB = field0(run_cli('add', 'foo', '--title', 'b', '--root', $ROOT)->{out}, 'task');

    my $r1 = run_cli('move', 'foo', $idB, '--first', '--root', $ROOT);
    is($r1->{rc}, 0, 'AC1 (behaviour 4): move b --first exits 0') or diag($r1->{err});
    my ($s1) = show_json('foo', '--root', $ROOT);
    is($s1->{tasks}[0]{id}, $idB, 'AC1 (behaviour 4): order is now b, a') if ref($s1) eq 'HASH';

    run_cli('move', 'foo', $idA, '--before', $idB, '--root', $ROOT);
    my ($s2) = show_json('foo', '--root', $ROOT);
    is($s2->{tasks}[0]{id}, $idA, 'AC1 (behaviour 4): move a --before b restores a, b') if ref($s2) eq 'HASH';

    my $rnoop = run_cli('move', 'foo', $idA, '--first', '--root', $ROOT);
    is(field0($rnoop->{out}, 'changed'), 'no', 'AC1 (behaviour 4): moving into its own place prints changed: no');

    my $rreorder = run_cli('reorder', 'foo', $idB, $idA, '--root', $ROOT);
    is($rreorder->{rc}, 0, 'AC1 (behaviour 4): reorder b a exits 0') or diag($rreorder->{err});
    my ($s3) = show_json('foo', '--root', $ROOT);
    is($s3->{tasks}[0]{id}, $idB, 'AC1 (behaviour 4): reorder b a -> b, a') if ref($s3) eq 'HASH';

    my $rmismatch = run_cli('reorder', 'foo', $idA, '--root', $ROOT);
    is($rmismatch->{rc}, 2, 'AC1 (behaviour 4): reorder with a partial id set exits 2');
    is(err_kind($rmismatch->{err}), 'reorder_mismatch', 'AC1 (behaviour 4): ...kind: reorder_mismatch');

    my $rbadmove = run_cli('move', 'foo', $idA, '--first', '--last', '--root', $ROOT);
    is($rbadmove->{rc}, 2, 'AC1 (behaviour 4): move --first --last exits 2');
    is(err_detail($rbadmove->{err}), 'bad_move', 'AC1 (behaviour 4): ...detail: bad_move');
}

# =============================================================================
# AC1 (behaviour 5) -- status changes write exactly one task-status entry.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'foo', '--root', $ROOT);
    my $idA = field0(run_cli('add', 'foo', '--title', 'a', '--root', $ROOT)->{out}, 'task');

    my $r1 = run_cli('status', 'foo', $idA, 'doing', '--root', $ROOT);
    is($r1->{rc}, 0, 'AC1 (behaviour 5): status foo a doing exits 0') or diag($r1->{err});
    is(field0($r1->{out}, 'changed'), 'yes', 'AC1 (behaviour 5): changed: yes');
    my ($s1) = show_json('foo', '--root', $ROOT);
    if (ref($s1) eq 'HASH') {
        my @entries = grep { $_->{event} eq 'task-status' } @{ $s1->{log} };
        is(scalar(@entries), 1, 'AC1 (behaviour 5): exactly one task-status log entry');
        is($entries[0]{task}, $idA, 'AC1 (behaviour 5): entry names the task');
        is($entries[0]{from}, 'pending', 'AC1 (behaviour 5): entry from: pending');
        is($entries[0]{to}, 'doing', 'AC1 (behaviour 5): entry to: doing');
    }
    my $r2 = run_cli('status', 'foo', $idA, 'doing', '--root', $ROOT);
    is(field0($r2->{out}, 'changed'), 'no', 'AC1 (behaviour 5): repeating the same status prints changed: no');
    my ($s2) = show_json('foo', '--root', $ROOT);
    if (ref($s2) eq 'HASH') {
        my @entries = grep { $_->{event} eq 'task-status' } @{ $s2->{log} };
        is(scalar(@entries), 1, 'AC1 (behaviour 5): no new log entry from the repeated status');
    }
}

# =============================================================================
# AC1 (behaviour 6) -- edit changes only the given field; conflicting /
# empty flag sets refuse.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'foo', '--root', $ROOT);
    my $idA = field0(run_cli('add', 'foo', '--title', 'a', '--root', $ROOT)->{out}, 'task');

    my $r1 = run_cli('edit', 'foo', $idA, '--title', 'a2', '--root', $ROOT);
    is($r1->{rc}, 0, 'AC1 (behaviour 6): edit --title a2 exits 0') or diag($r1->{err});
    my ($s1) = show_json('foo', '--root', $ROOT);
    is($s1->{tasks}[0]{title}, 'a2', 'AC1 (behaviour 6): title changed') if ref($s1) eq 'HASH';
    is($s1->{tasks}[0]{status}, 'pending', 'AC1 (behaviour 6): status unchanged by edit') if ref($s1) eq 'HASH';

    my $r2 = run_cli('edit', 'foo', $idA, '--blocked-on', 'xyz', '--clear-blocked-on', '--root', $ROOT);
    is($r2->{rc}, 2, 'AC1 (behaviour 6): --blocked-on and --clear-blocked-on together exits 2');
    is(err_detail($r2->{err}), 'blocked_on_conflict', 'AC1 (behaviour 6): ...detail: blocked_on_conflict');

    my $r3 = run_cli('edit', 'foo', $idA, '--root', $ROOT);
    is($r3->{rc}, 2, 'AC1 (behaviour 6): edit with no flags exits 2');
    is(err_detail($r3->{err}), 'nothing_to_change', 'AC1 (behaviour 6): ...detail: nothing_to_change');
}

# =============================================================================
# AC3/AC4 -- linked task: resolver live/archived/missing, all 8 statuses,
# decorated + unknown -> pending, status verb refused.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'foo', '--root', $ROOT);
    write_blueprint_package($ROOT, 'bp', '02-x', 'converging');

    my $radd = run_cli('add', 'foo', '--link', 'bp/02-x', '--root', $ROOT);
    is($radd->{rc}, 0, 'AC3: add --link bp/02-x exits 0') or diag($radd->{err});
    my ($s1) = show_json('foo', '--root', $ROOT);
    if (ref($s1) eq 'HASH') {
        is($s1->{tasks}[0]{linked}, JSON::PP::true, 'AC3: linked is true (JSON boolean)');
        is($s1->{tasks}[0]{link}, 'bp/02-x', 'AC3: link field holds bp/02-x');
        is($s1->{tasks}[0]{status}, 'converging', 'AC3: status reflects the package ledger');
        is($s1->{tasks}[0]{location}, 'live', 'AC3: location is live');
    }
    # the task RECORD on disk carries no status field
    my @files = list_md_files(thread_tasks_dir($ROOT, 'foo'));
    is(scalar(@files), 1, 'AC3: exactly one task record on disk');
    my $rawtext = slurp_text(thread_tasks_dir($ROOT, 'foo') . "/$files[0]");
    unlike($rawtext // '', qr/^status:/m, 'AC3: the on-disk task record has no status: field') if @files;

    my $taskid = field0($radd->{out}, 'task');
    my $rstatus = run_cli('status', 'foo', $taskid, 'done', '--root', $ROOT);
    is($rstatus->{rc}, 2, 'AC3/AC9: status verb on a linked task exits 2');
    is(err_kind($rstatus->{err}), 'refused', 'AC3/AC9: ...kind: refused');
    is(err_detail($rstatus->{err}), 'linked_task_has_no_status', 'AC3/AC9: ...detail: linked_task_has_no_status');
    my ($safterstatus) = show_json('foo', '--root', $ROOT);
    is(scalar(@{ $safterstatus->{log} }), 1, 'AC9: no log entry was added by the refused status change')
        if ref($safterstatus) eq 'HASH';

    # every BpState status, plus decoration, plus unknown
    my @statuses = qw(pending running converging reviewing done blocked parked dropped);
    for my $st (@statuses) {
        my $r = mkroot();
        run_cli('create', 'bar', '--root', $r);
        write_blueprint_package($r, 'bp2', '01-y', $st);
        run_cli('add', 'bar', '--link', 'bp2/01-y', '--root', $r);
        my ($sj) = show_json('bar', '--root', $r);
        is($sj->{tasks}[0]{status}, $st, "AC4: status '$st' renders as itself") if ref($sj) eq 'HASH';
    }
    {
        my $r = mkroot();
        run_cli('create', 'deco', '--root', $r);
        write_blueprint_package($r, 'bp3', '01-z', "\x{2705} done");
        run_cli('add', 'deco', '--link', 'bp3/01-z', '--root', $r);
        my ($sj) = show_json('deco', '--root', $r);
        is($sj->{tasks}[0]{status}, 'done', 'AC4: decorated "checkmark done" normalises to done') if ref($sj) eq 'HASH';
    }
    {
        my $r = mkroot();
        run_cli('create', 'weird', '--root', $r);
        write_blueprint_package($r, 'bp4', '01-w', 'not a real status');
        run_cli('add', 'weird', '--link', 'bp4/01-w', '--root', $r);
        my ($sj) = show_json('weird', '--root', $r);
        is($sj->{tasks}[0]{status}, 'pending', 'AC4: unrecognised ledger status renders as pending') if ref($sj) eq 'HASH';
    }

    # AC4 archived location
    {
        my $r = mkroot();
        run_cli('create', 'arc', '--root', $r);
        write_blueprint_package($r, 'bp5', '01-a', 'done', archived => 1);
        my $ra = run_cli('add', 'arc', '--link', 'bp5/01-a', '--root', $r);
        is($ra->{rc}, 0, 'AC4: linking a blueprint only present under _archive succeeds') or diag($ra->{err});
        my ($sj) = show_json('arc', '--root', $r);
        is($sj->{tasks}[0]{location}, 'archived', 'AC4: location is archived') if ref($sj) eq 'HASH';
        is($sj->{tasks}[0]{status}, 'done', 'AC4: archived status still resolves') if ref($sj) eq 'HASH';
    }
    # AC4 live wins when both exist
    {
        my $r = mkroot();
        run_cli('create', 'both', '--root', $r);
        write_blueprint_package($r, 'bp6', '01-b', 'running');
        write_blueprint_package($r, 'bp6', '01-b', 'done', archived => 1);
        run_cli('add', 'both', '--link', 'bp6/01-b', '--root', $r);
        my ($sj) = show_json('both', '--root', $r);
        is($sj->{tasks}[0]{location}, 'live', 'AC4: live wins over archived when both exist') if ref($sj) eq 'HASH';
        is($sj->{tasks}[0]{status}, 'running', 'AC4: live status is used') if ref($sj) eq 'HASH';
    }
    # AC4 missing
    {
        my $r = mkroot();
        run_cli('create', 'missing', '--root', $r);
        my $radd2 = run_cli('add', 'missing', '--link', 'nosuch/01-x', '--root', $r);
        is($radd2->{rc}, 2, 'AC4: add --link to a non-existent ledger exits 2');
        is(err_detail($radd2->{err}), 'link_missing', 'AC4: ...detail: link_missing');
    }
    # AC4 bad grammar
    {
        my $r = mkroot();
        run_cli('create', 'badgrammar', '--root', $r);
        my $radd3 = run_cli('add', 'badgrammar', '--link', 'has/two/slashes', '--root', $r);
        is($radd3->{rc}, 2, 'AC4: add --link with bad grammar exits 2');
        is(err_detail($radd3->{err}), 'bad_link', 'AC4: ...detail: bad_link');
    }
    # same link twice refused
    {
        my $r = mkroot();
        run_cli('create', 'dup', '--root', $r);
        write_blueprint_package($r, 'bpd', '01-d', 'pending');
        run_cli('add', 'dup', '--link', 'bpd/01-d', '--root', $r);
        my $rdup = run_cli('add', 'dup', '--link', 'bpd/01-d', '--root', $r);
        is($rdup->{rc}, 2, 'AC4: adding the same link twice in one thread exits 2');
        is(err_detail($rdup->{err}), 'link_exists', 'AC4: ...detail: link_exists');
    }
    # blocked_on refused on a linked task
    {
        my $r = mkroot();
        run_cli('create', 'nobl', '--root', $r);
        write_blueprint_package($r, 'bpn', '01-n', 'pending');
        my $rbl = run_cli('add', 'nobl', '--link', 'bpn/01-n', '--blocked-on', 'xyz', '--root', $r);
        is($rbl->{rc}, 2, 'AC4: --blocked-on with --link exits 2');
        is(err_detail($rbl->{err}), 'linked_task_no_blocked_on', 'AC4: ...detail: linked_task_no_blocked_on');
    }
}

# =============================================================================
# AC5 -- add-packages: exactly once, re-run adds only new, unknown blueprint
# writes nothing, works for an archived blueprint.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'pkgs', '--root', $ROOT);
    write_blueprint_package($ROOT, 'bp', '01-a', 'pending');
    write_blueprint_package($ROOT, 'bp', '02-b', 'pending');
    write_blueprint_package($ROOT, 'bp', '03-c', 'pending');

    my $r1 = run_cli('add-packages', 'pkgs', 'bp', '--root', $ROOT);
    is($r1->{rc}, 0, 'AC5: add-packages bp exits 0') or diag($r1->{err});
    is(field0($r1->{out}, 'total_added'), '3', 'AC5: three tasks added');
    my ($s1) = show_json('pkgs', '--root', $ROOT);
    if (ref($s1) eq 'HASH') {
        my @links = map { $_->{link} } @{ $s1->{tasks} };
        is_deeply(\@links, ['bp/01-a', 'bp/02-b', 'bp/03-c'], 'AC5: three linked tasks added in sorted package order');
        is($s1->{thread}{blueprints}, 'bp', 'AC5: blueprints records bp');
    }

    my $r2 = run_cli('add-packages', 'pkgs', 'bp', '--root', $ROOT);
    is(field0($r2->{out}, 'total_added'), '0', 'AC5: re-running adds none');

    write_blueprint_package($ROOT, 'bp', '04-d', 'pending');
    my $r3 = run_cli('add-packages', 'pkgs', 'bp', '--root', $ROOT);
    is(field0($r3->{out}, 'total_added'), '1', 'AC5: a newly-appeared package 04 is added on re-run');

    my $r4 = run_cli('add-packages', 'pkgs', 'nosuchbp', '--root', $ROOT);
    is($r4->{rc}, 2, 'AC5: add-packages on an unknown blueprint exits 2');
    is(err_detail($r4->{err}), 'blueprint_not_found', 'AC5: ...detail: blueprint_not_found');
    my ($s4) = show_json('pkgs', '--root', $ROOT);
    is(scalar(@{ $s4->{tasks} }), 4, 'AC5: nothing written by the refused unknown-blueprint call') if ref($s4) eq 'HASH';

    # archived-only blueprint
    my $ROOT2 = mkroot();
    run_cli('create', 'apkgs', '--root', $ROOT2);
    write_blueprint_package($ROOT2, 'abp', '01-x', 'done', archived => 1);
    my $r5 = run_cli('add-packages', 'apkgs', 'abp', '--root', $ROOT2);
    is($r5->{rc}, 0, 'AC5: add-packages on an archived-only blueprint succeeds') or diag($r5->{err});
    is(field0($r5->{out}, 'total_added'), '1', 'AC5: the one archived package is linked');
}

# =============================================================================
# AC6/AC7 -- log vocabulary table and the event verb.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'ev', '--root', $ROOT);

    my $r1 = run_cli('event', 'ev', '--event', 'paused', '--root', $ROOT);
    is($r1->{rc}, 2, 'AC7: event paused with no reason exits 2');
    is(err_detail($r1->{err}), 'reason_required', 'AC7: ...detail: reason_required');

    my $r2 = run_cli('event', 'ev', '--event', 'paused', '--reason', 'waiting', '--root', $ROOT);
    is($r2->{rc}, 0, 'AC7: event paused --reason waiting exits 0') or diag($r2->{err});
    is(field0($r2->{out}, 'state'), 'live', 'AC7: paused does not change state');

    my $r3 = run_cli('event', 'ev', '--event', 'handed-off', '--reason', 'r', '--root', $ROOT);
    is(field0($r3->{out}, 'state'), 'handed-off', 'AC7: handed-off sets state: handed-off');

    my $r4 = run_cli('event', 'ev', '--event', 'resumed', '--root', $ROOT);
    is(field0($r4->{out}, 'state'), 'live', 'AC7: resumed sets state: live');

    my $r5 = run_cli('event', 'ev', '--event', 'bogus', '--root', $ROOT);
    is($r5->{rc}, 2, 'AC7: event bogus exits 2');
    is(err_detail($r5->{err}), 'bad_event', 'AC7: ...detail: bad_event');

    for my $ev (qw(created archived task-status)) {
        my $r = run_cli('event', 'ev', '--event', $ev, '--root', $ROOT);
        is($r->{rc}, 2, "AC7: event $ev exits 2 (side-effect-only)");
        is(err_detail($r->{err}), 'event_not_recordable', "AC7: ...detail: event_not_recordable for $ev");
    }

    my $rlong = run_cli('event', 'ev', '--event', 'paused', '--reason', ('x' x 201), '--root', $ROOT);
    is($rlong->{rc}, 2, 'AC7: a 201-byte reason exits 2');
    is(err_detail($rlong->{err}), 'reason_too_long', 'AC7: ...detail: reason_too_long');

    my $rexact = run_cli('event', 'ev', '--event', 'paused', '--reason', ('x' x 200), '--root', $ROOT);
    is($rexact->{rc}, 0, 'AC7: a 200-byte reason is accepted') or diag($rexact->{err});

    my $rnl = run_cli('event', 'ev', '--event', 'paused', '--reason', "line1\nline2", '--root', $ROOT);
    is($rnl->{rc}, 2, 'AC7: a multi-line reason exits 2');
    is(err_detail($rnl->{err}), 'bad_reason', 'AC7: ...detail: bad_reason');

    my $rmsg = run_cli('event', 'ev', '--event', 'paused', '--message', 'x', '--root', $ROOT);
    is($rmsg->{rc}, 2, 'AC7: --message is not a flag on event');
    is(err_detail($rmsg->{err}), 'unknown_flag', 'AC7: ...detail: unknown_flag');

    # AC6: created + every event written above produces one row each; add/edit/move/reorder write none.
    my ($sj) = show_json('ev', '--root', $ROOT);
    if (ref($sj) eq 'HASH') {
        my @events = map { $_->{event} } @{ $sj->{log} };
        is($events[0], 'created', 'AC6: the first log row is created');
        ok((grep { $_ eq 'paused' } @events) >= 1, 'AC6: a paused row is present');
        ok((grep { $_ eq 'handed-off' } @events) >= 1, 'AC6: a handed-off row is present');
        ok((grep { $_ eq 'resumed' } @events) >= 1, 'AC6: a resumed row is present');
    }
}

# =============================================================================
# AC6 -- a package ledger status change writes no task-status entry.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'nolog', '--root', $ROOT);
    my $path = write_blueprint_package($ROOT, 'bpz', '01-z', 'pending');
    run_cli('add', 'nolog', '--link', 'bpz/01-z', '--root', $ROOT);
    my ($before) = show_json('nolog', '--root', $ROOT);
    my $before_count = ref($before) eq 'HASH' ? scalar(@{ $before->{log} }) : -1;

    write_blueprint_package($ROOT, 'bpz', '01-z', 'converging');
    run_cli('show', 'nolog', '--root', $ROOT); # a read that touches the thread
    my ($after) = show_json('nolog', '--root', $ROOT);
    my $after_count = ref($after) eq 'HASH' ? scalar(@{ $after->{log} }) : -1;
    is($after_count, $before_count, 'AC6: a package status change writes no task-status log entry');
}

# =============================================================================
# AC8 -- archive rule: auto-archive on any verb, never via a zero-task
# thread, never deletes, --archived listing, dropped-package fixture.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'alldone', '--root', $ROOT);
    my $idA = field0(run_cli('add', 'alldone', '--title', 'a', '--root', $ROOT)->{out}, 'task');
    run_cli('status', 'alldone', $idA, 'done', '--root', $ROOT);

    my ($sj) = show_json('alldone', '--root', $ROOT); # show triggers the archive check
    is($sj->{thread}{state}, 'archived', 'AC8: show archives a thread whose only task is done') if ref($sj) eq 'HASH';
    ok(-f thread_meta_path($ROOT, 'alldone'), 'AC8: the thread metadata record still exists (never deleted)');
    ok(-d thread_tasks_dir($ROOT, 'alldone'), 'AC8: the task store directory still exists (never deleted)');

    my ($lj) = list_json('--root', $ROOT);
    my @names = ref($lj) eq 'ARRAY' ? map { $_->{name} } @$lj : ();
    ok(!(grep { $_ eq 'alldone' } @names), 'AC8: default list omits the archived thread');
    my ($lja) = list_json('--archived', '--root', $ROOT);
    my @names2 = ref($lja) eq 'ARRAY' ? map { $_->{name} } @$lja : ();
    ok((grep { $_ eq 'alldone' } @names2), 'AC8: list --archived shows the archived thread');

    # zero-task thread never auto-archives
    run_cli('create', 'empty', '--root', $ROOT);
    run_cli('show', 'empty', '--root', $ROOT);
    my ($se) = show_json('empty', '--root', $ROOT);
    is($se->{thread}{state}, 'live', 'AC8: a zero-task thread is never auto-archived') if ref($se) eq 'HASH';

    # explicit archive, unconditional, idempotent
    my $rarc = run_cli('archive', 'empty', '--root', $ROOT);
    is($rarc->{rc}, 0, 'AC8: archive empty (zero tasks) succeeds unconditionally') or diag($rarc->{err});
    is(field0($rarc->{out}, 'changed'), 'yes', 'AC8: first archive reports changed: yes');
    my $rarc2 = run_cli('archive', 'empty', '--root', $ROOT);
    is(field0($rarc2->{out}, 'changed'), 'no', 'AC8: repeating archive reports changed: no');

    # dropped-package fixture
    my $ROOT2 = mkroot();
    run_cli('create', 'dropped', '--root', $ROOT2);
    write_blueprint_package($ROOT2, 'bpd', '01-d', 'dropped');
    run_cli('add', 'dropped', '--link', 'bpd/01-d', '--root', $ROOT2);
    my ($sd) = show_json('dropped', '--root', $ROOT2);
    is($sd->{thread}{state}, 'archived', 'AC8: a thread whose only linked task is dropped auto-archives') if ref($sd) eq 'HASH';

    # missing link blocks auto-archive -- the package is PENDING at add-packages
    # time (not done), so this fixture pins the "missing link blocks archive"
    # behaviour on its own, independent of whether add-packages itself archives
    # an already-done package (that is a separate assertion, below).
    my $ROOT3 = mkroot();
    run_cli('create', 'blocked', '--root', $ROOT3);
    write_blueprint_package($ROOT3, 'bpm', '01-m', 'pending');
    run_cli('add-packages', 'blocked', 'bpm', '--root', $ROOT3);
    # remove the ledger so the link becomes missing
    unlink(norm_path($ROOT3) . '/.ccpraxis-local-data/blueprints/bpm/packages/01-m.md');
    my ($sb) = show_json('blocked', '--root', $ROOT3);
    is($sb->{thread}{state}, 'live', 'AC8: a missing link blocks auto-archive') if ref($sb) eq 'HASH';

    # add-packages archives immediately when the package it links is ALREADY
    # done at call time -- spec 2.4/behaviour 14/AC8: every write verb except
    # create_thread/archive/migrate_legacy runs the archive check, including
    # add-packages. The thread must be archived as a DIRECT RESULT of this one
    # add-packages call: assert on add-packages's own `thread_state:` output
    # line (a read_thread the CLI performs inside the same invocation,
    # immediately after add_packages returns), not on a later show/list call.
    my $ROOT4 = mkroot();
    run_cli('create', 'already-done', '--root', $ROOT4);
    write_blueprint_package($ROOT4, 'bpq', '01-q', 'done');
    my $radd = run_cli('add-packages', 'already-done', 'bpq', '--root', $ROOT4);
    is($radd->{rc}, 0, 'AC8: add-packages with an already-done package succeeds') or diag($radd->{err});
    is(field0($radd->{out}, 'thread_state'), 'archived',
        'AC8/spec-2.4/behaviour-14: add-packages auto-archives when the newly-linked package is already done, as a direct result of that add-packages call')
        or diag($radd->{out});
}

# =============================================================================
# AC8/behaviour 15 -- refusals on an archived thread.
# =============================================================================
{
    my $ROOT = mkroot();
    run_cli('create', 'arch2', '--root', $ROOT);
    my $idA = field0(run_cli('add', 'arch2', '--title', 'a', '--root', $ROOT)->{out}, 'task');
    run_cli('status', 'arch2', $idA, 'done', '--root', $ROOT);
    run_cli('show', 'arch2', '--root', $ROOT); # triggers archive

    for my $case (
        [ ['add', 'arch2', '--title', 'z'], 'thread_archived', 'add' ],
        [ ['edit', 'arch2', $idA, '--title', 'z'], 'thread_archived', 'edit' ],
        [ ['move', 'arch2', $idA, '--first'], 'thread_archived', 'move' ],
        [ ['reorder', 'arch2', $idA], 'thread_archived', 'reorder' ],
        [ ['add-packages', 'arch2', 'whatever'], 'thread_archived', 'add-packages' ],
    ) {
        my ($args, $detail, $label) = @$case;
        my $r = run_cli(@$args, '--root', $ROOT);
        is($r->{rc}, 2, "AC8/behaviour 15: $label on an archived thread exits 2");
        is(err_detail($r->{err}), $detail, "AC8/behaviour 15: ...detail: $detail for $label");
    }
    my $rstatus = run_cli('status', 'arch2', $idA, 'obsoleted', '--root', $ROOT);
    is($rstatus->{rc}, 0, 'AC8/behaviour 15: status IS allowed on an archived thread (the doctor repair path)')
        or diag($rstatus->{err});

    for my $ev (qw(launched escalation-sent answer-applied finished)) {
        my $r = run_cli('event', 'arch2', '--event', $ev, '--root', $ROOT);
        is($r->{rc}, 0, "AC8/behaviour 15: event $ev is allowed on an archived thread") or diag($r->{err});
    }
    my $rpaused = run_cli('event', 'arch2', '--event', 'paused', '--reason', 'x', '--root', $ROOT);
    is($rpaused->{rc}, 2, 'AC8/behaviour 15: a state-changing event (paused) is refused on an archived thread');
    is(err_detail($rpaused->{err}), 'thread_archived', 'AC8/behaviour 15: ...detail: thread_archived');
}

# =============================================================================
# AC10 -- migration (behaviour 17): idempotency, crash resume, only-focus
# source, empty source.
# =============================================================================
{
    my $ROOT = mkroot();
    seed_legacy_tasklist($ROOT,
        { id => 't-done1',  title => 'Done one',     status => 'done' },
        { id => 't-obs1',   title => 'Obsoleted one', status => 'obsoleted' },
        { id => 't-pend1',  title => 'Pending one',   status => 'pending' },
        { id => 't-doing1', title => 'Doing one',     status => 'doing' },
        { id => 't-block1', title => 'Blocked one',   status => 'blocked', blocked_on => 'inbox-xyz' },
    );
    seed_legacy_focus($ROOT, 'sess-abc');

    my $r1 = run_cli('list', '--root', $ROOT); # any verb triggers migration
    is($r1->{rc}, 0, 'AC10: list (triggers migration) exits 0') or diag($r1->{err});

    my $openstore = open_legacy_store($ROOT, 'task');
    my $focusstore = open_legacy_store($ROOT, 'task-focus');
    is(scalar(@{ $openstore->ids }), 0, 'AC10: the flat task store is empty after migration');
    is(scalar(@{ $focusstore->ids }), 0, 'AC10: the task-focus store is empty after migration');

    my ($sdone) = show_json('legacy-tasklist-done', '--root', $ROOT);
    if (ref($sdone) eq 'HASH') {
        is($sdone->{thread}{state}, 'archived', 'AC10: legacy-tasklist-done is archived');
        my @ids = map { $_->{id} } @{ $sdone->{tasks} };
        is_deeply([sort @ids], [sort qw(t-done1 t-obs1)], 'AC10: legacy-tasklist-done holds exactly the done+obsoleted tasks');
    }
    my ($sopen) = show_json('legacy-tasklist-open', '--root', $ROOT);
    if (ref($sopen) eq 'HASH') {
        is($sopen->{thread}{state}, 'handed-off', 'AC10: legacy-tasklist-open is handed-off');
        my @ids = map { $_->{id} } @{ $sopen->{tasks} };
        is_deeply([sort @ids], [sort qw(t-pend1 t-doing1 t-block1)], 'AC10: legacy-tasklist-open holds exactly the rest');
        my ($blocked) = grep { $_->{id} eq 't-block1' } @{ $sopen->{tasks} };
        is($blocked->{blocked_on}, 'inbox-xyz', 'AC10: blocked_on is carried over') if $blocked;
        my @log = @{ $sopen->{log} };
        is($log[-1]{event}, 'handed-off', 'AC10: the open thread\'s log ends with handed-off');
        is($log[-1]{reason}, 'migrated from the flat tasklist', 'AC10: ...with the migration reason');
    }

    # second call: byte-identical tree under <almanac>
    my $almanac_dir = almanac_dir($ROOT);
    my %before_bytes;
    {
        require File::Find;
        File::Find::find(sub {
            return unless -f $_;
            $before_bytes{$File::Find::name} = slurp_raw($File::Find::name);
        }, $almanac_dir) if -d $almanac_dir;
    }
    run_cli('list', '--root', $ROOT);
    my %after_bytes;
    {
        require File::Find;
        File::Find::find(sub {
            return unless -f $_;
            $after_bytes{$File::Find::name} = slurp_raw($File::Find::name);
        }, $almanac_dir) if -d $almanac_dir;
    }
    is_deeply(\%after_bytes, \%before_bytes, 'AC10: a second call changes nothing under <almanac> (file list and bytes identical)');

    # only-done source
    my $ROOT2 = mkroot();
    seed_legacy_tasklist($ROOT2, { id => 'd1', title => 'only done', status => 'done' });
    run_cli('list', '--root', $ROOT2);
    ok(-f thread_meta_path($ROOT2, 'legacy-tasklist-done'), 'AC10: a done-only source creates the done thread');
    ok(!-f thread_meta_path($ROOT2, 'legacy-tasklist-open'), 'AC10: a done-only source creates no open thread');

    # empty source
    my $ROOT3 = mkroot();
    run_cli('list', '--root', $ROOT3);
    ok(!-f thread_meta_path($ROOT3, 'legacy-tasklist-done'), 'AC10: an empty source creates nothing (done)');
    ok(!-f thread_meta_path($ROOT3, 'legacy-tasklist-open'), 'AC10: an empty source creates nothing (open)');

    # crash-resume: pre-copy one task id into the open thread's task store,
    # leave the source record in place; a run must not duplicate it.
    my $ROOT4 = mkroot();
    seed_legacy_tasklist($ROOT4,
        { id => 'r1', title => 'Resumed one', status => 'pending' },
        { id => 'r2', title => 'Resumed two', status => 'pending' },
    );
    # Can't pre-create the thread's task store without Almanac::Thread
    # existing; this sub-case is exercised once Thread.pm exists. For now
    # we only assert the base migration completes without duplication on a
    # normal run (covered above); crash-resume proper needs Thread.pm's
    # tasks_type() to seed thread-tasks-legacy-tasklist-open directly.
}
{
    eval { require Almanac::Thread };
    SKIP: {
        skip 'Almanac::Thread not yet implemented -- crash-resume fixture needs tasks_type()', 2 if $@;
        my $ROOT = mkroot();
        seed_legacy_tasklist($ROOT,
            { id => 'r1', title => 'Resumed one', status => 'pending' },
            { id => 'r2', title => 'Resumed two', status => 'pending' },
        );
        my $tasks_type = Almanac::Thread::tasks_type('legacy-tasklist-open');
        my $pre_store = open_legacy_store($ROOT, $tasks_type);
        $pre_store->create(id => 'r1', fields => { title => 'Resumed one', created => '2026-01-01T00:00:00Z', status => 'pending' },
            order => ['title', 'created', 'status']);
        run_cli('list', '--root', $ROOT);
        my ($sopen) = show_json('legacy-tasklist-open', '--root', $ROOT);
        my @ids = ref($sopen) eq 'HASH' ? map { $_->{id} } @{ $sopen->{tasks} } : ();
        is(scalar(grep { $_ eq 'r1' } @ids), 1, 'AC10 crash-resume: r1 (pre-copied) appears exactly once, not duplicated');
        is(scalar(grep { $_ eq 'r2' } @ids), 1, 'AC10 crash-resume: r2 (not yet copied) is copied exactly once');
    }
}

done_testing();
