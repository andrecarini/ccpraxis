#!/usr/bin/env perl
# bp-spend.pl — normalized OpenCode Go + Zen spend reader, plus the composed
# audit-verdict, for b36-multi-provider-spend-governance.
#
# THE MECHANISM (spec §0): both providers publish spend ONLY on an authenticated
# HTML page (opencode.ai/workspace/{id}/billing) — no API, no CLI subcommand, no
# usage headers exist today. This file scrapes that page. It vendors NOTHING
# from any reference implementation; the selectors below are this repo's own,
# derived only from the fixture shape documented in the spec.
#
# THE THREE BINDING RULES (spec §1), restated at the point they are enforced
# below so a future editor cannot miss them while changing a regex:
#
#   1. A parse failure NEVER becomes a number. Every extraction returns
#      status => 'ok' with real figures, or status => 'unknown' with a
#      diagnostic. Never a default, never a zero, never a guess.
#   2. The cookie is a whole browser-session credential, broader than anything
#      else this system handles. resolve_credential() refuses a group/world-
#      readable fallback file outright, and nothing in this file ever places
#      the cookie value into a diagnostic, a log field, or an exception string.
#   3. No cadence of its own is published upstream, so this file enforces one:
#      $CADENCE_TTL_SECONDS (a NAMED constant, never a bare literal at the call
#      sites) plus a TTL cache. Failure direction is always "degrade to warn",
#      never "manufacture a pause/block out of a network hiccup" — mirrors
#      bp-deps-check.pl's binding invariant and b46's audit-vs-build split.
#
# REVISIT TRIGGER (spec §3a, operator 2026-08-03): the scrape is a workaround,
# not the destination. Every parse-failure diagnostic below therefore ends
# with the revisit prompt — check whether OpenCode now publishes a documented
# API, CLI subcommand, or usage header for Go/Zen quota BEFORE repairing the
# scrape; if one exists, replace this reader rather than patch a regex.
#
# NO LIVE HTTP AT LOAD TIME. fetch() takes an injected `http` coderef seam
# ($method, $url, \%headers) -> {status=>N, content=>STR}. Production code
# only reaches for a real transport (bp-http.pl, the house's curl wrapper —
# never HTTP::Tiny/LWP::UserAgent) lazily, inside the branch that actually
# performs a live fetch, so the test suite never triggers it and neither
# HTTP::Tiny nor LWP::UserAgent ever lands in %INC while it runs.
#
# mandated_means: bp-log.pl — every fetch attempt/outcome, when a log_path is
# given, goes through the real BpLog::event(). Never a reimplementation.

package BpSpend;
use strict;
use warnings;
use JSON::PP;
use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $DIR = dirname(abs_path(__FILE__));
require "$DIR/bp-log.pl";   # mandated_means — loaded unconditionally, no HTTP inside it.

# ---------------------------------------------------------------------------
# Cadence floor (spec §1.3). NAMED constant — referenced by variable at every
# call site below, never re-typed as a bare literal seconds figure.
# ---------------------------------------------------------------------------
our $CADENCE_TTL_SECONDS = 900;   # 15 minutes: a billing dashboard, not a meter.

my %WINDOW_KEY = ('5h' => 'five_hour', 'Weekly' => 'weekly', 'Monthly' => 'monthly');

# ---------------------------------------------------------------------------
# _revisit_diagnostic($why) -> the parse-failure diagnostic, always carrying
# the §3a revisit prompt so nobody who reads it can miss the question.
# ---------------------------------------------------------------------------
sub _revisit_diagnostic {
    my ($why) = @_;
    return "$why. Before repairing the scrape, check whether OpenCode now "
         . "publishes a documented API, CLI subcommand, or usage header for "
         . "Go/Zen quota -- if it does, replace this reader rather than fix it.";
}

# ---------------------------------------------------------------------------
# parse_go($html) -> pure, no I/O.
#   ok:      { status => 'ok', five_hour=>{used,limit}, weekly=>{...}, monthly=>{...} }
#   unknown: { status => 'unknown', diagnostic => $str }
# ---------------------------------------------------------------------------
sub parse_go {
    my ($html) = @_;
    $html = '' unless defined $html;

    my %found;
    while ($html =~ /<div\s+class="quota-window"\s+data-window="([^"]+)">(.*?)<\/div>/gs) {
        my ($label, $block) = ($1, $2);
        if ($block =~ /<span\s+class="quota-used">\s*\$?([\d.]+)\s*<\/span>\s*\/\s*<span\s+class="quota-limit">\s*\$?([\d.]+)\s*<\/span>/s) {
            $found{$label} = { used => $1 + 0, limit => $2 + 0 };
        }
    }

    my @missing = grep { !$found{$_} } qw(5h Weekly Monthly);
    if (@missing) {
        return {
            status     => 'unknown',
            diagnostic => _revisit_diagnostic(
                "Go quota-window selector (div.quota-window[data-window]/span.quota-used"
                . "+span.quota-limit) did not yield figures for: " . join(', ', @missing)
            ),
        };
    }

    return {
        status    => 'ok',
        five_hour => $found{'5h'},
        weekly    => $found{'Weekly'},
        monthly   => $found{'Monthly'},
    };
}

