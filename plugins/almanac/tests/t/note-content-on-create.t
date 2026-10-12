#!/usr/bin/env perl
# platform: any
# Oracle for bug 1a32 (blueprint tooling-fixes, package 02-note-content-on-
# create): almanac-note.pl create's materialize branch must fall back to the
# resolved --body when no --content/--content-file is given (today it writes
# only content-or-empty, so a --body-only create indexes a 0-byte target);
# edit gains --content/--content-file/--force-external. See
# specs/02-note-content-on-create-spec.md, acceptance criteria AC-1..AC-19.
#
# ISOLATION: every fixture is a fresh File::Temp tempdir reached only through
# --root/--home, or through Almanac::Note::check_pointers(root=>,home=>)'s
# own arguments. HOME and ALMANAC_HOME are overridden for this whole process
# (and therefore every child `perl almanac-note.pl` it spawns) to a synthetic
# fixture directory, so no code path that forgets an explicit --home can ever
# fall through to the operator's real ~/.claude vault or this repo's own
# .ccpraxis-local-data/almanac. This file never reads or writes the real
# vault or the real project almanac.
#
# HOUSE PATTERN (almanac-note-crud.t): every assertion below is expected to
# fail for exactly "missing/wrong behaviour", not for a fixture defect of
# this file's own making -- run_cli()/eval-wrapped calls make an unbuilt
# feature a reported failure, not an aborted file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(remove_tree);
use Cwd ();
use Encode ();
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $NOTE_PL = "$S/almanac-note.pl";
(my $REPO = "$Bin/../../../..") =~ s{\\}{/}g;
my $GLOBAL_CLAUDE_MD = "$REPO/global-config/CLAUDE.md";

# ISOLATION: see file header. Applies to every `perl almanac-note.pl` child
# process spawned below via run_cli()/run_cli_stdin(), and to every direct
# Almanac::Note::check_pointers() call that omits `home =>`.
my $FIXTURE_HOME = tempdir(CLEANUP => 1);
$FIXTURE_HOME =~ s{\\}{/}g;
local $ENV{HOME}          = $FIXTURE_HOME;
local $ENV{ALMANAC_HOME}  = $FIXTURE_HOME;
local $ENV{USERPROFILE}   = $FIXTURE_HOME;

# ---------------------------------------------------------------------------
# scaffolding (mirrors almanac-note-crud.t's conventions)
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

# _run($stdin_or_undef, @args) -> { rc, out, err }
sub _run {
    my ($stdin, @args) = @_;
    my (undef, $inpath)  = tempfile(UNLINK => 1);
    if (defined $stdin) {
        open(my $fh, '>:raw', $inpath) or die "fixture: cannot write stdin fixture $inpath: $!";
        print {$fh} $stdin;
        close $fh;
    }
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$NOTE_PL" $argstr < "$inpath" > "$outpath" 2> "$errpath"});
    my $rc  = $? >> 8;
    my $out = slurp_text($outpath);
    my $err = slurp_text($errpath);
    return { rc => $rc, out => (defined $out ? $out : ''), err => (defined $err ? $err : '') };
}
sub run_cli       { return _run(undef, @_) }
sub run_cli_stdin { my ($stdin, @args) = @_; return _run($stdin, @args) }

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

sub decode_json_or_undef {
    my ($text) = @_;
    my $decoded = eval { JSON::PP->new->decode($text) };
    return $decoded;
}

sub show_json {
    my ($id, @extra) = @_;
    my $r = run_cli('show', $id, '--json', @extra);
    return (decode_json_or_undef($r->{out}), $r);
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
    my ($dir) = @_;
    return wantarray ? () : 0 unless -d $dir;
    opendir(my $dh, $dir) or return wantarray ? () : 0;
    my @f = grep { /\.md\z/ } readdir($dh);
    closedir $dh;
    return @f;
}

