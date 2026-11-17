#!/usr/bin/env perl
# platform: any
# Immutable oracle for the one-shot host-side migration of legacy vault
# todos (scripts/todo-sync.pl's todos/ directory) into global almanac todo
# records (blueprint almanac-records, package 11). Derived ONLY from
# specs/11-migrate-todos-spec.md's 22 acceptance criteria -- the script this
# file drives, almanac-migrate-todos.pl, does not exist yet at the time this
# file is written, and every assertion below is expected to fail for exactly
# that reason (a failed spawn / missing file), never for a fixture defect of
# this file's own making.
#
# Everything here runs against FRESH File::Temp roots reached only through
# --home/--vault (or the HOME/USERPROFILE/ALMANAC_HOME env triple a fresh
# subprocess inherits) -- the operator's real vault, real todos and real
# ~/.claude are never touched, read or written by any assertion in this
# file. Every root's home directory is named with a literal 'e'-acute
# ("Andr\x{e9}-home"), per the harness rule, so AC20's encoding check is
# exercised by construction on every single run, not just one dedicated
# block.
#
# GIT FIXTURES: every git invocation this file makes (to build a fixture
# repo, or to prove AC12's recovery) spawns git.exe in LIST form (no shell),
# with each path argument downgraded to raw UTF-8 bytes first (_native_arg)
# -- measured on this host: a decoded (utf8-flagged) 'e'-acute path argument
# handed straight to a LIST-form exec of a native binary is misread, even
# though the identical decoded string works fine for Perl's OWN -f/-d/open
# against that same path. Git-dependent blocks `skip` with a reason when
# `git --version` fails on this host.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use Cwd ();
use Encode ();
use JSON::PP ();
use Digest::SHA ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $MIGRATE_PL = "$S/almanac-migrate-todos.pl";
my $TODO_PL    = "$S/almanac-todo.pl";

# =============================================================================
# scaffolding
# =============================================================================

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

# norm_path($p) -- verbatim from the sibling almanac-todo-crud.t: decodes
# Cwd::abs_path's unflagged UTF-8 bytes once, so concatenation against an
# already-decoded value never implicit-Latin-1-splits a multi-byte
# character (the CLAUDE.md non-ASCII-path landmine this whole file lives
# inside of, via "Andr\x{e9}-home").
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

sub sha256_of {
    my ($path) = @_;
    my $bytes = slurp_raw($path);
    return undef unless defined $bytes;
    return Digest::SHA::sha256_hex($bytes);
}

# fresh_home() -> $home -- a brand-new File::Temp root with a non-ASCII
# "Andr\x{e9}-home" leaf, per the harness rule. Never reused across blocks.
sub fresh_home {
    my $base = tempdir(CLEANUP => 1);
    $base =~ s{\\}{/}g;
    my $home = "$base/Andr\x{e9}-home";
    # APFS (macOS) refuses a file name that is not valid UTF-8 (EILSEQ). The
    # "\x{e9}" above is stored as the single byte 0xE9, which is what perl hands
    # the filesystem, so on darwin the path is utf8::upgrade'd: the same
    # characters, now stored and handed over as UTF-8 bytes, which is what a
    # real macOS path is. Elsewhere the byte form is kept as it was.
    utf8::upgrade($home) if $^O eq 'darwin';
    mkdir($home) or die "fixture: cannot mkdir $home: $!";
    return $home;
}

sub vault_dir_for  { my ($home) = @_; return norm_path($home) . '/.claude/claude-code-vault' }
sub todo_store_dir { my ($home) = @_; return vault_dir_for($home) . '/almanac/todo' }

sub store_files_in {
    my ($dir) = @_;
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return @f;
}

# run_migrate(%opt) -> { rc, out, err, raw_out }
#   opt: home (required, also seeds HOME/USERPROFILE/ALMANAC_HOME as a
#        second guard), args (arrayref), surface (optional 'container'),
#        vault (optional, appended as --vault), home_flag/vault_flag
#        (optional -- the LITERAL value passed on the --home/--vault flag
#        itself, overriding home/vault; used only by the empty-string
#        refusal tests below, so the env triple still points at a safe
#        fresh root even while probing a deliberately-empty flag value).
# Real subprocess, temp-file captures (never an in-memory STDOUT reopen --
# the CLAUDE.md Windows landmine). raw_out is the UNDECODED byte capture,
# kept alongside the decoded 'out' text for AC20's mojibake check.
#
# M4 (review): every spawn passes --home explicitly (spec §4's harness
# rule), not just the env triple -- the env triple alone never exercises
# the --home flag's own parse path or the --vault-defaults-from---home
# rule the spec's redirection contract rests on.
sub run_migrate {
    my (%opt) = @_;
    my @args = @{ $opt{args} || [] };
    my $vault_flag = exists $opt{vault_flag} ? $opt{vault_flag} : $opt{vault};
    my $home_flag  = exists $opt{home_flag}  ? $opt{home_flag}  : $opt{home};
    unshift @args, '--vault', $vault_flag if defined $vault_flag;
    unshift @args, '--home', $home_flag if defined $home_flag;

    local $ENV{HOME}         = $opt{home};
    local $ENV{USERPROFILE}  = $opt{home};
    local $ENV{ALMANAC_HOME} = $opt{home};
    if (defined $opt{surface}) { local $ENV{ALMANAC_SURFACE} = $opt{surface}; return _spawn_migrate(@args) }
    else                       { delete local $ENV{ALMANAC_SURFACE};          return _spawn_migrate(@args) }
}

sub _spawn_migrate {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$MIGRATE_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc      = $? >> 8;
    my $raw_out = slurp_raw($outpath);
    my $out     = slurp_text($outpath);
    my $err     = slurp_text($errpath);
    return {
        rc      => $rc,
        out     => (defined $out ? $out : ''),
        err     => (defined $err ? $err : ''),
        raw_out => (defined $raw_out ? $raw_out : ''),
    };
}

sub run_todo_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$TODO_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc  = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}

sub decode_json_or_undef {
    my ($text) = @_;
    my $decoded = eval { JSON::PP->new->decode($text) };
    return $decoded;
}

sub show_json_global {
    my ($id, $home) = @_;
    my $r = run_todo_cli('show', $id, '--global', '--json', '--home', $home);
    return (decode_json_or_undef($r->{out}), $r);
}

# field_line($text, $key) -> value | undef -- an UNINDENTED "key: value"
# line (this script's own top-level output fields), rest-of-line capture so
# a path value containing no leading/trailing space is still captured whole.
sub field_line {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\Q$key\E: (.*)$/m;
    return undef;
}

# field2($text, $key) -- the STDERR almanac-error: machine block's
# two-space-indented "  key: value" lines. Never matches prose.
sub field2 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}
sub err_kind { return field2($_[0], 'kind') }

# summary_removed_count($text) -- the "removed:" KEY is overloaded (a
# per-file "removed: <path>" line for each removed source, AND a summary
# "removed: <N>" count) -- scan from the bottom so the first purely-numeric
# match found is the summary, never a path line (which always contains a
# '/').
sub summary_removed_count {
    my ($text) = @_;
    return undef unless defined $text;
    for my $line (reverse split /\n/, $text) {
        return $1 if $line =~ /^removed: (\d+)$/;
    }
    return undef;
}

# extract_removed_paths($text) -- the per-file "removed: <legacy_path>"
# lines only, excluding the all-digit summary "removed: <N>" line that
# shares the same key (spec §2.6).
sub extract_removed_paths {
    my ($text) = @_;
    my @out;
    return @out unless defined $text;
    while ($text =~ /^removed: (\S+)$/mg) {
        push @out, $1 unless $1 =~ /\A\d+\z/;
    }
    return @out;
}

# ---------------------------------------------------------------------------
# Review M3 (deterministic half) -- a partial removal is recoverable ONLY
# if `recover_rev:` and the full list of sources (every `todo:` line) are
# ALREADY in the output before the FIRST per-file `removed: <path>` line is
# printed. This needs no failing unlink to prove: it is a property of
# OUTPUT ORDER on any run that removes at least one source, checked by byte
# OFFSET within the captured text, never by a separate subprocess or timing.
# ---------------------------------------------------------------------------

# _first_removed_path_pos($text) -- byte offset of the FIRST per-file
# "removed: <path>" line (excluding the all-digit summary line sharing the
# same key), or undef if none was printed.
sub _first_removed_path_pos {
    my ($text) = @_;
    return undef unless defined $text;
    while ($text =~ /^removed: (\S+)$/mg) {
        next if $1 =~ /\A\d+\z/;
        return $-[0];
    }
    return undef;
}

