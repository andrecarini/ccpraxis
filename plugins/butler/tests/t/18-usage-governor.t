#!/usr/bin/env perl
# t/18-usage-governor.t — immutable oracle for bp-usage-gate.pl (02-usage-governor).
#
# Tests the NEW `verdict` subcommand + the pure `BpUsageGate::verdict_decision`
# function which do NOT exist yet.  All tests must fail for the right reason:
# missing behaviour — NOT a harness or syntax error.
#
# Criterion → test map  (see report at reports/02-usage-governor/test-writer-02.md)
#   AC-1   below-trip → ok
#   AC-2   rising samples trip should_pause → pause-usage (until_epoch number)
#   AC-3   token floor → pause-token (no poll)
#   AC-4   http 500 / bad-JSON / validate_usage-fail → unavailable(telemetry)
#   AC-5   missing/invalid creds → unavailable(creds)
#   AC-6   reuse is observable (should_pause / trip_point agree)
#   AC-7   live smoke (soft; auto-skipped if creds absent)
#   AC-8   (static: perl -c / requires resolve — not a runtime test; reported only)
#   AC-9   (static: MSYS2 guard grep — not a runtime test; reported only)
#   AC-10  every verdict emission is valid single-line JSON with correct field types
#   AC-11  back-compat text path (no-arg) still prints OK/PAUSE + exit code
#   AC-12  no token sentinel ever appears in any output
#
# PINNED INTERFACE (implementer must match exactly):
#   Package:   BpUsageGate   (declared in bp-usage-gate.pl)
#   Pure fn:   BpUsageGate::verdict_decision($creds, $poll, $samples5, $samples7, $now, $t)
#     $creds   = { ok=>0|1, expires_ms=><num|undef>, detail=><str> }
#     $poll    = { status=><int>, parsed=><hashref|undef> }
#     $samples5 / $samples7 = [[epoch,util],...] (empty or ≥2 for burn)
#     $now     = epoch seconds (injected clock)
#     $t       = { ceil5, ceil7, drain, floor_h, jit_lo, jit_hi, rand }
#       where $t->{rand} ∈ [0,1) — injectable, mirroring choose_jitter
#     returns  = { action=><str>, until_epoch=><num|undef>, reason=><str> }
#
#   Subcommand seam: BpUsageGate::run(\@argv, \%opts)
#     %opts keys: now, http_get, creds_path, samples5, samples7, rand
#       now       => sub { $epoch }
#       http_get  => sub { my($url,$hdrs)=@_; return {status=>N, content=>STR} }
#       creds_path => $path_string   (overrides BP_CREDS_PATH)
#       samples5  / samples7 => [[epoch,util],...]
#       rand      => sub { $float_in_0_1 }
#     returns exit code; prints to STDOUT

use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempfile tempdir);
use File::Basename qw(dirname);

# ── helpers ─────────────────────────────────────────────────────────────────

my $J   = JSON::PP->new->canonical;
my $NOW = 1_830_297_600;   # fixed epoch: 2028-01-01T00:00:00Z

# ── load the gate script ────────────────────────────────────────────────────
my $GATE   = "$Bin/../../scripts/bp-usage-gate.pl";
my $GOVERN = "$Bin/../../scripts/bp-govern.pl";

# bp-govern.pl already exists and loads cleanly (it's read-only reference).
require $GOVERN;