ok(-f $NOTE_PL, 'almanac-note.pl exists at plugins/almanac/scripts/almanac-note.pl')
    or diag('almanac-note.pl is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

# do the file once so Almanac::Note::check_pointers() can be called directly
# (house pattern, almanac-note-crud.t AC-27/AC-28).
do $NOTE_PL if -f $NOTE_PL;

# =============================================================================
# AC-1 -- create --body only: target non-empty, byte-equal to body; show
# --json body equals.
# =============================================================================
{
    my $R1 = tempdir(CLEANUP => 1); $R1 =~ s{\\}{/}g;
    my $r = run_cli('create', '--title', 'AC1', '--body', 'fact one', '--root', $R1);
    is($r->{rc}, 0, 'AC-1: create --title --body exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    my $id = field0($r->{out}, 'id');
    ok(defined $id, 'AC-1: result block carries an id') or diag("stdout: $r->{out}");
    my $tf = internal_dir($R1, 'project') . "/$id.md";
    ok(-f $tf, 'AC-1: the target file exists');
    my $bytes = slurp_raw($tf);
    ok(defined $bytes && length($bytes) > 0, 'AC-1: the target file is non-empty');
    is($bytes, 'fact one', 'AC-1: the target file\'s bytes are byte-equal to the body');
    my ($j) = show_json($id, '--root', $R1);
    is(ref($j) eq 'HASH' ? $j->{body} : undef, 'fact one', 'AC-1: show --json body equals the body');
}

# =============================================================================
# AC-2 -- create --body - with stdin: target bytes == stdin == record body
# (the bug's exact invocation).
# =============================================================================
{
    my $R2 = tempdir(CLEANUP => 1); $R2 =~ s{\\}{/}g;
    my $stdin_body = "fact via stdin\n";
    my $r = run_cli_stdin($stdin_body, 'create', '--title', 'AC2', '--body', '-', '--root', $R2);
    is($r->{rc}, 0, 'AC-2: create --body - exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    my $id = field0($r->{out}, 'id');
    ok(defined $id, 'AC-2: result block carries an id') or diag("stdout: $r->{out}");
    my $tf = internal_dir($R2, 'project') . "/$id.md";
    is(slurp_raw($tf), $stdin_body, 'AC-2: the target file\'s bytes equal stdin (bug 1a32\'s exact repro)');
    my ($j) = show_json($id, '--root', $R2);
    is(ref($j) eq 'HASH' ? $j->{body} : undef, $stdin_body, 'AC-2: the record body also equals stdin');
}

# =============================================================================
# AC-3 -- create --body-file F: target bytes == F's bytes.
# =============================================================================
{
    my $R3 = tempdir(CLEANUP => 1); $R3 =~ s{\\}{/}g;
    my ($bfh, $bodyfile) = tempfile();
    binmode($bfh, ':raw');
    print {$bfh} "body from file\nwith a second line";
    close $bfh;
    my $r = run_cli('create', '--title', 'AC3', '--body-file', $bodyfile, '--root', $R3);
    is($r->{rc}, 0, 'AC-3: create --body-file exits 0') or diag("stderr: $r->{err}");
    my $id = field0($r->{out}, 'id');
    my $tf = internal_dir($R3, 'project') . "/$id.md";
    is(slurp_raw($tf), "body from file\nwith a second line", 'AC-3: the target file\'s bytes equal the body file\'s bytes');
}

# =============================================================================
# AC-4 -- create --content C: target == C, record has no body.
# =============================================================================
{
    my $R4 = tempdir(CLEANUP => 1); $R4 =~ s{\\}{/}g;
    my $r = run_cli('create', '--title', 'AC4', '--content', 'the content', '--root', $R4);
    is($r->{rc}, 0, 'AC-4: create --content exits 0') or diag("stderr: $r->{err}");
    my $id = field0($r->{out}, 'id');
    my $tf = internal_dir($R4, 'project') . "/$id.md";
    is(slurp_raw($tf), 'the content', 'AC-4: the target file\'s bytes equal --content');
    my ($j) = show_json($id, '--root', $R4);
    ok(ref($j) eq 'HASH', 'AC-4: show --json decodes') or diag('not a hashref');
    ok(!defined($j->{body}) || $j->{body} eq '', 'AC-4: the record has no body (undef or empty)') if ref($j) eq 'HASH';
}

# =============================================================================
# AC-5 -- create --body B --content C (B ne C): target == C, record body ==
# B. Repeated with --content-file.
# =============================================================================
{
    my $R5 = tempdir(CLEANUP => 1); $R5 =~ s{\\}{/}g;
    my $r = run_cli('create', '--title', 'AC5a', '--body', 'body text', '--content', 'content text', '--root', $R5);
    is($r->{rc}, 0, 'AC-5: create --body B --content C exits 0') or diag("stderr: $r->{err}");
    my $id = field0($r->{out}, 'id');
    my $tf = internal_dir($R5, 'project') . "/$id.md";
    is(slurp_raw($tf), 'content text', 'AC-5: the target equals --content (content wins for the target)');
    my ($j) = show_json($id, '--root', $R5);
    is(ref($j) eq 'HASH' ? $j->{body} : undef, 'body text', 'AC-5: the record body equals --body');

    my ($cfh, $contentfile) = tempfile();
    binmode($cfh, ':raw');
    print {$cfh} 'content from file';
    close $cfh;
    my $r2 = run_cli('create', '--title', 'AC5b', '--body', 'body text 2', '--content-file', $contentfile, '--root', $R5);
    is($r2->{rc}, 0, 'AC-5: create --body B --content-file F exits 0') or diag("stderr: $r2->{err}");
    my $id2 = field0($r2->{out}, 'id');
    my $tf2 = internal_dir($R5, 'project') . "/$id2.md";
    is(slurp_raw($tf2), 'content from file', 'AC-5: the target equals --content-file\'s bytes');
    my ($j2) = show_json($id2, '--root', $R5);
    is(ref($j2) eq 'HASH' ? $j2->{body} : undef, 'body text 2', 'AC-5: the record body equals --body (with --content-file)');
}

# =============================================================================
# AC-6 -- create with neither --body nor --content: target exists, 0 bytes
# (Decision 6(12) boundary -- unchanged, but pinned here too).
# =============================================================================
{
    my $R6 = tempdir(CLEANUP => 1); $R6 =~ s{\\}{/}g;
    my $r = run_cli('create', '--title', 'AC6', '--root', $R6);
    is($r->{rc}, 0, 'AC-6: create with neither --body nor --content exits 0') or diag("stderr: $r->{err}");
    my $id = field0($r->{out}, 'id');
    my $tf = internal_dir($R6, 'project') . "/$id.md";
    ok(-f $tf, 'AC-6: the target file exists');
    is(slurp_raw($tf), '', 'AC-6: the target file is 0 bytes');
}

# =============================================================================
# AC-7 -- explicit --target: not created, not touched, regardless of --body.
# =============================================================================
{
    my $R7 = tempdir(CLEANUP => 1); $R7 =~ s{\\}{/}g;
    my $r = run_cli('create', '--title', 'AC7a', '--target', '.ccpraxis-local-data/notes/mine.md', '--body', 'B', '--root', $R7);
    is($r->{rc}, 0, 'AC-7: create --target (internal, explicit) --body B exits 0') or diag("stderr: $r->{err}");
    my $id = field0($r->{out}, 'id');
    my ($j) = show_json($id, '--root', $R7);
    is(ref($j) eq 'HASH' ? $j->{body} : undef, 'B', 'AC-7: the record body equals --body');
    ok(!-f (norm_path($R7) . '/.ccpraxis-local-data/notes/mine.md'), 'AC-7: no file is created at the explicit internal target path');

    my $r2 = run_cli('create', '--title', 'AC7b', '--audience', 'external', '--target', 'docs/x.md', '--body', 'B', '--root', $R7);
    is($r2->{rc}, 0, 'AC-7: create --audience external --target --body B exits 0') or diag("stderr: $r2->{err}");
    ok(!-f (norm_path($R7) . '/docs/x.md'), 'AC-7: no file is created under <root>/docs/ for an explicit external target');
}

# =============================================================================
# AC-8 -- create --body - --content -: exit 2, stdin_conflict, no record, no
# target file.
# =============================================================================
{
    my $R8 = tempdir(CLEANUP => 1); $R8 =~ s{\\}{/}g;
    my $r = run_cli_stdin('irrelevant stdin', 'create', '--title', 'AC8', '--body', '-', '--content', '-', '--root', $R8);
    is($r->{rc}, 2, 'AC-8: create --body - --content - exits 2') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(err_kind($r->{err}), 'usage', 'AC-8: ...with kind: usage');
    is(field2($r->{err}, 'detail'), 'stdin_conflict', 'AC-8: ...and detail: stdin_conflict');
    my $DIR8 = record_dir($R8, 'project');
    is(scalar(list_md_files($DIR8)), 0, 'AC-8: no record was written under the note store');
    my $NOTES8 = internal_dir($R8, 'project');
    is(scalar(list_md_files($NOTES8)), 0, 'AC-8: no file was written under notes/');
}

# =============================================================================
# AC-9 -- edit <id> --content X replaces the target only, body untouched.
# Then edit <id> --content-file F (binary) replaces the target with F's
# bytes.
# =============================================================================
my ($AC9_ROOT, $AC9_ID, $AC9_TARGET);
{
    $AC9_ROOT = tempdir(CLEANUP => 1); $AC9_ROOT =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'AC9', '--body', 'B0', '--root', $AC9_ROOT);
    is($r0->{rc}, 0, 'AC-9 fixture: create --body B0 exits 0') or diag("stderr: $r0->{err}");
    $AC9_ID = field0($r0->{out}, 'id');
    $AC9_TARGET = internal_dir($AC9_ROOT, 'project') . "/$AC9_ID.md";

    my $r1 = run_cli('edit', $AC9_ID, '--content', 'X', '--root', $AC9_ROOT);
    is($r1->{rc}, 0, 'AC-9: edit <id> --content X exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(slurp_raw($AC9_TARGET), 'X', 'AC-9: the target now equals --content');
    my ($j1) = show_json($AC9_ID, '--root', $AC9_ROOT);
    is(ref($j1) eq 'HASH' ? $j1->{body} : undef, 'B0', 'AC-9: the record body is still B0');

    my ($cfh, $contentfile) = tempfile();
    binmode($cfh, ':raw');
    print {$cfh} "bin\x00ary\n";
    close $cfh;
    my $r2 = run_cli('edit', $AC9_ID, '--content-file', $contentfile, '--root', $AC9_ROOT);
    is($r2->{rc}, 0, 'AC-9: edit <id> --content-file F exits 0') or diag("stdout: $r2->{out}\nstderr: $r2->{err}");
    is(slurp_raw($AC9_TARGET), "bin\x00ary\n", 'AC-9: the target now equals the content file\'s bytes (NULs included)');
}

# =============================================================================
# AC-10 -- edit --body B1 alone: record body == B1, target byte-identical to
# before (compare full bytes).
# =============================================================================
{
    my $R10 = tempdir(CLEANUP => 1); $R10 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'AC10', '--content', 'original target bytes', '--root', $R10);
    is($r0->{rc}, 0, 'AC-10 fixture: create --content exits 0') or diag("stderr: $r0->{err}");
    my $id = field0($r0->{out}, 'id');
    my $tf = internal_dir($R10, 'project') . "/$id.md";
    my $before = slurp_raw($tf);

    my $r1 = run_cli('edit', $id, '--body', 'B1', '--root', $R10);
    is($r1->{rc}, 0, 'AC-10: edit --body B1 alone exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    my ($j) = show_json($id, '--root', $R10);
    is(ref($j) eq 'HASH' ? $j->{body} : undef, 'B1', 'AC-10: the record body equals B1');
    is(slurp_raw($tf), $before, 'AC-10: the target\'s bytes are byte-identical to before the body-only edit');
}

# =============================================================================
# AC-11 -- edit --body B2 --content X2: record body == B2, target == X2.
# =============================================================================
{
    my $R11 = tempdir(CLEANUP => 1); $R11 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'AC11', '--body', 'orig body', '--root', $R11);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'AC-11 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $tf = internal_dir($R11, 'project') . "/$id.md";

    my $r1 = run_cli('edit', $id, '--body', 'B2', '--content', 'X2', '--root', $R11);
    is($r1->{rc}, 0, 'AC-11: edit --body B2 --content X2 exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    my ($j) = show_json($id, '--root', $R11);
    is(ref($j) eq 'HASH' ? $j->{body} : undef, 'B2', 'AC-11: the record body equals B2');
    is(slurp_raw($tf), 'X2', 'AC-11: the target equals X2');
}

# =============================================================================
# AC-12 -- external note: edit --content without --force-external is
# refused, byte-identical; edit --content --force-external succeeds.
# =============================================================================
{
    my $R12 = tempdir(CLEANUP => 1); $R12 =~ s{\\}{/}g;
    mkdir(norm_path($R12) . '/docs') unless -d (norm_path($R12) . '/docs');
    my $r0 = run_cli('create', '--title', 'AC12', '--audience', 'external', '--target', 'docs/x.md', '--root', $R12);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'AC-12 fixture: external create succeeds') or diag("stderr: $r0->{err}");
    my $extfile = norm_path($R12) . '/docs/x.md';
    open(my $fh, '>:raw', $extfile) or die "fixture: cannot seed external target: $!";
    print {$fh} 'user bytes';
    close $fh;
    my $DIR12 = record_dir($R12, 'project');
    my $recfile = "$DIR12/$id.md";
    my $before_file = slurp_raw($extfile);
    my $before_rec  = slurp_raw($recfile);

    my $r1 = run_cli('edit', $id, '--content', 'X', '--root', $R12);
    is($r1->{rc}, 2, 'AC-12: edit --content on an external note (no --force-external) exits 2') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'usage', 'AC-12: ...with kind: usage');
    is(field2($r1->{err}, 'detail'), 'external_target_refused', 'AC-12: ...and detail: external_target_refused');
    is(slurp_raw($extfile), $before_file, 'AC-12: the external file is byte-identical after the refusal');
    is(slurp_raw($recfile), $before_rec, 'AC-12: the record is byte-identical after the refusal');

    my $r2 = run_cli('edit', $id, '--content', 'X', '--force-external', '--root', $R12);
    is($r2->{rc}, 0, 'AC-12: edit --content --force-external exits 0') or diag("stdout: $r2->{out}\nstderr: $r2->{err}");
    is(slurp_raw($extfile), 'X', 'AC-12: the external file now equals X');
}

# =============================================================================
# AC-13 -- edit --force-external with no content: exit 2,
# force_external_without_content, record byte-identical.
# =============================================================================
{
    my $R13 = tempdir(CLEANUP => 1); $R13 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'AC13', '--body', 'orig', '--root', $R13);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'AC-13 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $DIR13 = record_dir($R13, 'project');
    my $recfile = "$DIR13/$id.md";
    my $before = slurp_raw($recfile);

    my $r1 = run_cli('edit', $id, '--force-external', '--root', $R13);
    is($r1->{rc}, 2, 'AC-13: edit --force-external with no content exits 2') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'usage', 'AC-13: ...with kind: usage');
    is(field2($r1->{err}, 'detail'), 'force_external_without_content', 'AC-13: ...and detail: force_external_without_content');
    is(slurp_raw($recfile), $before, 'AC-13: the record is byte-identical after the refusal');
}

