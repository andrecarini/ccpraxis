#!/usr/bin/env perl
# s08-token-panel: access + refresh token status (TokenInfo.pm + launcher
# _gather_tokens wiring + Dashboard.pm Token panel).
#
# This file is the IMMUTABLE ORACLE for blueprint sandbox-butler-overhaul,
# package s08-token-panel (specs/s08-token-panel-spec.md). It is written
# BLIND to any TokenInfo.pm / _gather_tokens / _token_lines implementation --
# directly from the spec -- so it can serve as an oracle rather than an echo
# of whatever the implementer eventually writes.
#
# Coverage: AC-1..AC-21 (spec S4). AC-22 (whole-suite-green gate) is
# deliberately NOT encoded here -- it's a coordinator-side check.
#
# TokenInfo.pm DOES NOT EXIST YET -- every TokenInfo::status / ::fingerprint
# call below is wrapped (directly or via a helper) so a missing module/sub
# degrades to a clean per-assertion FAIL rather than aborting the whole file;
# that is EXPECTED and correct until the implementer lands s08. Likewise
# Dashboard::_token_lines and the Token-panel branch of _fixed_panels don't
# exist/fire yet.
#
# Hard constraint (spec S7, same module contract as t/41): this file MUST
# NOT `use utf8`.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use Digest::MD5 ();
use File::Temp qw(tempdir);

# ===========================================================================
# Pinned "now" -- no real-clock dependence anywhere in this file (S7).
# ===========================================================================
my $NOW = 1700003600;

# ===========================================================================
# Scaffolding
# ===========================================================================

# slurp($path) -> file contents, or '' if unreadable.
sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# extract_block($src, $start_literal) -> the brace-balanced block starting at
# the first '{' at-or-after $start_literal's first occurrence, or undef if
# $start_literal isn't found. Used for source-text-only launcher.pl checks
# (AC-13/AC-14) -- launcher.pl is never `require`d (side effects; t/36's
# stated convention).
sub extract_block {
    my ($src, $start_literal) = @_;
    my $idx = index($src, $start_literal);
    return undef if $idx < 0;
    my $brace_idx = index($src, '{', $idx);
    return undef if $brace_idx < 0;
    my $depth = 0;
    my $i     = $brace_idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if ($c eq '{') { $depth++; }
        elsif ($c eq '}') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $brace_idx, $i - $brace_idx + 1);
}

# creds(%opts) -> the OUTER decoded credentials document (S2.1: $creds is the
# hashref whose claudeAiOauth key holds the token record). Only keys actually
# supplied end up in the inner claudeAiOauth hash (so "missing" vs "undef" vs
# "empty string" are distinguishable per-case, per AC-4/AC-5).
sub creds {
    my (%o) = @_;
    my %oauth;
    $oauth{accessToken}      = $o{access}           if exists $o{access};
    $oauth{refreshToken}     = $o{refresh}          if exists $o{refresh};
    $oauth{expiresAt}        = $o{expiresAt}        if exists $o{expiresAt};
    $oauth{scopes}           = $o{scopes}           if exists $o{scopes};
    $oauth{subscriptionType} = $o{subscriptionType} if exists $o{subscriptionType};
    $oauth{rateLimitTier}    = $o{rateLimitTier}    if exists $o{rateLimitTier};
    return { claudeAiOauth => \%oauth };
}

# _status(...) -> TokenInfo::status(...) result, or undef if the module/sub
# is missing or dies (never propagates the die -- keeps this file executing
# to completion so every AC gets its own clean pass/fail line).
sub _status {
    my @args = @_;
    my $r = eval { TokenInfo::status(@args) };
    return $r;
}

# _fp(...) -> TokenInfo::fingerprint(...) result, or undef on missing/die.
sub _fp {
    my @args = @_;
    my $r = eval { TokenInfo::fingerprint(@args) };
    return $r;
}

sub is_hashref { my ($h) = @_; return ref($h) eq 'HASH'; }

# field($h, $k) -> $h->{$k} if $h is a hashref, else undef (never
# autovivifies / dereferences undef under `strict refs`).
sub field {
    my ($h, $k) = @_;
    return is_hashref($h) ? $h->{$k} : undef;
}

# token_lines_of($tokens) -> Dashboard::_token_lines($tokens) result as a
# list, or () on missing/die.
sub token_lines_of {
    my ($tokens) = @_;
    my @lines = eval { Dashboard::_token_lines($tokens) };
    return @lines;
}

# _deep_values($v, $acc) -> flat arrayref of every non-ref scalar reachable
# inside $v (recursing HASH/ARRAY). Used for the AC-12 INV-T leak sweep.
sub _deep_values {
    my ($v, $acc) = @_;
    $acc ||= [];
    if (ref $v eq 'HASH')       { _deep_values($_, $acc) for values %$v; }
    elsif (ref $v eq 'ARRAY')   { _deep_values($_, $acc) for @$v; }
    else                        { push @$acc, $v; }
    return $acc;
}

my $LAUNCHER_PATH   = "$Bin/../../scripts/launcher.pl";
my $DASHBOARD_PATH  = "$Bin/../../scripts/Dashboard.pm";
my $SCHEMA_DOC_PATH = "$Bin/../../docs/token-schema-inventory.md";

# ===========================================================================
# AC-1 -> DC-1: schema-inventory doc.
# ===========================================================================
{
    ok(-f $SCHEMA_DOC_PATH, 'AC-1: plugins/sandbox/docs/token-schema-inventory.md exists')
        or diag("expected at $SCHEMA_DOC_PATH");
    my $doc = slurp($SCHEMA_DOC_PATH);
    for my $field (qw(accessToken refreshToken expiresAt scopes subscriptionType rateLimitTier)) {
        like($doc, qr/\Q$field\E/, "AC-1: schema doc mentions $field");
    }
    like($doc, qr/no\s+refresh[-\s]token[-\s]expiry/i,
        'AC-1: schema doc states that no refresh-token-expiry field exists');
}

# ===========================================================================
# Module loading. TokenInfo.pm does NOT exist yet -- use_ok is expected to
# fail here; every call site below degrades cleanly instead of dying.
# Dashboard.pm DOES already exist (s06 landed) -- BAIL_OUT if that's broken,
# since nothing else in this file can run without it.
# ===========================================================================
use_ok('TokenInfo');
use_ok('Dashboard') or BAIL_OUT('Dashboard.pm did not load');

