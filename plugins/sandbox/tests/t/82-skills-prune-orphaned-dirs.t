#!/usr/bin/env perl
# p01-sandbox-plugin-provisioning — spec.md §2.3, Observable behavior 5.
#
# PluginSync::prune_orphaned_dirs($dest_root, $keep_names) does NOT exist yet
# (PluginSync.pm's @EXPORT_OK is qw(copy_tree prune_empty_parents
# reconcile_copy_plan safe_dest_rel read_copy_plan) as of this commit — no
# prune_orphaned_dirs). This file pins the one-time legacy-skill-cleanup
# contract from spec.md §0/§2.3, which is the operator's actual ruling:
#   - STANDING POLICY: an unowned, content-bearing directory is left alone.
#   - ONE-TIME (caller-gated, not this function's concern): empty unowned
#     directories ARE removed.
# AC-6 and AC-7 are written to be separately falsifiable: an implementation
# that deletes all six fixture dirs passes AC-6 but FAILS AC-7; an
# implementation that deletes none passes AC-7 but FAILS AC-6.
#
# Every call below is fully-qualified (PluginSync::prune_orphaned_dirs), NOT
# imported via `use ... qw(prune_orphaned_dirs)` — an unexported/undefined sub
# name in an import list dies at compile time, killing the whole file's TAP
# output. Calling it unqualified-but-fully-qualified at runtime instead lets
# every other, independent assertion in this file still run and report.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use PluginSync;

sub spew { my ($p, $c) = @_; my ($d) = $p =~ m{^(.*)/[^/]+$}; make_path($d) if $d && !-d $d;
           open my $f, '>:raw', $p or die "$p: $!"; print $f $c; close $f; }
sub slurp { my $p = shift; return undef unless -f $p; open my $f, '<:raw', $p or die; local $/; <$f> }

# run_prune — call the not-yet-implemented sub defensively: an
# "Undefined subroutine" death must not blow up the whole test file. Returns
# ([]) and records a diagnostic on death, so downstream assertions run and
# fail loudly against an empty result rather than being skipped.
sub run_prune {
    my ($dest_root, $keep) = @_;
    my @results;
    my $ok = eval { @results = PluginSync::prune_orphaned_dirs($dest_root, $keep); 1 };
    if (!$ok) {
        diag("PluginSync::prune_orphaned_dirs died (expected until implemented): $@");
    }
    return @results;
}

# =========================================================================
# can_ok — the deliverable is exported per spec.md §2.3 ("Add to @EXPORT_OK").
# =========================================================================
can_ok('PluginSync', 'prune_orphaned_dirs');

# =========================================================================
# AC-6 / AC-7: the six-real-directory fixture, reproduced by SHAPE (not name
# heuristic) exactly as scout-step1.md's addendum measured the live container:
# 4 empty mountpoint leftovers, 2 content-bearing (`plan`, `work-plan`).
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    for my $empty_name (qw(create-plan frontend-design manage-plans)) {
        make_path("$dest/$empty_name");
    }
    # resume-plan: empty but NESTED (zero regular files "anywhere in its
    # subtree, however deep" per spec — not just zero at the top level).
    make_path("$dest/resume-plan/nested/deeper");
    spew("$dest/plan/SKILL.md", "# plan skill\ncontent-A");
    spew("$dest/work-plan/SKILL.md", "# work-plan skill\ncontent-B");

    # Non-vacuity precondition: all six exist BEFORE the call.
    for my $name (qw(create-plan frontend-design manage-plans resume-plan plan work-plan)) {
        ok(-d "$dest/$name", "fixture precondition: $name exists before prune_orphaned_dirs runs");
    }

    my @results = run_prune($dest, []);   # nothing selected this launch
    my %by_name = map { ref($_) eq 'HASH' ? ($_->{name} => $_) : () } @results;

    for my $empty_name (qw(create-plan frontend-design manage-plans resume-plan)) {
        ok(!-e "$dest/$empty_name", "AC-6: empty legacy dir '$empty_name' removed from disk");
        is($by_name{$empty_name}{removed}, 1, "AC-6: '$empty_name' reported removed => 1")
            if exists $by_name{$empty_name};
        ok(exists $by_name{$empty_name}, "AC-6: '$empty_name' appears in the results list");
    }

    for my $content_name (qw(plan work-plan)) {
        ok(-d "$dest/$content_name",
           "AC-7: content-bearing legacy dir '$content_name' NOT removed — fails if an implementation deletes all six")
            or diag("Deleting '$content_name' violates done-criterion 5 (spec.md §0's second surfaced conflict) even though it satisfies criterion 4's literal wording.");
        is($by_name{$content_name}{removed}, 0, "AC-7: '$content_name' reported removed => 0")
            if exists $by_name{$content_name};
    }
    is(slurp("$dest/plan/SKILL.md"), "# plan skill\ncontent-A",
       'AC-7: plan/SKILL.md content byte-identical after the call');
    is(slurp("$dest/work-plan/SKILL.md"), "# work-plan skill\ncontent-B",
       'AC-7: work-plan/SKILL.md content byte-identical after the call');
}