# =============================================================================
# AC-14 -- edit --content X --expect-rev <stale>: exit 2, kind conflict,
# target and record byte-identical.
# =============================================================================
{
    my $R14 = tempdir(CLEANUP => 1); $R14 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'AC14', '--content', 'orig content', '--root', $R14);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'AC-14 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my ($cur) = show_json($id, '--root', $R14);
    my $stale_rev = (ref($cur) eq 'HASH') ? $cur->{rev} : ('d' x 64);
    # bump the rev with an unrelated edit so the captured rev becomes stale
    my $bump = run_cli('edit', $id, '--title', 'Bumped', '--root', $R14);
    is($bump->{rc}, 0, 'AC-14 fixture: an intervening edit succeeds, making the earlier rev stale') or diag("stderr: $bump->{err}");

    my $tf = internal_dir($R14, 'project') . "/$id.md";
    my $DIR14 = record_dir($R14, 'project');
    my $recfile = "$DIR14/$id.md";
    my $before_target = slurp_raw($tf);
    my $before_rec    = slurp_raw($recfile);

    my $r1 = run_cli('edit', $id, '--content', 'X', '--expect-rev', $stale_rev, '--root', $R14);
    is($r1->{rc}, 2, 'AC-14: edit --content X --expect-rev <stale> exits 2') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'conflict', 'AC-14: ...with kind: conflict');
    is(slurp_raw($tf), $before_target, 'AC-14: the target is byte-identical after the refused conflict edit');
    is(slurp_raw($recfile), $before_rec, 'AC-14: the record is byte-identical after the refused conflict edit');
}

