#!/usr/bin/env perl
# platform: any
# Immutable oracle for the CRUD surface of almanac-todo.pl (blueprint
# almanac-records, package 04-todos): create/list/show/edit/complete/
# reopen/delete in project scope, the machine-block error shape (inherited
# from Almanac::Store/Record verbatim), CAS behaviour, the module's count()
# shape (DC5), the list/show output grammars (DC2), body round-trip (DC4)
# and module-shape rules (MR). Scope-selection, Decision 7 container
# refusal and the global-scope sweep live in the sibling
# almanac-todo-scope.t. See specs/04-todos-spec.md.
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
use File::Spec ();
use Cwd ();
use Encode ();
use JSON::PP ();
use Time::HiRes ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $TODO_PL = "$S/almanac-todo.pl";

# ---------------------------------------------------------------------------
# blueprint where-things-go, package 03-thread-sessions (Decision 18 F7):
# `todo promote --thread` is hard ticket-gated. Every existing run_cli() call
# below that happens to invoke `promote` now needs a matching ticket minted
# for its EXACT argv first, or it will refuse `no_ticket` once the gate
# lands -- this is pure test-fixture migration (not new behaviour); the new
# package03 AC9 gate assertions are appended near the end of this file.
# ---------------------------------------------------------------------------
(my $TODO_BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
my $TODO_BPHOOK_PM = "$TODO_BUTLER_SCRIPTS/BpHook.pm";
require $TODO_BPHOOK_PM unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;
my $TODO_BSD = tempdir(CLEANUP => 1); $TODO_BSD =~ s{\\}{/}g;
my $TODO_TICKET_SEQ = 0;
sub mint_todo_ticket {
    my (@argv) = @_;
    local $ENV{BUTLER_STATE_DIR} = $TODO_BSD;
    return BpHook::write_ticket(
        { session_id => 'FIXTURE-TODO-SESSION', tool_use_id => 'FT' . (++$TODO_TICKET_SEQ),
          transcript_path => undef, cwd => '/fixture' },
        'almanac-todo', [ @argv ]);
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
    # Cwd::abs_path returns raw UTF-8 bytes with the Perl utf8 flag OFF on
    # this platform (unlike slurp_text/field0's PerlIO-decoded strings,
    # which carry the flag even for pure-ASCII content). Concatenating a
    # flagged string with this unflagged one upgrades the unflagged side via
    # implicit Latin-1, splitting a multi-byte UTF-8 sequence (e.g. "e"
    # with a diacritic) into two wrong codepoints -- silently breaking
    # -f/open against a real on-disk path whenever CWD's own path contains
    # non-ASCII (the CLAUDE.md-documented Windows non-ASCII-path landmine).
    # Decode once, here, to match every other value this file compares it to.
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

# _safe_home_for_cli() -- a dedicated tempdir every CLI spawn in this file is
# pinned to via ALMANAC_HOME/HOME/USERPROFILE. An explicit --home in @args
# always wins over these env vars (Almanac::Store::_resolve_home checks
# $opt{home} first), so this never changes behaviour for the global-scope
# fixtures that already pass --home $H.. explicitly.
#
# It exists because `todo promote` (run via run_cli, spec 2.11) refreshes
# the global-counts snapshot unconditionally -- "the thread write needs
# record_root regardless of the todo's own scope" (almanac-todo.pl's own
# comment on _cmd_promote) -- and almanac-thread.pl (run via run_thread_cli)
# does the same on every mutating verb. Neither passes --home, so without
# this pinning both resolve home from the real process environment. See
# redteam-1.md S1 (where-things-go package 02-thread-store): this is exactly
# how a prior run of this file wrote stale deleted-tempdir thread entries
# into the operator's real ~/.claude/almanac-global-counts.json.
my $SAFE_HOME_FOR_CLI;
sub _safe_home_for_cli {
    unless (defined $SAFE_HOME_FOR_CLI) {
        my $d = tempdir(CLEANUP => 1);
        $d =~ s{\\}{/}g;
        $SAFE_HOME_FOR_CLI = $d;
    }
    return $SAFE_HOME_FOR_CLI;
}

# run_cli(@args) -> { rc, out, err }
# Spawns a real perl process against almanac-todo.pl, capturing STDOUT and
# STDERR to separate temp files (never an in-memory scalar reopen -- see
# CLAUDE.md's Windows landmine list).
sub run_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    local $ENV{ALMANAC_HOME} = _safe_home_for_cli();
    local $ENV{HOME}         = _safe_home_for_cli();
    local $ENV{USERPROFILE}  = _safe_home_for_cli();
    local $ENV{BUTLER_STATE_DIR} = $TODO_BSD;
    mint_todo_ticket(@args) if @args && $args[0] eq 'promote';
    system(qq{perl "$TODO_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}

# field0($text, $key) -> value | undef -- column-0 "key: value" (result
# block, count block's top level).
sub field0 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\Q$key\E:\s(\S+)$/m;
    return undef;
}

# field2($text, $key) -- two-space-indented "  key: value" (list's per-todo
# block, count's per-scope block, and the STDERR almanac-error: machine
# block). Never match prose.
sub field2 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}

sub err_kind  { return field2($_[0], 'kind') }
sub has_almanac_error_block {
    my ($msg) = @_;
    return 0 unless defined $msg;
    return $msg =~ /^almanac-error:$/m ? 1 : 0;
}

# read_frontmatter($path) -> (\@keys, \%kv) -- parses the on-disk record's
# frontmatter, skipping the opening `---` delimiter, stopping at the
# closing one (the AC-37 store-test fix: the FIRST line IS the opening
# delimiter, so a bare /\A---/ match fires immediately and must be
# state-guarded).
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

sub extract_todo_blocks {
    my ($text) = @_;
    my @out;
    while ($text =~ /^todo:\s(\S+)\n {2}status:\s(\S+)\n {2}created:\s(\S+)\n {2}tags:\s(\S+)\n {2}title:\s(.*)$/mg) {
        push @out, { id => $1, status => $2, created => $3, tags => $4, title => $5 };
    }
    return @out;
}

sub decode_json_or_undef {
    my ($text) = @_;
    # Force scalar context on the eval so a die (e.g. an empty/malformed
    # string) returns undef, never an empty LIST -- a `return eval {...}`
    # evaluated in the caller's list context (show_json's own `return
    # (decode_json_or_undef(...), $r)`) collapses to () on die, which
    # silently drops a position from every caller's list assignment. That
    # is exactly the shape of trap this file's self-audit exists to catch:
    # a caller like `my ($after) = show_json(...)` would then bind $after
    # to $r (the run_cli result hashref) instead of undef, and every
    # ref($after) eq 'HASH' check downstream would pass on the WRONG value.
    my $decoded = eval { JSON::PP->new->decode($text) };
    return $decoded;
}

sub show_json {
    my ($id, @extra) = @_;
    my $r = run_cli('show', $id, '--json', @extra);
    return (decode_json_or_undef($r->{out}), $r);
}

# ---------------------------------------------------------------------------
# live-store sanity (house convention) -- before
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

ok(-f $TODO_PL, 'almanac-todo.pl exists at plugins/almanac/scripts/almanac-todo.pl')
    or diag('almanac-todo.pl is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

# =============================================================================
# MR -- module-shape rules, by grep (AC-41, AC-42). Run whether or not the
# script loaded, so a compile-breaking edit is still reported precisely.
# =============================================================================
{
    if (-f $TODO_PL) {
        my @lines = read_all_lines($TODO_PL);
        my (@exit_hits, @writefile_hits, @unlink_hits, @alarm_hits, @srand_hits,
            @containerenv_hits, @dockerenv_hits, @surface_hits, @frontmatter_hits);
        my $caller_line;
        for my $i (0 .. $#lines) {
            $caller_line = $i + 1 if !defined($caller_line) && $lines[$i] =~ /unless\s*\(\s*caller\s*\)/;
        }
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            next if $line =~ /^\s*#/;
            my $lineno = $i + 1;
            if ($line =~ /\bexit\s*\(/ || $line =~ /\bexit\s+\d/) {
                push @exit_hits, "$TODO_PL:$lineno: $line";
            }
            push @writefile_hits,    "$TODO_PL:$lineno: $line" if $line =~ /Almanac::Record::write_file/;
            push @unlink_hits,       "$TODO_PL:$lineno: $line" if $line =~ /\bunlink\b/;
            push @alarm_hits,        "$TODO_PL:$lineno: $line" if $line =~ /\balarm\s*\(/;
            push @srand_hits,        "$TODO_PL:$lineno: $line" if $line =~ /\bsrand\s*\(/;
            push @containerenv_hits, "$TODO_PL:$lineno: $line" if $line =~ m{/run/\.containerenv};
            push @dockerenv_hits,    "$TODO_PL:$lineno: $line" if $line =~ m{/\.dockerenv};
            push @surface_hits,      "$TODO_PL:$lineno: $line" if $line =~ /ALMANAC_SURFACE/;
            push @frontmatter_hits,  "$TODO_PL:$lineno: $line" if $line =~ /\A\s*---\s*\z/ || $line =~ /m\{\^?---/ || $line =~ m{/\^---};
        }

        # AC-41: every `exit` statement occurs after `unless (caller)`.
        my @exit_before_guard = grep {
            /^\Q$TODO_PL\E:(\d+):/ && ($1 < ($caller_line // 0))
        } @exit_hits;
        ok(defined $caller_line, 'AC-41: the file contains an `unless (caller)` main guard line')
            or diag('no `unless (caller)` found');
        unless (ok(@exit_before_guard == 0, 'AC-41: no `exit` statement occurs before the `unless (caller)` line')) {
            diag($_) for @exit_before_guard;
        }
        unless (ok(@writefile_hits == 0, 'AC-41: the file never calls Almanac::Record::write_file')) { diag($_) for @writefile_hits }
        unless (ok(@unlink_hits == 0, 'AC-41: the file contains no `unlink`')) { diag($_) for @unlink_hits }
        unless (ok(@alarm_hits == 0, 'AC-41: the file contains no `alarm`')) { diag($_) for @alarm_hits }
        unless (ok(@srand_hits == 0, 'AC-41: the file contains no `srand`')) { diag($_) for @srand_hits }

        # AC-29 / MR -- no container detection literals anywhere in this file.
        unless (ok(@containerenv_hits == 0, "AC-29: the file never mentions the literal '/run/.containerenv'")) { diag($_) for @containerenv_hits }
        unless (ok(@dockerenv_hits == 0, "AC-29: the file never mentions the literal '/.dockerenv'")) { diag($_) for @dockerenv_hits }
        unless (ok(@surface_hits == 0, "AC-29: the file never mentions the string 'ALMANAC_SURFACE'")) { diag($_) for @surface_hits }

        # AC-42: import allowlist -- core Perl plus Almanac::Store/Record only.
        my @uses = grep { /^\s*(use|require)\s+/ } @lines;
        my @allowed = (
            qr/^\s*use\s+strict\b/,          qr/^\s*use\s+warnings\b/,
            qr/^\s*use\s+Cwd\b/,             qr/^\s*use\s+File::Basename\b/,
            qr/^\s*use\s+POSIX\b/,           qr/^\s*use\s+JSON::PP\b/,
            qr/^\s*use\s+Encode\b/,          qr/^\s*use\s+Almanac::Store\b/,
            qr/^\s*use\s+Almanac::Record\b/, qr/^\s*use\s+Almanac::GlobalCounts\b/,
            # where-things-go package 02-thread-store (spec 2.11): `todo
            # promote` needs Almanac::Thread; loaded as a runtime `require`
            # (not a top-level `use`), matched here as either form.
            qr/^\s*(use|require)\s+Almanac::Thread\b/,
        );
        my @bad_imports = grep { my $l = $_; !grep { $l =~ $_ } @allowed } @uses;
        unless (ok(@bad_imports == 0, 'AC-42: the file imports only from the S2.0 allowlist')) {
            diag($_) for @bad_imports;
        }
        my @lock_import = grep { /Almanac::Lock/ } @uses;
        ok(@lock_import == 0, 'AC-42: Almanac::Lock is not imported (locking is the store\'s job)');
        my @other_plugin = grep { /butler|BpResumption|BpContinuityLease|steward/ } @uses;
        ok(@other_plugin == 0, 'AC-42: the file never mentions another plugin');

        # our $VERSION = '1.0';
        my @version_hits = grep { /our\s+\$VERSION\s*=\s*'1\.0'/ } @lines;
        ok(@version_hits >= 1, 'MR: the file declares our $VERSION = \'1.0\';');

        # package Almanac::Todo;
        my @package_hits = grep { /^\s*package\s+Almanac::Todo\s*;/ } @lines;
        ok(@package_hits >= 1, 'MR: the file declares `package Almanac::Todo;`');
    } else {
        fail("AC-41: $_") for (
            'the file contains an `unless (caller)` main guard line',
            'no `exit` statement occurs before the `unless (caller)` line',
            'the file never calls Almanac::Record::write_file',
            'the file contains no `unlink`', 'the file contains no `alarm`', 'the file contains no `srand`',
        );
        fail("AC-29: $_") for (
            "the file never mentions the literal '/run/.containerenv'",
            "the file never mentions the literal '/.dockerenv'",
            "the file never mentions the string 'ALMANAC_SURFACE'",
        );
        fail('AC-42: the file imports only from the S2.0 allowlist');
        fail('AC-42: Almanac::Lock is not imported (locking is the store\'s job)');
        fail('AC-42: the file never mentions another plugin');
        fail('MR: the file declares our $VERSION = \'1.0\';');
        fail('MR: the file declares `package Almanac::Todo;`');
    }
}

# =============================================================================
# AC-43 -- `checks:` perl -c with -I plugins/almanac/scripts and no other -I.
# =============================================================================
{
    my $cmd = qq{perl -I "$S" -c "$TODO_PL" 2>&1};
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    is($rc, 0, 'AC-43: perl -c almanac-todo.pl succeeds with -I plugins/almanac/scripts and no other -I')
        or diag("output: $out");
}

# =============================================================================
# AC-30 -- loading the file in-process (via a child, so a stray exit()/print
# cannot corrupt THIS test run) makes Almanac::Todo::count defined and runs
# no main body: no STDOUT, no STDERR, no premature exit.
# =============================================================================
{
    my $WORK30 = tempdir(CLEANUP => 1);
    $WORK30 =~ s{\\}{/}g;
    my $child = "$WORK30/ac30-child.pl";
    open(my $fh, '>', $child) or die "fixture: cannot write $child: $!";
    print {$fh} <<'AC30CHILD';
#!/usr/bin/env perl
use strict;
use warnings;
my ($todo_pl) = @ARGV;
do $todo_pl;
print "AC30-DO-ERR=" . (defined $@ && length $@ ? $@ : '(none)') . "\n" if $@;
print "AC30-SURVIVED\n";
print "AC30-COUNT-DEFINED=" . (defined &Almanac::Todo::count ? 1 : 0) . "\n";
exit 0;
AC30CHILD
    close $fh;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    system(qq{perl "$child" "$TODO_PL" > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    my $out = slurp_text($outpath) // '';
    my $err = slurp_text($errpath) // '';
    is($rc, 0, 'AC-30: a child process that `do`s almanac-todo.pl and returns exits 0 (no premature exit inside the load)')
        or diag("stdout: $out\nstderr: $err");
    is($err, '', 'AC-30: loading the file in-process prints nothing to STDERR');
    like($out, qr/^AC30-SURVIVED$/m, 'AC-30: the child survives the `do` (no exit() during load)');
    like($out, qr/^AC30-COUNT-DEFINED=1$/m, 'AC-30: Almanac::Todo::count is defined after loading');
    # Nothing besides the child's own two deliberate print lines (plus an
    # optional error-diagnostic line) may appear -- i.e. the load itself
    # prints nothing on STDOUT.
    my @lines = grep { length } split /\n/, $out;
    my @unexpected = grep { !/^AC30-(SURVIVED|COUNT-DEFINED=|DO-ERR=)/ } @lines;
    ok(@unexpected == 0, 'AC-30: the load itself (before the child\'s own prints) emits no STDOUT of its own')
        or diag('unexpected line(s): ' . join(' | ', @unexpected));
}

# do the file once for this process too, so count() can be called directly
# for AC-31/32/34/35/36 below (count() itself never dies/prints/exits per
# S2.6.6, so calling it in-process is safe and avoids a child spawn per
# fixture).
do $TODO_PL if -f $TODO_PL;

# =============================================================================
# B1 / AC-1, AC-2 -- create writes exactly one file, exits 0, correct result
# block, and the on-disk frontmatter shape.
# =============================================================================
my $ROOT1 = tempdir(CLEANUP => 1);
$ROOT1 =~ s{\\}{/}g;
my $DIR1 = norm_path($ROOT1) . '/.ccpraxis-local-data/almanac/todo';
{
    my $r = run_cli('create', '--title', 'First todo', '--root', $ROOT1);
    is($r->{rc}, 0, 'AC-1: create --title exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(field0($r->{out}, 'scope'), 'project', 'AC-1: result block carries scope: project');
    is(field0($r->{out}, 'status'), 'open', 'AC-1: result block carries status: open');
    is(field0($r->{out}, 'changed'), 'yes', 'AC-1: result block carries changed: yes');
    my $id = field0($r->{out}, 'id');
    ok(defined $id && length $id, 'AC-1: result block carries a non-empty id:');

    my @files = -d $DIR1 ? do { opendir(my $dh, $DIR1); my @f = grep { /\.md\z/ } readdir($dh); closedir $dh; @f } : ();
    is(scalar(@files), 1, 'AC-1: exactly one file was written under <root>/.ccpraxis-local-data/almanac/todo/');
    is($files[0], "$id.md", "AC-1: the file's stem equals the result block's id") if @files;

    my $path = "$DIR1/$id.md";
    my ($keys, $kv) = read_frontmatter($path);
    ok((grep { $_ eq 'title' } @$keys) >= 1, 'AC-2: frontmatter contains title');
    ok((grep { $_ eq 'status' } @$keys) >= 1, 'AC-2: frontmatter contains status');
    ok((grep { $_ eq 'created' } @$keys) >= 1, 'AC-2: frontmatter contains created');
    ok((grep { $_ eq 'id' } @$keys) >= 1, 'AC-2: frontmatter contains the store\'s id');
    ok((grep { $_ eq 'writer' } @$keys) >= 1, 'AC-2: frontmatter contains the store\'s writer');
    like($kv->{created} // '', qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, 'AC-2: created matches the ISO-8601 UTC pattern');
}

# =============================================================================
# AC-3 -- missing title (no --title at all) dies usage/missing_title and
# writes nothing; `--title` given with no following value (the argv-loop's
# own boolean-default rule would otherwise make it '1') likewise, per the
# spec's literal AC-3 text.
# =============================================================================
{
    my $ROOT3 = tempdir(CLEANUP => 1);
    $ROOT3 =~ s{\\}{/}g;
    my $DIR3 = norm_path($ROOT3) . '/.ccpraxis-local-data/almanac/todo';

    my $r1 = run_cli('create', '--root', $ROOT3);
    is($r1->{rc}, 2, 'AC-3: create with no --title at all exits 2') or diag("stderr: $r1->{err}");
    is(err_kind($r1->{err}), 'usage', 'AC-3: ...with kind: usage');
    is(field2($r1->{err}, 'detail'), 'missing_title', 'AC-3: ...and detail: missing_title');
    is($r1->{out}, '', 'AC-3: STDOUT is empty for the no-title-at-all failure');

    my $r2 = run_cli('create', '--root', $ROOT3, '--title');
    is($r2->{rc}, 2, 'AC-3: create --title with no following value exits 2') or diag("stderr: $r2->{err}");
    is(err_kind($r2->{err}), 'usage', 'AC-3: ...with kind: usage');
    is(field2($r2->{err}, 'detail'), 'missing_title', 'AC-3: ...and detail: missing_title');

    ok(!-d $DIR3 || do { opendir(my $dh, $DIR3); my @f = grep { /\.md\z/ } readdir($dh); closedir $dh; scalar(@f) == 0 },
       'AC-3: the store directory contains no new file after either missing-title attempt');
}

# =============================================================================
# AC-4 -- create --id <existing> dies exists, bytes unchanged; create --id
# 'a/b' dies bad_id.
# =============================================================================
{
    my $ROOT4 = tempdir(CLEANUP => 1);
    $ROOT4 =~ s{\\}{/}g;
    my $DIR4 = norm_path($ROOT4) . '/.ccpraxis-local-data/almanac/todo';

    my $r0 = run_cli('create', '--title', 'Original', '--id', 'todo-ac4', '--root', $ROOT4);
    is($r0->{rc}, 0, 'AC-4 fixture: create --id todo-ac4 succeeds') or diag("stderr: $r0->{err}");
    my $path4 = "$DIR4/todo-ac4.md";
    my $before = slurp_raw($path4);

    my $r1 = run_cli('create', '--title', 'Duplicate', '--id', 'todo-ac4', '--root', $ROOT4);
    is($r1->{rc}, 2, 'AC-4: create --id <existing> exits 2') or diag("stderr: $r1->{err}");
    is(err_kind($r1->{err}), 'exists', 'AC-4: ...with kind: exists');
    is(slurp_raw($path4), $before, 'AC-4: the existing file\'s bytes are unchanged after the refused duplicate create');

    my $r2 = run_cli('create', '--title', 'Bad', '--id', 'a/b', '--root', $ROOT4);
    is($r2->{rc}, 2, 'AC-4: create --id \'a/b\' exits 2');
    is(err_kind($r2->{err}), 'bad_id', 'AC-4: ...with kind: bad_id');
}

# =============================================================================
# AC-5 -- show on an unknown id: 2, kind: not_found, empty STDOUT.
# =============================================================================
{
    my $ROOT5 = tempdir(CLEANUP => 1);
    $ROOT5 =~ s{\\}{/}g;
    my $r = run_cli('show', 'no-such-todo', '--root', $ROOT5);
    is($r->{rc}, 2, 'AC-5: show <unknown id> exits 2');
    is(err_kind($r->{err}), 'not_found', 'AC-5: ...with kind: not_found');
    is($r->{out}, '', 'AC-5: STDOUT is empty');
}

# =============================================================================
# Shared fixture for the edit/complete/reopen/delete blocks below: one
# project-scope store, one todo.
# =============================================================================
my $ROOTX = tempdir(CLEANUP => 1);
$ROOTX =~ s{\\}{/}g;
my ($X_ID, $X_PATH);
{
    my $r = run_cli('create', '--title', 'Editable todo', '--root', $ROOTX, '--body', 'original body');
    $X_ID = field0($r->{out}, 'id');
    ok(defined $X_ID, 'edit-fixture: create succeeds and returns an id') or diag("stderr: $r->{err}");
    my $j = (show_json($X_ID, '--root', $ROOTX))[0];
    $X_PATH = $j->{path} if ref($j) eq 'HASH';
}

# =============================================================================
# AC-6 -- edit --title T2 --set colour=blue --unset tags: changed: yes; a
# subsequent show --json has the new title, colour, no tags, the original
# created, and a different rev.
# =============================================================================
{
    my ($before_json) = show_json($X_ID, '--root', $ROOTX);
    my $before_rev = ref($before_json) eq 'HASH' ? $before_json->{rev} : undef;
    my $before_created = ref($before_json) eq 'HASH' ? $before_json->{fields}{created} : undef;

    my $r = run_cli('edit', $X_ID, '--title', 'New Title', '--set', 'colour=blue', '--unset', 'tags', '--root', $ROOTX);
    is($r->{rc}, 0, 'AC-6: edit exits 0') or diag("stderr: $r->{err}");
    is(field0($r->{out}, 'changed'), 'yes', 'AC-6: result block carries changed: yes');

    my ($after) = show_json($X_ID, '--root', $ROOTX);
    ok(ref($after) eq 'HASH', 'AC-6: show --json after the edit decodes') or diag('not a hashref');
    if (ref($after) eq 'HASH') {
        is($after->{fields}{title}, 'New Title', 'AC-6: the new title is present');
        is($after->{fields}{colour}, 'blue', 'AC-6: the new field colour=blue is present');
        ok(!exists $after->{fields}{tags}, 'AC-6: tags is gone (unset)');
        is($after->{fields}{created}, $before_created, 'AC-6: created is unchanged');
        isnt($after->{rev}, $before_rev, 'AC-6: rev differs from before the edit');
    }
}

# =============================================================================
# AC-7 -- edit with no mutating flag: 2, detail: nothing_to_change, rev
# byte-identical (re-read, not by message).
# =============================================================================
{
    my $before_bytes = slurp_raw($X_PATH);
    my $r = run_cli('edit', $X_ID, '--root', $ROOTX);
    is($r->{rc}, 2, 'AC-7: edit with no mutating flag exits 2') or diag("stderr: $r->{err}");
    is(err_kind($r->{err}), 'usage', 'AC-7: ...with kind: usage');
    is(field2($r->{err}, 'detail'), 'nothing_to_change', 'AC-7: ...and detail: nothing_to_change');
    my $after_bytes = slurp_raw($X_PATH);
    is($after_bytes, $before_bytes, 'AC-7: the record\'s bytes (and therefore rev) are unchanged, verified by re-reading the file');
}

# =============================================================================
# AC-8 -- edit --set status=done and edit --unset status each die
# usage/status_is_reserved; edit --set writer=x dies reserved_field (the
# store's own kind, not this script's). Nothing written in any of the
# three.
# =============================================================================
{
    my $before_bytes = slurp_raw($X_PATH);

    my $r1 = run_cli('edit', $X_ID, '--set', 'status=done', '--root', $ROOTX);
    is($r1->{rc}, 2, 'AC-8: edit --set status=done exits 2');
    is(err_kind($r1->{err}), 'usage', 'AC-8: ...with kind: usage');
    is(field2($r1->{err}, 'detail'), 'status_is_reserved', 'AC-8: ...and detail: status_is_reserved');

    my $r2 = run_cli('edit', $X_ID, '--unset', 'status', '--root', $ROOTX);
    is($r2->{rc}, 2, 'AC-8: edit --unset status exits 2');
    is(err_kind($r2->{err}), 'usage', 'AC-8: ...with kind: usage');
    is(field2($r2->{err}, 'detail'), 'status_is_reserved', 'AC-8: ...and detail: status_is_reserved');

    my $r3 = run_cli('edit', $X_ID, '--set', 'writer=x', '--root', $ROOTX);
    is($r3->{rc}, 2, 'AC-8: edit --set writer=x exits 2');
    is(err_kind($r3->{err}), 'reserved_field', 'AC-8: ...with kind: reserved_field (the STORE\'s error, not usage)');

    my $after_bytes = slurp_raw($X_PATH);
    is($after_bytes, $before_bytes, 'AC-8: nothing was written by any of the three refused edits');
}

# =============================================================================
# AC-9 -- edit --expect-rev <stale hex> dies conflict, id: equal to the todo
# id, expected_rev != actual_rev; the on-disk record is byte-identical to
# before. Non-vacuity: a FRESH --expect-rev (the current rev) instead
# succeeds, so the conflict path is not simply always refusing.
# =============================================================================
{
    my ($cur) = show_json($X_ID, '--root', $ROOTX);
    my $stale_rev = (ref($cur) eq 'HASH') ? $cur->{rev} : 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef';

    # Move the record forward once so $stale_rev becomes genuinely stale.
    my $bump = run_cli('edit', $X_ID, '--set', 'bump=1', '--root', $ROOTX);
    is($bump->{rc}, 0, 'AC-9 fixture: an intervening edit succeeds, making the earlier rev stale') or diag("stderr: $bump->{err}");

    my $before_bytes = slurp_raw($X_PATH);
    my $r = run_cli('edit', $X_ID, '--title', 'Conflict Title', '--expect-rev', $stale_rev, '--root', $ROOTX);
    is($r->{rc}, 2, 'AC-9: edit --expect-rev <stale hex> exits 2') or diag("stderr: $r->{err}");
    is(err_kind($r->{err}), 'conflict', 'AC-9: ...with kind: conflict');
    is(field2($r->{err}, 'id'), $X_ID, 'AC-9: ...and id: equals the todo id');
    my $expected_rev = field2($r->{err}, 'expected_rev');
    my $actual_rev   = field2($r->{err}, 'actual_rev');
    ok(defined $expected_rev && defined $actual_rev && $expected_rev ne $actual_rev,
       'AC-9: expected_rev differs from actual_rev');
    my $after_bytes = slurp_raw($X_PATH);
    is($after_bytes, $before_bytes, 'AC-9: the record on disk is byte-identical to before the refused conflict edit');

    # Non-vacuity: the SAME edit with the CURRENT rev as baseline succeeds.
    my ($fresh) = show_json($X_ID, '--root', $ROOTX);
    my $fresh_rev = (ref($fresh) eq 'HASH') ? $fresh->{rev} : undef;
    my $r2 = run_cli('edit', $X_ID, '--title', 'Non-Stale Title', '--expect-rev', $fresh_rev, '--root', $ROOTX);
    is($r2->{rc}, 0, 'AC-9 (non-vacuity): the same shape of edit with the CURRENT rev as --expect-rev succeeds')
        or diag("stderr: $r2->{err}");
}

# =============================================================================
# AC-10 -- complete: changed: yes, status: done, completed_at matches the
# ISO pattern; a second complete: changed: no, rev IDENTICAL (non-vacuity:
# both the mutating and the idempotent path are asserted).
# =============================================================================
{
    my $ROOT10 = tempdir(CLEANUP => 1);
    $ROOT10 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'Complete me', '--root', $ROOT10);
    my $id10 = field0($r0->{out}, 'id');
    ok(defined $id10, 'AC-10 fixture: create succeeds') or diag("stderr: $r0->{err}");

    my $r1 = run_cli('complete', $id10, '--root', $ROOT10);
    is($r1->{rc}, 0, 'AC-10: complete exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'changed'), 'yes', 'AC-10: first complete: changed: yes');
    is(field0($r1->{out}, 'status'), 'done', 'AC-10: result block status: done');

    my ($j1) = show_json($id10, '--root', $ROOT10);
    ok(ref($j1) eq 'HASH', 'AC-10: show --json after complete decodes');
    if (ref($j1) eq 'HASH') {
        is($j1->{fields}{status}, 'done', 'AC-10: show --json reports status: done');
        like($j1->{fields}{completed_at} // '', qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/,
             'AC-10: completed_at matches the ISO-8601 pattern');
    }
    my $rev_after_first = ref($j1) eq 'HASH' ? $j1->{rev} : undef;

    my $r2 = run_cli('complete', $id10, '--root', $ROOT10);
    is($r2->{rc}, 0, 'AC-10: a second complete on an already-done todo still exits 0') or diag("stderr: $r2->{err}");
    is(field0($r2->{out}, 'changed'), 'no', 'AC-10: second complete: changed: no (non-vacuity pair with the first)');

    my ($j2) = show_json($id10, '--root', $ROOT10);
    is(ref($j2) eq 'HASH' ? $j2->{rev} : undef, $rev_after_first,
       'AC-10: the record\'s rev is IDENTICAL after the no-op second complete -- no write happened');
}

# =============================================================================
# AC-11 -- reopen: changed: yes, status: open, completed_at key ABSENT from
# fields; a second reopen: changed: no, rev identical (non-vacuity pair).
# =============================================================================
{
    my $ROOT11 = tempdir(CLEANUP => 1);
    $ROOT11 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'Reopen me', '--root', $ROOT11);
    my $id11 = field0($r0->{out}, 'id');
    run_cli('complete', $id11, '--root', $ROOT11);

    my $r1 = run_cli('reopen', $id11, '--root', $ROOT11);
    is($r1->{rc}, 0, 'AC-11: reopen exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'changed'), 'yes', 'AC-11: first reopen: changed: yes');
    is(field0($r1->{out}, 'status'), 'open', 'AC-11: result block status: open');

    my ($j1) = show_json($id11, '--root', $ROOT11);
    ok(ref($j1) eq 'HASH', 'AC-11: show --json after reopen decodes');
    ok(ref($j1) eq 'HASH' && !exists $j1->{fields}{completed_at}, 'AC-11: completed_at key is entirely absent from fields');
    my $rev_after_first = ref($j1) eq 'HASH' ? $j1->{rev} : undef;

    my $r2 = run_cli('reopen', $id11, '--root', $ROOT11);
    is($r2->{rc}, 0, 'AC-11: a second reopen on an already-open todo still exits 0') or diag("stderr: $r2->{err}");
    is(field0($r2->{out}, 'changed'), 'no', 'AC-11: second reopen: changed: no (non-vacuity pair)');

    my ($j2) = show_json($id11, '--root', $ROOT11);
    is(ref($j2) eq 'HASH' ? $j2->{rev} : undef, $rev_after_first,
       'AC-11: rev is identical after the no-op second reopen');
}

# =============================================================================
# AC-12 -- delete: exit 0; file gone; show then dies not_found; .md.lock
# STILL exists. delete nosuch: 2, not_found (not a silent no-op / not 0).
# =============================================================================
{
    my $ROOT12 = tempdir(CLEANUP => 1);
    $ROOT12 =~ s{\\}{/}g;
    my $DIR12 = norm_path($ROOT12) . '/.ccpraxis-local-data/almanac/todo';
    my $r0 = run_cli('create', '--title', 'Delete me', '--root', $ROOT12);
    my $id12 = field0($r0->{out}, 'id');
    ok(defined $id12, 'AC-12 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $path12 = "$DIR12/$id12.md";
    ok(-f $path12, 'AC-12 fixture: the file exists before delete');

    my $r1 = run_cli('delete', $id12, '--root', $ROOT12);
    is($r1->{rc}, 0, 'AC-12: delete exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'changed'), 'yes', 'AC-12: result block carries changed: yes');
    ok(!-f $path12, 'AC-12: the record file is gone');

    my $r2 = run_cli('show', $id12, '--root', $ROOT12);
    is($r2->{rc}, 2, 'AC-12: show <deleted id> exits 2');
    is(err_kind($r2->{err}), 'not_found', 'AC-12: ...with kind: not_found');

    ok(-f "$path12.lock", 'AC-12: <id>.md.lock still exists on disk after delete (package 01 design)');

    my $r3 = run_cli('delete', 'never-existed-todo', '--root', $ROOT12);
    is($r3->{rc}, 2, 'AC-12: delete nosuch exits 2 (not 0 -- it does NOT no-op)');
    is(err_kind($r3->{err}), 'not_found', 'AC-12: ...with kind: not_found');
}

# =============================================================================
# AC-13, AC-14, AC-15, AC-16, AC-17 -- list's default and --json forms.
# =============================================================================
{
    my $ROOTL = tempdir(CLEANUP => 1);
    $ROOTL =~ s{\\}{/}g;

    # AC-16: empty/absent store first.
    my $rempty = run_cli('list', '--root', $ROOTL);
    is($rempty->{rc}, 0, 'AC-16: list on an empty/absent store exits 0');
    unlike($rempty->{out}, qr/^todo:/m, 'AC-16: no todo: line is printed');
    is(field0($rempty->{out}, 'total'), '0', 'AC-16: total: 0');
    is(field0($rempty->{out}, 'open'), '0', 'AC-16: open: 0');
    is(field0($rempty->{out}, 'done'), '0', 'AC-16: done: 0');
    my $rempty_json = run_cli('list', '--json', '--root', $ROOTL);
    is($rempty_json->{out}, "[]\n", 'AC-16: list --json prints [] (with the same trailing newline discipline as any other output)')
        if $rempty_json->{out} =~ /\n\z/;
    my $decoded_empty = decode_json_or_undef($rempty_json->{out});
    is_deeply($decoded_empty, [], 'AC-16: list --json decodes to an empty array');

    # Create three todos, complete one, for AC-13/14/15/17.
    my @ids;
    for my $t ('Alpha todo', 'Beta todo', 'Gamma todo') {
        my $r = run_cli('create', '--title', $t, '--root', $ROOTL, '--tags', 'x,y');
        push @ids, field0($r->{out}, 'id');
    }
    ok((grep { defined } @ids) == 3, 'AC-13 fixture: three todos were created') or diag('ids: ' . join(',', map { $_ // '(undef)' } @ids));
    run_cli('complete', $ids[0], '--root', $ROOTL);

    my $r1 = run_cli('list', '--root', $ROOTL);
    is($r1->{rc}, 0, 'AC-13: list exits 0');
    my @blocks = extract_todo_blocks($r1->{out});
    is(scalar(@blocks), 3, 'AC-13: exactly one todo: block per record, with exactly the five keys in the fixed order '
                          . '(id/status/created/tags/title), two-space indented -- a block with a wrong/missing key '
                          . 'would not have matched the parser\'s regex at all')
        or diag("output:\n$r1->{out}");
    my @expect_ids = sort @ids;
    my @got_ids = map { $_->{id} } @blocks;
    is_deeply(\@got_ids, \@expect_ids, 'AC-13: ids appear in ascending ASCII order');
    is(field0($r1->{out}, 'total'), '3', 'AC-17: summary total: 3');
    is(field0($r1->{out}, 'open'), '2', 'AC-17: summary open: 2 (after completing one of three)');
    is(field0($r1->{out}, 'done'), '1', 'AC-17: summary done: 1');

    # AC-14: two consecutive invocations, no intervening mutation, are
    # byte-identical.
    my $r2 = run_cli('list', '--root', $ROOTL);
    is($r2->{out}, $r1->{out}, 'AC-14: two consecutive list invocations with no intervening mutation are byte-identical');

    # AC-15: list --json.
    my $rjson = run_cli('list', '--json', '--root', $ROOTL);
    is($rjson->{rc}, 0, 'AC-15: list --json exits 0');
    my $decoded = decode_json_or_undef($rjson->{out});
    ok(ref($decoded) eq 'ARRAY', 'AC-15: list --json decodes to an array') or diag("raw: $rjson->{out}");
    if (ref($decoded) eq 'ARRAY') {
        is(scalar(@$decoded), 3, 'AC-15: the array\'s length equals the summary total: (3)');
        is_deeply([map { $_->{id} } @$decoded], \@expect_ids, 'AC-15: element order matches the default form\'s order');
        for my $el (@$decoded) {
            for my $k (qw(id title status created writer)) {
                ok(exists $el->{$k}, "AC-15: each element carries the key '$k'");
            }
        }
    }
}

# =============================================================================
# AC-18 / B35 -- list on a store with one hand-written unparseable record:
# 2, kind: malformed, STDOUT empty (no partial listing).
# =============================================================================
{
    my $ROOT18 = tempdir(CLEANUP => 1);
    $ROOT18 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'Healthy', '--root', $ROOT18);
    is($r0->{rc}, 0, 'AC-18 fixture: one healthy todo is created') or diag("stderr: $r0->{err}");
    my $DIR18 = norm_path($ROOT18) . '/.ccpraxis-local-data/almanac/todo';
    if (-d $DIR18) {
        open(my $fh, '>', "$DIR18/bad.md") or die "fixture: cannot write $DIR18/bad.md: $!";
        print {$fh} "not frontmatter at all\n";
        close $fh;
    }
    my $r1 = run_cli('list', '--root', $ROOT18);
    is($r1->{rc}, 2, 'AC-18: list on a store with one malformed record exits 2') or diag("stderr: $r1->{err}");
    is(err_kind($r1->{err}), 'malformed', 'AC-18: ...with kind: malformed');
    is($r1->{out}, '', 'AC-18: STDOUT is empty -- no partial listing');
}

# =============================================================================
# AC-19, AC-20, AC-21 -- body round-trip: pipes, a bare `---` line, angle
# brackets, a tab, a trailing blank line.
# =============================================================================
{
    my $ROOTB = tempdir(CLEANUP => 1);
    $ROOTB =~ s{\\}{/}g;
    my $body = join("\n", 'a | b', '---', '<tag attr="x">', "col1\tcol2", 'trailing blank line follows', '') . "\n";

    my ($bfh, $bodyfile) = tempfile();
    binmode($bfh, ':raw');
    print {$bfh} $body;
    close $bfh;

    my $r0 = run_cli('create', '--title', 'Body round-trip', '--body-file', $bodyfile, '--root', $ROOTB);
    is($r0->{rc}, 0, 'AC-19 fixture: create --body-file succeeds') or diag("stderr: $r0->{err}");
    my $id19 = field0($r0->{out}, 'id');

    my ($j) = show_json($id19, '--root', $ROOTB);
    ok(ref($j) eq 'HASH', 'AC-19: show --json decodes') or diag('not a hashref');
    is($j->{body}, $body, 'AC-19: the body survives create(--body-file) -> show --json byte-identically') if ref($j) eq 'HASH';
    my $rev_from_file = ref($j) eq 'HASH' ? $j->{rev} : undef;

    # The same body passed via --body-file to a SECOND record produces an
    # identical rev is not meaningful (different id => different bytes on
    # disk); instead assert the spec's actual claim: the same body passed
    # via --body-file (as above) and via --body (a literal arg, no
    # embedded newlines needed here since the comparison is via a
    # different record with the SAME body content) produces byte-identical
    # body content when read back.
    my $r1b = run_cli('create', '--title', 'Body round-trip via literal', '--body', 'a | b', '--root', $ROOTB);
    is($r1b->{rc}, 0, 'AC-19 (single-line variant) fixture: create --body succeeds') or diag("stderr: $r1b->{err}");
    my $id19b = field0($r1b->{out}, 'id');
    my ($jb) = show_json($id19b, '--root', $ROOTB);
    is(ref($jb) eq 'HASH' ? $jb->{body} : undef, 'a | b', 'AC-19: a pipe-containing body passed via --body round-trips byte-identically');

    # AC-20: show's default form -- everything after the first empty line
    # equals the body exactly.
    my $rshow = run_cli('show', $id19, '--root', $ROOTB);
    is($rshow->{rc}, 0, 'AC-20: show (default form) exits 0') or diag("stderr: $rshow->{err}");
    if ($rshow->{out} =~ /\A(.*?)\n\n(.*)\z/s) {
        my $tail = $2;
        is($tail, $body, 'AC-20: everything after the first empty line equals the body exactly');
    } else {
        fail('AC-20: everything after the first empty line equals the body exactly')
            and diag("no blank-line separator found in:\n$rshow->{out}");
    }

    # AC-21: edit --body <the AC-19 body> on a todo created with a DIFFERENT
    # body replaces it exactly; other frontmatter fields are unchanged.
    my $rother = run_cli('create', '--title', 'Different original body', '--body', 'nothing special', '--root', $ROOTB);
    my $id21 = field0($rother->{out}, 'id');
    my ($before21) = show_json($id21, '--root', $ROOTB);
    my $before_title = ref($before21) eq 'HASH' ? $before21->{fields}{title} : undef;

    my $redit = run_cli('edit', $id21, '--body-file', $bodyfile, '--root', $ROOTB);
    is($redit->{rc}, 0, 'AC-21: edit --body-file (the AC-19 body) succeeds') or diag("stderr: $redit->{err}");
    my ($after21) = show_json($id21, '--root', $ROOTB);
    ok(ref($after21) eq 'HASH', 'AC-21: show --json after the edit decodes');
    if (ref($after21) eq 'HASH') {
        is($after21->{body}, $body, 'AC-21: the body was replaced exactly by the AC-19 body');
        is($after21->{fields}{title}, $before_title, 'AC-21: the title (an unrelated frontmatter field) is unchanged');
    }
}

# =============================================================================
# AC-22 -- a title and a body each containing 'Andre' (with the actual
# non-ASCII forms) and an em dash round-trip via create -> list -> show
# --json, with no mojibake / no double-encoding in the raw STDOUT bytes.
# =============================================================================
{
    my $ROOT22 = tempdir(CLEANUP => 1);
    $ROOT22 =~ s{\\}{/}g;
    my $name = "Andr\x{e9}"; # Andre with a combining/precomposed e-acute
    my $dash = "\x{2014}"; # em dash
    my $title22 = "Todo for $name $dash review";
    my $body22 = "Body mentions $name and a $dash dash.";

    my $r0 = run_cli('create', '--title', $title22, '--body', $body22, '--root', $ROOT22);
    is($r0->{rc}, 0, 'AC-22 fixture: create with non-ASCII title/body succeeds') or diag("stderr: $r0->{err}");
    my $id22 = field0($r0->{out}, 'id');

    my $rlist = run_cli('list', '--json', '--root', $ROOT22);
    my $decoded_list = decode_json_or_undef($rlist->{out});
    my ($el) = grep { $_->{id} eq $id22 } @{ $decoded_list // [] };
    is(ref($el) eq 'HASH' ? $el->{title} : undef, $title22, 'AC-22: the title round-trips unchanged through list --json (decoded characters)');

    my ($j22) = show_json($id22, '--root', $ROOT22);
    ok(ref($j22) eq 'HASH', 'AC-22: show --json decodes');
    if (ref($j22) eq 'HASH') {
        is($j22->{fields}{title}, $title22, 'AC-22: the title round-trips unchanged through show --json');
        is($j22->{body}, $body22, 'AC-22: the body round-trips unchanged through show --json');
    }

    # No mojibake: the raw bytes of list --json's STDOUT must never contain
    # the two-byte UTF-8-of-UTF-8 double-encoding artifact 0xC3 0x83 (which
    # is what re-encoding an already-UTF-8-decoded e-acute produces).
    my $raw_bytes = $rlist->{out};
    utf8::encode(my $copy = $raw_bytes) if utf8::is_utf8($raw_bytes);
    # slurp_text already decoded from UTF-8, so $rlist->{out} is a
    # character string; re-encode it to bytes for the mojibake check.
    my $bytes_for_check = $copy // do { my $c = $raw_bytes; utf8::encode($c); $c };
    unlike($bytes_for_check, qr/\xC3\x83/, 'AC-22: no double-encoded mojibake (0xC3 0x83) in the raw STDOUT bytes');
}

# =============================================================================
# AC-31, AC-32, AC-34, AC-35, AC-36 -- Almanac::Todo::count() shape.
# =============================================================================
my (%count_fixtures);
{
    # AC-31: 3 open + 2 done project todos, 1 open global todo.
    my $R31 = tempdir(CLEANUP => 1); $R31 =~ s{\\}{/}g;
    my $H31 = tempdir(CLEANUP => 1); $H31 =~ s{\\}{/}g;
    my @pids;
    for (1 .. 5) {
        my $r = run_cli('create', '--title', "p$_", '--root', $R31);
        push @pids, field0($r->{out}, 'id');
    }
    run_cli('complete', $pids[0], '--root', $R31);
    run_cli('complete', $pids[1], '--root', $R31);
    my $rg = run_cli('create', '--title', 'g1', '--global', '--home', $H31);
    is($rg->{rc}, 0, 'AC-31 fixture: the global todo is created') or diag("stderr: $rg->{err}");

    my $c = eval { Almanac::Todo::count(root => $R31, home => $H31) };
    ok(defined $c, 'AC-31: Almanac::Todo::count(root=>,home=>) returns a value') or diag("error: $@");
    if (ref($c) eq 'HASH') {
        is_deeply([sort keys %$c], [sort qw(type project global)], 'AC-31: the top level has exactly the keys type/project/global');
        is($c->{type}, 'todo', 'AC-31: type is the string todo');
        if (ref($c->{project}) eq 'HASH') {
            is_deeply([sort keys %{$c->{project}}], [sort qw(available reason open done total)],
                'AC-31: project scope has exactly available/reason/open/done/total');
            is($c->{project}{available}, 1, 'AC-31: project available == 1');
            is($c->{project}{reason}, 'ok', 'AC-31: project reason == ok');
            is($c->{project}{open}, 3, 'AC-31: project open == 3');
            is($c->{project}{done}, 2, 'AC-31: project done == 2');
            is($c->{project}{total}, 5, 'AC-31: project total == 5');
        } else {
            fail("AC-31: project scope key '$_'") for qw(available reason open done total);
        }
        if (ref($c->{global}) eq 'HASH') {
            is_deeply([sort keys %{$c->{global}}], [sort qw(available reason open done total)],
                'AC-31: global scope has exactly available/reason/open/done/total');
            is($c->{global}{available}, 1, 'AC-31: global available == 1');
            is($c->{global}{reason}, 'ok', 'AC-31: global reason == ok');
            is($c->{global}{open}, 1, 'AC-31: global open == 1');
            is($c->{global}{done}, 0, 'AC-31: global done == 0');
            is($c->{global}{total}, 1, 'AC-31: global total == 1');
        } else {
            fail("AC-31: global scope key '$_'") for qw(available reason open done total);
        }
    }
    $count_fixtures{ac31} = $c;
}

{
    # AC-32: count() against non-existent store directories -- available=>1,
    # reason=>'ok', all counts 0 for both scopes.
    my $R32 = tempdir(CLEANUP => 1); $R32 =~ s{\\}{/}g;
    my $H32 = tempdir(CLEANUP => 1); $H32 =~ s{\\}{/}g;
    my $c = eval { Almanac::Todo::count(root => $R32, home => $H32) };
    ok(defined $c, 'AC-32: count() against non-existent store dirs returns a value') or diag("error: $@");
    if (ref($c) eq 'HASH') {
        for my $scope (qw(project global)) {
            is($c->{$scope}{available}, 1, "AC-32: $scope available == 1 (empty is not unavailable)");
            is($c->{$scope}{reason}, 'ok', "AC-32: $scope reason == ok");
            is($c->{$scope}{open}, 0, "AC-32: $scope open == 0");
            is($c->{$scope}{done}, 0, "AC-32: $scope done == 0");
            is($c->{$scope}{total}, 0, "AC-32: $scope total == 0");
        }
    }
    $count_fixtures{ac32} = $c;
}

{
    # AC-34: one project record is unparseable -> project available=>0,
    # reason=>'malformed'; count() does not die; global (with one real
    # record) is unaffected.
    my $R34 = tempdir(CLEANUP => 1); $R34 =~ s{\\}{/}g;
    my $H34 = tempdir(CLEANUP => 1); $H34 =~ s{\\}{/}g;
    run_cli('create', '--title', 'healthy project todo', '--root', $R34);
    run_cli('create', '--title', 'healthy global todo', '--global', '--home', $H34);
    my $DIR34 = norm_path($R34) . '/.ccpraxis-local-data/almanac/todo';
    if (-d $DIR34) {
        open(my $fh, '>', "$DIR34/bad.md") or die "fixture: cannot write $DIR34/bad.md: $!";
        print {$fh} "not frontmatter at all\n";
        close $fh;
    }
    my $c = eval { Almanac::Todo::count(root => $R34, home => $H34) };
    ok(!$@, 'AC-34: count() does not die on an unparseable record') or diag("error: $@");
    ok(defined $c, 'AC-34: count() still returns a value');
    if (ref($c) eq 'HASH') {
        is($c->{project}{available}, 0, 'AC-34: project available == 0');
        is($c->{project}{reason}, 'malformed', 'AC-34: project reason == malformed');
        ok(!exists $c->{project}{open} && !exists $c->{project}{done} && !exists $c->{project}{total},
           'AC-34: project open/done/total keys are ABSENT (not zeroed)');
        is($c->{global}{available}, 1, 'AC-34: global scope is unaffected and still counted');
        is($c->{global}{total}, 1, 'AC-34: global total == 1');
    }
    $count_fixtures{ac34} = $c;
}

{
    # AC-35: a record whose status is hand-edited to 'weird' -> that scope
    # available=>0, reason=>'bad_status'.
    my $R35 = tempdir(CLEANUP => 1); $R35 =~ s{\\}{/}g;
    my $H35 = tempdir(CLEANUP => 1); $H35 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'will be tampered', '--root', $R35);
    my $id35 = field0($r0->{out}, 'id');
    ok(defined $id35, 'AC-35 fixture: create succeeds and returns an id') or diag("stderr: $r0->{err}");
    my $DIR35 = norm_path($R35) . '/.ccpraxis-local-data/almanac/todo';
    my $path35 = defined $id35 ? "$DIR35/$id35.md" : undef;
    my $bytes = defined $path35 ? slurp_raw($path35) : undef;
    my $tampered;
    if (defined $bytes) {
        ($tampered = $bytes) =~ s/^status: open$/status: weird/m;
        ok($tampered ne $bytes, 'AC-35 fixture: the hand-edit actually changed the status line') or diag($bytes);
        open(my $fh, '>:raw', $path35) or die "fixture: cannot rewrite $path35: $!";
        print {$fh} $tampered;
        close $fh;
    } else {
        fail('AC-35 fixture: the hand-edit actually changed the status line');
    }

    my $c = eval { Almanac::Todo::count(root => $R35, home => $H35) };
    ok(!$@, 'AC-35: count() does not die on a bad_status record') or diag("error: $@");
    if (ref($c) eq 'HASH') {
        is($c->{project}{available}, 0, 'AC-35: project available == 0');
        is($c->{project}{reason}, 'bad_status', 'AC-35: project reason == bad_status');
    }
    $count_fixtures{ac35} = $c;
}

# =============================================================================
# AC-36 -- for every scope entry count() can return: available==1 implies
# total==open+done and all three are non-negative integers; available==0
# implies none of the three keys exists. Asserted over the AC-31/32/34/35
# fixtures collected above (four of the spec's five; the fifth -- the
# container-unavailable case -- is asserted identically in
# almanac-todo-scope.t's AC-33 block, which this file does not duplicate).
# =============================================================================
{
    my @all_scopes;
    for my $label (qw(ac31 ac32 ac34 ac35)) {
        my $c = $count_fixtures{$label};
        next unless ref($c) eq 'HASH';
        for my $scope (qw(project global)) {
            push @all_scopes, ["$label/$scope", $c->{$scope}] if ref($c->{$scope}) eq 'HASH';
        }
    }
    ok(@all_scopes >= 6, 'AC-36 fixture: at least six scope-entries were collected across the four fixtures')
        or diag('collected: ' . scalar(@all_scopes));
    for my $pair (@all_scopes) {
        my ($label, $s) = @$pair;
        if ($s->{available}) {
            my $ok_shape = defined($s->{open}) && defined($s->{done}) && defined($s->{total})
                && $s->{open} =~ /\A\d+\z/ && $s->{done} =~ /\A\d+\z/ && $s->{total} =~ /\A\d+\z/
                && $s->{total} == $s->{open} + $s->{done};
            ok($ok_shape, "AC-36 [$label]: available==1 implies total==open+done, all non-negative integers")
                or diag("open=$s->{open} done=$s->{done} total=$s->{total}");
        } else {
            ok(!exists($s->{open}) && !exists($s->{done}) && !exists($s->{total}),
               "AC-36 [$label]: available==0 implies open/done/total keys do not exist");
        }
    }
}

# =============================================================================
# AC-38 -- two real OS processes each `create`-ing a todo in one project
# store simultaneously: both exit 0; list afterwards reports total: 2 with
# two distinct ids. Follows almanac-lock-serialization.t's run_barrier_pair
# convention.
# =============================================================================
{
    sub slurp_or_ac38 {
        my ($path) = @_;
        return '(missing)' unless -e $path;
        open(my $fh, '<', $path) or return "(unreadable: $!)";
        local $/;
        my $c = <$fh>;
        close $fh;
        return $c // '';
    }
    sub bounded_wait_for_file_ac38 {
        my ($path, $deadline_s) = @_;
        my $t0 = Time::HiRes::time();
        my $deadline = $t0 + $deadline_s;
        while (!-e $path) {
            return 0 if Time::HiRes::time() >= $deadline;
            Time::HiRes::sleep(0.02);
        }
        return 1;
    }
    sub run_barrier_pair_ac38 {
        my ($workdir, $child_pl, $argv1, $argv2) = @_;
        my %argv_by_n = (1 => $argv1, 2 => $argv2);
        for my $n (1, 2) {
            my @argv = ($workdir, $n, @{ $argv_by_n{$n} });
            my $argstr = join(' ', map { qq{"$_"} } @argv);
            system(qq{perl "$child_pl" $argstr > "$workdir/spawn-log.$n" 2>&1 &});
        }
        for my $n (1, 2) {
            unless (bounded_wait_for_file_ac38("$workdir/ready.$n", 30)) {
                fail("AC-38 barrier: child $n never signalled ready within 30s");
                diag("spawn-log.$n: " . slurp_or_ac38("$workdir/spawn-log.$n"));
                return undef;
            }
        }
        open(my $gf, '>', "$workdir/go") or die "cannot write go sentinel: $!";
        close $gf;
        my %done;
        for my $n (1, 2) {
            unless (bounded_wait_for_file_ac38("$workdir/done.$n", 60)) {
                fail("AC-38 barrier: child $n never signalled done within 60s");
                diag("spawn-log.$n: " . slurp_or_ac38("$workdir/spawn-log.$n"));
                return undef;
            }
            $done{$n} = slurp_or_ac38("$workdir/done.$n");
        }
        return { done => \%done };
    }

    my $WORK38 = tempdir(CLEANUP => 1);
    $WORK38 =~ s{\\}{/}g;
    my $ROOT38 = tempdir(CLEANUP => 1);
    $ROOT38 =~ s{\\}{/}g;

    my $create_child = "$WORK38/ac38-child.pl";
    open(my $fh, '>', $create_child) or die "fixture: cannot write $create_child: $!";
    print {$fh} <<'AC38CHILD';
#!/usr/bin/env perl
use strict;
use warnings;
use Time::HiRes ();
$| = 1;
my ($workdir, $n, $todo_pl, $root, $title) = @ARGV;
open(my $rf, '>', "$workdir/ready.$n") or die "child $n: cannot write ready: $!";
print {$rf} $$;
close $rf;
my $deadline = time() + 30;
while (!-e "$workdir/go") {
    if (time() > $deadline) {
        open(my $df, '>', "$workdir/done.$n"); print {$df} "TIMEOUT\n"; close $df;
        exit 1;
    }
    Time::HiRes::sleep(0.01);
}
my $cmdstr = qq{perl "$todo_pl" create --title "$title" --root "$root" > "$workdir/cli-out.$n" 2>&1};
system($cmdstr);
my $rc = $? >> 8;
open(my $df, '>', "$workdir/done.$n") or exit 1;
print {$df} "RC=$rc\n";
close $df;
exit 0;
AC38CHILD
    close $fh;

    my $result = run_barrier_pair_ac38(
        $WORK38, $create_child,
        [$TODO_PL, $ROOT38, 'AC38 child A'],
        [$TODO_PL, $ROOT38, 'AC38 child B'],
    );
    if ($result) {
        my ($rc1) = $result->{done}{1} =~ /^RC=(-?\d+)/m;
        my ($rc2) = $result->{done}{2} =~ /^RC=(-?\d+)/m;
        is($rc1, 0, 'AC-38: child A (concurrent create) exits 0') or diag("done.1: $result->{done}{1}");
        is($rc2, 0, 'AC-38: child B (concurrent create) exits 0') or diag("done.2: $result->{done}{2}");
    } else {
        fail('AC-38: child A (concurrent create) exits 0');
        fail('AC-38: child B (concurrent create) exits 0');
    }

    my $rlist = run_cli('list', '--root', $ROOT38);
    is($rlist->{rc}, 0, 'AC-38: list after the concurrent creates exits 0') or diag("stderr: $rlist->{err}");
    is(field0($rlist->{out}, 'total'), '2', 'AC-38: list reports total: 2');
    my @blocks38 = extract_todo_blocks($rlist->{out});
    my %uniq_ids = map { $_->{id} => 1 } @blocks38;
    is(scalar(keys %uniq_ids), 2, 'AC-38: the two todos have distinct ids');
}

# =============================================================================
# AC-39 -- unknown verb: detail: unknown_verb; no verb at all: detail:
# missing_verb; a verb needing an id without one: detail: missing_id. All
# exit exactly 2, never 1.
# =============================================================================
{
    my $ROOT39 = tempdir(CLEANUP => 1);
    $ROOT39 =~ s{\\}{/}g;

    my $r1 = run_cli('frobnicate', '--root', $ROOT39);
    is($r1->{rc}, 2, 'AC-39: an unknown verb exits 2 (never 1)');
    is(err_kind($r1->{err}), 'usage', 'AC-39: ...with kind: usage');
    is(field2($r1->{err}, 'detail'), 'unknown_verb', 'AC-39: ...and detail: unknown_verb');

    my $r2 = run_cli('--root', $ROOT39);
    is($r2->{rc}, 2, 'AC-39: no verb at all exits 2 (never 1)');
    is(err_kind($r2->{err}), 'usage', 'AC-39: ...with kind: usage');
    is(field2($r2->{err}, 'detail'), 'missing_verb', 'AC-39: ...and detail: missing_verb');

    my $r3 = run_cli('show', '--root', $ROOT39);
    is($r3->{rc}, 2, 'AC-39: show with no id exits 2 (never 1)');
    is(err_kind($r3->{err}), 'usage', 'AC-39: ...with kind: usage');
    is(field2($r3->{err}, 'detail'), 'missing_id', 'AC-39: ...and detail: missing_id');
}

# =============================================================================
# AC-40 -- a sweep of at least eight distinct failure invocations: every
# one exits exactly 2 and prints zero bytes on STDOUT.
# =============================================================================
{
    my $ROOT40 = tempdir(CLEANUP => 1);
    $ROOT40 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'seed', '--root', $ROOT40);
    my $seed_id = field0($r0->{out}, 'id');

    my @failures = (
        ['frobnicate',                                                        'unknown verb'],
        ['show', 'no-such-id',                                                'show unknown id'],
        ['create',                                                            'create with no title'],
        ['create', '--id', 'a/b', '--title', 'x',                             'create with bad id'],
        ['edit', $seed_id // 'x',                                             'edit with no mutating flag'],
        ['edit', $seed_id // 'x', '--set', 'status=done',                     'edit reserved status'],
        ['delete', 'no-such-id',                                              'delete unknown id'],
        ['list', '--project', '--global',                                    'list with conflicting scope flags'],
    );
    for my $case (@failures) {
        my ($label, @cmd_args_and_label) = @$case;
        my @args = @$case;
        my $label_text = pop @args;
        my $r = run_cli(@args, '--root', $ROOT40);
        is($r->{rc}, 2, "AC-40: [$label_text] exits exactly 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is($r->{out}, '', "AC-40: [$label_text] prints zero bytes on STDOUT");
    }
}

# =============================================================================
# AC-28 (partial, non-scope half) / B22 -- --project --global together: 2,
# detail: scope_conflict. (The global-vs-project non-fallback assertion
# lives in almanac-todo-scope.t alongside the container fixtures.)
# =============================================================================
{
    my $ROOTSC = tempdir(CLEANUP => 1);
    $ROOTSC =~ s{\\}{/}g;
    my $r = run_cli('list', '--project', '--global', '--root', $ROOTSC);
    is($r->{rc}, 2, 'B22: list --project --global exits 2');
    is(err_kind($r->{err}), 'usage', 'B22: ...with kind: usage');
    is(field2($r->{err}, 'detail'), 'scope_conflict', 'B22: ...and detail: scope_conflict');
}

# =============================================================================
# AC9 (blueprint where-things-go, package 02-thread-store, specs/
# 02-thread-store-spec.md section 2.11, behaviour 16) -- `todo promote <id>
# --thread <name>` creates a task in the thread, completes the todo with a
# pointer, and the body moves (not duplicates); re-running is a no-op;
# promoting an already-completed open todo whose task already exists
# (crash resume) reuses the task; `--thread` missing is a usage error;
# promoting a done todo with no promoted_to refuses todo_not_open.
# =============================================================================
(my $THREAD_PL_FOR_TODO = "$S/almanac-thread.pl") =~ s{\\}{/}g;
ok(-f $THREAD_PL_FOR_TODO, 'AC9 precondition: almanac-thread.pl exists (this package\'s own sibling script)')
    or diag('not present yet -- every AC9 assertion below is expected to fail for exactly that reason');

# run_thread_cli(@args) -- a real perl subprocess against almanac-thread.pl,
# pinned to the same safe tempdir home as run_cli (see _safe_home_for_cli
# above): every call here passes --root and never --home, and
# almanac-thread.pl unconditionally refreshes the global-counts snapshot on
# a mutating verb, so without this pinning the refresh resolves home from
# the real process environment.
sub run_thread_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    local $ENV{ALMANAC_HOME} = _safe_home_for_cli();
    local $ENV{HOME}         = _safe_home_for_cli();
    local $ENV{USERPROFILE}  = _safe_home_for_cli();
    local $ENV{BUTLER_STATE_DIR} = $TODO_BSD;
    # package 03-thread-sessions, Decision 18 F6: a hard ticket gate lands on
    # every almanac-thread.pl write verb -- mint one for this exact argv so
    # this file's AC9 (promote) fixture keeps working once that gate exists.
    BpHook::write_ticket(
        { session_id => 'FIXTURE-TODO-SESSION', tool_use_id => 'FT' . (++$TODO_TICKET_SEQ),
          transcript_path => undef, cwd => '/fixture' },
        'almanac-thread', [ @args ]);
    system(qq{perl "$THREAD_PL_FOR_TODO" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    return { rc => $rc, out => (slurp_text($outpath) // ''), err => (slurp_text($errpath) // '') };
}
sub thread_show_json {
    my (@args) = @_;
    my $r = run_thread_cli('show', @args, '--json');
    return (decode_json_or_undef($r->{out}), $r);
}

{
    my $ROOT9 = tempdir(CLEANUP => 1);
    $ROOT9 =~ s{\\}{/}g;
    run_thread_cli('create', 'promo-thread', '--root', $ROOT9);

    my $rc0 = run_cli('create', '--title', 'Promote me', '--body', 'original body text', '--root', $ROOT9);
    my $tid = field0($rc0->{out}, 'id');
    ok(defined $tid, 'AC9 fixture: todo create succeeds') or diag("stderr: $rc0->{err}");

    my $r1 = run_cli('promote', $tid, '--thread', 'promo-thread', '--root', $ROOT9);
    is($r1->{rc}, 0, 'AC9: todo promote <id> --thread <name> exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'thread'), 'promo-thread', 'AC9: result block carries thread: promo-thread');
    is(field0($r1->{out}, 'changed'), 'yes', 'AC9: first promote: changed: yes');
    my $task_id = field0($r1->{out}, 'task');
    ok(defined $task_id && length $task_id, 'AC9: result block carries a non-empty task: id');

    my ($todo_json) = show_json($tid, '--root', $ROOT9);
    if (ref($todo_json) eq 'HASH') {
        is($todo_json->{fields}{status}, 'done', 'AC9: the todo is completed (status: done)');
        is($todo_json->{fields}{promoted_to}, "promo-thread/$task_id", 'AC9: promoted_to points at <thread>/<task>');
        is($todo_json->{body}, "Moved to thread promo-thread, task $task_id.\n",
            'AC9: the todo body is replaced by exactly the pointer line');
    }

    my ($thread_json) = thread_show_json('promo-thread', '--root', $ROOT9);
    if (ref($thread_json) eq 'HASH') {
        my ($task) = grep { $_->{id} eq $task_id } @{ $thread_json->{tasks} };
        ok(defined $task, 'AC9: the thread holds a task with the returned id');
        if ($task) {
            is($task->{title}, 'Promote me', 'AC9: the task\'s title is the todo\'s title');
            is($task->{body}, 'original body text', 'AC9: the task\'s body is byte-identical to the todo\'s original body');
            is($task->{from_todo}, $tid, 'AC9: the task carries from_todo pointing at the todo id');
        }
    }

    # re-running: no-op, changed: no, creates nothing new.
    my $r2 = run_cli('promote', $tid, '--thread', 'promo-thread', '--root', $ROOT9);
    is($r2->{rc}, 0, 'AC9: re-running promote on an already-promoted todo exits 0') or diag("stderr: $r2->{err}");
    is(field0($r2->{out}, 'changed'), 'no', 'AC9: re-running promote: changed: no');
    is(field0($r2->{out}, 'task'), $task_id, 'AC9: re-running promote reports the SAME task id');
    my ($thread_json2) = thread_show_json('promo-thread', '--root', $ROOT9);
    is(scalar(@{ $thread_json2->{tasks} }), 1, 'AC9: re-running promote created no second task')
        if ref($thread_json2) eq 'HASH';
}

# AC9 -- crash resume: a task with from_todo already set exists in the
# thread (as if a prior promote wrote the task but crashed before
# completing the todo); a fresh promote call must reuse it, not duplicate.
{
    my $ROOT9b = tempdir(CLEANUP => 1);
    $ROOT9b =~ s{\\}{/}g;
    run_thread_cli('create', 'resume-thread', '--root', $ROOT9b);
    my $rc0 = run_cli('create', '--title', 'Crash resume me', '--root', $ROOT9b);
    my $tid = field0($rc0->{out}, 'id');
    my $radd = run_thread_cli('add', 'resume-thread', '--title', 'Crash resume me', '--root', $ROOT9b);
    # Thread.pm's add_task doesn't take --from-todo over the CLI per spec
    # 2.7's table (only the library function does); the crash-resume case is
    # therefore exercised by promote() itself finding the pre-existing link
    # via the library seam, which this black-box CLI fixture cannot pre-seed
    # without Almanac::Thread existing. The non-crash re-run case above
    # (AC9: re-running promote...) already proves idempotency; this fixture
    # is left as a precondition check so the gap is visible rather than
    # silently skipped.
    ok(-f "$S/Almanac/Thread.pm", 'AC9 crash-resume precondition: Almanac/Thread.pm exists to seed a from_todo task directly')
        or diag('not present yet -- the true crash-resume fixture needs Thread.pm\'s add_task(from_todo=>...) seam');
}

# =============================================================================
# AC9 -- --thread missing is a usage error; promoting an open todo succeeds;
# promoting an already-done todo with no promoted_to refuses todo_not_open.
# =============================================================================
{
    my $ROOT9c = tempdir(CLEANUP => 1);
    $ROOT9c =~ s{\\}{/}g;
    my $rc0 = run_cli('create', '--title', 'No thread flag', '--root', $ROOT9c);
    my $tid = field0($rc0->{out}, 'id');
    my $r = run_cli('promote', $tid, '--root', $ROOT9c);
    is($r->{rc}, 2, 'AC9: promote with no --thread flag exits 2');
    is(err_kind($r->{err}), 'usage', 'AC9: ...with kind: usage');
    is(field2($r->{err}, 'detail'), 'missing_thread', 'AC9: ...and detail: missing_thread');

    my $rc1 = run_cli('create', '--title', 'Already done, no promote', '--root', $ROOT9c);
    my $tid2 = field0($rc1->{out}, 'id');
    run_cli('complete', $tid2, '--root', $ROOT9c);
    run_thread_cli('create', 'orphan-thread', '--root', $ROOT9c);
    my $r2 = run_cli('promote', $tid2, '--thread', 'orphan-thread', '--root', $ROOT9c);
    is($r2->{rc}, 2, 'AC9: promoting an already-done todo with no promoted_to exits 2');
    is(err_kind($r2->{err}), 'refused', 'AC9: ...with kind: refused');
    is(field2($r2->{err}, 'detail'), 'todo_not_open', 'AC9: ...and detail: todo_not_open');
}

# =============================================================================
# package03 AC9 (blueprint where-things-go, package 03-thread-sessions,
# specs/03-thread-sessions-spec.md section 2.8, behaviour 9) -- `todo
# promote --thread` is ticket-gated exactly like almanac-thread.pl's own
# write verbs: a subagent ticket is refused, the todo stays open, no task is
# added; a main-session ticket succeeds and the task is created with the
# ticket's session. NOT to be confused with the 02-thread-store AC9 above
# (promote's own behavioural correctness).
# =============================================================================
{
    my $ROOT9g = tempdir(CLEANUP => 1); $ROOT9g =~ s{\\}{/}g;
    run_thread_cli('create', 'gate-thread', '--root', $ROOT9g);
    my $rc0 = run_cli('create', '--title', 'Gate me (subagent)', '--root', $ROOT9g);
    my $tid = field0($rc0->{out}, 'id');

    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my @argv = ('promote', $tid, '--thread', 'gate-thread', '--root', $ROOT9g);
    {
        local $ENV{BUTLER_STATE_DIR} = $TODO_BSD;
        BpHook::write_ticket(
            { session_id => 'GATE-SUB', tool_use_id => 'FT' . (++$TODO_TICKET_SEQ), agent_id => 'AG1',
              transcript_path => undef, cwd => '/fixture' },
            'almanac-todo', [ @argv ]);
    }
    my $argstr = join(' ', map { qq{"$_"} } @argv);
    local $ENV{ALMANAC_HOME} = _safe_home_for_cli();
    local $ENV{HOME}         = _safe_home_for_cli();
    local $ENV{USERPROFILE}  = _safe_home_for_cli();
    local $ENV{BUTLER_STATE_DIR} = $TODO_BSD;
    system(qq{perl "$TODO_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc_sub = $? >> 8;
    my $err_sub = slurp_text($errpath) // '';
    is($rc_sub, 2, 'package03 AC9: todo promote --thread with a subagent ticket exits 2');
    like($err_sub, qr/subagent/i, 'package03 AC9: ...STDERR names the subagent rule');
    my $r_check = run_cli('show', $tid, '--root', $ROOT9g);
    unlike($r_check->{out}, qr/status:\s*done/, 'package03 AC9: the todo stays open after the refused subagent promote');
    my ($tj) = thread_show_json('gate-thread', '--root', $ROOT9g);
    is(scalar(@{ $tj->{tasks} // [] }), 0, 'package03 AC9: no task was added to the thread by the refused promote')
        if ref($tj) eq 'HASH';

    my $r_main = run_cli('promote', $tid, '--thread', 'gate-thread', '--root', $ROOT9g);
    is($r_main->{rc}, 0, 'package03 AC9: the same promote from the main session succeeds') or diag($r_main->{err});
}

# =============================================================================
# Live-store sanity, again, at the end.
# =============================================================================
{
    my $live_after = count_reports_in($LIVE_STORE);
    is($live_after, $live_before,
       "AC-44: live store's report count is unchanged by this suite ($live_before before, $live_after after)");
}

done_testing();
