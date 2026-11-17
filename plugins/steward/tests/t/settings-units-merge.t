#!/usr/bin/env perl
# platform: any
# SettingsUnits.pm: the one-level dotted unit model every settings sync shares,
# and merge3, the per-unit three-way merge a sandbox's settings.json goes
# through when its container is created (plugins/sandbox/scripts/
# SandboxSettings.pm).
#
# WHY. A Rebuild used to copy the sandbox preset over the sandbox's
# settings.json, so every change made inside the sandbox was lost without a
# merge, a backup or a word. The merge keeps what only the sandbox changed,
# takes what only the preset changed, and asks about a unit both changed
# (keeping the sandbox's value unless the answer is "take"). These cases pin
# that matrix, deletions included, at both unit granularities.
#
# Pure: no files, no processes.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;

use lib "$Bin/../../scripts";
require_ok('SettingsUnits') or BAIL_OUT('SettingsUnits.pm does not load');

sub merge {
    my ($base, $local, $remote, $answer) = @_;
    my @asked;
    my $r = SettingsUnits::merge3(
        base => $base, local => $local, remote => $remote,
        resolve => sub { push @asked, $_[0]; return $answer },
    );
    return ($r, \@asked);
}

my $C = JSON::PP->new->canonical;
sub cj { return $C->encode($_[0]) }

# ---------------------------------------------------------------------------
# compute_units: the model promote.pl and json-diff.pl agree on
# ---------------------------------------------------------------------------
{
    my @u = SettingsUnits::compute_units(
        { a => 1, env => { X => 1, Y => 2 }, only => 1 },
        { a => 1, env => { X => 1, Z => 3 }, gone => 2 },
    );
    my %rel = map { $_->{name} => $_->{relation} } @u;
    is_deeply(\%rel, {
        a => 'identical', 'env.X' => 'identical', 'env.Y' => 'only_left',
        'env.Z' => 'only_right', only => 'only_left', gone => 'only_right',
    }, 'compute_units: a differing object expands one level; others stay whole');

    my @c = SettingsUnits::compute_units(
        { env => { X => 1 }, 'env.X' => 5 },
        { env => { X => 2 }, 'env.X' => 5 },
    );
    my %crel = map { $_->{name} => $_->{relation} } @c;
    is($crel{env}, 'diverged', 'compute_units: a dotted-name collision keeps the object whole');
}

# ---------------------------------------------------------------------------
# the merge matrix, top-level units
# ---------------------------------------------------------------------------
my $base = { keep => 1, shared => 'b', drop_by_preset => 1, drop_by_sandbox => 1, both => 'b',
             both_same => 'b', del_vs_change => 'b' };

{
    my $local  = { %$base, keep => 2, both => 'sandbox', both_same => 'x', del_vs_change => 'sandbox' };
    delete $local->{drop_by_sandbox};
    my $remote = { %$base, shared => 'preset', both => 'preset', both_same => 'x', added => 'new' };
    delete $remote->{drop_by_preset};
    delete $remote->{del_vs_change};
    my $local_before = cj($local);

    my ($r, $asked) = merge($base, $local, $remote, undef);
    my $res = $r->{result};
    is($res->{keep}, 2,          'sandbox-only change is kept');
    is($res->{shared}, 'preset', 'preset-only change is taken');
    is($res->{added}, 'new',     'preset-only addition is taken');
    ok(!exists $res->{drop_by_preset},  'preset-only deletion is taken (the key goes)');
    ok(!exists $res->{drop_by_sandbox}, 'sandbox-only deletion is kept (the key stays gone)');
    is($res->{both_same}, 'x',   'both changed to the same value: agreed, no question');
    is($res->{both}, 'sandbox',  'both changed differently, no answer: the sandbox value is kept (the default)');
    is($res->{del_vs_change}, 'sandbox', 'preset deleted what the sandbox changed: the sandbox value is kept by default');
    is_deeply([ sort map { $_->{name} } @$asked ], [ 'both', 'del_vs_change' ],
        'exactly the two units both sides changed differently were asked about');
    my ($dvc) = grep { $_->{name} eq 'del_vs_change' } @$asked;
    ok($dvc->{local_found} && !$dvc->{remote_found} && $dvc->{base_found},
        'the conflict record says which sides have the unit');
    is_deeply([ sort @{ $r->{taken} } ], [ 'added', 'drop_by_preset', 'shared' ], 'taken lists the preset-only units');
    is_deeply([ sort @{ $r->{kept} } ], [ 'drop_by_sandbox', 'keep' ], 'kept lists the sandbox-only units');
    is_deeply($r->{agreed}, [ 'both_same' ], 'agreed lists the unit both changed alike');
    ok($r->{changed}, 'changed is set when the result differs from the sandbox file');
    is(cj($local), $local_before, 'the sandbox side is never modified in place');

    my ($t) = merge($base, $local, $remote, 'take');
    is($t->{result}{both}, 'preset', 'answer "take": the preset value replaces the sandbox value');
    ok(!exists $t->{result}{del_vs_change}, 'answer "take" on a preset deletion removes the key');
    is($t->{result}{keep}, 2, '... and a sandbox-only change is still kept');
    is(scalar(grep { $_->{choice} eq 'take' } @{ $t->{conflicts} }), 2, 'the result records each choice');
}

