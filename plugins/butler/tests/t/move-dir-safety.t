#!/usr/bin/env perl
# platform: any
# never-halt package 05, bug 69f8 — move_dir never deletes a destination it
# did not create. Spec: .ccpraxis-local-data/blueprints/never-halt/specs/
# (this package's spec file). Decisions 8, 11(15), 21.
#
# bp-lifecycle.pl's move_dir tries rename, and on failure copies the tree
# DIRECTLY into $dst. If the copy fails it removes $dst outright. When another
# party filed the same destination meanwhile (a concurrent reconcile, a manual
# run, an orchestrator), that cleanup deletes the OTHER party's data. This
# file drives move_dir (and reconcile_one's use of it) through package-scope
# seams ($BpLifecycle::RENAME_FN / $BpLifecycle::COPY_FILE_FN) to prove the
# fallback stages its copy beside $dst and only ever removes ITS OWN staging
# directory.
#
# The spec requires bp-lifecycle.pl to be a requirable library (package
# BpLifecycle; ... unless (caller) { ... } 1;). `require $LIFECYCLE` below
# must return true with no CLI side effects (AC13), leaving move_dir and
# reconcile_one callable as BpLifecycle::*.

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path remove_tree);
use File::Basename qw(basename dirname);
use File::Copy ();
use File::Find ();
use Cwd qw(abs_path);

my $DIR       = dirname(abs_path(do { (my $f = __FILE__) =~ s{\\}{/}g; $f }));
my $SCRIPTS   = "$DIR/../../scripts";
my $LIFECYCLE = "$SCRIPTS/bp-lifecycle.pl";

ok(-f $LIFECYCLE, 'bp-lifecycle.pl exists') or BAIL_OUT('nothing to test');

# 11(13): every new test sets these to fixtures and never touches real state.
my $STATE_FIXTURE = tempdir(CLEANUP => 1);
$ENV{CCPRAXIS_DATA_DIR} = $STATE_FIXTURE;
$ENV{BUTLER_STATE_DIR}  = $STATE_FIXTURE;

# Requiring the script in-process is what the spec's file shape (2.1) exists
# for: move_dir and reconcile_one become callable, with seams overridable via
# `local $BpLifecycle::RENAME_FN = sub {...}` (observable behaviour 11, AC13).
eval { require $LIFECYCLE; 1 } or diag("require $LIFECYCLE failed: $@");

# --------------------------------------------------------------- fixtures ---

sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path)) unless -d dirname($path);
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# Fixture source tree: >= 2 levels, >= 3 files, one name carrying é.
sub fresh_src {
    my ($root) = @_;
    my $src = "$root/src";
    make_path("$src/subdir/nested");
    write_file("$src/a.txt",                 "alpha content\n");
    write_file("$src/subdir/b.txt",           "beta content\n");
    # APFS (macOS) refuses a file name that is not valid UTF-8, so there the
    # name's e-acute is its UTF-8 encoding; elsewhere the original lone Latin-1
    # byte. The CONTENT keeps the Latin-1 byte everywhere: bytes inside a file
    # are not the filesystem's business.
    my $name = $^O eq 'darwin' ? "c-\xc3\xa9.txt" : "c-\xe9.txt";
    write_file("$src/subdir/nested/$name", "gamma content \xe9\n");
    return $src;
}

