#!/usr/bin/env perl
# 181 — the launch decision, driven through every state it can be in.
#
# WHY THIS EXISTS, AND WHY IT IS NOT A GREP. t/180 asserts the SHAPE of the
# launcher source. That is worth having, but it cannot tell you what the
# launcher would DO in a given state — and the operator was right to object to
# being handed logic whose only real exercise was their next launch.
#
# The decision could not be executed before, because it was inline conditionals
# in a 5000-line script whose surrounding code builds images and starts
# containers. So it was extracted into decide_launch_plan(), which is pure: no
# podman, no I/O, no globals. This file drives it through all 4 (image ×
# container) states crossed with forced / stale / each operator answer, and
# checks the four outputs each time.
#
# THE CASE THE OPERATOR ASKED ABOUT (2026-09-07): "image missing → Continue —
# will you try to build a base image of a newer version while trying to use the
# existing container of an older version?" The answer is yes, deliberately, and
# AC4 pins it with the reasoning: a container descending from a superseded
# image is the routine state after ANY rebuild (launcher.pl:2903 says so), and
# the launch gate aborts with 'image missing' when an EXITED container has no
# image (:4882) — which is the normal between-sessions state. Skipping that
# build turns a recoverable sandbox into a failed launch.
#
# AC1  nothing is asked, and nothing rebuilt, when nothing is stale
# AC2  a forced reason never asks and always rebuilds
# AC3  each operator answer maps to the right plan
# AC4  a missing image is always built, including when a container exists
# AC5  the container is only removed when it exists AND a rebuild happens
# AC6  cancel decides nothing else
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

# Extract the two pure subs and eval them into a scratch package. The launcher
# cannot be `require`d: it runs a launch on load.
my $SRC = do {
    my $p = "$Bin/../../scripts/launcher.pl";
    open my $fh, '<:raw', $p or do { plan skip_all => "cannot read $p" };
    local $/;
    my $c = <$fh>;
    close $fh;
    $c;
};

my ($decide) = $SRC =~ /(sub\s+decide_launch_plan\s*\{.*?\n\})/s;
my ($wants)  = $SRC =~ /(sub\s+plan_wants_prompt\s*\{.*?\n\})/s;
my ($forced) = $SRC =~ /(sub\s+decide_forced_rebuild\s*\{.*?\n\})/s;

ok(defined $decide, 'precondition: decide_launch_plan is extractable')
    or do { done_testing(); exit };
ok(defined $wants, 'precondition: plan_wants_prompt is extractable')
    or do { done_testing(); exit };
ok(defined $forced, 'precondition: decide_forced_rebuild is extractable')
    or do { done_testing(); exit };

my $PKG = 'LaunchPlanUnderTest';
my $ok  = eval "package $PKG;\nuse strict;\nuse warnings;\n$decide\n$wants\n$forced\n1;\n";  ## no critic
ok($ok, 'precondition: the subs eval cleanly') or do { diag($@); done_testing(); exit };

sub forced {
    my (@a) = @_;
    no strict 'refs';   ## no critic
    return &{"${PKG}::decide_forced_rebuild"}(@a);
}

