#!/usr/bin/env perl
# platform: any
# Immutable oracle for almanac-note.pl's promote() (blueprint
# almanac-records, package 05-notes): the three-phase journal design of
# §2.6 -- normal promote both directions (internal<->external), id
# stability across promote, the journal-visible in-flight states and the
# invariant they must satisfy, plus both-scope (project/global) promote
# coverage and Decision-7 container refusal. CRUD, check_pointers()'s shape
# on healthy/dangling data, and the argv-grammar sweep live in the sibling
# almanac-note-crud.t. See specs/05-notes-spec.md.
#
# HOUSE PATTERN for a not-yet-built script: every call into the CLI or the
# module is wrapped in eval{} / run_cli() so "Undefined subroutine" / "Can't
# open perl script" is a caught, reported failure for THIS assertion rather
# than an abort of the whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use Cwd ();
use Encode ();
use JSON::PP ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $NOTE_PL = "$S/almanac-note.pl";

# ---------------------------------------------------------------------------
# scaffolding (duplicated from almanac-note-crud.t deliberately -- each test
# file in this plugin is self-contained, per house convention)
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
    # implicit Latin-1, splitting a multi-byte UTF-8 sequence into two
    # wrong codepoints -- silently breaking -f/open against a real on-disk
    # path whenever CWD's own path contains non-ASCII (the CLAUDE.md-
    # documented Windows non-ASCII-path landmine, fixed here from the
    # start per the almanac-todo-*.t precedent).
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

