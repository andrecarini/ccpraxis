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
use Fcntl ();

my $DIR = dirname(do { (my $f = __FILE__) =~ s{\\}{/}g; abs_path($f) // $f });
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
# resolve_credential(%opts) -> file-only (spec b36-reopen §1: the env path is
# REMOVED as a supported input, deliberately -- not merely unused. See the
# reopen spec's ruling: bp-jail.pl performs no environment isolation, exec()
# inherits %ENV wholesale, so a cookie that is never IN %ENV cannot leak via
# the jail. env_var/env are still accepted opts for call-site compatibility
# but are NEVER consulted -- resolution is file-only, unconditionally.
#   opts: env_var => NAME (ignored), env => \%ENV (ignored), fallback_path => PATH
#   ok:  { ok => 1, cookie => $str, source => 'file' }
#   fail:{ ok => 0, reason => 'missing'|'insecure-file', detail => $str }
# A group/world-readable fallback file is refused outright, naming the path
# and the required mode (0600) — never silently read.
# ---------------------------------------------------------------------------
sub resolve_credential {
    my (%opts) = @_;
    my $fallback_path = $opts{fallback_path};

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
        detail => "no credential found: "
                . (defined $fallback_path ? "no usable fallback file at $fallback_path" : "no fallback file configured"),
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
        # THREE STATES, not two (ledger done-criterion 1). A provider that was
        # never configured at all is ABSENT -- there is no meter to read, and
        # saying "unknown" about it would be a claim we cannot support and would
        # drag the composed verdict to unknown for a provider the operator never
        # asked us to govern.
        #
        # `missing` means no env var AND no usable fallback file: nobody
        # configured this provider. Anything else (notably `insecure-file`, a
        # credential that EXISTS but which we refuse to read) means the provider
        # IS configured and we could not read its meter -- that is genuinely
        # unknown, and must keep propagating as such.
        #
        # Neither ever becomes a number. Absent is not zero-spent.
        my $absent = (($cred->{reason} // '') eq 'missing') ? 1 : 0;
        my $status = $absent ? 'absent' : 'unknown';
        my $result = {
            status     => $status,
            provider   => $provider,
            diagnostic => $absent
                ? "provider not configured: $cred->{detail}"
                : "credential unavailable ($cred->{reason}): $cred->{detail}",
        };
        $cache->{$provider} = { fetched_at => $now, result => $result };
        $_log->('credential-unavailable', { status => $status, reason => $cred->{reason} });
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
    # ABSENT providers are skipped, not counted as unknown: nobody configured
    # them, so there is no meter to be uncertain about, and letting an
    # unconfigured provider drag the whole verdict to unknown would make the
    # default (Zen is off by default) permanently unknown for every operator.
    # Absent is still never zero -- it simply does not participate.
    @results = grep { !(ref($_) eq 'HASH' && (($_->{status} // '') eq 'absent')) } @results;
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

# ---------------------------------------------------------------------------
# write_snapshot(%opts) -> persists the composed spend snapshot so the TUI
# (launcher.pl's _gather_spend) can render without fetching (b36-reopen §2).
#
#   opts: path       => PATH (final destination, e.g. "<active run>/spend.json"),
#         results    => \@results (each shaped like fetch()'s own return value),
#         credential => \%opt (OPTIONAL -- accepted only so a caller that still
#                      has the credential struct in scope cannot accidentally
#                      leak it in; it is NEVER read, NEVER serialised, below),
#         now        => epoch (defaults to time).
#
# ⚠ REDACTION IS THE BINDING CONSTRAINT (spec §2.1). This sub NEVER serialises
# a raw result hash -- it builds each snapshot row from an explicit FIELD
# WHITELIST (provider/status/five_hour/weekly/monthly/balance/budget/
# diagnostic). Anything else on a result -- a stray `cookie` key, a `_debug`
# sub-hash carrying request headers, whatever a careless composer bolted on --
# is dropped on the floor, not merely "not forwarded" but never even looked
# at for the write. This is what makes the redaction structural rather than
# a matter of remembering not to pass the credential in.
#
# Atomic: write to a temp file in the SAME directory as $path, then rename()
# over the final path -- a reader can never observe a half-written file.
# Mode 0600 from creation (sysopen with the mode), never chmod'd after.
# ---------------------------------------------------------------------------
my @SNAPSHOT_RESULT_FIELDS = qw(provider status five_hour weekly monthly balance budget diagnostic);

sub _whitelist_result {
    my ($r) = @_;
    return {} unless ref($r) eq 'HASH';
    my %out;
    for my $f (@SNAPSHOT_RESULT_FIELDS) {
        next unless exists $r->{$f};
        my $v = $r->{$f};
        if (ref($v) eq 'HASH') {
            # five_hour/weekly/monthly are the only nested shape this file
            # ever produces (used/limit) -- whitelist those two sub-fields
            # only, so an unexpected nested key (e.g. a smuggled credential)
            # can never ride along even inside a field that IS on the list.
            my %sub;
            for my $sf (qw(used limit)) {
                $sub{$sf} = $v->{$sf} if exists $v->{$sf};
            }
            $out{$f} = \%sub;
        } else {
            $out{$f} = $v;
        }
    }
    return \%out;
}

sub write_snapshot {
    my (%opts) = @_;
    my $path    = $opts{path};
    my $results = ref($opts{results}) eq 'ARRAY' ? $opts{results} : [];
    my $now     = defined $opts{now} ? $opts{now} : time;

    die "write_snapshot: path is required\n" unless defined $path && length $path;

    my @clean = map { _whitelist_result($_) } @$results;
    my $snapshot = { generated_at => BpLog::_iso_now($now), results => \@clean };
    my $json = JSON::PP->new->canonical->encode($snapshot);

    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    $dir = '.' unless length $dir;
    if (length $dir && !-d $dir) { require File::Path; File::Path::make_path($dir); }

    my $tmp_path = "$path.tmp.$$." . int(rand(1_000_000));
    sysopen(my $fh, $tmp_path, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_TRUNC(), 0600)
        or die "write_snapshot: sysopen $tmp_path: $!";
    print {$fh} $json or die "write_snapshot: write $tmp_path: $!";
    close $fh or die "write_snapshot: close $tmp_path: $!";

    rename($tmp_path, $path) or die "write_snapshot: rename $tmp_path -> $path: $!";
    return $path;
}

package main;

# ===========================================================================
# CLI (b47). THIS BLOCK'S ABSENCE WAS THE DEFECT.
#
# bp-spend.pl previously ended `package main; 1;` with no `unless (caller)`
# block, so nothing outside a `require` could ever invoke it. Combined with
# write_snapshot having no production caller, the Spend panel could never
# render on any real fleet -- and the reader's `-f` guard plus its swallowing
# `eval` made that permanent breakage look exactly like "no data yet".
#
#   bp-spend.pl snapshot --run-dir DIR [--offline] [--now EPOCH] [--log PATH]
#
# Writes DIR/spend.json -- the exact path launcher.pl's _gather_spend reads.
# Exit 0 wrote (or served a still-fresh snapshot) - 2 usage - 4 I/O.
#
# CADENCE ACROSS PROCESSES. fetch()'s TTL cache is in-process and therefore
# useless to a CLI that exits, so this re-derives the floor from the EXISTING
# snapshot's generated_at. That makes the verb safe to call on any tick: inside
# $CADENCE_TTL_SECONDS it is a stat plus a read and makes no network call at
# all. Without this, wiring it to a frequent loop would hammer the providers --
# the cadence floor would exist in the library and be bypassed by its only
# caller.
#
# --offline performs no fetch and records every provider as `absent`. It exists
# so the write path can be exercised deterministically (no credentials, no
# network) -- the check that would have caught the original defect.
# ===========================================================================
unless (caller) {
    my $verb = shift(@ARGV) // '';
    my %opt;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a =~ /^--run-dir=(.*)$/) { $opt{run_dir} = $1 }
        elsif ($a eq '--run-dir')        { $opt{run_dir} = shift @ARGV }
        elsif ($a =~ /^--now=(.*)$/)     { $opt{now}     = $1 }
        elsif ($a eq '--now')            { $opt{now}     = shift @ARGV }
        elsif ($a =~ /^--log=(.*)$/)     { $opt{log}     = $1 }
        elsif ($a eq '--log')            { $opt{log}     = shift @ARGV }
        elsif ($a eq '--offline')        { $opt{offline} = 1 }
        elsif ($a eq '--force')          { $opt{force}   = 1 }
        else { print STDERR "bp-spend: unrecognised argument '$a'\n"; exit 2 }
    }

    if ($verb ne 'snapshot') {
        print STDERR "usage: bp-spend.pl snapshot --run-dir DIR [--offline] [--force] [--now EPOCH] [--log PATH]\n";
        exit 2;
    }
    unless (defined $opt{run_dir} && length $opt{run_dir}) {
        print STDERR "bp-spend: --run-dir is required\n";
        exit 2;
    }

    my $now  = defined $opt{now} && $opt{now} =~ /^\d+$/ ? $opt{now} + 0 : time;
    my $path = "$opt{run_dir}/spend.json";

    # Cross-process cadence floor -- see the header note.
    if (!$opt{force} && -f $path) {
        my $fresh = eval {
            open my $fh, '<:raw', $path or die "read\n";
            my $raw = do { local $/; <$fh> };
            close $fh;
            my $prev = JSON::PP->new->decode($raw);
            my $gen  = ref $prev eq 'HASH' ? ($prev->{generated_at} // '') : '';
            # generated_at is ISO; compare via mtime, which is what we control.
            my @st = stat($path);
            (@st && ($now - $st[9]) < $BpSpend::CADENCE_TTL_SECONDS) ? 1 : 0;
        };
        if ($fresh) { print "$path\n"; exit 0 }
    }

    my @results;
    if ($opt{offline}) {
        @results = map { { provider => $_, status => 'absent' } } qw(go zen);
    }
    else {
        my %cache;
        for my $p (qw(go zen)) {
            my $r = eval {
                BpSpend::fetch(provider => $p, now => $now, cache => \%cache,
                               log_path => $opt{log});
            };
            # A provider that blows up must not lose the whole snapshot: record
            # it as unknown (never zero, never absent -- it IS configured enough
            # to have failed) and keep going.
            push @results, (ref $r eq 'HASH') ? $r
                         : { provider => $p, status => 'unknown' };
        }
    }

    my $written = eval { BpSpend::write_snapshot(path => $path, results => \@results, now => $now) };
    if ($@ || !defined $written) {
        print STDERR "bp-spend: could not write $path: " . ($@ || "unknown error\n");
        exit 4;
    }
    print "$written\n";
    exit 0;
}

1;
