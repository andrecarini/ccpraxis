#!/usr/bin/env perl
# platform: any
# The escalation resolver must not send an internal lint's scope to the operator as "product".
#
# 2026-11-01: bp-escalation-resolver classified "should the naming lint exempt its own test
# fixtures (tools/checks/*/test/*.erl)?" as `category: product` with high confidence, the second
# time the same package's lint scope went to the operator. Package 04 and everything depending on
# it (03, 05, 06, 07, then 14) waited nine hours overnight. The operator: "this is not a product
# question, it's a deep technical question that doesn't affect the product".
#
# Two passages of the resolver's own instructions produced it:
#   - an input note saying "a naming/retirement rule already settled there makes an
#     apparently-technical question actually a `product` one";
#   - the subject-matter override's "naming/product-identity", with no line between the names
#     users see and the engineering rules that police words in the codebase.
# Both verdicts also cited "superseding a blueprint Decision" as reserved, though the row they
# would amend (Decision 18) was decided by `agent`.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;

my $F = "$Bin/../../agents/bp-escalation-resolver.md";
my $txt = do { open my $fh, '<:raw', $F or die "$F: $!"; local $/; <$fh> };
(my $flat = $txt) =~ s/\s+/ /g;

unlike($flat, qr/naming\/retirement rule already settled there makes an apparently-technical question actually a `product` one/,
       'the example that turned a retirement rule into a product question is gone');

like($flat, qr/\*\*Product identity means names the product's users see:\*\*/,
     'product identity is defined as what users see');
like($flat, qr/Which files a banned-word or naming lint scans, what it allow-lists, and whether a checker's own test fixtures may contain the words it bans are implementation/,
     'a lint\'s scope, allow-list and fixtures are named as implementation');

like($flat, qr/\*\*Read each row's `Decided` column: it says whose ruling it is\.\*\*/,
     'the Decisions table\'s Decided column decides whose ruling a row is');
like($flat, qr/A row decided by `agent` is an agent's own ruling.*?needing to amend it does not make a question `product`/,
     'amending an agent-decided row is within the agents\' purview');
like($flat, qr/A row decided by `user` is the operator's/, 'a user-decided row stays the operator\'s');

like($flat, qr/data retention, PII, security, money, or naming\/product-identity/,
     'the override itself is unchanged for genuine retention/PII/security/money/identity questions');

done_testing();
