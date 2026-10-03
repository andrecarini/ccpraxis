#!/usr/bin/env perl
# platform: any
# Immutable oracle for almanac-migrate-memories.pl (blueprint almanac-records,
# package 12-migrate-memories), the install hook plugins/almanac/ccpraxis-install.pl,
# and the two tracked CLAUDE.md text edits. Derived ONLY from
# specs/12-migrate-memories-spec.md's acceptance criteria (§4, AC-1..AC-23) --
# neither almanac-migrate-memories.pl nor plugins/almanac/ccpraxis-install.pl
# exists yet at the time this file is written, so every assertion below that
# spawns one of them is expected to fail for exactly that reason (a failed
# spawn / missing file), never for a fixture defect of this file's own making.
#
# ISOLATION (DC's "ISO", Decision 26): every fixture is SYNTHETIC. Every home,
# root and registry used here is a fresh File::Temp tempdir reached only
# through --home/--map (or the HOME/USERPROFILE/ALMANAC_HOME env triple a
# fresh subprocess inherits). This file never reads, copies or embeds the
# operator's real memories, transcripts, real paths or real user name. The two
# tracked-file ACs (AC-22) read the REPO's own CLAUDE.md / global-config/
# CLAUDE.md as text (never the installed ~/.claude/CLAUDE.md) -- exactly the
# files the implementer is allowed to edit. AC-19 is the tripwire: it hashes
# real, operator-owned paths ONLY to prove they are unchanged, and never
# opens/creates/writes any of them.
#
# SPAWNING: every child process is fork()+exec(LIST), STDOUT/STDERR reopened
# onto File::Temp files in the CHILD only -- never a shell string (no argv
# built by quoting and joining), never an in-memory scalar reopen. This is the
# house pattern already used by almanac-decision-crud.t / almanac-migrate-
# todos.t. AC-19's helper additionally asserts every --home passed to ANY
# spawn in this file (migrate script, note.pl, the install hook) lies under a
# File::Temp root, so a bug in this file's own fixture code cannot silently
# reach outside the sandbox.
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
use POSIX ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $MIGRATE_PL  = "$S/almanac-migrate-memories.pl";
my $NOTE_PL     = "$S/almanac-note.pl";
(my $PLUGIN_DIR = "$Bin/../..") =~ s{\\}{/}g;
my $HOOK_PL     = "$PLUGIN_DIR/ccpraxis-install.pl";
(my $REPO_DIR = "$Bin/../../../..") =~ s{\\}{/}g;
my $REPO_CLAUDE_MD   = "$REPO_DIR/CLAUDE.md";
my $GLOBAL_CLAUDE_MD = "$REPO_DIR/global-config/CLAUDE.md";

# =============================================================================
# AC-19 tripwire, taken BEFORE any fixture work below touches anything, so a
# later bug in this file cannot retroactively "fix" what it measures.
# =============================================================================
sub _real_home {
    return $ENV{ALMANAC_HOME} // $ENV{HOME} // $ENV{USERPROFILE};
}
sub sha256_of_path {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return Digest::SHA::sha256_hex(defined $bytes ? $bytes : '');
}
my $REAL_HOME              = _real_home();
my $REAL_INSTALLED_CLAUDE  = defined($REAL_HOME) ? "$REAL_HOME/.claude/CLAUDE.md" : undef;
my $REAL_NOTES_INDEX       = defined($REAL_HOME) ? "$REAL_HOME/.claude/almanac-notes.md" : undef;
my $TRIPWIRE_BEFORE = {
    repo_claude_md   => sha256_of_path($REPO_CLAUDE_MD),
    global_claude_md => sha256_of_path($GLOBAL_CLAUDE_MD),
    installed_claude_md_sha    => sha256_of_path($REAL_INSTALLED_CLAUDE),
    installed_claude_md_exists => (defined($REAL_INSTALLED_CLAUDE) && -e $REAL_INSTALLED_CLAUDE) ? 1 : 0,
    notes_index_sha    => sha256_of_path($REAL_NOTES_INDEX),
    notes_index_exists => (defined($REAL_NOTES_INDEX) && -e $REAL_NOTES_INDEX) ? 1 : 0,
};
sub _repo_note_md_count {
    my $dir = "$REPO_DIR/.ccpraxis-local-data/almanac/note";
    return -1 unless -d $dir;
    opendir(my $dh, $dir) or return -1;
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return scalar(@f);
}
my $TRIPWIRE_NOTE_COUNT_BEFORE = _repo_note_md_count();

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

sub sha256_of { return sha256_of_path($_[0]) }

# _canon_for_contains / path_contains -- a case-insensitive, slash-normalized
# "does this path lie under this root" test, per the almanac-migrate-todos.t
# precedent (File::Temp's tempdir() answers in either the MSYS "/tmp/..." or
# drive "/c/..." form for the SAME directory on this host).
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
sub path_under {
    my ($hay, $needle) = @_;
    return 0 unless defined $hay && defined $needle;
    my $a = _canon_for_contains($hay);
    my $b = _canon_for_contains($needle);
    return 0 unless defined $a && defined $b;
    return index($a, $b) >= 0;
}

# AC-19's spawn tripwire: every --home value handed to fork/exec in this file
# must resolve under a File::Temp root. Registered by every fresh_home() call
# below; asserted by every run_* helper before it forks.
my %KNOWN_TEMP_HOMES;
sub _register_temp_root {
    my ($p) = @_;
    $KNOWN_TEMP_HOMES{ _canon_for_contains($p) } = 1;
}
sub _assert_home_is_sandboxed {
    my ($home, $label) = @_;
    return unless defined $home;
    my $c = _canon_for_contains($home);
    my $ok = 0;
    for my $root (keys %KNOWN_TEMP_HOMES) {
        $ok = 1, last if index($c, $root) >= 0 || index($root, $c) >= 0;
    }
    ok($ok, "AC-19 spawn tripwire: --home for '$label' ($home) lies under a File::Temp root")
        or diag("home '$home' is not a registered temp root -- refusing to spawn against it");
    return $ok;
}

# fresh_home($leaf) -> $home -- a brand-new tempdir with a non-ASCII leaf
# ("Andr\x{e9}-home" by default, per house convention), .claude/ pre-created.
my $HOME_SEQ = 0;
sub fresh_home {
    my ($leaf) = @_;
    my $base = tempdir(CLEANUP => 1);
    $base =~ s{\\}{/}g;
    $leaf = "Andr\x{e9}-home-" . (++$HOME_SEQ) unless defined $leaf;
    my $home = "$base/$leaf";
    mkdir($home) or die "fixture: cannot mkdir $home: $!";
    make_path("$home/.claude") or die "fixture: cannot mkdir $home/.claude: $!";
    _register_temp_root($home);
    return $home;
}

# fresh_root($leaf) -> $root -- a brand-new project root tempdir, never under
# any $home's .claude/claude-code-vault (S1's "vault is never walked" rule).
my $ROOT_SEQ = 0;
sub fresh_root {
    my ($leaf) = @_;
    my $base = tempdir(CLEANUP => 1);
    $base =~ s{\\}{/}g;
    $leaf = "root-" . (++$ROOT_SEQ) unless defined $leaf;
    my $root = "$base/$leaf";
    mkdir($root) or die "fixture: cannot mkdir $root: $!";
    _register_temp_root($root);
    return $root;
}

sub vault_dir_for { my ($home) = @_; return norm_path($home) . '/.claude/claude-code-vault' }

# enc($root) -- transcribed verbatim from spec §2.2.1 / vault-sync.pl:1559.
# $root here is already a decoded Perl character string (our own fixture
# paths never leave that platform), so no cp1252 fallback is exercised.
sub enc {
    my ($root) = @_;
    my $c = $root;
    $c =~ s{\A/([A-Za-z])(?=/|\z)}{uc($1) . ':'}e;
    $c =~ s/[^A-Za-z0-9]/-/g;
    return $c;
}

sub registry_path { my ($home) = @_; return vault_dir_for($home) . '/.registry-local.json' }

# write_registry($home, %slug_to_root) -- {projects:{slug:{path:root}}}, per
# S1's live-file shape.
sub write_registry {
    my ($home, %slugs) = @_;
    my $dir = vault_dir_for($home);
    make_path($dir) unless -d $dir;
    my %projects;
    for my $slug (keys %slugs) {
        $projects{$slug} = { path => $slugs{$slug} };
    }
    my $json = JSON::PP->new->utf8->canonical->encode({ projects => \%projects });
    open(my $fh, '>:raw', registry_path($home)) or die "fixture: cannot write registry: $!";
    print {$fh} $json;
    close $fh;
}

sub write_malformed_registry {
    my ($home) = @_;
    my $dir = vault_dir_for($home);
    make_path($dir) unless -d $dir;
    open(my $fh, '>:raw', registry_path($home)) or die "fixture: cannot write registry: $!";
    print {$fh} "{ not json at all ]]]";
    close $fh;
}

# write_file($path, $bytes, %opt{mtime}) -- raw bytes, optional utime.
sub write_file {
    my ($path, $bytes, %opt) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]+\z}{};
    make_path($dir) unless -d $dir;
    open(my $fh, '>:raw', $path) or die "fixture: cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
    if (exists $opt{mtime}) { utime($opt{mtime}, $opt{mtime}, $path) or die "fixture: utime $path: $!" }
    return $path;
}