# =============================================================================
# AC-15 -- dangling repair: delete an internal note's target, then edit
# --content X: exit 0, file exists with X, check-pointers reports ok.
# =============================================================================
{
    my $R15 = tempdir(CLEANUP => 1); $R15 =~ s{\\}{/}g;
    my $H15 = tempdir(CLEANUP => 1); $H15 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'AC15', '--body', 'orig', '--root', $R15);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'AC-15 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $tf = internal_dir($R15, 'project') . "/$id.md";
    unlink($tf) if -f $tf;
    ok(!-f $tf, 'AC-15 fixture: the target file was actually removed (note is now dangling)');

    my $r1 = run_cli('edit', $id, '--content', 'X', '--root', $R15);
    is($r1->{rc}, 0, 'AC-15: edit --content X on a dangling note exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    ok(-f $tf, 'AC-15: the target file exists again');
    is(slurp_raw($tf), 'X', 'AC-15: the repaired target equals X');

    my $c = eval { Almanac::Note::check_pointers(root => $R15, home => $H15) };
    ok(defined $c, 'AC-15: check_pointers() returns a value after the repair') or diag("error: $@");
    if (ref($c) eq 'HASH' && ref($c->{project}) eq 'HASH') {
        my ($e) = grep { $_->{id} eq $id } @{$c->{project}{pointers}};
        ok(ref($e) eq 'HASH' && $e->{status} eq 'ok', 'AC-15: check-pointers reports the repaired note as ok');
    }
}

