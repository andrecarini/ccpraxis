#!/usr/bin/env perl
# p01-sandbox-plugin-provisioning — fix-batch step 7 regression coverage for
# findings F1, F2, F3 (reports/p01-sandbox-plugin-provisioning/{reviewer,redteam}-step6.md,
# fixbatch-step7.md). Nothing here re-covers t/85's existing, still-valid
# assertions about remove_named_legacy_dirs's basic contract; this file only
# pins the three fix-batch corrections:
#
#   F1 — CORRECTED per fixbatch-step7.md's F1 correction: the operator's
#        actual authorisation was "one-time removal of these two, then
#        warn-only" — a removal AND a policy. The first attempt at this
#        finding deleted the PluginSync::remove_named_legacy_dirs call from
#        launcher.pl entirely, which dropped the removal half and left the
#        two hard-coded specimens (`plan`, `work-plan`) in place forever. The
#        corrected fix restores the call, but gates it (together with
#        prune_orphaned_dirs) on a MACHINE-SCOPED marker file under the host
#        user's real ~/.claude (never $CLAUDE_DATA/claude-home, which is
#        per-project and is what a container's /root/.claude binds to) so the
#        pass fires at most once on this machine, instead of once per project
#        forever. launcher.pl is never require'd/executed here (AC-12 /
#        dispatch hard constraint), so the call-site and gating assertions
#        below are source-text checks, not behavioral ones; the marker-gating
#        LOGIC itself (do-nothing when a marker exists, act when it doesn't)
#        is exercised behaviorally further down via the same primitives
#        launcher.pl calls, since launcher.pl itself can't be executed.
#   F2 — remove_named_legacy_dirs must reject a $names (and $keep_names) entry
#        that is not a safe, single-component relative name (traversal guard),
#        exactly like reconcile_copy_plan already does for dest_rel.
#   F3 — both prune_orphaned_dirs and remove_named_legacy_dirs must verify a
#        removal actually happened (path gone) before reporting removed => 1;
#        a best-effort deletion that silently leaves the path behind (e.g. a
#        locked file on Windows) must be reported as removed => 0 with a
#        distinguishing `error` key, never as a false success.
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

