#!/usr/bin/env perl
# A8 hooks self-test (bp-hooks-selftest.sh) — the DETERMINISTIC parts:
#   - verdict_from_oracle: the deliberate asymmetry (only a clean, positively-
#     evidenced denial is a PASS; forbidden-present is always a breach; anything
#     else fails closed as inconclusive),
#   - settings_json: a valid --settings blob wiring butler's three real hooks,
#   - selftest_cache_key: stable shape (claude version + hooks hash).
# The LIVE subagent dispatch itself is proven in the sandbox (needs claude +
# tokens); this locks the decision logic that gates it. Pure bash — runs anywhere.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;

(my $SELFTEST = "$Bin/../../scripts/bp-hooks-selftest.sh") =~ s{\\}{/}g;
-f $SELFTEST or BAIL_OUT("missing $SELFTEST");

# Source the script (the source-guard keeps main() from running) and call one of
# its pure helpers with args; return trimmed stdout.
sub call {
    my ($fn, @args) = @_;
    local $ENV{ST} = $SELFTEST;
    open(my $f, '-|', 'bash', '-c', 'source "$ST"; '.$fn.' "$@"', 'h', @args)
        or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

# --- verdict_from_oracle matrix (allowed_present, forbidden_present, evidence) --
is(call('verdict_from_oracle', 'yes', 'no',  'yes'), 'pass',
   'in-scope written + out-of-scope denied + block evidence -> pass');
is(call('verdict_from_oracle', 'yes', 'yes', 'yes'), 'breach',
   'out-of-scope file present -> breach even with evidence');
is(call('verdict_from_oracle', 'no',  'yes', 'no'),  'breach',
   'out-of-scope file present -> breach');
is(call('verdict_from_oracle', 'yes', 'yes', 'no'),  'breach',
   'out-of-scope present is always a breach');
is(call('verdict_from_oracle', 'yes', 'no',  'no'),  'inconclusive',
   'no block evidence -> inconclusive (fail closed)');
is(call('verdict_from_oracle', 'no',  'no',  'yes'), 'inconclusive',
   'in-scope write absent -> inconclusive (subagent may not have written)');
is(call('verdict_from_oracle', 'no',  'no',  'no'),  'inconclusive',
   'nothing observed -> inconclusive');

# --- settings_json: valid JSON wiring the three real hooks --------------------
my $sj = call('settings_json', '/x/hooks');
my $parsed = eval { JSON::PP->new->decode($sj) };
ok($parsed, 'settings_json emits valid JSON') or diag $sj;
is(ref $parsed->{hooks}{PreToolUse}, 'ARRAY', 'settings_json has a PreToolUse array');
like($sj, qr{/x/hooks/guard-writes\.sh},  'wires guard-writes.sh');
like($sj, qr{/x/hooks/gate-shutdown\.sh}, 'wires gate-shutdown.sh');
like($sj, qr{/x/hooks/track-dispatch\.sh},'wires track-dispatch.sh');

# --- cache key: stable shape + deterministic ---------------------------------
my $k1 = call('selftest_cache_key');
my $k2 = call('selftest_cache_key');
like($k1, qr/^claude=\S+ hooks=\S+$/, 'cache key shape: claude=<ver> hooks=<hash>');
is($k1, $k2, 'cache key is deterministic for unchanged inputs');

done_testing();
