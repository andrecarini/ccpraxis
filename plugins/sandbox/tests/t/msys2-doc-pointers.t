#!/usr/bin/env perl
# platform: any
# The launcher's MSYS2-corruption error and scripts/lint-msys2-guard.pl both
# send the reader to the global CLAUDE.md's "MSYS2 path-conversion" section.
# global-config/ is now split per host (CLAUDE.md shared, CLAUDE.windows.md
# and CLAUDE.macos.md per platform), and that section moved to
# CLAUDE.windows.md, so a pointer naming the shared file sent a Windows
# operator to a file that no longer has it.
#
# This holds every such pointer to the file it names: each
# `global-config/<file>` mentioned on a line that also names the section must
# exist and contain the section's heading text. Pure: reads repo files only.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $ROOT = "$Bin/../../../..";
my $SECTION = 'MSYS2 path-conversion';

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

my %pointer_files = (
    'plugins/sandbox/scripts/launcher.pl' => 1,
    'scripts/lint-msys2-guard.pl'         => 1,
);

my $checked = 0;
for my $rel (sort keys %pointer_files) {
    my $src = slurp("$ROOT/$rel");
    ok(defined $src, "$rel is readable") or next;
    my @lines = split /\n/, $src;
    for my $i (0 .. $#lines) {
        # A pointer may wrap onto the next line in a comment block.
        my $window = join ' ', @lines[$i .. ($i + 1 > $#lines ? $#lines : $i + 1)];
        next unless $lines[$i] =~ m{global-config/(CLAUDE[\w.]*\.md)};
        my $target = $1;
        next unless $window =~ /\Q$SECTION\E/ || $lines[$i] =~ /MSYS2|bind mounts/;
        $checked++;
        my $doc = slurp("$ROOT/global-config/$target");
        ok(defined $doc, "$rel:" . ($i + 1) . " points at global-config/$target, which exists");
        like($doc // '', qr/^#+ .*\Q$SECTION\E/m,
            "$rel:" . ($i + 1) . " points at global-config/$target, which has the \"$SECTION\" section");
    }
}
ok($checked >= 3, "found the MSYS2 pointers to check ($checked)");

done_testing();
