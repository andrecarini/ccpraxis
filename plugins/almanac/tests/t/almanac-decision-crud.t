#!/usr/bin/env perl
# platform: any
# Immutable oracle for the CRUD surface of the operator's inbox script
# (blueprint where-things-go, package 01-inbox-rename, superseding the former
# pending-decisions script of blueprint almanac-records / package
# 08-pending-decisions): file/list/show/answer, unanswered-vs-answered
# distinguishability (DC-DIST), the never-blocks-the-filing-turn contract
# (DC-NB), the single accessor / module-shape contract that
# hook-continuity-remake 09 depends on, project-root resolution, and (new)
# the optional --link/--choices fields and the structured answer path.
# Traversal (blocked_tasks / DC-TRAV / DC-DANG) lives in the sibling
# almanac-decision-blocks.t. See specs/01-inbox-rename-spec.md and
# specs/08-pending-decisions-spec.md.
#
# HOUSE PATTERN for a not-yet-built script: every call into the CLI or the
# module is wrapped in eval{} / run_cli() so "Undefined subroutine" / "Can't
# open perl script" is a caught, reported failure for THIS assertion rather
# than an abort of the whole file -- every assertion below is expected to
# fail for exactly that reason right now, not for a fixture defect of this
# file's own making.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use Cwd ();
use Encode ();
use JSON::PP ();
use POSIX qw(WNOHANG);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $INBOX_PL = "$S/almanac-inbox.pl";
my $TASK_PL     = "$S/almanac-task.pl";

# ---------------------------------------------------------------------------
# no real user state: every spawn and every in-process call below inherits
# this file-scoped, per-file tempdir HOME/USERPROFILE/ALMANAC_HOME; the
# ambient env vars a store might otherwise consult are deleted.
# ---------------------------------------------------------------------------
my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{BP_PROJECT_ROOT};
delete local $ENV{CLAUDE_CODE_SESSION_ID};

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
# quote (D3's title `reply "A" or "B"` loses its quotes before perl ever
# sees them) -- fork()+exec(LIST) hands argv straight to the OS with no
# shell in between, the discipline this repo's process supervisors use for their
# own child spawn. STDOUT/STDERR are reopened onto files in the CHILD only
# (never an in-memory scalar, per CLAUDE.md's Windows landmine list; never
# the parent's own STDOUT/STDERR, which stay untouched throughout).
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
sub run_dec { return run_cli($INBOX_PL, @_) }

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

# read_frontmatter($path) -> (\@keys, \%kv)
sub read_frontmatter {
    my ($path) = @_;
    my @lines = read_all_lines($path);
    my (@keys, %kv);
    my $in = 0;
    for my $l (@lines) {
        if ($l =~ /\A---/) {
            last if $in;
            $in = 1;
            next;
        }
        if ($in && $l =~ /\A([A-Za-z0-9_]+):\s?(.*?)\r?\n?\z/) {
            push @keys, $1;
            $kv{$1} = $2;
        }
    }
    return (\@keys, \%kv);
}

sub decode_json_or_undef {
    my ($text) = @_;
    return eval { JSON::PP->new->decode($text) };
}

sub inbox_files_in {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return @f;
}

sub inbox_dir_for {
    return norm_path($_[0]) . '/.ccpraxis-local-data/almanac/inbox';
}

# parse_list_default($text) -> \@groups (each: id, status, title, answer)
sub parse_list_default {
    my ($text) = @_;
    my @groups;
    while ($text =~ /^item:\s(\S+)\n\s{2}status:\s(\S+)\n\s{2}title:\s(.*)\n\s{2}answer:\s(.*)$/mg) {
        push @groups, { id => $1, status => $2, title => $3, answer => $4 };
    }
    return \@groups;
}

