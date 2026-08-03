#!/usr/bin/env perl
# b36-multi-provider-spend-governance oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b36-multi-provider-spend-governance-spec.md
# section 3, acceptance criteria C1..C10, and section 3a (the REVISIT TRIGGER).
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/scripts/bp-spend.pl does not exist at the
# time this file was authored. Every assertion below that depends on it is expected to fail on
# MISSING BEHAVIOUR (a failed `require`, caught by eval — never a raw Perl exception propagating
# out of this file and never a bare "wrong path" mistake).
#
# INVENTED CONTRACT (the test-writer's job, same as b46 did for bp-pin.pl before it existed).
# This is the shape bp-spend.pl is expected to expose, inferred from the spec's own vocabulary
# (§2 "normalized reader... plus the gate decision... injectable fetcher and clock") and this
# repo's existing conventions (bp-usage-gate.pl's pure verdict_decision(), bp-pin.pl's
# resolve/audit split, bp-deps-check.pl's degrade-to-warn-never-block invariant):
#
#   package BpSpend (require "$DIR/bp-spend.pl"):
#
#     $BpSpend::CADENCE_TTL_SECONDS   -- named constant, the cadence floor (spec 1.3).
#
#     BpSpend::parse_go($html)  -> pure, no I/O.
#       success: { status => 'ok', five_hour => {used=>N,limit=>N}, weekly => {...}, monthly => {...} }
#       failure: { status => 'unknown', diagnostic => $str }   -- NEVER a number, NEVER 0.
#     BpSpend::parse_zen($html) -> pure, no I/O.
#       success: { status => 'ok', balance => N, budget => N|undef }
#       failure: { status => 'unknown', diagnostic => $str }
#     Both diagnostics, on a page that no longer matches, must carry the §3a REVISIT TRIGGER
#     prompt: check whether OpenCode now publishes a documented API/CLI/usage-header before
#     repairing the scrape.
#
#     BpSpend::resolve_credential(%opts) -> credential resolution (env first, then file).
#       opts: env_var => NAME, env => \%ENV (injectable), fallback_path => PATH
#       ok:  { ok => 1, cookie => $str, source => 'env'|'file' }
#       fail:{ ok => 0, reason => 'missing'|'insecure-file', detail => $str }
#       'insecure-file' detail NAMES the path and the required mode (0600).
#
#     BpSpend::fetch(%opts) -> the normalized reader + cadence + credential + parse, composed.
#       opts: provider => 'go'|'zen', http => CODEREF($method,$url,\%hdrs)->{status,content},
#             now => epoch, cache => \%hashref (mutated for TTL bookkeeping, shared across calls
#             to enforce the cadence floor), env_var/fallback_path (credential), log_path (optional
#             -- if given, every fetch attempt/outcome is logged via BpLog::event, NEVER a
#             reimplementation).
#       Returns the same shape as parse_go/parse_zen (status => 'ok'|'unknown', ...).
#       unreachable network / non-200 -> unknown, diagnostic mentions the network problem.
#       expired/rejected cookie (401, or a login-page redirect) -> unknown, diagnostic matches
#       /re-copy.*cookie/i -- NEVER a stack trace, never invented as a pause.
#
#     BpSpend::verdict(@results) -> composes N provider results into ONE decision.
#       { action => 'ok'|'unknown', reason => $str }
#       ANY result with status 'unknown' propagates: overall action is 'unknown', NEVER 'ok',
#       and NEVER does 'unknown' get coerced into a pause action (this is a WARN/audit path,
#       per bp-deps-check.pl's binding invariant: no gate manufactures a BLOCK/pause out of an
#       outage).
#
# MANDATORY VACUITY GATE (spec's own standing rule): C2/C3 are negative-only ("never a number")
# and pass trivially against a reader that always returns unknown -- so C1 asserts REAL
# EXTRACTION from a well-formed fixture IN THE SAME RUN, and cross-checks that well-formed and
# mangled fixtures produce DIFFERENT results. C4 first asserts something was actually logged,
# before asserting the cookie is absent from it. C10 asserts the injected fetcher was actually
# CALLED (a call counter), not merely that no live socket opened.
#
# NO SKIP whose condition is the failure state. Absence is always a FAILURE, never a skip.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Spec;
use JSON::PP;

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER   = fwd("$Bin/../..");
my $SCRIPTS  = "$BUTLER/scripts";
my $SPEND    = "$SCRIPTS/bp-spend.pl";
my $LOG      = "$SCRIPTS/bp-log.pl";
my $JAIL     = "$SCRIPTS/bp-jail.pl";

