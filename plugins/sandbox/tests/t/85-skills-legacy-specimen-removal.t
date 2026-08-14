#!/usr/bin/env perl
# p01-sandbox-plugin-provisioning — driver correction after implementer-step4:
# the operator's decision log (blueprint decision entry 2026-08-14T00:50:44Z,
# "ONE-TIME REMOVAL OF THESE TWO, THEN WARN-ONLY") authorises removal of the
# two NAMED pre-manifest legacy skill specimens (`plan`, `work-plan`) as a
# CALLER-SIDE one-time pass, distinct from PluginSync::prune_orphaned_dirs's
# STANDING policy (empty -> remove; content-bearing -> warn, never remove,
# t/82's AC-6/AC-7 — untouched and NOT re-covered here).
#
# t/82-skills-prune-orphaned-dirs.t's own header says this explicitly:
#   "ONE-TIME (caller-gated, not this function's concern): empty unowned
#   directories ARE removed."
# — i.e. AC-6/AC-7 pin prune_orphaned_dirs's function-level contract only;
# they say nothing about a caller that ALSO explicitly names two specimens for
# one-time removal via a SEPARATE function. This file pins that separate
# function, PluginSync::remove_named_legacy_dirs, added specifically so the
# caller (launcher.pl) has a hard-coded, non-predicate-derived removal path
# for exactly those two names — never a general "delete content-bearing dirs"
# primitive.
#
# Every assertion here is ADDITIVE coverage: nothing in t/82 is touched, and
# nothing here asserts anything about prune_orphaned_dirs's own removed/warned
# semantics for arbitrary directories.
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

can_ok('PluginSync', 'remove_named_legacy_dirs');

# =========================================================================
# Core contract: given the two authorised names, both content-bearing
# specimens are removed and reported; a THIRD content-bearing directory that
# is NOT one of the two named specimens is left completely untouched, even
# though it looks the same shape-wise (unselected + content-bearing) as
# `plan`/`work-plan` — proving this is a hard-coded name list, not a
# heuristic that happens to also match `plan`/`work-plan` today.
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    spew("$dest/plan/SKILL.md", "# plan skill\ncontent-A");
    spew("$dest/work-plan/SKILL.md", "# work-plan skill\ncontent-B");
    # A THIRD content-bearing, unselected directory that is NOT authorised for
    # removal — must survive untouched, proving the list is explicit, not a
    # "content-bearing + unselected" predicate that would also eat this one.
    spew("$dest/some-other-legacy-thing/SKILL.md", "not one of the two named specimens");

    for my $name (qw(plan work-plan some-other-legacy-thing)) {
        ok(-d "$dest/$name", "fixture precondition: $name exists before remove_named_legacy_dirs runs");
    }

    my @LEGACY_ONE_TIME_REMOVE = ('plan', 'work-plan');  # mirrors launcher.pl's hard-coded list exactly
    my @results = PluginSync::remove_named_legacy_dirs($dest, \@LEGACY_ONE_TIME_REMOVE, []);
    my %by_name = map { ref($_) eq 'HASH' ? ($_->{name} => $_) : () } @results;

    for my $name (qw(plan work-plan)) {
        ok(!-e "$dest/$name", "the named specimen '$name' is removed from disk");
        ok(exists $by_name{$name}, "'$name' appears in the results list");
        is($by_name{$name}{removed}, 1, "'$name' reported removed => 1");
    }

    ok(-d "$dest/some-other-legacy-thing",
       "a third, unnamed content-bearing directory is NOT removed — this pins the hard-coded-list discipline")
        or diag("If this fails, remove_named_legacy_dirs stopped being an explicit list and started matching on shape (content-bearing + unselected), which is exactly the scope-creep the driver's correction warned against.");
    is(slurp("$dest/some-other-legacy-thing/SKILL.md"), "not one of the two named specimens",
       "the third directory's content is byte-identical after the call");
    ok(!exists $by_name{'some-other-legacy-thing'}, "the third directory is never reported by remove_named_legacy_dirs");
}

# =========================================================================
# A currently-SELECTED name that happens to collide with one of the two
# authorised specimen names is NEVER removed — mirrors prune_orphaned_dirs's
# own keep discipline and the spec's own edge case ("an operator re-selects
# something literally named 'plan' today").
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    spew("$dest/plan/SKILL.md", "operator re-selected this literally-named skill today");

    my @results = PluginSync::remove_named_legacy_dirs($dest, ['plan', 'work-plan'], ['plan']);
    my %by_name = map { ref($_) eq 'HASH' ? ($_->{name} => $_) : () } @results;

    ok(-d "$dest/plan", "a currently-selected name never removed, even if it is one of the two authorised specimens");
    is(slurp("$dest/plan/SKILL.md"), "operator re-selected this literally-named skill today",
       "the kept-and-named-collision directory's content is byte-identical after the call");
    ok(!exists $by_name{'plan'}, "a kept collision name is never reported by remove_named_legacy_dirs");
}

# =========================================================================
# A named specimen that doesn't currently exist on disk is silently skipped
# (not reported as a spurious removal) — the launcher's one-time gate must be
# safe to run against a `claude-home/skills` tree that never had these two
# directories at all (e.g. a brand-new project).
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    ok(!-e "$dest/plan", "missing-specimen fixture precondition: plan does not exist");
    ok(!-e "$dest/work-plan", "missing-specimen fixture precondition: work-plan does not exist");

    my @results = PluginSync::remove_named_legacy_dirs($dest, ['plan', 'work-plan'], []);
    is(scalar(@results), 0, "no results when neither named specimen exists on disk — not a die, not a false removal report");
}

# =========================================================================
# CALLER-SIDE "runs once" discipline: this function itself has no notion of
# "once" (same as prune_orphaned_dirs) — a SECOND call with the same
# arguments against the SAME dest_root, after the first call already removed
# the specimens, must not die and must simply report nothing (idempotent),
# because the directories are already gone. This is what makes launcher.pl's
# $skills_manifest_existed gate sufficient: the underlying primitive is safe
# to call again even if the gate were ever bypassed by accident, though the
# gate itself (in launcher.pl, not tested here — AC-12/the task's own hard
# constraint forbids executing launcher.pl) is what actually prevents a
# SECOND launch from re-attempting this at all.
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    spew("$dest/plan/SKILL.md", "content-A");
    spew("$dest/work-plan/SKILL.md", "content-B");

    my @first = PluginSync::remove_named_legacy_dirs($dest, ['plan', 'work-plan'], []);
    is(scalar(@first), 2, "first call removes both named specimens");

    my @second = PluginSync::remove_named_legacy_dirs($dest, ['plan', 'work-plan'], []);
    is(scalar(@second), 0, "a second call against the same (now-empty-of-specimens) dest_root removes/reports nothing — idempotent, does not die");
    ok(!-e "$dest/plan" && !-e "$dest/work-plan", "both specimens remain absent after the second call");
}

done_testing();
