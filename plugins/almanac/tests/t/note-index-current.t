#!/usr/bin/env perl
# platform: any
# Immutable oracle for the 09-notes-fixes render-index integration
# (specs/09-notes-fixes-spec.md, blueprint where-things-go, package
# 09-notes-fixes). almanac-note.pl's own create/edit/delete CRUD behavior,
# its --covers requirement/budget and its delete content-removal rule are
# covered by the sibling almanac-note-crud.t and almanac-note-promote.t;
# this file is only about the render-index SIDE EFFECT a global create,
# edit or delete now triggers from the CLI entry point (spec §2.4), and its
# interaction with the already-existing global-counts refresh (AC-5).
#
# HOUSE PATTERN for a not-yet-built behavior: every call into the CLI is
# captured via fork()+exec(LIST) (never a shell string, never an in-memory
# scalar reopen -- the almanac-migrate-memories.t precedent), so a spawn
# failure is a caught, reported failure for THIS assertion rather than an
# abort of the whole file.
#
# ISOLATION / AC-27 tripwire: every call in this file passes an EXPLICIT
# --home pointing at a File::Temp fixture, and ALSO localizes
# $ENV{HOME}/$ENV{USERPROFILE}/$ENV{ALMANAC_HOME} to that same fixture
# around the call -- belt-and-suspenders, since the render-index CHILD
# process resolves its own home from inherited env whenever almanac-note.pl
# was not itself given --home (never the case in this file, but the
# tripwire below holds regardless of that implementation detail). The real
# ~/.claude/almanac-notes.md (hashed if present, its absence recorded if
# not) and the real global note store's directory listing are captured
# BEFORE anything else in this file runs, and compared again at the very
# end (AC-27).
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use Cwd ();
use Encode ();
use JSON::PP ();
use Digest::SHA ();
use POSIX ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $NOTE_PL    = "$S/almanac-note.pl";
my $MIGRATE_PL = "$S/almanac-migrate-memories.pl";

use lib "$Bin/../../scripts";
use Almanac::Store ();
use Almanac::GlobalCounts ();

