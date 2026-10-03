#!/usr/bin/env perl
# platform: any
# Host-only oracle for Almanac::GlobalCounts (blueprint almanac-records,
# package 19-global-counts-snapshot). See specs/19-global-counts-snapshot-
# spec.md sections 2.3, 3, 4 (AC1-AC13) and Decision 30. No container
# runtime here -- the mount-side behaviour (AC14-AC22) lives in the sibling
# plugins/sandbox/tests/t/sandbox-global-counts-mount.t.
#
# HOUSE PATTERN for a not-yet-built module (almanac-todo-crud.t,
# almanac-lock-bounded-acquire.t): every call into Almanac::GlobalCounts is
# reached through a fully-qualified sub name inside eval{}, so "Undefined
# subroutine" is a caught, reported failure for THIS assertion rather than
# an abort of the whole file. Almanac::Store, Almanac::Lock and the two CLI
# scripts already exist and are `use`d/`do`ne directly as real, working
# dependencies -- they are not the thing under test here.
#
# Every home in this file is an explicit temp directory passed as --home /
# home => ..., never $ENV{HOME}/$ENV{USERPROFILE} (Decision 26, AC13). See
# the "AC13" block near the end for the non-ASCII ("André") home case.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Time::HiRes ();
use JSON::PP ();
use Fcntl qw(:flock);
use Sys::Hostname ();
use Cwd ();

use lib "$Bin/../../scripts";
use Almanac::Store ();
use Almanac::Lock ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;

my $TODO_PL = "$S/almanac-todo.pl";
my $NOTE_PL = "$S/almanac-note.pl";
my $GC_PM   = "$S/Almanac/GlobalCounts.pm";

ok(-f $TODO_PL, 'almanac-todo.pl exists (real dependency, not under test)') or BAIL_OUT('almanac-todo.pl missing');
ok(-f $NOTE_PL, 'almanac-note.pl exists (real dependency, not under test)') or BAIL_OUT('almanac-note.pl missing');

ok(-f $GC_PM, 'Almanac::GlobalCounts module file exists at plugins/almanac/scripts/Almanac/GlobalCounts.pm')
    or diag('Almanac/GlobalCounts.pm is not present yet -- every assertion below that calls into it is '
          . 'expected to fail for exactly that reason, not for any other.');

my $HAVE_GC = eval { require Almanac::GlobalCounts; 1 } ? 1 : 0;
ok($HAVE_GC, 'Almanac::GlobalCounts loads with no compile/runtime error') or diag("load error: $@");

# Load the two CLI scripts as libraries (proven safe: `do FILE` makes
# `caller()` true inside their own `unless (caller) { ... exit 0 }` guard,
# so nothing runs and nothing exits -- verified against this exact repo).
do $TODO_PL or BAIL_OUT("do $TODO_PL failed: " . (defined $@ && length $@ ? $@ : $!));
do $NOTE_PL or BAIL_OUT("do $NOTE_PL failed: " . (defined $@ && length $@ ? $@ : $!));

my $ISO_RE = qr/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z$/;

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub mkdir_p { my ($d) = @_; make_path($d) unless -d $d; return; }

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
    open my $fh, '<', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_raw {
    my ($p, $bytes) = @_;
    open my $fh, '>:raw', $p or die "fixture: cannot write $p: $!";
    print {$fh} (defined $bytes ? $bytes : '');
    close $fh;
    return;
}

my $HOME_N = 0;
sub new_home {
    my $d = tempdir(CLEANUP => 1);
    $d =~ s{\\}{/}g;
    $HOME_N++;
    return $d;
}

sub norm_slash {
    my ($p) = @_;
    return $p unless defined $p;
    $p =~ s{\\}{/}g;
    $p =~ s{/\z}{} if length($p) > 1;
    $p =~ s{^([a-zA-Z]):}{uc($1) . ':'}e;
    return $p;
}

# norm_path($p) -- same helper almanac-todo-crud.t / almanac-store-scope.t
# use: routes through Cwd::abs_path FIRST, then normalizes slashes/drive
# case. Needed wherever a RAW tempdir() path is compared against a value
# the module produced by canonicalising home through
# Almanac::Store::_resolve_home (which itself calls Cwd::abs_path) -- on
# this host tempdir()'s own /tmp-mounted spelling and abs_path's resolved
# spelling of the SAME directory can differ, and norm_slash alone (pure
# string normalization, no filesystem resolution) does not converge them.
sub norm_path {
    my ($p) = @_;
    my $abs = Cwd::abs_path($p);
    $abs = $p unless defined $abs;
    return norm_slash($abs);
}

# run_cli($script, @args) -> { rc, out, err } -- same shape as
# almanac-todo-crud.t's run_cli, deliberately kept identical: quoted
# string-argv via system(), which is the proven, already-working pattern
# for invoking these CLI scripts on this host (no argument used anywhere in
# this file contains a shell metacharacter or an embedded quote).
sub run_cli {
    my ($script, @args) = @_;
    my (undef, $outpath) = File::Temp::tempfile();
    my (undef, $errpath) = File::Temp::tempfile();
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$script" $argstr > "$outpath" 2> "$errpath"});
    my $rc  = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    unlink $outpath, $errpath;
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}

sub field0 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\Q$key\E:\s(\S+)$/m;
    return undef;
}

sub bounded_wait_for_file {
    my ($path, $deadline_s) = @_;
    my $t0 = Time::HiRes::time();
    my $deadline = $t0 + $deadline_s;
    while (!-e $path) {
        return 0 if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.02);
    }
    return 1;
}

sub all_files_exist {
    my ($paths) = @_;
    for my $p (@$paths) { return 0 unless -e $p }
    return 1;
}