# A sorted "relative path => bytes" tree snapshot; directories are entries too.
sub snapshot {
    my ($dir) = @_;
    my @entries;
    return '<absent>' unless -e $dir;
    File::Find::find({ no_chdir => 1, wanted => sub {
        my $full = $File::Find::name;
        return if $full eq $dir;
        (my $rel = $full) =~ s/^\Q$dir\E[\/\\]?//;
        $rel =~ s{\\}{/}g;
        if (-d $full) {
            push @entries, "$rel/ => <dir>";
        } else {
            push @entries, "$rel => " . (slurp($full) // '<unreadable>');
        }
    } }, $dir);
    return join("\n", sort @entries);
}

# The staging-name regex from spec 2.3, parameterised on $dst's basename.
sub staging_re {
    my ($base) = @_;
    return qr/\A\.\Q$base\E\.move-staging\.\d+\.[0-9a-f]{8}\z/;
}

sub parent_entries {
    my ($parent) = @_;
    opendir(my $dh, $parent) or return ();
    my @e = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir $dh;
    return @e;
}

# Criterion 4 (asserted in every AC): no staging directory of THIS $dst's
# shape survives in $parent, except names explicitly excluded (AC10).
sub assert_no_staging {
    my ($parent, $dst_base, $label, %opt) = @_;
    my $exclude = $opt{exclude} || {};
    my $re      = staging_re($dst_base);
    my @staging = grep { /$re/ && !$exclude->{$_} } parent_entries($parent);
    is(scalar(@staging), 0, "$label: no staging directory left behind in $parent")
        or diag("found: @staging");
}

sub assert_parent_listing {
    my ($parent, $expected, $label) = @_;
    my @entries = parent_entries($parent);
    my @got     = sort @entries;
    is_deeply(\@got, [ sort @$expected ], "$label: parent listing is exactly {@$expected}");
}

# Default per-spec seam setup (AC3-AC10, AC12): 'direct' fails, 'final' is
# handed to the real rename, unless a test overrides one phase further.
sub default_rename_seam {
    my (%o) = @_;
    my @calls;
    my $final_behavior = $o{final} || sub { my ($from, $to) = @_; return rename($from, $to); };
    my $seam = sub {
        my ($from, $to, $phase) = @_;
        push @calls, { from => $from, to => $to, phase => $phase };
        if ($phase eq 'direct') {
            $! = 16;    # EBUSY-ish, matches spec's "$! = 16; return 0"
            return 0;
        }
        return $final_behavior->($from, $to);
    };
    return ($seam, \@calls);
}

# Every AC below must produce a genuine "not ok" against the spec's contract,
# never a hard process death — so a call to a not-yet-defined/not-yet-correct
# BpLifecycle sub is itself wrapped, and its (missing) result simply fails the
# assertions that follow, same as a wrong result would.
sub call_move_dir {
    my (@args) = @_;
    unless (defined &BpLifecycle::move_dir) {
        fail('BpLifecycle::move_dir is not defined (require did not produce the requirable library shape yet)');
        return (undef, undef);
    }
    my @r = eval { BpLifecycle::move_dir(@args) };
    if ($@) {
        fail("BpLifecycle::move_dir died instead of returning: $@");
        return (undef, undef);
    }
    return @r;
}

sub call_reconcile_one {
    my (@args) = @_;
    unless (defined &BpLifecycle::reconcile_one) {
        fail('BpLifecycle::reconcile_one is not defined (require did not produce the requirable library shape yet)');
        return undef;
    }
    my $r = eval { BpLifecycle::reconcile_one(@args) };
    if ($@) {
        fail("BpLifecycle::reconcile_one died instead of returning: $@");
        return undef;
    }
    return $r;
}

sub real_copy_seam {
    my @calls;
    my $seam = sub {
        my ($from, $to) = @_;
        push @calls, { from => $from, to => $to };
        return File::Copy::copy($from, $to);
    };
    return ($seam, \@calls);
}

# ============================================================================
# AC1 (DC1, DC4) — destination exists as a non-empty directory: refuses, both
# trees untouched, no staging, no seam calls.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    make_path($dst);
    write_file("$dst/existing.txt", "keep me\n");

    my $src_snap = snapshot($src);
    my $dst_snap = snapshot($dst);

    my ($rename_seam, $rename_calls) = default_rename_seam();
    my ($copy_seam, $copy_calls)     = real_copy_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = $copy_seam;

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC1: refuses when $dst exists (non-empty dir)');
    is($detail, "destination exists: $dst", 'AC1: exact E1 string');
    is(snapshot($src), $src_snap, 'AC1: $src snapshot unchanged');
    is(snapshot($dst), $dst_snap, 'AC1: $dst snapshot unchanged');
    is(scalar(@$rename_calls), 0, 'AC1: RENAME_FN never called');
    is(scalar(@$copy_calls),   0, 'AC1: COPY_FILE_FN never called');
    assert_no_staging($root, 'dst', 'AC1');
    assert_parent_listing($root, ['src', 'dst'], 'AC1');
}

