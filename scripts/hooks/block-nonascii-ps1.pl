#!/usr/bin/env perl
# block-nonascii-ps1.pl — PreToolUse guard: refuse to write non-ASCII into a
# .ps1 file.
#
# WHY A HOOK AND NOT A RULE. This rule was already written down, in the
# user-global CLAUDE.md, in detail, with the failure mode spelled out. Both .ps1
# files in ccpraxis violated it anyway, and nobody noticed until 2026-08-29 --
# when a change to an unrelated comment happened to require opening them.
# claude-sandbox.ps1, the sandbox launcher itself, was carrying THREE 0x94
# bytes. Operator: "So just a rule wasn't enough, it should also be handled by
# hooks then."
#
# That is the same conclusion guard-git-mutations.sh reached after a prohibited
# `git stash` destroyed a completed fix-batch: a written instruction is not an
# enforcement mechanism. This is the .ps1 equivalent, and it sits beside
# block-nul-redirect.pl, which enforces the other Windows landmine the same way.
#
# THE FAILURE IT PREVENTS. The Write tool saves UTF-8 with no BOM. PowerShell
# 5.1 reads a BOM-less file as CP1252, so a multi-byte character decodes into
# stray bytes -- and an em dash (E2 80 94) contributes 0x94, which in CP1252 is
# a SMART QUOTE. PowerShell treats it as a string delimiter: it opens a phantom
# string, swallows the following braces, and reports `Missing closing '}'` at a
# line far from the real problem.
#
# An EVEN number of them happens to balance, which is why claude-sandbox.ps1
# kept working while being wrong. That is not a safety margin -- it means the
# next em dash anyone adds is the one that breaks the launcher, and the error
# will point somewhere else entirely.
#
# SCOPE: .ps1 only. .sh and .pl files are read by tools that handle UTF-8
# correctly; Git Bash is unaffected. Blocking non-ASCII everywhere would be a
# nuisance with no failure behind it.
#
# THE ESCAPE HATCH IS REAL: a file that genuinely needs non-ASCII may have one,
# provided it starts with a UTF-8 BOM, which is what makes PowerShell 5.1 decode
# it correctly. The guard checks for that first and stands aside.
use strict;
use warnings;

# Fail OPEN on anything unexpected. This guard exists to catch an accident, not
# to be the reason an edit cannot happen; a bug here must not wedge the session.
$SIG{__DIE__} = sub { exit 0 };

my $payload = '';
{
    local $/;
    $payload = <STDIN> // '';
}
exit 0 unless length $payload;

# Parse with JSON::PP when available (core), else fall back to a regex. The
# fallback matters: a guard that silently stops guarding when a module is
# missing is the shape of bug this repo keeps finding.
my ($path, $content);
my $ok = eval {
    require JSON::PP;
    my $d = JSON::PP->new->decode($payload);
    my $ti = (ref $d eq 'HASH' && ref $d->{tool_input} eq 'HASH') ? $d->{tool_input} : {};
    $path = $ti->{file_path} // $ti->{notebook_path};
    # Write has `content`; Edit has new_string; MultiEdit carries a list.
    my @parts = grep { defined && !ref } ($ti->{content}, $ti->{new_string});
    if (ref $ti->{edits} eq 'ARRAY') {
        push @parts, grep { defined && !ref } map { ref $_ eq 'HASH' ? $_->{new_string} : () } @{ $ti->{edits} };
    }
    $content = join "\n", @parts;
    1;
};
unless ($ok) {
    ($path)    = $payload =~ /"file_path"\s*:\s*"([^"]*)"/;
    ($content) = $payload =~ /"(?:content|new_string)"\s*:\s*"(.*?)"\s*[,}]/s;
}

exit 0 unless defined $path && $path =~ /\.ps1\z/i;
exit 0 unless defined $content && length $content;

# A file that already carries a UTF-8 BOM decodes correctly under 5.1, so
# non-ASCII in it is safe and deliberate.
if (-f $path && open my $fh, '<:raw', $path) {
    read($fh, my $head, 3);
    close $fh;
    exit 0 if defined $head && $head eq "\xEF\xBB\xBF";
}
exit 0 if $content =~ /\A\xEF\xBB\xBF/;

my @bad;
while ($content =~ /([^\x00-\x7F])/g) {
    push @bad, $1;
    last if @bad >= 5;
}
exit 0 unless @bad;

my $shown = join ' ', map { sprintf('U+%04X', ord) } @bad;
print STDERR <<"MSG";
BLOCKED: this write puts non-ASCII characters into a .ps1 file ($shown).

PowerShell 5.1 reads a BOM-less file as CP1252. An em dash (U+2014) becomes the
bytes E2 80 94, and 0x94 is a SMART QUOTE in CP1252 -- PowerShell treats it as a
string delimiter, opens a phantom string, swallows the following braces, and
reports "Missing closing '}'" at a line far from the real problem.

Use ASCII: -- for an em dash, - for an en dash, -> for an arrow, plain quotes.
If the file genuinely needs non-ASCII, give it a UTF-8 BOM first and this guard
will stand aside.

File: $path
MSG
exit 2;
