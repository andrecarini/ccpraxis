#!/usr/bin/env perl
# bp-pin.pl — version-pin resolver + drift auditor (b46-version-pin-currency).
#
# ONE implementation, TWO modes, opposite failure policies (spec b46 sec2):
#
#   resolve  — runs at IMAGE BUILD time, to pick the version a human then bakes
#              into the Containerfile as a literal. On any registry problem
#              (unreachable, malformed, no eligible version) it FAILS CLOSED:
#              non-zero exit, a named cause, and NEVER a printed version.
#              Falling back to "latest" here would invert the repo's >=7-day
#              supply-chain rule and bake an unvetted version into an image.
#
#   audit    — runs in PREFLIGHT, to report drift between what's pinned in the
#              Containerfile and what would now be eligible. On the SAME
#              registry problems it DEGRADES TO WARN: exit 0, a drift-unknown
#              line. A network blip must never wedge an unattended fleet
#              (the same invariant bp-deps-check.pl already carries).
#
# EOL/LTS data is NEVER duplicated here. It is `require`d straight from
# bp-deps-check.pl's `our %EOL` (dates, not an is_eol flag, so an injected
# clock still drives the verdict). A second table is the b12/b13 drift lesson
# this blueprint has now hit four times — do not reintroduce it.
#
# The pin manifest IS the Containerfile (plugins/sandbox/container/Containerfile).
# `audit` parses the pinned versions out of it BY PATTERN, never by line number
# (SYN-23) — a separate pin list would drift from the real pins.
#
# TRANSPORT CONTRACT — identical in shape to bp-deps-check.pl's own injected
# `http` (bp-deps-check.pl `_registry_publish`) and to BpHttp::request's return
# shape: `$http->('GET', $url, {}) -> { status => $int, content => $json_text }`.
# The registry document `$json_text` decodes to an npm-packument shape,
# `{"time": {"<version>": "<ISO8601>", ...}}` — this is what makes the whole
# suite run offline and deterministically: inject `http` (library form) or
# `--fetcher <path-to-json-fixture>` (CLI form) and no live fetch ever happens.
#
# Usage:
#   perl bp-pin.pl resolve --policy <p> --package <name> --min-age-days N
#                          [--fetcher <path-to-packument.json>] [--now <iso|epoch>]
#     PATH is a single package's packument JSON ({"time": {...}}), read in
#     place of a live GET.
#   perl bp-pin.pl audit [--manifest <path>] [--now <iso|epoch>] [--offline]
#                        [--fetcher <path-to-multi-package.json>]
#     PATH is a JSON object keyed BY PACKAGE NAME, each value a packument doc:
#     {"node": {"time": {...}}, "pnpm": {"time": {...}}, ...} — one file stands
#     in for every pin `audit` needs to look up.
#
# Policies:
#   latest-eligible      — newest version >= --min-age-days old (opencode, pnpm).
#   latest-lts-eligible  — newest LTS line, non-EOL, >= --min-age-days old (node).
#
# require:  require "<path-to-this-file>";
#           my ($version,$cause,$detail) = BpPin::resolve({ policy=>..., package=>...,
#                                             min_age_days=>7, now=>$epoch, http=>$stub });
#           my ($report,$rc) = BpPin::audit({ manifest=>$path, http=>$stub, now=>$epoch });

package BpPin;
use strict;
use warnings;
no warnings 'once';   # $BpDepsCheck::EOL / $BpDepsCheck::FRESH_DAYS are read-once by design
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP;

# abs_path(__FILE__), NOT FindBin's $Bin and NOT bare dirname(__FILE__).
#
# FindBin's $Bin is derived from $0 (the ORIGINALLY INVOKED script), cached
# once per process -- so when this file is `require`d from a test living in
# plugins/butler/tests/t/, $Bin would resolve to the TEST's directory, not
# this script's, and every sibling `require` below would silently look in the
# wrong place. bare dirname(__FILE__) has its own landmine: invoked the normal
# way (`perl plugins/butler/scripts/bp-pin.pl` from the repo root) __FILE__ is
# RELATIVE, so `require "$DIR/..."` searches @INC, which has not contained '.'
# since perl 5.26 (see 9e85473/d846cfa's bp-blueprint.pl fix for the exact
# failure shape). abs_path(__FILE__) is stable under both invocation styles.
my $DIR = dirname(abs_path(__FILE__));

# The REAL EOL/LTS table. Consumed, never copied (spec b46 sec3/C5).
require "$DIR/bp-deps-check.pl";

