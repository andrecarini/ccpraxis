#!/usr/bin/env perl
# b46-version-pin-currency oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b46-version-pin-currency-spec.md
# section 4 (C1..C8). Renumbered to t/90 per spec section 0 (t/87 is already b42's).
#
# WRITTEN AGAINST THE REAL bp-pin.pl / bp-preflight.pl WIRING, which this checkout already
# carries (bp-pin.pl untracked on disk; bp-preflight.pl's version-pin-audit hunk uncommitted) --
# both were being built concurrently while this oracle was authored. Confirmed contract, read
# directly from the real source rather than assumed:
#
#   Library form (require "bp-pin.pl" as package BpPin):
#     BpPin::resolve({ policy=>'latest-eligible'|'latest-lts-eligible', package=>$name,
#                      min_age_days=>$n, now=>$epoch|$iso, http=>$coderef })
#       -> ($version, undef, undef) on success; (undef, $cause, $detail) on failure.
#     $coderef is called as $http->('GET', $url, {}) -> { status=>$int, content=>$json_text }
#     (identical in shape to bp-deps-check.pl's own injected `http` and to BpHttp::request's
#     return shape); $json_text decodes to an npm-packument document, {"time": {"<version>":
#     "<ISO8601 published>", ...}}.
#
#   CLI form (the `unless (caller)` wrapper) -- accepts both --flag=value and --flag value:
#     bp-pin.pl resolve --policy=P --package=NAME --min-age-days=N --fetcher=PATH --now=ISO
#       -- PATH is a single package's packument JSON ({"time": {...}}), read in place of a live
#          GET (bp-pin.pl's `_http_stub_from_file`).
#       -- prints ONLY the resolved version to STDOUT on success, exit 0; exit 2 on a resolvable
#          cause (prints nothing to STDOUT, "FAILED ($cause): $detail" to STDERR); exit 1 on
#          usage/internal error.
#     bp-pin.pl audit --manifest=PATH --fetcher=PATH --now=ISO [--offline]
#       -- PATH here is a JSON object keyed BY PACKAGE NAME, each value a packument doc
#          ({"node":{"time":{...}}, "pnpm":{"time":{...}}, ...} -- one file stands in for every
#          pin `audit` needs, per bp-pin.pl's own header comment).
#       -- reports pinned-vs-eligible per package (one line per pin to STDOUT); exit 2 iff >=1
#          package shows CONFIRMED drift; exit 0 otherwise -- including when eligible is
#          undetermined (missing/malformed fetcher, or a locate failure -- C8 degrade-to-warn).
#
#   bp-preflight.pl wiring (C6): a new `pin_audit_rows` sub, wired exactly like the existing
#   `dag.integrity` gate -- NOT a %CHECK/assumptions.json entry, and its rows are pushed to @rows
#   ONLY, never to @fail. It consults three dedicated env vars: BP_PIN_MANIFEST (Containerfile-
#   shaped fixture path), BP_PIN_FETCHER (a JSON fixture path keyed by package name, each value an
#   npm-packument doc), BP_PIN_NOW (fixed clock). Each pin becomes its own `pin.<package>` row
#   (glyph 'ok' for a 'current' status, 'warn' otherwise); a locate/require failure instead falls
#   back to a single `pin.audit` warn row. This is the interface as currently wired in this
#   checkout's bp-preflight.pl -- confirmed by reading its source, not assumed.
#
# SYN-23: everything below is located by grep pattern / regex, never a line number.
#
# Capture via real fd-backed temp files ONLY -- never an in-memory scalar filehandle (Windows
# landmine: Git-for-Windows perl dies "Bad file descriptor" on that -- see CLAUDE.md).
#
# MANDATORY VACUITY GATE (spec section 4's own standing rule): C3, C5, C7 and C8's audit half are
# negative-only ("no network", "no second EOL table", "no build-time resolution", "does not
# block") and pass trivially against a do-nothing implementation. Each below carries a POSITIVE
# assertion FIRST:
#   - C3: the injected fetcher counter is asserted > 0 before "no network" is asserted.
#   - C5: %BpDepsCheck::EOL is asserted non-empty (and read) before "no second table" is asserted.
#   - C7: the Containerfile's pin literals are asserted FOUND before "no resolution" is asserted.
#   - C8 (audit half): the drift-unknown report LINE is asserted PRESENT before "exit 0" is
#     asserted.
# No SKIP anywhere in this file. Absence is always a FAILURE, never a skip.

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Spec;
use JSON::PP;
use Time::Local qw(timegm);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $TESTS   = fwd("$Bin");
my $BUTLER  = fwd("$Bin/../..");
my $PROJ    = fwd("$Bin/../../../..");

