#!/usr/bin/env perl
# vault-namespace-sync.pl -- commit and push ONE top-level namespace in the vault.
#
# Exists because two of the vault's namespaces were being written by scripts
# that never committed them. `git status` in the vault on 2026-09-06 reported
# `reports/` and `bootstrap-archive/` as untracked -- every /steward:usage-audit
# report ever generated on this machine, sitting locally, never pushed, while
# the skill's own description said it "writes a dated report into the vault".
#
# Usage:
#   vault-namespace-sync.pl <relpath> [message] [--no-push] [--vault DIR]
#
# Emits one JSON object. Exit 0 on success (including "nothing to commit"),
# 1 on failure.
use strict;
use warnings;
use FindBin ();
use lib $FindBin::Bin;
use JSON::PP ();
use Getopt::Long qw(GetOptionsFromArray);
use VaultNamespace ();

$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;
binmode(STDOUT, ':raw');

my @argv = @ARGV;
my ($no_push, $vault) = (0, undef);
GetOptionsFromArray(\@argv, 'no-push' => \$no_push, 'vault=s' => \$vault) or do {
    print JSON::PP->new->canonical(1)->pretty->encode({ ok => JSON::PP::false, error => 'bad arguments' });
    exit 1;
};

my $rel = shift @argv;
my $msg = shift @argv;

unless (defined $rel && length $rel) {
    print JSON::PP->new->canonical(1)->pretty->encode(
        { ok => JSON::PP::false, error => 'usage: vault-namespace-sync.pl <relpath> [message]' });
    exit 1;
}

unless (defined $vault) {
    my $home = $ENV{HOME} // $ENV{USERPROFILE} // '';
    $home =~ s{\\}{/}g;
    $home =~ s{/+$}{};
    $vault = "$home/.claude/claude-code-vault";
}

my $r = VaultNamespace::sync(vault => $vault, path => $rel, message => $msg, push => ($no_push ? 0 : 1));

# Booleans go out as JSON booleans, not 1/0, so a consumer can test them
# without knowing which convention this script happened to use.
for my $k (qw(ok synced pushed)) {
    $r->{$k} = $r->{$k} ? JSON::PP::true : JSON::PP::false if exists $r->{$k};
}
$r->{vault} = $vault;
$r->{path}  = $rel;

print JSON::PP->new->canonical(1)->pretty->encode($r);
exit($r->{ok} ? 0 : 1);