sub write_frontmatter_md {
    my ($path, $pairs, $body, %opt) = @_;
    my $text = "---\n";
    $text .= "$_->[0]: $_->[1]\n" for @$pairs;
    $text .= "---\n";
    $text .= $body if defined $body;
    return write_file($path, Encode::encode('UTF-8', $text), %opt);
}

sub read_all_lines {
    my ($path) = @_;
    open(my $fh, '<', $path) or return ();
    my @l = <$fh>;
    close $fh;
    return @l;
}

sub basename_of { my ($p) = @_; (my $b = $p) =~ s{.*/}{}; return $b }

# --- discovery-path helpers (spec §2.2) ---
sub s1_dir  { my ($home, $enc) = @_; return norm_path($home) . "/.claude/projects/$enc/memory" }
sub s2_dir  { my ($home)       = @_; return norm_path($home) . "/.claude/memory" }
sub s3_dir  { my ($root, $enc) = @_; return norm_path($root) . "/.ccpraxis-local-data/claude-home/projects/$enc/memory" }
sub s4_dir  { my ($root)       = @_; return norm_path($root) . "/.ccpraxis-local-data/claude-home/memory" }

# --- key prefixes (spec §2.4) ---
sub s1_key { my ($enc, $name) = @_; return "host/projects/$enc/memory/$name" }
sub s2_key { my ($name)       = @_; return "host/memory/$name" }
sub s3_key { my ($enc, $name) = @_; return "sandbox/projects/$enc/memory/$name" }
sub s4_key { my ($name)       = @_; return "sandbox/memory/$name" }

# ---------------------------------------------------------------------------
# spawning -- fork()+exec(LIST), never a shell string, never an in-memory
# scalar reopen. Per-call $ENV{HOME,USERPROFILE,ALMANAC_HOME} are localized
# around the fork so the child (and only the child) inherits them.
# ---------------------------------------------------------------------------
sub _fork_capture {
    my (@argv) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $pid = fork();
    die "fixture: fork() failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $outpath) or POSIX::_exit(126);
        open(STDERR, '>', $errpath) or POSIX::_exit(126);
        exec($^X, @argv) or POSIX::_exit(127);
    }
    waitpid($pid, 0);
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

# run_migrate($verb, %opt) -> {rc,out,err,raw_out}
#   opt: home (required unless home_flag given), maps (arrayref of "ENC=ROOT"),
#        json (bool), extra (arrayref of extra flags/args), home_flag
#        (overrides the LITERAL --home value, used only by the empty-string
#        refusal test -- the env triple still points at a safe fresh root).
sub run_migrate {
    my ($verb, %opt) = @_;
    my $home = $opt{home};
    my $home_flag = exists $opt{home_flag} ? $opt{home_flag} : $home;
    _assert_home_is_sandboxed($home, "migrate $verb") if defined $home;
    my @argv = ($MIGRATE_PL, $verb);
    push @argv, '--home', $home_flag if defined $home_flag;
    for my $m (@{ $opt{maps} || [] }) { push @argv, '--map', $m }
    push @argv, '--json' if $opt{json};
    push @argv, @{ $opt{extra} || [] };

    local $ENV{HOME}         = $home;
    local $ENV{USERPROFILE}  = $home;
    local $ENV{ALMANAC_HOME} = $home;
    delete local $ENV{ALMANAC_SURFACE};
    return _fork_capture(@argv);
}

# run_note($scope_flags, %opt) -- almanac-note.pl, for fixture seeding and
# independent verification (never for driving the migration itself).
sub run_note {
    my (@args) = @_;
    my %by_flag;
    for (my $i = 0; $i < @args; $i++) {
        if ($args[$i] eq '--home' && defined $args[$i+1]) { $by_flag{home} = $args[$i+1] }
    }
    _assert_home_is_sandboxed($by_flag{home}, 'note.pl') if defined $by_flag{home};
    return _fork_capture($NOTE_PL, @args);
}

sub run_hook {
    my (@args) = @_;
    my %by_flag;
    for (my $i = 0; $i < @args; $i++) {
        if ($args[$i] eq '--home' && defined $args[$i+1]) { $by_flag{home} = $args[$i+1] }
    }
    _assert_home_is_sandboxed($by_flag{home}, 'install hook') if defined $by_flag{home};
    return _fork_capture($HOOK_PL, @args);
}

# decode_json_or_undef($raw_bytes) -> decoded structure | undef
#
# Takes UNDECODED bytes (a child's raw_out, never its decoded 'out' text) --
# JSON::PP's ->utf8 mode itself performs the UTF-8 decode, so handing it text
# that PerlIO's ':encoding(UTF-8)' layer already decoded double-decodes any
# non-ASCII byte and dies "malformed UTF-8" (measured against unmodified
# almanac-note.pl's correct UTF-8 JSON output).
sub decode_json_or_undef {
    my ($raw_bytes) = @_;
    my $decoded = eval { JSON::PP->new->utf8->decode($raw_bytes) };
    return $decoded;
}

# field_line($text, $key) -> value | undef -- an unindented "key: value" line.
sub field_line {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\Q$key\E: (.*)$/m;
    return undef;
}

# field2($text, $key) -- the STDERR almanac-error machine block's two-space
# indented "  key: value" lines.
sub field2 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}
sub err_kind   { return field2($_[0], 'kind') }
sub err_detail { return field2($_[0], 'detail') }

# list_json($opt) -> arrayref|undef -- almanac-note.pl list --json for one
# store, used to verify AC-1..AC-3, AC-11 independently of the migration
# script's own report.
sub list_json_global {
    my ($home) = @_;
    my $r = run_note('list', '--json', '--global', '--home', $home);
    return (decode_json_or_undef($r->{raw_out}), $r);
}
sub list_json_project {
    my ($root) = @_;
    my $r = run_note('list', '--json', '--root', $root);
    return (decode_json_or_undef($r->{raw_out}), $r);
}

sub note_by_migrated_from {
    my ($list, $key) = @_;
    return () unless ref($list) eq 'ARRAY';
    return grep { defined($_->{migrated_from}) && $_->{migrated_from} eq $key } @$list;
}

sub anchor_for_global { my ($home) = @_; return vault_dir_for($home) }
sub anchor_for_project { my ($root) = @_; return norm_path($root) }

sub target_abs {
    my ($anchor, $target) = @_;
    return "$anchor/$target";
}

# snapshot_tree($dir) -> {relpath => sha256}, excluding *.lock / *.lock.holder
# (spec B1's own exclusion).
sub snapshot_tree {
    my ($dir) = @_;
    my %out;
    return \%out unless -d $dir;
    my @stack = ($dir);
    while (@stack) {
        my $d = pop @stack;
        opendir(my $dh, $d) or next;
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir $dh;
        for my $e (@entries) {
            my $p = "$d/$e";
            if (-d $p) { push @stack, $p; next }
            next if $e =~ /\.lock(?:\.holder)?\z/;
            (my $rel = $p) =~ s{\A\Q$dir\E/?}{};
            $out{$rel} = sha256_of($p);
        }
    }
    return \%out;
}