# run_cli(@args) -> { rc, out, err }. Honours whatever %ENV is currently in
# effect (e.g. a `local $ENV{ALMANAC_SURFACE} = 'container'` around the
# call), since system() forks a fresh process that inherits it.
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
    # Force scalar context on the eval so a die collapses to undef, never
    # an empty LIST -- see the crud oracle's identical comment; the same
    # trap (a caller's list-context assignment silently binding the wrong
    # value on failure) applies here to every show_json() call below.
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
sub anchor_dir {
    my ($root_or_home, $scope) = @_;
    return $scope eq 'global' ? (norm_path($root_or_home) . '/.claude/claude-code-vault') : norm_path($root_or_home);
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

# invariant_holds($record_path, $anchor_abs) -- §2.6's central claim: at
# least one of target/promote_to resolves (relative to the anchor) to a
# path where -f is true.
sub invariant_holds {
    my ($record_path, $anchor_abs) = @_;
    my (undef, $kv) = read_frontmatter($record_path);
    my @candidates;
    push @candidates, $kv->{target} if defined $kv->{target} && length $kv->{target};
    push @candidates, $kv->{promote_to} if defined $kv->{promote_to} && length $kv->{promote_to};
    for my $c (@candidates) {
        return 1 if -f "$anchor_abs/$c";
    }
    return 0;
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
# Decision 18 / Decision 120(c): the protective intent here is COUNT
# UNCHANGED and PRE-EXISTING FILES UNTOUCHED (checked below, AC-50) -- not
# that the real repo's gitignored note store holds any records at all, or
# holds ac2-target.md specifically. A fresh clone / a store emptied by an
# unrelated run must not turn this suite red for that reason alone. Whether
# ac2-target.md happens to be there is recorded (not asserted) so the AC-50
# "survives untouched" check below stays conditional on it actually having
# existed, rather than requiring its presence.
my $ac2_target_existed_before = -f "$LIVE_NOTE_STORE/ac2-target.md" ? 1 : 0;

ok(-f $NOTE_PL, 'almanac-note.pl exists at plugins/almanac/scripts/almanac-note.pl')
    or diag('almanac-note.pl is not present yet -- every assertion below is '
          . 'expected to fail for exactly that reason, not any other.');

do $NOTE_PL if -f $NOTE_PL;

ok(!-e '/run/.containerenv' && !-e '/.dockerenv',
   'sanity: this host carries no real container marker (a precondition for the ALMANAC_SURFACE overrides below)');

# =============================================================================
# AC-17, AC-18, AC-19 -- promote internal->external moves the file, keeps
# the id, and the reverse promote restores everything; a full create->edit->
# promote->promote-back->delete sequence completes with exit 0 at every step.
# =============================================================================
{
    my $R = tempdir(CLEANUP => 1);
    $R =~ s{\\}{/}g;
    mkdir(norm_path($R) . '/docs') unless -d (norm_path($R) . '/docs');

    my $r0 = run_cli('create', '--title', 'Promote me', '--content', 'orig-bytes', '--root', $R);
    is($r0->{rc}, 0, 'AC-17/19 fixture: create exits 0') or diag("stderr: $r0->{err}");
    my $created_id = field0($r0->{out}, 'id');
    ok(defined $created_id, 'AC-17/19 fixture: create returns an id');
    my $old_src = internal_dir($R, 'project') . "/$created_id.md";
    ok(-f $old_src, 'AC-17/19 fixture: the internal target file exists before promote');

    my $r_edit = run_cli('edit', $created_id, '--covers', 'edited before promote', '--root', $R);
    is($r_edit->{rc}, 0, 'AC-19: the intervening edit exits 0') or diag("stderr: $r_edit->{err}");

    my ($before_json) = show_json($created_id, '--root', $R);
    my $before_created = ref($before_json) eq 'HASH' ? $before_json->{fields}{created} : undef;

    my $r1 = run_cli('promote', $created_id, '--target', 'docs/x.md', '--root', $R);
    is($r1->{rc}, 0, 'AC-17: promote --target docs/x.md exits 0') or diag("stderr: $r1->{err}");
    is(field0($r1->{out}, 'changed'), 'yes', 'AC-17: result block carries changed: yes');
    is(field0($r1->{out}, 'from'), ".ccpraxis-local-data/notes/$created_id.md", 'AC-17: from: is the old internal target');
    my $record_id_field = field0($r1->{out}, 'id');

    my $new_dest = norm_path($R) . '/docs/x.md';
    ok(-f $new_dest, 'AC-17: the file now exists at <R>/docs/x.md');
    is(slurp_raw($new_dest), 'orig-bytes', 'AC-17: the moved file\'s bytes are the ORIGINAL bytes');
    ok(!-f $old_src, 'AC-17: the file is gone from <R>/.ccpraxis-local-data/notes/');

    my ($after1) = show_json($created_id, '--root', $R);
    ok(ref($after1) eq 'HASH', 'AC-17: show --json after promote decodes');
    if (ref($after1) eq 'HASH') {
        is($after1->{fields}{audience}, 'external', 'AC-17: audience: external');
        is($after1->{fields}{target}, 'docs/x.md', 'AC-17: target: docs/x.md');
        ok(!exists $after1->{fields}{promote_to}, 'AC-17: no promote_to key remains');
        is($after1->{fields}{created}, $before_created, 'AC-17: created is unchanged across promote');
        is($after1->{id}, $created_id, 'AC-18: show --json id equals the create-time id');
    }

    # AC-18: four-way id equality.
    my $record_path = record_dir($R, 'project') . "/$created_id.md";
    ok(-f $record_path, 'AC-18: the record file\'s stem after promote is still <original id>.md');
    is($record_id_field, $created_id, 'AC-18: the promote result block\'s id: equals the create-time id');

    # AC-19: promote back internal.
    my $r2 = run_cli('promote', $created_id, '--audience', 'internal', '--root', $R);
    is($r2->{rc}, 0, 'AC-19: promote --audience internal (the reverse move) exits 0') or diag("stderr: $r2->{err}");
    my $restored = internal_dir($R, 'project') . "/$created_id.md";
    ok(-f $restored, 'AC-19: the file is back at <R>/.ccpraxis-local-data/notes/<id>.md');
    is(slurp_raw($restored), 'orig-bytes', 'AC-19: the restored file has the same bytes');
    ok(!-f $new_dest, 'AC-19: the file is gone from <R>/docs/');
    my ($after2) = show_json($created_id, '--root', $R);
    if (ref($after2) eq 'HASH') {
        is($after2->{fields}{audience}, 'internal', 'AC-19: audience: internal after promoting back');
        is($after2->{fields}{target}, ".ccpraxis-local-data/notes/$created_id.md", 'AC-19: target restored to the internal form');
        is($after2->{id}, $created_id, 'AC-19: the id is STILL the same after the round trip');
    }

    # Full sequence, own note, exit 0 at every step.
    my $rc0 = run_cli('create', '--title', 'Full sequence', '--content', 'seq-bytes', '--root', $R);
    my $seq_id = field0($rc0->{out}, 'id');
    is($rc0->{rc}, 0, 'AC-19 (sequence): create exits 0');
    my $rc1 = run_cli('edit', $seq_id, '--title', 'Full sequence edited', '--root', $R);
    is($rc1->{rc}, 0, 'AC-19 (sequence): edit exits 0');
    my $rc2 = run_cli('promote', $seq_id, '--target', 'docs/seq.md', '--root', $R);
    is($rc2->{rc}, 0, 'AC-19 (sequence): promote exits 0');
    my $rc3 = run_cli('promote', $seq_id, '--audience', 'internal', '--root', $R);
    is($rc3->{rc}, 0, 'AC-19 (sequence): promote-back exits 0');
    my $rc4 = run_cli('delete', $seq_id, '--root', $R);
    is($rc4->{rc}, 0, 'AC-19 (sequence): delete exits 0');
}

# =============================================================================
# AC-20 -- five precondition failures, each leaves both locations exactly
# as they were and (where phase 1 never ran) the record rev unchanged.
# =============================================================================
{
    my $R20 = tempdir(CLEANUP => 1);
    $R20 =~ s{\\}{/}g;
    mkdir(norm_path($R20) . '/docs') unless -d (norm_path($R20) . '/docs');

    # audience_unchanged: an already-external note, default-direction promote.
    my $rext = run_cli('create', '--title', 'already external', '--audience', 'external', '--target', 'docs/already.md', '--root', $R20);
    my $id_ext = field0($rext->{out}, 'id');
    my ($before_ext) = show_json($id_ext, '--root', $R20);
    my $r1 = run_cli('promote', $id_ext, '--root', $R20);
    is($r1->{rc}, 2, 'AC-20 [audience_unchanged]: promote with no --audience on an already-external note exits 2');
    is(field2($r1->{err}, 'detail'), 'audience_unchanged', 'AC-20 [audience_unchanged]: ...detail: audience_unchanged');
    my ($after_ext) = show_json($id_ext, '--root', $R20);
    is(ref($after_ext) eq 'HASH' ? $after_ext->{rev} : undef, ref($before_ext) eq 'HASH' ? $before_ext->{rev} : undef,
       'AC-20 [audience_unchanged]: rev unchanged');

    # target_refused: --audience internal with --target given.
    my $rint1 = run_cli('create', '--title', 'target refused case', '--content', 'tr-bytes', '--root', $R20);
    my $id_tr = field0($rint1->{out}, 'id');
    my $src_tr = internal_dir($R20, 'project') . "/$id_tr.md";
    my ($before_tr) = show_json($id_tr, '--root', $R20);
    my $r2 = run_cli('promote', $id_tr, '--audience', 'internal', '--target', 'docs/tr.md', '--root', $R20);
    is($r2->{rc}, 2, 'AC-20 [target_refused]: --audience internal --target ... exits 2');
    is(field2($r2->{err}, 'detail'), 'target_refused', 'AC-20 [target_refused]: ...detail: target_refused');
    ok(-f $src_tr, 'AC-20 [target_refused]: the source file is untouched');
    is(slurp_raw($src_tr), 'tr-bytes', 'AC-20 [target_refused]: the source bytes are unchanged');
    my ($after_tr) = show_json($id_tr, '--root', $R20);
    is(ref($after_tr) eq 'HASH' ? $after_tr->{rev} : undef, ref($before_tr) eq 'HASH' ? $before_tr->{rev} : undef,
       'AC-20 [target_refused]: rev unchanged');

    # missing_target: external default direction with no --target.
    my $rint2 = run_cli('create', '--title', 'missing target case', '--content', 'mt-bytes', '--root', $R20);
    my $id_mt = field0($rint2->{out}, 'id');
    my $src_mt = internal_dir($R20, 'project') . "/$id_mt.md";
    my $r3 = run_cli('promote', $id_mt, '--root', $R20);
    is($r3->{rc}, 2, 'AC-20 [missing_target]: promote with no --target (default external) exits 2');
    is(field2($r3->{err}, 'detail'), 'missing_target', 'AC-20 [missing_target]: ...detail: missing_target');
    ok(-f $src_mt, 'AC-20 [missing_target]: the source file is untouched');

    # external_target_unversioned: --target under .ccpraxis-local-data/.
    my $rint3 = run_cli('create', '--title', 'unversioned dest case', '--content', 'eu-bytes', '--root', $R20);
    my $id_eu = field0($rint3->{out}, 'id');
    my $src_eu = internal_dir($R20, 'project') . "/$id_eu.md";
    my $r4 = run_cli('promote', $id_eu, '--target', '.ccpraxis-local-data/notes/eu.md', '--root', $R20);
    is($r4->{rc}, 2, 'AC-20 [external_target_unversioned]: --target under .ccpraxis-local-data/ exits 2');
    is(field2($r4->{err}, 'detail'), 'external_target_unversioned', 'AC-20 [external_target_unversioned]: ...detail: external_target_unversioned');
    ok(-f $src_eu, 'AC-20 [external_target_unversioned]: the source file is untouched');

    # dest_parent_missing.
    my $rint4 = run_cli('create', '--title', 'dest parent missing case', '--content', 'dp-bytes', '--root', $R20);
    my $id_dp = field0($rint4->{out}, 'id');
    my $src_dp = internal_dir($R20, 'project') . "/$id_dp.md";
    my $r5 = run_cli('promote', $id_dp, '--target', 'docs/deep/new/x.md', '--root', $R20);
    is($r5->{rc}, 2, 'AC-20 [dest_parent_missing]: destination parent dir missing exits 2');
    is(field2($r5->{err}, 'detail'), 'dest_parent_missing', 'AC-20 [dest_parent_missing]: ...detail: dest_parent_missing');
    ok(-f $src_dp, 'AC-20 [dest_parent_missing]: the source file is untouched');
    ok(!-f (norm_path($R20) . '/docs/deep/new/x.md'), 'AC-20 [dest_parent_missing]: nothing was moved to the intended destination');
}

# =============================================================================
# AC-21 -- promote onto an occupied destination: 2, kind: exists, path:
# names the destination; both source and destination bytes unchanged.
# =============================================================================
{
    my $R21 = tempdir(CLEANUP => 1);
    $R21 =~ s{\\}{/}g;
    mkdir(norm_path($R21) . '/docs') unless -d (norm_path($R21) . '/docs');
    my $occupied = norm_path($R21) . '/docs/x.md';
    open(my $fh, '>:raw', $occupied) or die "fixture: cannot seed occupied destination: $!";
    print {$fh} 'occupant bytes';
    close $fh;

    my $r0 = run_cli('create', '--title', 'source for AC-21', '--content', 'source-bytes', '--root', $R21);
    my $id21 = field0($r0->{out}, 'id');
    ok(defined $id21, 'AC-21 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $src21 = internal_dir($R21, 'project') . "/$id21.md";

    my $r1 = run_cli('promote', $id21, '--target', 'docs/x.md', '--root', $R21);
    is($r1->{rc}, 2, 'AC-21: promote onto an occupied destination exits 2') or diag("stderr: $r1->{err}");
    is(err_kind($r1->{err}), 'exists', 'AC-21: ...with kind: exists');
    is(field2($r1->{err}, 'path'), $occupied, 'AC-21: ...and path: names the destination') if field2($r1->{err}, 'path');
    is(slurp_raw($occupied), 'occupant bytes', 'AC-21: the destination\'s bytes are unchanged');
    is(slurp_raw($src21), 'source-bytes', 'AC-21: the source\'s bytes are unchanged');
}

# =============================================================================
# AC-22 -- promote --expect-rev <stale> dies conflict; NO FILE HAS MOVED
# (source still exists, destination still absent) -- proving the CAS fires
# in phase 1, before the rename.
# =============================================================================
{
    my $R22 = tempdir(CLEANUP => 1);
    $R22 =~ s{\\}{/}g;
    mkdir(norm_path($R22) . '/docs') unless -d (norm_path($R22) . '/docs');
    my $r0 = run_cli('create', '--title', 'AC-22 source', '--content', 'ac22-bytes', '--root', $R22);
    my $id22 = field0($r0->{out}, 'id');
    ok(defined $id22, 'AC-22 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $src22 = internal_dir($R22, 'project') . "/$id22.md";
    my $dest22 = norm_path($R22) . '/docs/x.md';

    my ($cur) = show_json($id22, '--root', $R22);
    my $stale_rev = (ref($cur) eq 'HASH') ? $cur->{rev} : ('d' x 64);
    my $bump = run_cli('edit', $id22, '--set', 'bump=1', '--root', $R22);
    is($bump->{rc}, 0, 'AC-22 fixture: an intervening edit makes the earlier rev stale') or diag("stderr: $bump->{err}");

    my $r1 = run_cli('promote', $id22, '--target', 'docs/x.md', '--expect-rev', $stale_rev, '--root', $R22);
    is($r1->{rc}, 2, 'AC-22: promote --expect-rev <stale> exits 2') or diag("stderr: $r1->{err}");
    is(err_kind($r1->{err}), 'conflict', 'AC-22: ...with kind: conflict');
    ok(-f $src22, 'AC-22: the source file still exists (nothing moved)');
    ok(!-f $dest22, 'AC-22: the destination still does not exist (nothing moved)');
    is(slurp_raw($src22), 'ac22-bytes', 'AC-22: the source\'s bytes are unchanged');
}

# =============================================================================
# AC-23 -- promote on a note whose source target file was deleted out of
# band: 2, kind: not_found, path: absolute source; afterwards the record
# carries promote_to (phase 1 committed) while target still names the
# source (the journal is on disk, evidence phase ordering was followed).
# =============================================================================
my ($AC23_R, $AC23_ID, $AC23_DEST_REL);
our ($AC24_STATE_A, $AC24_STATE_B);
{
    my $R23 = tempdir(CLEANUP => 1);
    $R23 =~ s{\\}{/}g;
    mkdir(norm_path($R23) . '/docs') unless -d (norm_path($R23) . '/docs');
    my $r0 = run_cli('create', '--title', 'AC-23 source', '--content', 'ac23-bytes', '--root', $R23);
    my $id23 = field0($r0->{out}, 'id');
    ok(defined $id23, 'AC-23 fixture: create succeeds') or diag("stderr: $r0->{err}");
    my $src23 = internal_dir($R23, 'project') . "/$id23.md";
    unlink($src23) if -f $src23;
    ok(!-f $src23, 'AC-23 fixture: the source target file was actually removed out of band');

    my $r1 = run_cli('promote', $id23, '--target', 'docs/x.md', '--root', $R23);
    is($r1->{rc}, 2, 'AC-23: promote on a note whose source is missing exits 2') or diag("stderr: $r1->{err}");
    is(err_kind($r1->{err}), 'not_found', 'AC-23: ...with kind: not_found');
    is(field2($r1->{err}, 'path'), $src23, 'AC-23: ...and path: names the absolute source') if field2($r1->{err}, 'path');

    my $record_path23 = record_dir($R23, 'project') . "/$id23.md";
    my (undef, $kv23) = read_frontmatter($record_path23);
    is($kv23->{promote_to}, 'docs/x.md', 'AC-23: the record carries promote_to (phase 1\'s journal is on disk)');
    is($kv23->{target}, ".ccpraxis-local-data/notes/$id23.md", 'AC-23: target still names the (now-missing) source');

    ($AC23_R, $AC23_ID, $AC23_DEST_REL) = ($R23, $id23, 'docs/x.md');
}

# =============================================================================
# AC-24 -- the invariant, asserted directly, over three reachable
# intermediate states.
#
# NOTE (spec ambiguity, flagged in the report): §4's AC-24 text says "state
# (a) is what AC-23 leaves behind", but AC-23's own fixture deletes the
# source file BEFORE calling promote, which the §2.6 invariant text itself
# scopes to apply only "provided the original target existed when promote
# began" -- AC-23's precondition is violated on purpose, so its leftover
# state can have NEITHER target nor promote_to resolve, which would make
# THIS assertion vacuously fail through no fault of the implementation.
# State (a) is therefore built here per AC-24's own prose instead ("after
# phase 1 with the file STILL AT THE SOURCE"): a normal internal note,
# hand-journaled (promote_to set) with the source file left physically in
# place -- the same "hand-built" construction technique the spec itself
# authorizes for B35/B36's in-flight fixtures. AC-23's literal fixture is
# still exercised above, on its own terms, as its own AC.
# =============================================================================
{
    my $R24 = tempdir(CLEANUP => 1);
    $R24 =~ s{\\}{/}g;
    mkdir(norm_path($R24) . '/docs') unless -d (norm_path($R24) . '/docs');
    my $anchor24 = anchor_dir($R24, 'project');

    # --- state (a): phase 1 committed, file still at the source.
    my $ra = run_cli('create', '--title', 'state a', '--content', 'state-a-bytes', '--root', $R24);
    my $id_a = field0($ra->{out}, 'id');
    ok(defined $id_a, 'AC-24 [a] fixture: create succeeds') or diag("stderr: $ra->{err}");
    my $record_a = defined($id_a) ? (record_dir($R24, 'project') . "/$id_a.md") : undef;
    set_frontmatter_field($record_a, 'promote_to', 'docs/xa.md') if defined $record_a;
    ok((defined($record_a) && invariant_holds($record_a, $anchor24)),
       'AC-24 [a]: after phase 1 with the file still at the source, the invariant holds (-f true via target)');

    # --- state (b): after the rename, journal uncommitted.
    my $rb = run_cli('create', '--title', 'state b', '--content', 'state-b-bytes', '--root', $R24);
    my $id_b = field0($rb->{out}, 'id');
    ok(defined $id_b, 'AC-24 [b] fixture: create succeeds') or diag("stderr: $rb->{err}");
    my $record_b = defined($id_b) ? (record_dir($R24, 'project') . "/$id_b.md") : undef;
    set_frontmatter_field($record_b, 'promote_to', 'docs/xb.md') if defined $record_b;
    my $src_b  = defined($id_b) ? (internal_dir($R24, 'project') . "/$id_b.md") : undef;
    my $dest_b = norm_path($R24) . '/docs/xb.md';
    # Fixture-of-a-fixture: only attempt the direct rename() when the
    # source file genuinely exists (i.e. create actually materialized it).
    # A hard `die` here on a not-yet-built script would abort the WHOLE
    # FILE rather than reporting this one fixture step as failed -- exactly
    # the house-pattern violation this suite's own self-audit exists to
    # catch, so this is guarded rather than fatal.
    my $renamed = (defined($src_b) && -f $src_b) ? rename($src_b, $dest_b) : 0;
    ok($renamed, 'AC-24 [b] fixture: the file was moved directly, bypassing the script')
        or diag(defined($src_b) ? "rename($src_b -> $dest_b) failed or source absent: $!" : 'no source path (create did not return an id)');
    ok(($renamed && defined($record_b) && invariant_holds($record_b, $anchor24)),
       'AC-24 [b]: after the rename with the journal uncommitted, the invariant holds (-f true via promote_to)');

    # --- state (c): after a full promote.
    my $rc0 = run_cli('create', '--title', 'state c', '--content', 'state-c-bytes', '--root', $R24);
    my $id_c = field0($rc0->{out}, 'id');
    ok(defined $id_c, 'AC-24 [c] fixture: create succeeds') or diag("stderr: $rc0->{err}");
    my $rc1 = defined($id_c) ? run_cli('promote', $id_c, '--target', 'docs/xc.md', '--root', $R24) : { rc => -1 };
    is($rc1->{rc}, 0, 'AC-24 [c] fixture: the full promote exits 0') or diag("stderr: " . ($rc1->{err} // '(no id -- promote not attempted)'));
    my $record_c = defined($id_c) ? (record_dir($R24, 'project') . "/$id_c.md") : undef;
    ok((defined($record_c) && invariant_holds($record_c, $anchor24)),
       'AC-24 [c]: after a full promote, the invariant holds (-f true via the new target)');

    # remember for AC-25/26 (id may be undef when the fixture itself
    # couldn't be built yet -- AC-25/26 below already guard on ref($e) eq
    # 'HASH' / defined-ness before using these, so an undef id there simply
    # fails those assertions cleanly rather than crashing).
    $AC24_STATE_B = { root => $R24, id => $id_b, dest_rel => 'docs/xb.md', record => $record_b, dest_abs => $dest_b, bytes => 'state-b-bytes' };
    $AC24_STATE_A = { root => $R24, id => $id_a, dest_rel => 'docs/xa.md', record => $record_a, bytes => 'state-a-bytes' };
}

# =============================================================================
# AC-25 -- state (b): check_pointers() reports status in_flight, resolved
# equal to the DESTINATION's absolute path, and the note is ABSENT from
# dangling.
# =============================================================================
{
    my $Hfresh = tempdir(CLEANUP => 1);
    $Hfresh =~ s{\\}{/}g;
    my $c = eval { Almanac::Note::check_pointers(root => $AC24_STATE_B->{root}, home => $Hfresh) };
    ok(defined $c, 'AC-25: check_pointers() returns a value on state (b)') or diag("error: $@");
    if (ref($c) eq 'HASH' && ref($c->{project}) eq 'HASH') {
        my ($e) = grep { $_->{id} eq $AC24_STATE_B->{id} } @{$c->{project}{pointers}};
        ok(ref($e) eq 'HASH', 'AC-25: the state (b) note appears in pointers');
        if (ref($e) eq 'HASH') {
            is($e->{status}, 'in_flight', 'AC-25: status is in_flight');
            is($e->{resolved}, $AC24_STATE_B->{dest_abs}, 'AC-25: resolved equals the DESTINATION\'s absolute path');
        }
        ok(!(grep { $_->{id} eq $AC24_STATE_B->{id} } @{$c->{project}{dangling}}), 'AC-25: the note is ABSENT from dangling');
    }
}

# =============================================================================
# AC-26 -- re-running the identical promote against state (b) resumes
# (exits 0, no second rename, ends at ok with no promote_to); against
# state (a) it moves the file and ends at ok.
# =============================================================================
{
    # against state (b): resume.
    my $r_b = run_cli('promote', $AC24_STATE_B->{id}, '--target', $AC24_STATE_B->{dest_rel}, '--root', $AC24_STATE_B->{root});
    is($r_b->{rc}, 0, 'AC-26 [resume b]: re-running the identical promote against state (b) exits 0') or diag("stderr: $r_b->{err}");
    is(slurp_raw($AC24_STATE_B->{dest_abs}), $AC24_STATE_B->{bytes}, 'AC-26 [resume b]: the destination\'s bytes are unchanged (no second rename mangled them)');
    my @tmp_files = grep { /\.tmp\z/ } list_md_files((norm_path($AC24_STATE_B->{root}) . '/docs'));
    # list_md_files filters *.md, so widen the check to any .tmp file in docs/.
    opendir(my $dh, norm_path($AC24_STATE_B->{root}) . '/docs');
    my @any_tmp = grep { /\.tmp\z/ } readdir($dh);
    closedir $dh;
    is(scalar(@any_tmp), 0, 'AC-26 [resume b]: no .tmp file appears in the destination directory');
    my ($after_b) = show_json($AC24_STATE_B->{id}, '--root', $AC24_STATE_B->{root});
    if (ref($after_b) eq 'HASH') {
        is($after_b->{fields}{audience}, 'external', 'AC-26 [resume b]: audience: external');
        is($after_b->{fields}{target}, $AC24_STATE_B->{dest_rel}, 'AC-26 [resume b]: target is the destination');
        ok(!exists $after_b->{fields}{promote_to}, 'AC-26 [resume b]: no promote_to remains');
    }
    my $c_b = eval { Almanac::Note::check_pointers(root => $AC24_STATE_B->{root}, home => tempdir(CLEANUP => 1)) };
    if (ref($c_b) eq 'HASH' && ref($c_b->{project}) eq 'HASH') {
        my ($e) = grep { $_->{id} eq $AC24_STATE_B->{id} } @{$c_b->{project}{pointers}};
        is(ref($e) eq 'HASH' ? $e->{status} : undef, 'ok', 'AC-26 [resume b]: status is ok after the resumed promote');
    }

    # against state (a): move the file and commit.
    my $src_a = internal_dir($AC24_STATE_A->{root}, 'project') . "/$AC24_STATE_A->{id}.md";
    ok(-f $src_a, 'AC-26 [resume a] fixture: the file is still at the source before resuming');
    my $r_a = run_cli('promote', $AC24_STATE_A->{id}, '--target', $AC24_STATE_A->{dest_rel}, '--root', $AC24_STATE_A->{root});
    is($r_a->{rc}, 0, 'AC-26 [resume a]: re-running the identical promote against state (a) exits 0') or diag("stderr: $r_a->{err}");
    my $dest_a = norm_path($AC24_STATE_A->{root}) . '/docs/xa.md';
    ok(-f $dest_a, 'AC-26 [resume a]: the file was moved to the destination');
    ok(!-f $src_a, 'AC-26 [resume a]: the file is gone from the source');
    is(slurp_raw($dest_a), $AC24_STATE_A->{bytes}, 'AC-26 [resume a]: the moved file has the original bytes');
    my $c_a = eval { Almanac::Note::check_pointers(root => $AC24_STATE_A->{root}, home => tempdir(CLEANUP => 1)) };
    if (ref($c_a) eq 'HASH' && ref($c_a->{project}) eq 'HASH') {
        my ($e) = grep { $_->{id} eq $AC24_STATE_A->{id} } @{$c_a->{project}{pointers}};
        is(ref($e) eq 'HASH' ? $e->{status} : undef, 'ok', 'AC-26 [resume a]: status is ok after resuming from state (a)');
    }
}

# =============================================================================
# AC-35 -- AC-1/AC-9/AC-13/AC-17/AC-19-shaped verbs work identically under
# --global --home <tempdir>, with the internal target's `target` value
# being exactly notes/<id>.md -- NO .ccpraxis-local-data prefix.
# =============================================================================
{
    my $H35 = tempdir(CLEANUP => 1);
    $H35 =~ s{\\}{/}g;
    mkdir(norm_path($H35) . '/.claude') unless -d (norm_path($H35) . '/.claude');
    mkdir(norm_path($H35) . '/.claude/claude-code-vault') unless -d (norm_path($H35) . '/.claude/claude-code-vault');
    mkdir(norm_path($H35) . '/.claude/claude-code-vault/docs') unless -d (norm_path($H35) . '/.claude/claude-code-vault/docs');

    my $r0 = run_cli('create', '--title', 'Global note', '--content', 'global-bytes', '--covers', 'AC-35-global-covers', '--global', '--home', $H35);
    is($r0->{rc}, 0, 'AC-35 (create): create --global exits 0') or diag("stderr: $r0->{err}");
    is(field0($r0->{out}, 'scope'), 'global', 'AC-35 (create): result block carries scope: global');
    my $gid = field0($r0->{out}, 'id');
    is(field0($r0->{out}, 'target'), "notes/$gid.md", 'AC-35 (create): the recorded internal target is exactly notes/<id>.md');
    my $gdir = record_dir($H35, 'global');
    is(scalar(list_md_files($gdir)), 1, 'AC-35 (create): exactly one record under the Decision-2 global dir');

    my $redit = run_cli('edit', $gid, '--title', 'Global Edited', '--global', '--home', $H35);
    is($redit->{rc}, 0, 'AC-35 (edit): edit --global exits 0') or diag("stderr: $redit->{err}");

    my $rpromote = run_cli('promote', $gid, '--target', 'docs/g.md', '--global', '--home', $H35);
    is($rpromote->{rc}, 0, 'AC-35 (promote): promote --global exits 0') or diag("stderr: $rpromote->{err}");
    my $gdest = norm_path($H35) . '/.claude/claude-code-vault/docs/g.md';
    ok(-f $gdest, 'AC-35 (promote): the global external target exists');
    is(slurp_raw($gdest), 'global-bytes', 'AC-35 (promote): the global external target has the original bytes');

    my $rpromoteback = run_cli('promote', $gid, '--audience', 'internal', '--global', '--home', $H35);
    is($rpromoteback->{rc}, 0, 'AC-35 (promote back): the reverse promote --global exits 0') or diag("stderr: $rpromoteback->{err}");
    my ($j35) = show_json($gid, '--global', '--home', $H35);
    is(ref($j35) eq 'HASH' ? $j35->{fields}{target} : undef, "notes/$gid.md", 'AC-35 (promote back): the restored global internal target is notes/<id>.md');

    my $global_target = internal_dir($H35, 'global') . "/$gid.md";
    my $rdel = run_cli('delete', $gid, '--global', '--home', $H35);
    is($rdel->{rc}, 0, 'AC-35 (delete): delete --global exits 0') or diag("stderr: $rdel->{err}");
    # AC-19 (spec 09-notes-fixes §2.5): an internal note's content file is
    # now REMOVED by delete, in EITHER scope -- replaces the old
    # "still exists" oracle.
    ok(!-f $global_target, 'AC-19: delete --global REMOVES the internal note\'s content file too');
    like($rdel->{out}, qr/^content: removed$/m, 'AC-19: STDOUT carries content: removed for the global delete');
}

# =============================================================================
# AC-37 -- with ALMANAC_SURFACE=container, each of create/list/show/edit/
# promote/delete invoked with --global exits 2, prints nothing on STDOUT,
# STDERR carries the Decision-7 machine block. For promote additionally:
# the global internal-notes dir gains nothing, and the project tree is
# untouched.
# =============================================================================
{
    my $HOME37 = tempdir(CLEANUP => 1);
    $HOME37 =~ s{\\}{/}g;
    my $ROOT37 = tempdir(CLEANUP => 1);
    $ROOT37 =~ s{\\}{/}g;
    local $ENV{ALMANAC_SURFACE} = 'container';

    my %verb_args = (
        list     => ['list', '--global', '--home', $HOME37],
        create   => ['create', '--title', 'nope', '--global', '--home', $HOME37],
        show     => ['show', 'whatever-id', '--global', '--home', $HOME37],
        edit     => ['edit', 'whatever-id', '--title', 'x', '--global', '--home', $HOME37],
        promote  => ['promote', 'whatever-id', '--target', 'docs/x.md', '--global', '--home', $HOME37],
        delete   => ['delete', 'whatever-id', '--global', '--home', $HOME37],
    );
    for my $verb (sort keys %verb_args) {
        my $r = run_cli(@{ $verb_args{$verb} });
        is($r->{rc}, 2, "AC-37 [$verb]: --global under ALMANAC_SURFACE=container exits 2") or diag("stdout: $r->{out}\nstderr: $r->{err}");
        is($r->{out}, '', "AC-37 [$verb]: STDOUT is empty");
        is(err_kind($r->{err}), 'scope_unavailable', "AC-37 [$verb]: STDERR machine block carries kind: scope_unavailable")
            or diag("stderr: $r->{err}");
        is(field2($r->{err}, 'scope'), 'global', "AC-37 [$verb]: ...scope: global");
        is(field2($r->{err}, 'surface'), 'container', "AC-37 [$verb]: ...surface: container");
        is(field2($r->{err}, 'readable'), '0', "AC-37 [$verb]: ...readable: 0");
        is(field2($r->{err}, 'writable'), '0', "AC-37 [$verb]: ...writable: 0");
        is(field2($r->{err}, 'reason'), 'vault_not_mounted', "AC-37 [$verb]: ...reason: vault_not_mounted");
    }
    my $gdir37 = record_dir($HOME37, 'global');
    is(scalar(list_md_files($gdir37)), 0, 'AC-37 [promote]: the global internal-notes dir gains nothing');
    my $pdir37 = record_dir($ROOT37, 'project');
    is(scalar(list_md_files($pdir37)), 0, 'AC-37 [promote]: the project tree is untouched');
}

# =============================================================================
# AC-38 -- with ALMANAC_SURFACE=container, check_pointers() returns
# global => {available=>0, reason=>'vault_not_mounted'} with pointers/
# dangling ABSENT while project is fully reported; check-pointers exits 0.
# =============================================================================
{
    my $R38 = tempdir(CLEANUP => 1); $R38 =~ s{\\}{/}g;
    my $H38 = tempdir(CLEANUP => 1); $H38 =~ s{\\}{/}g;
    run_cli('create', '--title', 'p38', '--root', $R38);

    my ($direct, $via_cli);
    {
        local $ENV{ALMANAC_SURFACE} = 'container';
        $direct = eval { Almanac::Note::check_pointers(root => $R38, home => $H38) };
        $via_cli = run_cli('check-pointers', '--root', $R38, '--home', $H38);
    }
    ok(ref($direct) eq 'HASH', 'AC-38 fixture: the direct check_pointers() call under container returns a hashref') or diag('error: ' . ($@ // '(none)'));
    if (ref($direct) eq 'HASH') {
        is($direct->{global}{available}, 0, 'AC-38: global available == 0');
        is($direct->{global}{reason}, 'vault_not_mounted', 'AC-38: global reason == vault_not_mounted');
        ok(!exists($direct->{global}{pointers}) && !exists($direct->{global}{dangling}),
           'AC-38: global pointers/dangling keys are ABSENT');
        is($direct->{project}{available}, 1, 'AC-38: project is still fully reported');
    }
    is($via_cli->{rc}, 0, 'AC-38: the check-pointers verb exits 0 even when the global scope is unavailable')
        or diag("stderr: $via_cli->{err}");
}

# =============================================================================
# AC-39 -- with ALMANAC_SURFACE=container, every project-scope verb
# (including a full promote round trip) still exits 0 and behaves as on
# the host.
# =============================================================================
{
    my $ROOT39 = tempdir(CLEANUP => 1);
    $ROOT39 =~ s{\\}{/}g;
    mkdir(norm_path($ROOT39) . '/docs') unless -d (norm_path($ROOT39) . '/docs');
    local $ENV{ALMANAC_SURFACE} = 'container';

    my $rc0 = run_cli('create', '--title', 'Project under container', '--content', 'c39-bytes', '--root', $ROOT39);
    is($rc0->{rc}, 0, 'AC-39: create (project scope) under container exits 0') or diag("stderr: $rc0->{err}");
    my $id39 = field0($rc0->{out}, 'id');
    ok(defined $id39, 'AC-39: create returns an id');

    my $rlist = run_cli('list', '--root', $ROOT39);
    is($rlist->{rc}, 0, 'AC-39: list (project scope) under container exits 0') or diag("stderr: $rlist->{err}");

    my $rshow = run_cli('show', $id39, '--root', $ROOT39);
    is($rshow->{rc}, 0, 'AC-39: show (project scope) under container exits 0') or diag("stderr: $rshow->{err}");

    my $redit = run_cli('edit', $id39, '--title', 'Edited under container', '--root', $ROOT39);
    is($redit->{rc}, 0, 'AC-39: edit (project scope) under container exits 0') or diag("stderr: $redit->{err}");

    my $rpromote = run_cli('promote', $id39, '--target', 'docs/c39.md', '--root', $ROOT39);
    is($rpromote->{rc}, 0, 'AC-39: promote (project scope) under container exits 0') or diag("stderr: $rpromote->{err}");

    my $rdelete = run_cli('delete', $id39, '--root', $ROOT39);
    is($rdelete->{rc}, 0, 'AC-39: delete (project scope) under container exits 0') or diag("stderr: $rdelete->{err}");
}

# =============================================================================
# AC-40 -- --project --global together: 2, detail: scope_conflict; no verb
# ever falls back from global to project.
# =============================================================================
{
    my $ROOT40 = tempdir(CLEANUP => 1); $ROOT40 =~ s{\\}{/}g;
    my $HOME40 = tempdir(CLEANUP => 1); $HOME40 =~ s{\\}{/}g;
    my $PDIR40 = record_dir($ROOT40, 'project');
    my $GDIR40 = record_dir($HOME40, 'global');

    my $r = run_cli('create', '--title', 'Conflict', '--project', '--global', '--root', $ROOT40, '--home', $HOME40);
    is($r->{rc}, 2, 'AC-40: create --project --global together exits 2');
    is(err_kind($r->{err}), 'usage', 'AC-40: ...with kind: usage');
    is(field2($r->{err}, 'detail'), 'scope_conflict', 'AC-40: ...and detail: scope_conflict');

    is(scalar(list_md_files($GDIR40)), 0, 'AC-40: the global directory gained no file from the refused conflicting create');
    is(scalar(list_md_files($PDIR40)), 0, 'AC-40: the project directory gained no file either -- no silent fallback in either direction');
}

# =============================================================================
# Live-store sanity, again, at the end (AC-50).
# =============================================================================
{
    my $live_after       = count_md_in($LIVE_NOTE_STORE);
    my $live_notes_after = count_md_in($LIVE_NOTES_DIR);
    is($live_after, $live_before,
       "AC-50: live note store's record count is unchanged by this suite ($live_before before, $live_after after)");
    # Presence of ac2-target.md is never REQUIRED (Decision 18 / 120(c)) --
    # only, if it was there before this suite ran, that it is still there
    # after.
    SKIP: {
        skip('ac2-target.md was not present before this suite ran -- nothing to protect', 1)
            unless $ac2_target_existed_before;
        ok(-f "$LIVE_NOTE_STORE/ac2-target.md", 'AC-50: the pre-existing ac2-target.md fixture survives untouched');
    }
    is($live_notes_after, $live_notes_before,
       "AC-50: the repo's own .ccpraxis-local-data/notes/ gains nothing ($live_notes_before before, $live_notes_after after)");
}

done_testing();