# ============================================================================
# AC2 (DC1, DC4) — destination exists as a plain file: same assertions.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    write_file($dst, "i am a file, not a directory\n");

    my $src_snap = snapshot($src);
    my $dst_snap = snapshot($dst);

    my ($rename_seam, $rename_calls) = default_rename_seam();
    my ($copy_seam, $copy_calls)     = real_copy_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = $copy_seam;

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC2: refuses when $dst exists (plain file)');
    is($detail, "destination exists: $dst", 'AC2: exact E1 string');
    is(snapshot($src), $src_snap, 'AC2: $src snapshot unchanged');
    is(snapshot($dst), $dst_snap, 'AC2: $dst snapshot unchanged');
    is(scalar(@$rename_calls), 0, 'AC2: RENAME_FN never called');
    is(scalar(@$copy_calls),   0, 'AC2: COPY_FILE_FN never called');
    assert_no_staging($root, 'dst', 'AC2');
    assert_parent_listing($root, ['src', 'dst'], 'AC2');
}

# ============================================================================
# AC3 (DC2, DC4) — direct rename fails, $dst absent: staged copy, final
# rename places it, $src removed. The 'final' seam's $from is a staging
# sibling of $dst holding the full source tree at call time.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    my $src_snap = snapshot($src);

    my @final_snapshots;
    my ($rename_seam, $rename_calls) = default_rename_seam(final => sub {
        my ($from, $to) = @_;
        push @final_snapshots, { from => $from, snap => snapshot($from) };
        return rename($from, $to);
    });
    my ($copy_seam, $copy_calls) = real_copy_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = $copy_seam;

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 1, 'AC3: succeeds');
    is($detail, 'copy+remove', 'AC3: detail is copy+remove');
    is(scalar(@final_snapshots), 1, 'AC3: exactly one final rename attempt');
    if (@final_snapshots) {
        my $from = $final_snapshots[0]{from};
        is(dirname($from), $root, 'AC3: staging dir is a sibling of $dst');
        like(basename($from), staging_re('dst'), 'AC3: staging basename matches the spec regex');
        is($final_snapshots[0]{snap}, $src_snap, 'AC3: staging held the full source tree at call time');
    }
    is(snapshot($dst), $src_snap, "AC3: \$dst's tree equals the original source's tree");
    ok(!-e $src, 'AC3: $src is gone');
    assert_no_staging($root, 'dst', 'AC3');
    assert_parent_listing($root, ['dst'], 'AC3');
}

# ============================================================================
# AC3b (S2) — same as AC3, but $dst's basename AND the staging directory's
# parent both carry a REAL UTF-8 e-acute (\xc3\xa9, two bytes), not the lone
# Latin-1 byte (\xe9) used elsewhere in this file. Real paths on this host
# (C:/Users/André/...) carry the UTF-8 form, and the staging name embeds
# $dst's basename (_make_staging), so this is the encoding this new code path
# is most exposed to.
# ============================================================================
{
    my $base = tempdir(CLEANUP => 1);
    my $root = "$base/p\xc3\xa9rent";
    make_path($root);
    my $src  = fresh_src($root);
    my $dst  = "$root/d\xc3\xa9st";
    my $src_snap = snapshot($src);

    my @final_snapshots;
    my ($rename_seam, $rename_calls) = default_rename_seam(final => sub {
        my ($from, $to) = @_;
        push @final_snapshots, { from => $from, snap => snapshot($from) };
        return rename($from, $to);
    });
    my ($copy_seam, $copy_calls) = real_copy_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = $copy_seam;

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 1, 'AC3b: succeeds with a real UTF-8 e-acute in $dst basename and staging parent');
    is($detail, 'copy+remove', 'AC3b: detail is copy+remove');
    is(scalar(@final_snapshots), 1, 'AC3b: exactly one final rename attempt');
    if (@final_snapshots) {
        my $from = $final_snapshots[0]{from};
        is(dirname($from), $root, 'AC3b: staging dir is a sibling of $dst, inside the UTF-8 parent');
        like(basename($from), staging_re("d\xc3\xa9st"), 'AC3b: staging basename matches the spec regex with the UTF-8 base');
        is($final_snapshots[0]{snap}, $src_snap, 'AC3b: staging held the full source tree at call time');
    }
    is(snapshot($dst), $src_snap, "AC3b: \$dst's tree equals the original source's tree");
    ok(!-e $src, 'AC3b: $src is gone');
    assert_no_staging($root, "d\xc3\xa9st", 'AC3b');
    assert_parent_listing($root, ["d\xc3\xa9st"], 'AC3b');
}

