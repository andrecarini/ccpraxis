#!/usr/bin/env perl
# platform: any
# ORACLE for almanac-records package 17-doctor-and-cli, almanac.pl's dispatcher
# half. Derived ONLY from
# .ccpraxis-local-data/blueprints/almanac-records/specs/17-doctor-and-cli-spec.md
# sections 2.1, 2.3, 3 and 4 (AC1-AC5, AC27) -- NOT from reading almanac.pl,
# which this package's write set has not written yet. Every call into
# Almanac::CLI below is wrapped so a missing module/file/sub is a legible,
# non-crashing failure for THAT assertion rather than an abort of this file.
#
# HARD ISOLATION RULE: every project-scope call passes an explicit --root
# (a fresh File::Temp tempdir); HOME/ALMANAC_HOME/USERPROFILE point at a
# temp home; CLAUDE_PROJECT_DIR is unset. A snapshot of the real repo's own
# .ccpraxis-local-data/almanac tree is taken before anything runs and
# compared again at the end (house convention, see almanac-store-scope.t /
# almanac-legacy-queue-absorb.t L14).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Spec;
use File::Basename qw(basename);
use Cwd qw(abs_path);
use Encode ();

# ---------------------------------------------------------------------------
# Isolation: temp home, temp registry, no CLAUDE_PROJECT_DIR/BP_* leakage.
# ---------------------------------------------------------------------------
my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{BP_PROJECT_ROOT};
delete local $ENV{BP_LEDGER};
delete local $ENV{ALMANAC_SURFACE};

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $ALMANAC_PL  = "$S/almanac.pl";
my $ALMANAC_ABOUT = "$S/almanac.pl.about";
# OVERRIDDEN by blueprint where-things-go, package 02-thread-store (specs/
# 02-thread-store-spec.md section 2.10): routes() drops the `task` key and
# gains `thread`; `task` becomes a retired_types() pointer at `almanac
# thread`. almanac-task.pl itself still exists (its library half survives
# for old readers), so it is kept in %SCRIPT_OF only for the retirement
# assertions below, never for an AC1/AC2 routing comparison.
my %SCRIPT_OF = (
    todo     => "$S/almanac-todo.pl",
    note     => "$S/almanac-note.pl",
    thread   => "$S/almanac-thread.pl",
    inbox    => "$S/almanac-inbox.pl",
    bug      => "$S/almanac-bug.pl",
);
my $TASK_PL = "$S/almanac-task.pl"; # retired CLI; library half still loaded by other scripts
my $DECISION_PL = "$S/almanac-decision.pl";   # retired (spec 01-inbox-rename 2.6) -- used only by the AC20 cutover block
for my $t (sort keys %SCRIPT_OF) {
    ok(-f $SCRIPT_OF{$t}, "precondition: $SCRIPT_OF{$t} exists (earlier package, already implemented)")
        or diag("missing $SCRIPT_OF{$t} -- every AC1 comparison against '$t' will fail for that reason");
}

# ---------------------------------------------------------------------------
# Isolation guard: the REAL repo's own almanac tree must be byte-identical
# in listing before and after this whole file.
# ---------------------------------------------------------------------------
(my $REPO_ROOT = "$Bin/../../../..") =~ s{\\}{/}g;
my $REAL_ALMANAC_DIR = "$REPO_ROOT/.ccpraxis-local-data/almanac";
sub list_tree {
    my ($dir) = @_;
    return [] unless -d $dir;
    my @out;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full }
            else { (my $rel = $full) =~ s{\\}{/}g; push @out, $rel }
        }
        closedir $dh;
    }
    return [ sort @out ];
}
my $REAL_BEFORE = list_tree($REAL_ALMANAC_DIR);

