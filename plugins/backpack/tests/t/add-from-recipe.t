#!/usr/bin/env perl
# platform: any
# `backpack.pl add --recipe NAME` and the recipes it reads.
#
# Since 2026-10-30 the sandbox image ships no Node; a project declares Node and
# pnpm in its backpack through the sanctioned recipe recipes/node-pnpm.json.
# What must hold for that to be the reproducible path it claims to be:
#   1. every tracked recipe is a valid one-item backpack file (so `validate`
#      checks it, and its install/verify at least parse as shell);
#   2. `add --recipe` writes exactly the recipe's fields, byte for byte;
#   3. a flag given on the command line overrides that one field only;
#   4. the recipe name is a bare word, never a path, and an unknown name says
#      which recipes exist.
# What the node-pnpm recipe itself pins is asserted in
# plugins/sandbox/tests/t/node-pnpm-toolchain.t, next to the image settings it
# depends on.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use JSON::PP;
use Test::More;

my $BP      = File::Spec->rel2abs(File::Spec->catfile($Bin, qw(.. .. scripts backpack.pl)));
my $RECIPES = File::Spec->rel2abs(File::Spec->catfile($Bin, qw(.. .. recipes)));
ok(-f $BP, "backpack.pl exists at $BP") or BAIL_OUT("missing $BP");
ok(-d $RECIPES, "the recipes directory exists at $RECIPES") or BAIL_OUT("missing $RECIPES");

my $tmp  = tempdir(CLEANUP => 1);
my $capn = 0;