# assert_snapshot_equals_compute($home, $label) -- 7 fixed assertions,
# regardless of whether GlobalCounts exists yet, so callers can rely on a
# constant assertion count.
sub assert_snapshot_equals_compute {
    my ($home, $label) = @_;
    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $home) };
    my $snap = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
    my $comp = eval { Almanac::GlobalCounts::compute(home => $home) };
    if (!defined $snap || ref($comp) ne 'HASH'
        || ref($comp->{todo}) ne 'HASH' || ref($comp->{note}) ne 'HASH') {
        fail("$label: snapshot/compute comparable") for 1 .. 7;
        diag("snap defined: " . (defined $snap ? 'yes' : 'no') . "; compute error: " . ($@ // '(none)'));
        return;
    }
    is($snap->{schema}, 1, "$label: schema == 1");
    like($snap->{generated_at} // '', $ISO_RE, "$label: generated_at matches the ISO pattern");
    is($snap->{todo}{open},  $comp->{todo}{open},  "$label: todo.open == compute().todo.open");
    is($snap->{todo}{done},  $comp->{todo}{done},  "$label: todo.done == compute().todo.done");
    is($snap->{todo}{total}, $comp->{todo}{total}, "$label: todo.total == compute().todo.total");
    is($snap->{todo}{total}, $snap->{todo}{open} + $snap->{todo}{done},
        "$label: todo.total == todo.open + todo.done (invariant)");
    is($snap->{note}{total}, $comp->{note}{total}, "$label: note.total == compute().note.total");
    return;
}

# assert_matches_todo_count($home, $label) -- 3 fixed assertions against the
# independent oracle Almanac::Todo::count() (already-implemented, real code).
sub assert_matches_todo_count {
    my ($home, $label) = @_;
    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $home) };
    my $snap = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
    my $tc   = eval { Almanac::Todo::count(home => $home) };
    my $slot = (ref($tc) eq 'HASH' && ref($tc->{global}) eq 'HASH') ? $tc->{global} : undef;
    if (!defined $snap || !defined $slot) {
        fail("$label: todo count comparable against Almanac::Todo::count") for 1 .. 3;
        return;
    }
    is($snap->{todo}{open},  $slot->{open},  "$label: todo.open == Almanac::Todo::count()'s global slot");
    is($snap->{todo}{done},  $slot->{done},  "$label: todo.done == Almanac::Todo::count()'s global slot");
    is($snap->{todo}{total}, $slot->{total}, "$label: todo.total == Almanac::Todo::count()'s global slot");
    return;
}

# step_and_check($home, $label, $script, @args) -- runs one global CLI
# mutation (appends --global --home $home itself), asserts exit 0, then
# checks the snapshot against compute(). Returns the run_cli result so the
# caller can pull an id out of stdout. 8 fixed assertions.
sub step_and_check {
    my ($home, $label, $script, @args) = @_;
    my $r = run_cli($script, @args, '--global', '--home', $home);
    is($r->{rc}, 0, "$label: exits 0") or diag("stderr: $r->{err}");
    assert_snapshot_equals_compute($home, $label);
    return $r;
}

# ---------------------------------------------------------------------------
# Live-store sanity (house convention, e.g. almanac-store-scope.t /
# almanac-lock-bounded-acquire.t): this file must never leave a mark on the
# REAL repo's own almanac store. Every project-scope call above passes an
# explicit --root pointing at a temp project (never the ambient cwd), so
# this repo's own .ccpraxis-local-data/almanac tree should be byte-for-byte
# unchanged before and after this run -- snapshotted now, asserted at the
# very end (see the closing block just before done_testing()).
# ---------------------------------------------------------------------------
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIVE_ALMANAC = "$REPO/.ccpraxis-local-data/almanac";

sub list_almanac_files {
    my ($dir) = @_;
    my @files;
    return \@files unless -d $dir;
    my @stack = ($dir);
    while (@stack) {
        my $d = shift @stack;
        opendir(my $dh, $d) or next;
        my @entries = readdir($dh);
        closedir $dh;
        for my $e (@entries) {
            next if $e eq '.' || $e eq '..';
            my $p = "$d/$e";
            if (-d $p) { push @stack, $p }
            else       { push @files, $p }
        }
    }
    return [ sort @files ];
}

my $live_almanac_before = list_almanac_files($LIVE_ALMANAC);

# ---------------------------------------------------------------------------
# AC1 (DC-a, DC-g): snapshot_path shape
# ---------------------------------------------------------------------------
{
    my $H = new_home();
    my $expected = norm_path($H) . '/.claude/almanac-global-counts.json';
    my $got = eval { Almanac::GlobalCounts::snapshot_path(home => $H) };
    my $got_n = defined($got) ? norm_slash($got) : undef;
    is($got_n, $expected, 'AC1: snapshot_path(home=>H) equals H/.claude/almanac-global-counts.json')
        or diag("error: " . ($@ // '(none)'));

    my @segments = defined($got) ? split(m{[\\/]}, $got) : ();
    my @vault_hits = grep { lc($_) eq 'claude-code-vault' } @segments;
    is(scalar(@vault_hits), 0, 'AC1: no path segment of snapshot_path equals claude-code-vault');

    my $cap = Almanac::Store::scope_capability('global', home => $H, surface => 'host');
    my $root_n = norm_slash($cap->{root});
    my $is_under = defined($got_n) && (index("$got_n/", "$root_n/") == 0);
    ok(!$is_under, 'AC1: snapshot_path is not under the global scope_capability root (the vault)');
}

# ---------------------------------------------------------------------------
# AC2 (DC-a, DC-b): one global todo create
# ---------------------------------------------------------------------------
{
    my $H = new_home();
    my $r = run_cli($TODO_PL, 'create', '--title', 'AC2 global todo', '--global', '--home', $H);
    is($r->{rc}, 0, 'AC2: global todo create exits 0') or diag("stderr: $r->{err}");
    assert_snapshot_equals_compute($H, 'AC2');
    assert_matches_todo_count($H, 'AC2');
}

# ---------------------------------------------------------------------------
# AC3 (DC-a, DC-b): every mutating verb, both types, in global scope
# ---------------------------------------------------------------------------
{
    my $H = new_home();

    my $r0 = run_cli($TODO_PL, 'create', '--title', 'AC3 todo', '--global', '--home', $H);
    is($r0->{rc}, 0, 'AC3 setup: initial global todo create exits 0') or diag("stderr: $r0->{err}");
    my $tid = field0($r0->{out}, 'id');
    ok(defined $tid && length $tid, 'AC3 setup: initial todo id captured') or diag($r0->{out});

    step_and_check($H, 'AC3 todo edit',     $TODO_PL, 'edit',     $tid, '--title', 'AC3 todo edited');
    step_and_check($H, 'AC3 todo complete', $TODO_PL, 'complete', $tid);
    step_and_check($H, 'AC3 todo reopen',   $TODO_PL, 'reopen',   $tid);
    step_and_check($H, 'AC3 todo delete',   $TODO_PL, 'delete',   $tid);

    my $rn = step_and_check($H, 'AC3 note create', $NOTE_PL, 'create', '--title', 'AC3 note', '--covers', 'AC3 note covers');
    my $nid = field0($rn->{out}, 'id');
    ok(defined $nid && length $nid, 'AC3 setup: note id captured') or diag($rn->{out});

    # Independent oracle for "note.total equals the number of global note
    # records" (spec AC3), counted directly through Almanac::Store rather
    # than through compute() (which is the thing under test).
    {
        my $note_store = eval { Almanac::Store->open(scope => 'global', type => 'note', home => $H) };
        my $direct_total = (ref $note_store) ? scalar(@{ $note_store->list }) : undef;
        my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $H) };
        my $snap = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
        is(defined($snap) ? $snap->{note}{total} : undef, $direct_total,
            'AC3: note.total equals an independently-counted number of global note records');
    }

    step_and_check($H, 'AC3 note edit', $NOTE_PL, 'edit', $nid, '--title', 'AC3 note edited');

    mkdir_p("$H/.claude/claude-code-vault/ac3-ext");
    step_and_check($H, 'AC3 note promote', $NOTE_PL, 'promote', $nid,
        '--audience', 'external', '--target', 'ac3-ext/promoted.md');

    step_and_check($H, 'AC3 note delete', $NOTE_PL, 'delete', $nid);
}

