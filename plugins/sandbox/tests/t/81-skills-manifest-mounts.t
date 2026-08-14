#!/usr/bin/env perl
# p01-sandbox-plugin-provisioning — spec.md §2.1, Observable behaviors 1-2.
#
# skills.pl's `cmd_mounts` is spec'd to grow an optional --manifest FILE
# argument. Behavior required (spec §2.1):
#   - Without --manifest: STDOUT contract ("$path\t$name\n" per resolved,
#     on-disk-verified skill) is UNCHANGED from today.
#   - With --manifest FILE: additionally accumulate, for every skill that
#     reaches the print line (never for the two warn+next paths), an entry
#     { name, dest_rel => name, host_path } and atomically write \@plan as a
#     JSON array to FILE.
#   - The entry MUST have NO `src` key. This is the load-bearing contract with
#     PluginSync::reconcile_copy_plan (spec.md §2.1): that function's copy
#     phase is gated on `defined $e->{src}`; omitting it is how "reconcile
#     without copying" is achieved by reusing that function unmodified for
#     skills, which are only ever delivered by a live RO bind mount.
#
# As of this commit, skills.pl's cmd_mounts does NOT implement --manifest at
# all (verified by reading skills.pl:1544-1568 during test authoring: %opts
# is read for selection_file only). So every manifest-writing assertion below
# is expected to fail on missing behavior, not a scaffolding bug: the
# fixture's own preconditions (skills exist on disk, are selected, print
# correctly) are asserted FIRST and independently, so a failure in the
# manifest assertions cannot be blamed on a broken fixture.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);

BEGIN { $ENV{SANDBOX_SKILLS_NO_DISPATCH} = 1; }
require "$Bin/../../scripts/skills.pl";

my $J = JSON::PP->new->canonical->utf8;

sub spew { my ($p, $c) = @_; my ($d) = $p =~ m{^(.*)/[^/]+$}; make_path($d) if $d && !-d $d;
           open my $f, '>:raw', $p or die "$p: $!"; print $f $c; close $f; }

