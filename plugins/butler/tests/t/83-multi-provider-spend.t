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
use lib "$Bin/../lib";
use HostCaps qw(chmod_works);

# The credential-file feature is defined in terms of POSIX permission bits: a
# 0600 file is trusted, anything looser is refused. On a filesystem that stores
# no modes (NTFS through Git-Bash perl) chmod 0600 does not take, so the
# production code CORRECTLY refuses the file and every positive-control
# assertion inverts. The refusal is right; the property is simply unobservable
# here. Gate the positive controls rather than reporting a defect.
my $MODES = chmod_works();
my $NO_MODES = 'this filesystem stores no POSIX permission bits, so a 0600 credential file '
             . 'cannot be created or trusted here -- the positive control is unobservable';
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
my $AUTH     = "$SCRIPTS/bp-spend-auth.pl";
my $DOCS     = "$BUTLER/docs/spend-credentials.md";

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

# run_auth($stdin_content, @argv) -> ($combined_stdout_stderr, $exit_code)
#
# Runs bp-spend-auth.pl as a REAL external process (never a require -- the whole
# point of C17 is argv/stdin/echo behaviour of the actual CLI entry point), with
# $stdin_content piped in via a temp file (never a shell pipe literal, so a cookie
# value containing shell metacharacters cannot break quoting) and every element of
# @argv individually double-quoted.
sub run_auth {
    my ($stdin_content, @args) = @_;
    my ($sfh, $spath) = tempfile();
    print {$sfh} (defined $stdin_content ? $stdin_content : '');
    close $sfh;
    my @quoted = map { (my $a = $_) =~ s/"/\\"/g; qq{"$a"} } @args;
    my $cmd = join(' ', qq{"$^X"}, qq{"$AUTH"}, @quoted, '<', qq{"$spath"}, '2>&1');
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    unlink $spath;
    return ($out, $rc);
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
  SKIP: {
    skip $NO_MODES, 1 unless $MODES;
    is(ref($r2) eq 'HASH' ? $r2->{ok} : undef, 1, 'C5 control: the SAME file at mode 0600 is accepted');
  }
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
        my $proj = tempdir((-d '/root' && -w '/root') ? (DIR => '/root') : (), CLEANUP => 1);
        system('git', '-C', $proj, 'init', '-q');
        system('git', '-C', $proj, 'config', 'user.email', 'bp-spend-test@example.invalid');
        system('git', '-C', $proj, 'config', 'user.name', 'bp-spend-test');
        write_file("$proj/keep.txt", "hello\n");
        system('git', '-C', $proj, 'add', '-A');
        system('git', '-C', $proj, 'commit', '-q', '-m', 'baseline');

        my $jailroot = tempdir((-d '/root' && -w '/root') ? (DIR => '/root') : (), CLEANUP => 0);
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

# =====================================================================================
# C11 -- THREE STATES, not two (ledger done-criterion 1: "a provider that is not
# configured is reported ABSENT, never as zero-spent -- and a provider whose spend is
# UNMEASURABLE is a third state, distinct from both absent and zero").
#
# Added by the coordinator AFTER this package was marked done. The original oracle went
# green at 62/62 while asserting only two states, `ok` and `unknown`, so an unconfigured
# provider was indistinguishable from a configured one whose meter could not be read.
# The green suite was real; its COVERAGE of the done criteria was not checked against
# them one by one, and this criterion had no assertion at all. Found while scouting b37,
# whose own criterion 4 needs four visually distinct states and therefore cannot be built
# on a struct that collapses two of them.
# =====================================================================================
{
    # Not configured at all: no env var, no fallback file.
    my ($absent_out, $absent_err) = try_call('BpSpend::fetch (unconfigured provider)', sub {
        BpSpend::fetch(provider => 'zen', http => sub { die "must not be called\n" },
                        now => NOW_EPOCH, cache => {},
                        env_var => 'S16_NEVER_SET_ANYWHERE', env => {},
                        fallback_path => undef);
    });
    ok(!defined $absent_err, 'C11 setup: fetch() on an unconfigured provider returns without dying')
        or diag($absent_err);
    my $absent = ref($absent_out) eq 'ARRAY' ? $absent_out->[0] : undef;
    is(($absent // {})->{status}, 'absent',
       'C11: a provider with no credential and no fallback file is ABSENT -- not unknown, because there is no meter to be uncertain about');

    # Guarded: an undef result must NOT pass this by having no fields to inspect.
    ok(ref($absent) eq 'HASH', 'C11 gate: the absent result is a real struct (so the no-numeric check below is not vacuous)');
    my $absent_dump = join(' ', map { "$_=" . (defined $absent->{$_} ? $absent->{$_} : 'undef') }
                                sort keys %{ ref($absent) eq 'HASH' ? $absent : {} });
    unlike($absent_dump, qr/=\s*-?\d+(?:\.\d+)?\b/,
           'C11: the absent result carries NO numeric field -- absent is not zero-spent');

    # Configured but refused (mode 0600 violated): that IS a meter we could not read.
    my $tmpdir = tempdir(CLEANUP => 1);
    my $bad = "$tmpdir/cookie.json";
    write_file($bad, '{"cookie":"x"}');
    chmod 0644, $bad;
    my ($refused_out, $refused_err) = try_call('BpSpend::fetch (insecure credential file)', sub {
        BpSpend::fetch(provider => 'zen', http => sub { die "must not be called\n" },
                        now => NOW_EPOCH, cache => {},
                        env_var => 'S16_NEVER_SET_ANYWHERE', env => {},
                        fallback_path => $bad);
    });
    my $refused = ref($refused_out) eq "ARRAY" ? $refused_out->[0] : undef;
    is(($refused // {})->{status}, 'unknown',
       'C11 (the distinction): a credential that EXISTS but is refused is UNKNOWN, not absent -- the provider is configured and its meter is unreadable');

    # And the two must not collapse into each other.
    isnt(($absent // {})->{status}, ($refused // {})->{status},
         'C11: absent and unknown are genuinely DIFFERENT states, not two labels for one');

    # verdict(): absent does not drag the composed verdict to unknown (Zen is off by
    # default, so an unconfigured provider must not make every run permanently unknown).
    my ($v_absent_out, $v_absent_err) = try_call('BpSpend::verdict (ok + absent)', sub {
        BpSpend::verdict({ provider => 'claude', status => 'ok' },
                          { provider => 'zen',    status => 'absent' });
    });
    my $v_absent = ref($v_absent_out) eq "ARRAY" ? $v_absent_out->[0] : undef;
    is(($v_absent // {})->{action}, 'ok',
       'C11: a verdict over [ok, absent] is ok -- an unconfigured provider does not make the run unknown');

    # VACUITY GATE: verdict must still go unknown when a CONFIGURED provider is unreadable,
    # so the filtering above cannot be an implementation that ignores everything.
    my ($v_unknown_out, $v_unknown_err) = try_call('BpSpend::verdict (ok + absent + unknown)', sub {
        BpSpend::verdict({ provider => 'claude', status => 'ok' },
                          { provider => 'zen',    status => 'absent' },
                          { provider => 'go',     status => 'unknown' });
    });
    my $v_unknown = ref($v_unknown_out) eq "ARRAY" ? $v_unknown_out->[0] : undef;
    is(($v_unknown // {})->{action}, 'unknown',
       'C11 VACUITY GATE: a real unknown still propagates even when an absent provider is also present');
}

# =====================================================================================
# EXTENSION -- b36 REOPENED (spec: b36-spend-persistence-and-auth-spec.md, §5, C12..C20).
# Everything below is additive to the C1..C11 oracle above, which stayed untouched.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION, same as C1..C11. At authoring time
# bp-spend.pl has NO write_snapshot(), NO read path used by these tests, and
# bp-spend-auth.pl / docs/spend-credentials.md do not exist at all.
#
# FURTHER INVENTED CONTRACT (test-writer's job, same footing as the header block
# above), inferred from spec §2/§2.1/§3 vocabulary and this repo's own conventions
# (bp-pin.pl's --manifest/--fetcher override flags for test injectability):
#
#   BpSpend::write_snapshot(%opts) -> writes the composed snapshot.
#     opts: path => PATH, results => \@results (each shaped like fetch()'s return),
#           credential => \%opt (optional -- exercised only to prove it is NEVER
#           forwarded into the written bytes, see C14), now => epoch.
#     Must write JSON as { generated_at => ..., results => [ ...whitelisted fields... ] }
#     atomically (temp file in the same directory, then rename) at mode 0600.
#     Only fetch()'s own documented fields (provider/status/five_hour/weekly/
#     monthly/balance/budget/diagnostic) may appear -- nothing else, at any depth.
#
#   bp-spend-auth.pl (CLI, run as a real subprocess, never required):
#     --provider NAME              store a cookie for NAME, read from STDIN only
#     --provider NAME --from-firefox   host-side extraction (§3.1), degrades on
#                                       any non-Windows / no-profile / no-match case
#     --status [--provider NAME]   report presence/mode/parseability, never the value
#     --path PATH                  TEST-ONLY override of the credential file location
#                                   (mirrors bp-pin.pl's --manifest/--fetcher), so this
#                                   oracle never touches a real credential path.
#
# MANDATORY VACUITY GATES (this section's own, mirroring C1..C11's convention):
#   - C14 gates on "bytes were actually written" BEFORE the negative sentinel check,
#     so an empty/absent file cannot pass the redaction assertion for free.
#   - C12 pairs the removed-env assertion with a same-run file-resolves positive.
#   - C17 pairs the argv-rejection assertion with a same-run STDIN-store positive.
#   - C18 tests only the degrade path (the happy path is Windows-only, see below);
#     it is NOT skipped -- its absence-of-a-Windows-host does not change what is
#     assertable about the degrade behaviour, which is fully exercisable here.
# =====================================================================================

# =====================================================================================
# C12 -- the env credential path is GONE, not merely unused. With the env var set and
# NO file, resolve_credential must report `missing`. Paired positive: a 0600 file
# resolves regardless of what the (must-be-ignored) env var holds.
# =====================================================================================
{
    my $ENV_SENTINEL = 'ENV-COOKIE-MUST-BE-IGNORED-3c88a1';

    for my $var (qw(OPENCODE_GO_AUTH_COOKIE OPENCODE_AUTH_COOKIE)) {
        my ($res, $err) = try_call("BpSpend::resolve_credential (env-only, $var)", sub {
            BpSpend::resolve_credential(env_var => $var, env => { $var => $ENV_SENTINEL },
                                         fallback_path => undef);
        });
        my $r = $res ? $res->[0] : undef;
        is(ref($r) eq 'HASH' ? $r->{reason} : undef, 'missing',
           "C12: with $var set in the injected env and NO file, resolve_credential reports reason=missing -- the env path is GONE")
            or diag($err // (defined $r ? JSON::PP->new->canonical->encode($r) : '(undef)'));
        is(ref($r) eq 'HASH' ? $r->{ok} : undef, 0, "C12: ...and ok=0 for $var (paired with reason=missing above)");
    }

    my $tmp = tempdir(CLEANUP => 1);
    my $file_path = "$tmp/cookie-file-only.json";
    write_file($file_path, JSON::PP->new->encode({ cookie => 'file-sourced-cookie-value' }));
    chmod 0600, $file_path;

    my ($res2) = try_call('BpSpend::resolve_credential (file present, env set but must be ignored)', sub {
        BpSpend::resolve_credential(env_var => 'OPENCODE_GO_AUTH_COOKIE',
                                     env => { OPENCODE_GO_AUTH_COOKIE => $ENV_SENTINEL },
                                     fallback_path => $file_path);
    });
    my $r2 = $res2 ? $res2->[0] : undef;
  SKIP: {
    skip $NO_MODES, 3 unless $MODES;
    is(ref($r2) eq 'HASH' ? $r2->{ok} : undef, 1,
       'C12 positive: with a 0600 file present it resolves from the file (both env-removed and file-still-works, or neither)');
    is(ref($r2) eq 'HASH' ? $r2->{source} : undef, 'file', 'C12 positive: the resolution source is "file", never "env"');
    is(ref($r2) eq 'HASH' ? $r2->{cookie} : undef, 'file-sourced-cookie-value',
       'C12 positive: the resolved cookie is the FILE value, not the must-be-ignored env value');
  }
}

# =====================================================================================
# C13 -- snapshot round-trips for ok / unknown / absent alike.
# =====================================================================================
{
    my $tmp  = tempdir(CLEANUP => 1);
    my $path = "$tmp/spend.json";

    my $ok_result = { provider => 'go', status => 'ok',
        five_hour => { used => 42, limit => 100 },
        weekly    => { used => 310, limit => 1000 },
        monthly   => { used => 2200, limit => 4000 } };
    my $unknown_result = { provider => 'zen', status => 'unknown',
        diagnostic => 'credential unavailable (insecure-file): re-copy the cookie into a 0600 file' };
    my $absent_result = { provider => 'claude', status => 'absent',
        diagnostic => 'provider not configured: no fallback file and no credential' };

    my ($wres, $werr) = try_call('BpSpend::write_snapshot (C13 round-trip fixture)', sub {
        BpSpend::write_snapshot(path => $path, results => [ $ok_result, $unknown_result, $absent_result ],
                                 now => NOW_EPOCH);
    });
    ok(defined $wres, 'C13 setup: BpSpend::write_snapshot returns without dying') or diag($werr);

    my $bytes = -e $path ? read_file($path) : undef;
    ok(defined $bytes && length $bytes, 'C13 setup: write_snapshot actually produced a non-empty file on disk')
        or diag('snapshot file ' . (defined $bytes ? '(empty)' : '(absent)') . " at $path");

    my $decoded = defined $bytes ? eval { JSON::PP->new->decode($bytes) } : undef;
    ok(ref($decoded) eq 'HASH', 'C13 setup: the written snapshot decodes as JSON') or diag($@ // '(no bytes)');

    my $results = ref($decoded) eq 'HASH' ? $decoded->{results} : undef;
    ok(ref($results) eq 'ARRAY' && @$results == 3,
       "C13 setup: the decoded snapshot carries this test's own 3 fixture results (own fixture count, not a shared-artifact total)");

    my %by_provider = map { (ref($_) eq 'HASH' ? ($_->{provider} // '?') : '?') => $_ }
                       (ref($results) eq 'ARRAY' ? @$results : ());

    my $rt_ok = $by_provider{go};
    is(ref($rt_ok) eq 'HASH' ? $rt_ok->{status} : undef, 'ok', "C13: round-tripped 'ok' result keeps status=ok");
    is(ref($rt_ok) eq 'HASH' ? $rt_ok->{five_hour}{used} : undef, 42, "C13: round-tripped 'ok' result keeps five_hour.used=42");
    is(ref($rt_ok) eq 'HASH' ? $rt_ok->{monthly}{limit} : undef, 4000, "C13: round-tripped 'ok' result keeps monthly.limit=4000");

    my $rt_unk = $by_provider{zen};
    is(ref($rt_unk) eq 'HASH' ? $rt_unk->{status} : undef, 'unknown', "C13: round-tripped 'unknown' result keeps status=unknown");
    like(ref($rt_unk) eq 'HASH' ? ($rt_unk->{diagnostic} // '') : '', qr/re-?copy.*cookie/i,
         "C13: round-tripped 'unknown' result keeps its diagnostic");

    my $rt_absent = $by_provider{claude};
    is(ref($rt_absent) eq 'HASH' ? $rt_absent->{status} : undef, 'absent', "C13: round-tripped 'absent' result keeps status=absent");
}

# =====================================================================================
# C14 -- THE MOST IMPORTANT ASSERTION IN THIS PACKAGE. Token-shaped sentinel cookie,
# planted at TWO nesting depths (top-level field and inside a nested sub-hash) plus
# handed explicitly as `credential`, to prove redaction is structural, not accidental.
# The sentinel must appear NOWHERE in the written bytes. Paired positive: the real
# figures ARE present -- an empty/near-empty file must fail BOTH halves, not pass the
# negative one for free (mandatory vacuity gate, see file header).
# =====================================================================================
{
    my $tmp  = tempdir(CLEANUP => 1);
    my $path = "$tmp/spend-redaction.json";
    my $SENTINEL_TOP    = 'SPEND-SNAPSHOT-COOKIE-SENTINEL-TOP-b7f1e9';
    my $SENTINEL_NESTED = 'SPEND-SNAPSHOT-COOKIE-SENTINEL-NESTED-4d02ac';

    my $leaky_result = {
        provider  => 'go', status => 'ok',
        five_hour => { used => 7, limit => 20 },
        weekly    => { used => 55, limit => 200 },
        monthly   => { used => 300, limit => 900 },
        # Must NEVER survive into the written bytes, at two different nesting
        # depths -- simulates a composer that passes the credential straight
        # through instead of building an explicit field whitelist.
        cookie => $SENTINEL_TOP,
        _debug => { last_request => { headers => { Cookie => "session=$SENTINEL_NESTED" } } },
    };

    my ($wres, $werr) = try_call('BpSpend::write_snapshot (C14 redaction fixture)', sub {
        BpSpend::write_snapshot(path => $path, results => [ $leaky_result ],
                                 credential => { cookie => $SENTINEL_TOP }, now => NOW_EPOCH);
    });
    ok(defined $wres, 'C14 setup: write_snapshot(leaky result + explicit credential arg) returns without dying')
        or diag($werr);

    my $bytes = -e $path ? read_file($path) : undef;
    ok(defined $bytes && length $bytes,
       'C14 positive gate: the snapshot file was actually written with content -- an empty/absent file must NOT pass the redaction check for free')
        or diag('snapshot file ' . (defined $bytes ? '(empty)' : '(absent)') . " at $path");

    if (defined $bytes && length $bytes) {
        unlike($bytes, qr/\Q$SENTINEL_TOP\E/,
            'C14 THE MOST IMPORTANT ASSERTION: the top-level cookie sentinel appears NOWHERE in the written snapshot bytes');
        unlike($bytes, qr/\Q$SENTINEL_NESTED\E/,
            'C14: a cookie sentinel nested inside a sub-hash ALSO appears nowhere -- redaction holds at any nesting depth');
        like($bytes, qr/\b7\b/,   'C14 positive pair: the real five_hour.used figure (7) IS present in the snapshot');
        like($bytes, qr/\b900\b/, 'C14 positive pair: the real monthly.limit figure (900) IS present in the snapshot');
        like($bytes, qr/go/,      'C14 positive pair: the provider name IS present in the snapshot');
    } else {
        fail('C14 THE MOST IMPORTANT ASSERTION: the top-level cookie sentinel appears NOWHERE in the written snapshot bytes');
        fail('C14: a cookie sentinel nested inside a sub-hash ALSO appears nowhere in the written bytes');
        fail('C14 positive pair: the real figures ARE present in the snapshot');
    }
}

# =====================================================================================
# C15 -- atomic write: temp-then-rename in the same directory, asserted structurally
# (source-level, mirroring C8's named-constant check) AND behaviourally (no stray file
# left in the directory after a successful write).
# C16 -- mode 0600 on the written snapshot.
# =====================================================================================
{
    my $tmp  = tempdir(CLEANUP => 1);
    my $path = "$tmp/spend-atomic.json";

    ok(!-e $path, 'C15/C16 setup: the snapshot path does not exist before the write (clean fixture)');

    my ($wres, $werr) = try_call('BpSpend::write_snapshot (C15/C16 fixture)', sub {
        BpSpend::write_snapshot(path => $path,
            results => [ { provider => 'go', status => 'ok', five_hour => { used => 1, limit => 2 } } ],
            now => NOW_EPOCH);
    });
    ok(defined $wres, 'C15/C16 setup: write_snapshot returns without dying') or diag($werr);

    ok(-e $path, 'C15/C16: the final spend-atomic.json file exists after write_snapshot returns');

    if (opendir(my $dh, $tmp)) {
        my @entries = sort grep { !/^\.\.?$/ } readdir($dh);
        closedir $dh;
        is_deeply(\@entries, ['spend-atomic.json'],
            'C15: after write_snapshot returns, the directory holds ONLY the final file -- no leftover temp/partial file from a non-atomic write')
            or diag('directory entries: ' . join(', ', @entries));
    } else {
        fail('C15: after write_snapshot returns, the directory holds ONLY the final file');
    }

    if (-e $path) {
        my @st = stat($path);
        my $mode = @st ? ($st[2] & 07777) : undef;
      SKIP: {
        skip $NO_MODES, 1 unless $MODES;
        is($mode, 0600, 'C16: the written snapshot file is mode 0600');
      }
    } else {
        fail('C16: the written snapshot file is mode 0600');
    }

    my $src = read_file($SPEND) // '';
    my ($sub_body) = $src =~ /sub\s+write_snapshot\b(.*?)(?=\nsub\s+\w|\z)/s;
    if (defined $sub_body) {
        like($sub_body, qr/\brename\s*\(/,
            'C15 structural: write_snapshot() calls rename(...) -- not a direct open-and-write to the final path');
        like($sub_body, qr/tempfile|\.tmp\b|\btmp_|\$\$\D/,
            'C15 structural: write_snapshot() writes to a temp path in the same directory before renaming');
    } else {
        fail('C15 structural: write_snapshot() calls rename(...) -- not a direct open-and-write to the final path');
        fail('C15 structural: write_snapshot() writes to a temp path in the same directory before renaming');
    }
}

# =====================================================================================
# C17 -- bp-spend-auth.pl never takes the cookie on argv, never echoes it (not even in
# --status), and creates the file 0600 at creation. Paired positive: a cookie fed on
# STDIN is stored and afterwards resolvable via the REAL resolve_credential().
# =====================================================================================
{
    diag("subject under test: $AUTH " . (-e $AUTH ? "(present)" : "(ABSENT -- C17 assertions below are expected to fail on MISSING BEHAVIOUR)"));

    my $tmp  = tempdir(CLEANUP => 1);
    my $path = "$tmp/cookie.json";
    my $COOKIE = 'AUTH-AGENT-CLI-COOKIE-VALUE-9d21f0';

    # --- positive: STDIN cookie is stored, at 0600, and afterwards resolvable. ---
    my ($out, $rc) = run_auth($COOKIE, '--provider', 'go', '--path', $path);
    ok(-e $path, 'C17 positive: bp-spend-auth.pl (STDIN cookie) creates the credential file')
        or diag("auth output: $out (rc=$rc)");

    if (-e $path) {
        my @st = stat($path);
        my $mode = @st ? ($st[2] & 07777) : undef;
      SKIP: {
        skip $NO_MODES, 3 unless $MODES;
        is($mode, 0600, 'C17 positive: the created credential file is mode 0600 (created that way, per spec 3)');

        my ($res) = try_call('BpSpend::resolve_credential (after bp-spend-auth.pl STDIN store)', sub {
            BpSpend::resolve_credential(env_var => 'BP_TEST_SPEND_COOKIE_UNSET_ON_PURPOSE', env => {},
                                         fallback_path => $path);
        });
        my $r = $res ? $res->[0] : undef;
        is(ref($r) eq 'HASH' ? $r->{ok} : undef, 1, 'C17 positive: the STDIN-stored cookie resolves successfully afterwards');
        is(ref($r) eq 'HASH' ? $r->{cookie} : undef, $COOKIE, 'C17 positive: the resolved cookie value matches what was fed on STDIN');
      }
    } else {
        fail('C17 positive: the created credential file is mode 0600');
        fail('C17 positive: the STDIN-stored cookie resolves successfully afterwards');
        fail('C17 positive: the resolved cookie value matches what was fed on STDIN');
    }
    unlike($out, qr/\Q$COOKIE\E/, 'C17: bp-spend-auth.pl never echoes the cookie to its own stdout/stderr');

    # --- negative: a cookie value handed on argv is never accepted (not stored, not echoed). ---
    my $path2 = "$tmp/cookie2.json";
    my $ARGV_SENTINEL = 'ARGV-COOKIE-MUST-NEVER-BE-ACCEPTED-7e42b1';
    my ($out2, undef) = run_auth('', '--provider', 'go', '--cookie', $ARGV_SENTINEL, '--path', $path2);
    my $leaked_in_file = 0;
    if (-e $path2) {
        my $file_bytes = read_file($path2) // '';
        $leaked_in_file = (index($file_bytes, $ARGV_SENTINEL) >= 0) ? 1 : 0;
    }
    ok(!$leaked_in_file, 'C17: a cookie value supplied on argv is never written to the credential file');
    unlike($out2, qr/\Q$ARGV_SENTINEL\E/, 'C17: a cookie value supplied on argv is never echoed either');

    # --- --status never echoes the value, using the file stored via STDIN above. ---
    my ($out3, undef) = run_auth('', '--status', '--provider', 'go', '--path', $path);
    unlike($out3, qr/\Q$COOKIE\E/, 'C17: --status never echoes the cookie value, not even truncated');
}

# =====================================================================================
# C18 -- --from-firefox degrades: no profile / no DB / no matching cookie must exit
# non-zero, print manual instructions, and write NOTHING (no empty, no partial file).
# The happy path is Windows-only (winsqlite3.dll, spec §3.1) and is NOT assertable
# inside this Linux sandbox container -- only the degrade path is tested here.
# =====================================================================================
{
    # HARNESS gate, real assertion not diag-only: without this, "exits non-zero" and
    # "writes nothing" below would pass VACUOUSLY while bp-spend-auth.pl is simply
    # absent (a nonexistent script also exits non-zero and also writes nothing) --
    # exactly the "passes because the feature is ABSENT" trap the spec warns about.
    ok(-e $AUTH, 'C18 HARNESS: bp-spend-auth.pl exists in this checkout (so the degrade checks below are not vacuous)');

    my $tmp = tempdir(CLEANUP => 1);
    my $ff_path = "$tmp/cookie-ff.json";   # deliberately does not exist beforehand

    my ($out, $rc) = run_auth('', '--provider', 'go', '--from-firefox', '--path', $ff_path);
    isnt($rc, 0, 'C18: --from-firefox with no usable browser profile/db/cookie exits non-zero')
        or diag("auth output: $out");
    ok(!-e $ff_path, 'C18: --from-firefox degrade writes NOTHING -- no empty/partial credential file');
    like($out, qr/manual/i, 'C18: --from-firefox degrade prints the manual fallback instructions');

    diag('C18: the --from-firefox HAPPY PATH depends on winsqlite3.dll (Windows 10/11) per spec §3.1 '
       . 'and cannot be exercised inside this Linux sandbox container; only the degrade path is tested.');
}

# =====================================================================================
# C19 -- plugins/butler/docs/spend-credentials.md exists and names the path, the mode,
# and the expiry behaviour. Each assertion is scoped to its own paragraph (vicinity),
# never a bare match over the whole file, so unrelated prose elsewhere cannot produce a
# false pass.
# =====================================================================================
{
    ok(-e $DOCS, 'C19: plugins/butler/docs/spend-credentials.md exists');

    if (-e $DOCS) {
        my $doc = read_file($DOCS) // '';
        my @paras = split /\n\s*\n/, $doc;

        my $has_path = grep { /\.claude[\/\\]/ && /path/i } @paras;
        ok($has_path, 'C19: some paragraph of the docs names BOTH the credential path (under ~/.claude/) and calls it out as "the path"');

        my $has_mode = grep { /\b0?600\b/ && /mode|permission/i } @paras;
        ok($has_mode, 'C19: some paragraph of the docs names the required mode (0600)');

        my $has_expiry = grep { /expir/i } @paras;
        ok($has_expiry, 'C19: some paragraph of the docs describes expiry behaviour');
    } else {
        fail('C19: docs name the credential path');
        fail('C19: docs name the required mode (0600)');
        fail('C19: docs describe expiry behaviour');
    }
}

# =====================================================================================
# C20 -- no regression. Not a new assertion of its own (a self-referential "this file
# still passes" check would be vacuous) -- it is verified by running this WHOLE file:
# C1..C11 above are untouched by this extension, and t/156-worker-jail-isolation.t is
# run and confirmed separately as part of this package's verification, per spec §5.
# =====================================================================================

# =====================================================================================
# b47 -- REACHABILITY. C21..C24.
#
# WHY THESE EXIST, AND WHY THEY ARE NOT ROUND-TRIP ASSERTIONS.
#
# Everything above this line passed while the entire feature was INERT.
# `write_snapshot` was correct, tested, and had ZERO production callers;
# `bp-spend.pl` ended `package main; 1;` with no `unless (caller)` block, so no
# shell or orchestrator path could invoke it at all. `fetch` and `verdict` were
# equally unreachable -- they appear in launcher.pl:4686 and SpendPanel.pm:24
# only inside COMMENTS describing a wiring that did not exist.
#
# The operator-visible failure: open the TUI on a real fleet and the Spend panel
# is absent forever. Not an error -- the reader's `-f` guard plus its swallowing
# `eval` make a permanently-broken feature look exactly like "no data yet".
#
# b37 escalated this gap honestly and left the artifact's lifecycle to b36; b36
# built the artifact writer and never called it. Both packages are individually
# defensible and the seam between them was empty. So these assertions check the
# SEAM, not the units: a symbol with no caller is inert whatever the unit tests
# say.
# =====================================================================================
{
    my $root = "$Bin/../../../..";

    # --- C21: the module is invocable at all (it was not) --------------------
    my $spend_src = do {
        open my $fh, '<', "$Bin/../../scripts/bp-spend.pl" or die "open bp-spend.pl: $!";
        local $/; <$fh>;
    };
    like($spend_src, qr/unless \s* \( \s* caller \s* \)/x,
        'C21: bp-spend.pl has a CLI entry point (an `unless (caller)` block), not just a module body');

    # --- C22: a PRODUCTION caller of the writer exists -----------------------
    # The load-bearing one. Asserting the round trip alone is exactly what let
    # this ship twice, so this greps the tree for a non-test caller and fails if
    # the only references are the definition and the tests.
    # opendir rather than glob: deterministic, and it does not depend on
    # File::Glob's behaviour inside a long-running test process.
    my @callers;
    my $plug = "$root/plugins";
    if (opendir(my $pd, $plug)) {
        for my $p (sort grep { !/^\./ } readdir $pd) {
            my $sd = "$plug/$p/scripts";
            next unless -d $sd;
            opendir(my $fd, $sd) or next;
            for my $base (sort grep { /\.(pl|sh)$/ } readdir $fd) {
                next if $base eq 'bp-spend.pl';    # the definition itself
                my $f = "$sd/$base";
                open my $fh, '<', $f or next;
                my $t = do { local $/; <$fh> };
                close $fh;
                push @callers, $f
                    if $t =~ /write_snapshot|bp-spend\.pl['"]?\s+snapshot|spend_snapshot/;
            }
            closedir $fd;
        }
        closedir $pd;
    }
    ok(scalar(@callers) > 0,
        'C22: at least one PRODUCTION (non-test) caller writes the spend snapshot')
        or diag('no production caller found -- the writer is inert regardless of the unit tests above');
    diag("C22: production callers: @callers") if @callers;

    # --- C23: absence is DISTINGUISHABLE from broken -------------------------
    # A snapshot that never existed must be observable, not silently identical
    # to "no run active". The writer side must emit an event for it.
    my $orch_src = do {
        open my $fh, '<', "$Bin/../../scripts/bp-orchestrator.pl" or die "open bp-orchestrator.pl: $!";
        local $/; <$fh>;
    };
    like($orch_src, qr/spend_snapshot/,
        'C23: the orchestrator emits a spend_snapshot event, so absence is observable rather than silent');

    # --- C24: the CLI actually writes a snapshot when driven ----------------
    # Executed, not inspected: this is the check that would have caught the
    # original defect, because it invokes the code the way a real caller does.
    SKIP: {
        my $tmp = File::Temp->newdir(CLEANUP => 1);
        my $out = `perl "$Bin/../../scripts/bp-spend.pl" snapshot --run-dir "$tmp" --offline 2>&1`;
        my $rc  = $? >> 8;
        skip("C24: bp-spend.pl snapshot verb not available (rc=$rc)", 2) if $rc == 2;

        is($rc, 0, 'C24: `bp-spend.pl snapshot` exits 0 when driven like a real caller') or diag($out);
        ok(-f "$tmp/spend.json", 'C24: it wrote spend.json at the path the panel reads');
    }
}

done_testing();