# =============================================================================
# AC-16 -- aggregate: a fixture root exercising the AC-1..AC-5/AC-9..AC-12/
# AC-15 shapes reports project.dangling empty once the AC-7-style
# explicit-target notes are excluded by id, and every internal note from
# those shapes has status ok.
# =============================================================================
{
    my $R16 = tempdir(CLEANUP => 1); $R16 =~ s{\\}{/}g;
    my $H16 = tempdir(CLEANUP => 1); $H16 =~ s{\\}{/}g;
    mkdir(norm_path($R16) . '/docs') unless -d (norm_path($R16) . '/docs');
    my @internal_ids;
    my @excluded_ids;

    # AC-1 shape: --body only
    my $r1 = run_cli('create', '--title', 'ac16-1', '--body', 'b1', '--root', $R16);
    push @internal_ids, field0($r1->{out}, 'id');
    # AC-2 shape: --body -
    my $r2 = run_cli_stdin('stdin body', 'create', '--title', 'ac16-2', '--body', '-', '--root', $R16);
    push @internal_ids, field0($r2->{out}, 'id');
    # AC-3 shape: --body-file
    my ($bfh, $bodyfile) = tempfile();
    print {$bfh} 'body file bytes';
    close $bfh;
    my $r3 = run_cli('create', '--title', 'ac16-3', '--body-file', $bodyfile, '--root', $R16);
    push @internal_ids, field0($r3->{out}, 'id');
    # AC-4 shape: --content
    my $r4 = run_cli('create', '--title', 'ac16-4', '--content', 'c4', '--root', $R16);
    push @internal_ids, field0($r4->{out}, 'id');
    # AC-5 shape: --body + --content
    my $r5 = run_cli('create', '--title', 'ac16-5', '--body', 'b5', '--content', 'c5', '--root', $R16);
    push @internal_ids, field0($r5->{out}, 'id');
    # AC-9 shape: create then edit --content
    my $r9c = run_cli('create', '--title', 'ac16-9', '--body', 'b9', '--root', $R16);
    my $id9 = field0($r9c->{out}, 'id');
    run_cli('edit', $id9, '--content', 'c9', '--root', $R16);
    push @internal_ids, $id9;
    # AC-10 shape: create then edit --body alone
    my $r10c = run_cli('create', '--title', 'ac16-10', '--content', 'c10', '--root', $R16);
    my $id10 = field0($r10c->{out}, 'id');
    run_cli('edit', $id10, '--body', 'b10', '--root', $R16);
    push @internal_ids, $id10;
    # AC-11 shape: create then edit --body + --content
    my $r11c = run_cli('create', '--title', 'ac16-11', '--body', 'b11', '--root', $R16);
    my $id11 = field0($r11c->{out}, 'id');
    run_cli('edit', $id11, '--body', 'b11b', '--content', 'c11', '--root', $R16);
    push @internal_ids, $id11;
    # AC-12 shape: external note, edit --content --force-external (internal
    # to the aggregate check we only assert on internal-audience notes, so
    # this one is tracked separately and not asserted ok below -- external
    # notes with a materialized file are 'ok' too, but that shape belongs to
    # AC-12, not this aggregate).
    my $r12c = run_cli('create', '--title', 'ac16-12', '--audience', 'external', '--target', 'docs/ac16-12.md', '--root', $R16);
    my $id12 = field0($r12c->{out}, 'id');
    open(my $efh, '>:raw', norm_path($R16) . '/docs/ac16-12.md') or die $!;
    print {$efh} 'seed';
    close $efh;
    run_cli('edit', $id12, '--content', 'c12', '--force-external', '--root', $R16);
    push @internal_ids, $id12;
    # AC-15 shape: dangling repair
    my $r15c = run_cli('create', '--title', 'ac16-15', '--body', 'b15', '--root', $R16);
    my $id15 = field0($r15c->{out}, 'id');
    my $tf15 = internal_dir($R16, 'project') . "/$id15.md";
    unlink($tf15) if -f $tf15;
    run_cli('edit', $id15, '--content', 'c15', '--root', $R16);
    push @internal_ids, $id15;

    # AC-7 shape: explicit target, dangling by design -- excluded by id.
    my $r7 = run_cli('create', '--title', 'ac16-7', '--target', '.ccpraxis-local-data/notes/ac16-explicit.md', '--body', 'b7', '--root', $R16);
    push @excluded_ids, field0($r7->{out}, 'id');

    ok((grep { defined } @internal_ids) == scalar(@internal_ids), 'AC-16 fixture: every internal-shape create/edit returned an id')
        or diag('ids: ' . join(',', map { $_ // '(undef)' } @internal_ids));

    my $c = eval { Almanac::Note::check_pointers(root => $R16, home => $H16) };
    ok(defined $c, 'AC-16: check_pointers() returns a value') or diag("error: $@");
    if (ref($c) eq 'HASH' && ref($c->{project}) eq 'HASH') {
        my %excluded = map { $_ => 1 } @excluded_ids;
        my @dangling_minus_excluded = grep { !$excluded{$_->{id}} } @{$c->{project}{dangling}};
        is(scalar(@dangling_minus_excluded), 0,
            'AC-16: project.dangling is empty once the AC-7-style explicit-target notes are excluded by id')
            or diag('unexpected dangling ids: ' . join(',', map { $_->{id} } @dangling_minus_excluded));
        my $ac16_idx = 0;
        for my $id (@internal_ids) {
            $ac16_idx++;
            my ($e) = grep { $_->{id} eq $id } @{$c->{project}{pointers}};
            ok(ref($e) eq 'HASH' && $e->{status} eq 'ok', "AC-16: internal note #$ac16_idx has status ok")
                or diag("id=$id entry: " . (ref($e) eq 'HASH' ? JSON::PP->new->encode($e) : 'MISSING'));
        }
    }
}

# =============================================================================
# AC-17 -- edit <id> --content (bare, last): missing_flag_value. edit <id>
# --content X --content-file F: content_conflict.
# =============================================================================
{
    my $R17 = tempdir(CLEANUP => 1); $R17 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'AC17', '--root', $R17);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'AC-17 fixture: create succeeds') or diag("stderr: $r0->{err}");

    my $r1 = run_cli('edit', '--root', $R17, $id, '--content');
    is($r1->{rc}, 2, 'AC-17: edit <id> --content (bare, last) exits 2') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(field2($r1->{err}, 'detail'), 'missing_flag_value', 'AC-17: ...detail: missing_flag_value');

    my ($cfh, $contentfile) = tempfile();
    print {$cfh} 'x';
    close $cfh;
    my $r2 = run_cli('edit', $id, '--content', 'X', '--content-file', $contentfile, '--root', $R17);
    is($r2->{rc}, 2, 'AC-17: edit --content X --content-file F exits 2') or diag("stdout: $r2->{out}\nstderr: $r2->{err}");
    is(field2($r2->{err}, 'detail'), 'content_conflict', 'AC-17: ...detail: content_conflict');
}

# almanac-note-crud.t stays green through this package's own test_paths (tooling-fixes 06); no
# assertion runs it here.

# almanac-migrate-memories.t stays green through this package's own test_paths (tooling-fixes 06);
# no assertion runs it here.
# =============================================================================
# AC-19 -- global-config/CLAUDE.md contains the substring naming --content -.
# =============================================================================
{
    ok(-f $GLOBAL_CLAUDE_MD, 'AC-19 precondition: global-config/CLAUDE.md exists');
    my $global_text = slurp_text($GLOBAL_CLAUDE_MD);
    like($global_text // '', qr/\Qalmanac-note.pl create --global --title "..." --content -\E/,
        'AC-19: global-config/CLAUDE.md contains the --content - substring')
        or diag('not found in global-config/CLAUDE.md');
}

# =============================================================================
# S1 (regression -- review .ccpraxis-local-data/blueprints/tooling-fixes/
# reports/02-review.md, SHOULD-1) -- edit's step-7 cleanup (spec 3.2 step 7:
# "on any failure, unlink the temp file") must remove ONLY a temp file this
# invocation itself created, as a plain file. If "$target_abs.tmp.$$" is
# already occupied by a DIRECTORY (a foreign name collision) when the
# content-write open() fails, that failure must still be reported as an io
# error, but the colliding directory -- and everything inside it -- must
# survive untouched. Today's cleanup is an unconditional
# `File::Path::remove_tree($tmp) if -e $tmp`, which deletes the directory
# recursively: a strictly larger capability than "unlink the temp file".
#
# Driven IN-PROCESS via Almanac::Note::_cmd_edit (loaded by this file's own
# `do $NOTE_PL` above), not via run_cli()'s subprocess: the temp name is
# spec-defined as "$target_abs.tmp.$$" (3.2 step 7), and a subprocess's own
# $$ cannot be learned before its open() call runs, so only calling in this
# process -- where $$ is already known -- lets the fixture pre-occupy the
# exact colliding path deterministically.
# =============================================================================
{
    my $RS1 = tempdir(CLEANUP => 1); $RS1 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'S1', '--content', 'orig content', '--root', $RS1);
    is($r0->{rc}, 0, 'S1 fixture: create --content exits 0') or diag("stderr: $r0->{err}");
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'S1 fixture: create returned an id') or diag("stdout: $r0->{out}");
    my $tf = internal_dir($RS1, 'project') . "/$id.md";
    ok(-f $tf, 'S1 fixture: the target file exists before the collision');

    my $collision_dir = "$tf.tmp.$$";
    ok(!-e $collision_dir, 'S1 fixture: the collision path does not exist yet');
    mkdir($collision_dir) or die "fixture: cannot mkdir $collision_dir: $!";
    my $survivor = "$collision_dir/keepme.txt";
    open(my $sfh, '>:raw', $survivor) or die "fixture: cannot write $survivor: $!";
    print {$sfh} 'do not delete me';
    close $sfh;
    ok(-d $collision_dir && -f $survivor,
        'S1 fixture: a directory holding a file now occupies the exact temp name almanac-note.pl will use');

    my $ok = eval { Almanac::Note::_cmd_edit('project', { root => $RS1, content => 'CRASH' }, [$id]) };
    my $err = $@;
    ok(!$ok, 'S1: edit --content whose temp name collides with a directory does not succeed')
        or diag('edit unexpectedly returned success');
    ok((ref($err) && eval { $err->isa('Almanac::Store::Error') }),
        'S1: the failure is an Almanac::Store::Error')
        or diag('got: ' . (defined($err) ? "$err" : '(undef)'));
    is((ref($err) eq 'Almanac::Store::Error' ? $err->{kind} : undef), 'io', 'S1: ...with kind: io')
        or diag('err: ' . (defined($err) ? "$err" : '(undef)'));

    ok(-d $collision_dir, 'S1: the colliding directory still exists after the failure')
        or diag("$collision_dir is gone -- it was recursively deleted");
    ok(-f $survivor, 'S1: the file inside the colliding directory still exists after the failure')
        or diag("$survivor is gone");
    is(slurp_raw($survivor), 'do not delete me',
        'S1: the file inside the colliding directory is byte-identical after the failure');
    is(slurp_raw($tf), 'orig content', 'S1: the original target file is unchanged after the failure');
}