# ---------------------------------------------------------------------------
# live-store sanity + isolation guard (house convention, spec S4.3) -- before
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
    for my $t (qw(task task-focus decision inbox)) {
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

do $INBOX_PL if -f $INBOX_PL;

# =============================================================================
# D9 / D8 (part) -- module-shape rules, by grep. Run whether or not the
# script loaded. D9 serves the single-accessor contract hook-continuity-
# remake 09 depends on; D8's source-grep half (no <STDIN>/sleep/alarm, exit
# only inside `unless (caller)`) lives here too, house pattern per C9 in
# almanac-task-crud.t.
# =============================================================================
{
    if (-f $INBOX_PL) {
        my @lines = read_all_lines($INBOX_PL);
        my $caller_line;
        for my $i (0 .. $#lines) {
            $caller_line = $i + 1 if !defined($caller_line) && $lines[$i] =~ /unless\s*\(\s*caller\s*\)/;
        }
        my (@exit_hits, @stdin_hits, @sleep_hits, @alarm_hits, @global_hits,
            @insert_hits, @package_hits, @sub_open_hits, @open_call_hits);
        for my $i (0 .. $#lines) {
            my $line   = $lines[$i];
            next if $line =~ /^\s*#/;
            my $lineno = $i + 1;
            push @exit_hits, "$INBOX_PL:$lineno: $line"
                if ($line =~ /\bexit\s*\(/ || $line =~ /\bexit\s+\d/)
                && (!defined($caller_line) || $lineno < $caller_line);
            push @stdin_hits, "$INBOX_PL:$lineno: $line" if $line =~ /<STDIN>/;
            push @sleep_hits, "$INBOX_PL:$lineno: $line" if $line =~ /\bsleep\s*\(/;
            push @alarm_hits, "$INBOX_PL:$lineno: $line" if $line =~ /\balarm\s*\(/;
            push @global_hits, "$INBOX_PL:$lineno: $line" if $line =~ /--global/;
            push @insert_hits, "$INBOX_PL:$lineno: $line"
                if $line =~ /\binsert_(?:first|last|before|after)\b/;
            push @package_hits, "$INBOX_PL:$lineno: $line" if $line =~ /^\s*package\s+Almanac::Inbox\s*;/;
            push @sub_open_hits, "$INBOX_PL:$lineno: $line" if $line =~ /^\s*sub\s+open_inbox\b/;
            push @open_call_hits, $lineno if $line =~ /->open\s*\(/;
        }
        ok(defined $caller_line, 'D9: the file contains an `unless (caller)` main guard line')
            or diag('no `unless (caller)` found');
        unless (ok(@exit_hits == 0, 'D8/D9: no `exit` statement occurs before the `unless (caller)` line')) {
            diag($_) for @exit_hits;
        }
        unless (ok(@stdin_hits == 0, 'D8: the file never reads <STDIN>')) { diag($_) for @stdin_hits }
        unless (ok(@sleep_hits == 0, 'D8: the file never calls sleep()')) { diag($_) for @sleep_hits }
        unless (ok(@alarm_hits == 0, 'D8: the file never calls alarm()')) { diag($_) for @alarm_hits }
        unless (ok(@global_hits == 0, "D9: the file never mentions the literal '--global'")) { diag($_) for @global_hits }
        unless (ok(@insert_hits == 0, 'D9: the file never calls insert_first/insert_last/insert_before/insert_after'))
            { diag($_) for @insert_hits }
        ok(@package_hits >= 1, 'D9: the file declares `package Almanac::Inbox;`');
        ok(@sub_open_hits >= 1, 'D9: the file declares `sub open_inbox`');

        # Decision 24 (2): the real property (review M3) is "exactly one
        # Store->open call in the file, and it lives inside sub
        # open_inbox" -- a literal-count-of-'decision' proxy can be (and
        # was) satisfied by an in-file bypass helper that routes a SECOND
        # store-type value through a different spelling while the grep
        # still sees one 'decision' token. Counting ->open( calls and
        # locating the sole one structurally cannot be fooled that way.
        unless (is(scalar(@open_call_hits), 1, 'D9: exactly one ->open( call occurs in the whole file')) {
            diag("lines: " . join(',', @open_call_hits));
        }
        my ($od_start, $od_end);
        for my $i (0 .. $#lines) {
            if ($lines[$i] =~ /^\s*sub\s+open_inbox\b/) {
                $od_start = $i + 1;
                for my $j ($i + 1 .. $#lines) {
                    if ($lines[$j] =~ /^\s*sub\s+\w+/) { $od_end = $j; last }
                }
                $od_end = scalar(@lines) unless defined $od_end;
                last;
            }
        }
        if (defined($od_start) && @open_call_hits == 1) {
            ok($open_call_hits[0] >= $od_start && $open_call_hits[0] <= $od_end,
               "D9: the sole ->open( call (line $open_call_hits[0]) lives inside sub open_inbox (lines $od_start..$od_end)");
        } else {
            fail('D9: the sole ->open( call lives inside sub open_inbox');
        }

        # Decision 24 (2), continued: the _decision_type bypass helper
        # (review M3's "in-file bypass route ready to use") is removed
        # entirely -- count() writes the literal 'decision' directly.
        my @helper_hits = grep { /\b_decision_type\b/ } @lines;
        unless (is(scalar(@helper_hits), 0, 'D9: the file no longer defines or calls a _decision_type helper')) {
            diag($_) for @helper_hits;
        }
    } else {
        fail("D8/D9: $_") for (
            'the file contains an `unless (caller)` main guard line',
            'no `exit` statement occurs before the `unless (caller)` line',
            'the file never reads <STDIN>',
            'the file never calls sleep()',
            'the file never calls alarm()',
            "the file never mentions the literal '--global'",
            'the file never calls insert_first/insert_last/insert_before/insert_after',
            'the file declares `package Almanac::Inbox;`',
            'the file declares `sub open_inbox`',
            'exactly one ->open( call occurs in the whole file',
            'the sole ->open( call lives inside sub open_inbox',
            'the file no longer defines or calls a _decision_type helper',
        );
    }
}

# =============================================================================
# D1 -- section 3.1 items 1-3, 5: file/show create/read contract, via CLI.
# =============================================================================
{
    my $ROOT1 = tempdir(CLEANUP => 1);
    $ROOT1 =~ s{\\}{/}g;
    my $DIR1 = inbox_dir_for($ROOT1);

    # item 1: file --title on a fresh project with no decision store.
    my $r = run_dec('file', '--title', 'Ship the new API?', '--root', $ROOT1);
    is($r->{rc}, 0, 'D1/item1: file --title on a project with no decision store exits 0') or diag("stderr: $r->{err}");
    is(field0($r->{out}, 'status'), 'unanswered', 'D1/item1: result block carries status: unanswered');
    is(field0($r->{out}, 'changed'), 'yes', 'D1/item1: result block carries changed: yes');
    my $id1 = field0($r->{out}, 'id');
    ok(defined $id1 && length $id1, 'D1/item1: result block carries a non-empty id:');
    ok(defined field0($r->{out}, 'path'), 'D1/item1: result block carries a path:');
    ok(defined field0($r->{out}, 'rev'), 'D1/item1: result block carries a rev:');

    my @files1 = inbox_files_in($DIR1);
    is(scalar(@files1), 1, 'D1/item1: exactly one file was written under <root>/.ccpraxis-local-data/almanac/inbox/');
    is($files1[0], "$id1.md", "D1/item1: the file's stem equals the result block's id") if @files1;

    my $path1 = "$DIR1/$id1.md";
    my ($keys1, $kv1) = read_frontmatter($path1);
    is_deeply($keys1, [qw(id writer title status created)],
        'AC4: a plain file writes frontmatter keys id writer title status created, in that order, no link/choices key')
        if @$keys1;
    ok(!exists $kv1->{link}, 'AC4: a plain file has no link field');
    ok(!exists $kv1->{choices}, 'AC4: a plain file has no choices field');
    is($kv1->{status} // '', 'unanswered', 'D1/item1: frontmatter status is unanswered');
    like($kv1->{created} // '', qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, 'D1/item1: created matches the ISO-8601 UTC pattern');
    ok(!exists $kv1->{answer}, 'D1/item1: no answer field is present');
    ok(!exists $kv1->{answered_at}, 'D1/item1: no answered_at field is present');
    ok(!exists $kv1->{rank}, 'D1/item1: no rank field is present (decisions are never ranked)');

    # item 2: missing/blank/CR-LF title -- none of these create a file.
    my $rmiss = run_dec('file', '--root', $ROOT1);
    is($rmiss->{rc}, 2, 'D1/item2: file with no --title at all exits 2') or diag("stderr: $rmiss->{err}");
    is(err_kind($rmiss->{err}), 'usage', 'D1/item2: ...kind: usage');
    is(field2($rmiss->{err}, 'detail'), 'missing_title', 'D1/item2: ...detail: missing_title');

    my $rws = run_dec('file', '--title', '   ', '--root', $ROOT1);
    is($rws->{rc}, 2, 'D1/item2: file --title <whitespace-only> exits 2') or diag("stderr: $rws->{err}");
    is(err_kind($rws->{err}), 'usage', 'D1/item2: ...kind: usage');
    is(field2($rws->{err}, 'detail'), 'bad_title', 'D1/item2: ...detail: bad_title (whitespace-only)');

    my $rcrlf = run_dec('file', '--title', "line1\r\nline2", '--root', $ROOT1);
    is($rcrlf->{rc}, 2, 'D1/item2: file --title containing CR/LF exits 2') or diag("stderr: $rcrlf->{err}");
    is(field2($rcrlf->{err}, 'detail'), 'bad_title', 'D1/item2: ...detail: bad_title (CR/LF)');
    is($rcrlf->{out}, '', 'D1/item2: STDOUT is empty on a refused file');

    my @files_after_bad = inbox_files_in($DIR1);
    is(scalar(@files_after_bad), 1, 'D1/item2: none of the three refused files created a file (still exactly one)');

    # item 3: --id collision, and a bad id; --body stored verbatim.
    my $r3a = run_dec('file', '--title', 'Fixed id decision', '--id', 'decision-d1-x',
                       '--body', "context line one\ncontext line two\n", '--root', $ROOT1);
    is($r3a->{rc}, 0, 'D1/item3 fixture: file --id decision-d1-x --body ... succeeds') or diag("stderr: $r3a->{err}");
    my $r3b = run_dec('file', '--title', 'Dup id decision', '--id', 'decision-d1-x', '--root', $ROOT1);
    is($r3b->{rc}, 2, 'D1/item3: file --id <existing> exits 2') or diag("stderr: $r3b->{err}");
    is(err_kind($r3b->{err}), 'exists', 'D1/item3: ...kind: exists');
    my $r3c = run_dec('file', '--title', 'Bad id decision', '--id', 'a/b', '--root', $ROOT1);
    is($r3c->{rc}, 2, 'D1/item3: file --id a/b exits 2');
    is(err_kind($r3c->{err}), 'bad_id', 'D1/item3: ...kind: bad_id');

    my $rshow3 = run_dec('show', 'decision-d1-x', '--root', $ROOT1);
    is($rshow3->{rc}, 0, 'D1/item3: show <fixed id> exits 0') or diag("stderr: $rshow3->{err}");
    like($rshow3->{out}, qr/context line one\ncontext line two\n\z/,
         'D1/item3: --body is stored verbatim and printed by show after the blank line');

    # item 5: show on a missing id.
    my $r5 = run_dec('show', 'no-such-decision', '--root', $ROOT1);
    is($r5->{rc}, 2, 'D1/item5: show <unknown id> exits 2');
    is(err_kind($r5->{err}), 'not_found', 'D1/item5: ...kind: not_found');
    is($r5->{out}, '', 'D1/item5: STDOUT is empty');
}

# =============================================================================
# D2 -- section 3.1 item 4: list default groups + counts; list --json.
# =============================================================================
{
    my $ROOT2 = tempdir(CLEANUP => 1);
    $ROOT2 =~ s{\\}{/}g;

    my ($rec1, $rec2);
    eval {
        $rec1 = Almanac::Inbox::file(root => $ROOT2, title => 'Decision One');
        Almanac::Inbox::answer($rec1->{id}, root => $ROOT2, answer => 'yes, proceed');
        $rec2 = Almanac::Inbox::file(root => $ROOT2, title => 'Decision Two');
    };
    ok(!$@, 'D2 fixture: two decisions exist (in-process), the first answered, the second not')
        or diag("error: $@");
    my $id1 = ref($rec1) eq 'HASH' ? $rec1->{id} : 'MISSING-D1';
    my $id2 = ref($rec2) eq 'HASH' ? $rec2->{id} : 'MISSING-D2';

    my $rlist = run_dec('list', '--root', $ROOT2);
    is($rlist->{rc}, 0, 'D2: list exits 0') or diag("stderr: $rlist->{err}");
    my $groups = parse_list_default($rlist->{out});
    my ($g1) = grep { $_->{id} eq $id1 } @$groups;
    my ($g2) = grep { $_->{id} eq $id2 } @$groups;
    ok(defined $g1, 'D2: list default shows a group for the answered decision');
    ok(defined $g2, 'D2: list default shows a group for the unanswered decision');
    is($g1->{status}, 'answered', 'D2: the answered decision reports status: answered') if $g1;
    is($g1->{answer}, 'yes, proceed', 'D2: the answered decision reports its answer text') if $g1;
    is($g2->{status}, 'unanswered', 'D2: the unanswered decision reports status: unanswered') if $g2;
    is($g2->{answer}, '-', "D2: the unanswered decision reports answer: -") if $g2;
    is(field0($rlist->{out}, 'unanswered'), '1', 'D2: unanswered: 1');
    is(field0($rlist->{out}, 'answered'), '1', 'D2: answered: 1');
    is(field0($rlist->{out}, 'total'), '2', 'D2: total: 2');

    my $rjson = run_dec('list', '--json', '--root', $ROOT2);
    is($rjson->{rc}, 0, 'D2: list --json exits 0') or diag("stderr: $rjson->{err}");
    my $decoded = decode_json_or_undef($rjson->{out});
    ok(ref($decoded) eq 'ARRAY', 'D2: list --json decodes to an array') or diag("raw: $rjson->{out}");
    if (ref($decoded) eq 'ARRAY') {
        my ($j1) = grep { $_->{id} eq $id1 } @$decoded;
        my ($j2) = grep { $_->{id} eq $id2 } @$decoded;
        is(ref($j1) eq 'HASH' ? $j1->{status} : undef, 'answered', 'D2 --json: the answered decision has status answered');
        is(ref($j1) eq 'HASH' ? $j1->{answer} : undef, 'yes, proceed', 'D2 --json: the answered decision carries its answer string');
        is(ref($j2) eq 'HASH' ? $j2->{status} : undef, 'unanswered', 'D2 --json: the unanswered decision has status unanswered');
        ok(ref($j2) eq 'HASH' && exists($j2->{answer}) && !defined($j2->{answer}),
           'D2 --json: the unanswered decision has answer: null (present but null, never omitted)');
    }

    # empty / absent store.
    my $ROOTE = tempdir(CLEANUP => 1);
    $ROOTE =~ s{\\}{/}g;
    my $re = run_dec('list', '--root', $ROOTE);
    is($re->{rc}, 0, 'D2 (empty store): list exits 0') or diag("stderr: $re->{err}");
    my $trimmed = $re->{out};
    $trimmed =~ s/^\s+//; $trimmed =~ s/\s+$//;
    is($trimmed, "unanswered: 0\nanswered: 0\ntotal: 0", 'D2 (empty store): list prints only the three zero lines');

    my $listE = eval { Almanac::Inbox::list_items(root => $ROOTE) };
    ok(!$@, 'D2 (empty store): list_items() in-process does not die') or diag("error: $@");
    is_deeply($listE, [], 'D2 (empty store): list_items() returns an empty arrayref');
}

# =============================================================================
# D3 -- section 3.1 item 6: byte-for-byte title round trip.
# =============================================================================
{
    my $ROOT3 = tempdir(CLEANUP => 1);
    $ROOT3 =~ s{\\}{/}g;
    my $title = 'Use vendor A or vendor B? | pick one | reply "A" or "B"';
    my $rf = run_dec('file', '--title', $title, '--root', $ROOT3);
    is($rf->{rc}, 0, 'D3: file --title "<... | ... |...>" exits 0') or diag("stderr: $rf->{err}");
    my $id = field0($rf->{out}, 'id');
    ok(defined $id, 'D3 fixture: file succeeds') or diag("stderr: $rf->{err}");

    my $rlist = run_dec('list', '--root', $ROOT3);
    my $groups = parse_list_default($rlist->{out});
    my ($g) = grep { $_->{id} eq $id } @$groups;
    is($g->{title}, $title, 'D3: list default round-trips the title byte-for-byte, including | separators') if $g;

    my $rshow = run_dec('show', $id, '--root', $ROOT3);
    like($rshow->{out}, qr/^title:\s\Q$title\E$/m, 'D3: show round-trips the same title byte-for-byte');

    # in-process: a utf8-flagged non-ASCII title reads back `eq`.
    my $ROOT3B = tempdir(CLEANUP => 1);
    $ROOT3B =~ s{\\}{/}g;
    my $u_title = "caf\x{e9} decision";
    utf8::upgrade($u_title);
    ok(utf8::is_utf8($u_title), 'D3 fixture: the in-process title is utf8-flagged (the bug precondition)');
    my $urec = eval { Almanac::Inbox::file(root => $ROOT3B, title => $u_title) };
    ok(!$@ && defined($urec), 'D3: in-process file() with a utf8-flagged non-ASCII title does not die')
        or diag("error: $@");
    SKIP: {
        skip 'file() died -- see the diag above', 1 unless defined $urec;
        my $back = eval { Almanac::Inbox::read_item($urec->{id}, root => $ROOT3B) };
        ok(!$@ && ref($back) eq 'HASH' && $back->{fields}{title} eq $u_title,
           'D3: read_item() reads the non-ASCII title back `eq` the original string');
    }
}

# =============================================================================
# D4 -- section 3.3 items 10-13: answer's five-way branch.
# =============================================================================
{
    # CLI: items 10 and 11 (a real answer, then a repeat of the same answer).
    my $ROOT4 = tempdir(CLEANUP => 1);
    $ROOT4 =~ s{\\}{/}g;
    my $DIR4 = inbox_dir_for($ROOT4);
    my $rf = run_dec('file', '--title', 'Answerable via CLI', '--root', $ROOT4);
    my $id4 = field0($rf->{out}, 'id');
    ok(defined $id4, 'D4 fixture: file succeeds') or diag("stderr: $rf->{err}");
    my $path4 = "$DIR4/$id4.md";

    my $r10 = run_dec('answer', $id4, '--answer', 'go with vendor A', '--root', $ROOT4);
    is($r10->{rc}, 0, 'D4/item10: answer D --answer A on an unanswered D exits 0') or diag("stderr: $r10->{err}");
    is(field0($r10->{out}, 'changed'), 'yes', 'D4/item10: result block carries changed: yes');
    is(field0($r10->{out}, 'status'), 'answered', 'D4/item10: result block carries status: answered');
    my ($k4, $kv4) = read_frontmatter($path4);
    is($kv4->{status} // '', 'answered', 'D4/item10: frontmatter status is answered');
    is($kv4->{answer} // '', 'go with vendor A', 'D4/item10: frontmatter answer matches');
    ok(exists $kv4->{answered_at}, 'D4/item10: frontmatter carries answered_at');
    my $bytes_after_10 = slurp_raw($path4);

    my $r11 = run_dec('answer', $id4, '--answer', 'go with vendor A', '--root', $ROOT4);
    is($r11->{rc}, 0, 'D4/item11: repeating with the same answer exits 0') or diag("stderr: $r11->{err}");
    is(field0($r11->{out}, 'changed'), 'no', 'D4/item11: result block carries changed: no');
    my $bytes_after_11 = slurp_raw($path4);
    is($bytes_after_11, $bytes_after_10, 'D4/item11: the record file bytes are byte-identical after the no-op repeat');

    # in-process: item 12 (different answer -> already_answered, bytes unchanged).
    my $r12 = eval { Almanac::Inbox::answer($id4, answer => 'go with vendor B', root => $ROOT4) };
    my $err12 = $@;
    ok(!defined($r12) && $err12, 'D4/item12: answer() with a DIFFERENT answer on an answered D dies');
    is(ref($err12) =~ /::Error$/ ? $err12->{kind} : undef, 'usage', 'D4/item12: ...kind: usage');
    is(ref($err12) =~ /::Error$/ ? $err12->{detail} : undef, 'already_answered', 'D4/item12: ...detail: already_answered');
    my $bytes_after_12 = slurp_raw($path4);
    is($bytes_after_12, $bytes_after_10, 'D4/item12: the record file bytes are still byte-identical after the refused re-answer');

    # in-process: item 13's four sub-cases.
    my $r13a = eval { Almanac::Inbox::answer($id4, root => $ROOT4) };
    my $err13a = $@;
    ok(!defined($r13a) && $err13a, 'D4/item13: answer() with no answer option dies');
    is(ref($err13a) =~ /::Error$/ ? $err13a->{detail} : undef, 'missing_answer', 'D4/item13: ...detail: missing_answer');

    my $r13b = eval { Almanac::Inbox::answer($id4, answer => '   ', root => $ROOT4) };
    my $err13b = $@;
    ok(!defined($r13b) && $err13b, 'D4/item13: answer() with a whitespace-only answer dies');
    is(ref($err13b) =~ /::Error$/ ? $err13b->{detail} : undef, 'bad_answer', 'D4/item13: ...detail: bad_answer (whitespace-only)');

    my $r13c = eval { Almanac::Inbox::answer($id4, answer => "a\r\nb", root => $ROOT4) };
    my $err13c = $@;
    ok(!defined($r13c) && $err13c, 'D4/item13: answer() with a CR/LF answer dies');
    is(ref($err13c) =~ /::Error$/ ? $err13c->{detail} : undef, 'bad_answer', 'D4/item13: ...detail: bad_answer (CR/LF)');

    my $r13d = eval { Almanac::Inbox::answer('no-such-decision-13', answer => 'x', root => $ROOT4) };
    my $err13d = $@;
    ok(!defined($r13d) && $err13d, 'D4/item13: answer() with an unknown decision id dies');
    is(ref($err13d) =~ /::Error$/ ? $err13d->{kind} : undef, 'not_found', 'D4/item13: ...kind: not_found');

    # item 13's stale --expect-rev: a fresh, still-UNANSWERED decision whose
    # rev is bumped out from under a caller by a direct Store write (a benign
    # extra field), so the CAS in answer()'s rule-3 branch actually fires.
    my $rf5 = run_dec('file', '--title', 'Conflict target', '--root', $ROOT4);
    my $id5 = field0($rf5->{out}, 'id');
    ok(defined $id5, 'D4/item13 fixture: a second unanswered decision exists') or diag("stderr: $rf5->{err}");
    my $stale = eval { Almanac::Inbox::read_item($id5, root => $ROOT4) };
    ok(!$@ && ref($stale) eq 'HASH', 'D4/item13 fixture: the stale rev is captured before the bump') or diag("error: $@");
    my $stale_rev = ref($stale) eq 'HASH' ? $stale->{rev} : 'deadbeef' x 8;
    eval {
        require Almanac::Store;
        my $dstore = Almanac::Store->open(scope => 'project', type => 'inbox', root => $ROOT4);
        $dstore->update($id5, expect => { rev => $stale_rev, fields => $stale->{fields} }, set => { probe => 'x' });
    };
    ok(!$@, 'D4/item13 fixture: a direct Store update bumps the rev without changing status') or diag("error: $@");
    my $before13e = slurp_raw(inbox_dir_for($ROOT4) . "/$id5.md");
    my $r13e = eval { Almanac::Inbox::answer($id5, answer => 'y', expect_rev => $stale_rev, root => $ROOT4) };
    my $err13e = $@;
    ok(!defined($r13e) && $err13e, 'D4/item13: answer() with a stale --expect-rev dies');
    is(ref($err13e) =~ /::Error$/ ? $err13e->{kind} : undef, 'conflict', 'D4/item13: ...kind: conflict');
    my $after13e = slurp_raw(inbox_dir_for($ROOT4) . "/$id5.md");
    is($after13e, $before13e, 'D4/item13: the record file bytes are unchanged after the refused conflict');
}

# =============================================================================
# D4b -- Decision 24 (1) / review M1 regression: repeating a NON-ASCII
# answer OVER THE CLI reports changed: no (item 11's idempotence rule),
# never already_answered. `$ans` arrives from @ARGV as UNDECODED UTF-8
# BYTES; the stored answer comes back from Store as decoded CHARACTERS --
# comparing a multi-byte encoding against its own one-character decoding
# with `eq` never matches. The argument must be genuine multi-byte UTF-8
# bytes (what a real OS argv actually carries for non-ASCII text), not a
# single Perl \x{e9}-style character that Perl may store as one raw
# Latin-1 byte and which would then round-trip by coincidence (Latin-1
# 0xE9 IS Unicode U+00E9) without ever exercising the bug -- hence the
# explicit Encode::encode() below, deliberately NOT a bare literal.
# =============================================================================
{
    my $ROOT4B = tempdir(CLEANUP => 1);
    $ROOT4B =~ s{\\}{/}g;
    my $DIR4B = inbox_dir_for($ROOT4B);
    my $nonascii_chars  = "resposta \x{e9} essa: vers\x{e3}o com acentua\x{e7}\x{e3}o";
    my $nonascii_answer = Encode::encode('UTF-8', $nonascii_chars);

    my $rf4b = run_dec('file', '--title', 'Non-ASCII answer target', '--root', $ROOT4B);
    my $id4b = field0($rf4b->{out}, 'id');
    ok(defined $id4b, 'D4b fixture: file succeeds') or diag("stderr: $rf4b->{err}");

    my $rfirst = run_dec('answer', $id4b, '--answer', $nonascii_answer, '--root', $ROOT4B);
    is($rfirst->{rc}, 0, 'D4b: the first non-ASCII answer exits 0') or diag("stderr: $rfirst->{err}");
    is(field0($rfirst->{out}, 'changed'), 'yes', 'D4b: the first non-ASCII answer reports changed: yes');
    my $bytes_after_first = slurp_raw("$DIR4B/$id4b.md");

    my $rrepeat = run_dec('answer', $id4b, '--answer', $nonascii_answer, '--root', $ROOT4B);
    is($rrepeat->{rc}, 0, "D4b (review M1): repeating the SAME non-ASCII answer exits 0 (never already_answered)")
        or diag("stderr: $rrepeat->{err}");
    is(field0($rrepeat->{out}, 'changed'), 'no',
       'D4b (review M1): repeating the SAME non-ASCII answer reports changed: no, not a refusal');
    isnt(err_kind($rrepeat->{err}), 'usage', 'D4b (review M1): the repeat is never refused with kind: usage');
    my $bytes_after_repeat = slurp_raw("$DIR4B/$id4b.md");
    is($bytes_after_repeat, $bytes_after_first,
       'D4b: the record file bytes are byte-identical after the non-ASCII no-op repeat');
}

# =============================================================================
# D5 -- section 3.3 item 14: Decision 22 regression -- a utf8-upgraded,
# field-derived id still resolves (not not_found).
# =============================================================================
{
    my $ROOT5 = tempdir(CLEANUP => 1);
    $ROOT5 =~ s{\\}{/}g;
    my $rec = eval { Almanac::Inbox::file(root => $ROOT5, title => 'D5 target') };
    ok(!$@ && defined($rec), 'D5 fixture: file() succeeds') or diag("error: $@");
    SKIP: {
        skip 'file() died -- see the diag above', 3 unless defined $rec;
        my $field_id = $rec->{fields}{id};
        ok(defined $field_id, 'D5 fixture: the record carries fields->{id}');
        utf8::upgrade($field_id);
        ok(utf8::is_utf8($field_id), 'D5 fixture: the id is now utf8-flagged (the Decision 22 precondition)');
        my $result = eval { Almanac::Inbox::answer($field_id, answer => 'ok', root => $ROOT5) };
        my $err = $@;
        ok(!$err, 'D5: answer() with a utf8-upgraded, field-derived id does not die') or diag("error: $err");
        my $kind = (ref($err) =~ /::Error$/) ? $err->{kind} : undef;
        isnt($kind, 'not_found', 'D5: ...specifically never dies with kind: not_found');
    }
}

# =============================================================================
# D6 -- section 3.5 items 21-22: count().
# =============================================================================
{
    my $ROOT6 = tempdir(CLEANUP => 1);
    $ROOT6 =~ s{\\}{/}g;
    my $c0 = eval { Almanac::Inbox::count(root => $ROOT6) };
    ok(!$@, 'D6: count() on an absent store does not die') or diag("error: $@");
    if (ref($c0) eq 'HASH') {
        is($c0->{type}, 'inbox', 'D6: type is the string inbox');
        my $p0 = $c0->{project};
        if (ref($p0) eq 'HASH') {
            is($p0->{available}, 1, 'D6: available == 1 on an absent store');
            is($p0->{reason}, 'ok', 'D6: reason == ok on an absent store');
            is($p0->{unanswered}, 0, 'D6: unanswered == 0 on an absent store');
            is($p0->{answered}, 0, 'D6: answered == 0 on an absent store');
            is($p0->{total}, 0, 'D6: total == 0 on an absent store');
        } else {
            fail("D6: project.$_ on an absent store") for qw(available reason unanswered answered total);
        }
    } else {
        fail('D6: count() returns a hashref on an absent store');
    }

    my ($d1, $d2);
    eval {
        $d1 = Almanac::Inbox::file(root => $ROOT6, title => 'D6 one');
        $d2 = Almanac::Inbox::file(root => $ROOT6, title => 'D6 two');
        Almanac::Inbox::answer($d1->{id}, answer => 'ok', root => $ROOT6);
    };
    ok(!$@, 'D6 fixture: two decisions filed, one answered') or diag("error: $@");
    my $c1 = eval { Almanac::Inbox::count(root => $ROOT6) };
    ok(!$@, 'D6: count() after filing two and answering one does not die') or diag("error: $@");
    if (ref($c1) eq 'HASH' && ref($c1->{project}) eq 'HASH') {
        is_deeply([sort keys %{ $c1->{project} }], [sort qw(available reason unanswered answered total)],
            'D6: the project key has exactly available/reason/unanswered/answered/total');
        is($c1->{project}{unanswered}, 1, 'D6: unanswered == 1');
        is($c1->{project}{answered}, 1, 'D6: answered == 1');
        is($c1->{project}{total}, 2, 'D6: total == 2');
    } else {
        fail('D6: the project key has exactly available/reason/unanswered/answered/total');
        fail('D6: unanswered == 1');
        fail('D6: answered == 1');
        fail('D6: total == 2');
    }

    # item 22: out-of-band status value.
    my $ROOT6X = tempdir(CLEANUP => 1);
    $ROOT6X =~ s{\\}{/}g;
    eval {
        require Almanac::Store;
        my $s = Almanac::Store->open(scope => 'project', type => 'inbox', root => $ROOT6X);
        $s->create(id => 'D-oob', fields => { title => 'x', status => 'archived', created => '2020-01-01T00:00:00Z' },
                   order => [qw(title status created)]);
    };
    ok(!$@, 'D6 fixture: an out-of-band status decision record is created directly via Store') or diag("error: $@");
    my $cx = eval { Almanac::Inbox::count(root => $ROOT6X) };
    ok(!$@, 'D6: count() does not die on an out-of-band status value') or diag("error: $@");
    if (ref($cx) eq 'HASH' && ref($cx->{project}) eq 'HASH') {
        is($cx->{project}{available}, 0, 'D6: available == 0 on an out-of-band status value');
        is($cx->{project}{reason}, 'bad_status', 'D6: reason == bad_status');
    } else {
        fail('D6: available == 0 on an out-of-band status value');
        fail('D6: reason == bad_status');
    }

    # item 22: a malformed decision file.
    my $ROOT6M = tempdir(CLEANUP => 1);
    $ROOT6M =~ s{\\}{/}g;
    my $mdir = inbox_dir_for($ROOT6M);
    make_path($mdir);
    write_raw("$mdir/bad-decision.md", "not a frontmatter record at all\n");
    my $cm = eval { Almanac::Inbox::count(root => $ROOT6M) };
    ok(!$@, 'D6: count() does not die on a malformed decision file') or diag("error: $@");
    if (ref($cm) eq 'HASH' && ref($cm->{project}) eq 'HASH') {
        is($cm->{project}{available}, 0, 'D6: available == 0 on a malformed decision file');
        is($cm->{project}{reason}, 'malformed', 'D6: reason == malformed');
    } else {
        fail('D6: available == 0 on a malformed decision file');
        fail('D6: reason == malformed');
    }
}

# =============================================================================
# D7 -- section 3.2 item 7: filing never reads STDIN, never blocks. Real
# process, STDIN connected to a pipe THIS test holds open and never writes.
# House pattern: fork()+exec()+waitpid(WNOHANG), never a
# shell-level '&' (which this test cannot poll/kill deterministically).
# =============================================================================
my ($d7_out, $d7_err, $d7_status, $d7_reaped);
{
    my $ROOT7 = tempdir(CLEANUP => 1);
    $ROOT7 =~ s{\\}{/}g;
    my $DIR7 = inbox_dir_for($ROOT7);
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);

    pipe(my $rd, my $wr) or die "D7 fixture: pipe() failed: $!";

    my $pid = fork();
    if (!defined $pid) {
        fail('D7: fork() succeeds');
    } elsif ($pid == 0) {
        close $wr;
        open(STDIN, '<&', $rd) or POSIX::_exit(126);
        open(STDOUT, '>', $outpath) or POSIX::_exit(126);
        open(STDERR, '>', $errpath) or POSIX::_exit(126);
        exec($^X, $INBOX_PL, 'file', '--title', 'D7 never reads stdin', '--root', $ROOT7)
            or POSIX::_exit(127);
    } else {
        close $rd;
        my $deadline = time() + 20;
        while (time() < $deadline) {
            my $r = waitpid($pid, WNOHANG);
            if ($r == $pid) { $d7_reaped = 1; last; }
            select(undef, undef, undef, 0.05);
        }
        if (!$d7_reaped) {
            kill('KILL', $pid);
            waitpid($pid, 0);
            close $wr;
            fail('D7: file exited within the 20s deadline while STDIN pipe stayed open and unwritten');
            fail('D7: exit code is 0');
            fail('D7: a decision record exists on disk');
        } else {
            $d7_status = $? >> 8;
            close $wr;
            ok(1, 'D7: file exited within the 20s deadline while STDIN pipe stayed open and unwritten');
            is($d7_status, 0, 'D7: exit code is 0') or diag("stderr: " . (slurp_text($errpath) // ''));
            $d7_out = slurp_text($outpath);
            $d7_err = slurp_text($errpath);
            my $id7 = field0($d7_out, 'id');
            ok(defined($id7) && -f "$DIR7/$id7.md", 'D7: a decision record exists on disk')
                or diag("stdout: " . ($d7_out // '') . " stderr: " . ($d7_err // ''));
        }
    }
}

# =============================================================================
# D8 -- section 3.2 items 8-9: no hook-control tokens on stdout; in-process
# file() returns and the caller's next statement runs.
# =============================================================================
{
    if (defined $d7_out) {
        my @bad_lines = grep { /^\{/ } split /\n/, $d7_out;
        is(scalar(@bad_lines), 0, 'D8: no stdout line of the file run begins with `{`');
        unlike($d7_out, qr/"decision"/, 'D8: stdout never contains the token "decision" (JSON hook-control key)');
        unlike($d7_out, qr/"continue"/, 'D8: stdout never contains the token "continue"');
        unlike($d7_out, qr/"stopReason"/, 'D8: stdout never contains the token "stopReason"');
        is($d7_status, 0, 'D8: the file run\'s exit code is 0 (never 2, which a hook runner treats as a block)');
    } else {
        fail($_) for (
            'D8: no stdout line of the file run begins with `{`',
            'D8: stdout never contains the token "decision" (JSON hook-control key)',
            'D8: stdout never contains the token "continue"',
            'D8: stdout never contains the token "stopReason"',
            "D8: the file run's exit code is 0 (never 2, which a hook runner treats as a block)",
        );
    }

    my $ROOT8 = tempdir(CLEANUP => 1);
    $ROOT8 =~ s{\\}{/}g;
    my $before_marker = 1;
    my $rec8 = eval { Almanac::Inbox::file(root => $ROOT8, title => 'D8 in-process') };
    my $after_marker = 2;
    ok(!$@ && defined($rec8), 'D8: in-process file() returns a record without dying') or diag("error: $@");
    is($after_marker, 2, "D8: control returned to the caller after file() -- the next statement ran");
}

# =============================================================================
# D10 -- section 3.6 item 23: root resolution from a subdirectory, no --root.
# =============================================================================
{
    my $PROJECT = tempdir(CLEANUP => 1);
    $PROJECT =~ s{\\}{/}g;
    make_path("$PROJECT/.ccpraxis-local-data");
    my $SUBDIR = "$PROJECT/src/deep";
    make_path($SUBDIR);
    ok(-d $SUBDIR, 'D10 fixture: the project subdirectory exists');

    my $cwd_before = Cwd::getcwd();
    chdir($SUBDIR) or die "D10 fixture: cannot chdir to $SUBDIR: $!";
    my $r = eval { run_cli($INBOX_PL, 'file', '--title', 'D10 from a subdirectory') };
    chdir($cwd_before);

    is($r->{rc}, 0, 'D10: file with no --root, run from a project subdirectory, exits 0') or diag("stderr: $r->{err}");
    my $id10 = field0($r->{out}, 'id');
    ok(defined $id10, 'D10: result block carries an id');
    my $DIR10 = inbox_dir_for($PROJECT);
    ok(defined($id10) && -f "$DIR10/$id10.md",
       'D10: the record lands under THIS project\'s own .ccpraxis-local-data/almanac/inbox/, not elsewhere');
}

# =============================================================================
# DLK -- AC7/AC8: --link and --choices on `file`, spec section 2.3.
# =============================================================================
{
    my $ROOTLK = tempdir(CLEANUP => 1);
    $ROOTLK =~ s{\\}{/}g;
    my $DIRLK = inbox_dir_for($ROOTLK);

    # AC7: accepted link shapes + choices normalization.
    for my $case (
        ['wtg', 'accept,drop'],
        ['wtg/08-blueprint-parks', 'accept,drop'],
        ['wtg/06-x/03-scorer-rich--6aab33e21a8bbf3', 'accept,drop'],
    ) {
        my ($link, $choices) = @$case;
        my $r = run_dec('file', '--title', "link $link", '--link', $link, '--choices', $choices, '--root', $ROOTLK);
        is($r->{rc}, 0, "AC7: file --link $link --choices $choices exits 0") or diag("stderr: $r->{err}");
        my $id = field0($r->{out}, 'id');
        ok(defined $id, "AC7: result carries an id for link $link");
        my ($k, $kv) = read_frontmatter("$DIRLK/$id.md");
        is($kv->{link} // '', $link, "AC7: stored link field equals '$link'");
        is($kv->{choices} // '', $choices, "AC7: stored choices field equals '$choices'");
    }
    my $rspc = run_dec('file', '--title', 'spaced choices', '--choices', ' a , b ', '--root', $ROOTLK);
    is($rspc->{rc}, 0, 'AC7: file --choices \' a , b \' exits 0') or diag("stderr: $rspc->{err}");
    my $idspc = field0($rspc->{out}, 'id');
    my (undef, $kvspc) = read_frontmatter("$DIRLK/$idspc.md");
    is($kvspc->{choices} // '', 'a,b', "AC7: --choices ' a , b ' normalizes and stores as 'a,b'");

    # field order: title status created, then link (if given), then choices (if given) -- spec 2.3.
    my $rorder = run_dec('file', '--title', 'order check', '--link', 'wtg', '--choices', 'x,y', '--root', $ROOTLK);
    my $idorder = field0($rorder->{out}, 'id');
    my ($keysorder, undef) = read_frontmatter("$DIRLK/$idorder.md");
    my @tail = grep { /^(?:title|status|created|link|choices)$/ } @$keysorder;
    is_deeply(\@tail, [qw(title status created link choices)],
        'spec 2.3: field order on create is title status created, then link, then choices');

    # AC8: malformed --link -> bad_link, no store created.
    my $ROOTBL = tempdir(CLEANUP => 1);
    $ROOTBL =~ s{\\}{/}g;
    for my $bad ('', '/wtg', 'wtg/', 'wtg//p', 'a/b/c/d', 'wtg/../x', 'w g', 'wtg\\p') {
        my $r = run_dec('file', '--title', 'bad link', '--link', $bad, '--root', $ROOTBL);
        is($r->{rc}, 2, "AC8: file --link '$bad' exits 2") or diag("stderr: $r->{err}");
        is(err_kind($r->{err}), 'usage', "AC8: --link '$bad' ...kind: usage");
        is(field2($r->{err}, 'detail'), 'bad_link', "AC8: --link '$bad' ...detail: bad_link");
    }
    ok(!-d inbox_dir_for($ROOTBL), 'AC8: none of the bad --link calls created A/inbox');

    # AC8: malformed --choices -> bad_choices, no store created.
    my $ROOTBC = tempdir(CLEANUP => 1);
    $ROOTBC =~ s{\\}{/}g;
    my @bad_choices = ('', 'a,,b', 'a,', 'a,a', 'a b', join(',', map {"c$_"} 1 .. 17), ('x' x 65));
    for my $bad (@bad_choices) {
        my $r = run_dec('file', '--title', 'bad choices', '--choices', $bad, '--root', $ROOTBC);
        is($r->{rc}, 2, "AC8: file --choices '$bad' exits 2") or diag("stderr: $r->{err}");
        is(err_kind($r->{err}), 'usage', "AC8: --choices '$bad' ...kind: usage");
        is(field2($r->{err}, 'detail'), 'bad_choices', "AC8: --choices '$bad' ...detail: bad_choices");
    }
    ok(!-d inbox_dir_for($ROOTBC), 'AC8: none of the bad --choices calls created A/inbox');

    # AC8: bare value-taking flags -> missing_flag_value.
    my $ROOTMV = tempdir(CLEANUP => 1);
    $ROOTMV =~ s{\\}{/}g;
    for my $flag (qw(link choices)) {
        my $r = run_dec('file', '--title', 'bare flag', "--$flag", '--root', $ROOTMV);
        is($r->{rc}, 2, "AC8: file --$flag given bare exits 2");
        is(field2($r->{err}, 'detail'), 'missing_flag_value', "AC8: file --$flag bare ...detail: missing_flag_value");
    }
    ok(!-d inbox_dir_for($ROOTMV), 'AC8: none of the bare-flag calls created A/inbox');
}

# =============================================================================
# DAN -- AC9/AC10: structured answer on a choices item, spec section 2.4.
# =============================================================================
{
    my $ROOTAN = tempdir(CLEANUP => 1);
    $ROOTAN =~ s{\\}{/}g;
    my $DIRAN = inbox_dir_for($ROOTAN);

    my $rf = run_dec('file', '--title', 'pick one', '--choices', 'accept,drop', '--root', $ROOTAN);
    my $idc = field0($rf->{out}, 'id');
    ok(defined $idc, 'DAN fixture: a choices item is filed') or diag("stderr: $rf->{err}");
    my $pathc = "$DIRAN/$idc.md";

    # AC9: first structured answer.
    my $r1 = run_dec('answer', $idc, '--choice', 'drop', '--note', 'not needed', '--root', $ROOTAN);
    is($r1->{rc}, 0, 'AC9: answer --choice drop --note "not needed" exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'changed'), 'yes', 'AC9: result carries changed: yes');
    my (undef, $kv1) = read_frontmatter($pathc);
    is($kv1->{status} // '', 'answered', 'AC9: frontmatter status is answered');
    is($kv1->{choice} // '', 'drop', 'AC9: frontmatter choice is drop');
    is($kv1->{note} // '', 'not needed', 'AC9: frontmatter note is "not needed"');
    ok(exists $kv1->{answered_at}, 'AC9: frontmatter carries answered_at');
    ok(!exists $kv1->{answer}, 'AC9: no answer field is ever set on the structured path');
    my $bytes1 = slurp_raw($pathc);

    # AC9: identical repeat -> changed: no, bytes unchanged.
    my $r2 = run_dec('answer', $idc, '--choice', 'drop', '--note', 'not needed', '--root', $ROOTAN);
    is($r2->{rc}, 0, 'AC9: identical repeat exits 0') or diag("stderr: $r2->{err}");
    is(field0($r2->{out}, 'changed'), 'no', 'AC9: identical repeat reports changed: no');
    is(slurp_raw($pathc), $bytes1, 'AC9: identical repeat leaves the record bytes unchanged');

    # AC9: a different choice afterwards -> already_answered.
    my $r3 = run_dec('answer', $idc, '--choice', 'accept', '--root', $ROOTAN);
    is($r3->{rc}, 2, 'AC9: a different --choice afterwards exits 2');
    is(field2($r3->{err}, 'detail'), 'already_answered', 'AC9: ...detail: already_answered');
    is(slurp_raw($pathc), $bytes1, 'AC9: the refused re-answer leaves bytes unchanged');

    # AC9: a choice with no note, answered twice without note -> second is changed: no.
    my $rf2 = run_dec('file', '--title', 'pick one, no note', '--choices', 'a,b', '--root', $ROOTAN);
    my $idn = field0($rf2->{out}, 'id');
    my $rn1 = run_dec('answer', $idn, '--choice', 'a', '--root', $ROOTAN);
    is($rn1->{rc}, 0, 'AC9: no-note answer exits 0') or diag("stderr: $rn1->{err}");
    is(field0($rn1->{out}, 'changed'), 'yes', 'AC9: first no-note answer reports changed: yes');
    my $rn2 = run_dec('answer', $idn, '--choice', 'a', '--root', $ROOTAN);
    is(field0($rn2->{out}, 'changed'), 'no', 'AC9: repeating a no-note answer reports changed: no');

    # AC10: refusals on a choices item, each leaving bytes unchanged.
    my $rf3 = run_dec('file', '--title', 'refusal target', '--choices', 'x,y', '--root', $ROOTAN);
    my $idr = field0($rf3->{out}, 'id');
    my $pathr = "$DIRAN/$idr.md";
    my $bytes0 = slurp_raw($pathr);

    my $rA = run_dec('answer', $idr, '--answer', 'free text', '--choice', 'x', '--root', $ROOTAN);
    is($rA->{rc}, 2, 'AC10: --answer together with --choice exits 2');
    is(field2($rA->{err}, 'detail'), 'answer_with_choice', 'AC10: ...detail: answer_with_choice');
    is(slurp_raw($pathr), $bytes0, 'AC10: answer_with_choice leaves bytes unchanged');

    my $rB = run_dec('answer', $idr, '--answer', 'free text', '--root', $ROOTAN);
    is($rB->{rc}, 2, 'AC10: bare --answer alone on a choices item exits 2');
    is(field2($rB->{err}, 'detail'), 'missing_choice', 'AC10: ...detail: missing_choice (answer alone)');
    is(slurp_raw($pathr), $bytes0, 'AC10: missing_choice (answer alone) leaves bytes unchanged');

    my $rC = run_dec('answer', $idr, '--choice', 'nope', '--root', $ROOTAN);
    is($rC->{rc}, 2, 'AC10: --choice not in the list exits 2');
    is(field2($rC->{err}, 'detail'), 'bad_choice', 'AC10: ...detail: bad_choice');
    is(slurp_raw($pathr), $bytes0, 'AC10: bad_choice leaves bytes unchanged');

    my $rD = run_dec('answer', $idr, '--note', 'orphan note', '--root', $ROOTAN);
    is($rD->{rc}, 2, 'AC10: --note without --choice exits 2');
    is(field2($rD->{err}, 'detail'), 'missing_choice', 'AC10: ...detail: missing_choice (note alone)');
    is(slurp_raw($pathr), $bytes0, 'AC10: missing_choice (note alone) leaves bytes unchanged');

    my $rE = run_dec('answer', $idr, '--choice', 'x', '--note', '', '--root', $ROOTAN);
    is($rE->{rc}, 2, 'AC10: an empty --note exits 2');
    is(field2($rE->{err}, 'detail'), 'bad_note', 'AC10: ...detail: bad_note (empty)');
    is(slurp_raw($pathr), $bytes0, 'AC10: bad_note (empty) leaves bytes unchanged');

    my $rF = run_dec('answer', $idr, '--choice', 'x', '--note', "a\r\nb", '--root', $ROOTAN);
    is($rF->{rc}, 2, 'AC10: a CR/LF --note exits 2');
    is(field2($rF->{err}, 'detail'), 'bad_note', 'AC10: ...detail: bad_note (CR/LF)');
    is(slurp_raw($pathr), $bytes0, 'AC10: bad_note (CR/LF) leaves bytes unchanged');

    my $rG = run_dec('answer', $idr, '--choice', '--root', $ROOTAN);
    is($rG->{rc}, 2, 'AC10: bare --choice exits 2');
    is(field2($rG->{err}, 'detail'), 'missing_flag_value', 'AC10: bare --choice ...detail: missing_flag_value');

    # AC10: choice/note on a PLAIN item -> no_choices.
    my $rfp = run_dec('file', '--title', 'plain item', '--root', $ROOTAN);
    my $idp = field0($rfp->{out}, 'id');
    my $pathp = "$DIRAN/$idp.md";
    my $bytesp = slurp_raw($pathp);
    my $rP1 = run_dec('answer', $idp, '--choice', 'x', '--root', $ROOTAN);
    is($rP1->{rc}, 2, 'AC10: --choice on a plain item exits 2');
    is(field2($rP1->{err}, 'detail'), 'no_choices', 'AC10: ...detail: no_choices (choice)');
    is(slurp_raw($pathp), $bytesp, 'AC10: no_choices (choice) leaves bytes unchanged');
    my $rP2 = run_dec('answer', $idp, '--note', 'x', '--root', $ROOTAN);
    is($rP2->{rc}, 2, 'AC10: --note on a plain item exits 2');
    is(field2($rP2->{err}, 'detail'), 'no_choices', 'AC10: ...detail: no_choices (note)');
    is(slurp_raw($pathp), $bytesp, 'AC10: no_choices (note) leaves bytes unchanged');

    # spec 2.4: structured item answered with --answer -> missing_choice (never a free answer).
    my $rfs = run_dec('file', '--title', 'structured only', '--choices', 'a,b', '--root', $ROOTAN);
    my $ids = field0($rfs->{out}, 'id');
    my $rS = run_dec('answer', $ids, '--answer', 'free text', '--root', $ROOTAN);
    is($rS->{rc}, 2, 'spec 2.4: a structured item answered with --answer alone exits 2');
    is(field2($rS->{err}, 'detail'), 'missing_choice', 'spec 2.4: ...detail: missing_choice, never stored as a free answer');
}

# =============================================================================
# DOUT -- AC11: list/show output carries link/choices/choice/note only when present.
# =============================================================================
{
    my $ROOTO = tempdir(CLEANUP => 1);
    $ROOTO =~ s{\\}{/}g;

    my $rplain = run_dec('file', '--title', 'plain output item', '--root', $ROOTO);
    my $idplain = field0($rplain->{out}, 'id');
    my $rlink = run_dec('file', '--title', 'linked item', '--link', 'wtg', '--choices', 'accept,drop', '--root', $ROOTO);
    my $idlink = field0($rlink->{out}, 'id');
    run_dec('answer', $idlink, '--choice', 'accept', '--note', 'because', '--root', $ROOTO);

    my $rlist = run_dec('list', '--root', $ROOTO);
    is($rlist->{rc}, 0, 'AC11: list exits 0') or diag("stderr: $rlist->{err}");
    like($rlist->{out}, qr/item:\s\Q$idlink\E\n(?:\s{2}\S.*\n)*?\s{2}link:\swtg\n\s{2}choices:\saccept,drop\n\s{2}choice:\saccept\n\s{2}note:\sbecause\n/,
        'AC11: list default prints link/choices/choice/note in order for an item carrying them');
    unlike($rlist->{out}, qr/item:\s\Q$idplain\E\n(?:(?!item:).*\n)*?\s{2}(?:link|choices|choice|note):/,
        'AC11: list default prints none of the four extra lines for a plain item')
        if $rlist->{out} =~ /item:\s\Q$idplain\E/;

    my $rjson = run_dec('list', '--json', '--root', $ROOTO);
    my $decoded = decode_json_or_undef($rjson->{out});
    ok(ref($decoded) eq 'ARRAY', 'AC11: list --json decodes to an array') or diag("raw: $rjson->{out}");
    if (ref($decoded) eq 'ARRAY') {
        my ($jlink) = grep { $_->{id} eq $idlink } @$decoded;
        my ($jplain) = grep { $_->{id} eq $idplain } @$decoded;
        if (ref($jlink) eq 'HASH') {
            is($jlink->{link}, 'wtg', 'AC11 --json: link field present for the linked item');
            is_deeply($jlink->{choices}, ['accept', 'drop'], 'AC11 --json: choices is a JSON array of the split strings');
            is($jlink->{choice}, 'accept', 'AC11 --json: choice field present');
            is($jlink->{note}, 'because', 'AC11 --json: note field present');
        } else {
            fail('AC11 --json: linked item present in list --json output');
        }
        if (ref($jplain) eq 'HASH') {
            ok(!exists $jplain->{link}, 'AC11 --json: a plain item has no link key');
            ok(!exists $jplain->{choices}, 'AC11 --json: a plain item has no choices key');
            ok(!exists $jplain->{choice}, 'AC11 --json: a plain item has no choice key');
            ok(!exists $jplain->{note}, 'AC11 --json: a plain item has no note key');
        } else {
            fail('AC11 --json: plain item present in list --json output');
        }
    }

    my $rshow = run_dec('show', $idlink, '--root', $ROOTO);
    like($rshow->{out}, qr/^link:\swtg$/m, 'AC11: show default prints a link: line');
    like($rshow->{out}, qr/^choices:\saccept,drop$/m, 'AC11: show default prints a choices: line');
    like($rshow->{out}, qr/^choice:\saccept$/m, 'AC11: show default prints a choice: line');
    like($rshow->{out}, qr/^note:\sbecause$/m, 'AC11: show default prints a note: line');

    my $rshowp = run_dec('show', $idplain, '--root', $ROOTO);
    unlike($rshowp->{out}, qr/^(?:link|choices|choice|note):/m, 'AC11: show on a plain item has none of the four lines');
}

# =============================================================================
# DLIB -- AC12: Almanac::Inbox::file / answer used as library calls give the
# same results as the CLI (AC7-AC10), as package 06/08 will call them.
# =============================================================================
{
    my $ROOTLIB = tempdir(CLEANUP => 1);
    $ROOTLIB =~ s{\\}{/}g;

    my $rec = eval { Almanac::Inbox::file(root => $ROOTLIB, title => 'lib link', link => 'wtg/01-x', choices => 'yes,no') };
    ok(!$@ && ref($rec) eq 'HASH', 'AC12: Almanac::Inbox::file(... link => ..., choices => ...) does not die')
        or diag("error: $@");
    SKIP: {
        skip 'file() died -- see the diag above', 4 unless ref($rec) eq 'HASH';
        is($rec->{fields}{link}, 'wtg/01-x', 'AC12: library file() stores the link field');
        is($rec->{fields}{choices}, 'yes,no', 'AC12: library file() stores the choices field');

        my ($ans, $changed) = eval { Almanac::Inbox::answer($rec->{id}, root => $ROOTLIB, choice => 'yes', note => 'because lib') };
        ok(!$@ && ref($ans) eq 'HASH', 'AC12: library answer(choice/note) does not die') or diag("error: $@");
        is($changed, 1, 'AC12: library answer() reports changed on the first structured answer') if !$@;
    }

    my $bad = eval { Almanac::Inbox::file(root => $ROOTLIB, title => 'bad lib link', link => '/bad') };
    my $err = $@;
    ok(!defined($bad) || $err, 'AC12: library file() with a malformed link dies (or the call errors)');
    is(ref($err) =~ /::Error$/ ? $err->{detail} : undef, 'bad_link', 'AC12: ...detail: bad_link') if ref($err) =~ /::Error$/;
}

# =============================================================================
# D11 -- isolation guard (house convention), at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "D11: the live bug-reports store's report count is unchanged by this suite ($live_before before, $live_after after)");

    my $live_listing_after = live_almanac_listing();
    is_deeply($live_listing_after, $live_listing_before,
       'D11: the repo\'s own .ccpraxis-local-data/almanac/{task,task-focus,decision} listings are unchanged '
     . '(absent stays absent, present stays byte-identical in listing)');
}

done_testing();