# tui::DashboardScreen is a READ-ONLY dependency here (blueprint
# unified-tui-design-system package 06-dashboard-screen): LABEL_GUTTER() is
# this file's derivation source for the re-pointed oauth-row label
# assertions below (spec 06-dashboard-screen-spec.md S2.4.1), so every
# expected label string is DERIVED, never hand-padded.
my $DASHBOARD_SCREEN_OK43 = eval { require tui::DashboardScreen; 1 };
BAIL_OUT("tui::DashboardScreen.pm did not load ($@) -- LABEL_GUTTER() is this file's derivation source for the re-pointed oauth-row assertions; nothing below can mean anything without it")
    unless $DASHBOARD_SCREEN_OK43;

# ===========================================================================
# TokenInfo::status -- pure, total. AC-2..AC-12.
# ===========================================================================

# --- AC-2 -> DC-2 (B1): access present + valid. ---------------------------
{
    my $c = creds(access => 'ACCESS-AC2', refresh => 'REFRESH-AC2', expiresAt => ($NOW + 11520) * 1000);
    my $info = _status($c, 1700000000, $NOW);
    ok(is_hashref($info), 'AC-2: status() returns a hashref (B1 valid-access fixture)');
    is(field($info, 'access_present'),      1,             'AC-2: access_present=1 (B1)');
    is(field($info, 'access_state'),        'valid',       'AC-2: access_state=valid (B1)');
    is(field($info, 'access_expires_at'),   $NOW + 11520,  'AC-2: access_expires_at == int(expiresAt/1000) (B1)');
    is(field($info, 'access_seconds_left'), 11520,         'AC-2: access_seconds_left == access_expires_at - now (B1)');
}

# --- AC-3 -> DC-2 (B2): access present + expired, exact signed value. -----
{
    my $c1 = creds(access => 'A', refresh => 'R', expiresAt => ($NOW - 60) * 1000);
    my $i1 = _status($c1, 1700000000, $NOW);
    is(field($i1, 'access_state'),        'expired', 'AC-3: expiresAt 60s in the past -> access_state=expired (B2)');
    is(field($i1, 'access_seconds_left'), -60,       'AC-3: access_seconds_left == -60 exactly, signed (B2)');

    my $c2 = creds(access => 'A', refresh => 'R', expiresAt => $NOW * 1000);
    my $i2 = _status($c2, 1700000000, $NOW);
    is(field($i2, 'access_state'),        'expired', 'AC-3: expiresAt == now -> access_state=expired (B2)');
    is(field($i2, 'access_seconds_left'), 0,         'AC-3: access_seconds_left == 0 exactly (B2)');
}

# --- AC-4 -> DC-2 (B3): access absent (missing/empty), regardless of expiresAt. ---
{
    my @cases = (
        [ 'missing accessToken key', creds(refresh => 'R', expiresAt => ($NOW + 9999) * 1000) ],
        [ 'empty-string accessToken', creds(access => '', refresh => 'R', expiresAt => ($NOW + 9999) * 1000) ],
    );
    for my $case (@cases) {
        my ($label, $c) = @$case;
        my $info = _status($c, 1700000000, $NOW);
        is(field($info, 'access_present'),      0,         "AC-4: access_present=0 ($label) (B3)");
        is(field($info, 'access_state'),        'absent',  "AC-4: access_state=absent ($label) (B3)");
        is(field($info, 'access_expires_at'),   undef,     "AC-4: access_expires_at undef ($label), even with a valid future expiresAt (B3)");
        is(field($info, 'access_seconds_left'), undef,     "AC-4: access_seconds_left undef ($label) (B3)");
    }
}

# --- AC-5 -> DC-2 (B4): access present, expiresAt unverifiable. -----------
{
    my @cases = (
        [ 'expiresAt missing',  creds(access => 'A', refresh => 'R') ],
        [ 'expiresAt undef',    creds(access => 'A', refresh => 'R', expiresAt => undef) ],
        [ "expiresAt 'soon'",   creds(access => 'A', refresh => 'R', expiresAt => 'soon') ],
        [ 'expiresAt -5',       creds(access => 'A', refresh => 'R', expiresAt => -5) ],
    );
    for my $case (@cases) {
        my ($label, $c) = @$case;
        my $info = _status($c, 1700000000, $NOW);
        is(field($info, 'access_present'),      1,        "AC-5: access_present=1 ($label) (B4)");
        is(field($info, 'access_state'),        'absent', "AC-5: access_state=absent ($label) (B4)");
        is(field($info, 'access_expires_at'),   undef,    "AC-5: access_expires_at undef ($label) (B4)");
        is(field($info, 'access_seconds_left'), undef,    "AC-5: access_seconds_left undef ($label) (B4)");
    }
}

# --- AC-6 -> DC-2 (B5/B6): refresh presence + fingerprint format/value. ---
{
    my $tok  = 'REFRESH-TOKEN-AC6-VALUE';
    my $c    = creds(access => 'A', refresh => $tok, expiresAt => ($NOW + 100) * 1000);
    my $info = _status($c, 1700000000, $NOW);
    is(field($info, 'refresh_present'), 1, 'AC-6: refresh_present=1 when refreshToken is present (B5)');
    my $fp = field($info, 'refresh_fingerprint');
    like(defined($fp) ? $fp : '(undef)', qr/^[0-9a-f]{8}$/, 'AC-6: refresh_fingerprint is 8 lowercase hex chars (B5)');
    is($fp, substr(Digest::MD5::md5_hex($tok), 0, 8),
        'AC-6: refresh_fingerprint equals substr(md5_hex($tok),0,8), computed independently in this test (B5)');

    my @absent_cases = (
        [ 'missing refreshToken',     creds(access => 'A', expiresAt => ($NOW + 100) * 1000) ],
        [ 'empty-string refreshToken', creds(access => 'A', refresh => '', expiresAt => ($NOW + 100) * 1000) ],
    );
    for my $case (@absent_cases) {
        my ($label, $c2) = @$case;
        my $info2 = _status($c2, 1700000000, $NOW);
        is(field($info2, 'refresh_present'),     0,     "AC-6: refresh_present=0 ($label) (B6)");
        is(field($info2, 'refresh_fingerprint'), undef, "AC-6: refresh_fingerprint undef ($label) (B6)");
    }
}