# =============================================================================
# S2 (regression -- review 02-review.md, SHOULD-2) -- edit's target guard
# (spec 3.2 step 5) trusts a record's own `audience: internal` field and only
# checks the target's STRUCTURAL shape, not the audience-consistent
# `_validate_target` rule that an internal target must sit under the notes
# area. A record whose `audience` reads `internal` but whose `target` names
# a tracked file OUTSIDE the note store (this fixture's own CLAUDE.md-shaped
# file) must be refused by `edit --content` unless --force-external is given
# -- the same protection Decision 6(12) already gives a genuinely
# audience: external note. Spec 2.3 says such a record "would have to come
# from a hand edit or an older script version", so the fixture writes the
# record file directly, mirroring almanac-note-crud.t's AC-44 hand-written-
# record house pattern (this file's own header already notes seal state
# never blocks a plain read -- Store.pm's _load_record never checks it).
# =============================================================================
{
    my $RS2 = tempdir(CLEANUP => 1); $RS2 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'S2', '--body', 'orig', '--root', $RS2);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'S2 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $DIR = record_dir($RS2, 'project');
    my $recfile = "$DIR/$id.md";

    # A fixture-repo tracked file outside the note store, at <root>/CLAUDE.md
    # -- a plausible hand-edit target (spec 2.3's threat model).
    my $tracked = norm_path($RS2) . '/CLAUDE.md';
    open(my $tfh, '>:raw', $tracked) or die "fixture: cannot write $tracked: $!";
    print {$tfh} 'tracked instructions, not almanac-owned';
    close $tfh;

    my $before_rec = slurp_raw($recfile);
    ok(defined $before_rec, 'S2 fixture: the record file is readable before the hand edit');
    (my $rewritten = $before_rec) =~ s{^target: .*$}{target: CLAUDE.md}m;
    ok($rewritten =~ /^target: CLAUDE\.md$/m, 'S2 fixture: the hand-rewritten record carries target: CLAUDE.md')
        or diag("rewritten:\n$rewritten");
    open(my $wfh, '>:raw', $recfile) or die "fixture: cannot rewrite $recfile: $!";
    print {$wfh} $rewritten;
    close $wfh;

    my $before_tracked = slurp_raw($tracked);

    my $r1 = run_cli('edit', $id, '--content', 'X', '--root', $RS2);
    isnt($r1->{rc}, 0,
        'S2: edit --content on an internal-audience note whose target is a tracked file outside the note store is refused without --force-external')
        or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(slurp_raw($tracked), $before_tracked, 'S2: the tracked file is byte-identical after the refusal');
    is(slurp_raw($recfile), $rewritten, 'S2: the record is byte-identical after the refusal');
}