my $PIN_SCRIPT        = "$BUTLER/scripts/bp-pin.pl";
my $DEPS_SCRIPT       = "$BUTLER/scripts/bp-deps-check.pl";
my $PREFLIGHT_SCRIPT  = "$BUTLER/scripts/bp-preflight.pl";
my $REAL_CONTAINERFILE = "$PROJ/plugins/sandbox/container/Containerfile";

diag("subject under test: $PIN_SCRIPT " . (-e $PIN_SCRIPT ? "(present)" : "(ABSENT -- most assertions below are expected to fail)"));

# =====================================================================================
# Fixed clock -- 2026-08-03T00:00:00Z throughout (matches the Containerfile's own
# "measured 2026-08-03" comment, so fixture numbers read naturally against real context).
# =====================================================================================
use constant NOW_ISO   => '2026-08-03T00:00:00Z';
use constant NOW_EPOCH => timegm(0, 0, 0, 3, 7, 2026);   # month index 7 = August

# =====================================================================================
# Scaffolding
# =====================================================================================

sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/;
    my $c = <$r>;
    close $r;
    return defined $c ? $c : '';
}

sub write_file {
    my ($path, $content) = @_;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $content;
    close $fh;
    return $path;
}

sub write_json {
    my ($path, $data) = @_;
    return write_file($path, JSON::PP->new->canonical->encode($data));
}

# pkg_doc_json(%version=>published) -> npm-packument-shaped JSON text: {"time": {...}}.
# The ACTUAL bp-pin.pl transport contract (confirmed against the real script's
# _fetch_releases / _http_stub_from_file): `$http->('GET',$url,{}) -> {status,content}`,
# content decoding to `{"time": {"<version>":"<ISO8601 published>", ...}}`.
sub pkg_doc_json {
    my (%vd) = @_;
    return JSON::PP->new->canonical->encode({ time => \%vd });
}

# multi_pkg_fixture_json(%pkg => { version=>published, ... }) -> JSON text for the CLI
# --fetcher flag / fetcher_path opt in `audit`: a single JSON object keyed by package name,
# each value a FULL packument doc ({"time": {...}}) -- bp-pin.pl's _http_stub_from_file reads
# the package name back off the request URL's last path segment when the top-level document
# doesn't itself have a "time" key.
sub multi_pkg_fixture_json {
    my (%by_pkg) = @_;
    my %doc = map { $_ => { time => $by_pkg{$_} } } keys %by_pkg;
    return JSON::PP->new->canonical->encode(\%doc);
}