diag("subject under test: $SPEND " . (-e $SPEND ? "(present)" : "(ABSENT -- most assertions below are expected to fail on MISSING BEHAVIOUR)"));

# =====================================================================================
# Fixed clock -- arbitrary but stable across the run.
# =====================================================================================
use constant NOW_EPOCH => 1785800000;   # 2026-08-03-ish, exact value not load-bearing

# =====================================================================================
# Scaffolding
# =====================================================================================
sub write_file {
    my ($path, $bytes) = @_;
    open(my $fh, '>:raw', $path) or die "write $path: $!";
    print {$fh} $bytes;
    close $fh;
    return $path;
}
sub read_file {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# =====================================================================================
# HARNESS: load bp-spend.pl and bp-log.pl as modules. Guarded -- house idiom
# (t/88-execution-priority.t, t/90-version-pin-currency.t).
# =====================================================================================
my $SPEND_LOADED = do { local $@; eval { require $SPEND }; !$@ };
ok($SPEND_LOADED, 'HARNESS: bp-spend.pl requires cleanly as a module')
    or diag("require failed (expected pre-implementation -- bp-spend.pl does not exist yet): $@");

my $LOG_LOADED = do { local $@; eval { require $LOG }; !$@ };
ok($LOG_LOADED, 'HARNESS: bp-log.pl (the mandated logging means) requires cleanly');

# Every call below to a BpSpend:: sub is wrapped so a missing package/sub cannot take the whole
# file down with it -- an undefined-subroutine death is caught and reported as a normal failed
# assertion, exactly what "absence of implementation" should look like here.
sub try_call {
    my ($desc, $code) = @_;
    my @out;
    my $ok = eval { @out = $code->(); 1 };
    unless ($ok) {
        my $err = $@;
        $err =~ s/\s+$//;
        return (undef, "died calling $desc: $err");
    }
    return (\@out, undef);
}

# =====================================================================================
# Fixture pages -- INVENTED, not fetched. Representative of the documented mechanism (spec §0):
# opencode.ai/workspace/{id}/billing, authenticated HTML, Go = quota windows 5h/Weekly/Monthly,
# Zen = current balance + optional monthly budget.
# =====================================================================================

my $GO_WELLFORMED = <<'HTML';
<html><body>
<div class="quota-window" data-window="5h">
  <span class="quota-label">5h</span>
  <span class="quota-used">42</span> / <span class="quota-limit">100</span>
</div>
<div class="quota-window" data-window="Weekly">
  <span class="quota-label">Weekly</span>
  <span class="quota-used">310</span> / <span class="quota-limit">1000</span>
</div>
<div class="quota-window" data-window="Monthly">
  <span class="quota-label">Monthly</span>
  <span class="quota-used">2200</span> / <span class="quota-limit">4000</span>
</div>
</body></html>
HTML

my $GO_MANGLED = "<html><body><div class=\"totally-different-markup\">nothing recognisable here</div>\x00\xFF garbage bytes </body></html>";

my $GO_EMPTY = '';

my $GO_FIGURES_REMOVED = <<'HTML';
<html><body>
<div class="quota-window" data-window="5h">
  <span class="quota-label">5h</span>
</div>
<div class="quota-window" data-window="Weekly">
  <span class="quota-label">Weekly</span>
</div>
<div class="quota-window" data-window="Monthly">
  <span class="quota-label">Monthly</span>
</div>
</body></html>
HTML

my $ZEN_WELLFORMED = <<'HTML';
<html><body>
<div class="billing-balance">
  <span class="balance-label">Current balance</span>
  <span class="balance-value">$17.42</span>
</div>
<div class="billing-budget">
  <span class="budget-label">Monthly budget</span>
  <span class="budget-value">$50.00</span>
</div>
</body></html>
HTML

my $ZEN_MANGLED = "<html><body><section id=\"unexpected\">\x00binary\xFFjunk</section></body></html>";

my $ZEN_EMPTY = '';

my $ZEN_FIGURES_REMOVED = <<'HTML';
<html><body>
<div class="billing-balance">
  <span class="balance-label">Current balance</span>
</div>
</body></html>
HTML

my $ZEN_LOGIN_REDIRECT = <<'HTML';
<html><head><title>Sign in to OpenCode</title></head><body>
<form action="/login"><h1>Please sign in</h1><input name="email"></form>
</body></html>
HTML

# =====================================================================================
# C1 -- well-formed fixture yields the documented figures for BOTH providers. This is the
# VACUITY GATE'S POSITIVE HALF: C2/C3 are negative-only and would pass against an
# always-unknown reader, so C1 must show REAL extraction happened.
# =====================================================================================
{
    my ($go_res, $go_err) = try_call('BpSpend::parse_go (well-formed)', sub { BpSpend::parse_go($GO_WELLFORMED) });
    ok(defined $go_res, 'C1/Go: parse_go(well-formed) returns without dying')
        or diag($go_err);
    my $go = $go_res ? $go_res->[0] : undef;
    is(ref($go) eq 'HASH' ? $go->{status} : undef, 'ok', 'C1/Go: well-formed fixture yields status=ok')
        or diag(defined $go ? JSON::PP->new->canonical->encode($go) : '(undef)');
    if (ref($go) eq 'HASH' && ($go->{status} // '') eq 'ok') {
        is($go->{five_hour}{used}, 42,   'C1/Go: 5h used = 42 (real extraction, not a guess)');
        is($go->{five_hour}{limit}, 100, 'C1/Go: 5h limit = 100');
        is($go->{weekly}{used}, 310,     'C1/Go: Weekly used = 310');
        is($go->{weekly}{limit}, 1000,   'C1/Go: Weekly limit = 1000');
        is($go->{monthly}{used}, 2200,   'C1/Go: Monthly used = 2200');
        is($go->{monthly}{limit}, 4000,  'C1/Go: Monthly limit = 4000');
    } else {
        fail("C1/Go: $_") for (
            '5h used = 42', '5h limit = 100', 'Weekly used = 310',
            'Weekly limit = 1000', 'Monthly used = 2200', 'Monthly limit = 4000',
        );
    }

    my ($zen_res, $zen_err) = try_call('BpSpend::parse_zen (well-formed)', sub { BpSpend::parse_zen($ZEN_WELLFORMED) });
    ok(defined $zen_res, 'C1/Zen: parse_zen(well-formed) returns without dying')
        or diag($zen_err);
    my $zen = $zen_res ? $zen_res->[0] : undef;
    is(ref($zen) eq 'HASH' ? $zen->{status} : undef, 'ok', 'C1/Zen: well-formed fixture yields status=ok')
        or diag(defined $zen ? JSON::PP->new->canonical->encode($zen) : '(undef)');
    if (ref($zen) eq 'HASH' && ($zen->{status} // '') eq 'ok') {
        is($zen->{balance}, '17.42', 'C1/Zen: current balance = 17.42 (real extraction)');
        is($zen->{budget}, '50.00',  'C1/Zen: optional monthly budget = 50.00');
    } else {
        fail('C1/Zen: balance = 17.42');
        fail('C1/Zen: budget = 50.00');
    }
}

# =====================================================================================
# C2 -- THE MOST IMPORTANT ASSERTION IN THIS FILE. A page that no longer matches yields
# `unknown`, NEVER a number. Three fixtures per provider: mangled, empty, valid-with-figures-
# removed. Cross-checked against C1's well-formed result so "always unknown" cannot pass
# vacuously (the mandatory vacuity gate).
# =====================================================================================
{
    for my $case ([mangled => $GO_MANGLED], [empty => $GO_EMPTY], ['figures-removed' => $GO_FIGURES_REMOVED]) {
        my ($label, $html) = @$case;
        my ($res, $err) = try_call("BpSpend::parse_go ($label)", sub { BpSpend::parse_go($html) });
        my $r = $res ? $res->[0] : undef;
        is(ref($r) eq 'HASH' ? $r->{status} : undef, 'unknown', "C2/Go ($label): status is 'unknown', never a number")
            or diag($err // (defined $r ? JSON::PP->new->canonical->encode($r) : '(undef)'));
        if (ref($r) eq 'HASH') {
            for my $f (qw(five_hour weekly monthly)) {
                ok(!exists $r->{$f} || !defined $r->{$f}{used},
                   "C2/Go ($label): no numeric '$f.used' is fabricated alongside status=unknown");
            }
        }
    }
    for my $case ([mangled => $ZEN_MANGLED], [empty => $ZEN_EMPTY], ['figures-removed' => $ZEN_FIGURES_REMOVED]) {
        my ($label, $html) = @$case;
        my ($res, $err) = try_call("BpSpend::parse_zen ($label)", sub { BpSpend::parse_zen($html) });
        my $r = $res ? $res->[0] : undef;
        is(ref($r) eq 'HASH' ? $r->{status} : undef, 'unknown', "C2/Zen ($label): status is 'unknown', never a number")
            or diag($err // (defined $r ? JSON::PP->new->canonical->encode($r) : '(undef)'));
        if (ref($r) eq 'HASH') {
            ok(!defined $r->{balance}, "C2/Zen ($label): 'balance' is not fabricated alongside status=unknown");
        }
    }

    # Cross-check: well-formed (C1) and mangled (C2) must produce DIFFERENT results -- this is
    # what rules out a reader that always says unknown from trivially passing this section.
    my ($wf_res)  = try_call('cross-check well-formed', sub { BpSpend::parse_go($GO_WELLFORMED) });
    my ($mg_res)  = try_call('cross-check mangled',      sub { BpSpend::parse_go($GO_MANGLED) });
    my $wf_status = $wf_res && ref($wf_res->[0]) eq 'HASH' ? $wf_res->[0]{status} : undef;
    my $mg_status = $mg_res && ref($mg_res->[0]) eq 'HASH' ? $mg_res->[0]{status} : undef;
    isnt(($wf_status // '(undef)') . '', ($mg_status // '(undef)') . '',
         'VACUITY CROSS-CHECK: well-formed and mangled fixtures yield DIFFERENT statuses -- an always-unknown reader could not pass this file');
}

# =====================================================================================
# C3 -- `unknown` propagates to the VERDICT as `unknown`, never coerced to 0 anywhere on the
# path. Pairs with C1 so "always unknown" cannot pass (same vacuity concern as C2, at the
# verdict layer this time). This is b41's lesson generalised: undef burn silently read as ZERO
# by should_pause. Same trap, higher stakes.
# =====================================================================================
{
    my $ok_result = { provider => 'go',  status => 'ok',      five_hour => { used => 1, limit => 100 } };
    my $unk_result = { provider => 'zen', status => 'unknown', diagnostic => 'parse failure' };

    my ($v_res, $v_err) = try_call('BpSpend::verdict (one unknown)', sub { BpSpend::verdict($ok_result, $unk_result) });
    my $v = $v_res ? $v_res->[0] : undef;
    is(ref($v) eq 'HASH' ? $v->{action} : undef, 'unknown',
       'C3: a verdict over [ok, unknown] is unknown -- unknown PROPAGATES, is not overridden by the ok sibling')
        or diag($v_err // (defined $v ? JSON::PP->new->canonical->encode($v) : '(undef)'));

    # Positive half of the vacuity pairing: an all-ok verdict must NOT also read as unknown --
    # otherwise "always unknown" would trivially satisfy the assertion above.
    my $ok_only = { provider => 'go', status => 'ok', five_hour => { used => 1, limit => 100 } };
    my ($v2_res, $v2_err) = try_call('BpSpend::verdict (all ok)', sub { BpSpend::verdict($ok_only) });
    my $v2 = $v2_res ? $v2_res->[0] : undef;
    is(ref($v2) eq 'HASH' ? $v2->{action} : undef, 'ok',
       'C3 VACUITY CHECK: a verdict over an all-ok result set is "ok", not "unknown" -- rules out an always-unknown verdict()')
        or diag($v2_err // (defined $v2 ? JSON::PP->new->canonical->encode($v2) : '(undef)'));

    # Never coerced to 0: nothing numeric should appear standing in for the unknown provider.
    ok(!defined $unk_result->{balance} && !defined $unk_result->{five_hour},
       'C3: the unknown result itself carries no numeric field standing in for a real figure');
}

# =====================================================================================
# C4 -- the cookie is NEVER present in any log line, diagnostic, or error output. Asserted
# against bp-log.pl's REAL output (BpLog::event), not a re-implementation. Tested across BOTH
# the happy path and an error path (expired cookie), per spec instruction "test the error paths
# too, not just the happy path".
# =====================================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $log_path = "$tmp/spend.jsonl";
    my $SECRET_COOKIE = 'SESSION-COOKIE-VALUE-MUST-NEVER-LEAK-9f31ac7e';

    # Happy path: a successful fetch, with the real cookie in play, logging to the real bp-log.pl.
    my $calls = 0;
    my $http_ok = sub { $calls++; return { status => 200, content => $GO_WELLFORMED } };
    my ($res1, $err1) = try_call('BpSpend::fetch (happy path, logged)', sub {
        BpSpend::fetch(
            provider => 'go', http => $http_ok, now => NOW_EPOCH, cache => {},
            credential => { cookie => $SECRET_COOKIE }, log_path => $log_path,
        );
    });
    ok(defined $res1, 'C4 setup: fetch() (happy path) returns without dying') or diag($err1);

    # Error path: an expired/rejected cookie (see C6) -- still with the real cookie value present
    # in the call, still logging to the real log.
    my $http_401 = sub { return { status => 401, content => 'unauthorized' } };
    try_call('BpSpend::fetch (expired-cookie path, logged)', sub {
        BpSpend::fetch(
            provider => 'go', http => $http_401, now => NOW_EPOCH, cache => {},
            credential => { cookie => $SECRET_COOKIE }, log_path => $log_path,
        );
    });

    # Positive gate FIRST (mandatory vacuity check for C4): something was actually logged.
    my $log_content = -e $log_path ? read_file($log_path) : undef;
    ok(defined $log_content && length($log_content) > 0,
       'C4 positive gate: bp-log.pl actually wrote something to the log file (not an empty/absent log)')
        or diag('log file ' . (defined $log_content ? '(empty)' : '(absent)') . " at $log_path");

    # Negative: the raw cookie value never appears anywhere in that real log output, across
    # BOTH the happy path and the error path.
    if (defined $log_content) {
        unlike($log_content, qr/\Q$SECRET_COOKIE\E/,
            'C4: the raw cookie value does NOT appear anywhere in bp-log.pl\'s real log output (happy path + error path)');
        # sanity: the log format really is bp-log.pl's (ts + type JSON lines), not some other file.
        my @lines = grep { length } split /\n/, $log_content;
        my $shaped = grep {
            my $d = eval { JSON::PP::decode_json($_) };
            ref($d) eq 'HASH' && exists $d->{ts} && exists $d->{type};
        } @lines;
        ok($shaped > 0, 'C4 HARNESS: at least one logged line is bp-log.pl-shaped (ts + type JSON)');
    } else {
        fail('C4: the raw cookie value does NOT appear anywhere in bp-log.pl\'s real log output');
    }
}

# =====================================================================================
# C5 -- a group- or world-readable credential FILE is REFUSED, naming the path and the
# required mode.
# =====================================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $insecure_path = "$tmp/opencode-go.json";
    write_file($insecure_path, JSON::PP->new->encode({ cookie => 'irrelevant-value' }));
    chmod 0644, $insecure_path;   # world-readable

    my ($res, $err) = try_call('BpSpend::resolve_credential (insecure file)', sub {
        BpSpend::resolve_credential(env_var => 'BP_TEST_SPEND_COOKIE_UNSET_ON_PURPOSE',
                                     env => {}, fallback_path => $insecure_path);
    });
    my $r = $res ? $res->[0] : undef;
    is(ref($r) eq 'HASH' ? $r->{ok} : undef, 0, 'C5: a group/world-readable credential file is refused (ok=0)')
        or diag($err // (defined $r ? JSON::PP->new->canonical->encode($r) : '(undef)'));
    if (ref($r) eq 'HASH') {
        like($r->{detail} // '', qr/\Q$insecure_path\E/, 'C5: the refusal NAMES the insecure path');
        like($r->{detail} // '', qr/0?600/, 'C5: the refusal NAMES the required mode (0600)');
    } else {
        fail('C5: the refusal NAMES the insecure path');
        fail('C5: the refusal NAMES the required mode (0600)');
    }

    # Positive control: the SAME file at a safe mode is accepted, proving refusal isn't blanket.
    chmod 0600, $insecure_path;
    my ($res2) = try_call('BpSpend::resolve_credential (secure file)', sub {
        BpSpend::resolve_credential(env_var => 'BP_TEST_SPEND_COOKIE_UNSET_ON_PURPOSE',
                                     env => {}, fallback_path => $insecure_path);
    });
    my $r2 = $res2 ? $res2->[0] : undef;
    is(ref($r2) eq 'HASH' ? $r2->{ok} : undef, 1, 'C5 control: the SAME file at mode 0600 is accepted');
}

# =====================================================================================
# C6 -- an expired/rejected cookie yields `unknown` + an actionable "re-copy the cookie"
# message, and DOES NOT PAUSE. Session cookies die; expiry is expected, not exceptional.
# =====================================================================================
{
    my $http_401 = sub { return { status => 401, content => 'unauthorized' } };
    my ($res, $err) = try_call('BpSpend::fetch (401 expired cookie)', sub {
        BpSpend::fetch(provider => 'zen', http => $http_401, now => NOW_EPOCH, cache => {},
                        credential => { cookie => 'expired-cookie-value' });
    });
    my $r = $res ? $res->[0] : undef;
    is(ref($r) eq 'HASH' ? $r->{status} : undef, 'unknown', 'C6: an expired/rejected (401) cookie yields status=unknown')
        or diag($err // (defined $r ? JSON::PP->new->canonical->encode($r) : '(undef)'));
    if (ref($r) eq 'HASH') {
        like($r->{diagnostic} // '', qr/re-?copy.*cookie/i,
             'C6: the message is actionable -- tells the operator to re-copy the cookie');
        unlike($r->{diagnostic} // '', qr/died|Died at|stack trace|Undefined subroutine/i,
             'C6: never a stack trace / crash text as the diagnostic');
    } else {
        fail('C6: the message is actionable -- tells the operator to re-copy the cookie');
    }

    my $login_page_http = sub { return { status => 200, content => $ZEN_LOGIN_REDIRECT } };
    my ($res2) = try_call('BpSpend::fetch (login-page redirect)', sub {
        BpSpend::fetch(provider => 'zen', http => $login_page_http, now => NOW_EPOCH, cache => {},
                        credential => { cookie => 'expired-cookie-value' });
    });
    my $r2 = $res2 ? $res2->[0] : undef;
    is(ref($r2) eq 'HASH' ? $r2->{status} : undef, 'unknown',
       'C6: a 200 response that is actually a login-page redirect ALSO yields unknown (rejected session, not a parse failure)');

    my ($v_res) = try_call('BpSpend::verdict over an expired-cookie result', sub { BpSpend::verdict($r) });
    my $v = $v_res ? $v_res->[0] : undef;
    isnt(ref($v) eq 'HASH' ? ($v->{action} // '') : '', 'pause',
         'C6: an expired-cookie result never causes the composed verdict to PAUSE');
}

# =====================================================================================
# C7 -- unreachable network yields `unknown` and DOES NOT PAUSE (bp-deps-check.pl's binding
# invariant: no gate manufactures a failure/halt out of a network outage).
# =====================================================================================
{
    my $http_unreachable = sub { return { status => 0, content => '' } };
    my ($res, $err) = try_call('BpSpend::fetch (unreachable network)', sub {
        BpSpend::fetch(provider => 'go', http => $http_unreachable, now => NOW_EPOCH, cache => {},
                        credential => { cookie => 'some-cookie' });
    });
    my $r = $res ? $res->[0] : undef;
    is(ref($r) eq 'HASH' ? $r->{status} : undef, 'unknown', 'C7: an unreachable network yields status=unknown')
        or diag($err // (defined $r ? JSON::PP->new->canonical->encode($r) : '(undef)'));

    my $http_dies = sub { die "connection refused (simulated transport death)\n" };
    my ($res2, $err2) = try_call('BpSpend::fetch (transport dies)', sub {
        BpSpend::fetch(provider => 'go', http => $http_dies, now => NOW_EPOCH, cache => {},
                        credential => { cookie => 'some-cookie' });
    });
    # Whether fetch() catches the die itself or it propagates, the OUTCOME must never be a
    # process crash that takes a fleet down -- either a graceful unknown result, or (if the
    # die propagates) that is itself the finding to report, not silently accepted.
    my $r2 = $res2 ? $res2->[0] : undef;
    ok((ref($r2) eq 'HASH' && ($r2->{status} // '') eq 'unknown'),
       'C7: a transport that dies is caught and surfaces as status=unknown, never an uncaught crash')
        or diag($err2 // '(fetch returned but not as expected)');

    my ($v_res) = try_call('BpSpend::verdict over an unreachable-network result', sub { BpSpend::verdict($r) });
    my $v = $v_res ? $v_res->[0] : undef;
    isnt(ref($v) eq 'HASH' ? ($v->{action} // '') : '', 'pause',
         'C7: an unreachable-network result never causes the composed verdict to PAUSE');
}

# =====================================================================================
# C8 -- the cadence floor holds: repeated calls inside the TTL do not refetch; the constants
# are NAMED, not bare literals.
# =====================================================================================
{
    ok(defined $BpSpend::CADENCE_TTL_SECONDS && $BpSpend::CADENCE_TTL_SECONDS > 0,
       'C8 positive gate: $BpSpend::CADENCE_TTL_SECONDS is a defined, positive NAMED constant');

    my $calls = 0;
    my $http = sub { $calls++; return { status => 200, content => $GO_WELLFORMED } };
    my $cache = {};

    try_call('BpSpend::fetch (cadence, call 1)', sub {
        BpSpend::fetch(provider => 'go', http => $http, now => NOW_EPOCH, cache => $cache,
                        credential => { cookie => 'c' });
    });
    try_call('BpSpend::fetch (cadence, call 2, inside TTL)', sub {
        BpSpend::fetch(provider => 'go', http => $http, now => NOW_EPOCH + 1, cache => $cache,
                        credential => { cookie => 'c' });
    });
    is($calls, 1, 'C8: a second call inside the TTL window does NOT refetch (the injected http was called once)')
        or diag("http was called $calls time(s)");

    try_call('BpSpend::fetch (cadence, call 3, after TTL)', sub {
        BpSpend::fetch(provider => 'go', http => $http,
                        now => NOW_EPOCH + $BpSpend::CADENCE_TTL_SECONDS + 1, cache => $cache,
                        credential => { cookie => 'c' });
    });
    ok($calls >= 2, 'C8: a call AFTER the TTL has elapsed DOES refetch (the cadence floor is not a permanent cache)')
        or diag("http was called $calls time(s) total");

    # Named, not bare literal: scan the source for the cadence figure appearing as a variable
    # reference/constant, not scattered as raw seconds inline at each call site. This is a soft,
    # source-level check mirroring C5 of t/90 (bp-pin.pl's "no second EOL table" scan).
    if (-e $SPEND) {
        my $src = read_file($SPEND) // '';
        like($src, qr/CADENCE_TTL_SECONDS/, 'C8: bp-spend.pl source references a named cadence constant, not only a bare literal');
    } else {
        fail('C8: bp-spend.pl source references a named cadence constant, not only a bare literal');
    }
}

# =====================================================================================
# C9 -- the cookie is ABSENT from the jailed-worker environment (b33's jail was designed on
# OpenCode needing no credential; this is the FIRST OpenCode-related secret in the system).
#
# Exercised against the REAL bp-jail.pl (unmodified -- not in this package's write set), the
# actual mechanism that runs a command inside the worker jail. The scenario: a cookie value is
# present in the DISPATCHING process's own environment (as it would be if a coordinator that
# also polls spend spawned a jailed worker without deliberately excluding it) -- and the test
# asserts the jailed command never sees it. If nothing in the system currently strips it, this
# is expected to show the leak plainly (not skipped, not silently accepted).
# =====================================================================================
{
    # NOTE: there is deliberately NO skip_all here. bp-jail.pl is a shipped, present mechanism
    # (b33); if it were ever absent that is a finding, and the -e assertion below reports it as
    # a failure rather than letting the file exit 0 with an empty plan.
    {
        require File::Path;
        require POSIX;

        my $secret = 'OPENCODE-COOKIE-MUST-NOT-REACH-JAILED-WORKER-4b19e';
        my $proj = tempdir(DIR => '/root', CLEANUP => 1);
        system('git', '-C', $proj, 'init', '-q');
        system('git', '-C', $proj, 'config', 'user.email', 'bp-spend-test@example.invalid');
        system('git', '-C', $proj, 'config', 'user.name', 'bp-spend-test');
        write_file("$proj/keep.txt", "hello\n");
        system('git', '-C', $proj, 'add', '-A');
        system('git', '-C', $proj, 'commit', '-q', '-m', 'baseline');

        my $jailroot = tempdir(DIR => '/root', CLEANUP => 0);
        File::Path::remove_tree($jailroot);

        ok(-e $JAIL, 'C9 HARNESS: bp-jail.pl exists in this checkout (the real, unmodified mechanism under test)');

      SKIP: {
            skip('C9: bp-jail.pl not present -- cannot probe the jailed environment at all', 2) unless -e $JAIL;

            local %ENV = (%ENV, OPENCODE_AUTH_COOKIE => $secret, OPENCODE_GO_AUTH_COOKIE => $secret,
                          BP_PROJECT_ROOT => $proj, BP_WRITE_SET => 'keep.txt');

            my $create_out = `"$^X" "$JAIL" create --package c9-pkg --jail-root "$jailroot" 2>&1`;
            my $envfile = "$jailroot/work/.env-probe.txt";
            my $run_cmd = qq{"$^X" "$JAIL" run --package c9-pkg --jail-root "$jailroot" -- env 2>&1};
            my $probe_out = `$run_cmd`;

            unlike($probe_out, qr/\Q$secret\E/,
                'C9: the OpenCode cookie value is NOT visible in the jailed command\'s own environment (`env` output)');
            unlike($probe_out, qr/OPENCODE_AUTH_COOKIE|OPENCODE_GO_AUTH_COOKIE/,
                'C9: neither OPENCODE_AUTH_COOKIE nor OPENCODE_GO_AUTH_COOKIE is even NAMED in the jailed environment');

            system(qq{"$^X" "$JAIL" teardown --package c9-pkg --jail-root "$jailroot"});
        }
        File::Path::remove_tree($jailroot) if -e $jailroot;
        File::Path::remove_tree($proj) if -e $proj;
    }
}

# =====================================================================================
# C10 -- NO LIVE HTTP anywhere in the suite. Positive: assert the injected fetcher was actually
# CALLED (a call counter), not merely that no socket opened -- this whole suite's http seam is
# exercised throughout (C1/C2/C6/C7/C8 above already prove it), consolidated here as its own
# named assertion set.
# =====================================================================================
{
    my $calls = 0;
    my $http = sub { $calls++; return { status => 200, content => $ZEN_WELLFORMED } };
    try_call('BpSpend::fetch (C10 call-counter, zen)', sub {
        BpSpend::fetch(provider => 'zen', http => $http, now => NOW_EPOCH, cache => {},
                        credential => { cookie => 'c' });
    });
    ok($calls >= 1, 'C10: the injected fetcher coderef was actually invoked by fetch() -- not bypassed');

    # Negative: prove no live transport by OBSERVATION, not by grepping this file's own source.
    # (A self-grep is self-defeating -- the pattern literal is itself part of the source, so the
    # assertion can never pass no matter what the code does.) Instead: after this entire suite has
    # exercised every fetch path above through the injected seam, no real HTTP transport module has
    # been loaded into this process. If bp-spend.pl ever reached the network on its own -- e.g. by
    # falling back to a default transport when `http` was supplied -- one of these would be in %INC.
    ok(!exists $INC{'HTTP/Tiny.pm'},
        'C10: no real HTTP transport (HTTP::Tiny) was ever loaded while running this suite');
    ok(!exists $INC{'LWP/UserAgent.pm'},
        'C10: no real HTTP transport (LWP::UserAgent) was ever loaded while running this suite');
}

done_testing();