# --- AC0: which states force a rebuild -------------------------------------
#
# THE CASE THAT WAS MISSING. `claude-version` is written only inside the
# container-create block (launcher.pl:4754), so a container whose .launcher dir
# was cleared, moved, or written by an older launcher exists with NO recorded
# version. The original guard was `if (-f $file)`, which simply skipped the
# check — letting an unknown-version container through to "continue" and
# straight into the unsupported skew this force exists to prevent.
{
    is(forced(0, undef,     '2.1.257'), undef,
       'AC0 no container: nothing to be skewed against, no force');
    is(forced(0, '2.1.100', '2.1.257'), undef,
       'AC0 no container: a stale version record alone does not force');

    is(forced(1, '2.1.257', '2.1.257'), undef,
       'AC0 container on the host version: no force');

    ok(defined forced(1, '2.1.100', '2.1.257'),
       'AC0 container on a different version: forced');
    like(forced(1, '2.1.100', '2.1.257'), qr/2\.1\.100.*2\.1\.257/,
         'AC0 and the reason names both versions');

    ok(defined forced(1, undef, '2.1.257'),
       'AC0 container with NO recorded version: forced')
        or diag('  absence of evidence is not evidence of a match');
    like(forced(1, undef, '2.1.257'), qr/unrecorded/,
         'AC0 and the reason says the version is unrecorded, not that it mismatched');

    ok(defined forced(1, '', '2.1.257'),
       'AC0 an empty version record forces too');
    ok(defined forced(1, "  \n", '2.1.257'),
       'AC0 a whitespace-only record forces too');

    # A trailing newline from _read_file must not read as a mismatch.
    is(forced(1, "2.1.257\n", '2.1.257'), undef,
       'AC0 a trailing newline in the record is not a mismatch')
        or diag('  _read_file returns the file verbatim; an unchomped compare would '
              . 'force a rebuild on every single launch');
}

sub plan {
    my (%s) = @_;
    no strict 'refs';   ## no critic
    return &{"${PKG}::decide_launch_plan"}(%s);
}
sub wants {
    my (%s) = @_;
    no strict 'refs';   ## no critic
    return &{"${PKG}::plan_wants_prompt"}(%s);
}

# Every combination of what can exist on disk.
my @WORLDS = (
    { image_exists => 1, container_exists => 1, name => 'image+container' },
    { image_exists => 1, container_exists => 0, name => 'image only'      },
    { image_exists => 0, container_exists => 1, name => 'container only'  },
    { image_exists => 0, container_exists => 0, name => 'nothing'         },
);

# --- AC1: quiet when there is nothing to decide -----------------------------
for my $w (@WORLDS) {
    my $p = plan(%$w, stale_count => 0);
    is(wants(%$w, stale_count => 0), 0, "AC1 $w->{name}: no prompt when nothing is stale");
    is($p->{rebuild}, 0, "AC1 $w->{name}: nothing is rebuilt");
    is($p->{remove_container}, 0, "AC1 $w->{name}: the container is left alone");
    # ...but a missing image is still restored. See AC4.
    is($p->{build_image}, ($w->{image_exists} ? 0 : 1),
       "AC1 $w->{name}: builds only if the image is absent");
}

# --- AC2: forced never asks ---------------------------------------------------
for my $w (@WORLDS) {
    my %s = (%$w, force_reason => 'version mismatch', stale_count => 3);
    is(wants(%s), 0, "AC2 $w->{name}: a forced reason suppresses the prompt")
        or diag('  a forced remediation that asks can be declined; that is the B18 lesson');
    my $p = plan(%s);
    is($p->{forced},  1, "AC2 $w->{name}: reported as forced");
    is($p->{rebuild}, 1, "AC2 $w->{name}: rebuilds regardless of state");
    is($p->{build_image}, 1, "AC2 $w->{name}: and always builds the image");
}

# A forced reason outranks even an explicit 'continue' — the operator was not
# asked, so a stale answer from elsewhere must not weaken it.
{
    my $p = plan(image_exists => 1, container_exists => 1,
                 force_reason => 'version mismatch', stale_count => 0,
                 operator => 'continue');
    is($p->{rebuild}, 1, 'AC2 a forced rebuild is not overridden by a continue answer');
}