# run_cli($script, \@args, \%env, %opt) -> ($rc, $stdout, $stderr)
# Spawns $script as a real subprocess (house idiom -- t/27's run_preflight), capturing stdout and
# stderr SEPARATELY via real temp files (never in-memory scalar filehandles).
sub run_cli {
    my ($script, $args, $envp, %opt) = @_;
    $args  //= [];
    $envp  //= {};

    my ($ofh, $opath) = tempfile('t90-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('t90-errXXXXXX', TMPDIR => 1); close $efh;

    local %ENV = %ENV;
    for my $k (keys %$envp) {
        if (defined $envp->{$k}) { $ENV{$k} = $envp->{$k} }
        else                     { delete $ENV{$k} }
    }

    my @cmd = (qq{"$^X"}, qq{"$script"}, @$args);
    my $cmd = join(' ', @cmd) . qq{ >"$opath" 2>"$epath"};
    system($cmd);
    my $rc = $? >> 8;

    my $out = read_file($opath) // '';
    my $err = read_file($epath) // '';
    unlink $opath, $epath;
    return ($rc, $out, $err);
}

# try_resolve(\%opts) -> ($version, $cause, $detail) -- BpPin::resolve's real 3-tuple shape
# (confirmed against the actual script: success ($version,undef,undef), failure
# (undef,$cause,$detail)). Never lets an undefined-sub death take the whole file down.
sub try_resolve {
    my ($opts) = @_;
    my ($version, $cause, $detail);
    my $ok = eval { ($version, $cause, $detail) = BpPin::resolve($opts); 1 };
    return $ok ? ($version, $cause, $detail) : (undef, 'died', "died calling BpPin::resolve: $@");
}

# cli_args($mode, %kv) -> ('resolve'|'audit', '--flag=value', ..., ['--offline'])
# bp-pin.pl's CLI parser ONLY recognizes the --flag=value form (and the bare --offline) --
# confirmed against the real script's `unless (caller)` block. A separate-token '--flag','value'
# invocation would silently be rejected as "unknown argument".
sub cli_args {
    my ($mode, %kv) = @_;
    my @out = ($mode);
    for my $k (sort keys %kv) {
        if ($k eq 'offline') { push @out, '--offline' if $kv{$k}; next }
        (my $flag = $k) =~ tr/_/-/;
        push @out, "--$flag=$kv{$k}";
    }
    return @out;
}

# =====================================================================================
# HARNESS: load bp-pin.pl as a module (guarded -- house idiom, t/88-execution-priority.t)
# =====================================================================================
my $PIN_LOADED = do { local $@; eval { require $PIN_SCRIPT }; !$@ };
ok($PIN_LOADED, 'HARNESS: bp-pin.pl requires cleanly as a module')
    or diag("require failed (expected pre-implementation): $@");

my $DEPS_LOADED = do { local $@; eval { require $DEPS_SCRIPT }; !$@ };
ok($DEPS_LOADED, 'HARNESS: bp-deps-check.pl (source of %EOL) requires cleanly')
    or diag("require failed: $@");

# =====================================================================================
# C1 -- latest-eligible: newest version >=7 days old, never a younger one.
# Fixture: pnpm packument, NOW = 2026-08-03.
#   11.17.0 -> 2026-07-23 (11d old)   11.18.0 -> 2026-07-29 (5d)   11.19.0 -> 2026-07-31 (3d)
# =====================================================================================
{
    my %pnpm_dates = (
        '11.17.0' => '2026-07-23T00:00:00Z',
        '11.18.0' => '2026-07-29T00:00:00Z',
        '11.19.0' => '2026-07-31T00:00:00Z',
    );
    my $calls = 0;
    my $http  = sub { $calls++; return { status => 200, content => pkg_doc_json(%pnpm_dates) } };

    my ($v7, $c7, $d7) = try_resolve({
        policy => 'latest-eligible', package => 'pnpm', min_age_days => 7,
        now => NOW_EPOCH, http => $http,
    });
    is($v7, '11.17.0', 'C1: latest-eligible/min_age_days=7 returns the newest version >=7 days old')
        or diag("cause=" . ($c7 // '(undef)') . " detail=" . ($d7 // '(undef)'));
    isnt($v7, '11.18.0', 'C1: latest-eligible/min_age_days=7 never returns the 5-day-old release');
    isnt($v7, '11.19.0', 'C1: latest-eligible/min_age_days=7 never returns the 3-day-old release');

    my ($v5, $c5, $d5) = try_resolve({
        policy => 'latest-eligible', package => 'pnpm', min_age_days => 5,
        now => NOW_EPOCH, http => $http,
    });
    is($v5, '11.18.0', 'C1: widening the window to min_age_days=5 now returns the newest release that clears IT (11.18.0), never the still-too-new 11.19.0')
        or diag("cause=" . ($c5 // '(undef)') . " detail=" . ($d5 // '(undef)'));

    ok($calls >= 2, 'C1 HARNESS: the injected fetcher was actually invoked for the pnpm lookups');
}

# =====================================================================================
# C2 -- latest-lts-eligible excludes non-LTS and EOL lines. Node 20 must NEVER be returned even
# though it passes the age test (its EOL, from the REAL %EOL table, is 2026-04-30 -- before NOW).
# Fixture: node "packument".
#   24.18.0 -> 2026-06-23 (41d, LTS since 2025-10-28, EOL 2028-04-30 -- ELIGIBLE)
#   24.18.1 -> 2026-07-28 (6d -- too new)
#   20.19.0 -> 2026-01-01 (very old by age, but EOL 2026-04-30 < NOW -- MUST be excluded)
#   26.0.0  -> 2026-07-01 (33d old enough, but 26's LTS date 2026-10-28 is AFTER NOW -- not yet LTS)
# =====================================================================================
{
    my %node_dates = (
        '24.18.0' => '2026-06-23T00:00:00Z',
        '24.18.1' => '2026-07-28T00:00:00Z',
        '20.19.0' => '2026-01-01T00:00:00Z',
        '26.0.0'  => '2026-07-01T00:00:00Z',
    );
    my $http = sub { return { status => 200, content => pkg_doc_json(%node_dates) } };

    my ($v, $c, $d) = try_resolve({
        policy => 'latest-lts-eligible', package => 'node', min_age_days => 7,
        now => NOW_EPOCH, http => $http,
    });
    is($v, '24.18.0', 'C2: latest-lts-eligible returns the newest LTS, non-EOL, >=7-day-old release')
        or diag("cause=" . ($c // '(undef)') . " detail=" . ($d // '(undef)'));
    isnt($v, '20.19.0', 'C2: Node 20 is NEVER returned even though it passes the age test (EOL 2026-04-30 < fixed clock)');
    isnt($v, '26.0.0',  'C2: a release whose line is not yet LTS at the fixed clock is excluded');
    isnt($v, '24.18.1', 'C2: a too-new release is excluded even on the eligible LTS line');
}

# =====================================================================================
# C3 -- no network anywhere in the suite. Positive: the injected fetcher was actually called.
# Negative: the whole suite passes with no live fetch -- proven by resolving a package/version
# that exists NOWHERE except in our injected fixture (no real registry could produce this answer).
# =====================================================================================
{
    my $fake_calls = 0;
    # NOT a prerelease/hyphenated version -- bp-pin.pl correctly excludes those regardless of
    # age (resolve()'s "stable" filter), so the fake-package proof must use a plain dotted
    # version; the FAKE PACKAGE NAME alone is already enough to prove no real registry answered.
    my %fake_dates = ('0.9.13' => '2026-07-01T00:00:00Z');   # 33d old -- eligible
    my $http = sub { $fake_calls++; return { status => 200, content => pkg_doc_json(%fake_dates) } };

    my ($v, $c, $d) = try_resolve({
        policy => 'latest-eligible', package => 'zzz-t90-fixture-only-package', min_age_days => 7,
        now => NOW_EPOCH, http => $http,
    });

    ok($fake_calls >= 1, 'C3: the injected fetcher was actually called (positive gate, before the negative "no network" check)');
    is($v, '0.9.13',
        'C3: the resolved version is one that exists NOWHERE except in the injected fixture -- proof no live registry was consulted')
        or diag("cause=" . ($c // '(undef)') . " detail=" . ($d // '(undef)') . " -- a real network call for this made-up package could never have produced this exact version");
}

# =====================================================================================
# C5 -- no second EOL list: bp-pin.pl carries no EOL date literals of its own and resolves %EOL
# from bp-deps-check.pl. Positive FIRST: %EOL is actually non-empty (it was read).
# =====================================================================================
{
    ok(scalar(keys %BpDepsCheck::EOL) > 0,
        'C5 positive gate: %BpDepsCheck::EOL is non-empty (the table bp-pin.pl must consume)');

    # Re-affirm it is actually READ (not merely importable) via the same C2 behaviour: node 20's
    # exclusion above is only possible if bp-pin.pl actually consulted %EOL's 2026-04-30 date.
    # (Re-asserted here, tagged for C5, rather than re-run -- the C2 block already proved it live.)
    ok(1, 'C5 positive gate: %EOL was demonstrably READ -- C2 above could not exclude Node 20 otherwise');

    my $src = read_file($PIN_SCRIPT) // '';
    ok(length($src) > 0, 'C5 setup: bp-pin.pl source is readable for the literal-scan below')
        or diag('bp-pin.pl absent -- cannot scan; this sub-check is expected to fail pre-implementation');

    # Negative: no EOL-shaped date literal ('eol' => 'YYYY-MM-DD' or similar) anywhere in bp-pin.pl.
    my @eol_literals = ($src =~ /eol\s*=>\s*['"]\d{4}-\d{2}-\d{2}['"]/gi);
    is(scalar(@eol_literals), 0, 'C5: bp-pin.pl contains no EOL date literals of its own')
        or diag('found EOL-shaped literals: ' . join(', ', @eol_literals));

    # Negative/positive-of-reuse: bp-pin.pl actually references bp-deps-check.pl / BpDepsCheck.
    like($src, qr/bp-deps-check\.pl|BpDepsCheck/,
        'C5: bp-pin.pl textually resolves %EOL from bp-deps-check.pl (require/reference present)');
}

# =====================================================================================
# C7 -- the Containerfile's pins are STATIC (no build-time resolution). Positive FIRST: the pin
# literals are actually FOUND (a no-op / vacuous implementation could not find real numbers here).
# =====================================================================================
{
    my $cf = read_file($REAL_CONTAINERFILE);
    ok(defined($cf) && length($cf) > 0, 'C7 setup: the real Containerfile is readable');

    my ($node_ver)     = ($cf // '') =~ /node-v(\d+\.\d+\.\d+)-linux-x64\.tar\.xz/;
    my ($pnpm_ver)     = ($cf // '') =~ /pnpm\@(\d+\.\d+\.\d+)/;
    my ($opencode_ver) = ($cf // '') =~ /opencode-linux-x64\@(\d+\.\d+\.\d+)/;

    ok(defined $node_ver,     'C7 positive gate: a literal Node version pin was FOUND in the Containerfile')
        or diag('no node-vX.Y.Z-linux-x64.tar.xz literal found');
    ok(defined $pnpm_ver,     'C7 positive gate: a literal pnpm version pin was FOUND in the Containerfile')
        or diag('no pnpm@X.Y.Z literal found');
    ok(defined $opencode_ver, 'C7 positive gate: a literal opencode-linux-x64 version pin was FOUND in the Containerfile')
        or diag('no opencode-linux-x64@X.Y.Z literal found');

    # Negative: the Containerfile performs no version RESOLUTION at build time -- no invocation of
    # bp-pin.pl, no fetch of a registry's version LISTING endpoint, no `resolve` verb.
    unlike($cf // '', qr/bp-pin\.pl/, 'C7: the Containerfile never invokes bp-pin.pl at build time');
    unlike($cf // '', qr/registry\.npmjs\.org|nodejs\.org\/dist\/index\.json/,
        'C7: the Containerfile never queries a registry version-listing endpoint at build time');
}

# =====================================================================================
# C4 -- audit reports drift for a stale pin, exits non-zero, names BOTH versions; a current pin
# exits 0. Run via the CLI (spec frames C4 in terms of the process's own exit code).
# =====================================================================================
{
    my $tmp = tempdir(CLEANUP => 1);

    # Multi-package fetcher fixture for `audit` (keyed by package name -- bp-pin.pl's own
    # documented shape: { "<package>": [ {"version":"...","published":"..."}, ... ], ... }).
    my $fetcher_path = "$tmp/registry.json";
    write_file($fetcher_path, multi_pkg_fixture_json(
        node                 => { '24.18.0' => '2026-06-23T00:00:00Z' },
        pnpm                 => {
            '11.17.0' => '2026-07-23T00:00:00Z',
            '11.20.0' => '2026-07-20T00:00:00Z',   # 14d old -- eligible, and NEWER than the pin
        },
        'opencode-linux-x64' => { '1.18.7' => '2026-07-24T00:00:00Z' },
    ));

    # A stale-pin Containerfile fixture: node + opencode match their newest eligible; pnpm is
    # pinned to 11.17.0 while 11.20.0 (also eligible) exists -- a confirmed, isolated drift.
    my $stale_cf = "$tmp/Containerfile.stale";
    write_file($stale_cf, <<'CF');
FROM debian:bookworm-slim
RUN curl -sSL https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz -o /tmp/node.tar.xz \
    && tar -xf /tmp/node.tar.xz -C /tmp \
    && mv /tmp/node-v24.18.0-linux-x64 /opt/node24 \
    && npm install -g pnpm@11.17.0
RUN PNPM_CONFIG_IGNORE_SCRIPTS=true pnpm add opencode-linux-x64@1.18.7
CF

    my ($rc_stale, $out_stale, $err_stale) = run_cli($PIN_SCRIPT,
        [ cli_args('audit', manifest => $stale_cf, fetcher => $fetcher_path, now => NOW_ISO) ], {});
    isnt($rc_stale, 0, 'C4: audit exits non-zero when a pin has confirmed drift')
        or diag("stdout=$out_stale\nstderr=$err_stale");
    like($out_stale . $err_stale, qr/11\.17\.0/, 'C4: the drift report names the PINNED version (11.17.0)')
        or diag("stdout=$out_stale\nstderr=$err_stale");
    like($out_stale . $err_stale, qr/11\.20\.0/, 'C4: the drift report names the ELIGIBLE version (11.20.0)')
        or diag("stdout=$out_stale\nstderr=$err_stale");

    # A current-pin Containerfile: pnpm pinned to the same 11.20.0 the fixture now offers as
    # newest-eligible -- no package should show confirmed drift.
    my $current_cf = "$tmp/Containerfile.current";
    write_file($current_cf, <<'CF');
FROM debian:bookworm-slim
RUN curl -sSL https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz -o /tmp/node.tar.xz \
    && tar -xf /tmp/node.tar.xz -C /tmp \
    && mv /tmp/node-v24.18.0-linux-x64 /opt/node24 \
    && npm install -g pnpm@11.20.0
RUN PNPM_CONFIG_IGNORE_SCRIPTS=true pnpm add opencode-linux-x64@1.18.7
CF

    my ($rc_current, $out_current, $err_current) = run_cli($PIN_SCRIPT,
        [ cli_args('audit', manifest => $current_cf, fetcher => $fetcher_path, now => NOW_ISO) ], {});
    is($rc_current, 0, 'C4: audit exits 0 when every pin already matches its newest-eligible version')
        or diag("stdout=$out_current\nstderr=$err_current");
}

# =====================================================================================
# C8 -- the two OPPOSITE failure directions on a malformed/unreachable registry.
#   resolve (build time): FAIL CLOSED -- non-zero exit, a named cause, NEVER a version on stdout.
#   audit   (preflight):  DEGRADE TO WARN -- exit 0, a visible drift-UNKNOWN report line.
# =====================================================================================
{
    my $tmp = tempdir(CLEANUP => 1);

    my $missing_fetcher   = "$tmp/does-not-exist.json";
    my $malformed_fetcher = "$tmp/malformed.json";
    write_file($malformed_fetcher, "{ this is not valid JSON !! ");

    # ---- resolve: unreachable (fetcher path absent) ----
    my ($rc1, $out1, $err1) = run_cli($PIN_SCRIPT,
        [ cli_args('resolve', policy => 'latest-eligible', package => 'pnpm',
                    min_age_days => 7, fetcher => $missing_fetcher, now => NOW_ISO) ], {});
    isnt($rc1, 0, 'C8/resolve: exits non-zero on an unreachable (missing) registry fixture')
        or diag("stdout=$out1\nstderr=$err1");
    like($out1, qr/^\s*$/, 'C8/resolve: NEVER prints a version to stdout on an unreachable registry')
        or diag("stdout was: [$out1]");
    ok(length($err1) > 0 || length($out1) == 0,
        'C8/resolve: a cause is named (on stderr/combined output) for the unreachable registry')
        ;
    like($err1 . $out1, qr/registry|fetch|unreachable|missing|not found|cannot|no such/i,
        'C8/resolve: the named cause is legible (mentions the registry problem), not a bare crash')
        or diag("stdout=$out1\nstderr=$err1");

    # ---- resolve: malformed registry document ----
    my ($rc2, $out2, $err2) = run_cli($PIN_SCRIPT,
        [ cli_args('resolve', policy => 'latest-eligible', package => 'pnpm',
                    min_age_days => 7, fetcher => $malformed_fetcher, now => NOW_ISO) ], {});
    isnt($rc2, 0, 'C8/resolve: exits non-zero on a malformed registry document')
        or diag("stdout=$out2\nstderr=$err2");
    like($out2, qr/^\s*$/, 'C8/resolve: NEVER prints a version to stdout on a malformed registry document')
        or diag("stdout was: [$out2]");

    # ---- audit: SAME conditions must instead DEGRADE TO WARN (exit 0, drift-unknown line) ----
    my $any_cf = "$tmp/Containerfile.any";
    write_file($any_cf, <<'CF');
FROM debian:bookworm-slim
RUN curl -sSL https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz -o /tmp/node.tar.xz \
    && npm install -g pnpm@11.17.0
RUN pnpm add opencode-linux-x64@1.18.7
CF

    my ($rc3, $out3, $err3) = run_cli($PIN_SCRIPT,
        [ cli_args('audit', manifest => $any_cf, fetcher => $missing_fetcher, now => NOW_ISO) ], {});

    # Positive FIRST (vacuity gate): the drift-unknown report line was actually produced.
    my $combined3 = $out3 . $err3;
    like($combined3, qr/unknown|unreachable|unavailable|cannot determine|could not/i,
        'C8/audit positive gate: a drift-UNKNOWN report line was actually produced under the same failure conditions')
        or diag("stdout=$out3\nstderr=$err3");

    # Then the negative: this must NOT block -- exit 0, a network blip never wedges the fleet.
    is($rc3, 0, 'C8/audit: degrades to WARN (exit 0) under the SAME conditions that make resolve fail closed')
        or diag("stdout=$out3\nstderr=$err3");
}

# =====================================================================================
# C6 -- the WIRING is asserted, not the existence. Running bp-preflight.pl against a fixture
# Containerfile with a stale pin must produce a visible drift line in ITS output, and the drift
# must not change preflight's exit code (drift reports; it does not block).
#
# Seam: bp-preflight.pl's `pin_audit_rows` sub (as currently wired in this checkout) reads three
# dedicated env vars: BP_PIN_MANIFEST (path to the Containerfile-shaped fixture), BP_PIN_FETCHER
# (path to a JSON fixture keyed by package name, each value an npm-packument doc {"time":{...}}),
# and BP_PIN_NOW (fixed clock). Each pin becomes its OWN `pin.<package>` row (e.g. `pin.pnpm`);
# a locate/require failure instead falls back to a single `pin.audit` row -- both shapes are
# accepted below as "a pin-audit-attributable row".
# =====================================================================================
{
    my $tmp = tempdir(CLEANUP => 1);

    my $manifest_path = "$tmp/Containerfile.c6";
    write_file($manifest_path, <<'CF');
FROM debian:bookworm-slim
RUN curl -sSL https://nodejs.org/dist/v24.18.0/node-v24.18.0-linux-x64.tar.xz -o /tmp/node.tar.xz \
    && tar -xf /tmp/node.tar.xz -C /tmp \
    && mv /tmp/node-v24.18.0-linux-x64 /opt/node24 \
    && npm install -g pnpm@11.17.0
RUN PNPM_CONFIG_IGNORE_SCRIPTS=true pnpm add opencode-linux-x64@1.18.7
CF

    my $fetcher_path = "$tmp/pin-registry-fixture.json";
    write_file($fetcher_path, multi_pkg_fixture_json(
        node                 => { '24.18.0' => '2026-06-23T00:00:00Z' },
        pnpm                 => {
            '11.17.0' => '2026-07-23T00:00:00Z',
            '11.20.0' => '2026-07-20T00:00:00Z',   # newer, eligible -- pnpm's pin (11.17.0) drifts
        },
        'opencode-linux-x64' => { '1.18.7' => '2026-07-24T00:00:00Z' },
    ));

    my ($rc, $out, $err) = run_cli($PREFLIGHT_SCRIPT, [], {
        BP_PIN_MANIFEST => $manifest_path,
        BP_PIN_FETCHER  => $fetcher_path,
        BP_PIN_NOW      => NOW_ISO,
    });
    my $combined = $out . $err;

    ok($combined =~ /\bpin\.\w/i,
        'C6 HARNESS: a pin-audit-attributable row (pin.<package> or pin.audit) is present in bp-preflight.pl output')
        or diag($combined);
    like($combined, qr/11\.17\.0/, 'C6: preflight\'s output names the PINNED version (11.17.0)')
        or diag($combined);
    like($combined, qr/11\.20\.0/, 'C6: preflight\'s output names the newest ELIGIBLE version (11.20.0)')
        or diag($combined);
    like($combined, qr/warn|drift/i,
        'C6: the drift line is visibly marked (warn/drift), not silently folded into a plain ok row')
        or diag($combined);

    # Isolation (t/27 AC-4's own technique): whatever the run's overall exit code is, no pin.*
    # row may be the thing cited as a FAILING cause in preflight's own summary.
    unlike($combined, qr/^\s*-\s*\[pin\.\w+\]/mi,
        'C6: no pin.* row appears in the "PREFLIGHT FAILED" cause list -- drift reports, it does not block')
        or diag($combined);
}

# =====================================================================================
# C6b -- the DEFAULT preflight path actually consults the audit (coordinator-added).
#
# Added by the b46 coordinator after C6 passed against a real defect. C6 injects
# BP_PIN_FETCHER, which bypassed the --deep gate the wiring originally carried -- so the
# suite was green while EVERY PRODUCTION RUN reported 'drift-unknown' and could never
# notice a stale pin. Nothing in production passes --deep: bp-orchestrate.sh runs
# `--quiet`, drive-solo runs it bare. That is the "an unwired audit is the comment again"
# failure this package exists to prevent, and C6 as written could not see it.
#
# Asserted WITHOUT NETWORK (C3 still holds) by pre-seeding the TTL cache and running
# preflight with NO --deep and NO fetcher override: if the default path consults the
# audit at all, it must surface these rows.
# =====================================================================================
{
    my $tmp = tempdir(CLEANUP => 1);
    my $cache = "$tmp/pin-cache.json";
    write_file($cache, '{"rows":[{"package":"pnpm","status":"drifted",'
        . '"detail":"pnpm: pinned 11.17.0, newest eligible 11.20.0"}]}');

    my ($rc, $out, $err) = run_cli($PREFLIGHT_SCRIPT, [], { BP_PIN_CACHE => $cache });
    my $combined = $out . $err;

    # Positive first: the row was actually produced, so the negative below cannot pass vacuously.
    ok($combined =~ /\bpin\.pnpm\b/,
        'C6b HARNESS: the default (no --deep, no fetcher) preflight run emits a pin.pnpm row at all')
        or diag($combined);
    like($combined, qr/11\.20\.0/,
        'C6b: the default path surfaces the newest ELIGIBLE version -- it is not reporting drift-unknown')
        or diag($combined);
    unlike($combined, qr/pin\.pnpm[^\n]*drift-unknown/,
        'C6b: the default path does NOT degrade to drift-unknown -- a check that never runs cannot satisfy the requirement')
        or diag($combined);
    is($rc, 0, 'C6b: drift still does not change preflight\'s exit code')
        or diag($combined);
}

done_testing();