# ---------------------------------------------------------------------------
# AC4 (DC-a): project-scope mutations never touch the global snapshot
# ---------------------------------------------------------------------------
{
    # Project scope with no --root walks UP FROM CWD looking for
    # .ccpraxis-local-data/.git (Almanac::Store::resolve_project_root) --
    # every project-scope call in this file MUST pass an explicit --root
    # pointing at a temp project, exactly like the sibling scope tests
    # (almanac-todo-scope.t's $ROOT24/$ROOT27/...), or it silently writes
    # into THIS repo's own .ccpraxis-local-data/almanac tree.
    my $PROJECT_ROOT1 = tempdir(CLEANUP => 1);
    $PROJECT_ROOT1 =~ s{\\}{/}g;

    my $H = new_home();
    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $H) };
    my $r = run_cli($TODO_PL, 'create', '--title', 'AC4 project todo', '--root', $PROJECT_ROOT1, '--home', $H);
    is($r->{rc}, 0, 'AC4: project-scope todo create exits 0') or diag("stderr: $r->{err}");
    ok(!defined($path) || !-e $path,
        'AC4: snapshot stays absent after a project-scope mutation when it was absent before');

    my $PROJECT_ROOT2 = tempdir(CLEANUP => 1);
    $PROJECT_ROOT2 =~ s{\\}{/}g;

    my $H2 = new_home();
    mkdir_p("$H2/.claude");
    my $path2 = "$H2/.claude/almanac-global-counts.json";
    my $seed  = qq({"generated_at":"2020-01-01T00:00:00Z","note":{"total":0},"schema":1,)
              . qq("todo":{"done":0,"open":0,"total":0}}\n);
    write_raw($path2, $seed);
    my $before = slurp_raw($path2);

    my $r2 = run_cli($TODO_PL, 'create', '--title', 'AC4 project todo 2', '--root', $PROJECT_ROOT2, '--home', $H2);
    is($r2->{rc}, 0, 'AC4: project-scope todo create (pre-seeded snapshot) exits 0') or diag("stderr: $r2->{err}");
    is(slurp_raw($path2), $before, 'AC4: pre-seeded snapshot is byte-identical after a project-scope todo create');

    my $r3 = run_cli($NOTE_PL, 'create', '--title', 'AC4 project note', '--root', $PROJECT_ROOT2, '--home', $H2);
    is($r3->{rc}, 0, 'AC4: project-scope note create exits 0') or diag("stderr: $r3->{err}");
    is(slurp_raw($path2), $before, 'AC4: pre-seeded snapshot is still byte-identical after a project-scope note create');
}

# ---------------------------------------------------------------------------
# AC5 (DC-a): only the snapshot + lock sidecars change outside the vault
# ---------------------------------------------------------------------------
{
    sub snapshot_of_tree {
        my ($root) = @_;
        my %files;
        my @stack = ($root);
        while (@stack) {
            my $dir = shift @stack;
            opendir(my $dh, $dir) or next;
            my @entries = readdir($dh);
            closedir $dh;
            for my $e (@entries) {
                next if $e eq '.' || $e eq '..';
                my $p = "$dir/$e";
                if (-d $p) { push @stack, $p }
                elsif (-f $p) {
                    my @st = stat($p);
                    $files{$p} = (defined $st[9] ? $st[9] : 0) . ':' . (defined $st[7] ? $st[7] : 0);
                }
            }
        }
        return \%files;
    }

    my $H = new_home();
    mkdir_p("$H/.claude");
    my $before = snapshot_of_tree($H);
    my $r = run_cli($TODO_PL, 'create', '--title', 'AC5 todo', '--global', '--home', $H);
    is($r->{rc}, 0, 'AC5: global todo create exits 0') or diag("stderr: $r->{err}");
    my $after = snapshot_of_tree($H);

    my %changed;
    for my $p (keys %$after) {
        $changed{$p} = 1 unless exists($before->{$p}) && $before->{$p} eq $after->{$p};
    }
    for my $p (keys %$before) {
        $changed{$p} = 1 unless exists $after->{$p};
    }

    my $vault_dir = "$H/.claude/claude-code-vault/almanac";
    my @changed_paths = keys %changed;
    my @outside_vault = sort grep { index($_, "$vault_dir/") != 0 } @changed_paths;
    my @unexpected = grep { $_ !~ m{/almanac-global-counts\.json(\.lock(\.holder)?)?\z} } @outside_vault;
    is_deeply(\@unexpected, [],
        'AC5: every changed path outside the vault almanac/ dir is the snapshot or one of its lock sidecars')
        or diag(explain(\@unexpected));
}