# ---------------------------------------------------------------------------
# run_child(\@cmd, %opt) -> { rc, stdout, stderr }
#
# fork()+exec(), each stream redirected to its OWN File::Temp file in the
# CHILD only (never reopening this test process's own STDOUT/STDERR onto an
# in-memory scalar -- Windows landmine). List-form exec, so no shell-string
# quoting is involved anywhere, including for paths with spaces.
# opt: stdin => $text (optional)
# ---------------------------------------------------------------------------
sub run_child {
    my ($cmd, %opt) = @_;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $stdinfile;
    if (defined $opt{stdin}) {
        my $infh;
        (undef, $stdinfile) = tempfile();
        open($infh, '>:raw', $stdinfile) or die "fixture: $!";
        print {$infh} $opt{stdin};
        close $infh;
    }
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $outfile) or exit(126);
        open(STDERR, '>', $errfile) or exit(126);
        if (defined $stdinfile) {
            open(STDIN, '<', $stdinfile) or exit(126);
        } else {
            open(STDIN, '<', File::Spec->devnull) or exit(126);
        }
        exec(@$cmd) or exit(127);
    }
    waitpid($pid, 0);
    my $rc = $? >> 8;
    my $signal = $? & 127;
    my $out = _slurp($outfile);
    my $err = _slurp($errfile);
    return { rc => $rc, stdout => $out, stderr => $err, signal => $signal };
}
sub _slurp {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return '';
    local $/;
    my $t = <$fh>;
    return defined $t ? $t : '';
}

sub run_almanac {
    my (@args) = @_;
    return run_child([ $^X, $ALMANAC_PL, @args ]);
}
sub run_direct {
    my ($type, @args) = @_;
    return run_child([ $^X, $SCRIPT_OF{$type}, @args ]);
}

sub mk_root { my $t = tempdir(CLEANUP => 1); (my $n = $t) =~ s{\\}{/}g; return $n; }

# extract_module_verbs($file) -- the qw(...) of
# `my %VERBS = map { $_ => 1 } qw(...)`, across possibly-multiple physical
# lines, for todo/note/task/decision.
sub extract_module_verbs {
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    local $/;
    my $src = <$fh>;
    close $fh;
    return undef unless $src =~ /my\s+%VERBS\s*=\s*map\s*\{\s*\$_\s*=>\s*1\s*\}\s*qw\((.*?)\)/s;
    return [ grep { length } split /\s+/, $1 ];
}
# extract_bug_verbs($file) -- every `$cmd eq '<v>'` literal.
sub extract_bug_verbs {
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    my @verbs;
    while (my $line = <$fh>) {
        next if $line =~ /^\s*#/;
        while ($line =~ /\$cmd\s+eq\s+'([a-z-]+)'/g) {
            push @verbs, $1;
        }
    }
    close $fh;
    my %seen; my @uniq = grep { !$seen{$_}++ } @verbs;
    return [ @uniq ];
}

# ---------------------------------------------------------------------------
# Fixtures: one record of each record type in project root $ROOT, built
# through each type's OWN direct script (so AC1's "direct script run" side
# is the same command used to seed the fixture).
# ---------------------------------------------------------------------------
my $ROOT = mk_root();

sub fixture_ok {
    my ($label, $res) = @_;
    ok($res->{rc} == 0, "fixture: $label") or diag("rc=$res->{rc} out=$res->{stdout} err=$res->{stderr}");
}