# --- AC-7 -> DC-2 (B7): fingerprint stability + TokenInfo::fingerprint. ---
{
    my $tokA = 'REFRESH-TOKEN-AC7-A';
    my $tokB = 'REFRESH-TOKEN-AC7-B';

    my $c1 = creds(access => 'A', refresh => $tokA, expiresAt => ($NOW + 100) * 1000);
    my $c2 = creds(access => 'A', refresh => $tokA, expiresAt => ($NOW + 999) * 1000);
    my $i1 = _status($c1, 1700000000, $NOW);
    my $i2 = _status($c2, 1650000000, $NOW + 12345);
    is(field($i1, 'refresh_fingerprint'), field($i2, 'refresh_fingerprint'),
        'AC-7: same refreshToken, different $mtime/$now -> identical fingerprint (B7)');

    my $c3 = creds(access => 'A', refresh => $tokB, expiresAt => ($NOW + 100) * 1000);
    my $i3 = _status($c3, 1700000000, $NOW);
    isnt(field($i1, 'refresh_fingerprint'), field($i3, 'refresh_fingerprint'),
        'AC-7: a different refreshToken -> a different fingerprint (B7)');

    my $fp1 = _fp($tokA);
    my $fp2 = _fp($tokA);
    is($fp1, $fp2, 'AC-7: TokenInfo::fingerprint($tok) is stable across repeated calls');
    is($fp1, field($i1, 'refresh_fingerprint'),
        "AC-7: TokenInfo::fingerprint(\$tok) agrees with status()'s refresh_fingerprint for the same token");
    is(_fp(undef), undef, 'AC-7: TokenInfo::fingerprint(undef) -> undef');
    is(_fp(''),    undef, 'AC-7: TokenInfo::fingerprint("") -> undef');
}

# --- AC-8 -> DC-2 (B8): last-refreshed comes from $mtime, never the clock. ---
{
    my $c  = creds(access => 'A', refresh => 'R', expiresAt => ($NOW + 100) * 1000);
    my $i1 = _status($c, 1700000000, 1700003600);
    is(field($i1, 'last_refreshed_at'),  1700000000, 'AC-8: last_refreshed_at == the passed $mtime exactly (B8)');
    is(field($i1, 'last_refreshed_age'), 3600,       'AC-8: last_refreshed_age == $now - $mtime (B8)');

    my $i2 = _status($c, $NOW + 500, $NOW);
    is(field($i2, 'last_refreshed_age'), 0,
        'AC-8: future $mtime (clock skew, $mtime=$now+500) -> last_refreshed_age clamped to 0, never negative (B8)');

    for my $bad_mtime (undef, 'x') {
        my $i3 = _status($c, $bad_mtime, $NOW);
        my $lbl = defined $bad_mtime ? "'$bad_mtime'" : 'undef';
        is(field($i3, 'last_refreshed_at'),  undef, "AC-8: \$mtime=$lbl -> last_refreshed_at undef (B8)");
        is(field($i3, 'last_refreshed_age'), undef, "AC-8: \$mtime=$lbl -> last_refreshed_age undef (B8)");
    }
}

# --- AC-9 -> DC-2 (B10): refresh_expires sentinel, always. ----------------
{
    my $c  = creds(access => 'A', refresh => 'R', expiresAt => ($NOW + 100) * 1000);
    my $i1 = _status($c, 1700000000, $NOW);
    is(field($i1, 'refresh_expires'), 'n/a (not stored)',
        'AC-9: refresh_expires is the exact literal in the logged-in fixture (B10)');

    my $i2 = _status(undef, undef, $NOW);
    is(field($i2, 'refresh_expires'), 'n/a (not stored)',
        'AC-9: refresh_expires is the exact literal in the undef-input (not-logged-in) struct (B10)');
}

# --- AC-10 -> DC-2 (B9): optional subscription_type / rate_limit_tier. ---
{
    my $c1 = creds(access => 'A', refresh => 'R', expiresAt => ($NOW + 100) * 1000,
                    subscriptionType => 'max', rateLimitTier => 'default_max');
    my $i1 = _status($c1, 1700000000, $NOW);
    is(field($i1, 'subscription_type'), 'max',         'AC-10: subscription_type copied verbatim when present (B9)');
    is(field($i1, 'rate_limit_tier'),   'default_max', 'AC-10: rate_limit_tier copied verbatim when present (B9)');

    my $c2 = creds(access => 'A', refresh => 'R', expiresAt => ($NOW + 100) * 1000);
    my $i2 = _status($c2, 1700000000, $NOW);
    ok(is_hashref($i2), 'AC-10: status() returns a hashref for the missing-optional-fields fixture');
    if (is_hashref($i2)) {
        ok(!exists $i2->{subscription_type},
            'AC-10: subscription_type key does not `exist` when absent from input (B9, bp-token-keeper.pl shape)');
        ok(!exists $i2->{rate_limit_tier},
            'AC-10: rate_limit_tier key does not `exist` when absent from input (B9)');
    } else {
        fail('AC-10: subscription_type key absent (status() did not return a hashref)');
        fail('AC-10: rate_limit_tier key absent (status() did not return a hashref)');
    }

    my $c3 = creds(access => 'A', refresh => 'R', expiresAt => ($NOW + 100) * 1000,
                    subscriptionType => 'max', rateLimitTier => '');
    my $i3 = _status($c3, 1700000000, $NOW);
    ok(is_hashref($i3), 'AC-10: status() returns a hashref for the one-present-one-empty fixture');
    if (is_hashref($i3)) {
        is($i3->{subscription_type}, 'max', 'AC-10: the non-empty optional field (subscription_type) exists with its value');
        ok(!exists $i3->{rate_limit_tier}, 'AC-10: the empty-string optional field (rate_limit_tier) does not `exist` (B9)');
    } else {
        fail('AC-10: non-empty optional field present (status() did not return a hashref)');
        fail('AC-10: empty-string optional field absent (status() did not return a hashref)');
    }
}