# =============================================================================
# AC-27 tripwire -- captured before any fixture work below touches anything.
# =============================================================================
sub _real_home { return $ENV{ALMANAC_HOME} // $ENV{HOME} // $ENV{USERPROFILE} }
sub sha256_of_path {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $bytes = <$fh>;
    close $fh;
    return Digest::SHA::sha256_hex(defined $bytes ? $bytes : '');
}
sub _sorted_dir_listing {
    my ($dir) = @_;
    return [] unless defined $dir && -d $dir;
    opendir(my $dh, $dir) or return [];
    my @f = sort grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;
    return \@f;
}
my $REAL_HOME        = _real_home();
my $REAL_NOTES_INDEX = defined($REAL_HOME) ? "$REAL_HOME/.claude/almanac-notes.md" : undef;
my $REAL_NOTE_STORE  = defined($REAL_HOME) ? "$REAL_HOME/.claude/claude-code-vault/almanac/note" : undef;
my $TRIPWIRE_BEFORE = {
    notes_index_sha    => sha256_of_path($REAL_NOTES_INDEX),
    notes_index_exists => (defined($REAL_NOTES_INDEX) && -e $REAL_NOTES_INDEX) ? 1 : 0,
    note_store_listing => _sorted_dir_listing($REAL_NOTE_STORE),
};

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

# field0/field2 -- column-0 "key: value" and two-space-indented "  key: value"
# lines, the shared shape of almanac-note.pl's result block, its
# almanac-error block and almanac-migrate-memories.pl's own report lines.
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

# fresh_home($leaf) -> $home -- a brand-new tempdir with .claude/ pre-created.
# Defaults to a non-ASCII leaf so every ordinary fixture already exercises
# the Windows non-ASCII-path landmine; AC-24 additionally uses an
# explicitly-named "Andr\x{e9}-..." leaf for clarity at the call site.
my $HOME_SEQ = 0;
sub fresh_home {
    my ($leaf) = @_;
    my $base = tempdir(CLEANUP => 1);
    $base =~ s{\\}{/}g;
    $leaf = "Andr\x{e9}-home-" . (++$HOME_SEQ) unless defined $leaf;
    my $home = "$base/$leaf";
    mkdir($home) or die "fixture: cannot mkdir $home: $!";
    make_path("$home/.claude") or die "fixture: cannot mkdir $home/.claude: $!";
    return $home;
}

sub fresh_root {
    my $base = tempdir(CLEANUP => 1);
    $base =~ s{\\}{/}g;
    my $root = "$base/root";
    mkdir($root) or die "fixture: cannot mkdir $root: $!";
    return $root;
}

sub index_path { my ($home) = @_; return norm_path($home) . '/.claude/almanac-notes.md' }

# _fork_capture(@argv) -> {rc,out,err,raw_out} -- fork()+exec(LIST), never a
# shell string, never an in-memory scalar reopen (house pattern).
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

# run_note($home, @argv) -- @argv must include its own --home/--root/--global
# as appropriate; $home only drives the env-triple localisation (AC-27).
sub run_note {
    my ($home, @argv) = @_;
    local $ENV{HOME}         = $home;
    local $ENV{USERPROFILE}  = $home;
    local $ENV{ALMANAC_HOME} = $home;
    return _fork_capture($NOTE_PL, @argv);
}

# run_render_index($home) -- the explicit, standalone verb (used as the
# "follow-up render-index" oracle and to seed/inspect index state directly).
sub run_render_index {
    my ($home) = @_;
    local $ENV{HOME}         = $home;
    local $ENV{USERPROFILE}  = $home;
    local $ENV{ALMANAC_HOME} = $home;
    return _fork_capture($MIGRATE_PL, 'render-index', '--home', $home);
}

sub write_file {
    my ($path, $bytes) = @_;
    my $dir = $path;
    $dir =~ s{/[^/]+\z}{};
    make_path($dir) unless -d $dir;
    open(my $fh, '>:raw', $path) or die "fixture: cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
}

sub global_list_json {
    my ($home) = @_;
    my $r = run_note($home, 'list', '--json', '--global', '--home', $home);
    return (decode_json_or_undef($r->{raw_out}), $r);
}

# last_nonblank_line($text) -- the final non-empty line, used for AC-8's
# "index: is the LAST line" oracle without depending on a trailing newline.
sub last_nonblank_line {
    my ($text) = @_;
    my @lines = grep { length } split /\n/, (defined $text ? $text : '');
    return $lines[-1];
}

# =============================================================================
# AC-1 (B1) -- global create renders; index contains title+covers
# (untruncated); follow-up render-index reports changed: no.
# =============================================================================
{
    my $H = fresh_home();
    my $r = run_note($H, 'create', '--title', 'AC1 Title', '--covers', 'AC1 Covers', '--global', '--home', $H);
    is($r->{rc}, 0, 'AC-1: create --global --covers exits 0') or diag("stdout: $r->{out}\nstderr: $r->{err}");
    is(scalar(() = $r->{out} =~ /^id:\s/mg), 1, 'AC-1: the result block appears exactly once (one id: line)');
    is(last_nonblank_line($r->{out}), 'index: rendered', 'AC-1/AC-8: STDOUT ends with index: rendered');

    my $T = index_path($H);
    ok(-f $T, 'AC-1: the index file now exists');
    my $idx = slurp_text($T);
    like($idx, qr/\QAC1 Title\E/, 'AC-1: the index contains the title');
    like($idx, qr/\QAC1 Covers\E/, 'AC-1: the index contains the covers, untruncated');
    unlike($idx, qr/\[truncated\]/, 'AC-1/AC-11: the covers is not truncated');

    my $follow = run_render_index($H);
    is($follow->{rc}, 0, 'AC-1 fixture: the follow-up render-index exits 0') or diag("stderr: $follow->{err}");
    is(field0($follow->{out}, 'changed'), 'no', 'AC-1: an immediate follow-up render-index reports changed: no');
}

# =============================================================================
# AC-2 (B2) -- global edit renders; follow-up changed: no; old title absent,
# new title present.
# =============================================================================
{
    my $H = fresh_home();
    my $r0 = run_note($H, 'create', '--title', 'AC2 Old Title', '--covers', 'AC2 Covers', '--global', '--home', $H);
    is($r0->{rc}, 0, 'AC-2 fixture: create --global exits 0') or diag("stderr: $r0->{err}");
    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'AC-2 fixture: an id was captured') or diag($r0->{out});

    my $r1 = run_note($H, 'edit', $id, '--title', 'AC2 New Title', '--global', '--home', $H);
    is($r1->{rc}, 0, 'AC-2: edit --global exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(last_nonblank_line($r1->{out}), 'index: rendered', 'AC-2/AC-8: STDOUT ends with index: rendered');

    my $idx = slurp_text(index_path($H));
    like($idx, qr/\QAC2 New Title\E/, 'AC-2: the index contains the new title');
    unlike($idx, qr/\QAC2 Old Title\E/, 'AC-2: the index no longer contains the old title');

    my $follow = run_render_index($H);
    is(field0($follow->{out}, 'changed'), 'no', 'AC-2: a follow-up render-index reports changed: no');
}

# =============================================================================
# AC-3 (B3) -- global delete renders; title absent; deleting the last global
# note leaves a zero-byte index; follow-up changed: no.
# =============================================================================
{
    my $H = fresh_home();
    my $r0 = run_note($H, 'create', '--title', 'AC3 Title', '--covers', 'AC3 Covers', '--global', '--home', $H);
    is($r0->{rc}, 0, 'AC-3 fixture: create --global exits 0') or diag("stderr: $r0->{err}");
    my $id = field0($r0->{out}, 'id');

    my $r1 = run_note($H, 'delete', $id, '--global', '--home', $H);
    is($r1->{rc}, 0, 'AC-3: delete --global exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    like($r1->{out}, qr/^content:\s/m, 'AC-3: the result includes a content: line before index:');
    is(last_nonblank_line($r1->{out}), 'index: rendered', 'AC-3/AC-8: STDOUT ends with index: rendered');
    # content: must precede index: (spec §2.5).
    ok(index($r1->{out}, 'content:') < index($r1->{out}, 'index: rendered'),
        'AC-3: content: appears before index: in the delete output');

    my $T = index_path($H);
    ok(-f $T, 'AC-3: the index file still exists (now empty)');
    is(-s $T, 0, 'AC-3: deleting the last global note leaves the index at zero bytes');
    my $idx = slurp_text($T) // '';
    unlike($idx, qr/\QAC3 Title\E/, 'AC-3: the index no longer contains the deleted title');

    my $follow = run_render_index($H);
    is(field0($follow->{out}, 'changed'), 'no', 'AC-3: a follow-up render-index reports changed: no');
}

# =============================================================================
# AC-4/AC-5 (B4) -- a render failure (foreign_content, hand_edited) still
# exits 0, prints index: failed, carries the notes_index_stale warning with
# the right reason, leaves the index byte-identical, keeps the note change
# visible, and still refreshes the global counts snapshot.
# =============================================================================
{
    # foreign_content -- across create, edit, delete.
    my $H = fresh_home();
    my $T = index_path($H);
    write_file($T, "hand-written prose that was never part of any block\n");
    my $foreign_bytes = slurp_raw($T);

    my $r0 = run_note($H, 'create', '--title', 'AC4 Title', '--covers', 'AC4 Covers', '--global', '--home', $H);
    is($r0->{rc}, 0, 'AC-4 (create/foreign_content): exits 0 even though the render fails') or diag("stdout: $r0->{out}\nstderr: $r0->{err}");
    is(last_nonblank_line($r0->{out}), 'index: failed', 'AC-4 (create/foreign_content): STDOUT ends with index: failed');
    like($r0->{err}, qr/notes index not rendered/, 'AC-4 (create/foreign_content): STDERR carries the prose warning line');
    is(field2($r0->{err}, 'kind'), 'notes_index_stale', 'AC-4 (create/foreign_content): warning kind: notes_index_stale');
    is(field2($r0->{err}, 'reason'), 'foreign_content', 'AC-4 (create/foreign_content): warning reason: foreign_content');
    is(slurp_raw($T), $foreign_bytes, 'AC-4 (create/foreign_content): the index is byte-identical after the failed render');

    my $id = field0($r0->{out}, 'id');
    ok(defined $id, 'AC-4 (create/foreign_content) fixture: an id was captured despite the render failure') or diag($r0->{out});
    my ($glist) = global_list_json($H);
    ok((ref($glist) eq 'ARRAY' && (grep { $_->{id} eq (defined $id ? $id : '') } @$glist)),
        'AC-4 (create/foreign_content): the created note IS visible via list --global --json')
        if defined $id;

    # AC-5: the global counts snapshot still reflects the change.
    my $note_store = eval { Almanac::Store->open(scope => 'global', type => 'note', home => $H) };
    my $direct_total = (ref $note_store) ? scalar(@{ $note_store->list }) : undef;
    my $snap_path = eval { Almanac::GlobalCounts::snapshot_path(home => $H) };
    my $snap = eval { Almanac::GlobalCounts::read_snapshot(defined $snap_path ? $snap_path : '') };
    is(defined($snap) ? $snap->{note}{total} : undef, $direct_total,
        'AC-5: the global counts snapshot note.total equals the store\'s own count, even after a failed render');

    my $r1 = run_note($H, 'edit', $id, '--title', 'AC4 Title Edited', '--global', '--home', $H) if defined $id;
    if (defined $id) {
        is($r1->{rc}, 0, 'AC-4 (edit/foreign_content): exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
        is(last_nonblank_line($r1->{out}), 'index: failed', 'AC-4 (edit/foreign_content): STDOUT ends with index: failed');
        is(field2($r1->{err}, 'reason'), 'foreign_content', 'AC-4 (edit/foreign_content): warning reason: foreign_content');
        is(slurp_raw($T), $foreign_bytes, 'AC-4 (edit/foreign_content): the index is still byte-identical');
        my ($j) = (sub { my $r = run_note($H, 'show', $id, '--json', '--global', '--home', $H); return decode_json_or_undef($r->{raw_out}) })->();
        is(ref($j) eq 'HASH' ? $j->{fields}{title} : undef, 'AC4 Title Edited', 'AC-4 (edit/foreign_content): the edited field shows via show --json');
    }

    my $r2 = run_note($H, 'delete', $id, '--global', '--home', $H) if defined $id;
    if (defined $id) {
        is($r2->{rc}, 0, 'AC-4 (delete/foreign_content): exits 0') or diag("stdout: $r2->{out}\nstderr: $r2->{err}");
        is(last_nonblank_line($r2->{out}), 'index: failed', 'AC-4 (delete/foreign_content): STDOUT ends with index: failed');
        is(field2($r2->{err}, 'reason'), 'foreign_content', 'AC-4 (delete/foreign_content): warning reason: foreign_content');
        is(slurp_raw($T), $foreign_bytes, 'AC-4 (delete/foreign_content): the index is still byte-identical');
        my $r3 = run_note($H, 'show', $id, '--global', '--home', $H);
        is($r3->{rc}, 2, 'AC-4 (delete/foreign_content): show on the deleted id exits 2');
        is(err_kind($r3->{err}), 'not_found', 'AC-4 (delete/foreign_content): ...with kind: not_found');
    }
}
{
    # hand_edited -- for create only (per spec table).
    my $H = fresh_home();
    my $T = index_path($H);
    my $r0 = run_note($H, 'create', '--title', 'AC4HE Seed', '--covers', 'AC4HE Covers', '--global', '--home', $H);
    is($r0->{rc}, 0, 'AC-4 (hand_edited) fixture: seed create exits 0') or diag("stderr: $r0->{err}");
    is(last_nonblank_line($r0->{out}), 'index: rendered', 'AC-4 (hand_edited) fixture: the seed render succeeds');
    my $clean_bytes = slurp_raw($T);
    ok(defined($clean_bytes) && length($clean_bytes), 'AC-4 (hand_edited) fixture: the index is non-empty before the hand-edit');
    (my $edited = $clean_bytes) =~ s/AC4HE Seed/AC4HE Seed EDITED BY HAND/;
    isnt($edited, $clean_bytes, 'AC-4 (hand_edited) fixture: the hand-edit actually changed the bytes');
    write_file($T, $edited);

    my $r1 = run_note($H, 'create', '--title', 'AC4HE Second', '--covers', 'AC4HE Covers 2', '--global', '--home', $H);
    is($r1->{rc}, 0, 'AC-4 (create/hand_edited): exits 0 even though the render fails') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is(last_nonblank_line($r1->{out}), 'index: failed', 'AC-4 (create/hand_edited): STDOUT ends with index: failed');
    is(field2($r1->{err}, 'kind'), 'notes_index_stale', 'AC-4 (create/hand_edited): warning kind: notes_index_stale');
    is(field2($r1->{err}, 'reason'), 'hand_edited', 'AC-4 (create/hand_edited): warning reason: hand_edited');
    is(slurp_raw($T), $edited, 'AC-4 (create/hand_edited): the index is byte-identical after the failed render');
    my $id1 = field0($r1->{out}, 'id');
    my ($glist) = global_list_json($H);
    ok((ref($glist) eq 'ARRAY' && defined($id1) && (grep { $_->{id} eq $id1 } @$glist)),
        'AC-4 (create/hand_edited): the created note is visible via list --global --json');
}

# =============================================================================
# AC-6 (B5) -- project-scope create/edit/delete print no index: line and
# never create, read or write the index (pre-seeded content stays
# byte-identical; an absent index stays absent).
# =============================================================================
{
    my $H = fresh_home();
    my $R = fresh_root();
    my $T = index_path($H);
    ok(!-e $T, 'AC-6 fixture: the index does not exist yet');

    my $r0 = run_note($H, 'create', '--title', 'AC6 Project Note', '--root', $R);
    is($r0->{rc}, 0, 'AC-6: project create exits 0') or diag("stderr: $r0->{err}");
    unlike($r0->{out}, qr/^index:/m, 'AC-6: project create prints no index: line');
    ok(!-e $T, 'AC-6: project create never creates the index file');
    my $id = field0($r0->{out}, 'id');

    my $r1 = run_note($H, 'edit', $id, '--title', 'AC6 Edited', '--root', $R);
    is($r1->{rc}, 0, 'AC-6: project edit exits 0') or diag("stderr: $r1->{err}");
    unlike($r1->{out}, qr/^index:/m, 'AC-6: project edit prints no index: line');
    ok(!-e $T, 'AC-6: project edit never creates the index file');

    # Now pre-seed arbitrary content and confirm a project delete leaves it
    # byte-identical.
    write_file($T, "pre-seeded content unrelated to any project note\n");
    my $seeded = slurp_raw($T);
    my $r2 = run_note($H, 'delete', $id, '--root', $R);
    is($r2->{rc}, 0, 'AC-6: project delete exits 0') or diag("stderr: $r2->{err}");
    unlike($r2->{out}, qr/^index:/m, 'AC-6: project delete prints no index: line');
    is(slurp_raw($T), $seeded, 'AC-6: project delete leaves a pre-seeded index byte-identical');
}

# =============================================================================
# AC-7 (B6) -- a failed global verb prints no index: line; index
# byte-identical.
# =============================================================================
{
    my $H = fresh_home();
    my $r0 = run_note($H, 'create', '--title', 'AC7 Seed', '--covers', 'AC7 Covers', '--global', '--home', $H);
    is($r0->{rc}, 0, 'AC-7 fixture: seed create --global exits 0') or diag("stderr: $r0->{err}");
    my $T = index_path($H);
    my $before = slurp_raw($T);

    my $r1 = run_note($H, 'delete', 'nosuch-id-ac7', '--global', '--home', $H);
    is($r1->{rc}, 2, 'AC-7: delete nosuch --global exits 2') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    is($r1->{out}, '', 'AC-7: STDOUT is empty for a failed global verb');
    unlike($r1->{out}, qr/index:/, 'AC-7: a failed global verb prints no index: line');
    is(slurp_raw($T), $before, 'AC-7: the index is byte-identical after a failed global verb');
}

# =============================================================================
# AC-8 -- the verb's result block appears exactly once on STDOUT, followed
# by index: as the LAST line, for global create, edit and delete (checked
# inline above for create/edit/delete; this block adds the explicit
# one-result-block-per-call assertion the others didn't already cover).
# =============================================================================
{
    my $H = fresh_home();
    my $r0 = run_note($H, 'create', '--title', 'AC8 Title', '--covers', 'AC8 Covers', '--global', '--home', $H);
    is(scalar(() = $r0->{out} =~ /^id:\s/mg), 1, 'AC-8 (create): exactly one id: line');
    is(scalar(() = $r0->{out} =~ /^index:/mg), 1, 'AC-8 (create): exactly one index: line, which is the last');
    is(last_nonblank_line($r0->{out}), 'index: rendered', 'AC-8 (create): index: is the last line');

    my $id = field0($r0->{out}, 'id');
    my $r1 = run_note($H, 'edit', $id, '--title', 'AC8 Title 2', '--global', '--home', $H);
    is(scalar(() = $r1->{out} =~ /^id:\s/mg), 1, 'AC-8 (edit): exactly one id: line');
    is(last_nonblank_line($r1->{out}), 'index: rendered', 'AC-8 (edit): index: is the last line');

    my $r2 = run_note($H, 'delete', $id, '--global', '--home', $H);
    is(scalar(() = $r2->{out} =~ /^id:\s/mg), 1, 'AC-8 (delete): exactly one id: line');
    is(last_nonblank_line($r2->{out}), 'index: rendered', 'AC-8 (delete): index: is the last line');
}

# =============================================================================
# AC-24 (B24) -- B1, B3 and B17 hold with a fixture home whose path contains
# a non-ASCII character.
# =============================================================================
{
    my $H = fresh_home("Andr\x{e9}-ac24-home");
    like($H, qr/\x{e9}/, 'AC-24 fixture: the home path really contains the non-ASCII character');

    my $r0 = run_note($H, 'create', '--title', 'AC24 Title', '--covers', 'AC24 Covers', '--content', 'ac24 bytes', '--global', '--home', $H);
    is($r0->{rc}, 0, 'AC-24 (B1): create --global under a non-ASCII home exits 0') or diag("stdout: $r0->{out}\nstderr: $r0->{err}");
    is(last_nonblank_line($r0->{out}), 'index: rendered', 'AC-24 (B1): index: rendered under a non-ASCII home');
    my $idx = slurp_text(index_path($H));
    like($idx, qr/\QAC24 Title\E/, 'AC-24 (B1): the index contains the title under a non-ASCII home');

    my $id = field0($r0->{out}, 'id');
    my $content_path = norm_path($H) . "/.claude/claude-code-vault/notes/$id.md";
    ok(-f $content_path, 'AC-24 (B17) fixture: the content file exists before delete');

    my $r1 = run_note($H, 'delete', $id, '--global', '--home', $H);
    is($r1->{rc}, 0, 'AC-24 (B3/B17): delete --global under a non-ASCII home exits 0') or diag("stdout: $r1->{out}\nstderr: $r1->{err}");
    ok(!-f $content_path, 'AC-24 (B17): the content file is removed under a non-ASCII home');
    is(-s index_path($H), 0, 'AC-24 (B3): the index is zero bytes after deleting the only note, under a non-ASCII home');
    is(last_nonblank_line($r1->{out}), 'index: rendered', 'AC-24 (B3): index: rendered on the delete, under a non-ASCII home');
}

# =============================================================================
# AC-27 tripwire -- ASSERT. The real ~/.claude/almanac-notes.md and the real
# global note store directory listing are unchanged by this entire file.
# =============================================================================
{
    my $notes_exists_after = (defined($REAL_NOTES_INDEX) && -e $REAL_NOTES_INDEX) ? 1 : 0;
    is($notes_exists_after, $TRIPWIRE_BEFORE->{notes_index_exists},
        'AC-27: the real ~/.claude/almanac-notes.md existence is unchanged');
    if ($TRIPWIRE_BEFORE->{notes_index_exists}) {
        is(sha256_of_path($REAL_NOTES_INDEX), $TRIPWIRE_BEFORE->{notes_index_sha},
            'AC-27: the real ~/.claude/almanac-notes.md SHA-256 is unchanged');
    }
    is_deeply(_sorted_dir_listing($REAL_NOTE_STORE), $TRIPWIRE_BEFORE->{note_store_listing},
        'AC-27: the real global note store directory listing is unchanged');
}

done_testing();