# ---------------------------------------------------------------------------
# parse_zen($html) -> pure, no I/O.
#   ok:      { status => 'ok', balance => N, budget => N|undef }
#   unknown: { status => 'unknown', diagnostic => $str }
# ---------------------------------------------------------------------------
sub parse_zen {
    my ($html) = @_;
    $html = '' unless defined $html;

    my $balance;
    if ($html =~ /<div\s+class="billing-balance">.*?<span\s+class="balance-value">\s*\$?([\d.]+)\s*<\/span>.*?<\/div>/s) {
        $balance = $1;
    }

    unless (defined $balance) {
        return {
            status     => 'unknown',
            diagnostic => _revisit_diagnostic(
                "Zen billing-balance selector (div.billing-balance span.balance-value) "
                . "did not yield a recognisable balance"
            ),
        };
    }

    my $budget;
    if ($html =~ /<div\s+class="billing-budget">.*?<span\s+class="budget-value">\s*\$?([\d.]+)\s*<\/span>.*?<\/div>/s) {
        $budget = $1;
    }

    return { status => 'ok', balance => $balance, budget => $budget };
}

# ---------------------------------------------------------------------------
# resolve_credential(%opts) -> env-first, then a fallback file (spec §1.2).
#   opts: env_var => NAME, env => \%ENV (injectable), fallback_path => PATH
#   ok:  { ok => 1, cookie => $str, source => 'env'|'file' }
#   fail:{ ok => 0, reason => 'missing'|'insecure-file', detail => $str }
# A group/world-readable fallback file is refused outright, naming the path
# and the required mode (0600) — never silently read.
# ---------------------------------------------------------------------------
sub resolve_credential {
    my (%opts) = @_;
    my $env_var       = $opts{env_var};
    my $env           = $opts{env} // \%ENV;
    my $fallback_path = $opts{fallback_path};

    if (defined $env_var && exists $env->{$env_var}
        && defined $env->{$env_var} && length $env->{$env_var}) {
        return { ok => 1, cookie => $env->{$env_var}, source => 'env' };
    }

    if (defined $fallback_path && -e $fallback_path) {
        my @st = stat($fallback_path);
        my $mode = @st ? ($st[2] & 07777) : undef;
        if (defined $mode && ($mode & 0077)) {
            return {
                ok     => 0,
                reason => 'insecure-file',
                detail => sprintf(
                    "credential file %s is group/world-readable (mode %04o); refusing "
                    . "to read a session cookie from it -- required mode is 0600 "
                    . "(chmod 0600 %s)",
                    $fallback_path, $mode, $fallback_path
                ),
            };
        }

        my $raw = do {
            local $/;
            open my $fh, '<', $fallback_path
                or return { ok => 0, reason => 'missing', detail => "cannot open $fallback_path: $!" };
            <$fh>;
        };
        my $data = eval { JSON::PP->new->decode($raw) };
        if (ref $data eq 'HASH' && defined $data->{cookie} && length $data->{cookie}) {
            return { ok => 1, cookie => $data->{cookie}, source => 'file' };
        }
        return { ok => 0, reason => 'missing', detail => "credential file $fallback_path did not contain a usable 'cookie' field" };
    }

    return {
        ok     => 0,
        reason => 'missing',
        detail => "no credential found: env var " . ($env_var // '(unset)') . " not set"
                . (defined $fallback_path ? ", and no fallback file at $fallback_path" : ", and no fallback file configured"),
    };
}

sub _looks_like_login_redirect {
    my ($content) = @_;
    return 0 unless defined $content;
    return $content =~ /sign\s*in\s*to\s*opencode|action\s*=\s*"\/login"|please\s*sign\s*in/i ? 1 : 0;
}

# ---------------------------------------------------------------------------
# fetch(%opts) -> the normalized reader + cadence + credential + parse,
# composed. Returns the same shape as parse_go/parse_zen, with a 'provider'
# key stamped on.
#
#   opts: provider => 'go'|'zen',
#         http     => CODEREF($method,$url,\%hdrs)->{status,content},
#         now      => epoch,
#         cache    => \%hashref (mutated, shared across calls, keyed by provider,
#                     enforces the $CADENCE_TTL_SECONDS floor),
#         credential => { cookie => $str }  -- OR --
#         env_var / fallback_path (resolved via resolve_credential),
#         log_path => optional; every attempt/outcome logged via BpLog::event.
# ---------------------------------------------------------------------------
sub fetch {
    my (%opts) = @_;
    my $provider = $opts{provider} // 'unknown';
    my $now      = defined $opts{now} ? $opts{now} : time;
    my $cache    = $opts{cache} // {};
    my $log_path = $opts{log_path};

    my $_log = sub {
        my ($outcome, $extra) = @_;
        return unless defined $log_path;
        my %fields = (provider => $provider, outcome => $outcome, %{ $extra || {} });
        # NEVER include the credential/cookie here (spec §1.2) -- deliberately
        # not forwarded into %fields anywhere on this path.
        eval { BpLog::event($log_path, 'spend_fetch', \%fields, $now) };
    };

    # --- cadence floor: served from cache inside the TTL window, no I/O at all. ---
    if (exists $cache->{$provider}
        && defined $cache->{$provider}{fetched_at}
        && ($now - $cache->{$provider}{fetched_at}) < $CADENCE_TTL_SECONDS) {
        $_log->('cached', { status => $cache->{$provider}{result}{status} });
        return $cache->{$provider}{result};
    }

    # --- credential resolution ---
    my $cred;
    if (ref $opts{credential} eq 'HASH' && defined $opts{credential}{cookie}) {
        $cred = { ok => 1, cookie => $opts{credential}{cookie}, source => 'provided' };
    } else {
        $cred = resolve_credential(
            env_var       => $opts{env_var},
            env           => $opts{env},
            fallback_path => $opts{fallback_path},
        );
    }

    unless ($cred->{ok}) {
        my $result = {
            status     => 'unknown',
            provider   => $provider,
            diagnostic => "credential unavailable ($cred->{reason}): $cred->{detail}",
        };
        $cache->{$provider} = { fetched_at => $now, result => $result };
        $_log->('credential-unavailable', { status => 'unknown', reason => $cred->{reason} });
        return $result;
    }

    # --- transport: injected seam, or (lazily, only here) the house curl wrapper. ---
    my $http = $opts{http};
    unless (defined $http) {
        require "$DIR/bp-http.pl";   # lazy: never touched by the test suite's injected-seam paths.
        $http = sub {
            my ($method, $url, $hdrs) = @_;
            return BpHttp::request($method, $url, $hdrs);
        };
    }

    my $workspace_env = $provider eq 'go' ? 'OPENCODE_GO_WORKSPACE_ID' : 'OPENCODE_WORKSPACE_ID';
    my $workspace_id  = $opts{workspace_id} // $ENV{$workspace_env} // 'unknown';
    my $url = "https://opencode.ai/workspace/$workspace_id/billing";

    my $res = eval { $http->('GET', $url, { Cookie => "session=" . $cred->{cookie} }) };
    if ($@) {
        my $err = $@;
        $err =~ s/\s+$//;
        my $result = {
            status     => 'unknown',
            provider   => $provider,
            diagnostic => _revisit_diagnostic("network transport failed (caught, not a crash): $err"),
        };
        $cache->{$provider} = { fetched_at => $now, result => $result };
        $_log->('transport-error', { status => 'unknown' });
        return $result;
    }

    my $status  = ref($res) eq 'HASH' ? ($res->{status} // 0) : 0;
    my $content = ref($res) eq 'HASH' ? ($res->{content} // '') : '';

    my $result;
    if ($status == 401) {
        $result = {
            status     => 'unknown',
            provider   => $provider,
            diagnostic => "cookie rejected (401 unauthorized) -- re-copy the cookie from your opencode.ai session and try again.",
        };
    } elsif ($status == 200 && _looks_like_login_redirect($content)) {
        $result = {
            status     => 'unknown',
            provider   => $provider,
            diagnostic => "session rejected (redirected to sign-in) -- re-copy the cookie from your opencode.ai session and try again.",
        };
    } elsif ($status == 200) {
        my $parsed = $provider eq 'zen' ? parse_zen($content) : parse_go($content);
        $result = { %$parsed, provider => $provider };
    } else {
        $result = {
            status     => 'unknown',
            provider   => $provider,
            diagnostic => _revisit_diagnostic("network problem reaching the billing page (status=$status)"),
        };
    }

    $cache->{$provider} = { fetched_at => $now, result => $result };
    $_log->('fetched', { status => $result->{status}, http_status => $status });
    return $result;
}

# ---------------------------------------------------------------------------
# verdict(@results) -> composes N provider results into ONE decision.
#   { action => 'ok'|'unknown', reason => $str }
# ANY 'unknown' result propagates: overall action is 'unknown', NEVER 'ok',
# and NEVER coerced into a pause/block -- this is a WARN/audit path (spec
# §1.3, bp-deps-check.pl's binding invariant).
# ---------------------------------------------------------------------------
sub verdict {
    my @results = @_;
    my @unknown = grep { ref($_) eq 'HASH' && (($_->{status} // '') eq 'unknown') } @results;

    if (@unknown) {
        my @who = map { $_->{provider} // '?' } @unknown;
        return {
            action => 'unknown',
            reason => 'one or more providers unreadable (never coerced to a pause): ' . join(', ', @who),
        };
    }

    return { action => 'ok', reason => 'all providers reporting real figures' };
}

package main;
1;