# ============================================================================
# AC4 (DC3, DC4) — copy fails on its 2nd file: staging removed, $src intact,
# $dst absent.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    my $src_snap = snapshot($src);

    my @copy_calls;
    my ($rename_seam, $rename_calls) = default_rename_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = sub {
        my ($from, $to) = @_;
        push @copy_calls, { from => $from, to => $to };
        if (@copy_calls == 2) { $! = 5; return 0; }
        return File::Copy::copy($from, $to);
    };

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC4: fails');
    like($detail, qr/^rename failed \(.*\) and copy failed \(/, 'AC4: E4 prefix');
    is(snapshot($src), $src_snap, 'AC4: $src snapshot unchanged');
    ok(!-e $dst, 'AC4: $dst absent');
    assert_no_staging($root, 'dst', 'AC4');
    assert_parent_listing($root, ['src'], 'AC4');
}

# ============================================================================
# AC5 (DC3, DC4) — copy fails, AND a concurrent party creates $dst during the
# copy: $dst survives byte-identical, $src intact.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    my $src_snap = snapshot($src);

    my @copy_calls;
    my ($rename_seam, $rename_calls) = default_rename_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = sub {
        my ($from, $to) = @_;
        if (!@copy_calls) {
            mkdir $dst or die "AC5 fixture: mkdir $dst: $!";
            write_file("$dst/winner.txt", "winner\n");
        }
        push @copy_calls, { from => $from, to => $to };
        return 0;
    };

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC5: fails');
    like($detail, qr/^rename failed \(.*\) and copy failed \(/, 'AC5: E4 prefix');
    my $dst_snap = snapshot($dst);
    is($dst_snap, "winner.txt => winner\n", 'AC5: $dst is exactly {winner.txt}, byte-identical');
    is(snapshot($src), $src_snap, 'AC5: $src unchanged');
    assert_no_staging($root, 'dst', 'AC5');
    assert_parent_listing($root, ['src', 'dst'], 'AC5');
}

# ============================================================================
# AC6 (DC3, DC4) — copy seam DIES instead of returning false: same shape as
# AC4, and the detail carries the die message.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    my $src_snap = snapshot($src);

    my @copy_calls;
    my ($rename_seam, $rename_calls) = default_rename_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = sub {
        my ($from, $to) = @_;
        push @copy_calls, { from => $from, to => $to };
        die "AC6 simulated die\n" if @copy_calls == 2;
        return File::Copy::copy($from, $to);
    };

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC6: fails');
    like($detail, qr/^rename failed \(.*\) and copy failed \(/, 'AC6: E4 prefix');
    like($detail, qr/AC6 simulated die/, 'AC6: detail carries the die message');
    is(snapshot($src), $src_snap, 'AC6: $src snapshot unchanged');
    ok(!-e $dst, 'AC6: $dst absent');
    assert_no_staging($root, 'dst', 'AC6');
    assert_parent_listing($root, ['src'], 'AC6');
}

# ============================================================================
# AC7 (DC3, DC4; 11(15)) — destination appears WHILE the copy is running (not
# via a failing copy): copy completes into staging, but $dst now exists
# before the final rename is even attempted -> E5, not E4/E6.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    my $src_snap = snapshot($src);

    my @copy_calls;
    my ($rename_seam, $rename_calls) = default_rename_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = sub {
        my ($from, $to) = @_;
        if (!@copy_calls) {
            mkdir $dst or die "AC7 fixture: mkdir $dst: $!";
            write_file("$dst/winner.txt", "winner\n");
        }
        push @copy_calls, { from => $from, to => $to };
        return File::Copy::copy($from, $to);
    };

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC7: fails');
    like($detail, qr/^destination appeared: /, 'AC7: E5 prefix');
    is(snapshot($dst), "winner.txt => winner\n", 'AC7: $dst is exactly {winner.txt}');
    is(snapshot($src), $src_snap, 'AC7: $src unchanged');
    assert_no_staging($root, 'dst', 'AC7');
    assert_parent_listing($root, ['src', 'dst'], 'AC7');
}

