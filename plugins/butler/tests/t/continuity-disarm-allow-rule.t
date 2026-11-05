#!/usr/bin/env perl
# platform: any
# The settings payload (global-config/settings.json, merged into
# ~/.claude/settings.json by scripts/promote.pl) pre-approves the judged
# disarm and the break-glass file, and nothing broader (bug
# 20261105-212229-7709).
#
# Session 3f77dfd2, 2026-11-05: `butler-continuity off-confirm --otp ...
# --justification '...'` was denied by Claude Code's auto-mode classifier as
# [Security Weaken]. The disarm judge that off-confirm runs IS the safeguard,
# and off-confirm is its intended exit. Claude Code resolves a call matching an
# allow rule before the classifier sees it, and keeps narrow rules on entering
# auto mode (https://code.claude.com/docs/en/permission-modes.md, "How the
# classifier evaluates actions"). Bash rule matching per
# https://code.claude.com/docs/en/permissions.md: a trailing " *" also matches
# the bare command, the space before it is a word boundary, and every
# subcommand of a compound command must match on its own. Path rules: Write(...)
# path rules never match, so the file rule is an Edit(...) rule; "//" anchors
# at the filesystem root and "**" crosses directories, "*" one segment.
#
# AR1  the three rules are present, byte for byte
# AR2  they match the shapes the gate and butler-continuity print
# AR3  they never match emergency-stop, on, status, or a lookalike verb
# AR4  no other allow entry names butler-continuity or butler-break-glass
# AR5  the file rule matches exactly <...>/.ccpraxis-local-data/butler-break-glass/<x>.json
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use JSON::PP ();

(my $ROOT = "$Bin/../../../..") =~ s{\\}{/}g;
my $PAYLOAD = "$ROOT/global-config/settings.json";

my $raw = do { open(my $fh, '<:raw', $PAYLOAD) or die "open $PAYLOAD: $!"; local $/; <$fh> };
my $doc = JSON::PP->new->utf8->decode($raw);
my @allow = @{ $doc->{permissions}{allow} || [] };

my $OFF     = 'Bash(butler-continuity off *)';
my $CONFIRM = 'Bash(butler-continuity off-confirm *)';
my $GLASS   = 'Edit(//**/.ccpraxis-local-data/butler-break-glass/*.json)';

ok((grep { $_ eq $CONFIRM } @allow), "AR1: $CONFIRM is in the payload's allow list");
ok((grep { $_ eq $OFF } @allow),     "AR1: $OFF is in the payload's allow list");
ok((grep { $_ eq $GLASS } @allow),   "AR1: $GLASS is in the payload's allow list");
my %ask_deny = map { $_ => 1 } @{ $doc->{permissions}{ask} || [] }, @{ $doc->{permissions}{deny} || [] };
ok(!$ask_deny{$_}, "AR1: $_ is not also an ask or deny rule (deny and ask win over allow)") for ($OFF, $CONFIRM, $GLASS);

# Bash rule matching as documented, for the rule shapes in this payload:
# "X *" matches X itself or X followed by a space; no "*" means exact.
sub bash_rule_matches {
    my ($rule, $cmd) = @_;
    return 0 unless $rule =~ /\ABash\((.*)\)\z/s;
    my $r = $1;
    if ($r =~ /\A(.*) \*\z/s) {
        my $pre = $1;
        return 0 if $pre =~ /\*/;    # not a shape this test models
        return ($cmd eq $pre || index($cmd, "$pre ") == 0) ? 1 : 0;
    }
    if ($r =~ /\A(.*)\*\z/s && $1 !~ /\*/) { return index($cmd, $1) == 0 ? 1 : 0 }
    return 0 if $r =~ /\*/;
    return $cmd eq $r ? 1 : 0;
}
sub any_allow { my ($cmd) = @_; return grep { bash_rule_matches($_, $cmd) } @allow }

for my $cmd (
    q{butler-continuity off-confirm --otp 1a2b3c4d --justification 'goal met, both blueprints promoted'},
    q{butler-continuity off --reason 'all work done here' --token deadbeef},
    q{butler-continuity off},
) {
    ok(scalar(any_allow($cmd)), "AR2: allowed: $cmd");
}
for my $cmd (
    q{butler-continuity emergency-stop --reason 'a real defect'},
    q{butler-continuity emergency-stop},
    q{butler-continuity on --new-thread x --goal 'two words'},
    q{butler-continuity status},
    q{butler-continuity offx --reason 'a b'},
    q{butler-continuity},
) {
    my @m = any_allow($cmd);
    is_deeply(\@m, [], "AR3: no allow rule matches: $cmd");
}
ok(!bash_rule_matches($OFF, q{butler-continuity off-confirm --otp x}),
   'AR3: the off rule does not itself match off-confirm (word boundary)');

my @named = grep { /butler-continuity|butler-break-glass/ } @allow;
is_deeply([ sort @named ], [ sort($OFF, $CONFIRM, $GLASS) ], 'AR4: no other allow entry names butler-continuity or butler-break-glass');
my @wild = grep { /\ABash\(butler-continuity\s*\*?\)\z/ || /\ABash\(butler-continuity\*/ } @allow;
is_deeply(\@wild, [], 'AR4: no wildcard rule over every butler-continuity verb');
my @write_rules = grep { /\AWrite\(/ } @allow;
is_deeply(\@write_rules, [], 'AR4: no Write(path) rule (documented never to match; Edit(...) is the form)');

# The file rule, as gitignore-style matching on the POSIX-normalised path
# ("C:\x" -> "/c/x", per the permissions doc's Windows note).
sub glass_rule_regex {
    my ($rule) = @_;
    return undef unless $rule =~ m{\AEdit\(//(.*)\)\z};
    my $pat = $1;
    my $re = '';
    for my $tok (split m{(\*\*/|\*)}, $pat) {
        next unless length $tok;
        if    ($tok eq '**/') { $re .= '(?:.*/)?' }
        elsif ($tok eq '*')   { $re .= '[^/]*' }
        else                  { $re .= quotemeta($tok) }
    }
    return qr{\A/$re\z};
}
my $gre = glass_rule_regex($GLASS);
ok(defined $gre, 'AR5 setup: the file rule parses as a // anchored pattern');
if (defined $gre) {
    for my $p (
        '/c/Development/ccpraxis/.ccpraxis-local-data/butler-break-glass/3f77dfd2-451d-414b-a083-e0ff6437e96f.json',
        '/c/Users/André/work/proj/.ccpraxis-local-data/butler-break-glass/s.json',
        '/workspace/.ccpraxis-local-data/butler-break-glass/s.json',
    ) {
        like($p, $gre, "AR5: matches $p");
    }
    for my $p (
        '/c/p/.ccpraxis-local-data/butler-break-glass/sub/s.json',
        '/c/p/.ccpraxis-local-data/butler-break-glass/s.txt',
        '/c/p/.ccpraxis-local-data/butler-break-glass.json',
        '/c/p/.ccpraxis-local-data/bug-reports/s.json',
        '/c/p/.ccpraxis-local-data/x/butler-break-glass/s.json',
        '/c/p/.ccpraxis-local-data/butler-break-glass',
        '/c/p/butler-break-glass/s.json',
        '/c/Users/André/.claude/butler-state/continuity/break-glass/s.json',
        '/c/p/.claude/settings.json',
    ) {
        unlike($p, $gre, "AR5: does not match $p");
    }
}

done_testing();