# _recover_rev_line_pos($text) -- byte offset of the `recover_rev:` line,
# or undef if absent.
sub _recover_rev_line_pos {
    my ($text) = @_;
    return undef unless defined $text;
    return ($text =~ /^recover_rev: [0-9a-f]{40}$/m) ? $-[0] : undef;
}

# _last_todo_line_end_pos($text) -- byte offset one past the END of the
# LAST `todo: <id> <action> <legacy_path>` line, i.e. the point after which
# "the full list of sources" is complete. undef if there is no todo: line
# at all.
sub _last_todo_line_end_pos {
    my ($text) = @_;
    return undef unless defined $text;
    my $last_end;
    while ($text =~ /^todo: \S+ \S+ \S+$/mg) { $last_end = pos($text) }
    return $last_end;
}

# assert_recover_info_precedes_removal($text, $label) -- the reusable
# check itself. When no per-file removed: line was printed at all (e.g. a
# sources: 0 run that never enters the removal loop), the ordering claim is
# vacuously true and is recorded as such rather than silently skipped or
# forced to fail on an inapplicable case.
sub assert_recover_info_precedes_removal {
    my ($text, $label) = @_;
    my $first_removed = _first_removed_path_pos($text);
    unless (defined $first_removed) {
        ok(1, "$label: no removed: <path> line was printed -- M3 ordering is vacuously satisfied (nothing to check)");
        return;
    }
    my $rr_pos = _recover_rev_line_pos($text);
    ok(defined($rr_pos) && $rr_pos < $first_removed,
        "$label: recover_rev: is already in the output before the FIRST removed: <path> line (M3)")
        or diag("recover_rev pos: " . (defined $rr_pos ? $rr_pos : '(absent)') . ", first removed pos: $first_removed");
    my $last_todo_end = _last_todo_line_end_pos($text);
    ok(defined($last_todo_end) && $last_todo_end <= $first_removed,
        "$label: the full list of sources (every todo: line) is already in the output before the FIRST removed: <path> line (M3)")
        or diag("last todo: line end pos: " . (defined $last_todo_end ? $last_todo_end : '(absent)') . ", first removed pos: $first_removed");
}

sub extract_todo_action_lines {
    my ($text) = @_;
    my @out;
    while ($text =~ /^todo: (\S+) (\S+) (\S+)$/mg) {
        push @out, { id => $1, action => $2, legacy_path => $3 };
    }
    return @out;
}

sub extract_lines_with_prefix {
    my ($text, $prefix) = @_;
    my @out;
    while ($text =~ /^\Q$prefix\E: (\S+)$/mg) { push @out, $1 }
    return @out;
}

# path_contains($haystack_path, $needle_root) -- case-insensitive,
# slash-normalized substring test, used only for "this output path lies
# under this root" assertions (AC's own harness rule), never for an exact
# comparison a script's internal normalization convention could break.
#
# Both sides are canonicalised through Cwd::abs_path FIRST: File::Temp's
# tempdir() has been observed to answer in either the MSYS "/tmp/..." form
# or the drive "/c/Users/..." form for the SAME real directory (measured on
# this host), while Almanac::Store always prints Cwd::abs_path's own
# convergent form -- so comparing either side unresolved is a false
# negative waiting to happen, not a real "does not lie under" finding.
# abs_path requires the path to exist; a path that does not (yet) exist
# falls back to the raw string, matching this sub's pre-existing tolerance.
sub _canon_for_contains {
    my ($p) = @_;
    return undef unless defined $p;
    my $abs = Cwd::abs_path($p);
    $abs = $p unless defined $abs;
    $abs =~ s{\\}{/}g;
    $abs =~ s{/\z}{};
    $abs = lc($abs) if $^O =~ /\A(?:MSWin32|msys|cygwin)\z/i;
    return $abs;
}

sub path_contains {
    my ($hay, $needle) = @_;
    return 0 unless defined $hay && defined $needle;
    my $a = _canon_for_contains($hay);
    my $b = _canon_for_contains($needle);
    return 0 unless defined $a && defined $b;
    return index($a, $b) >= 0;
}

# ---------------------------------------------------------------------------
# git helpers -- list-form only, MSYS2_ARG_CONV_EXCL scoped to each call
# alongside already-forward-slashed Windows-form paths (never POSIX /x/
# form), per the CLAUDE.md discipline. AC22's own grep proves the SCRIPT
# UNDER TEST never sets this variable; this file's OWN fixture plumbing is
# not under that constraint.
# ---------------------------------------------------------------------------
# Perl's implicit encoding of a wide-character (utf8-flagged) argv element
# passed to an EXEC'd native binary mangles a non-ASCII path on this host
# (measured: -d on the identical decoded string succeeds, while git.exe
# reports "cannot change to ... No such file or directory" for the SAME
# path) -- downgrading a byte-copy to raw UTF-8 bytes first is what native
# Win32 argv actually wants. Downgrading a COPY only, never the caller's own
# scalar.
sub _native_arg {
    my ($s) = @_;
    return $s unless defined $s;
    my $copy = "$s";
    utf8::encode($copy) if utf8::is_utf8($copy);
    return $copy;
}

# Hermetic global config, once, for every git invocation this file makes:
# an empty file so no HOST setting leaks into a fixture repo through the
# global config layer.
my (undef, $EMPTY_GIT_CONFIG) = tempfile(UNLINK => 1);
$ENV{GIT_CONFIG_GLOBAL} = $EMPTY_GIT_CONFIG;

# core.autocrlf=false is injected as a genuine PER-INVOCATION `-c` on EVERY
# git call this file makes, not just at `git init` time. Measured: `git
# init -c core.autocrlf=false` does NOT persist that value into the new
# repo's own .git/config (init's -c only affects init's own behaviour, e.g.
# init.defaultBranch), so a LATER bare `git add`/`commit`/`checkout` in the
# same repo still inherited this host's Git-for-Windows SYSTEM config
# (core.autocrlf=true is that installer's default), silently CRLF-rewriting
# file content on checkout and breaking AC12's byte-for-byte recovery
# proof. GIT_CONFIG_GLOBAL isolation (above) closes the GLOBAL leak path;
# this closes the SYSTEM one, on the one property (line endings) this
# file's own byte-identity assertions actually depend on.
sub git_capture {
    my (@args) = @_;
    my @native = map { _native_arg($_) } @args;
    my $ok = open(my $fh, '-|', 'git', '-c', 'core.autocrlf=false', @native);
    return (1, '') unless $ok;
    my $out = do { local $/; <$fh> };
    close $fh;
    my $rc = $? >> 8;
    return ($rc, defined $out ? $out : '');
}
sub git_run { my (@a) = @_; my ($rc, undef) = git_capture(@a); return $rc }

my $HAVE_GIT = (git_capture('--version'))[0] == 0 ? 1 : 0;

# run_shell_command_raw($cmd_string) -- executes a single, already-assembled
# shell command LINE with NO -c injection of any kind (bypasses git_capture
# entirely). Used ONLY by AC12 (review M2): it must prove the LITERAL
# `recover_cmd` the script prints, exactly as printed, works -- injecting
# our own `-c core.autocrlf=false` there would hide the exact condition a
# real operator faces (this host's system core.autocrlf=true) and prove
# nothing about the printed command's own correctness. Perl's system(SCALAR)
# word-splits and execs directly (no shell) when the string has no shell
# metacharacters, which recover_cmd's fixed "git -C <vault> checkout <sha>
# -- todos" shape never does.
sub run_shell_command_raw {
    my ($cmd_string) = @_;
    system($cmd_string);
    return $? >> 8;
}