sub slurp_raw {
    my $p = shift;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# run_bp(@args) -> ($exit_code, $combined_output). system(LIST), output captured
# through a temp file (never an in-memory handle: Git-for-Windows perl).
sub run_bp {
    my @args = @_;
    my $cap = File::Spec->catfile($tmp, "cap." . (++$capn));
    open my $oo, '>&', \*STDOUT or die "dup STDOUT: $!";
    open my $oe, '>&', \*STDERR or die "dup STDERR: $!";
    open STDOUT, '>:raw', $cap  or die "redirect STDOUT: $!";
    open STDERR, '>&', \*STDOUT or die "merge STDERR: $!";
    my $rc = system($^X, $BP, @args);
    open STDOUT, '>&', $oo or die "restore STDOUT: $!";
    open STDERR, '>&', $oe or die "restore STDERR: $!";
    close $oo;
    close $oe;
    return ($rc == -1 ? -1 : $rc >> 8, slurp_raw($cap));
}

sub read_json_file { return JSON::PP->new->utf8->decode(slurp_raw($_[0])) }

my $have_bash = do { my $o = `bash -c "printf bashok" 2>/dev/null`; (defined $o && $o =~ /bashok/) ? 1 : 0 };

# ---------------------------------------------------------------------------
# 1. Every tracked recipe validates and holds one item whose commands parse.
# ---------------------------------------------------------------------------
opendir my $dh, $RECIPES or BAIL_OUT("cannot read $RECIPES: $!");
my @recipes = sort grep { /\.json\z/ } readdir $dh;
closedir $dh;
ok(scalar(@recipes) >= 1, 'at least one recipe is tracked') or diag("none in $RECIPES");
ok((grep { $_ eq 'node-pnpm.json' } @recipes), 'the node-pnpm recipe is tracked');

for my $file (@recipes) {
    my $path = "$RECIPES/$file";
    my ($rc, $out) = run_bp('validate', $path);
    is($rc, 0, "$file: backpack.pl validate accepts it") or diag($out);
    like($out, qr/^STATUS: ok$/m, "$file: validate reports STATUS: ok");
    like($out, qr/^ITEMS: 1$/m, "$file: holds exactly one item");

    my $item = eval { read_json_file($path)->{items}[0] } || {};
    for my $field (qw(install verify)) {
      SKIP: {
            skip 'bash is not available to parse the command', 1 unless $have_bash;
            # bash -n parses without executing anything.
            system('bash', '-n', '-c', $item->{$field} // '');
            is($? >> 8, 0, "$file: the $field command parses as shell (bash -n)");
        }
    }
    ok(defined $item->{rationale} && length $item->{rationale},
       "$file: carries a rationale (it is shown at the launcher's approval review)");
}

# ---------------------------------------------------------------------------
# 2. add --recipe writes the recipe's own fields.
# ---------------------------------------------------------------------------
my $recipe = read_json_file("$RECIPES/node-pnpm.json")->{items}[0];
my $bpfile = File::Spec->catfile($tmp, 'backpack.json');
{
    my ($rc, $out) = run_bp('add', $bpfile, '--recipe', 'node-pnpm');
    is($rc, 0, 'add --recipe node-pnpm succeeds on a fresh backpack') or diag($out);
    like($out, qr/^STATUS: added$/m, 'it reports STATUS: added');
    like($out, qr/^RECIPE: node-pnpm$/m, 'it names the recipe it used');

    my $items = read_json_file($bpfile)->{items};
    is(scalar(@$items), 1, 'the backpack now holds one item');
    for my $field (qw(category name install verify rationale)) {
        is($items->[0]{$field}, $recipe->{$field}, "the written $field is the recipe's, byte for byte");
    }
    is_deeply($items->[0]{bin_dirs}, $recipe->{bin_dirs}, "the written bin_dirs are the recipe's");
    like($items->[0]{added} // '', qr/^\d{4}-\d{2}-\d{2}$/, 'add stamps the date as for any item');
}

# ---------------------------------------------------------------------------
# 3. A flag overrides its own field and nothing else; same key updates in place.
# ---------------------------------------------------------------------------
{
    my ($rc, $out) = run_bp('add', $bpfile, '--recipe', 'node-pnpm',
                            '--rationale', 'the frontend is built with Vite');
    is($rc, 0, 'add --recipe with --rationale succeeds') or diag($out);
    like($out, qr/^STATUS: updated$/m, 're-adding the same recipe updates the entry in place');

    my $items = read_json_file($bpfile)->{items};
    is(scalar(@$items), 1, 'still one item, not a duplicate');
    is($items->[0]{rationale}, 'the frontend is built with Vite', 'the given --rationale wins');
    is($items->[0]{install}, $recipe->{install}, 'the install still comes from the recipe');
    is($items->[0]{verify},  $recipe->{verify},  'the verify still comes from the recipe');
}

# ---------------------------------------------------------------------------
# 4. The name is a bare word; an unknown one lists what exists.
# ---------------------------------------------------------------------------
{
    my $before = slurp_raw($bpfile);
    for my $bad ('../recipes/node-pnpm', '/etc/passwd', '.hidden', 'node-pnpm.json/x') {
        my ($rc, $out) = run_bp('add', $bpfile, '--recipe', $bad);
        is($rc, 1, "--recipe '$bad' is refused") or diag($out);
        like($out, qr/recipe name/, "--recipe '$bad': the error says a recipe name is expected");
    }
    my ($rc, $out) = run_bp('add', $bpfile, '--recipe', 'no-such-recipe');
    is($rc, 1, 'an unknown recipe is refused');
    like($out, qr/no recipe 'no-such-recipe'/, 'the error names the missing recipe');
    like($out, qr/available: [^\n]*\bnode-pnpm\b/, 'the error lists the recipes that do exist');
    is(slurp_raw($bpfile), $before, 'no refused --recipe touched the backpack file');
}

# ---------------------------------------------------------------------------
# 5. Without --recipe, add still requires every field (no silent defaults).
# ---------------------------------------------------------------------------
{
    my ($rc, $out) = run_bp('add', File::Spec->catfile($tmp, 'other.json'),
                            '--category', 'apt', '--name', 'jq', '--install', 'apt-get install -y jq');
    is($rc, 1, 'add without --verify and without --recipe is still refused');
    like($out, qr/--verify is required/, 'and says which field is missing');
}

done_testing();
