#!/usr/bin/env perl
# p01-sandbox-plugin-provisioning — spec.md Observable behaviors 3, 4, 6, 7;
# AC-4, AC-5, AC-8a.
#
# Skills are reconciled with the EXISTING, already-tested
# PluginSync::reconcile_copy_plan — spec.md §2.1/§2.2 deliberately reuse it
# unmodified rather than write a second reconcile. What's new is only the
# SHAPE of the entries: skill-shaped plan entries never carry a `src` key
# (skills are never copied, only ever bind-mounted live). This file exercises
# reconcile_copy_plan directly with that skill shape, so it is testing
# BEHAVIOR (does a src-less entry get removed/kept/never-copied correctly),
# not re-testing plugin-copy behavior already covered by t/32-plugin-sync.t.
#
# reconcile_copy_plan itself is fully implemented today (confirmed by reading
# PluginSync.pm during authoring: line 187's `next unless defined $e->{src}`
# already gates copying on src being present). So most assertions here are
# expected to ALREADY PASS — they are regression locks proving the reused
# function is safe for the new skill use-case, per spec.md's explicit
# instruction that AC-4/AC-5/AC-8a be testable via reconcile_copy_plan
# directly. Anything that fails indicates PluginSync.pm's contract is NOT
# what spec.md §2.1 assumes it is — a real, actionable finding either way.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use PluginSync qw(reconcile_copy_plan);

sub spew { my ($p, $c) = @_; my ($d) = $p =~ m{^(.*)/[^/]+$}; make_path($d) if $d && !-d $d;
           open my $f, '>:raw', $p or die "$p: $!"; print $f $c; close $f; }
sub slurp { my $p = shift; return undef unless -f $p; open my $f, '<:raw', $p or die; local $/; <$f> }

# =========================================================================
# AC-5 / Observable behavior 3 (copy phase): a skill-shaped ($new) entry with
# no `src` key must NEVER create/write into dest_root/name — the manifest
# entry only marks "this was selected", never a copy source. This is the
# test that would catch "reconcile silently starts copying skills".
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    ok(!-e "$dest/skill-a", 'AC-5 fixture precondition: dest_root/skill-a does not exist before reconcile');

    my $skill_entry = { name => 'skill-a', dest_rel => 'skill-a' };  # NO src, per spec §2.1
    reconcile_copy_plan([], [$skill_entry], $dest);

    ok(!-e "$dest/skill-a" || _is_empty_dir("$dest/skill-a"),
       'AC-5: a src-less skill entry creates NOTHING under dest_root (no copy happened)')
        or diag("If this fails, reconcile_copy_plan's copy phase started acting on entries without src — a regression against PluginSync.pm:185-196's `next unless defined \$e->{src}` gate.");
}

sub _is_empty_dir {
    my $p = shift;
    return 0 unless -d $p;
    opendir(my $dh, $p) or return 0;
    my @kids = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
    closedir $dh;
    return scalar(@kids) == 0;
}

# =========================================================================
# AC-4 / Observable behavior 3 (removal phase): a skill selected LAST launch
# (in $prior) and NOT selected THIS launch (absent from $new) is removed from
# dest_root, including any stray content a test fixture placed under it.
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    my $prior_entry = { name => 'skill-gone', dest_rel => 'skill-gone' };
    # Simulate the live RO bind having left the mountpoint dir behind on the
    # host with stray content (spec.md's edge-case: "accumulates stray
    # content between launches while unmounted").
    spew("$dest/skill-gone/SKILL.md", 'stale content');
    ok(-f "$dest/skill-gone/SKILL.md", 'AC-4 fixture precondition: skill-gone exists with content before reconcile');

    reconcile_copy_plan([$prior_entry], [], $dest);   # deselected this launch

    ok(!-e "$dest/skill-gone", 'AC-4: a skill deselected this launch is absent from dest_root after reconcile');
}

# =========================================================================
# Observable behavior 4: reconcile_copy_plan never touches a dest_root entry
# whose name never appears in $prior at all — independent of $new. This is
# the SAME assertion the plugins side already locks (t/32-plugin-sync.t's
# "sandbox-B" case) applied to the skill shape, and it is AC-8a.
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    # An in-container-installed skill: never named in ANY manifest, ever.
    spew("$dest/operator-installed-skill/SKILL.md", 'operator wrote this inside the container');
    ok(-f "$dest/operator-installed-skill/SKILL.md",
       'AC-8a fixture precondition: operator-installed-skill exists before reconcile');

    my $selected_a = { name => 'skill-a', dest_rel => 'skill-a' };
    # Ordinary reconcile pass with unrelated prior/new activity happening
    # around it — the in-container skill is in NEITHER.
    reconcile_copy_plan([], [$selected_a], $dest);

    ok(-d "$dest/operator-installed-skill",
       'AC-8a: an operator-installed skill (name in no manifest, ever) survives a reconcile pass — done-criterion 5');
    is(slurp("$dest/operator-installed-skill/SKILL.md"), 'operator wrote this inside the container',
       'AC-8a: operator-installed skill content is byte-identical after reconcile (this is the assertion that matters most — everything else here is recoverable, this one is not)');
}

# =========================================================================
# Observable behavior 6/7 — "a first launch prunes nothing (no history yet)":
# reconcile_copy_plan called with $prior = [] (the launcher's state before
# $SKILLS_COPY_MANIFEST ever existed) must not remove ANYTHING already
# present in dest_root, regardless of whether it's in $new or not — because
# step 1 of reconcile_copy_plan iterates $prior, and an empty $prior means
# that loop body never runs at all. This is distinct from AC-8a above (which
# tests "not in EITHER manifest, ever") — this tests the specific bootstrap
# moment where $prior is deliberately [] because no manifest has been written
# yet, even though the directory MIGHT independently reappear in a later
# $prior once manifests start being written.
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    spew("$dest/pre-existing-unrelated/SKILL.md", 'was here before any manifest existed');
    ok(-d "$dest/pre-existing-unrelated",
       'first-launch fixture precondition: pre-existing-unrelated exists before the bootstrap reconcile call');

    my $selected_only = { name => 'skill-a', dest_rel => 'skill-a' };
    reconcile_copy_plan([], [$selected_only], $dest);   # prior=[] : the bootstrap launch

    ok(-d "$dest/pre-existing-unrelated",
       'first-launch (prior=[]) removes NOTHING pre-existing — an over-eager bootstrap prune would destroy a fresh install, which is exactly what this pins against');
    is(slurp("$dest/pre-existing-unrelated/SKILL.md"), 'was here before any manifest existed',
       'first-launch: pre-existing content is byte-identical after the bootstrap reconcile call');
}

# =========================================================================
# Observable behavior 3, positive half: a skill selected BOTH last launch and
# this launch is kept (not removed) — dest_rel present in both $prior and
# $new. Paired with AC-4's negative half above.
# =========================================================================
{
    my $dest = tempdir(CLEANUP => 1);
    spew("$dest/skill-kept/SKILL.md", 'still selected');
    my $entry = { name => 'skill-kept', dest_rel => 'skill-kept' };

    reconcile_copy_plan([$entry], [$entry], $dest);   # selected both launches

    ok(-d "$dest/skill-kept", 'still-selected skill survives an ordinary reconcile pass');
    is(slurp("$dest/skill-kept/SKILL.md"), 'still selected',
       'still-selected skill content untouched (no copy attempted — src-less entry)');
}

done_testing();