# git_init_vault($vault) -- commits a .gitattributes containing '* -text'
# (review M2), matching the REAL vault's own attributes file (the coordinator
# verified this by hand; the script itself never checks for it -- review
# M1). Without it, a literal `recover_cmd` run under this host's system
# core.autocrlf=true would rewrite line endings on checkout, and AC12 would
# be proving a DIFFERENT, isolated command rather than the one an operator
# actually runs.
sub git_init_vault {
    my ($vault) = @_;
    git_run('-C', $vault, '-c', 'core.autocrlf=false', 'init', '-q');
    open(my $fh, '>:raw', "$vault/.gitattributes") or die "fixture: cannot write .gitattributes: $!";
    print {$fh} "* -text\n";
    close $fh;
    git_run('-C', $vault, 'add', 'todos', '.gitattributes');
    git_run('-C', $vault, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                          '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'initial import');
}

sub git_head {
    my ($vault) = @_;
    my ($rc, $out) = git_capture('-C', $vault, 'rev-parse', 'HEAD');
    return undef if $rc != 0;
    chomp $out;
    return $out;
}

# ---------------------------------------------------------------------------
# fixture builder -- the harness's fixed shape: 2 live todos, 1 archived
# todo, 1 README.md (never migrated). One live todo ("beta-live") carries a
# body with a pipe, a standalone '---' line, 'e'-acute, no trailing blank
# line, plus an extra `updated:` key and a `cwd:` value with 'e'-acute
# (S2.4's "every other legacy key... copied verbatim" + AC3). One live todo
# ("alpha-live") carries `tags: []` (AC3's omitted-tags case).
# ---------------------------------------------------------------------------
sub write_frontmatter_file {
    my ($path, $pairs, $body) = @_;
    open(my $fh, '>:encoding(UTF-8)', $path) or die "fixture: cannot write $path: $!";
    print {$fh} "---\n";
    print {$fh} "$_->[0]: $_->[1]\n" for @$pairs;
    print {$fh} "---\n";
    print {$fh} $body if defined $body;
    close $fh;
}

my $BODY_ALPHA = "# Alpha Title\n\nSimple alpha body text.\n";
my $BODY_BETA  = "# Beta Title\n\nBody has a | pipe character.\n---\n"
               . "A lone dash-line above this one.\ncaf\x{e9} accent line as the final line.\n";
my $BODY_GAMMA = "# Gamma Title\n\nArchived gamma body text.\n";

sub build_fixture_vault {
    my ($vault) = @_;
    make_path("$vault/todos/archive") unless -d "$vault/todos/archive";

    write_frontmatter_file("$vault/todos/alpha-live.md",
        [ ['created', '2026-01-01'], ['status', 'open'], ['tags', '[]'], ['cwd', '/c/Users/alpha'] ],
        $BODY_ALPHA);
    write_frontmatter_file("$vault/todos/beta-live.md",
        [ ['created', '2026-02-02'], ['status', 'open'], ['tags', '[x, y]'],
          ['cwd', "caf\x{e9} vault path"], ['updated', '2026-03-03T00:00:00Z'] ],
        $BODY_BETA);
    write_frontmatter_file("$vault/todos/archive/gamma-archived.md",
        [ ['created', '2025-12-12'], ['status', 'done'], ['tags', '[urgent]'], ['cwd', '/c/Users/gamma'] ],
        $BODY_GAMMA);
    write_frontmatter_file("$vault/todos/README.md",
        [ ['created', '2020-01-01'], ['status', 'open'] ], "# README\n\nnot a real todo.\n");

    my %expected = (
        'alpha-live' => {
            fields => { title => 'Alpha Title', status => 'open', created => '2026-01-01',
                        archived => 'no', legacy_path => 'todos/alpha-live.md', cwd => '/c/Users/alpha' },
            body => $BODY_ALPHA,
        },
        'beta-live' => {
            fields => { title => 'Beta Title', status => 'open', created => '2026-02-02',
                        tags => 'x,y', archived => 'no', legacy_path => 'todos/beta-live.md',
                        cwd => "caf\x{e9} vault path", updated => '2026-03-03T00:00:00Z' },
            body => $BODY_BETA,
        },
        'gamma-archived' => {
            fields => { title => 'Gamma Title', status => 'done', created => '2025-12-12',
                        tags => 'urgent', archived => 'yes',
                        legacy_path => 'todos/archive/gamma-archived.md', cwd => '/c/Users/gamma' },
            body => $BODY_GAMMA,
        },
    );
    return \%expected;
}

# assert_matches_expected($home, $id, \%expected_record, $label) -- AC2's
# content comparison, computed independently from the fixture text above,
# never from the migration script's own output.
sub assert_matches_expected {
    my ($home, $id, $expected, $label) = @_;
    my ($json, $r) = show_json_global($id, $home);
    ok(ref($json) eq 'HASH', "$label: show --json for '$id' decodes") or diag("stdout: $r->{out}\nstderr: $r->{err}");
    return unless ref($json) eq 'HASH';
    my %got = %{ $json->{fields} || {} };
    delete @got{qw(id writer rank)};
    is_deeply(\%got, $expected->{fields}, "$label: '$id' field set (minus id/writer/rank) equals the §2.4 expected set");
    is($json->{body}, $expected->{body}, "$label: '$id' body is byte-identical to the fixture's post-frontmatter bytes");
}

# =============================================================================
# module-shape rules, by grep (spec §2.1, §2.7, AC-22). Run whether or not
# the script has been written yet, so a compile-breaking edit is still
# reported precisely rather than as an undifferentiated spawn failure.
# =============================================================================
ok(-f $MIGRATE_PL, 'almanac-migrate-todos.pl exists at plugins/almanac/scripts/almanac-migrate-todos.pl')
    or diag('the script is not present yet -- every assertion below is expected to fail for '
          . 'exactly that reason, not any other.');

{
    if (-f $MIGRATE_PL) {
        my @lines = read_all_lines($MIGRATE_PL);
        my $caller_line;
        for my $i (0 .. $#lines) {
            $caller_line = $i + 1 if !defined($caller_line) && $lines[$i] =~ /unless\s*\(\s*caller\s*\)/;
        }
        my (@exit_hits, @alarm_hits, @lockunlink_hits, @msys_hits);
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            next if $line =~ /^\s*#/;
            my $lineno = $i + 1;
            push @exit_hits, "$MIGRATE_PL:$lineno: $line"
                if ($line =~ /\bexit\s*\(/ || $line =~ /\bexit\s+\d/)
                && (!defined($caller_line) || $lineno < $caller_line);
            push @alarm_hits, "$MIGRATE_PL:$lineno: $line" if $line =~ /\balarm\s*\(/;
            push @lockunlink_hits, "$MIGRATE_PL:$lineno: $line" if $line =~ /\bunlink\b/ && $line =~ /\.lock/;
            push @msys_hits, "$MIGRATE_PL:$lineno: $line" if $line =~ /MSYS2_ARG_CONV_EXCL/;
        }
        ok(defined $caller_line, 'AC-22 precondition: the file contains an `unless (caller)` main guard line')
            or diag('no `unless (caller)` found');
        unless (ok(@exit_hits == 0, 'the file never calls `exit` before its `unless (caller)` guard')) {
            diag($_) for @exit_hits;
        }
        unless (ok(@alarm_hits == 0, 'AC-22: the file contains no `alarm(`')) { diag($_) for @alarm_hits }
        unless (ok(@lockunlink_hits == 0, 'AC-22: the file never unlinks a path ending in .lock')) {
            diag($_) for @lockunlink_hits;
        }
        unless (ok(@msys_hits == 0, 'AC-22: the file never sets/mentions MSYS2_ARG_CONV_EXCL')) {
            diag($_) for @msys_hits;
        }
    } else {
        fail("AC-22: $_") for (
            'AC-22 precondition: the file contains an `unless (caller)` main guard line',
            'the file never calls `exit` before its `unless (caller)` guard',
            'AC-22: the file contains no `alarm(`',
            'AC-22: the file never unlinks a path ending in .lock',
            'AC-22: the file never sets/mentions MSYS2_ARG_CONV_EXCL',
        );
    }
}

# =============================================================================
# AC1 (DC1, S) -- fresh migration.
# =============================================================================
{
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    my $expected = build_fixture_vault($VAULT);
    my $DIR = todo_store_dir($HOME);

    my $r = run_migrate(home => $HOME, args => []);
    is($r->{rc}, 0, 'AC1: a fresh run exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(field_line($r->{out}, 'status'), 'migrated', 'AC1: status: migrated');
    ok(path_contains(field_line($r->{out}, 'source_dir') // '', $HOME), 'AC1: source_dir: lies under the fresh root');
    ok(path_contains(field_line($r->{out}, 'target_dir') // '', $HOME), 'AC1: target_dir: lies under the fresh root');

    my @files = sort(store_files_in($DIR));
    is(scalar(@files), 3, 'AC1: exactly 3 *.md records exist in target_dir');
    is_deeply(\@files, [sort qw(alpha-live.md beta-live.md gamma-archived.md)],
        'AC1: the ids equal the 3 stems (README.md is not migrated)');

    # =========================================================================
    # AC2 (DC1) -- fidelity, by content comparison against the fixture text.
    # =========================================================================
    for my $id (sort keys %$expected) {
        assert_matches_expected($HOME, $id, $expected->{$id}, 'AC2');
    }

    # =========================================================================
    # AC3 (DC1) -- created verbatim, tags form, updated/cwd with e-acute.
    # =========================================================================
    {
        my ($ja) = show_json_global('alpha-live', $HOME);
        is(ref($ja) eq 'HASH' ? $ja->{fields}{created} : undef, '2026-01-01', 'AC3: created is the legacy date string verbatim (alpha)');
        ok(ref($ja) eq 'HASH' && !exists $ja->{fields}{tags}, 'AC3: tags is absent for the tags: [] source (alpha)');

        my ($jb) = show_json_global('beta-live', $HOME);
        is(ref($jb) eq 'HASH' ? $jb->{fields}{tags} : undef, 'x,y', 'AC3: tags is "a,b" form for a bracketed list (beta)');
        is(ref($jb) eq 'HASH' ? $jb->{fields}{updated} : undef, '2026-03-03T00:00:00Z', 'AC3: updated is preserved verbatim (beta)');
        is(ref($jb) eq 'HASH' ? $jb->{fields}{cwd} : undef, "caf\x{e9} vault path", 'AC3: cwd (with e-acute) is preserved verbatim (beta)');
    }

    # =========================================================================
    # AC4 (DC2) -- archived distinguishable.
    # =========================================================================
    {
        my ($jg) = show_json_global('gamma-archived', $HOME);
        ok(ref($jg) eq 'HASH', 'AC4: show --json for the archived record decodes');
        if (ref($jg) eq 'HASH') {
            is($jg->{fields}{archived}, 'yes', 'AC4: archived: yes on the archived record');
            is($jg->{fields}{status}, 'done', 'AC4: status: done on the archived record');
            like($jg->{fields}{legacy_path}, qr{\Atodos/archive/}, 'AC4: legacy_path begins todos/archive/');
        }
        for my $id (qw(alpha-live beta-live)) {
            my ($jl) = show_json_global($id, $HOME);
            is(ref($jl) eq 'HASH' ? $jl->{fields}{archived} : undef, 'no', "AC4: archived: no on the live record '$id'");
        }
    }

    # =========================================================================
    # AC5 (DC3) -- re-run reports already-migrated, changes nothing.
    # =========================================================================
    {
        my %before_sha = map { $_ => sha256_of("$DIR/$_") } @files;
        my %before_source_sha = map {
            my $rel = $expected->{$_}{fields}{legacy_path}; ($_ => sha256_of("$VAULT/$rel"))
        } keys %$expected;

        my $r2 = run_migrate(home => $HOME, args => []);
        is($r2->{rc}, 0, 'AC5: a second identical run exits 0') or diag("stderr: $r2->{err}");
        my @actions = extract_todo_action_lines($r2->{out});
        is(scalar(@actions), 3, 'AC5: 3 todo: lines are printed');
        ok((!grep { $_->{action} ne 'already-migrated' } @actions), 'AC5: every action is already-migrated');
        is(field_line($r2->{out}, 'status'), 'already-migrated', 'AC5: status: already-migrated');
        is(field_line($r2->{out}, 'changed'), 'no', 'AC5: changed: no');
        is(field_line($r2->{out}, 'created'), '0', 'AC5: created: 0');

        for my $f (@files) {
            is(sha256_of("$DIR/$f"), $before_sha{$f}, "AC5: target file '$f' SHA-256 is unchanged");
        }
        for my $id (keys %$expected) {
            my $rel = $expected->{$id}{fields}{legacy_path};
            is(sha256_of("$VAULT/$rel"), $before_source_sha{$id}, "AC5: source file for '$id' SHA-256 is unchanged");
        }
    }

    # =========================================================================
    # AC6 (S, interruption) -- delete one target, re-run, only it is created.
    # =========================================================================
    {
        # Guarded, never a fatal die: the target only exists once a prior run
        # in this block actually created it, which depends on the very
        # script under test.
        unlink("$DIR/gamma-archived.md") if -f "$DIR/gamma-archived.md";
        my $r3 = run_migrate(home => $HOME, args => []);
        is($r3->{rc}, 0, 'AC6: a run after deleting one target exits 0') or diag("stderr: $r3->{err}");
        is(field_line($r3->{out}, 'created'), '1', 'AC6: created: 1');
        is(field_line($r3->{out}, 'already'), '2', 'AC6: already: 2');
        assert_matches_expected($HOME, 'gamma-archived', $expected->{'gamma-archived'}, 'AC6');
    }
}

# =============================================================================
# AC7 (S, conflict never overwrites).
# =============================================================================
{
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    my $expected = build_fixture_vault($VAULT);
    my $DIR = todo_store_dir($HOME);

    my $rseed = run_todo_cli('create', '--title', 'Pre-seeded conflicting title',
                              '--id', 'alpha-live', '--global', '--home', $HOME);
    is($rseed->{rc}, 0, 'AC7 fixture: pre-seeding a conflicting record for id alpha-live succeeds')
        or diag("stderr: $rseed->{err}");
    my $before_bytes = slurp_raw("$DIR/alpha-live.md");

    my $r = run_migrate(home => $HOME, args => []);
    is($r->{rc}, 2, 'AC7: the run exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(err_kind($r->{err}), 'conflict', 'AC7: ...kind: conflict');
    my @actions = extract_todo_action_lines($r->{out});
    my ($conflict_line) = grep { $_->{id} eq 'alpha-live' } @actions;
    ok(defined $conflict_line, 'AC7: a todo: alpha-live conflict line is printed');
    is($conflict_line->{action}, 'conflict', 'AC7: ...with action: conflict') if defined $conflict_line;

    is(slurp_raw("$DIR/alpha-live.md"), $before_bytes, 'AC7: the pre-seeded record is byte-unchanged');
    for my $id (qw(beta-live gamma-archived)) {
        ok(!-f "$DIR/$id.md", "AC7: no record exists for '$id' either -- nothing at all was written");
    }
}

# =============================================================================
# AC8 (S, Decision 4) -- six invalid-source variants, each its own fresh root.
# =============================================================================
{
    my @variants = (
        { label => 'no frontmatter',        kind => 'bad_source',          line => 1,
          raw   => "This file has no frontmatter at all.\nJust plain text.\n" },
        { label => 'status: cancelled',      kind => 'unsupported_status',
          raw   => "---\ncreated: 2026-01-01\nstatus: cancelled\ntags: [a]\n---\n\n# T\n\nBody.\n" },
        { label => 'missing created',        kind => 'missing_created',
          raw   => "---\nstatus: open\ntags: [a]\n---\n\n# T\n\nBody.\n" },
        { label => 'tags without brackets',  kind => 'bad_source',
          raw   => "---\ncreated: 2026-01-01\nstatus: open\ntags: a,b\n---\n\n# T\n\nBody.\n" },
        { label => 'a rank: frontmatter key', kind => 'reserved_legacy_key',
          raw   => "---\ncreated: 2026-01-01\nstatus: open\nrank: 5\n---\n\n# T\n\nBody.\n" },
    );

    for my $v (@variants) {
        my $HOME = fresh_home();
        my $VAULT = vault_dir_for($HOME);
        make_path("$VAULT/todos");
        open(my $fh, '>:raw', "$VAULT/todos/bad.md") or die "fixture: cannot write bad.md: $!";
        print {$fh} Encode::encode('UTF-8', $v->{raw});
        close $fh;

        my $r = run_migrate(home => $HOME, args => []);
        is($r->{rc}, 2, "AC8 ($v->{label}): exits 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is(err_kind($r->{err}), $v->{kind}, "AC8 ($v->{label}): ...kind: $v->{kind}");
        if (defined $v->{line}) {
            is(field2($r->{err}, 'line'), "$v->{line}", "AC8 ($v->{label}): ...line: $v->{line}");
        }
        ok(!-d todo_store_dir($HOME), "AC8 ($v->{label}): target_dir does not exist afterwards");
    }

    # The non-UTF-8-byte variant needs a genuinely invalid byte written
    # outside any character-string round trip.
    {
        my $HOME = fresh_home();
        my $VAULT = vault_dir_for($HOME);
        make_path("$VAULT/todos");
        open(my $fh, '>:raw', "$VAULT/todos/bad.md") or die "fixture: cannot write bad.md: $!";
        print {$fh} "---\ncreated: 2026-01-01\nstatus: open\ntags: [a]\n---\n\n# T\n\nInvalid byte: \xFF here.\n";
        close $fh;

        my $r = run_migrate(home => $HOME, args => []);
        is($r->{rc}, 2, 'AC8 (non-UTF-8 byte): exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is(err_kind($r->{err}), 'bad_source', 'AC8 (non-UTF-8 byte): ...kind: bad_source');
        ok(!-d todo_store_dir($HOME), 'AC8 (non-UTF-8 byte): target_dir does not exist afterwards');
    }
}

# =============================================================================
# AC9 (S, no duplicate) -- live dup.md + archived dup.md.
# =============================================================================
{
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    make_path("$VAULT/todos/archive");
    write_frontmatter_file("$VAULT/todos/dup.md",
        [ ['created', '2026-01-01'], ['status', 'open'] ], "# Live Dup\n\nBody.\n");
    write_frontmatter_file("$VAULT/todos/archive/dup.md",
        [ ['created', '2025-01-01'], ['status', 'done'] ], "# Archived Dup\n\nBody.\n");

    my $r = run_migrate(home => $HOME, args => []);
    is($r->{rc}, 2, 'AC9: exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(err_kind($r->{err}), 'id_collision', 'AC9: ...kind: id_collision');
    ok(!-d todo_store_dir($HOME), 'AC9: nothing is written');
}

# =============================================================================
# AC10 (S) -- --dry-run.
# =============================================================================
{
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    build_fixture_vault($VAULT);

    my $r = run_migrate(home => $HOME, args => ['--dry-run']);
    is($r->{rc}, 0, 'AC10: --dry-run exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    my @actions = extract_todo_action_lines($r->{out});
    is(scalar(@actions), 3, 'AC10: 3 todo: lines are printed');
    ok((!grep { $_->{action} ne 'would-create' } @actions), 'AC10: every action is would-create');
    is(field_line($r->{out}, 'status'), 'dry-run', 'AC10: status: dry-run');
    is(field_line($r->{out}, 'changed'), 'no', 'AC10: changed: no');
    ok(!-d todo_store_dir($HOME), 'AC10: target_dir does not exist afterwards');
}

SKIP: {
    skip 'AC10 (--remove-sources half): git is not available on this host', 3 unless $HAVE_GIT;
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    my $expected = build_fixture_vault($VAULT);
    git_init_vault($VAULT);
    my %before_source_sha = map {
        my $rel = $expected->{$_}{fields}{legacy_path}; ($_ => sha256_of("$VAULT/$rel"))
    } keys %$expected;

    my $r = run_migrate(home => $HOME, args => ['--dry-run', '--remove-sources']);
    is($r->{rc}, 0, 'AC10 (--remove-sources): --dry-run exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    my @would_remove = extract_lines_with_prefix($r->{out}, 'would-remove');
    is(scalar(@would_remove), 3, 'AC10 (--remove-sources): 3 would-remove: lines are printed');

    my $unchanged = 1;
    for my $id (keys %$expected) {
        my $rel = $expected->{$id}{fields}{legacy_path};
        $unchanged = 0 unless sha256_of("$VAULT/$rel") eq $before_source_sha{$id};
    }
    ok($unchanged, 'AC10 (--remove-sources): no source file was actually removed');
}

# =============================================================================
# AC11 (DC4, S) / AC12 (DC4) / AC13 (DC3, S) -- one continuing git fixture:
# removal, then (in a SEPARATE clone) recovery, then re-runs on the ORIGINAL
# post-removal state.
# =============================================================================
SKIP: {
    skip 'AC11-14: git is not available on this host', 1 unless $HAVE_GIT;

    my ($HOME_A, $VAULT_A, $expected_A, $head_before_A, $recover_rev, $recover_cmd, $source_dir_line);
    # ---- AC11: removal on its own fixture (VAULT_A), whose post-removal
    # state AC13 then continues from. ----
    {
        $HOME_A = fresh_home();
        $VAULT_A = vault_dir_for($HOME_A);
        $expected_A = build_fixture_vault($VAULT_A);
        git_init_vault($VAULT_A);
        $head_before_A = git_head($VAULT_A);
        ok(defined $head_before_A && $head_before_A =~ /\A[0-9a-f]{40}\z/,
            'AC11 fixture: git rev-parse HEAD (taken before the run) is a 40-hex sha');

        my $r = run_migrate(home => $HOME_A, args => ['--remove-sources']);
        is($r->{rc}, 0, 'AC11: --remove-sources exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
        my @removed = extract_removed_paths($r->{out});
        is(scalar(@removed), 3, 'AC11: 3 removed: lines are printed');
        is(summary_removed_count($r->{out}), '3', 'AC11: the summary removed: N count is 3');
        assert_recover_info_precedes_removal($r->{out}, 'AC11');
        for my $id (keys %$expected_A) {
            my $rel = $expected_A->{$id}{fields}{legacy_path};
            ok(!-f "$VAULT_A/$rel", "AC11: source file for '$id' is gone");
        }
        $recover_rev = field_line($r->{out}, 'recover_rev');
        is($recover_rev, $head_before_A, 'AC11: recover_rev equals git rev-parse HEAD taken before the run');
        $source_dir_line = field_line($r->{out}, 'source_dir');
        $recover_cmd = field_line($r->{out}, 'recover_cmd');
        if (defined $source_dir_line && defined $recover_rev) {
            (my $vault_as_printed = $source_dir_line) =~ s{/todos\z}{};
            is($recover_cmd, "git -C $vault_as_printed checkout $recover_rev -- todos",
                'AC11: recover_cmd equals the literal git -C <vault> checkout <recover_rev> -- todos');
        } else {
            fail('AC11: recover_cmd equals the literal git -C <vault> checkout <recover_rev> -- todos')
        }
    }

    # ---- AC12: recovery is real, proven on a FRESH clone of the same
    # pre-removal fixture so AC13's continuation of VAULT_A is untouched. ----
    {
        my $HOME_B = fresh_home();
        my $VAULT_B = vault_dir_for($HOME_B);
        my $expected_B = build_fixture_vault($VAULT_B);
        my %pre_sha = map {
            my $rel = $expected_B->{$_}{fields}{legacy_path}; ($_ => sha256_of("$VAULT_B/$rel"))
        } keys %$expected_B;
        git_init_vault($VAULT_B);

        my $r = run_migrate(home => $HOME_B, args => ['--remove-sources']);
        is($r->{rc}, 0, 'AC12 fixture: the removal run on the clone exits 0') or diag("stderr: $r->{err}");
        my $recover_cmd_b = field_line($r->{out}, 'recover_cmd');

        # M2: run the PRINTED recover_cmd VERBATIM -- no injected -c flags of
        # any kind (run_shell_command_raw bypasses git_capture entirely).
        # GIT_CONFIG_GLOBAL isolation (process-wide $ENV, set once above)
        # still applies, but nothing else does: byte-identity here must come
        # from the fixture's own '* -text' attribute (git_init_vault), the
        # same mechanism that protects the real vault, not from a test-only
        # override that the literal command an operator pastes never gets.
        SKIP: {
            skip 'AC12: no recover_cmd to test recovery with (the migrate run above did not succeed)', 1
                unless defined $recover_cmd_b;
            my $rc = run_shell_command_raw($recover_cmd_b);
            is($rc, 0, 'AC12: the PRINTED recover_cmd, run exactly as printed, exits 0');
        }
        for my $id (keys %$expected_B) {
            my $rel = $expected_B->{$id}{fields}{legacy_path};
            ok(-f "$VAULT_B/$rel", "AC12: '$id' source file exists again after recovery");
            is(sha256_of("$VAULT_B/$rel"), $pre_sha{$id}, "AC12: '$id' restored file is byte-identical (SHA-256) to before migration");
        }
    }

    # ---- AC13: continuing from AC11's post-removal state on VAULT_A. ----
    {
        my $r1 = run_migrate(home => $HOME_A, args => []);
        is($r1->{rc}, 0, 'AC13: re-run without --remove-sources exits 0') or diag("stderr: $r1->{err}");
        is(field_line($r1->{out}, 'sources'), '0', 'AC13: sources: 0 (without --remove-sources)');
        is(field_line($r1->{out}, 'status'), 'already-migrated', 'AC13: status: already-migrated (without --remove-sources)');
        is(field_line($r1->{out}, 'changed'), 'no', 'AC13: changed: no (without --remove-sources)');

        my $DIR_A = todo_store_dir($HOME_A);
        my %before_sha = map { $_ => sha256_of("$DIR_A/$_") } store_files_in($DIR_A);

        my $r2 = run_migrate(home => $HOME_A, args => ['--remove-sources']);
        is($r2->{rc}, 0, 'AC13: re-run with --remove-sources exits 0') or diag("stderr: $r2->{err}");
        is(field_line($r2->{out}, 'sources'), '0', 'AC13: sources: 0 (with --remove-sources)');
        is(field_line($r2->{out}, 'status'), 'already-migrated', 'AC13: status: already-migrated (with --remove-sources)');
        is(field_line($r2->{out}, 'changed'), 'no', 'AC13: changed: no (with --remove-sources)');
        assert_recover_info_precedes_removal($r2->{out}, 'AC13');

        my $unchanged = 1;
        for my $f (keys %before_sha) {
            $unchanged = 0 unless sha256_of("$DIR_A/$f") eq $before_sha{$f};
        }
        ok($unchanged, 'AC13: every target file is unchanged across both re-runs');
    }
}

# =============================================================================
# AC14 (S, interrupted removal) -- own fresh git fixture: plain run, manual
# unlink of one source, then --remove-sources.
# =============================================================================
SKIP: {
    skip 'AC14: git is not available on this host', 1 unless $HAVE_GIT;

    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    my $expected = build_fixture_vault($VAULT);
    git_init_vault($VAULT);

    my $r0 = run_migrate(home => $HOME, args => []);
    is($r0->{rc}, 0, 'AC14 fixture: a plain run (no removal) exits 0') or diag("stderr: $r0->{err}");

    my $gone_rel = $expected->{'gamma-archived'}{fields}{legacy_path};
    unlink("$VAULT/$gone_rel") or die "fixture: cannot unlink $gone_rel: $!";

    my $r1 = run_migrate(home => $HOME, args => ['--remove-sources']);
    is($r1->{rc}, 0, 'AC14: --remove-sources after a manual unlink still exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    isnt(err_kind($r1->{err}), 'not_recoverable', 'AC14: no not_recoverable');
    my @removed = extract_removed_paths($r1->{out});
    is(scalar(@removed), 2, 'AC14: 2 removed: lines are printed (for the two remaining sources)');
    is(summary_removed_count($r1->{out}), '2', 'AC14: removed: 2 (the summary count)');
    assert_recover_info_precedes_removal($r1->{out}, 'AC14');
}

# =============================================================================
# AC15 (DC4, S) -- not_recoverable, three sub-fixtures.
# =============================================================================
{
    # (a) vault is not a git repo at all.
    my $HOME_A = fresh_home();
    my $VAULT_A = vault_dir_for($HOME_A);
    build_fixture_vault($VAULT_A);
    my $r_a = run_migrate(home => $HOME_A, args => ['--remove-sources']);
    is($r_a->{rc}, 2, 'AC15 (not a git repo): exits 2') or diag("stdout: $r_a->{out}\nstderr: $r_a->{err}");
    is(err_kind($r_a->{err}), 'not_recoverable', 'AC15 (not a git repo): ...kind: not_recoverable');
    ok(!-d todo_store_dir($HOME_A), 'AC15 (not a git repo): no target record is created');
    ok(-f "$VAULT_A/todos/alpha-live.md", 'AC15 (not a git repo): no source is removed');
}

SKIP: {
    skip 'AC15 (untracked/modified sources): git is not available on this host', 1 unless $HAVE_GIT;

    # (b) a source is untracked.
    my $HOME_B = fresh_home();
    my $VAULT_B = vault_dir_for($HOME_B);
    build_fixture_vault($VAULT_B);
    git_run('-C', $VAULT_B, '-c', 'core.autocrlf=false', 'init', '-q');
    git_run('-C', $VAULT_B, 'add', 'todos/alpha-live.md', 'todos/README.md');
    git_run('-C', $VAULT_B, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                            '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'partial import');
    my $r_b = run_migrate(home => $HOME_B, args => ['--remove-sources']);
    is($r_b->{rc}, 2, 'AC15 (untracked source): exits 2') or diag("stdout: $r_b->{out}\nstderr: $r_b->{err}");
    is(err_kind($r_b->{err}), 'not_recoverable', 'AC15 (untracked source): ...kind: not_recoverable');
    ok(!-d todo_store_dir($HOME_B), 'AC15 (untracked source): no target record is created');
    ok(-f "$VAULT_B/todos/beta-live.md", 'AC15 (untracked source): no source is removed');

    # (c) a committed source is then modified.
    my $HOME_C = fresh_home();
    my $VAULT_C = vault_dir_for($HOME_C);
    build_fixture_vault($VAULT_C);
    git_init_vault($VAULT_C);
    open(my $fh, '>>:encoding(UTF-8)', "$VAULT_C/todos/alpha-live.md") or die $!;
    print {$fh} "an extra appended line that dirties this file\n";
    close $fh;

    my $r_c = run_migrate(home => $HOME_C, args => ['--remove-sources']);
    is($r_c->{rc}, 2, 'AC15 (modified source): exits 2') or diag("stdout: $r_c->{out}\nstderr: $r_c->{err}");
    is(err_kind($r_c->{err}), 'not_recoverable', 'AC15 (modified source): ...kind: not_recoverable');
    ok(!-d todo_store_dir($HOME_C), 'AC15 (modified source): no target record is created');
    ok(-f "$VAULT_C/todos/beta-live.md", 'AC15 (modified source): no source is removed');

    # (d) review M1 -- a checkout of HEAD would NOT restore the same bytes
    # the script parsed, even though `ls-files --error-unmatch` and `diff
    # --quiet HEAD` both report clean: no '* -text' attribute, and the
    # repo's OWN config (not this file's git_capture override, which only
    # binds OUR invocations, never the script-under-test's own child
    # process) carries core.autocrlf=true -- deterministic on any host,
    # standing in for "this host's system core.autocrlf=true" without
    # depending on what the real system config happens to be. `git diff
    # --quiet HEAD` reports clean here because autocrlf normalises BOTH
    # sides of that comparison symmetrically; only an actual checkout (or
    # `git cat-file --filters`, review M1's proposed fix) exposes the CRLF
    # rewrite. EXPECTED RED until M1 lands: today's preflight has no such
    # check, so this run currently migrates and removes normally instead of
    # refusing.
    my $HOME_D = fresh_home();
    my $VAULT_D = vault_dir_for($HOME_D);
    build_fixture_vault($VAULT_D);
    git_run('-C', $VAULT_D, 'init', '-q');
    git_run('-C', $VAULT_D, 'add', 'todos');
    git_run('-C', $VAULT_D, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid',
                            '-c', 'commit.gpgsign=false', 'commit', '-q', '-m', 'initial import');
    # A real config WRITE, unaffected by git_capture's own per-invocation -c
    # override (which only changes what THIS command reads, never what a
    # `config` subcommand chooses to persist to .git/config).
    git_run('-C', $VAULT_D, 'config', 'core.autocrlf', 'true');

    my $r_d = run_migrate(home => $HOME_D, args => ['--remove-sources']);
    is($r_d->{rc}, 2, 'AC15 (M1, checkout not byte-exact): exits 2')
        or diag("stdout: $r_d->{out}\nstderr: $r_d->{err}");
    is(err_kind($r_d->{err}), 'not_recoverable', 'AC15 (M1, checkout not byte-exact): ...kind: not_recoverable');
    ok(!-d todo_store_dir($HOME_D), 'AC15 (M1, checkout not byte-exact): no target record is created');
    ok(-f "$VAULT_D/todos/beta-live.md", 'AC15 (M1, checkout not byte-exact): no source is removed');
}

# =============================================================================
# Review M3 -- a failed/interrupted removal must not lose the recovery
# record. The second source's unlink is forced to fail. PROBED first,
# because forcing a genuine, externally-visible unlink() failure turns out
# to be HOST-DEPENDENT: on this host, measured directly, neither the DOS
# read-only attribute (chmod 0444), nor a parent-directory write-deny
# (chmod 0555 on the containing dir), nor an explicit Windows ACL DENY of
# Delete+DeleteChild (via icacls, even after breaking inheritance and
# denying Full access) stops Perl's own unlink() from succeeding -- this
# account's token evidently bypasses DACL-based delete protection
# entirely (a common property of an elevated/admin token, e.g. an enabled
# SeBackupPrivilege/SeRestorePrivilege). Asserting against a trap that
# silently does not trap would be red for the WRONG reason (a fixture
# defect of this file's own making, not the missing behaviour), so the
# probe below decides, and the real assertions run only if the probe
# proves the trap genuinely works here.
#
# If it does: by the time the loop reaches file 2, EVERY line the printed
# §2.6 block ever carries (the `todo:` lines, `recover_rev:`,
# `recover_cmd:`) must already be in STDOUT, and the first file's
# `removed:` line must be there too -- printed BEFORE the failing unlink is
# attempted, not batched at the end. EXPECTED RED until the fix lands
# (review's suggested fix: print the header/recover_rev/recover_cmd before
# the unlink loop, then each `removed:` line as it happens) -- today,
# everything is printed only after the loop finishes successfully, so a
# mid-loop failure currently loses all of it.
# =============================================================================
SKIP: {
    skip 'Review M3: git is not available on this host', 1 unless $HAVE_GIT;

    my $PROBEDIR = tempdir(CLEANUP => 1);
    my $probe_file = "$PROBEDIR/probe.txt";
    open(my $pfh, '>', $probe_file) or die "fixture: cannot write $probe_file: $!";
    print {$pfh} "probe\n";
    close $pfh;
    chmod(0444, $probe_file);
    my $probe_blocked = !unlink($probe_file);
    chmod(0644, $probe_file) if -f $probe_file;
    unlink($probe_file) if -f $probe_file;

    skip 'Review M3: this host\'s account bypasses read-only-attribute delete protection '
       . '(measured: chmod 0444 does not stop unlink()) -- not testable here', 1
        unless $probe_blocked;

    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    my $expected = build_fixture_vault($VAULT);
    git_init_vault($VAULT);

    my $beta_path = "$VAULT/" . $expected->{'beta-live'}{fields}{legacy_path};
    ok(-f $beta_path, 'Review M3 fixture: the second-in-order source exists before the read-only trap is set');
    chmod(0444, $beta_path);

    my $r = run_migrate(home => $HOME, args => ['--remove-sources']);

    # Cleanup FIRST, unconditionally, so a read-only file never survives
    # this block and defeats File::Temp's own CLEANUP => 1 on exit --
    # regardless of what the assertions below find.
    chmod(0644, $beta_path) if -f $beta_path;

    isnt($r->{rc}, 0, 'Review M3: a run that cannot unlink its second source does not exit 0')
        or diag("stdout: $r->{out}\nstderr: $r->{err}");
    ok(!-f "$VAULT/" . $expected->{'alpha-live'}{fields}{legacy_path},
        'Review M3: the FIRST source (alpha-live, ahead of the read-only trap in enumeration order) was removed');
    ok(-f $beta_path, 'Review M3: the read-only (second) source itself was not removed');

    like($r->{out}, qr/^recover_rev: [0-9a-f]{40}$/m,
        'Review M3: STDOUT already carries recover_rev: BEFORE the failing unlink was reached');
    like($r->{out}, qr/^recover_cmd: git -C /m,
        'Review M3: STDOUT already carries recover_cmd: BEFORE the failing unlink was reached');
    like($r->{out}, qr{^removed: todos/alpha-live\.md$}m,
        'Review M3: STDOUT already carries the removed: line for the file that succeeded before the failure');
}

# =============================================================================
# AC16 (S) -- no_sources.
# =============================================================================
{
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    make_path("$VAULT/todos");
    my $r = run_migrate(home => $HOME, args => []);
    is($r->{rc}, 2, 'AC16: an empty todos/ with an empty target store exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(err_kind($r->{err}), 'no_sources', 'AC16: ...kind: no_sources');
}

# =============================================================================
# AC17 (S, host-only / Decision 7) -- container surface.
# =============================================================================
{
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    my $expected = build_fixture_vault($VAULT);
    my %before_sha = map {
        my $rel = $expected->{$_}{fields}{legacy_path}; ($_ => sha256_of("$VAULT/$rel"))
    } keys %$expected;

    my $r = run_migrate(home => $HOME, args => [], surface => 'container');
    is($r->{rc}, 2, 'AC17: on a container surface the run exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(err_kind($r->{err}), 'scope_unavailable', 'AC17: ...kind: scope_unavailable');
    ok(!-d vault_dir_for($HOME) . '/almanac', "AC17: target_dir's parent tree (.../almanac) is not created");

    my $unchanged = 1;
    for my $id (keys %$expected) {
        my $rel = $expected->{$id}{fields}{legacy_path};
        $unchanged = 0 unless sha256_of("$VAULT/$rel") eq $before_sha{$id};
    }
    ok($unchanged, 'AC17: sources are untouched');
}

# =============================================================================
# AC18 (S, no duplicate under concurrency) -- two runs launched concurrently.
# =============================================================================
{
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    build_fixture_vault($VAULT);
    my $DIR = todo_store_dir($HOME);

    local $ENV{HOME}         = $HOME;
    local $ENV{USERPROFILE}  = $HOME;
    local $ENV{ALMANAC_HOME} = $HOME;
    delete local $ENV{ALMANAC_SURFACE};

    my @cmd = ('perl', $MIGRATE_PL, '--home', $HOME);
    my ($ok1, $ok2) = (open(my $fh1, '-|', @cmd), undef);
    my $fh2;
    $ok2 = open($fh2, '-|', @cmd);
    ok($ok1 && $ok2, 'AC18: both concurrent subprocesses were spawned') or diag("open failed: $!");

    my $out1 = defined($fh1) ? do { local $/; <$fh1> } : '';
    close $fh1 if $fh1;
    my $rc1 = $? >> 8;
    my $out2 = defined($fh2) ? do { local $/; <$fh2> } : '';
    close $fh2 if $fh2;
    my $rc2 = $? >> 8;

    is($rc1, 0, 'AC18: the first concurrent run exits 0') or diag("out1: $out1");
    is($rc2, 0, 'AC18: the second concurrent run exits 0') or diag("out2: $out2");

    my @files = store_files_in($DIR);
    is(scalar(@files), 3, 'AC18: exactly 3 records exist after both runs');

    my $c1 = field_line($out1, 'created');
    my $c2 = field_line($out2, 'created');
    is(($c1 // 0) + ($c2 // 0), 3,
        "AC18: the two runs' created counts sum to 3 (got " . ($c1 // 'undef') . ' + ' . ($c2 // 'undef') . ')');
}

# =============================================================================
# AC19 (DC1, S) -- visible to package 04 via almanac-todo.pl.
# =============================================================================
{
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    build_fixture_vault($VAULT);

    my $r = run_migrate(home => $HOME, args => []);
    is($r->{rc}, 0, 'AC19 fixture: a fresh run exits 0') or diag("stderr: $r->{err}");

    my $rl = run_todo_cli('list', '--global', '--json', '--home', $HOME);
    is($rl->{rc}, 0, 'AC19: almanac-todo.pl list --global --json exits 0') or diag("stderr: $rl->{err}");
    my $decoded = decode_json_or_undef($rl->{out});
    is(ref($decoded) eq 'ARRAY' ? scalar(@$decoded) : -1, 3, 'AC19: list --global lists all 3 migrated records');

    my $rc = run_todo_cli('count', '--json', '--home', $HOME);
    is($rc->{rc}, 0, 'AC19: almanac-todo.pl count --json exits 0') or diag("stderr: $rc->{err}");
    my $count = decode_json_or_undef($rc->{out});
    ok(ref($count) eq 'HASH', 'AC19: count --json decodes to a hash');
    if (ref($count) eq 'HASH') {
        is($count->{global}{available}, 1, 'AC19: global available: 1');
        is($count->{global}{open}, 2, 'AC19: global open: 2');
        is($count->{global}{done}, 1, 'AC19: global done: 1');
        is($count->{global}{total}, 3, 'AC19: global total: 3');
    }
}

# =============================================================================
# AC20 (S) -- redirection: source_dir: encodes the non-ASCII home leaf once.
# =============================================================================
{
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    build_fixture_vault($VAULT);
    my $r = run_migrate(home => $HOME, args => ['--dry-run']);
    is($r->{rc}, 0, 'AC20 fixture: --dry-run exits 0') or diag("stderr: $r->{err}");

    my $raw = $r->{raw_out};
    unlike($raw, qr/\xC3\x83\xC2\xA9/, 'AC20: no double-encoded mojibake (0xC3 0x83 0xC2 0xA9) for the e-acute in the home path');
    like($raw, qr/Andr\xC3\xA9-home/, 'AC20: the home leaf appears with the e-acute encoded exactly once (0xC3 0xA9)');
}

# =============================================================================
# AC21 (S) -- usage refusals.
# =============================================================================
{
    my $HOME = fresh_home();

    my $r1 = run_migrate(home => $HOME, args => ['--bogus-flag']);
    is($r1->{rc}, 2, 'AC21: an unknown flag exits 2') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'usage', 'AC21: ...kind: usage (unknown flag)');

    my $r2 = run_migrate(home => $HOME, args => ['a-stray-positional-argument']);
    is($r2->{rc}, 2, 'AC21: a positional argument exits 2') or diag("stdout: $r2->{out}\nstderr: $r2->{err}");
    is(err_kind($r2->{err}), 'usage', 'AC21: ...kind: usage (positional argument)');

    my $r3 = run_migrate(home => $HOME, args => ['--dry-run', '--home']);
    is($r3->{rc}, 2, 'AC21: --home with no following value exits 2') or diag("stdout: $r3->{out}\nstderr: $r3->{err}");
    is(err_kind($r3->{err}), 'usage', 'AC21: ...kind: usage (--home with no value)');

    ok(!-d todo_store_dir($HOME), 'AC21: no target dir was created by any of the three refused calls');
}

# =============================================================================
# Review minor #1 (M4 companion) -- an EMPTY --home/--vault value must be
# refused as usage, never silently fall through to ALMANAC_HOME/HOME (the
# REAL vault on an operator's own machine, if a wrapping script's own
# `--home "$ROOT"` ever ran with $ROOT unset). EXPECTED RED until the fix
# lands. The env triple is still seeded to a real, safe fresh root
# (run_migrate's home => $HOME) so a still-buggy script that DOES fall
# through lands in that temp root rather than in a real, un-sandboxed home.
# =============================================================================
{
    my $HOME = fresh_home();

    my $r1 = run_migrate(home => $HOME, args => [], home_flag => '');
    is($r1->{rc}, 2, 'Review minor #1: --home "" exits 2') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'usage', 'Review minor #1: --home "" ...kind: usage');

    my $r2 = run_migrate(home => $HOME, args => [], vault_flag => '');
    is($r2->{rc}, 2, 'Review minor #1: --vault "" exits 2') or diag("stdout: $r2->{out}\nstderr: $r2->{err}");
    is(err_kind($r2->{err}), 'usage', 'Review minor #1: --vault "" ...kind: usage');

    ok(!-d todo_store_dir($HOME), 'Review minor #1: no target dir was created by either empty-value refusal');
}

# =============================================================================
# Point 6 (review minors #3 and #4) -- --dry-run leaves the target store's
# on-disk state byte-identical: no pending-reorder journal is consumed, and
# (when combined with --remove-sources, the only path that reaches git at
# all) the vault's .git/index is not touched by an implicit `git diff`
# refresh. EXPECTED RED until the fix lands.
# =============================================================================
{
    # #4: a pending journal in the target store must survive a --dry-run
    # untouched -- store->list()'s automatic recover() is a WRITE, and the
    # "sources: 0 / legacy_path probe" branch (spec §2.8) reaches list()
    # regardless of --dry-run.
    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    build_fixture_vault($VAULT);

    my $r0 = run_migrate(home => $HOME, args => []);
    is($r0->{rc}, 0, 'Point 6 (#4) fixture: a full migration run exits 0') or diag("stderr: $r0->{err}");

    my $store_dir     = todo_store_dir($HOME);
    my $journal_path  = "$store_dir/.reorder-journal.json";
    my $store_lock    = "$store_dir/.store.lock";
    require JSON::PP;
    open(my $jfh, '>:raw', $journal_path) or die "fixture: cannot write $journal_path: $!";
    print {$jfh} JSON::PP->new->canonical->encode({
        version => 1, writer => 'fixture', started_at => time(),
        entries => { 'alpha-live' => { prev_rank => undef, next_rank => undef } },
    });
    close $jfh;
    my $journal_before = slurp_raw($journal_path);
    ok(!-f $store_lock, 'Point 6 (#4) fixture: no .store.lock exists yet');

    my $r1 = run_migrate(home => $HOME, args => ['--dry-run']);
    is($r1->{rc}, 0, 'Point 6 (#4): a second --dry-run (sources now 0) exits 0') or diag("stderr: $r1->{err}");
    is(slurp_raw($journal_path), $journal_before,
        'Point 6 (#4): the pending journal is byte-identical after --dry-run (no silent recover())');
    ok(!-f $store_lock, 'Point 6 (#4): --dry-run never created .store.lock (no write was attempted)');

    # #3: with --remove-sources added (the only path that runs git
    # preconditions at all), a fresh git-tracked vault's .git/index must be
    # byte-identical after --dry-run --remove-sources -- no implicit
    # `git diff`-triggered stat-refresh write.
    SKIP: {
        skip 'Point 6 (#3): git is not available on this host', 2 unless $HAVE_GIT;

        my $HOME2 = fresh_home();
        my $VAULT2 = vault_dir_for($HOME2);
        build_fixture_vault($VAULT2);
        git_init_vault($VAULT2);
        my $index_path = "$VAULT2/.git/index";
        ok(-f $index_path, 'Point 6 (#3) fixture: .git/index exists after the initial commit');
        my $index_before = slurp_raw($index_path);

        my $r2 = run_migrate(home => $HOME2, args => ['--dry-run', '--remove-sources']);
        is($r2->{rc}, 0, 'Point 6 (#3): --dry-run --remove-sources exits 0') or diag("stderr: $r2->{err}");
        is(slurp_raw($index_path), $index_before,
            'Point 6 (#3): .git/index is byte-identical after --dry-run --remove-sources (no implicit stat-refresh write)');
    }
}

# =============================================================================
# Point 5 (review minor #2) -- a signal-killed git precondition check must
# be treated as a failure, never as success ($? >> 8 == 0 whenever git
# dies by signal, since the exit-status byte is meaningless in that case).
# A fake `git` on PATH that kills itself is used to make this
# deterministic; probed first, because a signal death is only visible as
# such through Perl's $? on a host/perl build where WIFSIGNALED-style
# reporting actually survives a list-form spawn -- if the probe itself
# cannot show a signal death, the real assertion is SKIPPED with a reason
# rather than asserted against a mechanism this host cannot demonstrate.
# =============================================================================
SKIP: {
    skip 'Point 5: git is not available on this host', 1 unless $HAVE_GIT;

    my $FAKEBIN = tempdir(CLEANUP => 1);
    my $fake_git = "$FAKEBIN/git";
    open(my $fh, '>', $fake_git) or die "fixture: cannot write $fake_git: $!";
    print {$fh} "#!/usr/bin/env perl\nkill('KILL', \$\$);\nexit 1;\n";
    close $fh;
    chmod(0755, $fake_git);

    # Probe: does a self-KILLed perl child, spawned in list form, show up
    # as a non-zero LOW byte of $? (the WIFSIGNALED convention) rather than
    # a plain 0/1 exit code, on this host/perl?
    my $probe_rc = system('perl', $fake_git);
    my $probe_status = $?;
    my $probe_is_signal = ($probe_status & 127) != 0;

    skip 'Point 5: a self-KILLed child does not present as a signal death ($? & 127) on this host/perl -- '
       . 'not testable here', 1
        unless $probe_is_signal;

    my $HOME = fresh_home();
    my $VAULT = vault_dir_for($HOME);
    build_fixture_vault($VAULT);
    git_init_vault($VAULT);

    local $ENV{PATH} = "$FAKEBIN" . ($^O =~ /MSWin32/i ? ';' : ':') . $ENV{PATH};
    my $r = run_migrate(home => $HOME, args => ['--remove-sources']);
    isnt($r->{rc}, 0, 'Point 5: --remove-sources with a signal-killed git precondition check does not exit 0')
        or diag("stdout: $r->{out}\nstderr: $r->{err}");
    ok(!-d todo_store_dir($HOME), 'Point 5: no target record is created when the git precondition check dies by signal');
    ok(-f "$VAULT/todos/alpha-live.md", 'Point 5: no source is removed when the git precondition check dies by signal');
}

done_testing();