# --- AC-11 -> DC-2 (B11): degradation, never death. -----------------------
{
    my %canonical = (
        logged_in => 0, access_present => 0, access_state => 'absent',
        access_expires_at => undef, access_seconds_left => undef,
        refresh_present => 0, refresh_fingerprint => undef,
        refresh_expires => 'n/a (not stored)',
    );
    my @bad_creds = (
        [ 'undef',                     undef ],
        [ '{}',                        {} ],
        [ '[]',                        [] ],
        [ "'string'",                  'a plain string' ],
        [ '{claudeAiOauth=>undef}',    { claudeAiOauth => undef } ],
        [ "{claudeAiOauth=>'x'}",      { claudeAiOauth => 'x' } ],
        [ '{claudeAiOauth=>[]}',       { claudeAiOauth => [] } ],
        [ "{accessToken=>'flat'}",     { accessToken => 'flat' } ],
    );
    for my $case (@bad_creds) {
        my ($label, $c) = @$case;
        my $info = eval { TokenInfo::status($c, 1700000000, $NOW) };
        is($@, '', "AC-11: status($label, mtime, now) does not die (B11)");
        ok(is_hashref($info), "AC-11: status($label, mtime, now) returns a hashref (B11)");
        if (is_hashref($info)) {
            for my $k (sort keys %canonical) {
                is($info->{$k}, $canonical{$k}, "AC-11: status($label) -- $k matches the canonical not-logged-in struct (B11)");
            }
        } else {
            fail("AC-11: status($label) matches the canonical not-logged-in struct (did not return a hashref)");
        }
    }

    # A VALID fixture with $now undef -> the B11 $now-degraded struct, no death.
    my $good  = creds(access => 'A', refresh => 'R', expiresAt => ($NOW + 100) * 1000, subscriptionType => 'max');
    my $infod = eval { TokenInfo::status($good, 1700000000, undef) };
    is($@, '', 'AC-11: status(valid-creds, mtime, $now=undef) does not die (B11 $now-degraded)');
    if (is_hashref($infod)) {
        is($infod->{access_seconds_left}, undef,       'AC-11: $now undef -> access_seconds_left undef (B11)');
        is($infod->{last_refreshed_age},  undef,       'AC-11: $now undef -> last_refreshed_age undef (B11)');
        is($infod->{access_state},        'absent',    'AC-11: $now undef -> access_state=absent (B11)');
        is($infod->{access_present},      1,           'AC-11: $now undef -> access_present keeps its normal value (B11)');
        is($infod->{refresh_present},     1,           'AC-11: $now undef -> refresh_present keeps its normal value (B11)');
        ok(defined $infod->{refresh_fingerprint}, 'AC-11: $now undef -> refresh_fingerprint keeps its normal (defined) value (B11)');
        is($infod->{access_expires_at},   $NOW + 100,  'AC-11: $now undef -> access_expires_at keeps its normal value (B11)');
        is($infod->{last_refreshed_at},   1700000000,  'AC-11: $now undef -> last_refreshed_at keeps its normal value (B11)');
        is($infod->{subscription_type},   'max',       'AC-11: $now undef -> optional keys keep their normal values (B11)');
    } else {
        fail('AC-11: $now=undef degraded-struct field checks (status() did not return a hashref)');
    }
}

# --- AC-12 -> DC-2 (B12, INV-T): no token material, closed key set. -------
{
    my $ACCESS_SENTINEL  = 'sk-ant-oat01-FAKEACCESS-DO-NOT-LEAK';
    my $REFRESH_SENTINEL = 'sk-ant-ort01-FAKEREFRESH-DO-NOT-LEAK';

    my $c    = creds(access => $ACCESS_SENTINEL, refresh => $REFRESH_SENTINEL,
                      expiresAt => ($NOW + 3600) * 1000,
                      subscriptionType => 'max', rateLimitTier => 'default_max');
    my $info = _status($c, $NOW - 500, $NOW);
    ok(is_hashref($info), 'AC-12: status() returns a hashref for the sentinel fixture');

    my $vals = is_hashref($info) ? _deep_values($info) : [];
    my $leak_full = grep {
        defined $_ && !ref($_) && (index($_, $ACCESS_SENTINEL) >= 0 || index($_, $REFRESH_SENTINEL) >= 0)
    } @$vals;
    is($leak_full, 0, 'AC-12/INV-T: no value in the returned struct contains either sentinel as a substring (B12)');

    my %bad_substr;
    for my $sentinel ($ACCESS_SENTINEL, $REFRESH_SENTINEL) {
        for (my $i = 0; $i + 8 <= length($sentinel); $i++) {
            $bad_substr{ substr($sentinel, $i, 8) } = 1;
        }
    }
    my $leak_sub = grep { defined $_ && !ref($_) && $bad_substr{$_} } @$vals;
    is($leak_sub, 0,
        'AC-12/INV-T: no value in the returned struct equals any >=8-char substring of either sentinel (B12)');

    my @expected_keys = qw(
        logged_in access_present access_state access_expires_at access_seconds_left
        refresh_present refresh_fingerprint refresh_expires
        last_refreshed_at last_refreshed_age
        subscription_type rate_limit_tier
    );
    if (is_hashref($info)) {
        is_deeply([ sort keys %$info ], [ sort @expected_keys ],
            'AC-12: returned key set is exactly the 10 mandatory keys plus both optional keys (both were supplied)');
    } else {
        fail('AC-12: returned key set check (status() did not return a hashref)');
    }

    # Same sweep, but with NO optional fields supplied -> exactly 10 keys.
    my $c10 = creds(access => $ACCESS_SENTINEL, refresh => $REFRESH_SENTINEL, expiresAt => ($NOW + 3600) * 1000);
    my $i10 = _status($c10, $NOW - 500, $NOW);
    if (is_hashref($i10)) {
        my @expected10 = qw(
            logged_in access_present access_state access_expires_at access_seconds_left
            refresh_present refresh_fingerprint refresh_expires
            last_refreshed_at last_refreshed_age
        );
        is_deeply([ sort keys %$i10 ], [ sort @expected10 ],
            'AC-12: with no optional fields supplied, the returned key set is exactly the 10 mandatory keys, nothing extra');
    } else {
        fail('AC-12: 10-key-only key set check (status() did not return a hashref)');
    }
}

# ===========================================================================
# Launcher wiring: source-text + `perl -c` only (launcher.pl is NEVER
# `require`d -- side effects, per t/36's stated convention). AC-13..AC-17.
# ===========================================================================
my $launcher_src = slurp($LAUNCHER_PATH);
ok(length($launcher_src) > 0, 'launcher.pl is readable on disk') or BAIL_OUT("cannot read $LAUNCHER_PATH");