# ============================================================================
# AC8 (DC3, DC4; 11(15)) — destination appears inside the FINAL rename
# window: the 'final' seam itself creates $dst/winner.txt then fails the
# rename. Same assertions as AC7.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    my $src_snap = snapshot($src);

    my ($rename_seam, $rename_calls) = default_rename_seam(final => sub {
        mkdir $dst or die "AC8 fixture: mkdir $dst: $!";
        write_file("$dst/winner.txt", "winner\n");
        $! = 17;
        return 0;
    });
    my ($copy_seam, $copy_calls) = real_copy_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = $copy_seam;

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC8: fails');
    like($detail, qr/^destination appeared: /, 'AC8: E5 prefix');
    is(snapshot($dst), "winner.txt => winner\n", 'AC8: $dst is exactly {winner.txt}');
    is(snapshot($src), $src_snap, 'AC8: $src unchanged');
    assert_no_staging($root, 'dst', 'AC8');
    assert_parent_listing($root, ['src', 'dst'], 'AC8');
}

# ============================================================================
# AC9 (DC4) — every final rename attempt fails, $dst never appears: exactly 5
# attempts, staging removed, $src intact, $dst absent.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    my $src_snap = snapshot($src);

    my ($rename_seam, $rename_calls) = default_rename_seam(final => sub {
        $! = 13;
        return 0;
    });
    my ($copy_seam, $copy_calls) = real_copy_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = $copy_seam;

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC9: fails');
    like($detail, qr/moving the staged copy into place failed/, 'AC9: E6 substring');
    my @final_calls = grep { $_->{phase} eq 'final' } @$rename_calls;
    is(scalar(@final_calls), 5, 'AC9: the pinned retry ran exactly 5 final attempts');
    is(snapshot($src), $src_snap, 'AC9: $src unchanged');
    ok(!-e $dst, 'AC9: $dst absent');
    assert_no_staging($root, 'dst', 'AC9');
    assert_parent_listing($root, ['src'], 'AC9');
}

# ============================================================================
# AC10 (DC3, DC4) — a foreign, staging-shaped directory already sitting in
# $parent survives AC4's scenario byte-identical, and is excluded from (and
# checked separately from) the "no staging left behind" assertion.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    my $src_snap = snapshot($src);

    my $foreign_name = '.dst.move-staging.1.00000000';
    my $foreign      = "$root/$foreign_name";
    make_path($foreign);
    write_file("$foreign/foreign.txt", "not mine, leave it alone\n");
    my $foreign_snap = snapshot($foreign);

    my @copy_calls;
    my ($rename_seam, $rename_calls) = default_rename_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = sub {
        my ($from, $to) = @_;
        push @copy_calls, { from => $from, to => $to };
        if (@copy_calls == 2) { $! = 5; return 0; }
        return File::Copy::copy($from, $to);
    };

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC10: fails (AC4 scenario)');
    like($detail, qr/^rename failed \(.*\) and copy failed \(/, 'AC10: E4 prefix');

    assert_no_staging($root, 'dst', 'AC10', exclude => { $foreign_name => 1 });
    ok(-d $foreign, 'AC10: the pre-existing foreign staging-shaped dir still exists');
    is(snapshot($foreign), $foreign_snap, 'AC10: the foreign dir is byte-identical, untouched');
    is(snapshot($src), $src_snap, 'AC10: $src snapshot unchanged');
    ok(!-e $dst, 'AC10: $dst still absent');
    assert_parent_listing($root, ['src', $foreign_name], 'AC10');
}