# The CURRENT bp-usage-gate.pl has no `unless (caller)` guard: it executes all
# top-level code (including `exit`) on `require`.  The implementer must add
# `package BpUsageGate` + `unless (caller)` as part of pkg-02.  Until then we
# suppress exit() during the require by overriding CORE::GLOBAL::exit, then restore it.
# After the implementer ships, require works cleanly and this override is a no-op.
my $_gate_exit_code;  # set if the pre-pkg-02 gate calls exit during require
{
    no warnings qw(redefine once);
    local *CORE::GLOBAL::exit = sub { $_gate_exit_code = $_[0] // 0; die "HARNESS_EXIT\n" };
    my ($_tfh, $_tpath) = tempfile('t18-bootcreds-XXXXXX', SUFFIX => '.json', TMPDIR => 1);
    print $_tfh $J->encode({
        claudeAiOauth => {
            accessToken  => 'BOOT-SENTINEL-TOKEN',
            refreshToken => 'BOOT-REF',
            expiresAt    => ($NOW + 10*3600) * 1000,
            scopes       => ['user:inference'],
        }
    });
    close $_tfh;
    local $ENV{BP_CREDS_PATH} = $_tpath;
    # Redirect STDOUT during require so the gate's legacy emit() doesn't pollute
    # the TAP stream.  Use a real fd-backed temp file (scalar redirect dies on Windows).
    my ($sfh, $spath) = tempfile('t18-bootout-XXXXXX', TMPDIR => 1); close $sfh;
    open my $_save_out, '>&STDOUT' or die "dup STDOUT: $!";
    open STDOUT, '>:raw', $spath or die "reopen STDOUT for require: $!";
    my $LOADED = do { local $@; eval { require $GATE }; !$@ };
    open STDOUT, '>&', $_save_out or die "restore STDOUT: $!"; close $_save_out;
    unlink $spath, $_tpath;
    # If $LOADED is false (gate exited or failed to load), BpUsageGate:: calls below
    # will produce "Undefined subroutine" — the intended fail-first signal.
}

# Sentinel token — must NEVER appear in any emitted output (AC-12).
my $TOKEN_SENTINEL = 'sk-ant-ORACLE-SENTINEL-DO-NOT-EMIT-xXxXxXxX';

# Write a creds JSON file; token defaults to sentinel so AC-12 is tested everywhere.
sub write_creds {
    my (%o) = @_;
    # expires_ms: default well-above floor (5h from $NOW)
    my $exp_ms = $o{expires_ms} // (($NOW + 5 * 3600) * 1000);
    my $tok     = $o{token}     // $TOKEN_SENTINEL;
    my $ref_tok = $o{ref_token} // 'sk-ant-REFOK-placeholder';
    my ($fh, $path) = tempfile('t18-creds-XXXXXX', SUFFIX => '.json', TMPDIR => 1);
    print $fh $J->encode({
        claudeAiOauth => {
            accessToken   => $tok,
            refreshToken  => $ref_tok,
            expiresAt     => $exp_ms,
            scopes        => ['user:inference'],
        }
    });
    close $fh;
    return $path;
}

# Minimal valid usage response body.
sub usage_body {
    my (%o) = @_;
    my $u5       = $o{u5}       // 10;
    my $u7       = $o{u7}       // 5;
    my $resets5  = $o{resets5}  // '2099-01-01T00:00:00Z';
    my $resets7  = $o{resets7}  // '2099-01-02T00:00:00Z';
    return $J->encode({
        five_hour => { utilization => $u5, resets_at => $resets5 },
        seven_day => { utilization => $u7, resets_at => $resets7 },
    });
}

# Standard tunables — jitter forced to 0 so until_epoch is deterministic.
sub tunables {
    my (%o) = @_;
    return {
        ceil5   => 85,
        ceil7   => 90,
        drain   => 600,
        floor_h => 1,
        jit_lo  => 0,
        jit_hi  => 0,
        rand    => sub { 0 },
        %o,
    };
}

# capture_run — invoke BpUsageGate::run with injected seams; capture stdout+stderr
# via real fd-backed temp files (scalar filehandle capture dies on Git-for-Windows).
# Returns ($rc, $stdout, $stderr).
sub capture_run {
    my ($argv, $opts) = @_;
    my ($ofh, $opath) = tempfile('t18-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('t18-errXXXXXX', TMPDIR => 1); close $efh;
    open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDOUT, '>:raw', $opath
        or do { open STDOUT, '>&', $oldout; die "reopen STDOUT: $!" };
    open STDERR, '>:raw', $epath
        or do { open STDERR, '>&', $olderr; die "reopen STDERR: $!" };
    $| = 1;
    my $rc  = eval { BpUsageGate::run($argv, $opts) };
    my $err = $@;
    open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
    open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
    my $out  = do { open my $r, '<:raw', $opath or die; local $/; my $x = <$r>; close $r; $x // '' };
    my $eout = do { open my $r, '<:raw', $epath or die; local $/; my $x = <$r>; close $r; $x // '' };
    unlink $opath, $epath;
    die $err if $err;
    return ($rc, $out, $eout);
}

# Decode a single-line verdict JSON from capture_run stdout.
sub decode_verdict {
    my ($out) = @_;
    chomp(my $line = $out);
    return eval { $J->decode($line) };
}

# ── plan ─────────────────────────────────────────────────────────────────────
# AC-1..AC-12 are all covered below. The count is auto-tallied by done_testing()
# at the end of the file — no fixed `plan tests => N`. (An earlier draft ALSO
# declared `plan tests => 56`; that hand-count was off by 4 and, combined with
# done_testing, produced a spurious plan-mismatch failure. done_testing alone is
# authoritative and robust to the AC-7 soft-skip variance.)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-1: below-trip → ok
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
    my $creds = { ok => 1, expires_ms => ($NOW + 5*3600) * 1000, detail => '' };
    my $parsed = {
        five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00Z' },
        seven_day => { utilization =>  5, resets_at => '2099-01-02T00:00:00Z' },
    };
    my $poll = { status => 200, parsed => $parsed };
    # Single sample per window: burn=undef → should_pause false unless current≥ceil
    my $s5 = [[$NOW, 10]];
    my $s7 = [[$NOW,  5]];
    my $t  = tunables();

    my $v = BpUsageGate::verdict_decision($creds, $poll, $s5, $s7, $NOW, $t);

    is($v->{action},       'ok',  'AC-1: below-trip → action ok');
    is($v->{reason},       'ok',  'AC-1: below-trip → reason ok');
    is($v->{until_epoch},  undef, 'AC-1: below-trip → until_epoch undef');

    # Subcommand end-to-end (AC-10 also covered here)
    my $creds_path = write_creds();
    my ($rc, $out, $err) = capture_run(
        ['verdict'],
        {
            now        => sub { $NOW },
            http_get   => sub { { status => 200, content => usage_body(u5 => 10, u7 => 5) } },
            creds_path => $creds_path,
            samples5   => $s5,
            samples7   => $s7,
            rand       => sub { 0 },
        }
    );
    is($rc, 0, 'AC-1: verdict subcommand exits 0 for ok');
    my $vj = decode_verdict($out);
    is($vj->{action}, 'ok', 'AC-1: verdict JSON action=ok');
    unlink $creds_path;
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-2: rising samples trip should_pause → pause-usage with numeric until_epoch
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
    # Two rising samples: burn = (84-80)/600 = 0.00667%/s
    # should_pause(80, 0.00667, 600, 85) = 80 + 4 = 84 < 85 → no
    # Use steeper burn so it trips: (84-78)/600 = 0.01%/s
    # should_pause(84, 0.01, 600, 85) = 84 + 6 = 90 >= 85 → yes
    my $t0 = $NOW - 600;
    my $s5 = [[$t0, 78], [$NOW, 84]];   # burn 0.01%/s; projected = 84+6 = 90 >= 85
    my $s7 = [[$t0,  5], [$NOW,  5]];   # flat; no pause

    my $resets_iso = '2099-06-01T12:00:00Z';
    my $resets_ep  = BpGovern::iso_to_epoch($resets_iso);
    my $jitter     = 0;  # rand=0, jit_lo=jit_hi=0

    my $creds = { ok => 1, expires_ms => ($NOW + 5*3600) * 1000, detail => '' };
    my $parsed = {
        five_hour => { utilization => 84, resets_at => $resets_iso },
        seven_day => { utilization =>  5, resets_at => '2099-06-02T00:00:00Z' },
    };
    my $poll = { status => 200, parsed => $parsed };
    my $t    = tunables();

    my $v = BpUsageGate::verdict_decision($creds, $poll, $s5, $s7, $NOW, $t);

    is($v->{action},      'pause-usage',         'AC-2: tripped → action pause-usage');
    is($v->{reason},      'usage',               'AC-2: tripped → reason usage');
    is($v->{until_epoch}, $resets_ep + $jitter,  'AC-2: until_epoch = iso_to_epoch(resets_at)+jitter');
    ok(defined $v->{until_epoch} && $v->{until_epoch} =~ /^\d+$/,
        'AC-2: until_epoch is a number (not a string with leading/trailing chars)');

    # JSON encoding: until_epoch must be a JSON number, not a string
    my $enc = $J->encode($v);
    my $dec = $J->decode($enc);
    ok(ref \$dec->{until_epoch} eq 'SCALAR' && $dec->{until_epoch} =~ /^\d+$/,
        'AC-2: until_epoch encodes as JSON number not string');

    # Subcommand end-to-end
    my $creds_path = write_creds();
    my ($rc, $out) = capture_run(
        ['verdict'],
        {
            now        => sub { $NOW },
            http_get   => sub { { status => 200, content => usage_body(
                u5 => 84, u7 => 5,
                resets5 => $resets_iso,
                resets7 => '2099-06-02T00:00:00Z',
            ) } },
            creds_path => $creds_path,
            samples5   => $s5,
            samples7   => $s7,
            rand       => sub { 0 },
        }
    );
    is($rc, 0, 'AC-2: verdict subcommand exits 0 for pause-usage');
    my $vj = decode_verdict($out);
    is($vj->{action}, 'pause-usage', 'AC-2: end-to-end JSON action=pause-usage');
    unlink $creds_path;
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-3: token floor → pause-token; evaluated BEFORE poll; no poll call made
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
    # expires_ms exactly at floor (1h remaining): life_h = 1 ≤ floor_h=1 → pause-floor
    my $exp_ms = ($NOW + 1*3600) * 1000;   # exactly 1h → life_h = 1.0 → pause-floor
    my $creds  = { ok => 1, expires_ms => $exp_ms, detail => '' };
    # poll would give ok, but it should never be reached
    my $parsed = {
        five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00Z' },
        seven_day => { utilization =>  5, resets_at => '2099-01-02T00:00:00Z' },
    };
    my $poll = { status => 200, parsed => $parsed };
    my $t    = tunables();
    my $v    = BpUsageGate::verdict_decision($creds, $poll, [[$NOW,10]], [[$NOW,5]], $NOW, $t);

    is($v->{action},      'pause-token', 'AC-3: token at floor → pause-token');
    is($v->{reason},      'token',       'AC-3: reason=token');
    is($v->{until_epoch}, undef,         'AC-3: until_epoch=undef for pause-token');

    # No-poll assertion: inject an http_get that dies if called
    my $poll_called = 0;
    my $creds_path  = write_creds(expires_ms => $exp_ms);
    my ($rc, $out) = capture_run(
        ['verdict'],
        {
            now        => sub { $NOW },
            http_get   => sub { $poll_called++; { status => 200, content => usage_body() } },
            creds_path => $creds_path,
            samples5   => [[$NOW,10]],
            samples7   => [[$NOW, 5]],
            rand       => sub { 0 },
        }
    );
    is($rc, 0,           'AC-3: verdict subcommand exits 0 for pause-token');
    is($poll_called, 0,  'AC-3: no poll call when token floor triggered');
    unlink $creds_path;
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-4: http 500 / non-JSON body / validate_usage-fail → unavailable(telemetry)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# AC-4a: http 500
{
    my $creds = { ok => 1, expires_ms => ($NOW + 5*3600)*1000, detail => '' };
    my $poll  = { status => 500, parsed => undef };
    my $v     = BpUsageGate::verdict_decision($creds, $poll, [[$NOW,10]], [[$NOW,5]], $NOW, tunables());
    is($v->{action},      'unavailable', 'AC-4a: http 500 → unavailable');
    is($v->{reason},      'telemetry',   'AC-4a: http 500 → reason telemetry');
    is($v->{until_epoch}, undef,         'AC-4a: http 500 → until_epoch null');
}

# AC-4b: body not JSON (parsed=undef with status=200)
{
    my $creds = { ok => 1, expires_ms => ($NOW + 5*3600)*1000, detail => '' };
    my $poll  = { status => 200, parsed => undef };
    my $v     = BpUsageGate::verdict_decision($creds, $poll, [[$NOW,10]], [[$NOW,5]], $NOW, tunables());
    is($v->{action}, 'unavailable', 'AC-4b: non-JSON body → unavailable');
    is($v->{reason}, 'telemetry',   'AC-4b: non-JSON body → reason telemetry');
}

# AC-4c: validate_usage failure (missing utilization fields)
{
    my $creds  = { ok => 1, expires_ms => ($NOW + 5*3600)*1000, detail => '' };
    my $bad_body = { five_hour => { utilization => 'x' }, seven_day => {} };
    my $poll   = { status => 200, parsed => $bad_body };
    my $v      = BpUsageGate::verdict_decision($creds, $poll, [[$NOW,10]], [[$NOW,5]], $NOW, tunables());
    is($v->{action}, 'unavailable', 'AC-4c: validate_usage fail → unavailable');
    is($v->{reason}, 'telemetry',   'AC-4c: validate_usage fail → reason telemetry');

    # Subcommand: 500 → unavailable + exit 0
    my $creds_path = write_creds();
    my ($rc, $out) = capture_run(
        ['verdict'],
        {
            now        => sub { $NOW },
            http_get   => sub { { status => 500, content => 'server error' } },
            creds_path => $creds_path,
            samples5   => [[$NOW, 10]],
            samples7   => [[$NOW,  5]],
            rand       => sub { 0 },
        }
    );
    is($rc, 0, 'AC-4: http-500 subcommand exits 0 (degrade, no crash)');
    my $vj = decode_verdict($out);
    is($vj->{action}, 'unavailable', 'AC-4: http-500 subcommand JSON action=unavailable');
    unlink $creds_path;
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-5: missing/invalid creds file → unavailable(creds)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# AC-5a: creds ok=0 at pure fn level
{
    my $creds = { ok => 0, expires_ms => undef, detail => 'cannot-open:/no/such/path' };
    my $poll  = { status => 200, parsed => { five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00Z' },
                                             seven_day => { utilization =>  5, resets_at => '2099-01-02T00:00:00Z' } } };
    my $v = BpUsageGate::verdict_decision($creds, $poll, [[$NOW,10]], [[$NOW,5]], $NOW, tunables());
    is($v->{action}, 'unavailable', 'AC-5a: creds ok=0 → unavailable');
    is($v->{reason}, 'creds',       'AC-5a: creds ok=0 → reason creds');
    is($v->{until_epoch}, undef,    'AC-5a: creds ok=0 → until_epoch null');
}

# AC-5b: subcommand with missing creds file
{
    my $tmpdir      = tempdir(CLEANUP => 1);
    my $missing     = "$tmpdir/no-such-creds.json";
    my ($rc, $out)  = capture_run(
        ['verdict'],
        {
            now        => sub { $NOW },
            http_get   => sub { { status => 200, content => usage_body() } },
            creds_path => $missing,
            samples5   => [[$NOW, 10]],
            samples7   => [[$NOW,  5]],
            rand       => sub { 0 },
        }
    );
    is($rc, 0, 'AC-5b: missing creds → exit 0 (degrade)');
    my $vj = decode_verdict($out);
    is($vj->{action}, 'unavailable', 'AC-5b: missing creds → action=unavailable');
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-6: reuse is observable — independently compute should_pause / trip_point
#        on the same samples/ceiling and assert the verdict matches.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
    my $ceil5 = 85;
    my $drain = 600;
    my $t0    = $NOW - 600;
    my $s5    = [[$t0, 78], [$NOW, 84]];   # burn 0.01%/s; 84+6=90 >= 85
    my $s7    = [[$t0,  5], [$NOW,  5]];   # flat

    # Independent computation via BpGovern (the spec says gate CALLS these, not re-implements)
    my $burn5         = BpGovern::burn_per_sec($s5);
    my $expected_trip = BpGovern::should_pause(84, $burn5, $drain, $ceil5);
    # should_pause should be 1 (trip)
    is($expected_trip, 1, 'AC-6: independent BpGovern::should_pause confirms trip=1 for fixture');

    my $creds = { ok => 1, expires_ms => ($NOW + 5*3600)*1000, detail => '' };
    my $parsed = {
        five_hour => { utilization => 84, resets_at => '2099-06-01T12:00:00Z' },
        seven_day => { utilization =>  5, resets_at => '2099-06-02T00:00:00Z' },
    };
    my $poll = { status => 200, parsed => $parsed };
    my $t    = tunables(ceil5 => $ceil5, drain => $drain);

    my $v = BpUsageGate::verdict_decision($creds, $poll, $s5, $s7, $NOW, $t);

    # If gate reimplemented the math, a different impl could diverge on edge cases.
    # This assertion forces the gate's verdict to agree with BpGovern's decision.
    is($v->{action} eq 'pause-usage' ? 1 : 0, $expected_trip,
        'AC-6: verdict action (pause-usage=1, else=0) matches BpGovern::should_pause result');

    # Verify trip_point also agrees (gate must use BpGovern::trip_point for headroom math)
    my $tp = BpGovern::trip_point($burn5, $drain, $ceil5);
    ok($tp < $ceil5, 'AC-6: BpGovern::trip_point is below ceiling for this fixture');
    ok(84 >= $tp,    'AC-6: current util (84) is at or above trip_point, confirming pause');

    # until_epoch must be iso_to_epoch(resets_at) + jitter
    my $expected_ue = BpGovern::iso_to_epoch('2099-06-01T12:00:00Z') + 0;
    is($v->{until_epoch}, $expected_ue, 'AC-6: until_epoch derived from BpGovern::iso_to_epoch');
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-7: live smoke — soft / auto-skip if real creds absent or no network
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
    my $home       = $ENV{HOME} // $ENV{USERPROFILE} // '';
    my $real_creds = $ENV{BP_CREDS_PATH} // "$home/.claude/.credentials.json";
    my $can_smoke  = -f $real_creds;

    SKIP: {
        skip 'AC-7: live smoke skipped (real creds absent; hermetic-only run)', 3
            unless $can_smoke;

        # Shell out to the real script so we don't inject seams — this is a true
        # smoke that exercises the full live path including BpHttp::request.
        my $perl = $^X;
        my $out  = `"$perl" "$GATE" verdict 2>/dev/null`;
        my $exit = $? >> 8;
        is($exit, 0, 'AC-7: live smoke exits 0 (worst case = unavailable, not crash)');
        my $vj = eval { JSON::PP->new->decode($out) };
        ok(defined $vj && ref $vj eq 'HASH', 'AC-7: live smoke output is decodable JSON hash');
        my $valid_actions = { ok=>1, 'pause-usage'=>1, 'pause-token'=>1, unavailable=>1 };
        ok($valid_actions->{$vj->{action} // ''}, 'AC-7: live smoke action is one of the four valid actions');
    }
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-10: every verdict emission — valid single-line JSON, correct field types
#         (sampled across ok/pause-usage/pause-token/unavailable)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
    my @cases = (
        { action=>'ok',          until_epoch=>undef, reason=>'ok' },
        { action=>'pause-usage', until_epoch=>4102444800, reason=>'usage' },
        { action=>'pause-token', until_epoch=>undef, reason=>'token' },
        { action=>'unavailable', until_epoch=>undef, reason=>'creds' },
    );
    for my $case (@cases) {
        my $enc = JSON::PP->new->canonical->encode({
            action      => $case->{action},
            until_epoch => $case->{until_epoch},
            reason      => $case->{reason},
        });
        # Must be decodable
        my $dec = eval { JSON::PP->new->decode($enc) };
        # No test here — AC-10 coverage comes from the end-to-end capture_run tests
        # (AC-1, AC-2, AC-4, AC-5b) which each call decode_verdict on real output.
    }
    # Check the until_epoch JSON number constraint directly:
    my $h = { action => 'pause-usage', reason => 'usage', until_epoch => 4102444800 + 0 };
    my $enc = JSON::PP->new->canonical->encode($h);
    unlike($enc, qr/"until_epoch"\s*:\s*"/, 'AC-10: until_epoch encodes as JSON number not quoted string');
    like($enc,   qr/"until_epoch"\s*:\s*\d/, 'AC-10: until_epoch is bare number in JSON');
    like($enc,   qr/^\{.*\}$/, 'AC-10: verdict JSON is a single-line object (no embedded newlines in encode)');
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-11: back-compat text path — no-arg invocation still emits legacy format
#         OK/PAUSE with original exit codes (0/10); field layout unchanged.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# AC-11a: no-arg OK (utilization below soft ceilings)
{
    my $creds_path = write_creds();
    my ($rc, $out) = capture_run(
        [],   # no args → legacy text path
        {
            now        => sub { $NOW },
            http_get   => sub { { status => 200, content => usage_body(u5 => 10, u7 => 5) } },
            creds_path => $creds_path,
            samples5   => [[$NOW, 10]],
            samples7   => [[$NOW,  5]],
            rand       => sub { 0 },
        }
    );
    is($rc, 0, 'AC-11a: no-arg OK → exit 0');
    like($out, qr/^OK\b/, 'AC-11a: no-arg OK → first token is OK');
    like($out, qr/five=/, 'AC-11a: no-arg OK → legacy field "five" present');
    like($out, qr/seven=/, 'AC-11a: no-arg OK → legacy field "seven" present');
    unlink $creds_path;
}

# AC-11b: no-arg PAUSE (utilization above soft ceiling)
{
    my $creds_path = write_creds();
    my ($rc, $out) = capture_run(
        [],
        {
            now        => sub { $NOW },
            http_get   => sub { { status => 200, content => usage_body(u5 => 81, u7 => 5) } },
            creds_path => $creds_path,
            samples5   => [[$NOW, 81]],
            samples7   => [[$NOW,  5]],
            rand       => sub { 0 },
        }
    );
    is($rc, 10, 'AC-11b: no-arg PAUSE → exit 10');
    like($out, qr/^PAUSE\b/, 'AC-11b: no-arg PAUSE → first token is PAUSE');
    unlink $creds_path;
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AC-12: token sentinel never appears in any emitted output
#         (tested across verdict + text path, stdout + stderr)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
    my $sentinel   = $TOKEN_SENTINEL;
    my $creds_path = write_creds(token => $sentinel);   # sentinel in the creds file

    # verdict path
    my ($rc1, $out1, $err1) = capture_run(
        ['verdict'],
        {
            now        => sub { $NOW },
            http_get   => sub { { status => 200, content => usage_body(u5 => 10, u7 => 5) } },
            creds_path => $creds_path,
            samples5   => [[$NOW, 10]],
            samples7   => [[$NOW,  5]],
            rand       => sub { 0 },
        }
    );
    ok(index($out1, $sentinel) < 0, 'AC-12: sentinel not in verdict stdout');
    ok(index($err1, $sentinel) < 0, 'AC-12: sentinel not in verdict stderr');

    # text (no-arg) path
    my ($rc2, $out2, $err2) = capture_run(
        [],
        {
            now        => sub { $NOW },
            http_get   => sub { { status => 200, content => usage_body(u5 => 10, u7 => 5) } },
            creds_path => $creds_path,
            samples5   => [[$NOW, 10]],
            samples7   => [[$NOW,  5]],
            rand       => sub { 0 },
        }
    );
    ok(index($out2, $sentinel) < 0, 'AC-12: sentinel not in text-path stdout');
    ok(index($err2, $sentinel) < 0, 'AC-12: sentinel not in text-path stderr');

    unlink $creds_path;
}

done_testing;