# =============================================================================
# module-shape rules (§2.0, AC-18/AC-23), by grep -- run whether or not the
# files exist yet, so a compile-breaking edit is still reported precisely.
# =============================================================================
{
    ok(-f $MIGRATE_PL, 'almanac-migrate-memories.pl exists at plugins/almanac/scripts/almanac-migrate-memories.pl')
        or diag('the script is not present yet -- every spawn-based assertion below is expected '
              . 'to fail for exactly that reason, not any other.');

    if (-f $MIGRATE_PL) {
        my @lines = read_all_lines($MIGRATE_PL);
        my $text  = join('', @lines);
        my $caller_line;
        for my $i (0 .. $#lines) {
            $caller_line = $i + 1 if !defined($caller_line) && $lines[$i] =~ /unless\s*\(\s*caller\s*\)/;
        }
        ok(defined $caller_line, 'AC-18: the file contains an `unless (caller)` main guard line');

        my (@exit_hits, @destructive_hits, @msys_hits, @bad_import_hits);
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            next if $line =~ /^\s*#/;
            my $lineno = $i + 1;
            push @exit_hits, "$MIGRATE_PL:$lineno: $line"
                if ($line =~ /\bexit\s*\(/ || $line =~ /\bexit\s+\d/)
                && (!defined($caller_line) || $lineno < $caller_line);
            push @destructive_hits, "$MIGRATE_PL:$lineno: $line"
                if $line =~ /\b(?:unlink|rmdir|remove_tree|rename)\s*\(/;
            push @msys_hits, "$MIGRATE_PL:$lineno: $line" if $line =~ /MSYS2_ARG_CONV_EXCL/;
        }
        my %ALLOWED_MODULE = map { $_ => 1 } (
            qw(strict warnings File::Basename File::Spec File::Temp JSON::PP Encode),
            'Almanac::Store', 'Almanac::Record', 'Almanac::ClaudeMdBlock',
        );
        while ($text =~ /^\s*use\s+([A-Za-z0-9_:]+)/mg) {
            my $mod = $1;
            push @bad_import_hits, $mod unless $ALLOWED_MODULE{$mod};
        }
        unless (ok(@exit_hits == 0, 'AC-18: the file never calls `exit` before its `unless (caller)` guard')) {
            diag($_) for @exit_hits;
        }
        unless (ok(@destructive_hits == 0, 'AC-18: no unlink/rmdir/remove_tree/rename literal appears anywhere')) {
            diag($_) for @destructive_hits;
        }
        unless (ok(@msys_hits == 0, 'AC-18: the file never sets MSYS2_ARG_CONV_EXCL')) {
            diag($_) for @msys_hits;
        }
        unless (ok(@bad_import_hits == 0, 'AC-18: every `use` import is within the §2.0 allowlist')) {
            diag("unexpected import: $_") for @bad_import_hits;
        }
        like($text, qr/our\s+\$VERSION\s*=\s*'1\.0'\s*;/, 'AC-18: our $VERSION = \'1.0\'; is present');

        my ($rc_compile) = system($^X, '-c', '-I', "$S", $MIGRATE_PL) >> 8;
        # perl -c writes to STDERR; we only need the exit code here.
        is($rc_compile, 0, 'AC-18: perl -c passes with only -I plugins/almanac/scripts');
    } else {
        fail("AC-18: $_") for (
            'the file contains an `unless (caller)` main guard line',
            'the file never calls `exit` before its `unless (caller)` guard',
            'no unlink/rmdir/remove_tree/rename literal appears anywhere',
            'the file never sets MSYS2_ARG_CONV_EXCL',
            'every `use` import is within the §2.0 allowlist',
            'our $VERSION = \'1.0\'; is present',
            'perl -c passes with only -I plugins/almanac/scripts',
        );
    }
}

{
    ok(-f $HOOK_PL, 'AC-23 precondition: plugins/almanac/ccpraxis-install.pl exists')
        or diag('the hook is not present yet -- every AC-23 spawn-based assertion below is '
              . 'expected to fail for exactly that reason.');
    if (-f $HOOK_PL) {
        my @lines = read_all_lines($HOOK_PL);
        is($lines[1], "# ccpraxis-install.pl \x{2014} almanac plugin install hook: ensures ~/.claude/almanac-notes.md exists.\n",
            'AC-23: line 2 matches the §2.8 text exactly (the line install.pl prints)')
            if 0; # em-dash spelling is host/editor dependent; checked loosely below instead.
        like($lines[1] // '', qr/^#\s*ccpraxis-install\.pl\s*.\s*almanac plugin install hook: ensures ~\/\.claude\/almanac-notes\.md exists\.\s*$/,
            'AC-23: line 2 matches the §2.8 text (loosely, allowing for the dash glyph)');

        my $text = join('', @lines);
        unlike($text, qr/\bunlink\s*\(/, 'AC-23: the hook contains no unlink(');
        unlike($text, qr/\brename\s*\(/, 'AC-23: the hook contains no rename(');
        unlike($text, qr/CLAUDE\.md/, 'AC-23: the hook never mentions/opens a path ending CLAUDE.md');

        my $rc_compile = system($^X, '-c', $HOOK_PL) >> 8;
        is($rc_compile, 0, 'AC-23: perl -c passes for the install hook');
    } else {
        fail("AC-23: $_") for (
            'line 2 matches the §2.8 text (loosely, allowing for the dash glyph)',
            'the hook contains no unlink(',
            'the hook contains no rename(',
            'the hook never mentions/opens a path ending CLAUDE.md',
            'perl -c passes for the install hook',
        );
    }
}

# =============================================================================
# AC-16 -- argv grammar refusals (§2.1). Cheap: every case gets its own fresh
# home so no case can taint another.
# =============================================================================
{
    my @cases = (
        { label => 'missing verb',            verb => undef,        args => [],                     detail => 'missing_verb' },
        { label => 'unknown verb',             verb => 'frobnicate', args => [],                     detail => 'unknown_verb' },
        { label => 'extra positional (plan)',  verb => 'plan',       args => ['bogus'],              detail => 'extra_positional' },
        { label => 'unknown flag (plan)',      verb => 'plan',       args => ['--wat'],              detail => 'unknown_flag' },
        { label => 'unknown flag (render-index)', verb => 'render-index', args => ['--json'],        detail => 'unknown_flag' },
        { label => 'bad --map, no =',          verb => 'plan',       args => ['--map', 'nosign'],    detail => 'bad_map' },
        { label => 'bad --map, bad enc chars', verb => 'plan',       args => ['--map', 'a/b=/x'],    detail => 'bad_map' },
        { label => 'bad --map, empty ROOT',    verb => 'plan',       args => ['--map', 'enc1='],     detail => 'bad_map' },
    );
    for my $c (@cases) {
        my $HOME = fresh_home();
        my @extra = @{ $c->{args} };
        my $r;
        if (defined $c->{verb}) { $r = run_migrate($c->{verb}, home => $HOME, extra => \@extra) }
        else                    { $r = _fork_capture($MIGRATE_PL, '--home', $HOME) }
        is($r->{rc}, 2, "AC-16 ($c->{label}): exits 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is($r->{out}, '', "AC-16 ($c->{label}): STDOUT is empty");
        is(err_kind($r->{err}), 'usage', "AC-16 ($c->{label}): kind: usage");
        is(err_detail($r->{err}), $c->{detail}, "AC-16 ($c->{label}): detail: $c->{detail}");
    }

    # bare --home / --map with no value, and an explicitly empty --home.
    for my $c (
        { label => 'bare --home',  args => ['--home'] },
        { label => 'bare --map',   args => ['--map'] },
    ) {
        my $r = _fork_capture($MIGRATE_PL, 'plan', @{ $c->{args} });
        is($r->{rc}, 2, "AC-16 ($c->{label}): exits 2") or diag("stderr: $r->{err}");
        is(err_detail($r->{err}), 'missing_flag_value', "AC-16 ($c->{label}): detail: missing_flag_value");
    }
    {
        my $HOME = fresh_home();
        my $r = run_migrate('plan', home => $HOME, home_flag => '');
        is($r->{rc}, 2, "AC-16 (--home ''): exits 2") or diag("stderr: $r->{err}");
        is(err_detail($r->{err}), 'missing_flag_value', "AC-16 (--home ''): detail: missing_flag_value");
    }

    # per-verb allowlist: plan/run allow home,map,json; render-index allows
    # only home.
    {
        my $HOME = fresh_home();
        my $r = run_migrate('run', home => $HOME, extra => ['--bogus-flag']);
        is($r->{rc}, 2, 'AC-16 (unknown flag on run): exits 2');
        is(err_detail($r->{err}), 'unknown_flag', 'AC-16 (unknown flag on run): detail: unknown_flag');
    }
}

# =============================================================================
# AC-1, AC-2, AC-3, AC-4, AC-5, AC-11, AC-13, AC-17, AC-20 -- the core fresh
# migration, across all four source kinds (S1 registry-mapped, S2 global, S3,
# S4), non-ASCII root/title included by construction, over ONE shared fixture.
# =============================================================================
{
    my $HOME = fresh_home();
    my $R1   = fresh_root('proj-one');           # mapped via registry, S1 + S3 + S4 live here
    my $R2   = fresh_root("caf\x{e9}-root");      # AC-20's non-ASCII root, S1-only via --map
    write_registry($HOME, 'proj-one' => $R1);    # R2 is deliberately UNregistered here

    my $enc1 = enc(norm_path($R1));
    my $enc2 = enc(norm_path($R2));

    # S1 (registry-mapped) -- one MEMORY.md index + one real record.
    my $S1_1 = s1_dir($HOME, $enc1);
    write_frontmatter_md("$S1_1/feedback.md",
        [ ['type', 'feedback'] ], "# Feedback title\n\nBody text one.\n",
        mtime => 1_700_000_000);
    write_file("$S1_1/MEMORY.md",
        Encode::encode('UTF-8', "# Index\n\n- [Feedback Title](feedback.md)\n"));
    # x.tmp -- skipped, never read (AC-9).
    write_file("$S1_1/x.tmp", "not markdown\n");

    # S2 (global).
    my $S2 = s2_dir($HOME);
    write_frontmatter_md("$S2/global-note.md",
        [ ['name', "Caf\x{e9} Global Title"] ], "Global body.\n",
        mtime => 1_700_000_100);
    write_file("$S2/MEMORY.md", Encode::encode('UTF-8', "# Index\n"));

    # S3 (sandbox, per-root) -- one project-under-project memory dir.
    my $S3_1 = s3_dir($R1, 'sandbox-enc-a');
    write_frontmatter_md("$S3_1/sandboxed.md",
        [ ['metadata', ''], ["  type", 'design'] ], "Sandbox record body.\n",
        mtime => 1_700_000_200);

    # S4 (sandbox, per-root, no <enc> level).
    my $S4_1 = s4_dir($R1);
    write_frontmatter_md("$S4_1/global-sandbox.md",
        [], "Sandbox global-scope body.\n", mtime => 1_700_000_300);

    # AC-20: a NON-ASCII root, reached only via --map (unregistered).
    my $S1_2 = s1_dir($HOME, $enc2);
    write_frontmatter_md("$S1_2/accented.md",
        [ ['name', "Titre avec \x{e9}"] ], "Accented body \x{e9}.\n",
        mtime => 1_700_000_400);

    my $r_plan = run_migrate('plan', home => $HOME, maps => ["$enc2=$R2"], json => 1);
    is($r_plan->{rc}, 0, 'AC-1/AC-11/AC-20 fixture: plan --json exits 0') or diag("stdout: $r_plan->{out}\nstderr: $r_plan->{err}");
    my $plan_json = decode_json_or_undef($r_plan->{raw_out});
    ok(ref($plan_json) eq 'HASH' && ref($plan_json->{entries}) eq 'ARRAY',
        'AC-17: plan --json decodes to {entries:[...], summary:{...}}');
    if (ref($plan_json) eq 'HASH') {
        my $sum = $plan_json->{summary} || {};
        my @entries = @{ $plan_json->{entries} };
        my $records_reported = scalar(grep { ($_->{status} // '') eq 'would_create' } @entries);
        is($sum->{records}, $records_reported, 'AC-17: summary.records agrees with the entries reported would_create');
        ok(defined($sum->{indexes}) && $sum->{indexes} >= 2, 'AC-17: summary.indexes counts at least the two MEMORY.md files');
        is($sum->{would_create}, $sum->{records}, 'AC-17 (plan): summary.would_create equals summary.records on a fresh tree');
    }

    # AC-1 (B1 half): plan is read-only.
    my $before_snap = snapshot_tree(vault_dir_for($HOME));
    my $r_run = run_migrate('run', home => $HOME, maps => ["$enc2=$R2"], json => 1);
    is($r_run->{rc}, 0, 'AC-1: run exits 0') or diag("stdout: $r_run->{out}\nstderr: $r_run->{err}");
    my $run_json = decode_json_or_undef($r_run->{raw_out});
    ok(ref($run_json) eq 'HASH', 'AC-17 (run): run --json decodes');
    if (ref($run_json) eq 'HASH') {
        is($run_json->{summary}{failed}, 0, 'AC-17 (run): summary.failed is 0 on a clean fresh run');
        is($run_json->{summary}{created}, $run_json->{summary}{records}, 'AC-17 (run): summary.created equals summary.records');
    }

    # AC-1/AC-2/AC-3: verify each of the four kinds independently via
    # almanac-note.pl, never via the migration script's own report.
    my ($glist) = list_json_global($HOME);
    ok(ref($glist) eq 'ARRAY', 'AC-1: global list --json decodes after run');
    my ($plist1) = list_json_project($R1);
    ok(ref($plist1) eq 'ARRAY', 'AC-1: project list --json decodes for R1 after run');

    my %check = (
        s1 => { key => s1_key($enc1, 'feedback.md'),      list => $plist1, anchor => anchor_for_project($R1),
                title => 'Feedback Title', tags => 'memory,feedback', mtime => 1_700_000_000, src => "$S1_1/feedback.md" },
        s2 => { key => s2_key('global-note.md'),          list => $glist,  anchor => anchor_for_global($HOME),
                title => "Caf\x{e9} Global Title", tags => 'memory', mtime => 1_700_000_100, src => "$S2/global-note.md" },
        s3 => { key => s3_key('sandbox-enc-a', 'sandboxed.md'), list => $plist1, anchor => anchor_for_project($R1),
                title => 'sandboxed', tags => 'memory,design', mtime => 1_700_000_200, src => "$S3_1/sandboxed.md" },
        s4 => { key => s4_key('global-sandbox.md'),       list => $plist1, anchor => anchor_for_project($R1),
                title => 'global-sandbox', tags => 'memory', mtime => 1_700_000_300, src => "$S4_1/global-sandbox.md" },
    );
    for my $k (sort keys %check) {
        my $c = $check{$k};
        my @matches = note_by_migrated_from($c->{list}, $c->{key});
        is(scalar(@matches), 1, "AC-1 ($k): exactly one note carries migrated_from == '$c->{key}'")
            or diag('list: ' . JSON::PP->new->canonical->encode($c->{list} || []));
        next unless @matches == 1;
        my $note = $matches[0];
        is($note->{audience}, 'internal', "AC-1 ($k): audience is internal");
        my $target_path = target_abs($c->{anchor}, $note->{target});
        ok(-f $target_path, "AC-2 ($k): <anchor>/<target> is a regular file")
            or diag("expected: $target_path");
        is(slurp_raw($target_path), slurp_raw($c->{src}), "AC-2 ($k): target bytes are byte-identical to the source");
        is($note->{migrated_from}, $c->{key}, "AC-3 ($k): migrated_from equals the §2.4 key");
        is($note->{tags}, $c->{tags}, "AC-3 ($k): tags is '$c->{tags}'");
        my $expect_created = POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($c->{mtime}));
        is($note->{created}, $expect_created, "AC-3 ($k): created equals the source mtime, ISO Z");
        is($note->{title}, $c->{title}, "AC-5 ($k): title resolves via the §2.5 chain");
    }

    # AC-4: MEMORY.md never becomes a note, and note count == record count.
    my @all_migrated_keys = map { $_->{key} } values %check;
    for my $home_list (($glist, $plist1)) {
        for my $n (@$home_list) {
            unlike($n->{migrated_from} // '', qr/MEMORY\.md\z/, 'AC-4: no note has a MEMORY.md migrated_from key');
        }
    }
    ok(scalar(@$plist1) >= 3, 'AC-4: the project store holds a note for each of its non-index records (>= 3: s1,s3,s4)');

    # AC-20: the accented root's record migrated too, and enc() collapsed the
    # accent to exactly one dash; no mojibake anywhere in the raw output.
    my ($plist2) = list_json_project($R2);
    my @acc = note_by_migrated_from($plist2, s1_key($enc2, 'accented.md'));
    is(scalar(@acc), 1, 'AC-20: the accented-root record migrated into R2');
    if (@acc) {
        is($acc[0]{title}, "Titre avec \x{e9}", 'AC-20: the accented title is preserved exactly');
    }
    unlike($enc2, qr/[^A-Za-z0-9-]/, 'AC-20: enc() of the accented root is pure [A-Za-z0-9-]');
    unlike($r_run->{raw_out}, qr/\xC3\x83/, 'AC-20: no mojibake (Ã) byte sequence appears in raw STDOUT');

    # =========================================================================
    # AC-6, AC-7 -- idempotent re-run and re-plan (B3).
    # =========================================================================
    {
        my $global_notes_snap = snapshot_tree(vault_dir_for($HOME));
        my $project_notes_snap = snapshot_tree(norm_path($R1) . '/.ccpraxis-local-data');

        my $r2 = run_migrate('run', home => $HOME, maps => ["$enc2=$R2"], json => 1);
        is($r2->{rc}, 0, 'AC-6: a second run exits 0') or diag("stderr: $r2->{err}");
        my $j2 = decode_json_or_undef($r2->{raw_out});
        if (ref($j2) eq 'HASH') {
            ok((!grep { $_->{status} ne 'already' } @{ $j2->{entries} || [] }),
                'AC-6: every entry reports status: already on the second run');
        }

        is_deeply(snapshot_tree(vault_dir_for($HOME)), $global_notes_snap,
            'AC-6: the global notes/store snapshot is unchanged after the second run');
        is_deeply(snapshot_tree(norm_path($R1) . '/.ccpraxis-local-data'), $project_notes_snap,
            'AC-6: the R1 project notes/store snapshot is unchanged after the second run');

        my $r_replan = run_migrate('plan', home => $HOME, maps => ["$enc2=$R2"], json => 1);
        is($r_replan->{rc}, 0, 'AC-7: plan after a run exits 0');
        my $jp = decode_json_or_undef($r_replan->{raw_out});
        if (ref($jp) eq 'HASH') {
            ok((!grep { $_->{status} eq 'would_create' } @{ $jp->{entries} || [] }),
                'AC-7: plan after a run reports no would_create entries -- everything is already');
        }
    }

    # =========================================================================
    # AC-13 (B9) -- source bytes and mtimes are unchanged after plan/run/run.
    # =========================================================================
    for my $c (values %check) {
        ok(-f $c->{src}, "AC-13: source '$c->{src}' still exists");
        my @st = stat($c->{src});
        is($st[9], $c->{mtime}, "AC-13: source '$c->{src}' mtime is unchanged")
            if @st;
    }
}

# =============================================================================
# AC-8, AC-9 -- unreadable / unexpected_entry, and skipped non-markdown; no
# almanac/notes dir appears anywhere, even with a readable a.md sorting first.
# =============================================================================
{
    my $HOME = fresh_home();
    my $R = fresh_root();
    write_registry($HOME, 'r' => $R);
    my $enc = enc(norm_path($R));
    my $dir = s1_dir($HOME, $enc);

    write_frontmatter_md("$dir/a.md", [], "readable, sorts first\n", mtime => 1_700_000_000);
    mkdir("$dir/bad.md") or die "fixture: mkdir bad.md: $!";   # directory named *.md -> unreadable

    for my $verb (qw(plan run)) {
        my $r = run_migrate($verb, home => $HOME, maps => ["$enc=$R"]);
        is($r->{rc}, 2, "AC-8 ($verb): a directory named *.md exits 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is($r->{out}, '', "AC-8 ($verb): STDOUT is empty");
        is(err_kind($r->{err}), 'refused', "AC-8 ($verb): kind: refused");
        is(err_detail($r->{err}), 'unreadable', "AC-8 ($verb): detail: unreadable");
        ok(!-d (norm_path($R) . '/.ccpraxis-local-data/almanac'), "AC-8 ($verb): no almanac/ dir was created under R");
        ok(!-d (norm_path($R) . '/.ccpraxis-local-data/notes'), "AC-8 ($verb): no notes/ dir was created under R");
    }
}
{
    my $HOME = fresh_home();
    my $R = fresh_root();
    write_registry($HOME, 'r' => $R);
    my $enc = enc(norm_path($R));
    my $dir = s1_dir($HOME, $enc);
    make_path($dir) unless -d $dir;

    mkdir("$dir/subdir") or die "fixture: mkdir subdir: $!"; # directory, not *.md -> unexpected_entry
    write_file("$dir/x.tmp", "skip me\n");                    # skipped, never read
    write_frontmatter_md("$dir/ok.md", [], "fine\n", mtime => 1_700_000_000);

    my $r_run = run_migrate('run', home => $HOME, maps => ["$enc=$R"]);
    is($r_run->{rc}, 2, 'AC-9: a plain subdirectory exits 2') or diag("stdout: $r_run->{out}\nstderr: $r_run->{err}");
    is(err_kind($r_run->{err}), 'refused', 'AC-9: kind: refused');
    is(err_detail($r_run->{err}), 'unexpected_entry', 'AC-9: detail: unexpected_entry');
    ok(!-d (norm_path($R) . '/.ccpraxis-local-data/almanac'), 'AC-9: nothing was written');

    # remove the offending subdir and re-check that x.tmp alone is reported
    # skipped/not_markdown and the run exits 0.
    rmdir("$dir/subdir") or die "fixture: rmdir subdir: $!";
    my $r2 = run_migrate('plan', home => $HOME, maps => ["$enc=$R"], json => 1);
    is($r2->{rc}, 0, 'AC-9: plan exits 0 once the stray subdir is gone') or diag("stderr: $r2->{err}");
    my $j2 = decode_json_or_undef($r2->{raw_out});
    if (ref($j2) eq 'HASH') {
        my ($tmp_entry) = grep { ($_->{path} // '') =~ /x\.tmp\z/ } @{ $j2->{entries} || [] };
        ok(defined $tmp_entry, 'AC-9: an entry for x.tmp is reported');
        is($tmp_entry->{status}, 'skipped', 'AC-9: x.tmp status: skipped') if $tmp_entry;
        is($tmp_entry->{reason}, 'not_markdown', 'AC-9: x.tmp reason: not_markdown') if $tmp_entry;
    }
}

# =============================================================================
# AC-10 -- S1 mapping precedence, unmapped, ambiguous, and a malformed
# registry.
# =============================================================================
{
    my $HOME = fresh_home();
    my $R = fresh_root();
    my $enc = enc(norm_path($R));
    my $dir = s1_dir($HOME, $enc);
    write_frontmatter_md("$dir/note.md", [], "body\n", mtime => 1_700_000_000);

    # (a) unmapped -- no registry entry and no --map.
    my $r_unmapped = run_migrate('plan', home => $HOME);
    is($r_unmapped->{rc}, 2, 'AC-10 (unmapped): exits 2') or diag("stderr: $r_unmapped->{err}");
    is(err_detail($r_unmapped->{err}), 'unmapped_memory_dir', 'AC-10 (unmapped): detail: unmapped_memory_dir');

    # (b) --map resolves it, landing the record in R.
    my $r_mapped = run_migrate('run', home => $HOME, maps => ["$enc=$R"]);
    is($r_mapped->{rc}, 0, 'AC-10 (--map): exits 0') or diag("stdout: $r_mapped->{out}\nstderr: $r_mapped->{err}");
    my ($plist) = list_json_project($R);
    is(scalar(note_by_migrated_from($plist, s1_key($enc, 'note.md'))), 1, 'AC-10 (--map): the record landed in R via --map');
}
{
    # (c) ambiguous: two DIFFERENT registered roots share the same enc().
    # enc() maps EVERY non-alphanumeric character to '-' with no collapsing,
    # so two sibling directories under the SAME parent, differing only in
    # one character that is itself non-alphanumeric on both sides (here '_'
    # vs '-'), are two genuinely distinct real directories whose enc() is
    # nonetheless byte-identical -- a deterministic collision, not a random
    # tempdir-naming coincidence.
    my $parent = tempdir(CLEANUP => 1);
    $parent =~ s{\\}{/}g;
    my $R_a = "$parent/amb_root";
    my $R_b = "$parent/amb-root";
    mkdir($R_a) or die "fixture: mkdir $R_a: $!";
    mkdir($R_b) or die "fixture: mkdir $R_b: $!";
    _register_temp_root($R_a);
    _register_temp_root($R_b);
    my $enc_a = enc(norm_path($R_a));
    my $enc_b = enc(norm_path($R_b));
    is($enc_a, $enc_b, 'AC-10 (ambiguous_mapping) fixture: the two roots really do share one enc() value')
        or diag("enc_a=$enc_a enc_b=$enc_b");

    my $HOME = fresh_home();
    write_frontmatter_md(s1_dir($HOME, $enc_a) . '/note.md', [], "body\n", mtime => 1_700_000_000);
    write_registry($HOME, 'r1' => $R_a, 'r2' => $R_b);

    my $r_amb = run_migrate('plan', home => $HOME);
    is($r_amb->{rc}, 2, 'AC-10 (ambiguous_mapping): two different roots sharing enc() exits 2')
        or diag("stderr: $r_amb->{err}");
    is(err_detail($r_amb->{err}), 'ambiguous_mapping', 'AC-10 (ambiguous_mapping): detail: ambiguous_mapping');
}
{
    # (d) malformed registry.
    my $HOME = fresh_home();
    my $R = fresh_root();
    my $enc = enc(norm_path($R));
    write_frontmatter_md(s1_dir($HOME, $enc) . '/note.md', [], "body\n", mtime => 1_700_000_000);
    write_malformed_registry($HOME);
    my $r = run_migrate('plan', home => $HOME);
    is($r->{rc}, 2, 'AC-10 (registry_unreadable): a malformed registry exits 2') or diag("stderr: $r->{err}");
    is(err_kind($r->{err}), 'refused', 'AC-10 (registry_unreadable): kind: refused');
    is(err_detail($r->{err}), 'registry_unreadable', 'AC-10 (registry_unreadable): detail: registry_unreadable');
}

# =============================================================================
# AC-7 (root_missing half) / AC-10 not-a-directory mapped root.
# =============================================================================
{
    my $HOME = fresh_home();
    my $missing_root = fresh_root('will-not-exist');
    rmdir($missing_root) or die "fixture: rmdir $missing_root: $!";
    my $enc = enc(norm_path(File::Spec->catdir($missing_root, '..')) . '/will-not-exist');
    # Build the S1 dir directly under $enc (mapped root need not exist for the
    # memory dir itself to be discoverable -- only the MAPPED root's
    # directory-ness is checked, per §2.2.1 step 3).
    write_frontmatter_md(s1_dir($HOME, 'anyenc') . '/note.md', [], "body\n", mtime => 1_700_000_000);
    my $r = run_migrate('plan', home => $HOME, maps => ["anyenc=$missing_root"]);
    is($r->{rc}, 2, 'AC-10 (root_missing): a --map target that is not a directory exits 2')
        or diag("stderr: $r->{err}");
    is(err_detail($r->{err}), 'root_missing', 'AC-10 (root_missing): detail: root_missing');
}

# =============================================================================
# AC-10 (missing registered root) -- a registry entry pointing at a
# non-existent directory is skipped with a warning; exit code unaffected.
# =============================================================================
{
    my $HOME = fresh_home();
    my $missing_root = fresh_root('missing-registered-root');
    rmdir($missing_root) or die "fixture: rmdir $missing_root: $!";
    write_registry($HOME, 'gone' => $missing_root);
    # Nothing else in the tree -- a plan against an otherwise-empty fixture,
    # solely to observe the warning + exit code.
    my $r = run_migrate('plan', home => $HOME);
    is($r->{rc}, 0, 'AC-10: a missing registered root does not fail the run') or diag("stderr: $r->{err}");
    like($r->{err}, qr/^migrate: root_missing: \Q$missing_root\E\s*$/m,
        'AC-10: STDERR carries exactly the "migrate: root_missing: <R>" warning line');
}

# =============================================================================
# AC-11, AC-4 (index report) -- S3/S4 already exercised above; here we check
# the MEMORY.md index report fields (entries, linked_missing, unindexed) and
# that vault mirrors never appear.
# =============================================================================
{
    my $HOME = fresh_home();
    my $R = fresh_root();
    write_registry($HOME, 'r' => $R);
    my $enc = enc(norm_path($R));
    my $dir = s1_dir($HOME, $enc);

    write_frontmatter_md("$dir/linked.md", [], "linked body\n", mtime => 1_700_000_000);
    write_frontmatter_md("$dir/unindexed.md", [], "unindexed body\n", mtime => 1_700_000_100);
    write_file("$dir/MEMORY.md", Encode::encode('UTF-8',
        "# Index\n\n- [Linked Title](linked.md)\n- [Ghost](ghost.md)\n"));

    # AC-7/B7: a vault mirror and a `_host-memory/` plant sitting right next
    # to the vault dir this file never walks.
    my $vault_plant = vault_dir_for($HOME) . '/projects/plant/files/_host-memory/plant.md';
    write_frontmatter_md($vault_plant, [], "must never be read\n", mtime => 1_700_000_200);
    my $vault_memory_plant = vault_dir_for($HOME) . '/almanac/memory/plant2.md';
    write_frontmatter_md($vault_memory_plant, [], "must never be read either\n", mtime => 1_700_000_300);

    my $r = run_migrate('plan', home => $HOME, maps => ["$enc=$R"], json => 1);
    is($r->{rc}, 0, 'AC-4/AC-11 fixture: plan --json exits 0') or diag("stderr: $r->{err}");
    my $j = decode_json_or_undef($r->{raw_out});
    ok(ref($j) eq 'HASH', 'AC-4: plan --json decodes');
    if (ref($j) eq 'HASH') {
        my ($idx) = grep { ($_->{path} // '') =~ /MEMORY\.md\z/ && ($_->{path} // '') =~ /\Q$enc\E/ } @{ $j->{entries} || [] };
        ok(defined $idx, 'AC-4: an index entry for this dir\'s MEMORY.md is reported');
        if ($idx) {
            is($idx->{entries}, 2, 'AC-4: index entries: 2 (two link lines)');
            is($idx->{linked_missing}, 1, 'AC-4: index linked_missing: 1 (ghost.md has no record)');
            is($idx->{unindexed}, 1, 'AC-4: index unindexed: 1 (unindexed.md has no link)');
        }
        for my $e (@{ $j->{entries} || [] }) {
            unlike($e->{path} // '', qr{_host-memory}, 'AC-7 (B7): no entry ever comes from _host-memory/');
            unlike($e->{path} // '', qr{claude-code-vault}, 'AC-7 (B7): no entry ever comes from the vault directly');
        }
    }
}

# =============================================================================
# AC-12 -- diverged, dangling, duplicate_migration, each exit 2 with the full
# report, and the target is never recreated / nothing else is written.
# =============================================================================
{
    my $HOME = fresh_home();
    my $R = fresh_root();
    write_registry($HOME, 'r' => $R);
    my $enc = enc(norm_path($R));
    my $dir = s1_dir($HOME, $enc);
    write_frontmatter_md("$dir/rec.md", [], "original body\n", mtime => 1_700_000_000);

    my $key = s1_key($enc, 'rec.md');

    # (a) diverged -- pre-seed a note with the right migrated_from but
    # DIFFERENT content at its target (in the PROJECT store, since this
    # key's scope is R, not global).
    my $rseed = run_note('create', '--title', 'Diverged pre-seed',
        '--set', "migrated_from=$key", '--content', 'DIFFERENT bytes here', '--root', $R);
    is($rseed->{rc}, 0, 'AC-12 (diverged) fixture: pre-seeding a note with migrated_from succeeds')
        or diag("stderr: $rseed->{err}");

    my $r = run_migrate('run', home => $HOME, maps => ["$enc=$R"]);
    is($r->{rc}, 2, 'AC-12 (diverged): exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    unlike($r->{out} // '', qr/\A\z/, 'AC-12 (diverged): STDOUT is NOT empty -- the full report is printed even on failure');
    like($r->{out}, qr/\bdiverged\b/, 'AC-12 (diverged): the report mentions "diverged"');
}
{
    # (b) dangling -- migrated_from matches, but the target file is missing.
    my $HOME = fresh_home();
    my $R = fresh_root();
    write_registry($HOME, 'r' => $R);
    my $enc = enc(norm_path($R));
    write_frontmatter_md(s1_dir($HOME, $enc) . '/rec.md', [], "body\n", mtime => 1_700_000_000);
    my $key = s1_key($enc, 'rec.md');

    my $rseed = run_note('create', '--title', 'Dangling pre-seed', '--target', '.ccpraxis-local-data/notes/dangling.md',
        '--set', "migrated_from=$key", '--root', $R);
    is($rseed->{rc}, 0, 'AC-12 (dangling) fixture: pre-seeding a pointer-only note succeeds')
        or diag("stderr: $rseed->{err}");
    ok(!-f (norm_path($R) . '/.ccpraxis-local-data/notes/dangling.md'), 'AC-12 (dangling) fixture: the target file does not exist');

    my $r = run_migrate('run', home => $HOME, maps => ["$enc=$R"]);
    is($r->{rc}, 2, 'AC-12 (dangling): exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    like($r->{out}, qr/\bdangling\b/, 'AC-12 (dangling): the report mentions "dangling"');
    ok(!-f (norm_path($R) . '/.ccpraxis-local-data/notes/dangling.md'), 'AC-12 (dangling): the target is NOT recreated');
}
{
    # (c) duplicate_migration -- two notes share the same migrated_from.
    my $HOME = fresh_home();
    my $R = fresh_root();
    write_registry($HOME, 'r' => $R);
    my $enc = enc(norm_path($R));
    write_frontmatter_md(s1_dir($HOME, $enc) . '/rec.md', [], "body\n", mtime => 1_700_000_000);
    my $key = s1_key($enc, 'rec.md');

    for my $i (1, 2) {
        my $rseed = run_note('create', '--title', "Dup pre-seed $i",
            '--set', "migrated_from=$key", '--content', "dup body $i", '--root', $R);
        is($rseed->{rc}, 0, "AC-12 (duplicate_migration) fixture: pre-seed $i succeeds") or diag("stderr: $rseed->{err}");
    }
    my $before_snap = snapshot_tree(norm_path($R) . '/.ccpraxis-local-data');
    my $r = run_migrate('run', home => $HOME, maps => ["$enc=$R"]);
    is($r->{rc}, 2, 'AC-12 (duplicate_migration): exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    like($r->{out}, qr/\bduplicate_migration\b/, 'AC-12 (duplicate_migration): the report mentions "duplicate_migration"');
    is_deeply(snapshot_tree(norm_path($R) . '/.ccpraxis-local-data'), $before_snap,
        'AC-12 (duplicate_migration): nothing was written');
}

# =============================================================================
# AC-14 -- render-index (B10): fresh, no-op re-run, emptying, zero-notes
# create, project-note exclusion, malformed-note exclusion.
# =============================================================================
{
    my $HOME = fresh_home();
    my $T = "$HOME/.claude/almanac-notes.md";
    ok(!-e $T, 'AC-14 fixture: the index target does not exist yet');

    # Zero notes, absent file -> created with zero bytes.
    my $r0 = run_migrate('render-index', home => $HOME);
    is($r0->{rc}, 0, 'AC-14 (zero notes, absent): render-index exits 0') or diag("stderr: $r0->{err}");
    ok(-f $T, 'AC-14 (zero notes, absent): the index file now exists');
    is(-s $T, 0, 'AC-14 (zero notes, absent): the index file is zero bytes');
    is(field_line($r0->{out}, 'notes'), '0', 'AC-14 (zero notes, absent): notes: 0');

    # One valid global note, one project note (must be excluded), one
    # malformed (missing title) global note (must be excluded, reported).
    my $rg = run_note('create', '--title', 'Good Global Note', '--covers', 'good-global-covers', '--global', '--home', $HOME);
    is($rg->{rc}, 0, 'AC-14 fixture: a good global note is created') or diag("stderr: $rg->{err}");

    my $R = fresh_root();
    my $rp = run_note('create', '--title', 'A Project Note', '--root', $R);
    is($rp->{rc}, 0, 'AC-14 fixture: a project note is created (must never appear in the index)')
        or diag("stderr: $rp->{err}");

    my $rbad = run_note('create', '--title', 'placeholder', '--covers', 'placeholder-covers', '--global', '--home', $HOME);
    is($rbad->{rc}, 0, 'AC-14 fixture: a to-be-broken global note is created') or diag("stderr: $rbad->{err}");
    my $bad_id = field_line($rbad->{out}, 'id');
    # Exercise the spec's own "missing_title" exclusion by stripping the
    # title field entirely (§2.6 step 4: excluded when title is empty).
    my $redit = run_note('edit', $bad_id, '--global', '--home', $HOME, '--unset', 'title');
    is($redit->{rc}, 0, 'AC-14 fixture: unsetting the malformed note\'s title succeeds')
        or diag("stderr: $redit->{err}");

    my $r1 = run_migrate('render-index', home => $HOME);
    is($r1->{rc}, 0, 'AC-14 (mixed notes): render-index exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(field_line($r1->{out}, 'notes'), '1', 'AC-14 (mixed notes): notes: 1 (only the good global note is kept)');
    # 09-notes-fixes §2.4: every global create/edit already auto-renders the
    # index as it commits, so by the time this EXPLICIT render-index call
    # runs (after the last global mutation above), the index is already
    # current -- changed: no (was changed: yes before auto-render existed).
    is(field_line($r1->{out}, 'changed'), 'no', 'AC-14 (mixed notes): changed: no (auto-render already made the index current)');
    my $excluded_line = field_line($r1->{out}, 'excluded') // '';
    like($excluded_line, qr/\Q$bad_id\E=missing_title/, 'AC-14 (mixed notes): the malformed note appears under excluded: as missing_title');
    my $bytes1 = slurp_raw($T);
    ok(defined($bytes1) && length($bytes1) > 0, 'AC-14 (mixed notes): the index is now non-empty');
    unlike($bytes1, qr/A Project Note/, 'AC-14 (mixed notes): a project-scope note never appears in the rendered index');

    my $Almanac_ClaudeMdBlock_path = "$S/Almanac/ClaudeMdBlock.pm";
    ok(-f $Almanac_ClaudeMdBlock_path, 'AC-14 precondition: Almanac::ClaudeMdBlock.pm exists to inspect the render');

    # A second render-index is a true no-op.
    my $mtime_before = (stat($T))[9];
    my $r2 = run_migrate('render-index', home => $HOME);
    is($r2->{rc}, 0, 'AC-14 (no-op re-run): exits 0') or diag("stderr: $r2->{err}");
    is(field_line($r2->{out}, 'changed'), 'no', 'AC-14 (no-op re-run): changed: no');
    is(slurp_raw($T), $bytes1, 'AC-14 (no-op re-run): bytes are unchanged');
    is((stat($T))[9], $mtime_before, 'AC-14 (no-op re-run): mtime is unchanged');

    # Delete the last global note -> zero bytes, changed: yes.
    my $good_id = field_line($rg->{out}, 'id');
    my $rdel = run_note('delete', $good_id, '--global', '--home', $HOME);
    is($rdel->{rc}, 0, 'AC-14 (emptying) fixture: the good global note is deleted') or diag("stderr: $rdel->{err}");
    my $r3 = run_migrate('render-index', home => $HOME);
    is($r3->{rc}, 0, 'AC-14 (emptying): render-index exits 0') or diag("stderr: $r3->{err}");
    is(-s $T, 0, 'AC-14 (emptying): the index is zero bytes again');
    # Same reasoning as above: the delete itself already auto-rendered the
    # (now-empty) index, so this explicit call is a no-op.
    is(field_line($r3->{out}, 'changed'), 'no', 'AC-14 (emptying): changed: no (auto-render already emptied the index)');
}

# =============================================================================
# AC-15 -- render-index refusals: foreign_content, hand_edited,
# claude_dir_missing; a fixture CLAUDE.md is byte-identical after every call;
# and the three disallowed flags.
# =============================================================================
{
    my $HOME = fresh_home();
    my $T = "$HOME/.claude/almanac-notes.md";
    write_file("$HOME/.claude/CLAUDE.md", "unrelated fixture content, never touched\n");
    my $claude_before = slurp_raw("$HOME/.claude/CLAUDE.md");

    # foreign_content: prose sits outside the block.
    write_file($T, "some hand-written prose that was never part of any block\n");
    my $r_foreign = run_migrate('render-index', home => $HOME);
    is($r_foreign->{rc}, 2, 'AC-15 (foreign_content): exits 2') or diag("stdout: $r_foreign->{out}\nstderr: $r_foreign->{err}");
    is(err_detail($r_foreign->{err}), 'foreign_content', 'AC-15 (foreign_content): detail: foreign_content');
    is(slurp_raw($T), "some hand-written prose that was never part of any block\n",
        'AC-15 (foreign_content): $T is byte-identical after the refusal');
    is(slurp_raw("$HOME/.claude/CLAUDE.md"), $claude_before, 'AC-15 (foreign_content): the fixture CLAUDE.md is byte-identical');
}
{
    my $HOME = fresh_home();
    my $T = "$HOME/.claude/almanac-notes.md";
    write_file("$HOME/.claude/CLAUDE.md", "unrelated fixture content, never touched\n");
    my $claude_before = slurp_raw("$HOME/.claude/CLAUDE.md");

    # Build a real block first, then hand-edit its payload.
    my $rg = run_note('create', '--title', 'Seed Note', '--covers', 'seed-note-covers', '--global', '--home', $HOME);
    is($rg->{rc}, 0, 'AC-15 (hand_edited) fixture: seed note created') or diag("stderr: $rg->{err}");
    my $r0 = run_migrate('render-index', home => $HOME);
    is($r0->{rc}, 0, 'AC-15 (hand_edited) fixture: initial render-index exits 0') or diag("stderr: $r0->{err}");
    my $bytes = slurp_raw($T);
    ok(defined($bytes) && length($bytes), 'AC-15 (hand_edited) fixture: the index is non-empty before the hand-edit');
    (my $edited = $bytes) =~ s/Seed Note/Seed Note EDITED BY HAND/;
    isnt($edited, $bytes, 'AC-15 (hand_edited) fixture: the hand-edit actually changed the bytes');
    write_file($T, $edited);

    my $r_hand = run_migrate('render-index', home => $HOME);
    is($r_hand->{rc}, 2, 'AC-15 (hand_edited): exits 2') or diag("stdout: $r_hand->{out}\nstderr: $r_hand->{err}");
    is(err_detail($r_hand->{err}), 'hand_edited', 'AC-15 (hand_edited): detail: hand_edited');
    is(slurp_raw($T), $edited, 'AC-15 (hand_edited): $T is byte-identical after the refusal');
    is(slurp_raw("$HOME/.claude/CLAUDE.md"), $claude_before, 'AC-15 (hand_edited): the fixture CLAUDE.md is byte-identical');
}
{
    my $base = tempdir(CLEANUP => 1);
    $base =~ s{\\}{/}g;
    my $HOME = "$base/no-dot-claude-home";
    mkdir($HOME) or die "fixture: mkdir $HOME: $!";
    _register_temp_root($HOME);
    ok(!-d "$HOME/.claude", 'AC-15 (claude_dir_missing) fixture: no .claude/ exists under this home');

    my $r = run_migrate('render-index', home => $HOME);
    is($r->{rc}, 2, 'AC-15 (claude_dir_missing): exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(err_detail($r->{err}), 'claude_dir_missing', 'AC-15 (claude_dir_missing): detail: claude_dir_missing');
    ok(!-e "$HOME/.claude", 'AC-15 (claude_dir_missing): nothing at all was created under this home');
}
{
    my $HOME = fresh_home();
    for my $bad (['--file', 'x'], ['--root', 'x'], ['--global']) {
        my $r = run_migrate('render-index', home => $HOME, extra => $bad);
        is($r->{rc}, 2, 'AC-15 (' . $bad->[0] . '): render-index rejects it') or diag("stderr: $r->{err}");
        is(err_detail($r->{err}), 'unknown_flag', 'AC-15 (' . $bad->[0] . '): detail: unknown_flag');
    }
}

# =============================================================================
# AC-21 note: the coordinator-side ledger/disk check is out of scope for this
# file (per spec §4, "AC-21 is checked by the coordinator from the ledger and
# from disk") -- recorded here only so the mapping table has an entry.
# =============================================================================
ok(1, 'AC-21: coordinator-only (ledger + real ~/.claude/almanac-notes.md) -- not testable from this synthetic-fixture file');

# =============================================================================
# AC-22 -- the exact tracked-file text edits (repo CLAUDE.md, global-config/
# CLAUDE.md). Reads the REPO's own two files -- never the installed
# ~/.claude/CLAUDE.md -- exactly the two files the implementer may edit.
# =============================================================================
{
    ok(-f $REPO_CLAUDE_MD, 'AC-22 precondition: the repo CLAUDE.md exists');
    ok(-f $GLOBAL_CLAUDE_MD, 'AC-22 precondition: global-config/CLAUDE.md exists');
    my $repo_text   = slurp_text($REPO_CLAUDE_MD);
    my $global_text = slurp_text($GLOBAL_CLAUDE_MD);

    if (defined $repo_text) {
        # Manual match (not like()) so a failure's diag never dumps the
        # whole (non-ASCII-bearing) file body through Test2's TAP formatter.
        my $ac22a_re = qr/A durable fact is an almanac note\s*\n\(`plugins\/almanac\/scripts\/almanac-note\.pl create`\), never a memory; existing memory files are\nmigrated by `plugins\/almanac\/scripts\/almanac-migrate-memories\.pl`\./;
        ok(($repo_text =~ $ac22a_re) ? 1 : 0,
            'AC-22: the repo CLAUDE.md carries the §2.7a replacement text byte-exact')
            or diag('the exact §2.7a paragraph was not found verbatim');
        ok(($repo_text !~ /<!--\s*BEGIN GENERATED/) ? 1 : 0, 'AC-22: the repo CLAUDE.md carries no "<!-- BEGIN GENERATED" line');
        ok(($repo_text !~ /<!--\s*END GENERATED/) ? 1 : 0, 'AC-22: the repo CLAUDE.md carries no "<!-- END GENERATED" line');
    } else {
        fail('AC-22: the repo CLAUDE.md carries the §2.7a replacement text byte-exact');
    }

    if (defined $global_text) {
        my @lines = split /\n/, $global_text;
        my @at_lines = grep { $_ eq '@~/.claude/almanac-notes.md' } @lines;
        is(scalar(@at_lines), 1, 'AC-22: exactly one line equal to "@~/.claude/almanac-notes.md" at column 0');
        my @any_at_line = grep { /^\@/ } @lines;
        is(scalar(@any_at_line), 1, 'AC-22: no other new "@" line appears at column 0');
        # Manual match (not like()) so a failure's diag never dumps the
        # whole (non-ASCII-bearing) file body through Test2's TAP formatter,
        # which otherwise emits a "Wide character in print" warning.
        ok(scalar(grep { $_ eq '## Durable facts go in almanac notes' } @lines),
            'AC-22: the new section heading is present')
            or diag('heading line not found among ' . scalar(@lines) . ' lines');
        ok(($global_text !~ /<!--\s*BEGIN GENERATED/) ? 1 : 0, 'AC-22: global-config/CLAUDE.md carries no "<!-- BEGIN GENERATED" line');
        ok(($global_text !~ /<!--\s*END GENERATED/) ? 1 : 0, 'AC-22: global-config/CLAUDE.md carries no "<!-- END GENERATED" line');

        # The import line must not sit inside a fenced code block. Track
        # fence state across the WHOLE file (```), the only fence marker in
        # active use in this repo's docs.
        my $in_fence = 0;
        my $import_in_fence = 0;
        for my $l (@lines) {
            $in_fence = !$in_fence if $l =~ /^```/;
            $import_in_fence = 1 if $l eq '@~/.claude/almanac-notes.md' && $in_fence;
        }
        ok(!$import_in_fence, 'AC-22: the import line is not inside a fenced code block');
    } else {
        fail('AC-22: exactly one line equal to "@~/.claude/almanac-notes.md" at column 0');
    }
}

# =============================================================================
# AC-25 (spec 09-notes-fixes, B25) -- a global memory with no `description`
# migrates with covers equal to its (sanitized) title, so the migration's
# own global creates are not refused by almanac-note.pl's new --covers
# requirement; a global memory whose `description` exceeds the 200-byte
# budget yields a failed entry (create_failed) and no note.
# =============================================================================
{
    my $HOME25 = fresh_home();
    my $S2_25 = s2_dir($HOME25);

    # No description at all -- fm->{name} supplies the title; covers must
    # fall back to that same (sanitized) title.
    write_frontmatter_md("$S2_25/no-description.md",
        [ ['name', 'No Description Memory'] ], "Body with no description.\n",
        mtime => 1_700_000_500);

    my $r = run_migrate('run', home => $HOME25, json => 1);
    is($r->{rc}, 0, 'AC-25 (no description): run exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    my $j = decode_json_or_undef($r->{raw_out});
    ok(ref($j) eq 'HASH', 'AC-25 (no description): run --json decodes') or diag("raw: $r->{raw_out}");
    if (ref($j) eq 'HASH') {
        is($j->{summary}{failed}, 0, 'AC-25 (no description): summary.failed is 0');
    }

    my ($glist25) = list_json_global($HOME25);
    ok(ref($glist25) eq 'ARRAY', 'AC-25 (no description): global list --json decodes');
    my @matches25 = note_by_migrated_from($glist25, s2_key('no-description.md'));
    is(scalar(@matches25), 1, 'AC-25 (no description): exactly one note carries the expected migrated_from');
    if (@matches25 == 1) {
        is($matches25[0]{title}, 'No Description Memory', 'AC-25 (no description): title resolves as usual');
        is($matches25[0]{covers}, 'No Description Memory', 'AC-25 (no description): covers falls back to the sanitized title');
    }

    # description over the 200-byte budget -> create_failed, no note.
    my $HOME25B = fresh_home();
    my $S2_25B = s2_dir($HOME25B);
    my $long_description = 'd' x 201;
    write_frontmatter_md("$S2_25B/over-budget.md",
        [ ['name', 'Over Budget Memory'], ['description', $long_description] ],
        "Body with an over-budget description.\n", mtime => 1_700_000_600);

    my $rb = run_migrate('run', home => $HOME25B, json => 1);
    is($rb->{rc}, 2, 'AC-25 (over-budget description): run exits 2') or diag("stdout: $rb->{out}\nstderr: $rb->{err}");
    my $jb = decode_json_or_undef($rb->{raw_out});
    if (ref($jb) eq 'HASH') {
        is($jb->{summary}{failed}, 1, 'AC-25 (over-budget description): summary.failed is 1');
        my ($entry) = grep { ($_->{key} // '') eq s2_key('over-budget.md') } @{ $jb->{entries} || [] };
        ok(ref($entry) eq 'HASH' && $entry->{status} eq 'create_failed',
            'AC-25 (over-budget description): the entry\'s status is create_failed')
            or diag('entries: ' . JSON::PP->new->canonical->encode($jb->{entries} || []));
    }
    my ($glist25b) = list_json_global($HOME25B);
    my @matches25b = note_by_migrated_from($glist25b, s2_key('over-budget.md'));
    is(scalar(@matches25b), 0, 'AC-25 (over-budget description): no note was created');
}

# =============================================================================
# AC-23 -- install hook behaviour, all five rows of §2.8 (B12).
# =============================================================================
{
    my $HOME = fresh_home();
    my $T = "$HOME/.claude/almanac-notes.md";

    my $r_plan = run_hook('plan', '--home', $HOME);
    is($r_plan->{rc}, 0, 'AC-23 (absent, plan): exits 0') or diag("stdout: $r_plan->{out}\nstderr: $r_plan->{err}");
    like($r_plan->{out}, qr/would create/, 'AC-23 (absent, plan): prints "would create"');
    ok(!-e $T, 'AC-23 (absent, plan): nothing is created');

    my $r_apply = run_hook('apply', '--home', $HOME);
    is($r_apply->{rc}, 0, 'AC-23 (absent, apply): exits 0') or diag("stdout: $r_apply->{out}\nstderr: $r_apply->{err}");
    ok(-f $T, 'AC-23 (absent, apply): the stub now exists');
    is(-s $T, 0, 'AC-23 (absent, apply): the stub is zero bytes');
    like($r_apply->{out}, qr/created empty stub/, 'AC-23 (absent, apply): prints "created empty stub"');

    my $r_apply2 = run_hook('apply', '--home', $HOME);
    is($r_apply2->{rc}, 0, 'AC-23 (present, apply again): exits 0') or diag("stderr: $r_apply2->{err}");
    like($r_apply2->{out}, qr/present/, 'AC-23 (present, apply again): prints "present"');
    is(-s $T, 0, 'AC-23 (present, apply again): the file is unchanged (still zero bytes)');
}
{
    my $HOME = fresh_home();
    my $T = "$HOME/.claude/almanac-notes.md";
    write_file($T, "pre-existing content that must never be touched\n");
    my $before = slurp_raw($T);
    my $r = run_hook('apply', '--home', $HOME);
    is($r->{rc}, 0, 'AC-23 (present with content, apply): exits 0') or diag("stderr: $r->{err}");
    is(slurp_raw($T), $before, 'AC-23 (present with content, apply): the file is byte-identical afterwards');
}
{
    my $base = tempdir(CLEANUP => 1);
    $base =~ s{\\}{/}g;
    my $HOME = "$base/no-dot-claude-for-hook";
    mkdir($HOME) or die "fixture: mkdir $HOME: $!";
    _register_temp_root($HOME);
    my $r = run_hook('apply', '--home', $HOME);
    is($r->{rc}, 0, 'AC-23 (no .claude, apply): exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    like($r->{out}, qr/skipped/, 'AC-23 (no .claude, apply): prints "skipped"');
    ok(!-e "$HOME/.claude", 'AC-23 (no .claude, apply): nothing is created');
}

# =============================================================================
# AC-19 -- the tripwire itself, checked AFTER every block above. Every real,
# operator-owned path this file is permitted to touch is a stat-only proof of
# non-change; none of it was opened for writing anywhere above.
# =============================================================================
{
    is(sha256_of_path($REPO_CLAUDE_MD), $TRIPWIRE_BEFORE->{repo_claude_md},
        'AC-19: the repo CLAUDE.md SHA-256 is unchanged by this test file')
        if defined $TRIPWIRE_BEFORE->{repo_claude_md};
    is(sha256_of_path($GLOBAL_CLAUDE_MD), $TRIPWIRE_BEFORE->{global_claude_md},
        'AC-19: global-config/CLAUDE.md SHA-256 is unchanged by this test file')
        if defined $TRIPWIRE_BEFORE->{global_claude_md};

    my $installed_exists_after = (defined($REAL_INSTALLED_CLAUDE) && -e $REAL_INSTALLED_CLAUDE) ? 1 : 0;
    is($installed_exists_after, $TRIPWIRE_BEFORE->{installed_claude_md_exists},
        'AC-19: the real ~/.claude/CLAUDE.md existence is unchanged');
    if ($TRIPWIRE_BEFORE->{installed_claude_md_exists}) {
        is(sha256_of_path($REAL_INSTALLED_CLAUDE), $TRIPWIRE_BEFORE->{installed_claude_md_sha},
            'AC-19: the real ~/.claude/CLAUDE.md SHA-256 is unchanged');
    }

    my $notes_exists_after = (defined($REAL_NOTES_INDEX) && -e $REAL_NOTES_INDEX) ? 1 : 0;
    is($notes_exists_after, $TRIPWIRE_BEFORE->{notes_index_exists},
        'AC-19: the real ~/.claude/almanac-notes.md existence is unchanged');
    if ($TRIPWIRE_BEFORE->{notes_index_exists}) {
        is(sha256_of_path($REAL_NOTES_INDEX), $TRIPWIRE_BEFORE->{notes_index_sha},
            'AC-19: the real ~/.claude/almanac-notes.md SHA-256 is unchanged');
    }

    is(_repo_note_md_count(), $TRIPWIRE_NOTE_COUNT_BEFORE,
        'AC-19: the count of *.md in the repo\'s own .ccpraxis-local-data/almanac/note/ is unchanged');
}

done_testing();