# =========================================================================
# AC-8b: a currently-SELECTED (keep-listed) directory survives regardless of
# content/emptiness, and — per spec — must not even be INSPECTED. We plant an
# unreadable subtree inside it; a correct implementation skips it via the
# keep-check before ever trying to walk in, so the call must neither die nor
# report anything for it.
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    make_path("$dest/kept-skill/locked-subdir");
    spew("$dest/kept-skill/SKILL.md", "kept content");
    my $chmod_ok = chmod 0000, "$dest/kept-skill/locked-subdir";

    ok(-d "$dest/kept-skill", 'AC-8b fixture precondition: kept-skill exists before the call');

    my @results = run_prune($dest, ['kept-skill']);
    my %by_name = map { ref($_) eq 'HASH' ? ($_->{name} => $_) : () } @results;

    ok(-d "$dest/kept-skill", 'AC-8b: a selected (kept) directory survives unconditionally');
    is(slurp("$dest/kept-skill/SKILL.md"), 'kept content', 'AC-8b: kept directory content byte-identical after the call');
    ok(!exists $by_name{'kept-skill'}, 'AC-8b: a kept name is never even reported — the function must not process, let alone inspect, it');

    chmod 0700, "$dest/kept-skill/locked-subdir" if $chmod_ok;  # restore so CLEANUP can remove it
}

# =========================================================================
# Non-directory immediate children are skipped entirely (never touched, never
# reported) — spec §2.3's "a non-directory: skipped entirely" clause.
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    spew("$dest/stray-file.txt", 'not a skill');
    ok(-f "$dest/stray-file.txt", 'non-directory fixture precondition: stray-file.txt exists before the call');

    my @results = run_prune($dest, []);
    my %by_name = map { ref($_) eq 'HASH' ? ($_->{name} => $_) : () } @results;

    ok(-f "$dest/stray-file.txt", 'non-directory child survives (not a directory, so never a prune candidate)');
    ok(!exists $by_name{'stray-file.txt'}, 'non-directory child is never reported by prune_orphaned_dirs');
}

# =========================================================================
# Symlink at the top level: skipped entirely, mirrors reconcile_copy_plan's
# existing symlink discipline (t/32-plugin-sync.t's red-team MEDIUM-1 block).
# Skipped on filesystems/perls that can't make a followable symlink
# (Git-for-Windows turns them into junctions/copies) — same guard as t/32.
# =========================================================================
SKIP: {
    my $dest = tempdir(CLEANUP => 1);
    my $outside = "$dest/../outside-secret-$$";
    make_path($outside);
    spew("$outside/secret.txt", 'do-not-touch');
    make_path($dest);
    my $made = eval { symlink($outside, "$dest/evil-link"); 1 };
    skip 'no followable symlinks on this perl/filesystem', 2
        unless $made && -l "$dest/evil-link";

    my @results = run_prune($dest, []);
    my %by_name = map { ref($_) eq 'HASH' ? ($_->{name} => $_) : () } @results;

    ok(-l "$dest/evil-link", 'symlink child: the link itself is left untouched');
    ok(!exists $by_name{'evil-link'}, 'symlink child: never reported (skipped before -d/-f checks)');

    unlink "$dest/evil-link";
    File::Path::remove_tree($outside);
}

# =========================================================================
# Missing / non-directory $dest_root -> returns ().
# =========================================================================
{
    my $missing = tempdir(CLEANUP => 1) . "/does-not-exist-$$";
    ok(!-e $missing, 'missing-dest_root fixture precondition: the path truly does not exist');
    my @results = run_prune($missing, ['anything']);
    is(scalar(@results), 0, 'a missing dest_root returns an empty list, not a die');
}

done_testing();