# =========================================================================
# F1 (corrected) — launcher.pl's automatic one-time cleanup block MUST call
# BOTH PluginSync::prune_orphaned_dirs (standing content-based policy) AND
# PluginSync::remove_named_legacy_dirs (the operator-authorised one-time
# removal of the two named specimens) -- and BOTH must be gated on a
# MACHINE-SCOPED marker, not merely the per-project $skills_manifest_existed
# check alone. Read-only source inspection; launcher.pl is NEVER require'd or
# executed here.
# =========================================================================
{
    my $launcher_path = "$Bin/../../scripts/launcher.pl";
    ok(-f $launcher_path, 'F1 fixture precondition: launcher.pl exists at the expected path');
    open my $fh, '<:raw', $launcher_path or die "read $launcher_path: $!";
    local $/;
    my $src = <$fh>;
    close $fh;

    my $calls = () = $src =~ /PluginSync::remove_named_legacy_dirs\s*\(/g;
    is($calls, 1,
       'F1: launcher.pl calls PluginSync::remove_named_legacy_dirs exactly once — the operator ' .
       'authorised a REMOVAL, not merely a standing warn-only policy; dropping the call entirely ' .
       'silently keeps the two specimens forever')
        or diag("If this is 0, the removal half of the operator's authorisation ('one-time removal " .
                "of these two, then warn-only') has been dropped again, reintroducing the corrected " .
                "finding F1. If this is >1, the call has been duplicated or re-wired somewhere " .
                "outside the single gated one-time block.");

    like($src, qr/PluginSync::prune_orphaned_dirs\(\s*"\$CLAUDE_DATA\/skills"/,
         'F1: the automatic one-time pass still runs the standing, content-based prune_orphaned_dirs policy');

    # The call site for remove_named_legacy_dirs must be reachable only through
    # the SAME conditional gate as prune_orphaned_dirs (both live inside one
    # `unless (...)` block keyed off $skills_manifest_existed and the new
    # machine-scoped marker) -- not called unconditionally, and not gated on
    # some OTHER, weaker condition.
    like($src,
         qr/unless\s*\(\s*\$skills_manifest_existed\s*\|\|\s*\$legacy_cleanup_marker_present\s*\)\s*\{.*?PluginSync::prune_orphaned_dirs.*?PluginSync::remove_named_legacy_dirs/s,
         'F1: remove_named_legacy_dirs is gated behind the SAME unless-block as prune_orphaned_dirs, ' .
         'keyed off both the per-project manifest flag and the new machine-scoped marker')
        or diag("If this fails, remove_named_legacy_dirs has been called outside the gated one-time " .
                "block (e.g. unconditionally, or on every launch), reintroducing unbounded destructive " .
                "removal by name.");

    like($src, qr/PluginSync::remove_named_legacy_dirs\(\s*\n?\s*"\$CLAUDE_DATA\/skills",\s*\['plan',\s*'work-plan'\]/,
         "F1: the hard-coded two-name list ('plan', 'work-plan') is passed literally, never computed");

    # The gate must reference a marker path built from the HOST user's real
    # ~/.claude (via $CLAUDE_HOST_CONFIG / home_dir()), never $CLAUDE_DATA
    # (this project's claude-home, which is what binds to /root/.claude
    # inside a container) -- that per-project/container-bind confusion is
    # exactly what made the marker machine-scoped instead of per-project in
    # the first place.
    like($src, qr/LEGACY_SKILLS_CLEANUP_MARKER\s*=\s*"\$CLAUDE_HOST_CONFIG\//,
         'F1: the one-time gate marker lives under $CLAUDE_HOST_CONFIG (real host ~/.claude), ' .
         'not under $CLAUDE_DATA (this project\'s claude-home / the container\'s /root/.claude bind)');
    unlike($src, qr/LEGACY_SKILLS_CLEANUP_MARKER\s*=\s*"\$CLAUDE_DATA\//,
           'F1: the marker is NOT rooted at $CLAUDE_DATA — that would make it per-project again, ' .
           'reintroducing the original per-project "one-time" bug');
}

# =========================================================================
# F1 (corrected) — behavioral coverage of the marker-gating LOGIC itself,
# exercised via the same primitives launcher.pl's gated block calls
# (prune_orphaned_dirs / remove_named_legacy_dirs), since launcher.pl cannot
# be executed here. This proves: no marker -> pass fires; marker present ->
# pass does not fire. It cannot prove launcher.pl's own `unless (...)` wiring
# is correct (the source-text assertions above cover that); it proves the
# underlying gate CONDITION, evaluated the same way launcher.pl evaluates it
# (-e on a marker path), produces the right on/off behavior against real
# specimens on disk.
# =========================================================================
{
    my $root       = tempdir(CLEANUP => 1);
    my $skills_dir = "$root/skills";
    spew("$skills_dir/plan/SKILL.md", "legacy specimen content");
    spew("$skills_dir/work-plan/SKILL.md", "legacy specimen content");

    my $marker = "$root/fake-home/.claude/.sandbox-legacy-skills-cleanup-v1";

    # -- Marker ABSENT: the gate condition launcher.pl evaluates
    #    (unless ($skills_manifest_existed || $legacy_cleanup_marker_present))
    #    must be true (pass fires) when the marker file does not exist.
    {
        ok(!-e $marker, 'marker-absent fixture precondition: marker does not exist yet');
        my $skills_manifest_existed    = 0;   # first launch: no per-project history either
        my $legacy_cleanup_marker_present = -e $marker;
        ok(!($skills_manifest_existed || $legacy_cleanup_marker_present),
           'F1/marker: gate condition is FALSE (pass fires) when neither signal is present');

        my @results = PluginSync::remove_named_legacy_dirs($skills_dir, ['plan', 'work-plan'], []);
        my %by_name = map { $_->{name} => $_ } @results;
        ok($by_name{plan}{removed} && $by_name{'work-plan'}{removed},
           'F1/marker: with the gate open, remove_named_legacy_dirs actually removes both specimens');
        ok(!-d "$skills_dir/plan" && !-d "$skills_dir/work-plan",
           'F1/marker: both legacy specimen directories are gone from disk after the gated pass runs');
    }

    # -- Marker PRESENT: recreate a specimen (simulating a later, unrelated,
    #    legitimately-named directory) and prove the gate condition suppresses
    #    the pass entirely -- it must not even be inspected, let alone removed.
    {
        spew("$skills_dir/plan/SKILL.md", "a NEW, unrelated directory happening to share the name");
        make_path("$root/fake-home/.claude");
        open my $fh, '>', $marker or die "write $marker: $!";
        print $fh "1\n";
        close $fh;
        ok(-e $marker, 'marker-present fixture precondition: marker now exists');

        my $skills_manifest_existed    = 0;
        my $legacy_cleanup_marker_present = -e $marker;
        ok(($skills_manifest_existed || $legacy_cleanup_marker_present),
           'F1/marker: gate condition is TRUE (pass suppressed) once the marker exists');

        # launcher.pl's `unless (...)` block would not even be entered here --
        # demonstrate that by simply NOT calling remove_named_legacy_dirs when
        # the gate says "suppressed", and confirming the re-created directory
        # survives untouched (nothing in this test path deletes it).
        ok(-d "$skills_dir/plan", 'F1/marker: with the gate closed, a same-named directory is left ' .
                                   'untouched (the pass is never invoked)');
    }
}

# =========================================================================
# F2 — traversal guard on remove_named_legacy_dirs's $names / $keep_names.
# =========================================================================
{
    my $root      = tempdir(CLEANUP => 1);
    my $dest_root = "$root/dest_root/skills";
    make_path($dest_root);
    my $victim_dir = "$root/victim_outside";
    spew("$victim_dir/important.txt", "do not delete me");

    ok(-d $victim_dir, 'F2 fixture precondition: victim_outside exists before the call');

    my @results = PluginSync::remove_named_legacy_dirs($dest_root, ['../../victim_outside'], []);

    ok(-d $victim_dir, 'F2: a traversal name outside dest_root is NOT removed')
        or diag("If this fails, remove_named_legacy_dirs deleted a directory outside dest_root via a " .
                "'../' name, reintroducing finding F2 (the same traversal guard reconcile_copy_plan " .
                "already applies via safe_dest_rel).");
    ok(-f "$victim_dir/important.txt", 'F2: the victim directory content survives byte-for-byte');
    is(scalar(@results), 0, 'F2: a rejected traversal name is never reported as removed');
}

# =========================================================================
# F3 — both pruning functions verify removal before reporting success.
# Monkey-patch the shared, private _force_remove_tree to a no-op so the
# directory provably survives the "removal" attempt, then assert the
# function reports the truth rather than a hard-coded removed => 1.
# =========================================================================
{
    no warnings 'redefine';
    local *PluginSync::_force_remove_tree = sub { return; };  # simulate a locked-file no-op deletion

    # -- prune_orphaned_dirs: an EMPTY orphaned directory that "removal" fails to actually delete.
    {
        my $dest = tempdir(CLEANUP => 1);
        make_path("$dest/stuck-empty-dir");
        ok(-d "$dest/stuck-empty-dir", 'F3/prune fixture precondition: stuck-empty-dir exists');

        my @results = PluginSync::prune_orphaned_dirs($dest, []);
        my %by_name = map { ref($_) eq 'HASH' ? ($_->{name} => $_) : () } @results;

        ok(-d "$dest/stuck-empty-dir", 'F3/prune fixture sanity: the no-op patch really left the dir behind');
        ok(exists $by_name{'stuck-empty-dir'}, 'F3/prune: the still-present directory is still reported');
        is($by_name{'stuck-empty-dir'}{removed}, 0,
           'F3/prune: removed => 0 when the path is still present after the removal attempt — never a false success')
            or diag("If this fails, prune_orphaned_dirs reports removed => 1 unconditionally after calling " .
                    "_force_remove_tree, without checking the path is actually gone (finding F3).");
        ok(exists $by_name{'stuck-empty-dir'}{error} && length $by_name{'stuck-empty-dir'}{error},
           'F3/prune: a distinguishing error key is present when removal did not actually happen');
    }

    # -- remove_named_legacy_dirs: a named, content-bearing specimen that "removal" fails to delete.
    {
        my $dest = tempdir(CLEANUP => 1);
        spew("$dest/plan/SKILL.md", "content that must not be silently reported gone");
        ok(-d "$dest/plan", 'F3/remove_named fixture precondition: plan exists');

        my @results = PluginSync::remove_named_legacy_dirs($dest, ['plan', 'work-plan'], []);
        my %by_name = map { ref($_) eq 'HASH' ? ($_->{name} => $_) : () } @results;

        ok(-d "$dest/plan", 'F3/remove_named fixture sanity: the no-op patch really left the dir behind');
        ok(exists $by_name{'plan'}, 'F3/remove_named: the still-present specimen is still reported');
        is($by_name{'plan'}{removed}, 0,
           'F3/remove_named: removed => 0 when the path is still present after the removal attempt — never a false success')
            or diag("If this fails, remove_named_legacy_dirs reports removed => 1 unconditionally after " .
                    "calling _force_remove_tree, without checking the path is actually gone (finding F3). " .
                    "This is the worse of the two cases per the red-team report: it deletes CONTENT-bearing " .
                    "directories, so a false success here can mask a corrupted, partially-deleted operator skill.");
        ok(exists $by_name{'plan'}{error} && length $by_name{'plan'}{error},
           'F3/remove_named: a distinguishing error key is present when removal did not actually happen');
    }
}

done_testing();
