#!/usr/bin/env perl
# b51-turn-cap-single-source oracle.
#
# WHY THIS EXISTS
#
# A turn cap is defined in TWELVE places under three different field names
# (`max_turns`, `maxTurns`, `steps`) and the copies have drifted three separate
# times, each time silently:
#
#   1. b23 raised the ledger max_turns authoring default 80 -> 150 in prose and
#      never touched plugins/butler/agents/bp-scout.md's `maxTurns: 15`.
#   2. b23 ALSO never touched templates/package-ledger.md, which `git blame`
#      still puts at the ORIGINAL commit's `max_turns: 80` -- so the authoring
#      prose says 150 while the template every package is authored from says 80.
#   3. b49 raised the agent caps and missed the OpenCode `steps:` twins, caught
#      only because t/81 happened to assert that one mirror.
#
# Frontmatter cannot reference a variable, so a literal MUST be physically
# present in each agent file. True single-sourcing is therefore impossible; what
# is achievable is a CANONICAL source plus a guard that makes drift a red suite
# instead of a silent two-month divergence. That is what this file is.
#
# NO SHAPE PINS. Role names and counts come from the config and the glob, never
# from a list here; numeric assertions are floors or equalities against the
# config, never hardcoded values. (t/00-oracle-hygiene.t.)

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Temp ();

my $ROOT   = File::Spec->rel2abs("$Bin/../../../..");        # -> /project
my $MODULE = "$ROOT/plugins/butler/scripts/bp-turn-caps.pl";
my $CONFIG = "$ROOT/plugins/butler/turn-caps.json";

ok(-f $MODULE, 'bp-turn-caps.pl exists') or BAIL_OUT("missing: $MODULE");
ok(-f $CONFIG, 'turn-caps.json exists')  or BAIL_OUT("missing: $CONFIG");

require $MODULE;

# ------------------------------------------------------ C1: the canonical source ---

my $cfg = eval { BpTurnCaps::load($CONFIG) };
ok(!$@ && ref($cfg) eq 'HASH', 'C1: BpTurnCaps::load returns a hashref') or BAIL_OUT("load failed: $@");

ok(defined $cfg->{ceiling},             'C1: config declares a ceiling');
ok(defined $cfg->{coordinator_default}, 'C1: config declares a coordinator_default');
is(ref($cfg->{roles}), 'HASH',          'C1: config declares a roles map');
cmp_ok(scalar(keys %{ $cfg->{roles} }), '>', 0, 'C1: the roles map is non-empty');

# ------------------------------------------- C2: the coordinator is not out-ranked ---
#
# A coordinator dispatches SEVERAL workers plus scouting, validation and ledger
# work. Capping it below any single worker it dispatches is the inversion that
# the 80-vs-800 divergence produced.

my $max_role = 0;
for my $r (keys %{ $cfg->{roles} }) {
    $max_role = $cfg->{roles}{$r} if $cfg->{roles}{$r} > $max_role;
}
cmp_ok($cfg->{coordinator_default}, '>=', $max_role,
    'C2: coordinator_default is at least the largest worker cap (it does strictly more)');

# ------------------------------------------------- C3: the ceiling leaves headroom ---
#
# widen_max_turns grows to 2x the author's intent. A ceiling below that truncates
# the widen policy instead of only "truncating the absurd", which is what its own
# comment says it is for.

cmp_ok($cfg->{ceiling}, '>=', 2 * $cfg->{coordinator_default},
    'C3: ceiling leaves room for the documented 2x widen rather than binding on it');

# ----------------------------------------------------------- C4: zero live drift ---
#
# THE REGRESSION GUARD -- the assertion that would have caught all three historical
# divergences on the day each landed.

my $drift = eval { BpTurnCaps::drift($cfg, $ROOT) };
ok(!$@, 'C4: BpTurnCaps::drift ran') or diag("error: $@");
is(ref($drift), 'ARRAY', 'C4: drift returns an arrayref');

is(scalar(@$drift), 0, 'C4: no surface has drifted from the canonical source')
    or diag("drifted:\n" . join('', map {
        sprintf("  %-12s %-58s %-10s want=%s have=%s\n",
            $_->{surface}, $_->{file}, $_->{field},
            $_->{want} // '?', defined $_->{have} ? $_->{have} : '(absent)')
    } @$drift));

# --------------------------------- C5: every agent role is KNOWN to the config ---
#
# A new agent added without a config entry must fail loudly, not default silently.

for my $path (sort glob("$ROOT/plugins/*/agents/*.md")) {
    my ($role) = $path =~ m{([^/]+)\.md$};
    ok(defined $cfg->{roles}{$role},
        "C5: role '$role' has a canonical cap (a new agent cannot default silently)");
}

# ------------------------------------------------------- C6: drift is DETECTABLE ---
#
# Non-vacuity, proven against a scratch tree rather than argued. Without this, C4
# passing could mean "nothing to check" rather than "everything agrees".

{
    my $tmp = File::Temp->newdir(CLEANUP => 1);
    my $fake = "$tmp/plugins/butler/agents";
    make_path($fake);

    my ($role) = sort keys %{ $cfg->{roles} };
    my $wrong  = $cfg->{roles}{$role} + 1;
    open my $fh, '>', "$fake/$role.md" or die $!;
    print $fh "---\nname: $role\nmaxTurns: $wrong\n---\n\nbody\n";
    close $fh;

    my $d = BpTurnCaps::drift($cfg, "$tmp");
    cmp_ok(scalar(@$d), '>', 0, 'C6: a deliberately wrong maxTurns is reported as drift');
    ok((grep { ($_->{have} // '') eq "$wrong" } @$d),
        'C6: the drift record carries the offending value it actually found');
}

# ------------------------------------------------------------- C7: the CLI verb ---
#
# `check` is what a human or a hook runs; it must agree with the library and must
# signal by EXIT CODE, since that is all a hook can read.

{
    my $out = `perl "$MODULE" check --root "$ROOT" --config "$CONFIG" 2>&1`;
    my $rc  = $? >> 8;
    is($rc, 0, 'C7: `check` exits 0 against the real tree') or diag($out);
}

done_testing();