# capture_mounts — invoke cmd_mounts with real-fd STDOUT/STDERR capture (a
# scalar-ref redirect dies on Git-for-Windows perl; see CLAUDE.md landmine).
sub capture_mounts {
    my (%opts) = @_;
    my ($ofh, $opath) = tempfile('t81-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('t81-errXXXXXX', TMPDIR => 1); close $efh;
    open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDOUT, '>:raw', $opath or do { open STDOUT, '>&', $oldout; die "reopen STDOUT: $!" };
    open STDERR, '>:raw', $epath or do { open STDERR, '>&', $olderr; die "reopen STDERR: $!" };
    $| = 1;
    my $rc = eval { cmd_mounts(%opts) };
    my $died = $@;
    open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
    open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
    my $out = do { open my $r, '<:raw', $opath or die; local $/; my $x = <$r>; close $r; $x // '' };
    my $err = do { open my $r, '<:raw', $epath or die; local $/; my $x = <$r>; close $r; $x // '' };
    unlink $opath, $epath;
    die $died if $died;
    return ($rc, $out, $err);
}

my $dir = tempdir(CLEANUP => 1);

# --- fixture: 3 skills selected. A and B resolve; C is selected but not
#     discoverable (hits the first warn+next path); D is selected, discoverable,
#     but its path has vanished from disk (hits the second warn+next path). ---
my $skill_a_path = "$dir/skills/skill-a"; make_path($skill_a_path);
my $skill_b_path = "$dir/skills/skill-b"; make_path($skill_b_path);
my $skill_d_path = "$dir/skills/skill-d-vanished";  # deliberately NOT created

my $snapshot = "$dir/discovery-snapshot.json";
spew($snapshot, $J->encode([
    { name => 'skill-a', source => 'custom', path => $skill_a_path },
    { name => 'skill-b', source => 'custom', path => $skill_b_path },
    { name => 'skill-d', source => 'custom', path => $skill_d_path },
]));

my $sel = "$dir/selected-skills.json";
spew($sel, $J->encode({ schema_version => 3, selected => ['skill-a', 'skill-b', 'skill-c', 'skill-d'] }));

# =========================================================================
# Observable behavior 1: no --manifest -> stdout contract unchanged.
# =========================================================================
{
    my ($rc, $out, $err) = capture_mounts(
        selection_file => $sel, discovery_snapshot => $snapshot,
    );
    is($rc, 0, 'no-manifest: cmd_mounts returns 0');
    my @lines = grep { length } split /\r?\n/, $out;
    is(scalar(@lines), 2, 'no-manifest: exactly 2 resolved skills printed (a, b)');
    ok((grep { $_ eq "$skill_a_path\tskill-a" } @lines), 'no-manifest: skill-a line has the documented path\tname shape');
    ok((grep { $_ eq "$skill_b_path\tskill-b" } @lines), 'no-manifest: skill-b line has the documented path\tname shape');
    like($err, qr/selected skill 'skill-c' is no longer discoverable/, 'no-manifest: warn+next fires for undiscoverable skill-c (fixture precondition)');
    like($err, qr/skill 'skill-d'.*vanished/, 'no-manifest: warn+next fires for vanished skill-d (fixture precondition)');
}

# =========================================================================
# Observable behavior 2 + the src-less contract: --manifest FILE.
# =========================================================================
{
    my $manifest = "$dir/host-tier-skills.json";
    ok(!-e $manifest, 'manifest fixture precondition: manifest file does not exist before the call');

    my ($rc, $out, $err) = capture_mounts(
        selection_file => $sel, discovery_snapshot => $snapshot, manifest => $manifest,
    );
    is($rc, 0, 'with-manifest: cmd_mounts still returns 0');

    my @lines = grep { length } split /\r?\n/, $out;
    is(scalar(@lines), 2, 'with-manifest: stdout contract is UNCHANGED by adding --manifest (still 2 lines)');

    ok(-f $manifest, 'with-manifest: manifest file was written to disk')
        or diag("cmd_mounts does not yet implement --manifest (skills.pl:1544-1568 as read); this is the expected missing-behavior failure this test exists to catch");

    {
        # Deliberately NOT a SKIP block: every one of these must run and FAIL
        # loudly when the manifest is absent, not be silently skipped — a
        # missing-manifest state means "0 entries, no dest_rel, no host_path",
        # which every assertion below already expresses correctly as a failure.
        my $raw_plan = -f $manifest
            ? eval { $J->decode(do { open my $f, '<:raw', $manifest or die; local $/; <$f> }) }
            : undef;
        is(ref $raw_plan, 'ARRAY', 'manifest: top-level shape is a JSON array');
        my $plan = (ref $raw_plan eq 'ARRAY') ? $raw_plan : [];  # safe fallback for indexing below only
        is(scalar(@$plan), 2, 'manifest: exactly 2 entries (one per resolved skill; NOT one for skill-c or skill-d)');

        my %by_name = map { $_->{name} => $_ } @$plan;
        ok(exists $by_name{'skill-a'}, 'manifest: skill-a entry present');
        ok(exists $by_name{'skill-b'}, 'manifest: skill-b entry present');
        ok(!exists $by_name{'skill-c'}, 'manifest: undiscoverable skill-c NEVER recorded (manifest may only claim what was actually placed)');
        ok(!exists $by_name{'skill-d'}, 'manifest: vanished skill-d NEVER recorded');

        is($by_name{'skill-a'}{dest_rel}, 'skill-a', 'manifest: dest_rel === name (per spec §2.1)');
        is($by_name{'skill-a'}{host_path}, $skill_a_path, 'manifest: host_path is the resolved on-disk skill path');
        ok(!exists $by_name{'skill-a'}{src},
           'manifest: entry has NO src key — the load-bearing no-copy contract with reconcile_copy_plan (spec §2.1)')
            or diag('A src key here would make a future reconcile_copy_plan call actually COPY skill content into claude-home, which spec.md explicitly forbids (skills are transport-only via live RO bind).');
    }
}

done_testing();