# ---------------------------------------------------------------------------
# AC6 (DC-a): K>=4 real concurrent processes
# ---------------------------------------------------------------------------
{
    my $WORK = tempdir(CLEANUP => 1);
    $WORK =~ s{\\}{/}g;
    my $CHILD = "$WORK/burst.pl";
    open(my $fh, '>', $CHILD) or die "fixture: cannot write $CHILD: $!";
    print {$fh} <<'CHILD';
#!/usr/bin/env perl
use strict;
use warnings;
my ($todo_pl, $home, $n, $count, $donefile) = @ARGV;
my $ok = 1;
for my $i (1 .. $count) {
    my $rc = system('perl', $todo_pl, 'create', '--title', "burst-$n-$i", '--global', '--home', $home);
    $ok = 0 if $rc != 0;
}
open(my $df, '>', $donefile) or exit 1;
print {$df} ($ok ? "OK\n" : "FAIL\n");
close $df;
CHILD
    close $fh;

    # $H is shared across the 4 children (they all target the SAME global store).
    my $H = new_home();
    my @done_files;
    for my $n (1 .. 4) {
        my $done = "$WORK/done.$n";
        push @done_files, $done;
        my @argv = ($CHILD, $TODO_PL, $H, $n, 5, $done);
        my $argstr = join(' ', map { qq{"$_"} } @argv);
        system(qq{perl $argstr > "$WORK/log.$n" 2>&1 &});
    }

    my $all_done = 1;
    for my $done (@done_files) {
        $all_done = 0 unless bounded_wait_for_file($done, 90);
    }
    ok($all_done, 'AC6: all 4 concurrent burst children signalled done within 90s');

    my $all_ok = 1;
    for my $n (1 .. 4) {
        my $body = slurp_text("$WORK/done.$n") // '';
        unless ($body =~ /^OK/m) {
            $all_ok = 0;
            diag("child $n log: " . (slurp_text("$WORK/log.$n") // '(no log)'));
        }
    }
    ok($all_ok, 'AC6: all 4 concurrent processes exit 0 for every one of their 5 creates');

    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $H) };
    my $snap = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
    my $comp = eval { Almanac::GlobalCounts::compute(home => $H) };
    if (defined $snap && ref($comp) eq 'HASH' && ref($comp->{todo}) eq 'HASH') {
        is($snap->{todo}{total}, 20, 'AC6: final snapshot todo.total == 20 (4 processes x 5 creates)');
        is($snap->{todo}{total}, $comp->{todo}{total}, 'AC6: final snapshot todo.total == compute().todo.total');
    } else {
        fail('AC6: final snapshot readable and decodable') for 1 .. 2;
    }
}

# ---------------------------------------------------------------------------
# AC7 (DC-a): a concurrent reader never regresses from valid to undef
# ---------------------------------------------------------------------------
{
    my $H = new_home();
    my $seed = run_cli($TODO_PL, 'create', '--title', 'AC7 seed', '--global', '--home', $H);
    is($seed->{rc}, 0, 'AC7: seed global todo create exits 0') or diag("stderr: $seed->{err}");

    my $WORK = tempdir(CLEANUP => 1);
    $WORK =~ s{\\}{/}g;
    my $CHILD = "$WORK/burst.pl";
    open(my $fh, '>', $CHILD) or die "fixture: cannot write $CHILD: $!";
    print {$fh} <<'CHILD';
#!/usr/bin/env perl
use strict;
use warnings;
my ($todo_pl, $home, $n, $count, $donefile) = @ARGV;
for my $i (1 .. $count) {
    system('perl', $todo_pl, 'create', '--title', "ac7-$n-$i", '--global', '--home', $home);
}
open(my $df, '>', $donefile) or exit 1;
print {$df} "OK\n";
close $df;
CHILD
    close $fh;

    my @done_files;
    for my $n (1 .. 4) {
        my $done = "$WORK/done.$n";
        push @done_files, $done;
        my @argv = ($CHILD, $TODO_PL, $H, $n, 10, $done);
        my $argstr = join(' ', map { qq{"$_"} } @argv);
        system(qq{perl $argstr > "$WORK/log.$n" 2>&1 &});
    }

    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $H) };
    my $seen_valid = 0;
    my $violation  = 0;
    my $reads      = 0;
    while ($reads < 200 || !all_files_exist(\@done_files)) {
        $reads++;
        my $snap = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
        if (defined $snap) {
            $seen_valid = 1;
        } elsif ($seen_valid) {
            $violation = 1;
            last;
        }
        last if $reads > 20_000;   # hard safety cap against a runaway loop
    }
    for my $done (@done_files) { bounded_wait_for_file($done, 90) }

    ok($reads >= 200, "AC7: reader performed at least 200 read_snapshot calls (did $reads)");
    ok(!$violation, 'AC7: read_snapshot never returned undef after its first valid read');
}