fixture_ok('todo create', run_direct('todo', 'create', '--title', 'a todo', '--root', $ROOT));
{
    my $r = run_child([ $^X, $SCRIPT_OF{note}, 'create', '--title', 'a note', '--audience', 'internal',
                         '--body', 'note body', '--root', $ROOT ]);
    fixture_ok('note create', $r);
}
# ---------------------------------------------------------------------------
# blueprint where-things-go, package 03-thread-sessions (Decision 18 F6): a
# hard ticket gate lands on every almanac-thread.pl write verb. Mint one for
# this fixture's 'thread create' call, keyed on the exact post-dispatch argv
# almanac-thread.pl itself sees (run_direct strips the leading 'thread' type
# word before invoking the script) -- same convention as thread-store.t.
{
    (my $CD_BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
    require "$CD_BUTLER_SCRIPTS/BpHook.pm" unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
    my $CD_BSD = tempdir(CLEANUP => 1); $CD_BSD =~ s{\\}{/}g;
    local $ENV{BUTLER_STATE_DIR} = $CD_BSD;
    BpHook::write_ticket(
        { session_id => 'FIXTURE-SESSION', tool_use_id => 'FT-CD1',
          transcript_path => undef, cwd => '/fixture' },
        'almanac-thread', [ 'create', 'fixture-thread', '--root', $ROOT ]);
    fixture_ok('thread create', run_direct('thread', 'create', 'fixture-thread', '--root', $ROOT));
}
fixture_ok('inbox file', run_direct('inbox', 'file', '--title', 'an inbox item', '--root', $ROOT));
fixture_ok('bug file', run_direct('bug', 'file', '--project', $ROOT, '--title', 'a bug',
    '--severity', 'low', '--area', 'sandbox', '--body', 'a bug body'));

# =============================================================================
# AC1 (DC1) -- for each of todo/note/task/decision/bug, one read verb via
# almanac.pl equals the direct script run byte-for-byte on stdout, stderr and
# exit code, on this fixture (>= 1 record per type).
# =============================================================================
{
    my %READ_ARGS = (
        todo     => [ 'list',                        '--root', $ROOT ],
        note     => [ 'list',                        '--root', $ROOT ],
        thread   => [ 'list',                        '--root', $ROOT ],
        inbox    => [ 'list',                        '--root', $ROOT ],
        bug      => [ 'list', '--project', $ROOT ],
    );
    for my $type (qw(todo note thread inbox bug)) {
        my $direct  = run_direct($type, @{ $READ_ARGS{$type} });
        my $viadash = run_almanac($type, @{ $READ_ARGS{$type} });
        is($viadash->{stdout}, $direct->{stdout}, "AC1: almanac $type ... stdout equals the direct $type script run");
        is($viadash->{stderr}, $direct->{stderr}, "AC1: almanac $type ... stderr equals the direct $type script run");
        is($viadash->{rc},     $direct->{rc},     "AC1: almanac $type ... exit code equals the direct $type script run");
    }
}

# =============================================================================
# AC2 (DC1, DC2) -- Almanac::CLI::routes() has exactly the six type keys;
# each record type's verbs set equals the script's own set (extracted from
# source, never re-derived by hand); each script exists beside almanac.pl.
# =============================================================================
{
    ok(-f $ALMANAC_PL, 'precondition: almanac.pl exists') or diag('almanac.pl missing -- AC2 cannot load it');
    my $LOAD_ERR;
    {
        local $@;
        do $ALMANAC_PL if -f $ALMANAC_PL;
        $LOAD_ERR = $@;
    }
    ok(!$LOAD_ERR, 'AC2: almanac.pl loads with no compile/runtime error via `do`')
        or diag("load error: $LOAD_ERR");

    my $routes = eval { Almanac::CLI::routes() };
    ok(ref($routes) eq 'HASH', 'AC2: Almanac::CLI::routes() returns a hashref')
        or diag('error: ' . ($@ // '(no routes() sub)'));

    if (ref($routes) eq 'HASH') {
        is_deeply([ sort keys %$routes ], [qw(bug doctor inbox note thread todo)],
            'AC1/spec 2.10: routes() has exactly the keys bug doctor inbox note thread todo (task retired, thread added)');

        is(ref($routes->{doctor}), 'HASH', 'AC2: routes()->{doctor} is a hashref') or diag('not a hashref');
        is($routes->{doctor}{script}, 'almanac-doctor.pl', 'AC2: doctor routes to almanac-doctor.pl')
            if ref($routes->{doctor}) eq 'HASH';
        ok(!defined $routes->{doctor}{verbs}, 'AC2: doctor takes no verb (verbs is undef)')
            if ref($routes->{doctor}) eq 'HASH';
        ok(-f "$S/almanac-doctor.pl", 'AC2: almanac-doctor.pl exists beside almanac.pl');

        for my $type (qw(todo note inbox)) {
            my $expected = extract_module_verbs($SCRIPT_OF{$type});
            ok(defined $expected, "AC2: extracted %VERBS qw(...) from $type\'s own source")
                or diag("could not find the %VERBS = map {...} qw(...) idiom in $SCRIPT_OF{$type}");
            if (ref($routes->{$type}) eq 'HASH' && defined $expected) {
                is($routes->{$type}{script}, "almanac-$type.pl", "AC2: $type routes to almanac-$type.pl");
                is_deeply([ sort @{ $routes->{$type}{verbs} || [] } ], [ sort @$expected ],
                    "AC2: $type's routes() verbs set equals its own script's %VERBS set");
                ok(-f "$S/$routes->{$type}{script}", "AC2: $type's script exists beside almanac.pl");
            } else {
                fail("AC2: $type's routes() verbs set equals its own script's %VERBS set");
            }
        }

        # thread (spec 2.10, EXTENDED by blueprint where-things-go package
        # 03-thread-sessions, Decision 31: routes() gains attach/detach/
        # switch/take-over): routes() hardcodes the verb list rather than
        # deriving it from almanac-thread.pl's own source (it is not
        # declared as a %VERBS = map {...} qw(...) idiom), so the expected
        # set here is the spec's table 2.7 verb list, restated.
        {
            my @thread_expected = qw(create list show archive archive-if-done add edit move reorder status add-packages event attach detach switch take-over);
            is($routes->{thread}{script}, 'almanac-thread.pl', 'AC2: thread routes to almanac-thread.pl')
                if ref($routes->{thread}) eq 'HASH';
            if (ref($routes->{thread}) eq 'HASH') {
                is_deeply([ sort @{ $routes->{thread}{verbs} || [] } ], [ sort @thread_expected ],
                    'AC2: thread\'s routes() verbs set equals the spec 2.7 verb table');
                ok(-f "$S/$routes->{thread}{script}", 'AC2: thread\'s script exists beside almanac.pl');
            } else {
                fail('AC2: thread\'s routes() verbs set equals the spec 2.7 verb table');
            }
        }

        my $bug_expected = extract_bug_verbs($SCRIPT_OF{bug});
        ok(defined $bug_expected && @$bug_expected, 'AC2: extracted $cmd eq literals from almanac-bug.pl\'s source');
        if (ref($routes->{bug}) eq 'HASH' && defined $bug_expected) {
            is($routes->{bug}{script}, 'almanac-bug.pl', 'AC2: bug routes to almanac-bug.pl');
            is_deeply([ sort @{ $routes->{bug}{verbs} || [] } ], [ sort @$bug_expected ],
                'AC2: bug\'s routes() verbs set equals every $cmd eq literal in almanac-bug.pl');
            ok(-f "$S/$routes->{bug}{script}", 'AC2: bug\'s script exists beside almanac.pl');
        } else {
            fail('AC2: bug\'s routes() verbs set equals every $cmd eq literal in almanac-bug.pl');
        }
    } else {
        fail('AC2: routes() has exactly the keys bug doctor inbox note thread todo');
    }
}

# =============================================================================
# AC3 (DC1) -- exit and stdin pass-through.
# =============================================================================
{
    my $direct_show  = run_direct('todo', 'show', 'nosuch', '--root', $ROOT);
    my $viadash_show = run_almanac('todo', 'show', 'nosuch', '--root', $ROOT);
    is($viadash_show->{rc}, $direct_show->{rc}, 'AC3: almanac todo show nosuch exits like the direct run')
        or diag("direct rc=$direct_show->{rc} out=$direct_show->{stdout} err=$direct_show->{stderr}");
    isnt($viadash_show->{rc}, 0, 'AC3: ...and that exit code is non-zero (a real failure, not a vacuous match)');
}
{
    my $res = run_child([ $^X, $ALMANAC_PL, 'todo', 'create', '--title', 'stdin-piped', '--body', '-', '--root', $ROOT ],
                         stdin => "hello\n");
    is($res->{rc}, 0, 'AC3: almanac todo create --body - with piped stdin succeeds') or diag($res->{stderr});
    like($res->{stdout}, qr/\S/, 'AC3: ...and prints something (the created record path)');

    # Find the created todo whose body is exactly "hello\n" and confirm the
    # STDIN text really reached the record body -- through the direct
    # script's own `show`, not by re-parsing almanac.pl's stdout by hand.
    my $list_res = run_direct('todo', 'list', '--root', $ROOT, '--json');
    my $found_id;
    if ($list_res->{stdout} =~ /"id"\s*:\s*"([^"]+)"[^}]*"title"\s*:\s*"stdin-piped"/s) {
        $found_id = $1;
    }
    ok(defined $found_id, 'AC3: the stdin-created todo is discoverable via the direct script\'s own list --json')
        or diag($list_res->{stdout});
    if (defined $found_id) {
        my $show_res = run_direct('todo', 'show', $found_id, '--root', $ROOT);
        like($show_res->{stdout}, qr/hello/, 'AC3: ...and its body contains the piped stdin text "hello"');
    }
}
{
    my $DOCTOR_ROOT = mk_root();
    my $res = run_almanac('doctor', '--root', $DOCTOR_ROOT);
    is($res->{rc}, 0, 'AC3: almanac doctor --root R on a clean (empty) fixture exits 0')
        or diag("out=$res->{stdout} err=$res->{stderr}");
}

# =============================================================================
# AC4 (DC2) -- for every record type, `almanac <type> zzz` exits 2, stdout
# empty, stderr exactly the two lines of section 2.1 with that type's verbs
# in TABLE order; the type's store dir is not created (nothing spawned).
# =============================================================================
{
    my %TABLE_VERBS = (
        # where-things-go package 02-thread-store, spec 2.10/2.11: routes()
        # gains `promote` on todo (mirrors note's existing promote entry).
        # package 03-thread-sessions (Decision 31) adds attach/detach/
        # switch/take-over to thread.
        todo     => [qw(create list show edit complete reopen delete count promote)],
        note     => [qw(create list show edit promote delete check-pointers)],
        thread   => [qw(create list show archive archive-if-done add edit move reorder status add-packages event attach detach switch take-over)],
        inbox    => [qw(file list show answer blocks)],
        bug      => [qw(file append update set-status takeover list collect verify)],
    );
    for my $type (sort keys %TABLE_VERBS) {
        my $FRESH_ROOT = mk_root();
        my $res = run_almanac($type, 'zzz', '--root', $FRESH_ROOT);
        is($res->{rc}, 2, "AC4: almanac $type zzz exits 2");
        is($res->{stdout}, '', "AC4: almanac $type zzz -- stdout is empty");
        my $expect = "almanac: unknown verb 'zzz' for 'almanac $type'\n"
                   . "almanac $type verbs: " . join(' ', @{ $TABLE_VERBS{$type} }) . "\n";
        is($res->{stderr}, $expect, "AC4: almanac $type zzz -- stderr is exactly the two-line message in table order");
        ok(!-d "$FRESH_ROOT/.ccpraxis-local-data/almanac/$type",
            "AC4: almanac $type zzz never created the $type store dir (nothing was spawned)");
    }
}

# =============================================================================
# AC5 (DC2) -- almanac (no args), almanac zzz, almanac todo, almanac todo
# --json each exit 2 with the exact section 2.1 messages; stdout empty.
# =============================================================================
{
    my $res_none = run_almanac();
    is($res_none->{rc}, 2, 'AC5: almanac (no args) exits 2');
    is($res_none->{stdout}, '', 'AC5: almanac (no args) -- stdout empty');
    is($res_none->{stderr}, "almanac: missing type\n" . "almanac types: bug doctor inbox note thread todo\n",
        'AC5: almanac (no args) -- exact stderr message');

    my $res_zzz = run_almanac('zzz');
    is($res_zzz->{rc}, 2, 'AC5: almanac zzz exits 2');
    is($res_zzz->{stdout}, '', 'AC5: almanac zzz -- stdout empty');
    is($res_zzz->{stderr}, "almanac: unknown type 'zzz'\n" . "almanac types: bug doctor inbox note thread todo\n",
        'AC5: almanac zzz -- exact stderr message');

    my $ROOT5 = mk_root();
    my $res_noverb = run_almanac('todo', '--root', $ROOT5);
    is($res_noverb->{rc}, 2, 'AC5: almanac todo (missing verb) exits 2');
    is($res_noverb->{stdout}, '', 'AC5: almanac todo -- stdout empty');
    is($res_noverb->{stderr},
        "almanac: missing verb for 'almanac todo'\n"
      . "almanac todo verbs: create list show edit complete reopen delete count promote\n",
        'AC5: almanac todo -- exact stderr message');

    my $res_flagverb = run_almanac('todo', '--json', '--root', $ROOT5);
    is($res_flagverb->{rc}, 2, 'AC5: almanac todo --json (verb begins with --) exits 2');
    is($res_flagverb->{stdout}, '', 'AC5: almanac todo --json -- stdout empty');
    is($res_flagverb->{stderr},
        "almanac: missing verb for 'almanac todo'\n"
      . "almanac todo verbs: create list show edit complete reopen delete count promote\n",
        'AC5: almanac todo --json -- exact stderr message (a --flag is never mistaken for a verb)');
}

# =============================================================================
# AC27 (D37-4) -- almanac.pl.about satisfies every section 2.3 rule.
# =============================================================================
{
    ok(-f $ALMANAC_ABOUT, 'AC27: plugins/almanac/scripts/almanac.pl.about exists')
        or diag("missing: $ALMANAC_ABOUT");
    if (-f $ALMANAC_ABOUT) {
        open(my $fh, '<:raw', $ALMANAC_ABOUT) or die "cannot read $ALMANAC_ABOUT: $!";
        local $/;
        my $bytes = <$fh>;
        close $fh;
        $bytes = '' unless defined $bytes;

        my $decoded = eval { Encode::decode('UTF-8', $bytes, Encode::FB_CROAK() | Encode::LEAVE_SRC()) };
        ok(!$@, 'AC27: almanac.pl.about is valid UTF-8') or diag("decode error: $@");

        my @nl = ($bytes =~ /\n/g);
        is(scalar(@nl), 1, 'AC27: almanac.pl.about contains exactly one \n');
        ok($bytes =~ /\n\z/, 'AC27: ...and that \n is the file\'s last byte') if @nl == 1;

        (my $content = $bytes) =~ s/\n\z//;
        unlike($content, qr/\r/, 'AC27: no \r anywhere in the content');
        unlike($content, qr/\t/, 'AC27: no tab anywhere in the content');
        unlike($content, qr/^\s/, 'AC27: no leading whitespace before the \n');
        unlike($content, qr/\s$/, 'AC27: no trailing whitespace before the \n');
        ok(length($content) >= 1 && length($content) <= 120,
            'AC27: content is 1 to 120 characters (got ' . length($content) . ')');
        unlike($content, qr/questions\.md/, 'AC27: does not contain the literal "questions.md"');

        # gen-readme-tree.pl's describe(): first line, trimmed (leading/
        # trailing whitespace stripped) -- must equal the file's content
        # minus the trailing \n (which, given the rules above, is already
        # whitespace-free at both ends, so trimming is a no-op here; this
        # assertion pins that equivalence rather than assuming it).
        (my $trimmed = $content) =~ s/^\s+|\s+$//g;
        is($trimmed, $content, 'AC27: gen-readme-tree.pl\'s describe() would yield exactly the content (trim is a no-op)');
    } else {
        fail($_) for (
            'AC27: almanac.pl.about is valid UTF-8',
            'AC27: almanac.pl.about contains exactly one \n',
            'AC27: content is 1 to 120 characters',
        );
    }
}

# =============================================================================
# AC2 (continued) -- retired_types() and the hard-cutover run() branch, spec
# section 2.6: a retired type prints its one line and returns 2, spawning
# nothing, BEFORE the unknown-type check.
# =============================================================================
{
    my $retired = eval { Almanac::CLI::retired_types() };
    is_deeply($retired, { decision => 'almanac inbox', task => 'almanac thread' },
        'AC2/AC11 (spec 2.10): retired_types() returns exactly { decision => "almanac inbox", task => "almanac thread" }')
        or diag('error: ' . ($@ // '(retired_types() missing or wrong shape)'));
}

# =============================================================================
# AC11 (specs/02-thread-store-spec.md section 2.10, behaviour 18) --
# `almanac task ...` is retired at the DISPATCHER level: exit 2, stderr
# exactly the one-line pointer, stdout empty, nothing written under the
# fixture root, and the hard-cutover branch fires BEFORE any attempt to spawn
# almanac-task.pl (so this never depends on almanac-task.pl's own CLI
# behaviour, which is tested directly in almanac-task-focus.t).
# =============================================================================
{
    my $expect_line = "almanac: 'almanac task' is retired; use 'almanac thread' instead\n";
    for my $case (
        ['no args',        []],
        ['list',           ['list']],
        ['add --title x',  ['add', '--title', 'x']],
        ['focus',          ['focus']],
        ['bogus verb',     ['bogus']],
    ) {
        my ($label, $args) = @$case;
        my $ROOTT = mk_root();
        my @full = @$args ? (@$args, '--root', $ROOTT) : ('--root', $ROOTT);
        my $res = @$args ? run_almanac('task', @full) : run_almanac('task');
        is($res->{rc}, 2, "AC11: almanac task ($label) exits 2") or diag("stdout=$res->{stdout} stderr=$res->{stderr}");
        is($res->{stdout}, '', "AC11: almanac task ($label) -- stdout empty");
        is($res->{stderr}, $expect_line, "AC11: almanac task ($label) -- stderr is exactly the retirement pointer");
        ok(!-d "$ROOTT/.ccpraxis-local-data", "AC11: almanac task ($label) wrote nothing under the fixture root");
    }
}

# =============================================================================
# AC20 (DC4) -- `almanac decision ...` is retired: exit 2, stderr exactly the
# 2.6 line, stdout empty, nothing written under the fixture root.
# =============================================================================
{
    my $expect_line = "almanac: 'almanac decision' is retired; use 'almanac inbox' instead\n";
    for my $case (
        ['no args',            []],
        ['list',               ['list']],
        ['file --title x',     ['file', '--title', 'x']],
        ['bogus verb',         ['bogus']],
    ) {
        my ($label, $args) = @$case;
        my $ROOT20 = mk_root();
        my @full = @$args ? (@$args, '--root', $ROOT20) : ('--root', $ROOT20);
        # "no args" must still mean no args AT ALL for `almanac decision`
        # (the --root is only needed to pin down where nothing gets written).
        my $res = @$args
            ? run_almanac('decision', @full)
            : run_almanac('decision');
        is($res->{rc}, 2, "AC20: almanac decision ($label) exits 2") or diag("stdout=$res->{stdout} stderr=$res->{stderr}");
        is($res->{stdout}, '', "AC20: almanac decision ($label) -- stdout empty");
        is($res->{stderr}, $expect_line, "AC20: almanac decision ($label) -- stderr is exactly the 2.6 retirement line");
        ok(!-d "$ROOT20/.ccpraxis-local-data", "AC20: almanac decision ($label) wrote nothing under the fixture root");
    }
}

# =============================================================================
# AC21 (DC4) -- `perl S/almanac-decision.pl ...` is retired directly, and a
# require/do of it dies with the same line, leaving Almanac::Decision::file
# undefined.
# =============================================================================
{
    my $expect_line = "almanac: 'almanac-decision.pl' is retired; use 'almanac inbox' instead\n";
    for my $case (
        ['no args',        []],
        ['list --root',    ['list']],
        ['file --title x', ['file', '--title', 'x']],
    ) {
        my ($label, $args) = @$case;
        my $ROOT21 = mk_root();
        my $res = run_child([ $^X, $DECISION_PL, @$args, '--root', $ROOT21 ]);
        is($res->{rc}, 2, "AC21: perl almanac-decision.pl ($label) exits 2") or diag("stdout=$res->{stdout} stderr=$res->{stderr}");
        is($res->{stderr}, $expect_line, "AC21: perl almanac-decision.pl ($label) -- stderr is exactly the 2.6 line");
        ok(!-d "$ROOT21/.ccpraxis-local-data", "AC21: perl almanac-decision.pl ($label) wrote nothing");
    }

    # `do FILE` deliberately does NOT re-throw a die past the `do` statement
    # itself (it behaves like an inner eval: it sets $@ and returns undef,
    # same as `eval { do FILE }` would) -- so `!eval { do $DECISION_PL; 1 }`
    # can never observe a "died" outcome for ANY file, by Perl's own
    # documented semantics. `require EXPR` of the same path DOES re-throw
    # into an enclosing eval (verified empirically), which is the call form
    # that actually exercises "dies" the way this assertion means it.
    my $died = !eval { require $DECISION_PL; 1 };
    my $err = $@;
    ok($died, 'AC21: `require` of almanac-decision.pl dies') or diag('require did not die');
    like($err, qr/\Q$expect_line\E/, 'AC21: ...with a message containing the 2.6 line') if $died;
    ok(!defined(&Almanac::Decision::file), 'AC21: Almanac::Decision::file is undefined after the require');
}

# =============================================================================
# Isolation guard, again, at the end: the real repo's almanac tree is
# unchanged by this whole file.
# =============================================================================
{
    my $real_after = list_tree($REAL_ALMANAC_DIR);
    is_deeply($real_after, $REAL_BEFORE,
        'house convention: the real repo\'s .ccpraxis-local-data/almanac tree has the same file listing before and after this file');
}

done_testing();