# =============================================================================
# S3 -- edit refusal paths the spec defines (3.2 step 5, 2.3) but AC-1..AC-19
# leave untested: promote_in_flight, malformed (bad audience),
# dest_parent_missing, and stdin_conflict on edit (only create's stdin_
# conflict is covered, at AC-8).
# =============================================================================

# S3a -- promote_in_flight: a record whose promote_to is journalled (phase 1
# of a real `promote` committed, phase 2 failed because the source file was
# already missing) refuses edit --content, byte-identical.
{
    my $R = tempdir(CLEANUP => 1); $R =~ s{\\}{/}g;
    mkdir(norm_path($R) . '/docs') unless -d (norm_path($R) . '/docs');
    my $r0 = run_cli('create', '--title', 'S3a', '--body', 'orig', '--root', $R);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'S3a fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $tf = internal_dir($R, 'project') . "/$id.md";
    unlink($tf) if -f $tf;
    ok(!-f $tf, 'S3a fixture: the source target is removed before promote runs');

    my $rp = run_cli('promote', $id, '--audience', 'external', '--target', 'docs/s3a-dest.md', '--root', $R);
    isnt($rp->{rc}, 0, 'S3a fixture: promote with a missing source file fails after journalling promote_to')
        or diag("stdout: $rp->{out}\nstderr: $rp->{err}");

    my $DIR = record_dir($R, 'project');
    my $recfile = "$DIR/$id.md";
    my $rec_after_promote = slurp_raw($recfile);
    like($rec_after_promote // '', qr{^promote_to: docs/s3a-dest\.md$}m,
        'S3a fixture: promote_to is journalled on the record despite the failed move')
        or diag("record: " . ($rec_after_promote // '(unreadable)'));

    my $r1 = run_cli('edit', $id, '--content', 'X', '--root', $R);
    is($r1->{rc}, 2, 'S3a: edit --content on a note with promote_to set exits 2')
        or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'usage', 'S3a: ...with kind: usage');
    is(field2($r1->{err}, 'detail'), 'promote_in_flight', 'S3a: ...and detail: promote_in_flight');
    is(slurp_raw($recfile), $rec_after_promote, 'S3a: the record is byte-identical after the refusal');
    ok(!-f $tf, 'S3a: the (still-missing) target is not created by the refused edit');
}

# S3b -- malformed: a record hand-rewritten with an audience that is neither
# internal nor external refuses edit --content.
{
    my $R = tempdir(CLEANUP => 1); $R =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'S3b', '--body', 'orig', '--root', $R);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'S3b fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $DIR = record_dir($R, 'project');
    my $recfile = "$DIR/$id.md";
    my $before = slurp_raw($recfile);
    (my $rewritten = $before) =~ s{^audience: internal$}{audience: bogus}m;
    ok($rewritten =~ /^audience: bogus$/m, 'S3b fixture: the hand-rewritten record carries audience: bogus')
        or diag("rewritten:\n$rewritten");
    open(my $wfh, '>:raw', $recfile) or die "fixture: cannot rewrite $recfile: $!";
    print {$wfh} $rewritten;
    close $wfh;
    my $tf = internal_dir($R, 'project') . "/$id.md";
    my $before_tf = slurp_raw($tf);

    my $r1 = run_cli('edit', $id, '--content', 'Z', '--root', $R);
    is($r1->{rc}, 2, 'S3b: edit --content on a record with a bad audience exits 2')
        or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'malformed', 'S3b: ...with kind: malformed');
    is(slurp_raw($recfile), $rewritten, 'S3b: the record is byte-identical after the refusal');
    is(slurp_raw($tf), $before_tf, 'S3b: the target is byte-identical after the refusal');
}

