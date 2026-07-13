#!/usr/bin/env perl
# 16-oauth-sandbox-preflight.t — oracle tests for the oauth_usable($d,$now_ms)
# pure predicate and the oauth.sandbox_login manifest entry.
#
# P1 refuse — missing creds structure
# P2 refuse — expired, no refreshToken
# P3 pass   — renewable (refreshToken present, even if expired)
# P4 pass   — unexpired accessToken
# P5 actionable reason — predicate failure returns non-empty reason string
# P6 manifest integrity — oauth.sandbox_login entry present with required fields
#
# FAIL-FIRST NOTE: against current code (pre-impl) —
#   * bp-preflight.pl is NOT require-safe: its main loop runs and calls exit()
#     when the file is require'd. We detect this via a temp-file child process
#     (avoids Windows quoting hazards in perl -e "...path with spaces...").
#   * oauth_usable() does not exist yet — predicate tests are SKIPped with diag.
#   * The manifest lacks the oauth.sandbox_login entry — P6c fails.
# All failures are for the right reason: missing behavior, not broken scaffolding.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempfile);

plan tests => 15;

my $script   = "$Bin/../../scripts/bp-preflight.pl";
my $manifest = "$Bin/../../docs/assumptions.json";

ok(-f $script, 'bp-preflight.pl exists');

# ---- require-safety probe (child process via temp file) ----------------------
# We write the probe to a temp .pl file to avoid Windows path-quoting hazards
# that arise when embedding $script (which may contain spaces, backslashes, or
# non-ASCII chars) inside a perl -e "..." string on the command line.
# Pre-impl: main loop runs, exit() fires, child exits non-zero.
# Post-impl (unless(caller)+1;): child exits 0 and prints HAS_PREDICATE.
my ($tfh, $tname) = tempfile(SUFFIX => '.pl', UNLINK => 1);
print $tfh <<"END_PROBE";
use strict;
use warnings;
my \$rc = eval { require q($script); 1 };
if (!\$rc) {
    my \$err = \$\@ // 'unknown load error';
    print "LOAD_ERROR:\$err\n";
    exit 1;
}
print defined(&main::oauth_usable) ? "HAS_PREDICATE\n" : "NO_PREDICATE\n";
exit 0;
END_PROBE
close $tfh;

my $probe_out = `"$^X" "$tname" 2>&1`;
my $probe_rc  = $? >> 8;

my $is_require_safe = ($probe_rc == 0 && $probe_out =~ /HAS_PREDICATE/);
my $has_predicate   = $is_require_safe;

if ($is_require_safe) {
    pass('bp-preflight.pl is require-safe and defines oauth_usable');
} else {
    my $diag = $probe_out;
    $diag =~ s/\s+$//;
    fail('bp-preflight.pl is require-safe and defines oauth_usable');
    diag("child probe exit=$probe_rc output=[$diag]");
    diag("expected pre-impl: file not require-safe / oauth_usable not yet defined");
}

# ---- load script for predicate tests (only if require-safe) ------------------
if ($is_require_safe) {
    require $script;
}

# ---- P1: refuse — missing or empty creds ------------------------------------
SKIP: {
    skip 'oauth_usable not defined (pre-impl)', 2 unless $has_predicate;

    my ($ok1) = main::oauth_usable({});
    ok(!$ok1, 'P1a: oauth_usable({}) => not ok (claudeAiOauth absent)');

    my ($ok2) = main::oauth_usable({ claudeAiOauth => {} });
    ok(!$ok2, 'P1b: oauth_usable({claudeAiOauth=>{}}) => not ok (empty hash, no tokens)');
}

# ---- P2: refuse — expired, no refreshToken -----------------------------------
SKIP: {
    skip 'oauth_usable not defined (pre-impl)', 1 unless $has_predicate;

    my ($ok) = main::oauth_usable(
        { claudeAiOauth => { accessToken => 'x', expiresAt => 1000 } },
        2000
    );
    ok(!$ok, 'P2: expired accessToken + no refreshToken => not ok');
}

# ---- P3: pass — renewable (refreshToken present, even though expired) --------
SKIP: {
    skip 'oauth_usable not defined (pre-impl)', 1 unless $has_predicate;

    my ($ok) = main::oauth_usable(
        { claudeAiOauth => { refreshToken => 'r', accessToken => 'x', expiresAt => 1000 } },
        2000
    );
    ok($ok, 'P3: refreshToken present => ok regardless of expiry');
}

# ---- P4: pass — unexpired accessToken ----------------------------------------
SKIP: {
    skip 'oauth_usable not defined (pre-impl)', 1 unless $has_predicate;

    my ($ok) = main::oauth_usable(
        { claudeAiOauth => { accessToken => 'x', expiresAt => 9999 } },
        2000
    );
    ok($ok, 'P4: accessToken present and unexpired (expiresAt 9999 > now_ms 2000) => ok');
}

# ---- P5: actionable failure reason is non-empty ------------------------------
# The spec requires that the %CHECK sub wraps the predicate $reason into the
# actionable message "... run `claude-sandbox` and `/login` first ..." — that
# wording is produced by the %CHECK impl, not by oauth_usable itself.
# We assert that oauth_usable returns a non-empty $reason on failure (the raw
# material the %CHECK sub wraps). The full actionable message text is only
# testable once %CHECK{oauth.sandbox_login} exists (post-impl).
SKIP: {
    skip 'oauth_usable not defined (pre-impl)', 2 unless $has_predicate;

    my ($ok, $reason) = main::oauth_usable({});
    ok(!$ok,                  'P5a: predicate fails on missing creds (setup for reason check)');
    ok(length($reason // '') > 0, 'P5b: predicate failure reason is non-empty (feeds actionable %CHECK message)');
}

# ---- P6: manifest integrity — oauth.sandbox_login entry ----------------------
# P6a/P6b: the file must parse as valid JSON (always true — existing entries).
# P6c: the oauth.sandbox_login entry must exist (FAILS pre-impl, Change B adds it).
# P6d-P6f: entry fields — only checked when entry exists.
ok(-f $manifest, 'P6a: assumptions.json exists');

my $m = do {
    open my $fh, '<:raw', $manifest or die "cannot open $manifest: $!";
    local $/;
    eval { JSON::PP->new->decode(<$fh>) };
};
ok(ref $m eq 'HASH', 'P6b: assumptions.json is valid JSON');

my ($oauth_entry) = grep { ref $_ eq 'HASH' && ($_->{id} // '') eq 'oauth.sandbox_login' }
                        @{ $m->{assumptions} // [] };

ok(defined $oauth_entry, "P6c: assumption 'oauth.sandbox_login' exists in manifest")
    or diag("entry with id='oauth.sandbox_login' absent — expected (pre-impl); added by Change B");

SKIP: {
    skip "oauth.sandbox_login entry absent (pre-impl)", 3 unless defined $oauth_entry;

    my $envs = $oauth_entry->{supported_envs} // [];
    ok((grep { $_ eq 'sandbox-linux' } @$envs),
       "P6d: oauth.sandbox_login supported_envs contains 'sandbox-linux'");

    ok(length($oauth_entry->{what}          // '') > 0, 'P6e: what field is non-empty');
    ok(length($oauth_entry->{implement_hint} // '') > 0, 'P6f: implement_hint field is non-empty');
}