# ---------------------------------------------------------------------------
# AC8 (DC-a): a malformed record leaves refresh failing, snapshot untouched,
# and a mutation of a DIFFERENT record still exits 0 with the warning block.
# ---------------------------------------------------------------------------
{
    my $H = new_home();
    my $r1 = run_cli($TODO_PL, 'create', '--title', 'AC8 good1', '--global', '--home', $H);
    my $id1 = field0($r1->{out}, 'id');
    my $r2 = run_cli($TODO_PL, 'create', '--title', 'AC8 good2', '--global', '--home', $H);
    my $id2 = field0($r2->{out}, 'id');
    ok(defined($id1) && defined($id2), 'AC8 setup: two global todos created with captured ids')
        or diag("r1.out=$r1->{out} r2.out=$r2->{out}");

    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $H) };
    my $before_bytes = defined($path) ? slurp_raw($path) : undef;

    my $store = eval { Almanac::Store->open(scope => 'global', type => 'todo', home => $H) };
    if (ref($store) && defined $id1) {
        my $rec_path = eval { $store->_record_path($id1) };
        if (defined $rec_path) {
            write_raw($rec_path, "not frontmatter at all, no leading delimiter\n");
        }
    }

    my $res = eval { Almanac::GlobalCounts::refresh(home => $H) };
    if (ref($res) eq 'HASH') {
        is($res->{ok}, 0, 'AC8: refresh returns ok=>0 for a malformed global record');
        is($res->{reason}, 'malformed', 'AC8: reason is malformed');
    } else {
        fail('AC8: refresh returned a result hash') for 1 .. 2;
        diag("refresh error: " . ($@ // '(none)'));
    }

    my $after_bytes = defined($path) ? slurp_raw($path) : undef;
    is($after_bytes, $before_bytes, 'AC8: the pre-existing snapshot bytes are unchanged after a failed refresh');

    my $r3 = run_cli($TODO_PL, 'edit', $id2, '--title', 'AC8 good2 edited', '--global', '--home', $H);
    is($r3->{rc}, 0, 'AC8: a CLI mutation of a DIFFERENT record still exits 0') or diag("stderr: $r3->{err}");
    like($r3->{err}, qr/^  kind: global_counts_stale$/m,
        'AC8: STDERR carries the machine block line "  kind: global_counts_stale"');
    like($r3->{err}, qr/^  reason: malformed$/m,
        'AC8: STDERR carries the machine block line "  reason: malformed"');
}

# ---------------------------------------------------------------------------
# AC9 (DC-a): a lock held by a REAL separate process times refresh out
# ---------------------------------------------------------------------------
{
    my $HOLDER_PL_SRC = <<'HOLDER';
#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(:flock);
use Time::HiRes ();
$| = 1;
my ($lockpath, $hold_s, $readypath) = @ARGV;
open(my $fh, '>', $lockpath) or do {
    open(my $rf, '>', $readypath); print {$rf} "OPEN-FAIL $!"; close $rf; exit 1;
};
flock($fh, LOCK_EX) or do {
    open(my $rf, '>', $readypath); print {$rf} "FLOCK-FAIL $!"; close $rf; exit 1;
};
open(my $rf, '>', $readypath) or exit 1;
print {$rf} $$;
close $rf;
Time::HiRes::sleep($hold_s || 0);
close $fh;
exit 0;
HOLDER

    my $WORK = tempdir(CLEANUP => 1);
    $WORK =~ s{\\}{/}g;
    my $HOLDER_PL = "$WORK/raw-holder.pl";
    write_raw($HOLDER_PL, $HOLDER_PL_SRC);

    my $H = new_home();
    mkdir_p("$H/.claude");
    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $H) };
    $path = "$H/.claude/almanac-global-counts.json" unless defined $path;
    my $lockpath  = "$path.lock";
    my $readypath = "$WORK/ready";

    system(qq{perl "$HOLDER_PL" "$lockpath" "3" "$readypath" > "$WORK/holder-log" 2>&1 &});
    my $up = bounded_wait_for_file($readypath, 10);
    ok($up, 'AC9: the external holder process signalled ready within 10s')
        or diag("holder log: " . (slurp_text("$WORK/holder-log") // '(none)'));

    my $t0 = Time::HiRes::time();
    my $res = eval { Almanac::GlobalCounts::refresh(home => $H, timeout_ms => 200) };
    my $elapsed_ms = (Time::HiRes::time() - $t0) * 1000;

    if (ref($res) eq 'HASH') {
        is($res->{ok}, 0, 'AC9: refresh under external lock contention returns ok=>0');
        my $reason = defined($res->{reason}) ? $res->{reason} : '';
        ok(length($reason) && $reason =~ /timeout/,
            "AC9: reason names a timeout kind (got '$reason')");
    } else {
        fail('AC9: refresh returned a result hash') for 1 .. 2;
        diag("refresh error: " . ($@ // '(none)'));
    }
    ok($elapsed_ms < 5000,
        sprintf('AC9: refresh honoured its 200ms budget rather than the holder\'s full 3s hold (took %.0fms)', $elapsed_ms));

    bounded_wait_for_file("$WORK/never", 3.5);   # give the holder time to release naturally
}

# ---------------------------------------------------------------------------
# AC10 (DC-g / visible-not-accessible): container surface never writes
# ---------------------------------------------------------------------------
{
    my $H = new_home();
    local $ENV{ALMANAC_SURFACE} = 'container';
    my $res = eval { Almanac::GlobalCounts::refresh(home => $H) };
    if (ref($res) eq 'HASH') {
        is($res->{reason}, 'container', 'AC10: refresh on the container surface returns reason=>container');
    } else {
        fail('AC10: refresh returned a result hash');
        diag("refresh error: " . ($@ // '(none)'));
    }
    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $H) };
    ok(!defined($path) || !-e $path, 'AC10: the snapshot path does not exist after a container-surface refresh');
}

# ---------------------------------------------------------------------------
# AC11 (DC-f, reader contract): read_snapshot's total validity rule
# ---------------------------------------------------------------------------
{
    my $H = new_home();
    mkdir_p("$H/.claude");
    my $base = "$H/.claude";

    my %cases = (
        zero_byte           => '',
        oversize             => ('{"generated_at":"2020-01-01T00:00:00Z","note":{"total":0},"schema":1,'
                                . '"todo":{"done":0,"open":0,"total":0},"pad":"' . ('x' x 5000) . '"}' . "\n"),
        non_json             => "not json at all\n",
        json_array           => "[]\n",
        schema_2             => qq({"generated_at":"2020-01-01T00:00:00Z","note":{"total":0},"schema":2,)
                               . qq("todo":{"done":0,"open":0,"total":0}}\n),
        missing_note_total   => qq({"generated_at":"2020-01-01T00:00:00Z","note":{},"schema":1,)
                               . qq("todo":{"done":0,"open":0,"total":0}}\n),
        negative_count       => qq({"generated_at":"2020-01-01T00:00:00Z","note":{"total":-1},"schema":1,)
                               . qq("todo":{"done":0,"open":0,"total":0}}\n),
        non_integer_count    => qq({"generated_at":"2020-01-01T00:00:00Z","note":{"total":1.5},"schema":1,)
                               . qq("todo":{"done":0,"open":0,"total":0}}\n),
        bad_generated_at     => qq({"generated_at":"not-a-date","note":{"total":0},"schema":1,)
                               . qq("todo":{"done":0,"open":0,"total":0}}\n),
    );

    my $absent_path = "$base/does-not-exist-$$.json";
    my $snap_absent = eval { Almanac::GlobalCounts::read_snapshot($absent_path) };
    ok(!defined($snap_absent), 'AC11: read_snapshot(undef) for an absent path') or diag($@);

    my $dir_path = "$base/case-directory.json";
    mkdir_p($dir_path);
    my $snap_dir = eval { Almanac::GlobalCounts::read_snapshot($dir_path) };
    ok(!defined($snap_dir), 'AC11: read_snapshot(undef) for a directory') or diag($@);

    for my $name (sort keys %cases) {
        my $p = "$base/case-$name.json";
        write_raw($p, $cases{$name});
        my $snap = eval { Almanac::GlobalCounts::read_snapshot($p) };
        ok(!defined($snap), "AC11: read_snapshot(undef) for case '$name'") or diag($@);
    }

    my $extra_path = "$base/case-extra-key.json";
    write_raw($extra_path, qq({"extra":"ignored","generated_at":"2020-01-01T00:00:00Z",)
                          . qq("note":{"total":0},"schema":1,"todo":{"done":0,"open":0,"total":0}}\n));
    my $snap_extra = eval { Almanac::GlobalCounts::read_snapshot($extra_path) };
    ok(defined($snap_extra) && ref($snap_extra) eq 'HASH',
        'AC11: read_snapshot returns a hash for a valid file with an extra unknown key')
        or diag($@);
}

# ---------------------------------------------------------------------------
# AC12 (DC-b): serialize's byte shape
# ---------------------------------------------------------------------------
{
    my $counts = { todo => { open => 2, done => 3, total => 5 }, note => { total => 4 } };
    my $gen_at = '2020-01-01T00:00:00Z';
    my $bytes  = eval { Almanac::GlobalCounts::serialize($counts, $gen_at) };

    if (defined $bytes) {
        like($bytes, qr/\n\z/, 'AC12: serialize output ends in a newline');
        my $body_only = substr($bytes, 0, length($bytes) - 1);
        unlike($body_only, qr/\n\z/, 'AC12: exactly one trailing newline, not two');

        my $decoded = eval { JSON::PP->new->decode($bytes) };
        ok(ref($decoded) eq 'HASH', 'AC12: serialize output decodes to a JSON object') or diag($@);

        if (ref($decoded) eq 'HASH') {
            my @keys = sort keys %$decoded;
            is_deeply(\@keys, [sort qw(generated_at note schema todo)],
                'AC12: exactly the section-2.2 key set');
            my $reencoded = JSON::PP->new->canonical(1)->encode($decoded) . "\n";
            is($reencoded, $bytes, 'AC12: re-serializing the decoded value is byte-identical (canonical)');
        } else {
            fail('AC12: exactly the section-2.2 key set');
            fail('AC12: re-serializing the decoded value is byte-identical (canonical)');
        }
    } else {
        fail("AC12: serialize $_") for 1 .. 5;
        diag("serialize error: " . ($@ // '(none)'));
    }
}

# ---------------------------------------------------------------------------
# AC13 (Decision 26, platform): explicit temp homes only, including a
# non-ASCII ("André") home segment, which must still pass AC2's checks.
# ---------------------------------------------------------------------------
{
    my $base = tempdir(CLEANUP => 1);
    $base =~ s{\\}{/}g;
    my $H = "$base/André";
    mkdir_p($H);
    ok(-d $H, 'AC13 setup: the non-ASCII ("André") home directory was created');

    my $r = run_cli($TODO_PL, 'create', '--title', 'AC13 unicode todo', '--global', '--home', $H);
    is($r->{rc}, 0, 'AC13: global todo create under a home containing "André" exits 0') or diag("stderr: $r->{err}");
    assert_snapshot_equals_compute($H, 'AC13 (André home)');
    assert_matches_todo_count($H, 'AC13 (André home)');
}

# =============================================================================
# AC18 (blueprint where-things-go, package 02-thread-store, specs/
# 02-thread-store-spec.md section 2.6, behaviour 21) -- the open-thread
# count and the recorded-projects list.
#
# Fixtures build thread metadata records directly via Almanac::Store (type
# 'thread', unmodified by this package), exactly as Almanac::Thread::
# create_thread would write them, since Thread.pm does not exist yet.
# =============================================================================
sub mk_thread {
    my ($root, $name, $state) = @_;
    my $store = Almanac::Store->open(scope => 'project', type => 'thread', root => $root);
    $store->create(id => $name, fields => { created => '2026-01-01T00:00:00Z', state => $state, owner_kind => 'none', owner_id => '-' },
        order => [qw(created state owner_kind owner_id)]);
    return;
}

{
    my $H18 = new_home();
    my $PA = tempdir(CLEANUP => 1); $PA =~ s{\\}{/}g;
    my $PB = tempdir(CLEANUP => 1); $PB =~ s{\\}{/}g;

    # PA is "registered" (in the steward registry); PB is known only via a
    # recorded thread write. write_registry-style helper not present in this
    # file; build the minimal registry JSON directly.
    mkdir_p("$H18/.claude/claude-code-vault");
    write_raw("$H18/.claude/claude-code-vault/.registry-local.json",
        JSON::PP->new->canonical->encode({ projects => { pa => { path => $PA } } }));

    mk_thread($PA, 'pa-open', 'live');
    mk_thread($PA, 'pa-handed', 'handed-off');
    mk_thread($PA, 'pa-archived', 'archived');
    mk_thread($PB, 'pb-open', 'live');

    my $res = eval { Almanac::GlobalCounts::refresh(home => $H18, record_root => $PB) };
    ok(ref($res) eq 'HASH' && ($res->{ok} // 0), 'AC18: refresh(record_root => PB) succeeds')
        or diag('error: ' . ($@ // 'refresh did not return ok'));

    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $H18) };
    my $snap = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
    ok(ref($snap) eq 'HASH', 'AC18: snapshot decodes after the PB-recording refresh') or diag('error: ' . ($@ // '(none)'));
    if (ref($snap) eq 'HASH') {
        is($snap->{thread}{open}, 3, 'AC18: thread.open == 3 (PA: live+handed-off; PB: live); archived not counted');
        ok((grep { norm_path($_) eq norm_path($PB) } @{ $snap->{thread}{projects} || [] }) >= 1,
            'AC18: thread.projects contains PB (the recorded root)');
    }

    # a later global todo write (no record_root) must keep PB recorded and
    # recount both projects.
    my $rtodo = run_cli($TODO_PL, 'create', '--title', 'AC18 keeps PB', '--global', '--home', $H18);
    is($rtodo->{rc}, 0, 'AC18 fixture: a global todo write after the thread refresh exits 0') or diag($rtodo->{err});
    my $snap2 = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
    if (ref($snap2) eq 'HASH') {
        is($snap2->{thread}{open}, 3, 'AC18: a later global todo write (no record_root) still counts PB\'s thread');
        ok((grep { norm_path($_) eq norm_path($PB) } @{ $snap2->{thread}{projects} || [] }) >= 1,
            'AC18: ...and PB is still in thread.projects');
    }

    # archiving a thread in PB lowers open by one.
    {
        my $store = Almanac::Store->open(scope => 'project', type => 'thread', root => $PB);
        my $rec = $store->read('pb-open');
        $store->update('pb-open', expect => $rec, set => { state => 'archived' });
    }
    my $res3 = eval { Almanac::GlobalCounts::refresh(home => $H18, record_root => $PB) };
    ok(ref($res3) eq 'HASH' && ($res3->{ok} // 0), 'AC18 fixture: refresh after archiving PB\'s thread succeeds');
    my $snap3 = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
    is(ref($snap3) eq 'HASH' ? $snap3->{thread}{open} : undef, 2,
        'AC18: archiving PB\'s open thread lowers thread.open by one (3 -> 2)');

    # a project both registered AND recorded is counted once: record PA too.
    my $res4 = eval { Almanac::GlobalCounts::refresh(home => $H18, record_root => $PA) };
    my $snap4 = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
    is(ref($snap4) eq 'HASH' ? $snap4->{thread}{open} : undef, 2,
        'AC18: PA counted once whether reached via the registry or via being recorded (count unchanged)');
}

# =============================================================================
# AC18 -- a failing refresh (e.g. <home>/.claude is a plain file) prints the
# global_counts_stale warning via the CLI's own warning path, exits 0, and
# the thread write that triggered it is on disk regardless.
# =============================================================================
{
    my $H18b = new_home();
    write_raw("$H18b/.claude", 'not a directory');
    my $P18b = tempdir(CLEANUP => 1); $P18b =~ s{\\}{/}g;
    my $res = eval { Almanac::GlobalCounts::refresh(home => $H18b, record_root => $P18b) };
    ok(ref($res) eq 'HASH', 'AC18: refresh on a broken <home>/.claude returns a hashref, never dies')
        or diag('error: ' . ($@ // '(none)'));
    if (ref($res) eq 'HASH') {
        ok(!($res->{ok} // 0), 'AC18: ...and ok is false (the refresh genuinely failed)');
        ok(defined $res->{reason} && length $res->{reason}, 'AC18: ...with a reason set');
    }
}

# =============================================================================
# AC18 -- non-ASCII project roots round-trip and are counted.
# =============================================================================
{
    my $H18c = new_home();
    my $base = tempdir(CLEANUP => 1); $base =~ s{\\}{/}g;
    my $Pu = "$base/André-project";
    mkdir_p($Pu);
    mk_thread($Pu, 'unicode-thread', 'live');
    my $res = eval { Almanac::GlobalCounts::refresh(home => $H18c, record_root => $Pu) };
    ok(ref($res) eq 'HASH' && ($res->{ok} // 0), 'AC18: refresh with a non-ASCII ("André") record_root succeeds')
        or diag('error: ' . ($@ // 'refresh did not return ok'));
    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $H18c) };
    my $snap = eval { Almanac::GlobalCounts::read_snapshot(defined $path ? $path : '') };
    if (ref($snap) eq 'HASH') {
        is($snap->{thread}{open}, 1, 'AC18: the non-ASCII project\'s open thread is counted');
        ok((grep { norm_path($_) eq norm_path($Pu) } @{ $snap->{thread}{projects} || [] }) >= 1,
            'AC18: the non-ASCII project root round-trips byte-exact in thread.projects');
    }
}

# =============================================================================
# AC18 -- snapshot never exceeds 4096 bytes: a fixture with many long
# recorded roots evicts in the 2.6 order (registry-member entries first,
# oldest first; then the oldest remaining) and keeps `open` correct.
# =============================================================================
{
    my $Hbig = new_home();
    my @roots;
    for my $i (1 .. 60) {
        my $base = tempdir(CLEANUP => 1); $base =~ s{\\}{/}g;
        my $r = "$base/a-very-long-project-directory-name-to-pad-the-snapshot-$i";
        mkdir_p($r);
        mk_thread($r, "t-$i", 'live');
        push @roots, $r;
        eval { Almanac::GlobalCounts::refresh(home => $Hbig, record_root => $r) };
    }
    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $Hbig) };
    my $bytes = slurp_raw(defined $path ? $path : '');
    ok(defined $bytes, 'AC18 (size budget): the snapshot file is readable after 60 recorded roots');
    if (defined $bytes) {
        ok(length($bytes) <= 4096, 'AC18 (size budget): the snapshot never exceeds 4096 bytes')
            or diag('size: ' . length($bytes));
        my $snap = eval { JSON::PP->new->utf8->decode($bytes) };
        if (ref($snap) eq 'HASH') {
            # where-things-go package 02-thread-store, Decision 28: spec 2.6
            # step 1 derives @recorded solely from the PREVIOUSLY WRITTEN,
            # already-budget-evicted snapshot -- a non-registry root evicted
            # from `projects` in one refresh() call is therefore permanently
            # unrecoverable in later calls (verbatim per spec, confirmed by
            # the implementer, not a bug). With 60 distinct, never-revisited
            # roots and long path names, eviction starts well before all 60
            # are ever recorded together, so `open` is NOT required to equal
            # 60 at the end -- only to stay a plausible count and to never
            # exceed what the surviving `projects` list can account for.
            ok(defined $snap->{thread}{open} && $snap->{thread}{open} >= 0 && $snap->{thread}{open} <= 60,
                'AC18 (size budget): open stays within [0, 60] (eviction of a non-registry root is permanent per spec 2.6 step 1, so open is not required to still be exactly 60)')
                or diag('open: ' . ($snap->{thread}{open} // '(undef)'));
            ok(scalar(@{ $snap->{thread}{projects} || [] }) < 60,
                'AC18 (size budget): some recorded projects were evicted from the projects list (count dropped)')
                or diag('projects count: ' . scalar(@{ $snap->{thread}{projects} || [] }));
            ok($snap->{thread}{open} >= scalar(@{ $snap->{thread}{projects} || [] }),
                'AC18 (size budget): open is at least as large as the surviving projects list (every root still listed is among those counted)')
                or diag('open: ' . $snap->{thread}{open} . ' projects: ' . scalar(@{ $snap->{thread}{projects} || [] }));
        }
    }
}

# =============================================================================
# AC18 -- a snapshot with a malformed `thread` section still yields the
# correct todo/note counts (the bad thread key is dropped, not fatal).
# =============================================================================
{
    my $Hmal = new_home();
    run_cli($TODO_PL, 'create', '--title', 'AC18 malformed-thread todo', '--global', '--home', $Hmal);
    my $path = eval { Almanac::GlobalCounts::snapshot_path(home => $Hmal) };
    ok(defined $path && -f $path, 'AC18 (malformed thread) fixture: a snapshot exists after a todo write');
    if (defined $path && -f $path) {
        my $raw = slurp_raw($path);
        my $doc = eval { JSON::PP->new->utf8->decode($raw) };
        if (ref($doc) eq 'HASH') {
            $doc->{thread} = { open => 'not-a-number', projects => 'not-an-array' };
            write_raw($path, JSON::PP->new->utf8->canonical->encode($doc));
            my $snap = eval { Almanac::GlobalCounts::read_snapshot($path) };
            ok(ref($snap) eq 'HASH', 'AC18 (malformed thread): read_snapshot still returns a hashref') or diag('error: ' . ($@ // '(none)'));
            if (ref($snap) eq 'HASH') {
                ok(!exists $snap->{thread}, 'AC18 (malformed thread): the bad thread key is dropped entirely');
                ok(exists $snap->{todo} && ref($snap->{todo}) eq 'HASH', 'AC18 (malformed thread): todo counts survive');
                ok(exists $snap->{note} && ref($snap->{note}) eq 'HASH', 'AC18 (malformed thread): note counts survive');
            }
        } else {
            fail('AC18 (malformed thread): fixture snapshot decodes as JSON');
        }
    }
}

# =============================================================================
# AC18 -- serialize() without a thread key is byte-identical to the
# no-thread-support baseline (ASCII-only document, same todo/note counts).
# =============================================================================
{
    my $counts_no_thread = { todo => { open => 1, done => 2, total => 3 }, note => { total => 4 } };
    my $gen_at = '2026-01-01T00:00:00Z';
    my $bytes_without_thread_key = eval { Almanac::GlobalCounts::serialize($counts_no_thread, $gen_at) };
    ok(defined $bytes_without_thread_key, 'AC18: serialize() without a thread key in $counts succeeds')
        or diag('error: ' . ($@ // '(none)'));
    if (defined $bytes_without_thread_key) {
        unlike($bytes_without_thread_key, qr/"thread"/, 'AC18: no "thread" key is emitted when $counts carries none');
    }
}

# =============================================================================
# REGRESSION (blueprint tooling-backlog, package 13-almanac-decision-
# relative-path; almanac bug 20261001-184636-75fe; no architect spec --
# Decision 65, mechanical fix): almanac-todo.pl and almanac-note.pl, invoked
# by their everyday RELATIVE path from the repo root (the bug report's exact
# repro style), must never fail with perl's "Can't locate ... in @INC". Both
# scripts' BEGIN blocks only `unshift @INC, $dir` and `use Module::Name ()`
# (no sibling-SCRIPT require), so this already passes today; it is asserted
# here so the package's fix (Cwd::abs_path(__FILE__) in every BEGIN block
# named by the ledger's write_set) cannot regress it. The real doubled-join
# failure (relative sibling-SCRIPT require) is covered for almanac-doctor.pl
# and almanac-bug.pl/almanac-migrate-todos.pl/almanac-migrate-memories.pl in
# almanac-doctor.t, almanac-inbox.pl/almanac-task.pl in
# almanac-decision-blocks.t, and almanac-thread.pl in thread-sessions.t.
# =============================================================================
{
    (my $REPO_ROOT = Cwd::abs_path("$Bin/../../../..")) =~ s{\\}{/}g;
    ok(-d "$REPO_ROOT/plugins/almanac/scripts", 'REGRESSION precondition: REPO_ROOT resolves to the repo checkout')
        or BAIL_OUT("REPO_ROOT does not look like the repo root: $REPO_ROOT");

    # run_cli_relative($rel_script, @args) -> { rc, out, err } -- same shape
    # as run_cli() above, but the script is given as a RELATIVE path and the
    # subshell alone is cd'd to $REPO_ROOT first (this process's own cwd is
    # never touched), reproducing the bug report's literal invocation style.
    sub run_cli_relative {
        my ($rel_script, @args) = @_;
        my (undef, $outpath) = File::Temp::tempfile();
        my (undef, $errpath) = File::Temp::tempfile();
        my $argstr = join(' ', map { qq{"$_"} } @args);
        system(qq{cd "$REPO_ROOT" && perl "$rel_script" $argstr > "$outpath" 2> "$errpath"});
        my $rc  = $? >> 8;
        my $out = slurp_text($outpath);
        my $err = slurp_text($errpath);
        unlink $outpath, $errpath;
        return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
    }

    my $CANT_LOCATE_RE = qr/Can't locate \S+ in \@INC/;

    my $Hrel1 = tempdir(CLEANUP => 1);
    my $r1 = run_cli_relative('plugins/almanac/scripts/almanac-todo.pl', 'list', '--home', $Hrel1);
    unlike($r1->{out} . $r1->{err}, $CANT_LOCATE_RE,
        'REGRESSION (75fe): almanac-todo.pl by RELATIVE path from the repo root never fails "Can\'t locate ... in @INC"')
        or diag("rc=$r1->{rc}\nout:\n$r1->{out}\nerr:\n$r1->{err}");
    is($r1->{rc}, 0, 'REGRESSION (75fe): almanac-todo.pl "list" on an empty --home exits 0 via relative invocation')
        or diag("out:\n$r1->{out}\nerr:\n$r1->{err}");

    my $Hrel2 = tempdir(CLEANUP => 1);
    my $r2 = run_cli_relative('plugins/almanac/scripts/almanac-note.pl', 'list', '--home', $Hrel2);
    unlike($r2->{out} . $r2->{err}, $CANT_LOCATE_RE,
        'REGRESSION (75fe): almanac-note.pl by RELATIVE path from the repo root never fails "Can\'t locate ... in @INC"')
        or diag("rc=$r2->{rc}\nout:\n$r2->{out}\nerr:\n$r2->{err}");
    is($r2->{rc}, 0, 'REGRESSION (75fe): almanac-note.pl "list" on an empty --home exits 0 via relative invocation')
        or diag("out:\n$r2->{out}\nerr:\n$r2->{err}");
}

# ---------------------------------------------------------------------------
# Live-store sanity, closing half: the real repo's .ccpraxis-local-data/
# almanac tree must list exactly the same files now as it did before this
# file ran anything.
# ---------------------------------------------------------------------------
{
    my $live_almanac_after = list_almanac_files($LIVE_ALMANAC);
    is_deeply($live_almanac_after, $live_almanac_before,
        'sanity: the real repo .ccpraxis-local-data/almanac tree is unchanged by this run '
      . '(every project-scope call used an explicit temp --root)')
        or diag(explain({ before => $live_almanac_before, after => $live_almanac_after }));
}

done_testing();