our $DEFAULT_MIN_AGE_DAYS = $BpDepsCheck::FRESH_DAYS;   # 7, reused rather than re-declared

our $DEFAULT_MANIFEST = "$DIR/../../sandbox/container/Containerfile";

# ---- version comparison (dotted numeric, "1.2.3" style) -------------------

sub cmp_version {
    my ($a, $b) = @_;
    my @pa = split /\./, ($a // '0');
    my @pb = split /\./, ($b // '0');
    my $n = @pa > @pb ? scalar(@pa) : scalar(@pb);
    for my $i (0 .. $n - 1) {
        my $x = $pa[$i] // 0;
        my $y = $pb[$i] // 0;
        $x =~ s/^(\d*).*$/$1/; $y =~ s/^(\d*).*$/$1/;
        $x = 0 unless length $x;
        $y = 0 unless length $y;
        my $c = $x <=> $y;
        return $c if $c;
    }
    return 0;
}

sub _newest {
    my (@releases) = @_;
    return undef unless @releases;
    my @sorted = sort { cmp_version($b->{version}, $a->{version}) } @releases;
    return $sorted[0];
}

# ---- transport plumbing ----------------------------------------------------

sub _uri_escape_segment {
    my ($s) = @_;
    $s = '' unless defined $s && !ref $s;
    $s =~ s{([^A-Za-z0-9\-._~])}{sprintf('%%%02X', ord($1))}ge;
    return $s;
}

sub _url_for_package {
    my ($pkg) = @_;
    return 'https://registry.npmjs.org/' . _uri_escape_segment($pkg);
}

# _http_stub_from_file($path) -> coderef with the SAME (method,url,headers) ->
# {status,content} shape as a real transport. Auto-detects which of the two
# documented fixture shapes the file holds:
#   - a single packument ({"time": {...}}) -- returned for WHATEVER package is
#     asked (this is `resolve`'s single-package CLI fixture).
#   - an object keyed by package name, each value a packument -- the package
#     actually being fetched is read back off the URL's last path segment
#     (this is `audit`'s multi-package CLI fixture).
sub _http_stub_from_file {
    my ($path) = @_;
    return sub {
        my ($method, $url, $headers) = @_;
        open my $fh, '<:raw', $path
            or die "cannot open fetcher fixture '$path': $!\n";
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $doc = eval { JSON::PP->new->utf8->relaxed->decode($raw) };
        die "fetcher fixture '$path' is not valid JSON: $@\n" if $@;
        die "fetcher fixture '$path' is not a JSON object\n" unless ref $doc eq 'HASH';

        if (exists $doc->{time}) {
            return { status => 200, content => JSON::PP->new->canonical->encode($doc) };
        }
        my ($pkg) = $url =~ m{([^/]+)$};
        die "fetcher fixture '$path' has no entry for the requested package (url: $url)\n"
            unless defined $pkg && exists $doc->{$pkg};
        return { status => 200, content => JSON::PP->new->canonical->encode($doc->{$pkg}) };
    };
}

# _default_http() -> coderef. Best-effort LIVE transport via bp-http.pl,
# mirroring bp-deps-check.pl's own graceful-degrade pattern verbatim: a
# missing/unloadable transport must never crash the caller, only surface as a
# status-0 response (which both resolve's fail-closed and audit's WARN paths
# already handle as "could not reach the registry"). Never exercised by the
# (offline, deterministic) test suite.
sub _default_http {
    my $loaded = eval { require "$DIR/bp-http.pl"; 1 };
    return $loaded
        ? sub { BpHttp::request(@_) }
        : sub { { status => 0, content => 'bp-http.pl transport unavailable' } };
}

sub _resolve_http {
    my ($opts) = @_;
    return $opts->{http}                              if ref $opts->{http} eq 'CODE';
    return _http_stub_from_file($opts->{fetcher_path}) if defined $opts->{fetcher_path};
    return _default_http();
}

sub _resolve_now {
    my ($opts) = @_;
    return time unless defined $opts->{now};
    my $e = BpDepsCheck::parse_iso8601($opts->{now});
    die "unparseable --now value '$opts->{now}'\n" unless defined $e;
    return $e;
}

# _fetch_releases($http,$package) -> (\@releases,undef,undef) on success,
# (undef,$cause,$detail) on any failure. $cause is a STABLE, named string
# (never freeform) so both resolve's fail-closed path and audit's WARN path
# can key off it. Mirrors bp-deps-check.pl's own `_registry_publish` shape.
sub _fetch_releases {
    my ($http, $package) = @_;
    my $url = _url_for_package($package);

    my $res = eval { $http->('GET', $url, {}) };
    if ($@) {
        (my $err = $@) =~ s/\s+$//;
        return (undef, 'fetch-failed', "registry fetch for '$package' raised an error: $err");
    }
    return (undef, 'transport-error', "registry fetch for '$package' returned no usable response")
        unless ref $res eq 'HASH';

    my $status = $res->{status};
    $status = 0 unless defined $status && !ref $status && $status =~ /^\d+$/;
    return (undef, "http-$status", "registry returned status $status for '$package' (expected 200)")
        if $status != 200;

    my $body = $res->{content};
    $body = '' unless defined $body && !ref $body;
    my $doc = eval { JSON::PP->new->utf8->decode($body) };
    return (undef, 'malformed-registry-document', "registry response for '$package' is not valid JSON")
        if $@ || ref $doc ne 'HASH';
    return (undef, 'malformed-registry-document', "registry document for '$package' has no 'time' object")
        unless ref $doc->{time} eq 'HASH';

    my @releases;
    for my $v (sort keys %{ $doc->{time} }) {
        next if $v eq 'created' || $v eq 'modified';   # npm packument metadata keys, not versions
        my $pub = $doc->{time}{$v};
        next unless defined $pub && !ref $pub;
        push @releases, { version => $v, published => $pub };
    }
    return (undef, 'malformed-registry-document', "registry document for '$package' has no usable release entries")
        unless @releases;
    for my $r (@releases) {
        return (undef, 'malformed-registry-document', "unparseable publish date '$r->{published}' for $package\@$r->{version}")
            unless defined BpDepsCheck::parse_iso8601($r->{published});
    }
    return (\@releases, undef, undef);
}

# ---- resolve ---------------------------------------------------------------

# resolve(\%opts) -> ($version, $cause, $detail)
#   success: ($version, undef, undef)
#   failure: (undef, $cause, $detail)   -- NEVER a version alongside a cause.
sub resolve {
    my ($opts) = @_;
    $opts ||= {};

    my $policy = $opts->{policy};
    return (undef, 'usage-error', "unknown --policy '" . ($policy // '') . "' (expected latest-eligible or latest-lts-eligible)")
        unless defined $policy && ($policy eq 'latest-eligible' || $policy eq 'latest-lts-eligible');

    my $package = $opts->{package};
    return (undef, 'usage-error', '--package is required') unless defined $package && length $package;

    my $min_age = $opts->{min_age_days};
    return (undef, 'usage-error', '--min-age-days must be a non-negative integer')
        unless defined $min_age && $min_age =~ /^\d+$/;

    my $now = eval { _resolve_now($opts) };
    return (undef, 'usage-error', $@) if $@;

    my $http = _resolve_http($opts);
    my ($releases, $cause, $detail) = _fetch_releases($http, $package);
    return (undef, $cause, $detail) unless $releases;

    # A prerelease/non-stable version ("12.0.0-alpha.21", "1.2.3-rc.0") is
    # NEVER "eligible", regardless of age: it is not what "latest LTS/stable"
    # means, and shipping one into a pinned build is exactly the kind of
    # unreviewed-variable outcome this package exists to prevent. Filtering it
    # out here (rather than trusting the registry not to list one) matters in
    # practice -- a live npm packument's `time` object lists EVERY published
    # version, prereleases included.
    my @stable = grep { $_->{version} !~ /[-+]/ } @$releases;
    return (undef, 'no-eligible-version', "'$package' has releases, but none is a stable (non-prerelease) version")
        unless @stable;
    $releases = \@stable;

    if ($policy eq 'latest-eligible') {
        my @eligible = grep {
            my $age = BpDepsCheck::age_days(BpDepsCheck::parse_iso8601($_->{published}), $now);
            defined $age && $age >= $min_age;
        } @$releases;
        return (undef, 'no-eligible-version',
                "no release of '$package' is >= $min_age day(s) old as of " . BpDepsCheck::iso_of($now))
            unless @eligible;
        my $best = _newest(@eligible);
        return ($best->{version}, undef, undef);
    }

    # latest-lts-eligible: pick the newest LTS major line that is (a) already
    # LTS, (b) not yet EOL, as of $now -- then the newest release WITHIN that
    # line that also clears the age floor. Mirrors the Containerfile's own
    # comment for Node: 24.18.1 was too new; 24.18.0 was the newest ELIGIBLE
    # release of the (already-chosen) Active-LTS line.
    my $tbl = $BpDepsCheck::EOL{$package};
    return (undef, 'unknown-lts-package', "no EOL/LTS table entry for '$package' in bp-deps-check.pl's \%EOL")
        unless $tbl;

    my @majors_desc = sort { $b <=> $a } grep { defined $tbl->{$_}{lts} } keys %$tbl;
    for my $maj (@majors_desc) {
        my $lts = BpDepsCheck::parse_iso8601($tbl->{$maj}{lts});
        my $eol = BpDepsCheck::parse_iso8601($tbl->{$maj}{eol});
        next unless defined $lts && defined $eol;
        next if $lts > $now;     # not LTS yet
        next if $eol <= $now;    # already EOL -- Node 20's exclusion (spec C2) lands here

        my @in_line = grep {
            my $m = BpDepsCheck::major_of($package, $_->{version});
            defined $m && $m eq $maj;
        } @$releases;
        my @eligible = grep {
            my $age = BpDepsCheck::age_days(BpDepsCheck::parse_iso8601($_->{published}), $now);
            defined $age && $age >= $min_age;
        } @in_line;
        next unless @eligible;
        my $best = _newest(@eligible);
        return ($best->{version}, undef, undef);
    }
    return (undef, 'no-eligible-lts-version',
            "no non-EOL LTS line of '$package' has a release >= $min_age day(s) old as of " . BpDepsCheck::iso_of($now));
}

# ---- Containerfile pin extraction (SYN-23: by pattern, never by line number) ---

our @PIN_SPEC = (
    { package => 'node',              policy => 'latest-lts-eligible',
      pattern => qr/node-v([0-9][0-9.]*)-linux-x64\.tar\.xz/ },
    { package => 'pnpm',               policy => 'latest-eligible',
      pattern => qr/pnpm\@([0-9][0-9.]*)/ },
    { package => 'opencode-linux-x64', policy => 'latest-eligible',
      pattern => qr/opencode-linux-x64\@([0-9][0-9.]*)/ },
);

# _parse_pins($path) -> (\@pins, undef) | (undef, $error)
sub _parse_pins {
    my ($path) = @_;
    open my $fh, '<', $path or return (undef, "cannot open manifest '$path': $!");
    local $/;
    my $content = <$fh>;
    close $fh;
    return (undef, "manifest '$path' is empty") unless defined $content && length $content;

    my @pins;
    for my $spec (@PIN_SPEC) {
        next unless $content =~ $spec->{pattern};
        push @pins, { package => $spec->{package}, policy => $spec->{policy}, pinned => $1 };
    }
    return (undef, "no recognizable version pins found in '$path'") unless @pins;
    return (\@pins, undef);
}

# ---- audit ------------------------------------------------------------------

# audit(\%opts) -> (\%report, $rc)
#   $rc is 2 if any pin shows genuine (confirmed) drift, else 0 -- NEVER
#   non-zero purely because a lookup degraded to "unknown" (spec b46 sec2,
#   C8's audit half).
sub audit {
    my ($opts) = @_;
    $opts ||= {};

    my $manifest = $opts->{manifest} // $DEFAULT_MANIFEST;
    my $min_age  = defined $opts->{min_age_days} ? $opts->{min_age_days} : $DEFAULT_MIN_AGE_DAYS;
    my $offline  = $opts->{offline} ? 1 : 0;

    my $now = eval { _resolve_now($opts) };
    if ($@) {
        (my $err = $@) =~ s/\s+$//;
        return ({ generated_at => undef, manifest => $manifest, rows => [],
                  error => "bad --now: $err" }, 0);
    }

    my ($pins, $perr) = _parse_pins($manifest);
    unless ($pins) {
        # Cannot even locate the pins -- degrade to WARN, exactly like every
        # other "I could not determine" path in this family. A missing/moved
        # manifest is not a safety condition.
        return ({ generated_at => BpDepsCheck::iso_of($now), manifest => $manifest, rows => [],
                  error => $perr }, 0);
    }

    my $http = _resolve_http($opts);
    my @rows;
    my $drift = 0;
    for my $p (@$pins) {
        if ($offline) {
            push @rows, { package => $p->{package}, pinned => $p->{pinned}, eligible => undef,
                          status => 'unknown',
                          detail => "$p->{package}: pinned $p->{pinned}, eligible-version drift-unknown (--offline)" };
            next;
        }
        my ($eligible, $cause, $detail) = resolve({
            policy => $p->{policy}, package => $p->{package}, min_age_days => $min_age,
            http => $http, now => $now,
        });
        if (!defined $eligible) {
            push @rows, { package => $p->{package}, pinned => $p->{pinned}, eligible => undef,
                          status => 'unknown',
                          detail => "$p->{package}: pinned $p->{pinned}, eligible-version drift-unknown/could not determine ($cause: $detail)" };
            next;
        }
        if (cmp_version($eligible, $p->{pinned}) > 0) {
            $drift = 1;
            push @rows, { package => $p->{package}, pinned => $p->{pinned}, eligible => $eligible,
                          status => 'drift',
                          detail => "$p->{package}: pinned $p->{pinned}, newest eligible $eligible -- DRIFT (warn, not blocking)" };
        } else {
            push @rows, { package => $p->{package}, pinned => $p->{pinned}, eligible => $eligible,
                          status => 'current',
                          detail => "$p->{package}: pinned $p->{pinned} is current (newest eligible $eligible)" };
        }
    }

    my %report = (generated_at => BpDepsCheck::iso_of($now), manifest => $manifest, rows => \@rows);
    return (\%report, $drift ? 2 : 0);
}

# ---- CLI --------------------------------------------------------------------

unless (caller) {
    my @args = @ARGV;
    my $mode = shift @args;

    my $usage = "usage: bp-pin.pl resolve --policy <p> --package <name> --min-age-days N\n"
              . "                         [--fetcher <path>] [--now <iso|epoch>]\n"
              . "       bp-pin.pl audit [--manifest <path>] [--now <iso|epoch>] [--offline]\n"
              . "                       [--fetcher <path>]\n";

    unless (defined $mode && ($mode eq 'resolve' || $mode eq 'audit')) {
        print STDERR $usage;
        exit 1;
    }

    my %opt;
    for (@args) {
        if    (/^--policy=(.+)$/)       { $opt{policy}        = $1 }
        elsif (/^--package=(.+)$/)      { $opt{package}       = $1 }
        elsif (/^--min-age-days=(.+)$/) { $opt{min_age_days}  = $1 }
        elsif (/^--fetcher=(.+)$/)      { $opt{fetcher_path}  = $1 }
        elsif (/^--now=(.+)$/)          { $opt{now}           = $1 }
        elsif (/^--manifest=(.+)$/)     { $opt{manifest}      = $1 }
        elsif ($_ eq '--offline')       { $opt{offline}       = 1 }
        # Support space-separated flags too (`--fetcher PATH`, not only `--fetcher=PATH`).
        elsif (/^--(policy|package|min-age-days|fetcher|now|manifest)$/) {
            my $name = $1;
            my $val  = shift @args;
            unless (defined $val) {
                print STDERR "bp-pin.pl: --$name requires a value\n$usage";
                exit 1;
            }
            (my $key = $name) =~ tr/-/_/;
            $key = 'fetcher_path' if $name eq 'fetcher';
            $opt{$key} = $val;
        }
        else {
            print STDERR "bp-pin.pl: unknown argument '$_'\n$usage";
            exit 1;
        }
    }

    if ($mode eq 'resolve') {
        for my $req (qw(policy package min_age_days)) {
            next if defined $opt{$req};
            (my $flag = "--$req") =~ tr/_/-/;
            print STDERR "bp-pin.pl resolve: $flag is required\n$usage";
            exit 1;
        }
        my ($version, $cause, $detail) = eval { resolve(\%opt) };
        if ($@) {
            (my $err = $@) =~ s/\s+$//;
            print STDERR "bp-pin.pl resolve: internal error: $err\n";
            exit 1;
        }
        unless (defined $version) {
            print STDERR "bp-pin.pl resolve: FAILED ($cause): $detail\n";
            exit 2;
        }
        print "$version\n";
        exit 0;
    }

    # audit
    my ($report, $rc) = eval { audit(\%opt) };
    if ($@) {
        (my $err = $@) =~ s/\s+$//;
        print STDERR "bp-pin.pl audit: internal error: $err\n";
        exit 1;
    }
    if (defined $report->{error}) {
        print "bp-pin.pl audit: $report->{error} (drift-unknown; not blocking)\n";
        exit 0;
    }
    for my $r (@{ $report->{rows} }) {
        print "$r->{detail}\n";
    }
    exit $rc;
}

1;