# ============================================================================
# AC11 (DC1, DC4) — destination appears right after the DIRECT rename
# attempt (step 3): E2, COPY_FILE_FN never called, both trees intact.
# ============================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $src  = fresh_src($root);
    my $dst  = "$root/dst";
    my $src_snap = snapshot($src);

    my @copy_calls;
    local $BpLifecycle::RENAME_FN = sub {
        my ($from, $to, $phase) = @_;
        if ($phase eq 'direct') {
            mkdir $dst or die "AC11 fixture: mkdir $dst: $!";
            write_file("$dst/winner.txt", "winner\n");
            $! = 16;
            return 0;
        }
        return rename($from, $to);
    };
    local $BpLifecycle::COPY_FILE_FN = sub {
        my ($from, $to) = @_;
        push @copy_calls, { from => $from, to => $to };
        return File::Copy::copy($from, $to);
    };

    my ($ok, $detail) = call_move_dir($src, $dst);
    is($ok, 0, 'AC11: fails');
    like($detail, qr/^destination appeared: /, 'AC11: E2 prefix');
    is(scalar(@copy_calls), 0, 'AC11: COPY_FILE_FN never called');
    is(snapshot($dst), "winner.txt => winner\n", 'AC11: $dst is exactly {winner.txt}');
    is(snapshot($src), $src_snap, 'AC11: $src unchanged (nothing was copied)');
    assert_no_staging($root, 'dst', 'AC11');
    assert_parent_listing($root, ['src', 'dst'], 'AC11');
}

# ============================================================================
# AC12 (DC3, DC5) — reconcile_one surfaces move_dir's E5 refusal in process,
# on a done-lifecycle fixture, using AC7's seams.
# ============================================================================