# S3c -- dest_parent_missing: an internal note whose target's parent
# directory has since been removed refuses edit --content, byte-identical.
{
    my $R = tempdir(CLEANUP => 1); $R =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'S3c', '--content', 'orig content', '--root', $R);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'S3c fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $tf = internal_dir($R, 'project') . "/$id.md";
    ok(-f $tf, 'S3c fixture: the target file exists');
    my $notes_dir = internal_dir($R, 'project');
    remove_tree($notes_dir);
    ok(!-d $notes_dir, 'S3c fixture: the target\'s parent directory no longer exists');

    my $DIR = record_dir($R, 'project');
    my $recfile = "$DIR/$id.md";
    my $before_rec = slurp_raw($recfile);

    my $r1 = run_cli('edit', $id, '--content', 'Y', '--root', $R);
    is($r1->{rc}, 2, 'S3c: edit --content whose target parent directory is missing exits 2')
        or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'usage', 'S3c: ...with kind: usage');
    is(field2($r1->{err}, 'detail'), 'dest_parent_missing', 'S3c: ...and detail: dest_parent_missing');
    is(slurp_raw($recfile), $before_rec, 'S3c: the record is byte-identical after the refusal');
    ok(!-d $notes_dir, 'S3c: the parent directory is still missing (not recreated by the refused edit)');
}

# S3d -- stdin_conflict on edit (only create's is covered by AC-8): edit <id>
# --body - --content - exits 2, detail stdin_conflict, record and target
# byte-identical.
{
    my $R = tempdir(CLEANUP => 1); $R =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'S3d', '--body', 'orig', '--root', $R);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'S3d fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $tf = internal_dir($R, 'project') . "/$id.md";
    my $DIR = record_dir($R, 'project');
    my $recfile = "$DIR/$id.md";
    my $before_rec = slurp_raw($recfile);
    my $before_tf  = slurp_raw($tf);

    my $r1 = run_cli_stdin('irrelevant stdin', 'edit', $id, '--body', '-', '--content', '-', '--root', $R);
    is($r1->{rc}, 2, 'S3d: edit --body - --content - exits 2') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'usage', 'S3d: ...with kind: usage');
    is(field2($r1->{err}, 'detail'), 'stdin_conflict', 'S3d: ...and detail: stdin_conflict');
    is(slurp_raw($recfile), $before_rec, 'S3d: the record is byte-identical after the refusal');
    is(slurp_raw($tf), $before_tf, 'S3d: the target is byte-identical after the refusal');
}

# =============================================================================
# S4 (review 02-review.md, SHOULD-4) -- the step-7 failure path itself: the
# target path is a directory (not a name collision on the TEMP name, as in
# S1 -- here the write of the temp file succeeds, and the rename onto the
# existing directory fails). The result is kind io, the temp file left
# behind by the failed rename is removed (spec 3.2 step 7's ordinary case),
# and the directory occupying the target path -- and its contents -- survive
# untouched.
# =============================================================================
{
    my $RS4 = tempdir(CLEANUP => 1); $RS4 =~ s{\\}{/}g;
    my $r0 = run_cli('create', '--title', 'S4', '--content', 'orig', '--root', $RS4);
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'S4 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $tf = internal_dir($RS4, 'project') . "/$id.md";
    unlink($tf) if -f $tf;
    mkdir($tf) or die "fixture: cannot mkdir $tf: $!";
    my $inside = "$tf/keep.txt";
    open(my $ifh, '>:raw', $inside) or die "fixture: cannot write $inside: $!";
    print {$ifh} 'keepme';
    close $ifh;
    ok(-d $tf && -f $inside, 'S4 fixture: a directory now occupies the target path');

    my $r1 = run_cli('edit', $id, '--content', 'Y', '--root', $RS4);
    is($r1->{rc}, 2, 'S4: edit --content whose target is a directory exits 2')
        or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(err_kind($r1->{err}), 'io', 'S4: ...with kind: io');

    my $notes_dir = internal_dir($RS4, 'project');
    opendir(my $dh, $notes_dir) or die "fixture: cannot opendir $notes_dir: $!";
    my @entries = grep { !/^\.\.?$/ } readdir($dh);
    closedir($dh);
    my @stray = grep { /\Q$id\E\.md\.tmp\./ } @entries;
    is(scalar(@stray), 0, 'S4: no *.tmp.* sibling remains after the failed target write')
        or diag('stray entries: ' . join(',', @stray));

    ok(-d $tf, 'S4: the directory occupying the target path still exists');
    ok(-f $inside, 'S4: the file inside that directory still exists');
    is(slurp_raw($inside), 'keepme', 'S4: the file inside is byte-identical after the failed write');
}

done_testing();