{
    my $s = { a => 1, b => 2 };
    my ($r) = merge($s, { a => 1, b => 2 }, { a => 1, b => 2 }, undef);
    ok(!$r->{changed}, 'nothing changed on either side: changed is 0');
    my ($r2) = merge($s, { a => 1, b => 3 }, { a => 1, b => 2 }, undef);
    ok(!$r2->{changed}, 'only the sandbox changed: the result is the sandbox file, changed is 0');

    my ($both_del, $asked) = merge($s, { a => 1 }, { a => 1 }, undef);
    ok(!exists $both_del->{result}{b} && !@$asked, 'both deleted the same key: agreed, no question');
}

# ---------------------------------------------------------------------------
# one level down: env.X style units
# ---------------------------------------------------------------------------
{
    my $b = { env => { A => '1', B => '1' }, permissions => { allow => ['x'] } };
    my $l = { env => { A => 'sandbox', B => '1' }, permissions => { allow => ['x', 'y'] } };
    my $r = { env => { A => '1', B => '1', C => 'new' }, permissions => { allow => ['x'], deny => ['z'] } };
    my ($m, $asked) = merge($b, $l, $r, undef);
    is_deeply($m->{result}{env}, { A => 'sandbox', B => '1', C => 'new' },
        'env.A changed in the sandbox and env.C added by the preset: both land');
    is_deeply($m->{result}{permissions}, { allow => ['x', 'y'], deny => ['z'] },
        'permissions.allow from the sandbox, permissions.deny from the preset');
    ok(!@$asked, 'different sub-keys of one object are not a conflict');

    my $r2 = { env => { A => 'preset', B => '1' } , permissions => $b->{permissions} };
    my ($m2, $asked2) = merge($b, $l, $r2, undef);
    is_deeply([ map { $_->{name} } @$asked2 ], [ 'env.A' ], 'the same sub-key changed on both sides is one conflict named env.A');
    is($m2->{result}{env}{A}, 'sandbox', '... defaulting to the sandbox value');
    my ($m3) = merge($b, $l, $r2, 'take');
    is($m3->{result}{env}{A}, 'preset', '... or the preset value on "take"');
    is($m3->{result}{env}{B}, '1', '... leaving the rest of env alone');

    my $r3 = { env => { A => '1' }, permissions => $b->{permissions} };
    my ($m4, $asked4) = merge($b, $l, $r3, undef);
    ok(!exists $m4->{result}{env}{B} && $m4->{result}{env}{A} eq 'sandbox' && !@$asked4,
        'the preset removing env.B removes only that sub-key');
}

{
    # Mixed granularity: the sandbox replaced env wholesale, the preset changed
    # two of its sub-keys. One conflict, at env, not two.
    my $b = { env => { A => '1', B => '1' } };
    my $l = { env => 'not an object any more' };
    my $r = { env => { A => '2', B => '2' } };
    my ($m, $asked) = merge($b, $l, $r, undef);
    is_deeply([ map { $_->{name} } @$asked ], [ 'env' ], 'whole-object change vs sub-key changes: one conflict at env');
    is($m->{result}{env}, 'not an object any more', '... keeping the sandbox value by default');
    my ($t) = merge($b, $l, $r, 'take');
    is_deeply($t->{result}{env}, { A => '2', B => '2' }, '... or the whole preset object on "take"');

    my $r_gone = {};
    my ($g, $asked_g) = merge($b, { env => { A => 'sandbox', B => '1' } }, $r_gone, 'take');
    is_deeply([ map { $_->{name} } @$asked_g ], [ 'env' ], 'the preset deleting env the sandbox edited inside: one conflict at env');
    ok(!exists $g->{result}{env}, '... "take" removes env');
}

# ---------------------------------------------------------------------------
# no base (the sandbox predates the record): every difference is the sides' own
# ---------------------------------------------------------------------------
{
    my ($m, $asked) = merge(undef, { a => 1, mine => 1, same => 's' }, { a => 2, theirs => 1, same => 's' }, undef);
    is_deeply($m->{result}, { a => 1, mine => 1, theirs => 1, same => 's' },
        'no base: a unit on one side only is kept or taken, an equal unit is left alone');
    is_deeply([ map { $_->{name} } @$asked ], [ 'a' ], 'no base: a unit both have with different values is asked about');
}

# ---------------------------------------------------------------------------
# the *_at_path helpers never autovivify through a non-object
# ---------------------------------------------------------------------------
{
    my $d = { env => 'str' };
    SettingsUnits::delete_at_path($d, [ 'env', 'X' ]);
    is($d->{env}, 'str', 'delete_at_path below a non-object is a no-op');
    SettingsUnits::take_at_path($d, [ 'env', 'X' ], { env => { X => 1 } });
    is_deeply($d->{env}, { X => 1 }, 'take_at_path below a non-object takes the whole parent');
    my ($f) = SettingsUnits::value_at_path(undef, [ 'a' ]);
    ok(!$f, 'value_at_path on a non-object finds nothing');
}

done_testing();