# --- AC-13 -> DC-3: use TokenInfo + sub _gather_tokens + its body. --------
{
    like($launcher_src, qr/\buse\s+TokenInfo\b/, 'AC-13: launcher.pl source contains "use TokenInfo"');
    like($launcher_src, qr/\bsub\s+_gather_tokens\b/, 'AC-13: launcher.pl defines sub _gather_tokens');

    my $body = extract_block($launcher_src, 'sub _gather_tokens');
    if (defined $body) {
        like($body, qr/\$SANDBOX_CREDENTIALS_FILE\b/, 'AC-13: _gather_tokens body references $SANDBOX_CREDENTIALS_FILE');
        like($body, qr/\bstat\s*\(/, 'AC-13: _gather_tokens body calls stat(...)');
        like($body, qr/TokenInfo::status\s*\([^)]*\btime\b/,
            'AC-13: _gather_tokens body calls TokenInfo::status(...) with time');
    } else {
        fail('AC-13: _gather_tokens body references $SANDBOX_CREDENTIALS_FILE (sub not found -- cannot extract body)');
        fail('AC-13: _gather_tokens body calls stat(...) (sub not found -- cannot extract body)');
        fail('AC-13: _gather_tokens body calls TokenInfo::status(...) with time (sub not found -- cannot extract body)');
    }
}

# --- AC-14 -> DC-3 (B14): _gather_tokens() inside the ~10s cache guard, --
# --- and called nowhere else in the gather closure. -----------------------
{
    my $gather_block = extract_block($launcher_src, 'gather    => sub {');
    ok(defined $gather_block, 'AC-14: the gather => sub {...} closure is extractable from launcher.pl')
        or diag('cannot locate the "gather    => sub {" literal -- has formatting changed?');
    if (defined $gather_block) {
        my ($guard_slice) = $gather_block =~ /if\s*\(\s*\$now\s*-\s*\$last_inspect\s*>=\s*(?:\d+|\$[A-Za-z_]\w*)\s*\)\s*\{(.*?)\$last_inspect\s*=\s*\$now\s*;/s;
        ok(defined $guard_slice, 'AC-14: located the ~10s cache guard slice inside the gather closure');
        if (defined $guard_slice) {
            like($guard_slice, qr/\$cached_tokens\s*=\s*_gather_tokens\s*\(\s*\)/,
                'AC-14: $cached_tokens = _gather_tokens() is inside the ~10s cache guard');
        } else {
            fail('AC-14: $cached_tokens = _gather_tokens() is inside the ~10s cache guard (guard slice not found)');
        }
        my $n_calls = () = $gather_block =~ /_gather_tokens\s*\(/g;
        is($n_calls, 1, 'AC-14: _gather_tokens() is called exactly once in the whole gather closure (only inside the cache guard)');
    } else {
        fail('AC-14: $cached_tokens = _gather_tokens() is inside the ~10s cache guard (gather closure not found)');
        fail('AC-14: _gather_tokens() called exactly once in the gather closure (gather closure not found)');
    }
}

# --- AC-15 -> DC-3: tokens => $cached_tokens in the return hash; declared --
# --- alongside the other cache vars. --------------------------------------
{
    like($launcher_src, qr/tokens\s*=>\s*\$cached_tokens/, 'AC-15: gather return hash contains tokens => $cached_tokens');
    like($launcher_src, qr/my\s+\$cached_tokens\s*=\s*undef/, 'AC-15: $cached_tokens is declared (mirroring the other cache vars)');

    my ($decl_region) = $launcher_src =~ /(my\s+\$cached_status\b.*?my\s+\$last_inspect\b)/s;
    if (defined $decl_region) {
        like($decl_region, qr/\$cached_tokens/,
            'AC-15: $cached_tokens is declared in the same region as the other cache vars (before $last_inspect)');
    } else {
        fail('AC-15: $cached_tokens declared alongside the other cache vars (declaration region not found)');
    }
}

# --- AC-16 -> DC-3 (B15, non-regression, I2). ------------------------------
{
    # Launcher-side: source-text only (launcher.pl can't be require'd).
    like($launcher_src, qr/\bsub\s+_gather_oauth_expiry\b/, 'AC-16: launcher.pl still defines sub _gather_oauth_expiry');
    like($launcher_src, qr/_gather_oauth_expiry\(\)/, 'AC-16: launcher.pl still calls _gather_oauth_expiry() at its call site');
    like($launcher_src, qr/oauth_expires_at\s*=>/, 'AC-16: launcher.pl gather-return hash still contains oauth_expires_at =>');

    # Dashboard-side: source-text floor plus a stronger BEHAVIORAL check
    # (Dashboard.pm is loadable, so prefer exercising it over grepping it).
    my $dash_src = slurp($DASHBOARD_PATH);
    like($dash_src, qr/\$state\{oauth_remaining\}\s*=/, 'AC-16: Dashboard.pm source still derives $state{oauth_remaining}');
    # RE-POINTED (package 06-dashboard-screen, spec S2.4.1, driver report
    # item 3): the hand-padded label literal 'oauth     : ' is GONE, in
    # favour of the ONE shared gutter (tui::DashboardScreen::LABEL_GUTTER()
    # == 11) -- every row's label is now built by calling a gutter helper
    # with the bare label name, never spelled out as a pre-padded string.
    # Scanning for a hard-coded padding width would just re-pin the stale
    # mechanism this package deliberately deleted. What survives: the
    # source still builds an oauth row from the bare label 'oauth' --
    # scanned generically (not coupled to the helper's own variable name)
    # -- and the label TEXT that construct produces is re-derived through
    # LABEL_GUTTER() itself for the stronger behavioral check just below,
    # never hand-padded.
    like($dash_src, qr/\(\s*'oauth'\s*\)/,
        'AC-16: Dashboard.pm source still builds an oauth row from the bare label \'oauth\' (padding now comes from the shared LABEL_GUTTER(), not a hand-padded literal)');

    my %base = (
        project_name => 'demo', container => 'c1', status => 'running',
        beat_age => 5, uptime => 100, oauth_remaining => 11520,
        busy_age => 10, stay_awake => 1, needs_you => 0,
    );
    my @variants = (
        [ 'no tokens key',     {} ],
        [ 'tokens key present', { tokens => { logged_in => 0 } } ],
    );
    # RE-POINTED (package 06-dashboard-screen, spec S2.4.3, driver report
    # item 3). The Sandbox panel is deleted, so "Sandbox panel present" /
    # "Sandbox oauth row unaffected by tokens" have no surviving subject as
    # written. The real claim underneath was never "the oauth row always
    # renders identically regardless of tokens" -- per S2.4.3's own
    # conditional it is the OPPOSITE: the oauth fact lives in Run when
    # $state->{tokens} is absent, and in the Token panel's 'access' row
    # when it is a HASH -- EXACTLY ONCE, never both, never neither. Both
    # arms are asserted below (an untested arm is where this breaks).
    my $oauth_label43 = sprintf('%-*s : ', tui::DashboardScreen::LABEL_GUTTER(), 'oauth');
    for my $variant (@variants) {
        my ($label, $extra) = @$variant;
        my %s = (%base, %$extra);
        my @panels = Dashboard::_fixed_panels(\%s, 80);
        my ($run)   = grep { $_->{title} eq 'Run' } @panels;
        my ($token) = grep { $_->{title} eq 'Token' } @panels;
        my ($run_oauth_row) = $run ? (grep { $_->[0]{text} eq $oauth_label43 } @{ $run->{lines} }) : ();

        if (!exists $extra->{tokens}) {
            # arm 1: tokens absent -> oauth lives in Run (moved off the
            # deleted Sandbox panel), byte-identical to the old row.
            ok(!$token, "AC-16 (re-pointed): no Token panel when tokens is absent ($label)");
            ok($run_oauth_row, "AC-16 (re-pointed): an oauth row exists in Run when tokens is absent ($label)");
            is_deeply($run_oauth_row,
                [ { text => $oauth_label43, role => 'label' },
                  { text => Dashboard::fmt_oauth(11520), role => Dashboard::oauth_role(11520) } ],
                "AC-16 (re-pointed): the Run oauth row renders exactly as the deleted Sandbox oauth row did ($label)")
                if $run_oauth_row;
        } else {
            # arm 2: tokens present -> the SAME fact moves to Token's
            # 'access' row instead; Run must carry no oauth row at all.
            ok($token, "AC-16 (re-pointed): a Token panel exists when tokens is present ($label)");
            ok(!$run_oauth_row, "AC-16 (re-pointed): Run carries no oauth row when tokens is present ($label)");
        }
    }
}

# --- AC-17 -> DC-3/DC-4: `perl -c` from an unrelated CWD. -----------------
{
    my $isolated_cwd = tempdir(CLEANUP => 1);
    my $cmd = sprintf('cd %s && "%s" -c "%s" 2>&1', $isolated_cwd, $^X, $LAUNCHER_PATH);
    my $output = `$cmd`;
    is($? >> 8, 0,
        'AC-17: perl -c launcher.pl exits 0 from an unrelated CWD (TokenInfo resolves via the existing @INC bootstrap)')
        or diag("output: $output");
}

# ===========================================================================
# Token panel: Dashboard.pm, loaded directly. AC-18..AC-21.
# ===========================================================================

# --- AC-18 -> DC-3 (B16/B17): panel presence + ordering. -------------------
{
    my %base = (
        project_name => 'demo', container => 'c1', status => 'running',
        beat_age => 5, uptime => 100, oauth_remaining => 11520,
        busy_age => 10, stay_awake => 1, needs_you => 0,
    );

    my @p_no_tokens = Dashboard::build_panels(\%base, 80);
    my @titles_no_tokens = map { $_->{title} } @p_no_tokens;
    ok(!(grep { $_ eq 'Token' } @titles_no_tokens), 'AC-18: build_panels with no tokens key -> no Token panel (B16)');
    # RE-POINTED (spec S2.4.3): the Sandbox panel is deleted, so the panel
    # list without tokens is now ['Run', 'Recent activity'] -- Run leads.
    is_deeply(\@titles_no_tokens, [ 'Run', 'Recent activity' ],
        'AC-18: the panel list is otherwise unchanged for a state without tokens (B16) -- re-pointed: Sandbox is deleted, Run leads');

    my %with_tokens = (%base, tokens => {
        logged_in => 1, access_present => 1, access_state => 'valid',
        access_expires_at => $NOW + 100, access_seconds_left => 100,
        refresh_present => 1, refresh_fingerprint => 'aa11bb22',
        refresh_expires => 'n/a (not stored)',
        last_refreshed_at => $NOW - 10, last_refreshed_age => 10,
    });
    my @p_tokens = Dashboard::build_panels(\%with_tokens, 80);
    my @token_panels = grep { $_->{title} eq 'Token' } @p_tokens;
    is(scalar(@token_panels), 1, 'AC-18: build_panels with tokens a hashref -> exactly one Token panel (B17)');

    my @titles_tokens = map { $_->{title} } @p_tokens;
    my ($ti) = grep { $titles_tokens[$_] eq 'Token' } 0 .. $#titles_tokens;
    my ($ai) = grep { $titles_tokens[$_] eq 'Recent activity' } 0 .. $#titles_tokens;
    ok(defined($ti) && defined($ai) && $ti < $ai, 'AC-18: Token panel is positioned before Recent activity (B17)');

    my %with_bp_and_tokens = (%with_tokens, backpack => { total => 1, approved => 1,
        items => [ { key => 'apt:jq', approved => 1 } ] });
    my @p_both = Dashboard::build_panels(\%with_bp_and_tokens, 80);
    my @titles_both = map { $_->{title} } @p_both;
    # RE-POINTED (spec S2.4.3/S2.4.8, Decision 9, driver report item 3):
    # the Backpack panel is deleted -- backpack data now renders as a
    # summary ROW inside Run, never a titled panel of its own, so "ordered
    # after Backpack" has no surviving panel-title subject. What survives:
    # with backpack data present, no NEW panel appears and Token's
    # position relative to Run/Recent-activity is unaffected; the backpack
    # fact still reaches the frame (as a Run row -- the counter-fixture
    # proving this isn't vacuously true because backpack rendering
    # vanished entirely).
    ok(!(grep { $_ eq 'Backpack' } @titles_both),
        'AC-18 (re-pointed): no Backpack panel exists even with backpack data present (Decision 9)');
    my ($run_i)   = grep { $titles_both[$_] eq 'Run' } 0 .. $#titles_both;
    my ($token_i) = grep { $titles_both[$_] eq 'Token' } 0 .. $#titles_both;
    my ($act_i)   = grep { $titles_both[$_] eq 'Recent activity' } 0 .. $#titles_both;
    ok(defined($run_i) && defined($token_i) && defined($act_i) && $run_i < $token_i && $token_i < $act_i,
        'AC-18 (re-pointed): Token panel still sits between Run and Recent activity when backpack data is also present (position unaffected)');
    my ($run_both) = grep { $_->{title} eq 'Run' } @p_both;
    my $bp_label43 = sprintf('%-*s : ', tui::DashboardScreen::LABEL_GUTTER(), 'backpack');
    ok(($run_both && grep { $_->[0]{text} eq $bp_label43 } @{ $run_both->{lines} }),
        'AC-18 (re-pointed) counter-fixture: the backpack fact DOES reach the frame in this fixture -- as a row inside Run, not as the deleted panel');
}

# --- AC-19 -> DC-3 (B18/B19): the state -> line table, verbatim. ----------
{
    my $LBL_ACCESS      = 'access      : ';
    my $LBL_REFRESH     = 'refresh     : ';
    my $LBL_REFRESHED   = 'refreshed   : ';
    my $LBL_REFRESHEXP  = 'refresh-exp : ';
    my $LBL_ACCOUNT     = 'account     : ';
    my @ALLOWED_ROLES   = qw(label value muted strong good warn bad accent);

    my %fixA = ( # valid, 11520s left
        logged_in => 1, access_present => 1, access_state => 'valid',
        access_expires_at => $NOW + 11520, access_seconds_left => 11520,
        refresh_present => 1, refresh_fingerprint => 'abc12345',
        refresh_expires => 'n/a (not stored)',
        last_refreshed_at => $NOW - 3600, last_refreshed_age => 3600,
        subscription_type => 'max', rate_limit_tier => 'default_max',
    );
    my @linesA = token_lines_of(\%fixA);
    is(scalar(@linesA), 5, 'AC-19: valid-far fixture -> 5 body lines (account present) (B19)');
    is_deeply($linesA[0], [ { text => $LBL_ACCESS,     role => 'label' }, { text => 'expires in 3h12m',   role => 'good' } ], 'AC-19: valid-far -- access line');
    is_deeply($linesA[1], [ { text => $LBL_REFRESH,    role => 'label' }, { text => 'present (abc12345)', role => 'good' } ], 'AC-19: valid-far -- refresh line');
    is_deeply($linesA[2], [ { text => $LBL_REFRESHED,  role => 'label' }, { text => '1h00m ago',          role => 'value' } ], 'AC-19: valid-far -- refreshed line');
    is_deeply($linesA[3], [ { text => $LBL_REFRESHEXP, role => 'label' }, { text => 'n/a (not stored)',   role => 'muted' } ], 'AC-19: valid-far -- refresh-exp line');
    is_deeply($linesA[4], [ { text => $LBL_ACCOUNT,    role => 'label' }, { text => 'max / default_max',  role => 'value' } ], 'AC-19: valid-far -- account line (subscription_type / rate_limit_tier order)');

    my %fixB = ( # valid, <=900s left (warn tier)
        logged_in => 1, access_present => 1, access_state => 'valid',
        access_expires_at => $NOW + 300, access_seconds_left => 300,
        refresh_present => 1, refresh_fingerprint => 'def67890',
        refresh_expires => 'n/a (not stored)',
        last_refreshed_at => $NOW - 45, last_refreshed_age => 45,
    );
    my @linesB = token_lines_of(\%fixB);
    is(scalar(@linesB), 4, 'AC-19: valid-warn(<=900s) fixture -> 4 body lines (no account) (B19)');
    is_deeply($linesB[0], [ { text => $LBL_ACCESS,     role => 'label' }, { text => 'expires in 5m',      role => 'warn' } ], 'AC-19: valid-warn -- access line');
    is_deeply($linesB[1], [ { text => $LBL_REFRESH,    role => 'label' }, { text => 'present (def67890)', role => 'good' } ], 'AC-19: valid-warn -- refresh line');
    is_deeply($linesB[2], [ { text => $LBL_REFRESHED,  role => 'label' }, { text => '45s ago',            role => 'value' } ], 'AC-19: valid-warn -- refreshed line');
    is_deeply($linesB[3], [ { text => $LBL_REFRESHEXP, role => 'label' }, { text => 'n/a (not stored)',   role => 'muted' } ], 'AC-19: valid-warn -- refresh-exp line');

    my %fixC = ( # expired
        logged_in => 1, access_present => 1, access_state => 'expired',
        access_expires_at => $NOW - 60, access_seconds_left => -60,
        refresh_present => 1, refresh_fingerprint => 'aa11bb22',
        refresh_expires => 'n/a (not stored)',
        last_refreshed_at => $NOW - 10, last_refreshed_age => 10,
    );
    my @linesC = token_lines_of(\%fixC);
    is(scalar(@linesC), 4, 'AC-19: expired fixture -> 4 body lines (no account) (B19)');
    is_deeply($linesC[0], [ { text => $LBL_ACCESS,     role => 'label' }, { text => 'EXPIRED',            role => 'bad' } ], 'AC-19: expired -- access line');
    is_deeply($linesC[1], [ { text => $LBL_REFRESH,    role => 'label' }, { text => 'present (aa11bb22)', role => 'good' } ], 'AC-19: expired -- refresh line');
    is_deeply($linesC[2], [ { text => $LBL_REFRESHED,  role => 'label' }, { text => '10s ago',            role => 'value' } ], 'AC-19: expired -- refreshed line');
    is_deeply($linesC[3], [ { text => $LBL_REFRESHEXP, role => 'label' }, { text => 'n/a (not stored)',   role => 'muted' } ], 'AC-19: expired -- refresh-exp line');

    my %fixD = ( # not logged in
        logged_in => 0, access_present => 0, access_state => 'absent',
        access_expires_at => undef, access_seconds_left => undef,
        refresh_present => 0, refresh_fingerprint => undef,
        refresh_expires => 'n/a (not stored)',
        last_refreshed_at => undef, last_refreshed_age => undef,
    );
    my @linesD = token_lines_of(\%fixD);
    is(scalar(@linesD), 4, 'AC-19: not-logged-in fixture -> 4 body lines (no account) (B19)');
    is_deeply($linesD[0], [ { text => $LBL_ACCESS,     role => 'label' }, { text => 'not logged in (run /login)', role => 'bad' } ], 'AC-19: not-logged-in -- access line');
    is_deeply($linesD[1], [ { text => $LBL_REFRESH,    role => 'label' }, { text => 'absent',                    role => 'bad' } ], 'AC-19: not-logged-in -- refresh line');
    is_deeply($linesD[2], [ { text => $LBL_REFRESHED,  role => 'label' }, { text => 'n/a',                       role => 'muted' } ], 'AC-19: not-logged-in -- refreshed line');
    is_deeply($linesD[3], [ { text => $LBL_REFRESHEXP, role => 'label' }, { text => 'n/a (not stored)',          role => 'muted' } ], 'AC-19: not-logged-in -- refresh-exp line');

    # Structural shape (B19 second half + the closed role vocabulary).
    for my $pair ( [ 'valid-far', \@linesA ], [ 'valid-warn', \@linesB ], [ 'expired', \@linesC ], [ 'not-logged-in', \@linesD ] ) {
        my ($tag, $lines) = @$pair;
        for my $i (0 .. $#$lines) {
            my $line = $lines->[$i];
            is(ref($line), 'ARRAY', "AC-19: $tag line $i is an ARRAY ref of spans");
            next unless ref($line) eq 'ARRAY';
            for my $span (@$line) {
                is(ref($span), 'HASH', "AC-19: $tag line $i span is a HASH ref");
                next unless ref($span) eq 'HASH';
                is_deeply([ sort keys %$span ], [ 'role', 'text' ], "AC-19: $tag line $i span has exactly the keys text/role");
                my $role = $span->{role};
                ok((defined($role) && grep { $_ eq $role } @ALLOWED_ROLES),
                    "AC-19: $tag line $i span role (" . (defined $role ? $role : 'undef') . ') is in the closed vocabulary');
            }
        }
    }

    # S2.3/S5 edge cases (not separately numbered, but spec-mandated).
    my @linesEmpty = token_lines_of({});
    is(scalar(@linesEmpty), 4, 'S2.3/S5 edge: tokens=>{} -> 4 lines, all in the undef/absent branches');
    is_deeply($linesEmpty[3], [ { text => $LBL_REFRESHEXP, role => 'label' }, { text => 'n/a', role => 'muted' } ],
        'S2.3/S5 edge: tokens=>{} -- refresh-exp falls back to the literal "n/a" (missing refresh_expires key)');

    my @linesBad = token_lines_of('not-a-hashref');
    is_deeply(\@linesBad, [], 'S2.3 edge: _token_lines(non-hashref) -> empty list, never dies');
    my @linesUndef = token_lines_of(undef);
    is_deeply(\@linesUndef, [], 'S2.3 edge: _token_lines(undef) -> empty list, never dies');
}

# --- AC-20 -> DC-3 (B20): no token material rendered. ---------------------
{
    my $ACCESS_SENTINEL  = 'sk-ant-oat01-FAKEACCESS-DO-NOT-LEAK';
    my $REFRESH_SENTINEL = 'sk-ant-ort01-FAKEREFRESH-DO-NOT-LEAK';
    my $expected_fp = substr(Digest::MD5::md5_hex($REFRESH_SENTINEL), 0, 8);

    my $c    = creds(access => $ACCESS_SENTINEL, refresh => $REFRESH_SENTINEL, expiresAt => ($NOW + 3600) * 1000);
    my $info = _status($c, $NOW - 100, $NOW);

    my @lines = token_lines_of($info);
    my $panel_text = join(' ', map {
        ref($_) eq 'ARRAY' ? join('', map { defined($_->{text}) ? $_->{text} : '' } @$_) : ''
    } @lines);

    unlike($panel_text, qr/\Q$ACCESS_SENTINEL\E/,  'AC-20: Token panel span text does not contain the access-token sentinel (B20)');
    unlike($panel_text, qr/\Q$REFRESH_SENTINEL\E/, 'AC-20: Token panel span text does not contain the refresh-token sentinel (B20)');
    like($panel_text, qr/\Q$expected_fp\E/,        'AC-20: Token panel span text DOES contain the independently-computed fingerprint (B20)');

    my %state = (project_name => 'demo', container => 'c1', status => 'running', tokens => $info);
    my $frame = eval { Dashboard::compose_frame(\%state, 30, 80) };
    my $frame_text = (ref($frame) eq 'ARRAY')
        ? join(' ', map { defined($_->{text}) ? $_->{text} : '' } @$frame)
        : '';
    unlike($frame_text, qr/\Q$ACCESS_SENTINEL\E/,  'AC-20: compose_frame row text does not contain the access-token sentinel (B20)');
    unlike($frame_text, qr/\Q$REFRESH_SENTINEL\E/, 'AC-20: compose_frame row text does not contain the refresh-token sentinel (B20)');
}

# --- AC-21 -> DC-4 (B21): width-safe compose_frame with a tokens state. ---
{
    my %tokens_fixture = (
        logged_in => 1, access_present => 1, access_state => 'valid',
        access_expires_at => $NOW + 11520, access_seconds_left => 11520,
        refresh_present => 1, refresh_fingerprint => 'abc12345',
        refresh_expires => 'n/a (not stored)',
        last_refreshed_at => $NOW - 3600, last_refreshed_age => 3600,
        subscription_type => 'max', rate_limit_tier => 'default_max',
    );
    my %state = (
        project_name => 'demo', container => 'claude-demo-abcd1234', status => 'running',
        beat_age => 12, uptime => 3660, oauth_remaining => 11520,
        busy_age => 30, stay_awake => 1, needs_you => 0,
        tokens => \%tokens_fixture,
        events => [ 'e0', 'e1', 'e2' ],
    );
    for my $cols (40, 80, 100, 120) {
        my $frame = Dashboard::compose_frame(\%state, 30, $cols);
        is(ref($frame), 'ARRAY', "AC-21: compose_frame(state,30,$cols) returns an arrayref (B21)");
        next unless ref($frame) eq 'ARRAY';
        is(scalar(@$frame), 30, "AC-21: compose_frame(state,30,$cols) returns exactly 30 rows (B21)");
        my $bad_width = 0;
        my $bad_escape = 0;
        for my $cell (@$frame) {
            $bad_width++  if Dashboard::display_width($cell->{text}) != $cols;
            $bad_escape++ if $cell->{text} =~ /\e/;
        }
        is($bad_width,  0, "AC-21: every row's display_width == $cols (B21)");
        is($bad_escape, 0, "AC-21: no row text contains an ANSI escape (\\e) (B21)");
    }
}

done_testing();
