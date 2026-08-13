#!/usr/bin/env perl
# Oracle for b02-backpack-owns-path — DC4, static content assertions.
# Spec section 2.5's docs sibling: AC11-AC13. No subprocess execution here --
# these are pure text checks over tracked files.
#
# The spec's Context section confirms the filer's "docs tell npm-global
# authors to set PATH" claim is ABSENT from every backpack doc in this repo
# today -- so these tests do NOT assert removal of anything (there is
# nothing to remove). They assert the NEW contract is stated.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $ROOT = "$Bin/../..";   # plugins/backpack

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or BAIL_OUT("cannot open $path: $!");
    local $/;
    return <$fh>;
}

# ===========================================================================
# AC11 -- skills/add/SKILL.md documents --bin_dirs and states entries no
# longer need hand-rolled `export PATH=...` preambles.
# ===========================================================================
{
    my $path = "$ROOT/skills/add/SKILL.md";
    ok(-f $path, "AC11: $path exists") or BAIL_OUT('fixture broken');
    my $src = slurp($path);

    like($src, qr/--bin_dirs/,
        'AC11: skills/add/SKILL.md documents the --bin_dirs flag') or diag('not found');
    like($src, qr/PATH/,
        'AC11: skills/add/SKILL.md mentions PATH at all (today it mentions PATH nowhere)')
        or diag('not found -- confirms the pre-edit baseline: PATH appears in NO backpack doc');
    like($src, qr/(?:no longer|not|don't|need(?:s)? not).{0,60}\bexport PATH\b|export PATH.{0,60}(?:no longer|unnecessary|not needed)/is,
        'AC11: states entries no longer need a hand-rolled export PATH=... preamble')
        or diag('the new contract (bin_dirs replaces hand-rolled PATH preambles) is not stated');
}

# ===========================================================================
# AC12 -- skills/install/SKILL.md documents the PROFILE_PATH/PATHDIRS output
# lines.
# ===========================================================================
{
    my $path = "$ROOT/skills/install/SKILL.md";
    ok(-f $path, "AC12: $path exists") or BAIL_OUT('fixture broken');
    my $src = slurp($path);

    like($src, qr/PROFILE_PATH/, 'AC12: skills/install/SKILL.md documents PROFILE_PATH') or diag('not found');
    like($src, qr/PATHDIRS/,     'AC12: skills/install/SKILL.md documents PATHDIRS')     or diag('not found');
}

# ===========================================================================
# AC13 -- backpack.pl's schema-comment block documents bin_dirs.
# ===========================================================================
{
    my $path = "$ROOT/scripts/backpack.pl";
    ok(-f $path, "AC13: $path exists") or BAIL_OUT('fixture broken');
    my $src = slurp($path);

    # Isolate the schema comment block (starts at "# Schema (backpack v2):"
    # per the file's own header, per the spec's citation) so a bin_dirs
    # mention buried somewhere unrelated in the file doesn't count.
    my ($schema_block) = $src =~ /(# Schema \(backpack v2\):.*?\n\n)/s;
    ok(defined $schema_block, 'AC13: the schema comment block is present at all (anchor found)')
        or BAIL_OUT('cannot locate the schema comment block to check');
    like($schema_block, qr/bin_dirs/,
        'AC13: the schema comment block documents the new bin_dirs field') or diag($schema_block);
}

done_testing();