# Fixture helpers lifted verbatim (shapes/naming) from lifecycle-reconcile.t
# so this exercises the SAME real blueprint.md/ledger shapes as that suite.
sub blueprint_md {
    my (%o) = @_;
    my $status = $o{status} // 'running';
    my $rows   = '';
    for my $p (@{ $o{packages} || [] }) {
        $rows .= "| $p->{pkg} | thing | — | sonnet | $p->{table} |\n";
    }
    return <<"MD";
# Test Blueprint

\`\`\`
blueprint: $o{name}
created: 2026-01-01
last_updated: 2026-01-01T00:00Z
status: $status        # drafting | audited | running | done | archived
\`\`\`

## Objective

Test fixture.

## Package status

| pkg | deliverable | depends_on | model | status |
|-----|-------------|------------|-------|--------|
$rows
## Harvest log

## Incidents

MD
}

sub ledger_md {
    my (%o) = @_;
    return <<"MD";
---
package: $o{pkg}
blueprint: $o{blueprint}
status: $o{status}
last_updated: 2026-01-01T00:00Z
---

# Package $o{pkg}

## Next action

None.
MD
}

sub make_ac12_blueprint {
    my ($root, $name) = @_;
    my $dir = "$root/blueprints/$name";
    make_path("$dir/packages");
    write_file("$dir/blueprint.md",
        blueprint_md(name => $name, status => 'running',
                     packages => [ { pkg => '01-a', table => 'done' } ]));
    write_file("$dir/packages/01-a.md",
        ledger_md(pkg => '01-a', blueprint => $name, status => 'done'));
    return $dir;
}

sub bp_status_of {
    my ($file) = @_;
    my $c = slurp($file) // '';
    return '' unless $c =~ /^```\s*\n((?:.*\n)*?)^```\s*$/m;
    my $b = $1;
    return '' unless $b =~ /^status:[ \t]*([^\n#]*)/m;
    my $v = $1;
    $v =~ s/\s+\z//;
    return $v;
}

{
    my $root = tempdir(CLEANUP => 1);
    my $name = 'ac12-done';
    my $bpdir = make_ac12_blueprint($root, $name);
    my $archive_dst = "$root/blueprints/_archive/$name";

    my @copy_calls;
    my ($rename_seam, $rename_calls) = default_rename_seam();
    local $BpLifecycle::RENAME_FN    = $rename_seam;
    local $BpLifecycle::COPY_FILE_FN = sub {
        my ($from, $to) = @_;
        if (!@copy_calls) {
            make_path($archive_dst) unless -d $archive_dst;
            write_file("$archive_dst/winner.txt", "winner\n");
        }
        push @copy_calls, { from => $from, to => $to };
        return File::Copy::copy($from, $to);
    };

    my $r = call_reconcile_one($bpdir, { archive => 1, data_root => $root });

    ok(ref($r) eq 'HASH', 'AC12: reconcile_one returned a report hash');
    my $err0 = (ref($r) eq 'HASH' && ref($r->{errors}) eq 'ARRAY') ? $r->{errors}[0] : undef;
    like($err0 // '', qr/^archive failed: destination appeared: /,
        'AC12: errors[0] surfaces the E5 refusal verbatim');
    is(ref($r) eq 'HASH' ? $r->{status_after} : undef, 'audited',
        'AC12: status_after rolled back to audited');
    ok(-d $bpdir, 'AC12: the source blueprint dir still exists');
    is(bp_status_of("$bpdir/blueprint.md"), 'audited', 'AC12: blueprint.md status is audited');
    is(snapshot($archive_dst), "winner.txt => winner\n",
        'AC12: the other party\'s _archive entry is intact, exactly {winner.txt}');
}

# ============================================================================
# AC13 (DC5) — the file is requirable with no side effects.
# ============================================================================
{
    ok((eval { require $LIFECYCLE; 1 }), 'AC13: require returns true (does not die)')
        or diag("require failed: $@");

    my ($ofh, $out_file) = tempfile();
    close $ofh;
    my ($efh, $err_file) = tempfile();
    close $efh;
    open(my $saved_out, '>&', \*STDOUT) or die "dup stdout: $!";
    open(my $saved_err, '>&', \*STDERR) or die "dup stderr: $!";
    open(STDOUT, '>', $out_file) or die "redirect stdout: $!";
    open(STDERR, '>', $err_file) or die "redirect stderr: $!";
    # 11: require must not change %ENV. Delete the one variable the CLI block
    # sets so a require that leaks it (guard hoisted back to file scope, or
    # otherwise reached outside `unless (caller)`) turns "UNSET" into "SET".
    my $code = qq{delete \$ENV{MSYS2_ARG_CONV_EXCL}; require "$LIFECYCLE"; print "LOADED\\n"; print exists \$ENV{MSYS2_ARG_CONV_EXCL} ? "SET\\n" : "UNSET\\n";};
    my $rc = system($^X, '-e', $code);
    open(STDOUT, '>&', $saved_out);
    open(STDERR, '>&', $saved_err);
    close $saved_out;
    close $saved_err;
    my $child_out = slurp($out_file) // '';
    my $child_err = slurp($err_file) // '';
    unlink $out_file, $err_file;

    is($rc, 0, 'AC13: a child `require` of bp-lifecycle.pl exits 0');
    is($child_out, "LOADED\nUNSET\n", 'AC13: child stdout is exactly "LOADED\\nUNSET\\n" (no CLI side effects on require, MSYS2_ARG_CONV_EXCL untouched)');
    is($child_err, '', 'AC13: child stderr is empty');

    ok(ref($BpLifecycle::RENAME_FN) eq 'CODE', 'AC13: $BpLifecycle::RENAME_FN is a CODE ref');
    ok(ref($BpLifecycle::COPY_FILE_FN) eq 'CODE', 'AC13: $BpLifecycle::COPY_FILE_FN is a CODE ref');
    ok(defined &BpLifecycle::move_dir, 'AC13: BpLifecycle::move_dir is defined');

    # 2.1: the MSYS2 guard must be the CLI block's FIRST statement (a
    # source-anchored check, not behavioural -- a require can't observe
    # ordering inside a block it never executes).
    my $source = slurp($LIFECYCLE) // '';
    if ($source =~ /unless\s*\(\s*caller\s*\)\s*\{(.*)\z/s) {
        my $block = $1;
        my $first_statement;
        for my $line (split /\n/, $block) {
            my $stripped = $line;
            $stripped =~ s/^\s+//;
            next if $stripped eq '';
            next if $stripped =~ /^#/;
            $first_statement = $stripped;
            last;
        }
        like($first_statement // '', qr/^\$ENV\{MSYS2_ARG_CONV_EXCL\}\s*=\s*'\*'\s*if\s*\$\^O/,
            "AC13: the CLI block's first non-comment statement sets MSYS2_ARG_CONV_EXCL")
            or diag("first statement was: " . ($first_statement // '<none found>'));
    } else {
        fail("AC13: could not locate 'unless (caller) {' in $LIFECYCLE");
    }
}

done_testing();
