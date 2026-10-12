#!/usr/bin/env perl
# platform: any
# Immutable oracle for the CRUD surface of almanac-note.pl (blueprint
# almanac-records, package 05-notes): create/list/show/edit/delete in
# project scope, the module's check_pointers() shape (DC3/DC4), the argv-
# grammar hardening baked in from the start (missing-flag-value fails
# closed, exists-based scope/conflict checks, per-verb unknown-flag
# rejection), body/target validation, audience enum validation, error
# shapes, and module-shape rules (MR). promote()'s three-phase journal
# atomicity, both-scope promote coverage and Decision-7 refusal live in the
# sibling almanac-note-promote.t. See specs/05-notes-spec.md.
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
use Scalar::Util qw(refaddr);

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $NOTE_PL = "$S/almanac-note.pl";

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
    # non-ASCII (the CLAUDE.md-documented Windows non-ASCII-path landmine,
    # fixed here from the start per the almanac-todo-*.t precedent).
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

# run_cli(@args) -> { rc, out, err }
sub run_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$NOTE_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}

# field0/field2/field4 -- column-0, two-space, four-space "key: value" lines.
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
sub field4 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{4}\Q$key\E:\s(\S+)$/m;
    return undef;
}
sub err_kind { return field2($_[0], 'kind') }

sub decode_json_or_undef {
    my ($text) = @_;
    # Force scalar context on the eval so a die (e.g. an empty/malformed
    # string) returns undef, never an empty LIST -- a `return eval {...}`
    # evaluated in the caller's list context collapses to () on die, which
    # silently drops a position from every caller's list assignment. This
    # is exactly the class of vacuous-pass bug this file's self-audit
    # exists to catch.
    my $decoded = eval { JSON::PP->new->decode($text) };
    return $decoded;
}

sub show_json {
    my ($id, @extra) = @_;
    my $r = run_cli('show', $id, '--json', @extra);
    return (decode_json_or_undef($r->{out}), $r);
}

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

# set_frontmatter_field / remove_frontmatter_field -- hand-tamper a record's
# on-disk frontmatter directly (bypassing the script's own reserved-field
# checks), used to build states the CLI itself refuses to construct (§5,
# AC-30's "no target field at all" / "audience: sideways").
sub set_frontmatter_field {
    my ($path, $field, $value) = @_;
    my $bytes = slurp_raw($path);
    return undef unless defined $bytes;
    my @lines = split /\n/, $bytes, -1;
    my @out;
    my $delim_count = 0;
    my $replaced = 0;
    for my $l (@lines) {
        if ($l =~ /\A---\s*\z/) {
            $delim_count++;
            if ($delim_count == 2 && !$replaced) {
                push @out, "$field: $value";
                $replaced = 1;
            }
            push @out, $l;
            next;
        }
        if ($delim_count == 1 && $l =~ /\A\Q$field\E:/) {
            push @out, "$field: $value";
            $replaced = 1;
            next;
        }
        push @out, $l;
    }
    open(my $fh, '>:raw', $path) or die "cannot rewrite $path: $!";
    print {$fh} join("\n", @out);
    close $fh;
    return 1;
}
sub remove_frontmatter_field {
    my ($path, $field) = @_;
    my $bytes = slurp_raw($path);
    return undef unless defined $bytes;
    my @lines = split /\n/, $bytes, -1;
    my @out;
    my $delim_count = 0;
    for my $l (@lines) {
        if ($l =~ /\A---\s*\z/) {
            $delim_count++;
            push @out, $l;
            next;
        }
        if ($delim_count == 1 && $l =~ /\A\Q$field\E:/) {
            next;
        }
        push @out, $l;
    }
    open(my $fh, '>:raw', $path) or die "cannot rewrite $path: $!";
    print {$fh} join("\n", @out);
    close $fh;
    return 1;
}

sub record_dir {
    my ($root_or_home, $scope) = @_;
    return $scope eq 'global'
        ? norm_path($root_or_home) . '/.claude/claude-code-vault/almanac/note'
        : norm_path($root_or_home) . '/.ccpraxis-local-data/almanac/note';
}
sub internal_dir {
    my ($root_or_home, $scope) = @_;
    return $scope eq 'global'
        ? norm_path($root_or_home) . '/.claude/claude-code-vault/notes'
        : norm_path($root_or_home) . '/.ccpraxis-local-data/notes';
}
sub list_md_files {
    # NB: `return ();` in SCALAR context yields undef, not 0 -- and every
    # caller of this sub uses `scalar(list_md_files(...))` against a
    # numeric expectation. Guard both early-return paths with `wantarray`
    # so a non-existent/unreadable directory counts as zero files, not an
    # undef that would make `is(scalar(...), 0, ...)` fail for the wrong
    # reason. Caught in self-audit before dispatch.
    my ($dir) = @_;
    return wantarray ? () : 0 unless -d $dir;
    opendir(my $dh, $dir) or return wantarray ? () : 0;
    my @f = grep { /\.md\z/ } readdir($dh);
    closedir $dh;
    return @f;
}

# extract_note_blocks -- list's default form, exactly the five keys of §2.8
# in fixed order, two-space indented.
sub extract_note_blocks {
    my ($text) = @_;
    my @out;
    while ($text =~ /^note:\s(\S+)\n {2}audience:\s(\S+)\n {2}target:\s(\S+)\n {2}covers:\s(\S+)\n {2}tags:\s(\S+)\n {2}title:\s(.*)$/mg) {
        push @out, { id => $1, audience => $2, target => $3, covers => $4, tags => $5, title => $6 };
    }
    return @out;
}

# extract_cp_notes -- check-pointers' default form per-note blocks: a
# two-space "note:" line followed by three four-space audience/target/
# status lines, in that order (§2.8).
sub extract_cp_notes {
    my ($text) = @_;
    my @out;
    while ($text =~ /^\s{2}note:\s(\S+)\n\s{4}audience:\s(\S+)\n\s{4}target:\s(\S+)\n\s{4}status:\s(\S+)$/mg) {
        push @out, { id => $1, audience => $2, target => $3, status => $4 };
    }
    return @out;
}

# ---------------------------------------------------------------------------
# live-store sanity (house convention, AC-50) -- before
# ---------------------------------------------------------------------------
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $LIVE_NOTE_STORE = "$REPO/.ccpraxis-local-data/almanac/note";
my $LIVE_NOTES_DIR  = "$REPO/.ccpraxis-local-data/notes";
sub count_md_in {
    my ($dir) = @_;
    return 0 unless -d $dir;
    opendir(my $dh, $dir) or return 0;
    my @f = grep { /\.md\z/ && -f "$dir/$_" } readdir($dh);
    closedir $dh;
    return scalar @f;
}
my $live_before       = count_md_in($LIVE_NOTE_STORE);
my $live_notes_before = count_md_in($LIVE_NOTES_DIR);
# Decision 120(c): the protective intent here is COUNT UNCHANGED and
# PRE-EXISTING FILES UNTOUCHED (checked below, AC-50) -- not that the real
# repo's gitignored note store holds any particular record, or holds
# ac2-target.md specifically. A fresh clone / a store emptied by an
# unrelated run must not turn this suite red for that reason alone. Whether
# ac2-target.md happens to be there is recorded (not asserted) so the AC-50
# "survives untouched" check below stays conditional on it actually having
# existed, rather than requiring its presence.
my $ac2_target_existed_before = -f "$LIVE_NOTE_STORE/ac2-target.md" ? 1 : 0;