# --- AC3: the operator's answer ----------------------------------------------
for my $w (@WORLDS) {
    my %base = (%$w, stale_count => 2);

    is(wants(%base), 1, "AC3 $w->{name}: a stale reason does ask");

    # Not answered yet: decide nothing, request the prompt.
    my $unasked = plan(%base);
    is($unasked->{ask}, 0, "AC3 $w->{name}: the plan itself carries no answer yet");
    is($unasked->{rebuild}, 0, "AC3 $w->{name}: and commits to no rebuild before one");

    my $reb = plan(%base, operator => 'rebuild');
    is($reb->{rebuild}, 1, "AC3 $w->{name}: rebuild => rebuild");
    is($reb->{build_image}, 1, "AC3 $w->{name}: rebuild always builds");

    my $con = plan(%base, operator => 'continue');
    is($con->{rebuild}, 0, "AC3 $w->{name}: continue => no rebuild");

    my $can = plan(%base, operator => 'cancel');
    is($can->{cancel}, 1, "AC3 $w->{name}: cancel => cancel");
}

# --- AC4: THE OPERATOR'S EDGE CASE -------------------------------------------
# A missing image is built even when a container exists and will be reused.
{
    my $p = plan(image_exists => 0, container_exists => 1,
                 stale_count => 0);
    is($p->{build_image}, 1,
       'AC4 image missing + container present: the image IS restored')
        or diag('  the launch gate aborts with "image missing" for an EXITED container '
              . '(:4882), which is the normal between-sessions state');
    is($p->{rebuild}, 0,
       'AC4 ...without rebuilding, so the existing container is kept');
    is($p->{remove_container}, 0,
       'AC4 ...and without removing it');

    # Continuing past a stale prompt behaves the same way.
    my $c = plan(image_exists => 0, container_exists => 1,
                 stale_count => 2, operator => 'continue');
    is($c->{build_image}, 1, 'AC4 the same holds when the operator chose continue');
    is($c->{remove_container}, 0, 'AC4 and the container still survives');
}

# The counter-case: with the image present, continue builds nothing at all.
{
    my $p = plan(image_exists => 1, container_exists => 1,
                 stale_count => 2, operator => 'continue');
    is($p->{build_image}, 0, 'AC4 counter-check: continue with everything present builds nothing');
}

# --- AC5: container removal ---------------------------------------------------
{
    is(plan(image_exists => 1, container_exists => 1,
            stale_count => 1, operator => 'rebuild')->{remove_container}, 1,
       'AC5 rebuild + existing container => remove it');
    is(plan(image_exists => 1, container_exists => 0,
            stale_count => 1, operator => 'rebuild')->{remove_container}, 0,
       'AC5 rebuild with no container => nothing to remove')
        or diag('  `podman rm -f` on a nonexistent container is noise in the launch output');
    is(plan(image_exists => 1, container_exists => 1,
            stale_count => 1, operator => 'continue')->{remove_container}, 0,
       'AC5 continue never removes the container');
}

# --- AC6: cancel is inert ------------------------------------------------------
{
    my $p = plan(image_exists => 0, container_exists => 0,
                 stale_count => 1, operator => 'cancel');
    is($p->{cancel}, 1, 'AC6 cancel is reported');
    is($p->{build_image}, 0, 'AC6 and nothing is built');
    is($p->{rebuild}, 0, 'AC6 nothing is rebuilt');
    is($p->{remove_container}, 0, 'AC6 nothing is removed');
}

# --- Total: no state produces an incoherent plan -------------------------------
# A plan that removes the container without rebuilding, or cancels while also
# doing work, would be self-contradictory in a way no single assertion above
# would necessarily catch.
{
    my $bad = 0;
    for my $w (@WORLDS) {
        for my $force (undef, 'version mismatch') {
            for my $stale (0, 2) {
                for my $ans (undef, 'rebuild', 'continue', 'cancel') {
                    my $p = plan(%$w, force_reason => $force,
                                 stale_count => $stale, operator => $ans);
                    $bad++ if $p->{remove_container} && !$p->{rebuild};
                    $bad++ if $p->{cancel} && ($p->{rebuild} || $p->{build_image}
                                               || $p->{remove_container});
                    $bad++ if $p->{rebuild} && !$p->{build_image};
                }
            }
        }
    }
    is($bad, 0, 'no combination of state, force, staleness and answer yields an incoherent plan');
}

done_testing();
