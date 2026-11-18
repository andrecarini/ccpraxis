#!/usr/bin/env perl
# platform: any
# The reviewer checks the STRUCTURE a diff leaves behind, not only whether it
# works (operator, 2026-11-18, after comparing bp-reviewer with Cursor's
# "thermo-nuclear code quality review" rubric). Before this, bp-reviewer's
# method weighed spec conformance, correctness, conventions and a
# maintainability item limited to dead code, duplication and test smells, while
# 48 ccpraxis files had grown past 1,000 lines with nothing in review asking
# whether new code belonged in a module of its own (bug 20261118-023309-ed40).
#
# Pins, in the Method section:
#   S1  a Structure item, ordered before Maintainability
#   S2  its five checks: scattered special cases, a re-written existing helper,
#       logic in the wrong layer, indirection-only wrappers, growth of an
#       already-large file
#   S3  the scope guard: a simpler shape is a finding inside the write set, not
#       a redesign (the agent's own "findings, not redesigns" rule still holds)
#   S4  the severity rule for structural findings and the few-findings rule
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $path = "$Bin/../../agents/bp-reviewer.md";
open my $fh, '<:raw', $path or BAIL_OUT("$path: $!");
my $doc = do { local $/; <$fh> };
close $fh;

my ($method) = $doc =~ /^## Method\n(.*?)^## /ms;
ok(defined $method, 'the Method section is found') or BAIL_OUT('no Method section');

my $i_struct = index($method, '**Structure**');
my $i_maint  = index($method, '**Maintainability**');
ok($i_struct >= 0, 'S1: Method has a Structure item');
ok($i_maint > $i_struct, 'S1: ...weighed before Maintainability');

like($method, qr/special cases.*one-off branches/s, 'S2: scattered special cases');
like($method, qr/helper the codebase already has/, 'S2: a re-written existing helper');
like($method, qr/wrong layer/, 'S2: logic in the wrong layer');
like($method, qr/only adds indirection/, 'S2: indirection-only wrappers, flags or modes');
like($method, qr/already large.*1,000 lines.*module of its own/s, 'S2: growth of an already-large file');

like($method, qr/inside the write set/, 'S3: a simpler shape stays inside the write set');
like($doc, qr/You produce findings, not redesigns\./, 'S3: the findings-not-redesigns rule is kept');

like($method, qr/structural finding is SHOULD-FIX, or MUST-FIX when it breaks a convention/, 'S4: structural severity');
like($method, qr/few findings you are sure of/, 'S4: few sure findings over a long list');
like($method, qr/NITs must never bury a structural finding/, 'S4: NITs never bury structure');

like($doc, qr/^description:.*\bstructure\b/m, 'the description names structure');

done_testing();