ok(-f $NOTE_PL, 'almanac-note.pl exists at plugins/almanac/scripts/almanac-note.pl')
    or diag('almanac-note.pl is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

# =============================================================================
# MR -- module-shape rules by grep (§2.0), run whether or not the script
# loaded, so a compile-breaking edit is still reported precisely.
# =============================================================================
{
    if (-f $NOTE_PL) {
        my @lines = read_all_lines($NOTE_PL);
        my (@exit_hits, @writefile_hits, @unlink_hits, @alarm_hits, @srand_hits,
            @containerenv_hits, @dockerenv_hits, @surface_hits, @frontmatter_hits,
            @lock_bad_hits, @on_rename_hits);
        my $caller_line;
        for my $i (0 .. $#lines) {
            $caller_line = $i + 1 if !defined($caller_line) && $lines[$i] =~ /unless\s*\(\s*caller\s*\)/;
        }
        # AC-23: locate `sub _cmd_delete` and the next `sub ` after it, so the
        # single permitted `unlink` can be checked for location as well as
        # count (replaces AC-46's blanket ban, line 336 pre-rewrite).
        my ($delete_sub_line, $next_sub_after_delete);
        for my $i (0 .. $#lines) {
            if (!defined($delete_sub_line) && $lines[$i] =~ /^\s*sub\s+_cmd_delete\b/) {
                $delete_sub_line = $i + 1;
                next;
            }
            if (defined($delete_sub_line) && !defined($next_sub_after_delete) && $i + 1 > $delete_sub_line
                && $lines[$i] =~ /^\s*sub\s+/) {
                $next_sub_after_delete = $i + 1;
            }
        }
        for my $i (0 .. $#lines) {
            my $line = $lines[$i];
            next if $line =~ /^\s*#/;
            my $lineno = $i + 1;
            if ($line =~ /\bexit\s*\(/ || $line =~ /\bexit\s+\d/) {
                push @exit_hits, "$NOTE_PL:$lineno: $line";
            }
            push @writefile_hits,    "$NOTE_PL:$lineno: $line" if $line =~ /Almanac::Record::write_file/;
            push @unlink_hits,       "$NOTE_PL:$lineno: $line" if $line =~ /\bunlink\b/;
            push @alarm_hits,        "$NOTE_PL:$lineno: $line" if $line =~ /\balarm\s*\(/;
            push @srand_hits,        "$NOTE_PL:$lineno: $line" if $line =~ /\bsrand\s*\(/;
            push @containerenv_hits, "$NOTE_PL:$lineno: $line" if $line =~ m{/run/\.containerenv};
            push @dockerenv_hits,    "$NOTE_PL:$lineno: $line" if $line =~ m{/\.dockerenv};
            push @surface_hits,      "$NOTE_PL:$lineno: $line" if $line =~ /ALMANAC_SURFACE/;
            push @frontmatter_hits,  "$NOTE_PL:$lineno: $line" if $line =~ /\A\s*---\s*\z/ || $line =~ /m\{\^?---/ || $line =~ m{/\^---};
            push @lock_bad_hits,     "$NOTE_PL:$lineno: $line"
                if $line =~ /Almanac::Lock::acquire/ || $line =~ /->\s*release\b/ || $line =~ /->\s*suspend\b/
                || $line =~ /->\s*resume\b/ || $line =~ /\block_path_for\b/ || $line =~ /\bholder_path_for\b/;
            push @on_rename_hits,    "$NOTE_PL:$lineno: $line" if $line =~ /on_rename/;
        }

        my @exit_before_guard = grep { /^\Q$NOTE_PL\E:(\d+):/ && ($1 < ($caller_line // 0)) } @exit_hits;
        ok(defined $caller_line, 'MR: the file contains an `unless (caller)` main guard line')
            or diag('no `unless (caller)` found');
        unless (ok(@exit_before_guard == 0, 'MR/AC-46: no `exit` statement occurs before the `unless (caller)` line')) {
            diag($_) for @exit_before_guard;
        }
        unless (ok(@writefile_hits == 0, 'AC-46: the file never calls Almanac::Record::write_file')) { diag($_) for @writefile_hits }
        # AC-23 (replaces AC-46's "the file contains no unlink", line 336):
        # exactly one non-comment `unlink` call in the whole file, and it
        # must sit between `sub _cmd_delete` and the next `sub` after it.
        is(scalar(@unlink_hits), 1, 'AC-23: the file contains exactly one non-comment `unlink` call')
            or diag($_) for @unlink_hits;
        if (@unlink_hits == 1 && $unlink_hits[0] =~ /^\Q$NOTE_PL\E:(\d+):/) {
            my $hit_line = $1;
            ok(defined($delete_sub_line) && defined($next_sub_after_delete)
                    && $hit_line > $delete_sub_line && $hit_line < $next_sub_after_delete,
                'AC-23: the one `unlink` call lies between `sub _cmd_delete` and the next `sub` line')
                or diag("unlink at line $hit_line; _cmd_delete starts at "
                    . ($delete_sub_line // '(not found)') . ", next sub at " . ($next_sub_after_delete // '(not found)'));
        } else {
            fail('AC-23: the one `unlink` call lies between `sub _cmd_delete` and the next `sub` line');
        }
        unless (ok(@alarm_hits == 0, 'AC-46: the file contains no `alarm`')) { diag($_) for @alarm_hits }
        unless (ok(@srand_hits == 0, 'AC-46: the file contains no `srand`')) { diag($_) for @srand_hits }
        unless (ok(@frontmatter_hits == 0, 'AC-46/MR: the file contains no frontmatter/--- delimiter parsing')) { diag($_) for @frontmatter_hits }

        unless (ok(@containerenv_hits == 0, "AC-41: the file never mentions the literal '/run/.containerenv'")) { diag($_) for @containerenv_hits }
        unless (ok(@dockerenv_hits == 0, "AC-41: the file never mentions the literal '/.dockerenv'")) { diag($_) for @dockerenv_hits }
        unless (ok(@surface_hits == 0, "AC-41: the file never mentions the string 'ALMANAC_SURFACE'")) { diag($_) for @surface_hits }

        unless (ok(@lock_bad_hits == 0, 'AC-46: the only Almanac::Lock symbol named is rename_with_retry (no acquire/release/suspend/resume/lock_path_for/holder_path_for)')) {
            diag($_) for @lock_bad_hits;
        }
        unless (ok(@on_rename_hits == 0, 'MR/§2.6: no product path supplies rename_with_retry\'s on_rename seam')) {
            diag($_) for @on_rename_hits;
        }

        # AC-47: import allowlist -- exactly §2.0's core-Perl-plus-almanac set.
        my @uses = grep { /^\s*(use|require)\s+/ } @lines;
        my @allowed = (
            qr/^\s*use\s+strict\b/,            qr/^\s*use\s+warnings\b/,
            qr/^\s*use\s+File::Basename\b/,    qr/^\s*use\s+File::Path\b/,
            qr/^\s*use\s+JSON::PP\b/,          qr/^\s*use\s+Encode\b/,
            qr/^\s*use\s+Almanac::Store\b/,    qr/^\s*use\s+Almanac::Record\b/,
            qr/^\s*use\s+Almanac::Lock\b/, qr/^\s*use\s+Almanac::GlobalCounts\b/,
            # AC-26 (spec §2.6): the covers-budget and render-capture fixes
            # add exactly these two beyond the set above.
            qr/^\s*use\s+File::Temp\b/, qr/^\s*use\s+Almanac::ClaudeMdBlock\b/,
        );
        my @bad_imports = grep { my $l = $_; !grep { $l =~ $_ } @allowed } @uses;
        unless (ok(@bad_imports == 0, 'AC-47: the file imports only from the §2.0 allowlist')) {
            diag($_) for @bad_imports;
        }
        my @other_plugin = grep { /butler|BpResumption|BpContinuityLease|steward/ } @uses;
        ok(@other_plugin == 0, 'AC-47: the file never mentions another plugin');

        my @version_hits = grep { /our\s+\$VERSION\s*=\s*'1\.0'/ } @lines;
        ok(@version_hits >= 1, 'MR: the file declares our $VERSION = \'1.0\';');

        my @package_hits = grep { /^\s*package\s+Almanac::Note\s*;/ } @lines;
        ok(@package_hits >= 1, 'MR: the file declares `package Almanac::Note;`');
    } else {
        fail("MR: $_") for (
            'the file contains an `unless (caller)` main guard line',
            'no `exit` statement occurs before the `unless (caller)` line',
            'the file never calls Almanac::Record::write_file',
            'the file contains no `alarm`', 'the file contains no `srand`',
            'the file contains no frontmatter/--- delimiter parsing',
        );
        fail("AC-23: $_") for (
            'the file contains exactly one non-comment `unlink` call',
            'the one `unlink` call lies between `sub _cmd_delete` and the next `sub` line',
        );
        fail("AC-41: $_") for (
            "the file never mentions the literal '/run/.containerenv'",
            "the file never mentions the literal '/.dockerenv'",
            "the file never mentions the string 'ALMANAC_SURFACE'",
        );
        fail('AC-46: the only Almanac::Lock symbol named is rename_with_retry');
        fail('MR/§2.6: no product path supplies rename_with_retry\'s on_rename seam');
        fail('AC-47: the file imports only from the §2.0 allowlist');
        fail('AC-47: the file never mentions another plugin');
        fail('MR: the file declares our $VERSION = \'1.0\';');
        fail('MR: the file declares `package Almanac::Note;`');
    }
}

# =============================================================================
# AC-48 -- `checks:` perl -c with -I plugins/almanac/scripts, no other -I.
# =============================================================================
{
    my $cmd = qq{perl -I "$S" -c "$NOTE_PL" 2>&1};
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    is($rc, 0, 'AC-48: perl -c almanac-note.pl succeeds with -I plugins/almanac/scripts and no other -I')
        or diag("output: $out");
}

# =============================================================================
# AC-27 -- require/`do`-ing the file in a child process runs no main body
# (no STDOUT, no STDERR, no premature exit) and makes
# Almanac::Note::check_pointers defined.
# =============================================================================
{
    my $WORK27 = tempdir(CLEANUP => 1);
    $WORK27 =~ s{\\}{/}g;
    my $child = "$WORK27/ac27-child.pl";
    open(my $fh, '>', $child) or die "fixture: cannot write $child: $!";
    print {$fh} <<'AC27CHILD';
#!/usr/bin/env perl
use strict;
use warnings;
my ($note_pl) = @ARGV;
do $note_pl;
print "AC27-DO-ERR=" . (defined $@ && length $@ ? $@ : '(none)') . "\n" if $@;
print "AC27-SURVIVED\n";
print "AC27-CP-DEFINED=" . (defined &Almanac::Note::check_pointers ? 1 : 0) . "\n";
exit 0;
AC27CHILD
    close $fh;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    system(qq{perl "$child" "$NOTE_PL" > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    my $out = slurp_text($outpath) // '';
    my $err = slurp_text($errpath) // '';
    is($rc, 0, 'AC-27: a child process that `do`s almanac-note.pl and returns exits 0 (no premature exit inside the load)')
        or diag("stdout: $out\nstderr: $err");
    is($err, '', 'AC-27: loading the file in-process prints nothing to STDERR');
    like($out, qr/^AC27-SURVIVED$/m, 'AC-27: the child survives the `do` (no exit() during load)');
    like($out, qr/^AC27-CP-DEFINED=1$/m, 'AC-27: Almanac::Note::check_pointers is defined after loading');
    my @lines = grep { length } split /\n/, $out;
    my @unexpected = grep { !/^AC27-(SURVIVED|CP-DEFINED=|DO-ERR=)/ } @lines;
    ok(@unexpected == 0, 'AC-27: the load itself emits no STDOUT of its own')
        or diag('unexpected line(s): ' . join(' | ', @unexpected));
}

# do the file once for this process too, so check_pointers() can be called
# directly (it never dies/prints/exits per §2.7 clause 8).
do $NOTE_PL if -f $NOTE_PL;

# =============================================================================
# AC-1, AC-2 -- create writes exactly one record and one target file, exits
# 0, correct result block, and the on-disk frontmatter shape (no rank).
# =============================================================================
my $ROOT1 = tempdir(CLEANUP => 1);
$ROOT1 =~ s{\\}{/}g;
my $DIR1 = record_dir($ROOT1, 'project');
my $ID1;
{
    my $r = run_cli('create', '--title', 'First note', '--root', $ROOT1);
    is($r->{rc}, 0, 'AC-1: create --title exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(field0($r->{out}, 'scope'), 'project', 'AC-1: result block carries scope: project');
    is(field0($r->{out}, 'audience'), 'internal', 'AC-1: result block carries audience: internal');
    is(field0($r->{out}, 'changed'), 'yes', 'AC-1: result block carries changed: yes');
    $ID1 = field0($r->{out}, 'id');
    ok(defined $ID1 && length $ID1, 'AC-1: result block carries a non-empty id:');
    is(field0($r->{out}, 'target'), ".ccpraxis-local-data/notes/$ID1.md", 'AC-1: result block carries target: .ccpraxis-local-data/notes/<id>.md');

    my @files = list_md_files($DIR1);
    is(scalar(@files), 1, 'AC-1: exactly one record was written under <root>/.ccpraxis-local-data/almanac/note/');
    is($files[0], "$ID1.md", "AC-1: the record file's stem equals the result block's id") if @files;

    my $target_path = internal_dir($ROOT1, 'project') . "/$ID1.md";
    ok(-f $target_path, 'AC-1: exactly one target file was written under <root>/.ccpraxis-local-data/notes/');

    my $path = "$DIR1/$ID1.md";
    my ($keys, $kv) = read_frontmatter($path);
    ok((grep { $_ eq 'title' } @$keys) >= 1, 'AC-2: frontmatter contains title');
    ok((grep { $_ eq 'audience' } @$keys) >= 1, 'AC-2: frontmatter contains audience');
    ok((grep { $_ eq 'target' } @$keys) >= 1, 'AC-2: frontmatter contains target');
    ok((grep { $_ eq 'created' } @$keys) >= 1, 'AC-2: frontmatter contains created');
    ok((grep { $_ eq 'id' } @$keys) >= 1, 'AC-2: frontmatter contains the store\'s id');
    ok((grep { $_ eq 'writer' } @$keys) >= 1, 'AC-2: frontmatter contains the store\'s writer');
    ok(!(grep { $_ eq 'rank' } @$keys), 'AC-2/ruling-2: frontmatter contains NO rank key');
    like($kv->{created} // '', qr/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, 'AC-2: created matches the ISO-8601 UTC pattern');

    my ($j) = show_json($ID1, '--root', $ROOT1);
    ok(ref($j) eq 'HASH', 'AC-2: show --json decodes') or diag('not a hashref');
    is(ref($j) eq 'HASH' ? $j->{fields}{rank} : 'MISSING', undef, 'AC-2: show --json reports fields.rank as undef/absent')
        if ref($j) eq 'HASH';
    # spec: "show --json reports rank as null" -- assert the TOP-LEVEL rank
    # key (mirrored from §2.8's show --json grammar), decoded to Perl undef.
    if (ref($j) eq 'HASH') {
        ok(exists $j->{rank}, 'AC-2: show --json has a top-level rank key');
        is($j->{rank}, undef, 'AC-2: top-level rank decodes to JSON null');
    }
}

# =============================================================================
# AC-3 -- content bytes.
# =============================================================================
{
    my $ROOT3 = tempdir(CLEANUP => 1);
    $ROOT3 =~ s{\\}{/}g;
    my $r1 = run_cli('create', '--title', 'Has content', '--content', 'hello', '--root', $ROOT3);
    is($r1->{rc}, 0, 'AC-3: create --content hello exits 0') or diag("stderr: $r1->{err}");
    my $id1 = field0($r1->{out}, 'id');
    my $tf1 = internal_dir($ROOT3, 'project') . "/$id1.md";
    is(slurp_raw($tf1), 'hello', 'AC-3: the target file\'s bytes are exactly "hello"');

    my $r2 = run_cli('create', '--title', 'No content flag', '--root', $ROOT3);
    is($r2->{rc}, 0, 'AC-3: create with no content flag exits 0') or diag("stderr: $r2->{err}");
    my $id2 = field0($r2->{out}, 'id');
    my $tf2 = internal_dir($ROOT3, 'project') . "/$id2.md";
    is(slurp_raw($tf2), '', 'AC-3: with no content flag, the target file is zero bytes');

    my ($cfh, $contentfile) = tempfile();
    binmode($cfh, ':raw');
    print {$cfh} "binary\x00bytes\nhere";
    close $cfh;
    my $r3 = run_cli('create', '--title', 'From content-file', '--content-file', $contentfile, '--root', $ROOT3);
    is($r3->{rc}, 0, 'AC-3: create --content-file exits 0') or diag("stderr: $r3->{err}");
    my $id3 = field0($r3->{out}, 'id');
    my $tf3 = internal_dir($ROOT3, 'project') . "/$id3.md";
    is(slurp_raw($tf3), "binary\x00bytes\nhere", 'AC-3: create --content-file reproduces the file\'s bytes exactly');
}

# =============================================================================
# AC-4 -- external audience with an explicit target creates NO file under
# the target's directory.
# =============================================================================
{
    my $ROOT4 = tempdir(CLEANUP => 1);
    $ROOT4 =~ s{\\}{/}g;
    my $r = run_cli('create', '--title', 'External note', '--audience', 'external', '--target', 'docs/x.md', '--root', $ROOT4);
    is($r->{rc}, 0, 'AC-4: create --audience external --target docs/x.md exits 0') or diag("stderr: $r->{err}");
    is(field0($r->{out}, 'audience'), 'external', 'AC-4: result block carries audience: external');
    is(field0($r->{out}, 'target'), 'docs/x.md', 'AC-4: result block carries target: docs/x.md');
    ok(!-f (norm_path($ROOT4) . '/docs/x.md'), 'AC-4: no file is created under <root>/docs/');
}

# =============================================================================
# AC-5 -- ten distinct usage failures, each exits 2 with the named detail,
# leaving the note store empty. Matches B4-B9 literally.
# =============================================================================
{
    my $ROOT5 = tempdir(CLEANUP => 1);
    $ROOT5 =~ s{\\}{/}g;
    my @cases = (
        [ ['create', '--root', $ROOT5],                                                                       'missing_title',                     'no --title at all' ],
        [ ['create', '--root', $ROOT5, '--title'],                                                             'missing_flag_value',                'bare --title' ],
        [ ['create', '--title', 'T', '--audience', 'sideways', '--root', $ROOT5],                              'bad_audience',                       '--audience sideways' ],
        [ ['create', '--title', 'T', '--audience', 'external', '--root', $ROOT5],                              'missing_target',                     '--audience external with no target' ],
        [ ['create', '--title', 'T', '--target', '../x.md', '--root', $ROOT5],                                 'bad_target',                         '--target ../x.md' ],
        [ ['create', '--title', 'T', '--target', '/abs/x.md', '--root', $ROOT5],                               'bad_target',                         '--target /abs/x.md' ],
        [ ['create', '--title', 'T', '--target', 'docs/x', '--root', $ROOT5],                                  'bad_target',                         '--target docs/x (no .md)' ],
        [ ['create', '--title', 'T', '--target', 'notes/x.md', '--root', $ROOT5],                              'internal_target_outside_notes_dir', 'internal --target notes/x.md' ],
        [ ['create', '--title', 'T', '--audience', 'external', '--target', '.ccpraxis-local-data/notes/x.md', '--root', $ROOT5], 'external_target_unversioned', 'external --target under .ccpraxis-local-data/' ],
        [ ['create', '--title', 'T', '--target', '.ccpraxis-local-data/notes/mine.md', '--content', 'x', '--root', $ROOT5],       'content_refused',            '--target with --content' ],
    );
    for my $case (@cases) {
        my ($args, $detail, $label) = @$case;
        my $r = run_cli(@$args);
        is($r->{rc}, 2, "AC-5 [$label]: exits 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is(err_kind($r->{err}), 'usage', "AC-5 [$label]: ...with kind: usage");
        is(field2($r->{err}, 'detail'), $detail, "AC-5 [$label]: ...and detail: $detail");
        is($r->{out}, '', "AC-5 [$label]: STDOUT is empty");
    }
    my $DIR5 = record_dir($ROOT5, 'project');
    is(scalar(list_md_files($DIR5)), 0, 'AC-5: the note store contains no record after any of the ten refusals');
}

# =============================================================================
# AC-6 -- create --id <existing> dies exists, bytes unchanged; create --id
# 'a/b' dies bad_id.
# =============================================================================
{
    my $ROOT6 = tempdir(CLEANUP => 1);
    $ROOT6 =~ s{\\}{/}g;
    my $DIR6 = record_dir($ROOT6, 'project');

    my $r0 = run_cli('create', '--title', 'Original', '--id', 'note-ac6', '--root', $ROOT6);
    is($r0->{rc}, 0, 'AC-6 fixture: create --id note-ac6 succeeds') or diag("stderr: $r0->{err}");
    my $path6 = "$DIR6/note-ac6.md";
    my $before = slurp_raw($path6);

    my $r1 = run_cli('create', '--title', 'Duplicate', '--id', 'note-ac6', '--root', $ROOT6);
    is($r1->{rc}, 2, 'AC-6: create --id <existing> exits 2') or diag("stderr: $r1->{err}");
    is(err_kind($r1->{err}), 'exists', 'AC-6: ...with kind: exists');
    is(slurp_raw($path6), $before, 'AC-6: the existing record\'s bytes are unchanged after the refused duplicate create');

    my $r2 = run_cli('create', '--title', 'Bad', '--id', 'a/b', '--root', $ROOT6);
    is($r2->{rc}, 2, 'AC-6: create --id \'a/b\' exits 2');
    is(err_kind($r2->{err}), 'bad_id', 'AC-6: ...with kind: bad_id');
}

# =============================================================================
# AC-7 -- create whose default internal target file already exists: 2,
# kind: exists, existing file's bytes unchanged, NO record created.
# =============================================================================
{
    my $ROOT7 = tempdir(CLEANUP => 1);
    $ROOT7 =~ s{\\}{/}g;
    my $DIR7 = record_dir($ROOT7, 'project');
    my $INT7 = internal_dir($ROOT7, 'project');

    # First: create --id explicitly, so the default target path is known,
    # THEN pre-seed a file at where a SECOND explicit --id would default to.
    my $preexisting_id = 'note-ac7';
    File::Spec->case_tolerant; # no-op, silence unused warning avoidance
    mkdir(norm_path($ROOT7) . '/.ccpraxis-local-data') unless -d norm_path($ROOT7) . '/.ccpraxis-local-data';
    mkdir($INT7) unless -d $INT7;
    open(my $fh, '>:raw', "$INT7/$preexisting_id.md") or die "fixture: cannot write pre-existing target: $!";
    print {$fh} 'already here';
    close $fh;

    my $r = run_cli('create', '--title', 'Collides', '--id', $preexisting_id, '--root', $ROOT7);
    is($r->{rc}, 2, 'AC-7: create whose default internal target already exists exits 2') or diag("stderr: $r->{err}");
    is(err_kind($r->{err}), 'exists', 'AC-7: ...with kind: exists');
    is(slurp_raw("$INT7/$preexisting_id.md"), 'already here', 'AC-7: the pre-existing target file\'s bytes are unchanged');
    ok(!-f "$DIR7/$preexisting_id.md", 'AC-7: no record was created');
}

# =============================================================================
# AC-8 -- show on an unknown id: 2, kind: not_found, empty STDOUT.
# =============================================================================
{
    my $ROOT8 = tempdir(CLEANUP => 1);
    $ROOT8 =~ s{\\}{/}g;
    my $r = run_cli('show', 'no-such-note', '--root', $ROOT8);
    is($r->{rc}, 2, 'AC-8: show <unknown id> exits 2');
    is(err_kind($r->{err}), 'not_found', 'AC-8: ...with kind: not_found');
    is($r->{out}, '', 'AC-8: STDOUT is empty');
}

# =============================================================================
# Shared fixture for AC-9..AC-16: one project-scope store, one note.
# =============================================================================
my $ROOTX = tempdir(CLEANUP => 1);
$ROOTX =~ s{\\}{/}g;
my ($X_ID, $X_PATH);
{
    my $r = run_cli('create', '--title', 'Editable note', '--root', $ROOTX, '--body', 'original body');
    $X_ID = field0($r->{out}, 'id');
    ok(defined $X_ID, 'edit-fixture: create succeeds and returns an id') or diag("stderr: $r->{err}");
    my $j = (show_json($X_ID, '--root', $ROOTX))[0];
    $X_PATH = $j->{path} if ref($j) eq 'HASH';
}

# =============================================================================
# AC-9 -- edit changes title/covers/set/unset; audience and target are
# UNCHANGED; created is unchanged; rev differs.
# =============================================================================
{
    my ($before_json) = show_json($X_ID, '--root', $ROOTX);
    my $before_rev      = ref($before_json) eq 'HASH' ? $before_json->{rev} : undef;
    my $before_created  = ref($before_json) eq 'HASH' ? $before_json->{fields}{created} : undef;
    my $before_audience = ref($before_json) eq 'HASH' ? $before_json->{fields}{audience} : undef;
    my $before_target   = ref($before_json) eq 'HASH' ? $before_json->{fields}{target} : undef;

    my $r = run_cli('edit', $X_ID, '--title', 'New Title', '--covers', 'the X protocol', '--set', 'colour=blue', '--unset', 'tags', '--root', $ROOTX);
    is($r->{rc}, 0, 'AC-9: edit exits 0') or diag("stderr: $r->{err}");
    is(field0($r->{out}, 'changed'), 'yes', 'AC-9: result block carries changed: yes');

    my ($after) = show_json($X_ID, '--root', $ROOTX);
    ok(ref($after) eq 'HASH', 'AC-9: show --json after the edit decodes') or diag('not a hashref');
    if (ref($after) eq 'HASH') {
        is($after->{fields}{title}, 'New Title', 'AC-9: the new title is present');
        is($after->{fields}{covers}, 'the X protocol', 'AC-9: the new covers is present');
        is($after->{fields}{colour}, 'blue', 'AC-9: the new field colour=blue is present');
        ok(!exists $after->{fields}{tags}, 'AC-9: tags is gone (unset)');
        is($after->{fields}{created}, $before_created, 'AC-9: created is unchanged');
        is($after->{fields}{audience}, $before_audience, 'AC-9: audience is UNCHANGED by edit');
        is($after->{fields}{target}, $before_target, 'AC-9: target is UNCHANGED by edit');
        isnt($after->{rev}, $before_rev, 'AC-9: rev differs from before the edit');
    }
}

# =============================================================================
# AC-10 -- the three script-reserved fields refuse both --set and --unset
# (six invocations), plus edit --set writer=x dies reserved_field (the
# store's kind, not this script's). Nothing written in any case.
# =============================================================================
{
    my $before_bytes = slurp_raw($X_PATH);
    my @cases = (
        [ ['--set', 'audience=external'], 'audience_is_reserved', '--set audience=external' ],
        [ ['--unset', 'audience'],        'audience_is_reserved', '--unset audience' ],
        [ ['--set', 'target=docs/x.md'],  'target_is_reserved',   '--set target=docs/x.md' ],
        [ ['--unset', 'target'],          'target_is_reserved',   '--unset target' ],
        [ ['--set', 'promote_to=x'],      'journal_is_reserved',  '--set promote_to=x' ],
        [ ['--unset', 'promote_to'],      'journal_is_reserved',  '--unset promote_to' ],
    );
    for my $case (@cases) {
        my ($flags, $detail, $label) = @$case;
        my $r = run_cli('edit', $X_ID, @$flags, '--root', $ROOTX);
        is($r->{rc}, 2, "AC-10 [$label]: exits 2") or diag("stderr: $r->{err}");
        is(err_kind($r->{err}), 'usage', "AC-10 [$label]: ...with kind: usage");
        is(field2($r->{err}, 'detail'), $detail, "AC-10 [$label]: ...and detail: $detail");
    }
    my $r7 = run_cli('edit', $X_ID, '--set', 'writer=x', '--root', $ROOTX);
    is($r7->{rc}, 2, 'AC-10: edit --set writer=x exits 2');
    is(err_kind($r7->{err}), 'reserved_field', 'AC-10: ...with kind: reserved_field (the STORE\'s error, not usage)');

    my $after_bytes = slurp_raw($X_PATH);
    is($after_bytes, $before_bytes, 'AC-10: nothing was written by any of the seven refused edits');
}

# =============================================================================
# AC-11 -- edit with no mutating flag: 2, detail: nothing_to_change, rev
# byte-identical (re-read, not by message).
# =============================================================================
{
    my $before_bytes = slurp_raw($X_PATH);
    my $r = run_cli('edit', $X_ID, '--root', $ROOTX);
    is($r->{rc}, 2, 'AC-11: edit with no mutating flag exits 2') or diag("stderr: $r->{err}");
    is(err_kind($r->{err}), 'usage', 'AC-11: ...with kind: usage');
    is(field2($r->{err}, 'detail'), 'nothing_to_change', 'AC-11: ...and detail: nothing_to_change');
    my $after_bytes = slurp_raw($X_PATH);
    is($after_bytes, $before_bytes, 'AC-11: the record\'s bytes (and therefore rev) are unchanged, verified by re-reading the file');
}

# =============================================================================
# AC-12 -- edit --expect-rev <stale> dies conflict, id: equals the note id,
# expected_rev != actual_rev, record byte-identical to before. Non-vacuity:
# the same edit with the CURRENT rev succeeds.
# =============================================================================
{
    my ($cur) = show_json($X_ID, '--root', $ROOTX);
    my $stale_rev = (ref($cur) eq 'HASH') ? $cur->{rev} : ('d' x 64);

    my $bump = run_cli('edit', $X_ID, '--set', 'bump=1', '--root', $ROOTX);
    is($bump->{rc}, 0, 'AC-12 fixture: an intervening edit succeeds, making the earlier rev stale') or diag("stderr: $bump->{err}");

    my $before_bytes = slurp_raw($X_PATH);
    my $r = run_cli('edit', $X_ID, '--title', 'Conflict Title', '--expect-rev', $stale_rev, '--root', $ROOTX);
    is($r->{rc}, 2, 'AC-12: edit --expect-rev <stale hex> exits 2') or diag("stderr: $r->{err}");
    is(err_kind($r->{err}), 'conflict', 'AC-12: ...with kind: conflict');
    is(field2($r->{err}, 'id'), $X_ID, 'AC-12: ...and id: equals the note id');
    my $expected_rev = field2($r->{err}, 'expected_rev');
    my $actual_rev   = field2($r->{err}, 'actual_rev');
    ok(defined $expected_rev && defined $actual_rev && $expected_rev ne $actual_rev,
       'AC-12: expected_rev differs from actual_rev');
    my $after_bytes = slurp_raw($X_PATH);
    is($after_bytes, $before_bytes, 'AC-12: the record on disk is byte-identical to before the refused conflict edit');

    my ($fresh) = show_json($X_ID, '--root', $ROOTX);
    my $fresh_rev = (ref($fresh) eq 'HASH') ? $fresh->{rev} : undef;
    my $r2 = run_cli('edit', $X_ID, '--title', 'Non-Stale Title', '--expect-rev', $fresh_rev, '--root', $ROOTX);
    is($r2->{rc}, 0, 'AC-12 (non-vacuity): the same shape of edit with the CURRENT rev as --expect-rev succeeds')
        or diag("stderr: $r2->{err}");
}

# =============================================================================
# AC-13/AC-19/AC-20 -- delete: record gone; an INTERNAL note's content file
# is now REMOVED (spec §2.5, replacing the old "survives" oracle); an
# EXTERNAL note's target is NEVER touched (bytes AND mtime unchanged);
# `content: removed`/`content: kept` is printed on STDOUT after the result
# block; show then not_found, .md.lock remains, delete nosuch: not_found
# (never a silent no-op / never 0).
# =============================================================================
{
    my $ROOT13 = tempdir(CLEANUP => 1);
    $ROOT13 =~ s{\\}{/}g;
    my $DIR13 = record_dir($ROOT13, 'project');

    # internal audience
    my $r0 = run_cli('create', '--title', 'Delete me (internal)', '--content', 'keepme', '--root', $ROOT13);
    my $id13 = field0($r0->{out}, 'id');
    ok(defined $id13, 'AC-13 fixture: internal create succeeds') or diag("stderr: $r0->{err}");
    my $path13 = "$DIR13/$id13.md";
    my $target13 = internal_dir($ROOT13, 'project') . "/$id13.md";
    ok(-f $path13, 'AC-13 fixture: the record exists before delete');
    ok(-f $target13, 'AC-13 fixture: the target file exists before delete');

    my $r1 = run_cli('delete', $id13, '--root', $ROOT13);
    is($r1->{rc}, 0, 'AC-13: delete exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'changed'), 'yes', 'AC-13: result block carries changed: yes');
    ok(!-f $path13, 'AC-13: the record file is gone');
    ok(!-f $target13, 'AC-19: deleting an internal note REMOVES its content file (§2.5)');
    like($r1->{out}, qr/^content: removed$/m, 'AC-19: STDOUT carries content: removed, after the result block');

    my $r2 = run_cli('show', $id13, '--root', $ROOT13);
    is($r2->{rc}, 2, 'AC-13: show <deleted id> exits 2');
    is(err_kind($r2->{err}), 'not_found', 'AC-13: ...with kind: not_found');

    ok(-f "$path13.lock", 'AC-13: <id>.md.lock still exists on disk after delete (package 01 design)');

    my $r3 = run_cli('delete', 'never-existed-note', '--root', $ROOT13);
    is($r3->{rc}, 2, 'AC-13: delete nosuch exits 2 (not 0 -- it does NOT no-op)');
    is(err_kind($r3->{err}), 'not_found', 'AC-13: ...with kind: not_found');
    unlike($r3->{out}, qr/^content:/m, 'AC-22 (B21): a refused delete prints no content: line');

    # external audience -- AC-20: bytes AND mtime are untouched.
    mkdir(norm_path($ROOT13) . '/docs') unless -d (norm_path($ROOT13) . '/docs');
    my $rext = run_cli('create', '--title', 'External', '--audience', 'external', '--target', 'docs/x.md', '--root', $ROOT13);
    is($rext->{rc}, 0, 'AC-13 fixture: external create succeeds') or diag("stderr: $rext->{err}");
    my $extid = field0($rext->{out}, 'id');
    my $extpath_target = norm_path($ROOT13) . '/docs/x.md';
    open(my $fh, '>:raw', $extpath_target) or die "fixture: cannot seed external target: $!";
    print {$fh} 'external content';
    close $fh;
    utime(1_700_000_000, 1_700_000_000, $extpath_target) or die "fixture: utime: $!";
    my $mtime_before_ext = (stat($extpath_target))[9];
    my $rdel = run_cli('delete', $extid, '--root', $ROOT13);
    is($rdel->{rc}, 0, 'AC-13: delete on an external note exits 0') or diag("stderr: $rdel->{err}");
    ok(-f $extpath_target, 'AC-13/AC-20: <root>/docs/x.md still exists after deleting the external note that pointed at it');
    is(slurp_raw($extpath_target), 'external content', 'AC-20: the external target\'s bytes are unchanged after delete');
    is((stat($extpath_target))[9], $mtime_before_ext, 'AC-20: the external target\'s mtime is unchanged after delete');
    like($rdel->{out}, qr/^content: kept$/m, 'AC-20: STDOUT carries content: kept for an external delete');
}

# =============================================================================
# AC-14, AC-15, AC-16 -- list's default and --json forms.
# =============================================================================
{
    my $ROOTL = tempdir(CLEANUP => 1);
    $ROOTL =~ s{\\}{/}g;

    my $rempty = run_cli('list', '--root', $ROOTL);
    is($rempty->{rc}, 0, 'AC-15: list on an empty/absent store exits 0');
    unlike($rempty->{out}, qr/^note:/m, 'AC-15: no note: line is printed');
    is(field0($rempty->{out}, 'total'), '0', 'AC-15: total: 0');
    is(field0($rempty->{out}, 'internal'), '0', 'AC-15: internal: 0');
    is(field0($rempty->{out}, 'external'), '0', 'AC-15: external: 0');
    my $rempty_json = run_cli('list', '--json', '--root', $ROOTL);
    my $decoded_empty = decode_json_or_undef($rempty_json->{out});
    is_deeply($decoded_empty, [], 'AC-15: list --json decodes to an empty array on an absent store');

    my @ids;
    for my $t ('Alpha note', 'Beta note', 'Gamma note') {
        my $r = run_cli('create', '--title', $t, '--root', $ROOTL, '--tags', 'x,y');
        push @ids, field0($r->{out}, 'id');
    }
    ok((grep { defined } @ids) == 3, 'AC-14 fixture: three notes were created') or diag('ids: ' . join(',', map { $_ // '(undef)' } @ids));
    # one external note, to exercise the internal/external split
    my $rext = run_cli('create', '--title', 'Delta external', '--audience', 'external', '--target', 'docs/d.md', '--root', $ROOTL);
    my $ext_id = field0($rext->{out}, 'id');
    push @ids, $ext_id if defined $ext_id;

    my $r1 = run_cli('list', '--root', $ROOTL);
    is($r1->{rc}, 0, 'AC-14: list exits 0');
    my @blocks = extract_note_blocks($r1->{out});
    is(scalar(@blocks), 4, 'AC-14: exactly one note: block per record, with exactly the five keys in the fixed order '
                          . '(audience/target/covers/tags/title), two-space indented')
        or diag("output:\n$r1->{out}");
    my @expect_ids = sort @ids;
    my @got_ids = map { $_->{id} } @blocks;
    is_deeply(\@got_ids, \@expect_ids, 'AC-14: ids appear in ascending ASCII order');
    is(field0($r1->{out}, 'total'), '4', 'AC-14: summary total: 4');
    is(field0($r1->{out}, 'internal'), '3', 'AC-14: summary internal: 3');
    is(field0($r1->{out}, 'external'), '1', 'AC-14: summary external: 1');

    my $r2 = run_cli('list', '--root', $ROOTL);
    is($r2->{out}, $r1->{out}, 'AC-14: two consecutive list invocations with no intervening mutation are byte-identical');

    my $rjson = run_cli('list', '--json', '--root', $ROOTL);
    is($rjson->{rc}, 0, 'AC-15: list --json exits 0');
    my $decoded = decode_json_or_undef($rjson->{out});
    ok(ref($decoded) eq 'ARRAY', 'AC-15: list --json decodes to an array') or diag("raw: $rjson->{out}");
    if (ref($decoded) eq 'ARRAY') {
        is(scalar(@$decoded), 4, 'AC-15: the array\'s length equals the summary total: (4)');
        is_deeply([map { $_->{id} } @$decoded], \@expect_ids, 'AC-15: element order matches the default form\'s order');
        for my $el (@$decoded) {
            for my $k (qw(id title audience target created writer)) {
                ok(exists $el->{$k}, "AC-15: each element carries the key '$k'");
            }
        }
    }

    # AC-16 -- list never stats a target: delete a target file out of band,
    # confirm list's output is byte-identical to before.
    my $before_delete = $r1->{out};
    my $target_to_kill = internal_dir($ROOTL, 'project') . "/$ids[0].md";
    unlink($target_to_kill) if -f $target_to_kill;
    ok(!-f $target_to_kill, 'AC-16 fixture: the target file was actually removed');
    my $r3 = run_cli('list', '--root', $ROOTL);
    is($r3->{rc}, 0, 'AC-16: list still exits 0 after a target file goes missing out of band');
    is($r3->{out}, $before_delete, 'AC-16: list\'s output is byte-identical to before the out-of-band target deletion');
}

# =============================================================================
# AC-44 -- list on a store with one hand-written unparseable record: 2,
# kind: malformed, STDOUT empty (no partial listing, Decision 4).
# =============================================================================
{
    my $ROOT44 = tempdir(CLEANUP => 1);
    $ROOT44 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'Healthy', '--root', $ROOT44);
    is($r0->{rc}, 0, 'AC-44 fixture: one healthy note is created') or diag("stderr: $r0->{err}");
    my $DIR44 = record_dir($ROOT44, 'project');
    if (-d $DIR44) {
        open(my $fh, '>', "$DIR44/bad.md") or die "fixture: cannot write $DIR44/bad.md: $!";
        print {$fh} "not frontmatter at all\n";
        close $fh;
    }
    my $r1 = run_cli('list', '--root', $ROOT44);
    is($r1->{rc}, 2, 'AC-44: list on a store with one malformed record exits 2') or diag("stderr: $r1->{err}");
    is(err_kind($r1->{err}), 'malformed', 'AC-44: ...with kind: malformed');
    is($r1->{out}, '', 'AC-44: STDOUT is empty -- no partial listing');
}

# =============================================================================
# AC-42 -- body round-trip: pipes, a bare `---` line, angle brackets, a tab,
# a trailing blank line.
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
    is($r0->{rc}, 0, 'AC-42 fixture: create --body-file succeeds') or diag("stderr: $r0->{err}");
    my $id42 = field0($r0->{out}, 'id');

    my ($j) = show_json($id42, '--root', $ROOTB);
    ok(ref($j) eq 'HASH', 'AC-42: show --json decodes') or diag('not a hashref');
    is($j->{body}, $body, 'AC-42: the body survives create(--body-file) -> show --json byte-identically') if ref($j) eq 'HASH';

    my $rshow = run_cli('show', $id42, '--root', $ROOTB);
    is($rshow->{rc}, 0, 'AC-42: show (default form) exits 0') or diag("stderr: $rshow->{err}");
    if ($rshow->{out} =~ /\A(.*?)\n\n(.*)\z/s) {
        my $tail = $2;
        is($tail, $body, 'AC-42: everything after the first empty line equals the body exactly');
    } else {
        fail('AC-42: everything after the first empty line equals the body exactly')
            and diag("no blank-line separator found in:\n$rshow->{out}");
    }
}

# =============================================================================
# AC-43 -- a title and covers each containing Andre (with the actual
# non-ASCII form) and an em dash round-trip via create -> list -> show
# --json, with no mojibake in the raw STDOUT bytes.
# =============================================================================
{
    my $ROOT43 = tempdir(CLEANUP => 1);
    $ROOT43 =~ s{\\}{/}g;
    my $name = "Andr\x{e9}";
    my $dash = "\x{2014}";
    my $title43  = "Note for $name $dash review";
    my $covers43 = "Covers ${name}'s $dash work";

    my $r0 = run_cli('create', '--title', $title43, '--covers', $covers43, '--root', $ROOT43);
    is($r0->{rc}, 0, 'AC-43 fixture: create with non-ASCII title/covers succeeds') or diag("stderr: $r0->{err}");
    my $id43 = field0($r0->{out}, 'id');

    my $rlist = run_cli('list', '--json', '--root', $ROOT43);
    my $decoded_list = decode_json_or_undef($rlist->{out});
    my ($el) = grep { $_->{id} eq $id43 } @{ $decoded_list // [] };
    is(ref($el) eq 'HASH' ? $el->{title} : undef, $title43, 'AC-43: the title round-trips unchanged through list --json (decoded characters)');

    my ($j43) = show_json($id43, '--root', $ROOT43);
    ok(ref($j43) eq 'HASH', 'AC-43: show --json decodes');
    if (ref($j43) eq 'HASH') {
        is($j43->{fields}{title}, $title43, 'AC-43: the title round-trips unchanged through show --json');
        is($j43->{fields}{covers}, $covers43, 'AC-43: covers round-trips unchanged through show --json');
    }

    my $raw_bytes = $rlist->{out};
    my $bytes_for_check = $raw_bytes;
    utf8::encode($bytes_for_check) if utf8::is_utf8($bytes_for_check);
    unlike($bytes_for_check, qr/\xC3\x83/, 'AC-43: no double-encoded mojibake (0xC3 0x83) in the raw STDOUT bytes');
}

# =============================================================================
# AC-28 -- check_pointers(root=>,home=>) on two healthy project notes.
# =============================================================================
my (%cp_fixtures);
{
    my $R28 = tempdir(CLEANUP => 1); $R28 =~ s{\\}{/}g;
    my $H28 = tempdir(CLEANUP => 1); $H28 =~ s{\\}{/}g;
    run_cli('create', '--title', 'cp1', '--root', $R28);
    run_cli('create', '--title', 'cp2', '--root', $R28);

    my $c = eval { Almanac::Note::check_pointers(root => $R28, home => $H28) };
    ok(defined $c, 'AC-28: check_pointers(root=>,home=>) returns a value') or diag("error: $@");
    if (ref($c) eq 'HASH') {
        is_deeply([sort keys %$c], [sort qw(type project global)], 'AC-28: top level has exactly type/project/global');
        is($c->{type}, 'note', 'AC-28: type is the string note');
        if (ref($c->{project}) eq 'HASH') {
            is_deeply([sort keys %{$c->{project}}], [sort qw(available reason pointers dangling)],
                'AC-28: project scope has exactly available/reason/pointers/dangling');
            is($c->{project}{available}, 1, 'AC-28: project available == 1');
            is($c->{project}{reason}, 'ok', 'AC-28: project reason == ok');
            is(ref($c->{project}{pointers}), 'ARRAY', 'AC-28: project pointers is an arrayref');
            is(scalar(@{$c->{project}{pointers}}), 2, 'AC-28: project pointers has 2 entries');
            is_deeply($c->{project}{dangling}, [], 'AC-28: project dangling is empty');
            for my $e (@{$c->{project}{pointers}}) {
                is_deeply([sort keys %$e], [sort qw(id title audience target promote_to resolved record status)],
                    'AC-28: each pointer entry has exactly the eight keys of §2.7 clause 5');
                is($e->{status}, 'ok', 'AC-28: each healthy entry has status ok');
                ok(defined $e->{resolved}, 'AC-28: each healthy entry has resolved defined');
                is($e->{promote_to}, undef, 'AC-28: each healthy entry has promote_to undef');
            }
        }
        is($c->{global}{available}, 1, 'AC-28: global (empty home) is available too');
        is($c->{global}{reason}, 'ok', 'AC-28: global reason == ok');
    }
    $cp_fixtures{ac28} = $c;
}

# =============================================================================
# AC-29 -- after one target file is deleted out of band, that entry is
# dangling (resolved undef) and appears in dangling; the healthy entry is
# untouched and absent from dangling; the dangling entry is the SAME
# hashref as the corresponding pointers entry (reference identity).
# =============================================================================
{
    my $R29 = tempdir(CLEANUP => 1); $R29 =~ s{\\}{/}g;
    my $H29 = tempdir(CLEANUP => 1); $H29 =~ s{\\}{/}g;
    my $r1 = run_cli('create', '--title', 'healthy', '--root', $R29);
    my $r2 = run_cli('create', '--title', 'to be dangling', '--root', $R29);
    my $id_healthy   = field0($r1->{out}, 'id');
    my $id_dangling  = field0($r2->{out}, 'id');
    ok(defined $id_healthy && defined $id_dangling, 'AC-29 fixture: both notes created') or diag("$r1->{err} / $r2->{err}");
    my $target_gone = internal_dir($R29, 'project') . "/$id_dangling.md";
    unlink($target_gone) if -f $target_gone;
    ok(!-f $target_gone, 'AC-29 fixture: the target file was actually removed');

    my $c = eval { Almanac::Note::check_pointers(root => $R29, home => $H29) };
    ok(defined $c, 'AC-29: check_pointers() returns a value') or diag("error: $@");
    if (ref($c) eq 'HASH' && ref($c->{project}) eq 'HASH') {
        my ($p) = grep { $_->{id} eq $id_healthy } @{$c->{project}{pointers}};
        my ($d) = grep { $_->{id} eq $id_dangling } @{$c->{project}{pointers}};
        ok(ref($p) eq 'HASH' && $p->{status} eq 'ok', 'AC-29: the healthy entry has status ok');
        ok(ref($d) eq 'HASH' && $d->{status} eq 'dangling', 'AC-29: the deleted-target entry has status dangling');
        is(ref($d) eq 'HASH' ? $d->{resolved} : 'MISSING', undef, 'AC-29: the dangling entry has resolved undef') if ref($d) eq 'HASH';
        is(scalar(@{$c->{project}{dangling}}), 1, 'AC-29: dangling has length 1');
        ok(!(grep { $_->{id} eq $id_healthy } @{$c->{project}{dangling}}), 'AC-29: the healthy entry is absent from dangling');
        my ($d_in_dangling) = grep { $_->{id} eq $id_dangling } @{$c->{project}{dangling}};
        ok(ref($d_in_dangling) eq 'HASH', 'AC-29: the dangling entry appears in the dangling array');
        if (ref($d) eq 'HASH' && ref($d_in_dangling) eq 'HASH') {
            is(refaddr($d), refaddr($d_in_dangling), 'AC-29: dangling holds the SAME hashref as pointers (reference identity)');
        }
    }
}

# =============================================================================
# AC-30 -- a hand-edited target of '../../outside.md', a note with NO target
# field, and a note whose audience is 'sideways' each return dangling with
# resolved undef; none is ok; each appears in dangling.
# =============================================================================
{
    my $R30 = tempdir(CLEANUP => 1); $R30 =~ s{\\}{/}g;
    my $H30 = tempdir(CLEANUP => 1); $H30 =~ s{\\}{/}g;
    my $DIR30 = record_dir($R30, 'project');

    my $ra = run_cli('create', '--title', 'traversal target', '--root', $R30);
    my $rb = run_cli('create', '--title', 'no target field', '--root', $R30);
    my $rc = run_cli('create', '--title', 'bad audience', '--root', $R30);
    my ($ida, $idb, $idc) = map { field0($_->{out}, 'id') } ($ra, $rb, $rc);
    ok((defined $ida && defined $idb && defined $idc), 'AC-30 fixture: three notes created')
        or diag("$ra->{err} / $rb->{err} / $rc->{err}");

    set_frontmatter_field("$DIR30/$ida.md", 'target', '../../outside.md');
    remove_frontmatter_field("$DIR30/$idb.md", 'target');
    set_frontmatter_field("$DIR30/$idc.md", 'audience', 'sideways');

    my $c = eval { Almanac::Note::check_pointers(root => $R30, home => $H30) };
    ok(defined $c, 'AC-30: check_pointers() does not die on any of the three tampered records') or diag("error: $@");
    if (ref($c) eq 'HASH' && ref($c->{project}) eq 'HASH') {
        for my $pair ([$ida, 'traversal target'], [$idb, 'no target field'], [$idc, 'bad audience']) {
            my ($id, $label) = @$pair;
            my ($e) = grep { $_->{id} eq $id } @{$c->{project}{pointers}};
            ok(ref($e) eq 'HASH' && $e->{status} eq 'dangling', "AC-30 [$label]: status is dangling");
            is(ref($e) eq 'HASH' ? $e->{resolved} : 'MISSING', undef, "AC-30 [$label]: resolved is undef") if ref($e) eq 'HASH';
            ok((grep { $_->{id} eq $id } @{$c->{project}{dangling}}), "AC-30 [$label]: appears in the dangling array");
        }
    }
}

# =============================================================================
# AC-31 -- a note whose target path is a DIRECTORY rather than a file
# returns dangling (the -f rule of ruling 6, asserted directly).
# =============================================================================
{
    my $R31 = tempdir(CLEANUP => 1); $R31 =~ s{\\}{/}g;
    my $H31 = tempdir(CLEANUP => 1); $H31 =~ s{\\}{/}g;
    my $r = run_cli('create', '--title', 'target becomes a dir', '--root', $R31);
    my $id31 = field0($r->{out}, 'id');
    ok(defined $id31, 'AC-31 fixture: create succeeds') or diag("stderr: $r->{err}");
    my $tf = internal_dir($R31, 'project') . "/$id31.md";
    unlink($tf) if -f $tf;
    mkdir($tf) or diag("could not mkdir $tf: $!");
    ok(-d $tf, 'AC-31 fixture: a directory now sits at the target path');

    my $c = eval { Almanac::Note::check_pointers(root => $R31, home => $H31) };
    ok(defined $c, 'AC-31: check_pointers() does not die when the target path is a directory') or diag("error: $@");
    if (ref($c) eq 'HASH' && ref($c->{project}) eq 'HASH') {
        my ($e) = grep { $_->{id} eq $id31 } @{$c->{project}{pointers}};
        ok(ref($e) eq 'HASH' && $e->{status} eq 'dangling', 'AC-31: a directory at the target path is reported dangling, never ok');
    }
}

# =============================================================================
# AC-32 -- check_pointers() against non-existent store directories returns
# both scopes available=>1, reason=>'ok', pointers=>[], dangling=>[].
# =============================================================================
{
    my $R32 = tempdir(CLEANUP => 1); $R32 =~ s{\\}{/}g;
    my $H32 = tempdir(CLEANUP => 1); $H32 =~ s{\\}{/}g;
    my $c = eval { Almanac::Note::check_pointers(root => $R32, home => $H32) };
    ok(defined $c, 'AC-32: check_pointers() against non-existent dirs returns a value') or diag("error: $@");
    if (ref($c) eq 'HASH') {
        for my $scope (qw(project global)) {
            is($c->{$scope}{available}, 1, "AC-32: $scope available == 1 (no notes is not unavailable)");
            is($c->{$scope}{reason}, 'ok', "AC-32: $scope reason == ok");
            is_deeply($c->{$scope}{pointers}, [], "AC-32: $scope pointers == []");
            is_deeply($c->{$scope}{dangling}, [], "AC-32: $scope dangling == []");
        }
    }
}

# =============================================================================
# AC-33 -- one unparseable project record: project available=>0,
# reason=>'malformed', pointers/dangling ABSENT (exists false); does not
# die; global unaffected.
# =============================================================================
{
    my $R33 = tempdir(CLEANUP => 1); $R33 =~ s{\\}{/}g;
    my $H33 = tempdir(CLEANUP => 1); $H33 =~ s{\\}{/}g;
    run_cli('create', '--title', 'healthy project note', '--root', $R33);
    my $DIR33 = record_dir($R33, 'project');
    if (-d $DIR33) {
        open(my $fh, '>', "$DIR33/bad.md") or die "fixture: cannot write $DIR33/bad.md: $!";
        print {$fh} "not frontmatter at all\n";
        close $fh;
    }
    my $c = eval { Almanac::Note::check_pointers(root => $R33, home => $H33) };
    ok(!$@, 'AC-33: check_pointers() does not die on an unparseable record') or diag("error: $@");
    ok(defined $c, 'AC-33: check_pointers() still returns a value');
    if (ref($c) eq 'HASH') {
        is($c->{project}{available}, 0, 'AC-33: project available == 0');
        is($c->{project}{reason}, 'malformed', 'AC-33: project reason == malformed');
        ok(!exists($c->{project}{pointers}) && !exists($c->{project}{dangling}),
           'AC-33: project pointers/dangling keys are ABSENT (exists is false, not "equal to []")');
        is($c->{global}{available}, 1, 'AC-33: global scope is unaffected and still reported');
    }
}

# =============================================================================
# AC-34 -- check-pointers default form grammar and --json deep equality.
# =============================================================================
{
    my $R34 = tempdir(CLEANUP => 1); $R34 =~ s{\\}{/}g;
    my $H34 = tempdir(CLEANUP => 1); $H34 =~ s{\\}{/}g;
    run_cli('create', '--title', 'cp-default-1', '--root', $R34);
    my $rd = run_cli('create', '--title', 'cp-default-2 external', '--audience', 'external', '--target', 'docs/z.md', '--root', $R34);
    my $id_ext = field0($rd->{out}, 'id');
    my $target_missing = norm_path($R34) . '/docs/z.md';
    ok(!-f $target_missing, 'AC-34 fixture: the external note\'s target was never materialized -- it is dangling by construction');

    my $r = run_cli('check-pointers', '--root', $R34, '--home', $H34);
    is($r->{rc}, 0, 'AC-34: check-pointers exits 0') or diag("stderr: $r->{err}");
    like($r->{out}, qr/^type:\snote$/m, 'AC-34: type: note at column 0');
    like($r->{out}, qr/^scope:\sproject$/m, 'AC-34: scope: project at column 0');
    like($r->{out}, qr/^scope:\sglobal$/m, 'AC-34: scope: global at column 0');
    is(field2($r->{out}, 'available'), '1', 'AC-34: project available: 1 (two-space indent)');
    is(field2($r->{out}, 'total'), '2', 'AC-34: project total: 2');
    is(field2($r->{out}, 'dangling'), '1', 'AC-34: project dangling: 1');
    my @cp_notes = extract_cp_notes($r->{out});
    ok((grep { $_->{id} eq $id_ext && $_->{status} eq 'dangling' } @cp_notes), 'AC-34: the external note appears with status: dangling, four-space indented');
    ok((grep { $_->{status} eq 'ok' } @cp_notes), 'AC-34: the healthy note appears with status: ok');

    my $rjson = run_cli('check-pointers', '--json', '--root', $R34, '--home', $H34);
    is($rjson->{rc}, 0, 'AC-34: check-pointers --json exits 0');
    my $direct = eval { Almanac::Note::check_pointers(root => $R34, home => $H34) };
    my $decoded = decode_json_or_undef($rjson->{out});
    if (ref($direct) eq 'HASH' && ref($decoded) eq 'HASH') {
        is_deeply($decoded, $direct, 'AC-34: check-pointers --json decodes is_deeply-equal to Almanac::Note::check_pointers() for the same fixture');
    } else {
        fail('AC-34: check-pointers --json decodes is_deeply-equal to Almanac::Note::check_pointers()');
        diag('direct ref: ' . ref($direct) . ' decoded ref: ' . ref($decoded));
    }
}

# =============================================================================
# AC-36 -- a project note and a global note with the same title are two
# distinct records; neither list shows the other's id.
# =============================================================================
{
    my $ROOT36 = tempdir(CLEANUP => 1); $ROOT36 =~ s{\\}{/}g;
    my $HOME36 = tempdir(CLEANUP => 1); $HOME36 =~ s{\\}{/}g;
    my $PDIR36 = record_dir($ROOT36, 'project');
    my $GDIR36 = record_dir($HOME36, 'global');

    my $rp = run_cli('create', '--title', 'Same Title Both Scopes', '--root', $ROOT36);
    my $rg = run_cli('create', '--title', 'Same Title Both Scopes', '--covers', 'AC-36-global-covers', '--global', '--home', $HOME36);
    is($rp->{rc}, 0, 'AC-36 fixture: project create succeeds') or diag("stderr: $rp->{err}");
    is($rg->{rc}, 0, 'AC-36 fixture: global create succeeds') or diag("stderr: $rg->{err}");
    my $pid = field0($rp->{out}, 'id');
    my $gid = field0($rg->{out}, 'id');
    ok(defined($pid) && defined($gid) && $pid ne $gid, 'AC-36: the project and global records have distinct ids')
        or diag('pid=' . ($pid // '(undef)') . ' gid=' . ($gid // '(undef)'));

    ok(-f "$PDIR36/" . ($pid // '(none)') . '.md', 'AC-36: the project record exists under the project Decision-2 dir') if defined $pid;
    ok(-f "$GDIR36/" . ($gid // '(none)') . '.md', 'AC-36: the global record exists under the global Decision-2 dir') if defined $gid;
    ok(!-f "$GDIR36/" . ($pid // '(none)') . '.md', 'AC-36: the project id is NOT present under the global dir') if defined $pid;
    ok(!-f "$PDIR36/" . ($gid // '(none)') . '.md', 'AC-36: the global id is NOT present under the project dir') if defined $gid;

    my $rlist_p = run_cli('list', '--root', $ROOT36);
    my $rlist_g = run_cli('list', '--global', '--home', $HOME36);
    my @pblocks = extract_note_blocks($rlist_p->{out});
    my @gblocks = extract_note_blocks($rlist_g->{out});
    ok(defined($pid) && (grep { $_->{id} eq $pid } @pblocks), 'AC-36: project list shows the project id') if defined $pid;
    ok(defined($gid) && !(grep { $_->{id} eq $gid } @pblocks), 'AC-36: project list does NOT show the global id') if defined $gid;
    ok(defined($gid) && (grep { $_->{id} eq $gid } @gblocks), 'AC-36: global list shows the global id') if defined $gid;
    ok(defined($pid) && !(grep { $_->{id} eq $pid } @gblocks), 'AC-36: global list does NOT show the project id') if defined $pid;
}

# =============================================================================
# AC-45 -- argv hardening sweep.
# =============================================================================
{
    my $ROOT45 = tempdir(CLEANUP => 1);
    $ROOT45 =~ s{\\}{/}g;

    # unknown flag, per verb
    my $r1 = run_cli('list', '--expect-rev', 'x', '--root', $ROOT45);
    is($r1->{rc}, 2, 'AC-45: list --expect-rev x (unallowed on list) exits 2');
    is(field2($r1->{err}, 'detail'), 'unknown_flag', 'AC-45: ...detail: unknown_flag');

    my $r2 = run_cli('create', '--title', 'x', '--bogus-flag', 'y', '--root', $ROOT45);
    is($r2->{rc}, 2, 'AC-45: create --bogus-flag exits 2');
    is(field2($r2->{err}, 'detail'), 'unknown_flag', 'AC-45: ...detail: unknown_flag');

    my $rseed = run_cli('create', '--title', 'seed', '--root', $ROOT45);
    my $seed_id = field0($rseed->{out}, 'id');
    my $r3 = run_cli('edit', $seed_id, '--expect-rv', 'x', '--root', $ROOT45);
    is($r3->{rc}, 2, 'AC-45: edit --expect-rv (typo) exits 2 -- a typo fails closed');
    is(field2($r3->{err}, 'detail'), 'unknown_flag', 'AC-45: ...detail: unknown_flag');

    # bare value-required flags -> missing_flag_value, on create (all
    # value-required flags this verb accepts). The flag under test is
    # placed LAST in argv (never followed by --root) so a bare-value check
    # can never be silently cured by a later occurrence of the SAME flag
    # (repeated flags are last-wins per §2.2, and a flag that DOES receive
    # a value deletes its %bool_default mark -- testing "--root" with a
    # trailing "--root $ROOT45" would therefore vacuously pass). Since the
    # value-required-flag sweep runs during argv parsing, before any store
    # is opened, omitting --root here touches no real filesystem path.
    for my $flag (qw(root home id target covers tags body body-file content content-file audience)) {
        my $r = run_cli('create', '--root', $ROOT45, '--title', 'x', "--$flag");
        is($r->{rc}, 2, "AC-45: bare --$flag exits 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is(field2($r->{err}, 'detail'), 'missing_flag_value', "AC-45: ...detail: missing_flag_value for --$flag");
    }
    my $r4 = run_cli('edit', '--root', $ROOT45, $seed_id, '--expect-rev');
    is($r4->{rc}, 2, 'AC-45: edit --expect-rev bare (last value-required flag not on create) exits 2');
    is(field2($r4->{err}, 'detail'), 'missing_flag_value', 'AC-45: ...detail: missing_flag_value for --expect-rev');

    # extra_positional
    my $r5 = run_cli('show', $seed_id, 'extra-positional-token', '--root', $ROOT45);
    is($r5->{rc}, 2, 'AC-45: two positionals after the verb exits 2');
    is(field2($r5->{err}, 'detail'), 'extra_positional', 'AC-45: ...detail: extra_positional');

    # --global 0 still selects global (presence, not truthiness)
    my $HOME45 = tempdir(CLEANUP => 1);
    $HOME45 =~ s{\\}{/}g;
    my $r6 = run_cli('create', '--title', 'global via presence', '--covers', 'AC-45-global-covers', '--global', '0', '--home', $HOME45, '--root', $ROOT45);
    is($r6->{rc}, 0, 'AC-45: create --global 0 --home <H> exits 0') or diag("stderr: $r6->{err}");
    is(field0($r6->{out}, 'scope'), 'global', 'AC-45: --global 0 STILL selects the global scope (presence, not truthiness)');
    my $GDIR45 = record_dir($HOME45, 'global');
    is(scalar(list_md_files($GDIR45)), 1, 'AC-45: exactly one record was written under the GLOBAL dir, not project');
}

# =============================================================================
# Spec 09-notes-fixes §2.3/§2.5/§2.6: global --covers requirement+budget, and
# delete's content-file removal rule. Test labels below carry the spec's own
# AC numbers with a "(covers)"/"(delete)" suffix to disambiguate from this
# file's pre-existing (05-notes) AC-9..AC-18 labels, which cover unrelated
# edit/check-pointers behavior.
# =============================================================================

# -----------------------------------------------------------------------
# AC-18 (static) -- the budget number comes from COVERS_BYTE_BUDGET(), never
# the literal 200, anywhere non-comment in almanac-note.pl.
# -----------------------------------------------------------------------
{
    my @lines = read_all_lines($NOTE_PL);
    my $budget_sym_count = grep { /\bCOVERS_BYTE_BUDGET\b/ } @lines;
    ok($budget_sym_count >= 1, 'AC-18: almanac-note.pl mentions COVERS_BYTE_BUDGET')
        or diag('COVERS_BYTE_BUDGET not found anywhere in the file');
    my @literal_200 = grep { $_ !~ /^\s*#/ && /\b200\b/ } @lines;
    ok(@literal_200 == 0, 'AC-18: no non-comment line contains the literal 200')
        or diag($_) for @literal_200;
}

# -----------------------------------------------------------------------
# AC-9 (covers)/B7 -- create --global without --covers: missing_covers,
# nothing written.
# -----------------------------------------------------------------------
{
    my $HOMEC9 = tempdir(CLEANUP => 1); $HOMEC9 =~ s{\\}{/}g;
    my $r = run_cli('create', '--title', 'No Covers', '--global', '--home', $HOMEC9);
    is($r->{rc}, 2, 'AC-9 (covers): create --global without --covers exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is($r->{out}, '', 'AC-9 (covers): STDOUT is empty');
    is(err_kind($r->{err}), 'usage', 'AC-9 (covers): ...with kind: usage');
    is(field2($r->{err}, 'detail'), 'missing_covers', 'AC-9 (covers): ...and detail: missing_covers');
    like($r->{err}, qr/a global note needs --covers/, 'AC-9 (covers): STDERR carries the missing_covers prose line');
    my $GDIR9 = record_dir($HOMEC9, 'global');
    is(scalar(list_md_files($GDIR9)), 0, 'AC-9 (covers): no record was created under the global store');
    my $NOTES9 = internal_dir($HOMEC9, 'global');
    is(scalar(list_md_files($NOTES9)), 0, 'AC-9 (covers): no content file appears under the global notes dir');
}

# -----------------------------------------------------------------------
# AC-10 (covers)/B8 -- project create without covers still exits 0.
# -----------------------------------------------------------------------
{
    my $ROOTC10 = tempdir(CLEANUP => 1); $ROOTC10 =~ s{\\}{/}g;
    my $r = run_cli('create', '--title', 'No Covers Needed', '--root', $ROOTC10);
    is($r->{rc}, 0, 'AC-10 (covers): project create without --covers exits 0') or diag("stderr: $r->{err}");
}

# -----------------------------------------------------------------------
# AC-11 (covers)/B9 -- 201 bytes refused (byte count stated); 200 accepted
# and stored untruncated.
# -----------------------------------------------------------------------
{
    my $HOMEC11 = tempdir(CLEANUP => 1); $HOMEC11 =~ s{\\}{/}g;
    my $c201 = 'x' x 201;
    my $r1 = run_cli('create', '--title', 'Over Budget', '--covers', $c201, '--global', '--home', $HOMEC11);
    is($r1->{rc}, 2, 'AC-11 (covers): create --global --covers <201 bytes> exits 2') or diag("stderr: $r1->{err}");
    is(field2($r1->{err}, 'detail'), 'covers_over_budget', 'AC-11 (covers): ...detail: covers_over_budget');
    like($r1->{err}, qr/--covers is 201 bytes/, 'AC-11 (covers): STDERR states "--covers is 201 bytes"');
    like($r1->{err}, qr/at most 200 bytes/, 'AC-11 (covers): STDERR states "at most 200 bytes"');
    my $GDIR11 = record_dir($HOMEC11, 'global');
    is(scalar(list_md_files($GDIR11)), 0, 'AC-11 (covers): nothing was written for the refused 201-byte covers');

    my $c200 = 'x' x 200;
    my $r2 = run_cli('create', '--title', 'Exactly Budget', '--covers', $c200, '--global', '--home', $HOMEC11);
    is($r2->{rc}, 0, 'AC-11 (covers): create --global --covers <200 bytes> (exactly the budget) exits 0') or diag("stderr: $r2->{err}");
    my $id11 = field0($r2->{out}, 'id');
    my ($j11) = show_json($id11, '--global', '--home', $HOMEC11);
    is(ref($j11) eq 'HASH' ? $j11->{fields}{covers} : undef, $c200, 'AC-11 (covers): the stored covers is the full 200-byte value, untruncated');
}

# -----------------------------------------------------------------------
# AC-12 (covers)/B10 -- multibyte byte counting: 100xe (200 bytes)
# accepted, 101xe (202 bytes) refused and the count is stated.
# -----------------------------------------------------------------------
{
    my $HOMEC12 = tempdir(CLEANUP => 1); $HOMEC12 =~ s{\\}{/}g;
    my $e_ok  = "\x{e9}" x 100;   # 100 x 2-byte UTF-8 char = 200 bytes
    my $e_bad = "\x{e9}" x 101;   # 202 bytes

    my $r1 = run_cli('create', '--title', 'Multibyte OK', '--covers', $e_ok, '--global', '--home', $HOMEC12);
    is($r1->{rc}, 0, 'AC-12 (covers): 100 x e-acute (200 bytes) is accepted') or diag("stderr: $r1->{err}");

    my $r2 = run_cli('create', '--title', 'Multibyte Bad', '--covers', $e_bad, '--global', '--home', $HOMEC12);
    is($r2->{rc}, 2, 'AC-12 (covers): 101 x e-acute (202 bytes) is refused') or diag("stdout: $r2->{out}\nstderr: $r2->{err}");
    is(field2($r2->{err}, 'detail'), 'covers_over_budget', 'AC-12 (covers): ...detail: covers_over_budget');
    like($r2->{err}, qr/--covers is 202 bytes/, 'AC-12 (covers): STDERR states "--covers is 202 bytes"');
}

# -----------------------------------------------------------------------
# AC-13 (covers)/B11 -- --set covers= satisfies the requirement and is
# budget-checked the same way as --covers.
# -----------------------------------------------------------------------
{
    my $HOMEC13 = tempdir(CLEANUP => 1); $HOMEC13 =~ s{\\}{/}g;
    my $r1 = run_cli('create', '--title', 'Via Set', '--set', 'covers=via set value', '--global', '--home', $HOMEC13);
    is($r1->{rc}, 0, 'AC-13 (covers): --set covers=... satisfies the global covers requirement') or diag("stderr: $r1->{err}");
    my $id13c = field0($r1->{out}, 'id');
    my ($j13c) = show_json($id13c, '--global', '--home', $HOMEC13);
    is(ref($j13c) eq 'HASH' ? $j13c->{fields}{covers} : undef, 'via set value', 'AC-13 (covers): the --set value is stored as covers');

    my $r2 = run_cli('create', '--title', 'Via Set Over Budget', '--set', 'covers=' . ('y' x 201), '--global', '--home', $HOMEC13);
    is($r2->{rc}, 2, 'AC-13 (covers): --set covers=<201 bytes> is refused') or diag("stderr: $r2->{err}");
    is(field2($r2->{err}, 'detail'), 'covers_over_budget', 'AC-13 (covers): ...detail: covers_over_budget');
}

# -----------------------------------------------------------------------
# AC-14 (covers)/B12 -- edit over budget via --covers and via --set
# covers=: refused with the byte count; rev and fields unchanged.
# -----------------------------------------------------------------------
{
    my $HOMEC14 = tempdir(CLEANUP => 1); $HOMEC14 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'Edit Budget Fixture', '--covers', 'initial covers', '--global', '--home', $HOMEC14);
    is($r0->{rc}, 0, 'AC-14 (covers) fixture: global create succeeds') or diag("stderr: $r0->{err}");
    my $id14 = field0($r0->{out}, 'id');
    my ($before14) = show_json($id14, '--global', '--home', $HOMEC14);
    my $before_rev14 = ref($before14) eq 'HASH' ? $before14->{rev} : undef;

    my $r1 = run_cli('edit', $id14, '--covers', ('z' x 201), '--global', '--home', $HOMEC14);
    is($r1->{rc}, 2, 'AC-14 (covers): edit --global --covers <201 bytes> exits 2') or diag("stderr: $r1->{err}");
    is(field2($r1->{err}, 'detail'), 'covers_over_budget', 'AC-14 (covers): ...detail: covers_over_budget');
    like($r1->{err}, qr/--covers is 201 bytes/, 'AC-14 (covers): STDERR states the byte count for --covers');

    my $r2 = run_cli('edit', $id14, '--set', 'covers=' . ('w' x 201), '--global', '--home', $HOMEC14);
    is($r2->{rc}, 2, 'AC-14 (covers): edit --global --set covers=<201 bytes> exits 2') or diag("stderr: $r2->{err}");
    is(field2($r2->{err}, 'detail'), 'covers_over_budget', 'AC-14 (covers): ...detail: covers_over_budget (via --set)');

    my ($after14) = show_json($id14, '--global', '--home', $HOMEC14);
    is(ref($after14) eq 'HASH' ? $after14->{rev} : undef, $before_rev14, 'AC-14 (covers): rev is unchanged after both refusals');
    is(ref($after14) eq 'HASH' ? $after14->{fields}{covers} : undef, 'initial covers', 'AC-14 (covers): covers is unchanged after both refusals');
}

# -----------------------------------------------------------------------
# AC-15 (covers)/B13 -- edit --unset covers on a global note is refused
# missing_covers; record unchanged.
# -----------------------------------------------------------------------
{
    my $HOMEC15 = tempdir(CLEANUP => 1); $HOMEC15 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'Unset Covers Fixture', '--covers', 'will be unset', '--global', '--home', $HOMEC15);
    my $id15 = field0($r0->{out}, 'id');
    ok(defined $id15, 'AC-15 (covers) fixture: global create succeeds') or diag("stderr: $r0->{err}");

    my $r1 = run_cli('edit', $id15, '--unset', 'covers', '--global', '--home', $HOMEC15);
    is($r1->{rc}, 2, 'AC-15 (covers): edit --global --unset covers exits 2') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(field2($r1->{err}, 'detail'), 'missing_covers', 'AC-15 (covers): ...detail: missing_covers');

    my ($after15) = show_json($id15, '--global', '--home', $HOMEC15);
    is(ref($after15) eq 'HASH' ? $after15->{fields}{covers} : undef, 'will be unset', 'AC-15 (covers): covers is unchanged after the refused unset');
}

# -----------------------------------------------------------------------
# AC-16 (covers)/B14+B15 -- a legacy global note with no covers can still
# be edited (as long as the edit doesn't touch covers); project-scope
# create/edit with an over-budget covers still exits 0 (no project budget).
# -----------------------------------------------------------------------
{
    my $HOMEC16 = tempdir(CLEANUP => 1); $HOMEC16 =~ s{\\}{/}g;
    # Build a "legacy" global note with NO covers at all by hand-tampering
    # the on-disk frontmatter after a (covers-satisfying) create -- the CLI
    # itself can never construct this shape going forward, which is exactly
    # why it is a hand-made fixture rather than a plain create.
    my $r0 = run_cli('create', '--title', 'Legacy Global', '--covers', 'temporary', '--global', '--home', $HOMEC16);
    my $id16 = field0($r0->{out}, 'id');
    ok(defined $id16, 'AC-16 (covers) fixture: global create succeeds') or diag("stderr: $r0->{err}");
    my $GDIR16 = record_dir($HOMEC16, 'global');
    remove_frontmatter_field("$GDIR16/$id16.md", 'covers');
    my ($legacy_before) = show_json($id16, '--global', '--home', $HOMEC16);
    ok(ref($legacy_before) eq 'HASH' && !exists($legacy_before->{fields}{covers}),
        'AC-16 (covers) fixture: the legacy note now has no covers field at all');

    my $r1 = run_cli('edit', $id16, '--title', 'Legacy Global Edited', '--global', '--home', $HOMEC16);
    is($r1->{rc}, 0, 'AC-16 (covers)/B14: editing a legacy covers-less global note (without touching covers) exits 0')
        or diag("stderr: $r1->{err}");

    my $ROOTC16 = tempdir(CLEANUP => 1); $ROOTC16 =~ s{\\}{/}g;
    my $big = 'p' x 300;
    my $r2 = run_cli('create', '--title', 'Project Big Covers', '--covers', $big, '--root', $ROOTC16);
    is($r2->{rc}, 0, 'AC-16 (covers)/B15: project create with a 300-byte covers exits 0 (no project budget)')
        or diag("stderr: $r2->{err}");
    my $id16p = field0($r2->{out}, 'id');
    my $r3 = run_cli('edit', $id16p, '--covers', $big, '--root', $ROOTC16);
    is($r3->{rc}, 0, 'AC-16 (covers)/B15: project edit with a 300-byte covers exits 0 (no project budget)')
        or diag("stderr: $r3->{err}");
}

# -----------------------------------------------------------------------
# AC-21 (delete)/B19,B22,B23 -- content removal is refused (content: kept,
# nothing touched) for: an internal-labelled target OUTSIDE the notes dir;
# a record with promote_to set; and a directory occupying the content path.
# -----------------------------------------------------------------------
{
    my $ROOTC21 = tempdir(CLEANUP => 1); $ROOTC21 =~ s{\\}{/}g;
    my $DIR21 = record_dir($ROOTC21, 'project');

    # B19: audience internal, target hand-tampered to point OUTSIDE the
    # notes dir (the CLI itself can never construct this shape).
    mkdir(norm_path($ROOTC21) . '/docs') unless -d (norm_path($ROOTC21) . '/docs');
    my $r19 = run_cli('create', '--title', 'B19 outside notes dir', '--root', $ROOTC21);
    my $id19 = field0($r19->{out}, 'id');
    ok(defined $id19, 'AC-21 (B19) fixture: create succeeds') or diag("stderr: $r19->{err}");
    set_frontmatter_field("$DIR21/$id19.md", 'target', 'docs/outside.md');
    my $outside_path = norm_path($ROOTC21) . '/docs/outside.md';
    open(my $fh19, '>:raw', $outside_path) or die "fixture: cannot seed $outside_path: $!";
    print {$fh19} 'outside bytes';
    close $fh19;
    my $rdel19 = run_cli('delete', $id19, '--root', $ROOTC21);
    is($rdel19->{rc}, 0, 'AC-21 (B19): delete of an internal-labelled, outside-notes-dir target exits 0') or diag("stderr: $rdel19->{err}");
    ok(-f $outside_path, 'AC-21 (B19): the outside-notes-dir file still exists');
    is(slurp_raw($outside_path), 'outside bytes', 'AC-21 (B19): its bytes are unchanged');
    like($rdel19->{out}, qr/^content: kept$/m, 'AC-21 (B19): STDOUT carries content: kept');

    # B22: promote_to set on an internal note -- nothing removed.
    my $r22 = run_cli('create', '--title', 'B22 promote in flight', '--content', 'b22 bytes', '--root', $ROOTC21);
    my $id22 = field0($r22->{out}, 'id');
    ok(defined $id22, 'AC-21 (B22) fixture: create succeeds') or diag("stderr: $r22->{err}");
    set_frontmatter_field("$DIR21/$id22.md", 'promote_to', 'docs/wip.md');
    my $target22 = internal_dir($ROOTC21, 'project') . "/$id22.md";
    ok(-f $target22, 'AC-21 (B22) fixture: the content file exists before delete');
    my $rdel22 = run_cli('delete', $id22, '--root', $ROOTC21);
    is($rdel22->{rc}, 0, 'AC-21 (B22): delete of a note with promote_to set exits 0') or diag("stderr: $rdel22->{err}");
    ok(-f $target22, 'AC-21 (B22): the content file still exists (promote in flight)');
    is(slurp_raw($target22), 'b22 bytes', 'AC-21 (B22): its bytes are unchanged');
    like($rdel22->{out}, qr/^content: kept$/m, 'AC-21 (B22): STDOUT carries content: kept');

    # B23: a DIRECTORY occupies the content path.
    my $r23 = run_cli('create', '--title', 'B23 directory at path', '--root', $ROOTC21);
    my $id23 = field0($r23->{out}, 'id');
    ok(defined $id23, 'AC-21 (B23) fixture: create succeeds') or diag("stderr: $r23->{err}");
    my $target23 = internal_dir($ROOTC21, 'project') . "/$id23.md";
    unlink($target23) if -f $target23;
    mkdir($target23) or diag("could not mkdir $target23: $!");
    open(my $fh23, '>:raw', "$target23/inner.txt") or die "fixture: cannot write inner file: $!";
    print {$fh23} 'inner bytes';
    close $fh23;
    my $rdel23 = run_cli('delete', $id23, '--root', $ROOTC21);
    is($rdel23->{rc}, 0, 'AC-21 (B23): delete when a directory occupies the content path exits 0') or diag("stderr: $rdel23->{err}");
    ok(-d $target23, 'AC-21 (B23): the directory still exists');
    ok(-f "$target23/inner.txt", 'AC-21 (B23): its contents survive');
    like($rdel23->{out}, qr/^content: kept$/m, 'AC-21 (B23): STDOUT carries content: kept');
}

# -----------------------------------------------------------------------
# AC-22 (delete)/B20 -- an internal note whose content file is already
# gone (out of band): delete exits 0, content: absent.
# -----------------------------------------------------------------------
{
    my $ROOTC22 = tempdir(CLEANUP => 1); $ROOTC22 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'B20 already gone', '--root', $ROOTC22);
    my $id20 = field0($r0->{out}, 'id');
    ok(defined $id20, 'AC-22 (B20) fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $target20 = internal_dir($ROOTC22, 'project') . "/$id20.md";
    unlink($target20) if -f $target20;
    ok(!-f $target20, 'AC-22 (B20) fixture: the content file was removed out of band');
    my $rdel20 = run_cli('delete', $id20, '--root', $ROOTC22);
    is($rdel20->{rc}, 0, 'AC-22 (B20): delete exits 0 when the content file is already absent') or diag("stderr: $rdel20->{err}");
    like($rdel20->{out}, qr/^content: absent$/m, 'AC-22 (B20): STDOUT carries content: absent');
}

# =============================================================================
# AC-49 -- at least ten distinct failure invocations, each exits exactly 2
# and prints zero bytes on STDOUT.
# =============================================================================
{
    my $ROOT49 = tempdir(CLEANUP => 1);
    $ROOT49 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'seed49', '--root', $ROOT49);
    my $seed_id = field0($r0->{out}, 'id');

    my @failures = (
        ['frobnicate',                                                        'unknown verb'],
        ['show', 'no-such-id',                                                'show unknown id'],
        ['create',                                                            'create with no title'],
        ['create', '--id', 'a/b', '--title', 'x',                             'create with bad id'],
        ['edit', $seed_id // 'x',                                             'edit with no mutating flag'],
        ['edit', $seed_id // 'x', '--set', 'audience=external',               'edit reserved audience'],
        ['delete', 'no-such-id',                                              'delete unknown id'],
        ['list', '--project', '--global',                                    'list with conflicting scope flags'],
        ['create', '--title', 'x', '--audience', 'sideways',                 'create with bad audience'],
        ['create', '--title', 'x', '--target', '../escape.md',               'create with escaping target'],
    );
    for my $case (@failures) {
        my ($label, @cmd_args_and_label) = @$case;
        my @args = @$case;
        my $label_text = pop @args;
        my $r = run_cli(@args, '--root', $ROOT49);
        is($r->{rc}, 2, "AC-49: [$label_text] exits exactly 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is($r->{out}, '', "AC-49: [$label_text] prints zero bytes on STDOUT");
    }
}

# =============================================================================
# Live-store sanity, again, at the end (AC-50).
# =============================================================================
{
    my $live_after       = count_md_in($LIVE_NOTE_STORE);
    my $live_notes_after = count_md_in($LIVE_NOTES_DIR);
    is($live_after, $live_before,
       "AC-50: live note store's record count is unchanged by this suite ($live_before before, $live_after after)");
    # Presence of ac2-target.md is never REQUIRED (Decision 120(c)) -- only,
    # if it was there before this suite ran, that it is still there after.
    SKIP: {
        skip('ac2-target.md was not present before this suite ran -- nothing to protect', 1)
            unless $ac2_target_existed_before;
        ok(-f "$LIVE_NOTE_STORE/ac2-target.md", 'AC-50: the pre-existing ac2-target.md fixture survives untouched');
    }
    is($live_notes_after, $live_notes_before,
       "AC-50: the repo's own .ccpraxis-local-data/notes/ gains nothing ($live_notes_before before, $live_notes_after after)");
}

done_testing();
