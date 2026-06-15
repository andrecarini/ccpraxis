#!/usr/bin/env perl
# 01-encoding.t — byte-for-byte assertion that encode_project_dir reproduces the
# six live transcript-dir names (Decision #1 encoding rule), plus the _host-memory
# in-container /project vector, plus proof that emit_json's _decode_strings_-
# recursive survives UTF-8 "André" and decodes CP1252 "Andr\xE9" WITHOUT the old
# FB_QUIET truncation. Exercises the real vault-sync.pl via host-memory-path — no
# vault, no git, pure function behaviour.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Encode qw(encode);
use StewardTest qw(ok is like unlike run_vs temproot done_testing diag);

my $root = temproot();
my $home = "$root/home";   # throwaway HOME; encoding doesn't depend on it

# slug-cwd (POSIX, as the registry stores) => expected Claude transcript dir name
my @vectors = (
    [ "/c/Development/andrecarini",                       "C--Development-andrecarini" ],
    [ "/c/Users/Andr\xC3\xA9/.claude/ccpraxis",          "C--Users-Andr---claude-ccpraxis" ],
    [ "/c/Development/GSA/gsa-superapp",                  "C--Development-GSA-gsa-superapp" ],
    [ "/c/Users/Andr\xC3\xA9/Personal Files/Job search", "C--Users-Andr--Personal-Files-Job-search" ],
    [ "/c/Development/Klink",                             "C--Development-Klink" ],
    [ "/c/Users/Andr\xC3\xA9/Personal Files/Notion bughunting", "C--Users-Andr--Personal-Files-Notion-bughunting" ],
    [ "/project",                                         "-project" ],
);

for my $v (@vectors) {
    my ($cwd, $expected) = @$v;
    my $r = run_vs($home, 'host-memory-path', '--cwd', $cwd);
    ok($r->{json}, "host-memory-path emitted JSON for $expected") or next;
    is($r->{json}{encoded}, $expected, "encode_project_dir: $expected");
}

# UTF-8 "André" (0xC3 0xA9) survives _decode_strings_recursive unchanged.
{
    my $r = run_vs($home, 'host-memory-path', '--cwd', "/c/x/Andr\xC3\xA9/y");
    my $bytes = defined $r->{json} ? encode('UTF-8', $r->{json}{cwd}) : '';
    like($bytes, qr/Andr\xC3\xA9/, "UTF-8 André survives emit_json round-trip");
}

# CP1252 "Andr\xE9" (single high byte) decodes to "André" — NOT truncated to
# "Andr" the way the old FB_QUIET path did.
{
    my $r = run_vs($home, 'host-memory-path', '--cwd', "/c/x/Andr\xE9/y");
    my $bytes = defined $r->{json} ? encode('UTF-8', $r->{json}{cwd}) : '';
    like($bytes, qr/Andr\xC3\xA9/, "CP1252 Andr\\xE9 decodes to André (cp1252 fallback)");
    unlike($bytes, qr{Andr/y}, "CP1252 byte was not silently dropped before /y");
}

done_testing();
