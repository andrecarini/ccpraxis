#!/usr/bin/env perl
# b35-worker-model-preference oracle. Derived ONLY from
# .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/b35-worker-model-preference-spec.md
# §2 (resolution cascade), §3 (fallback ladder, incl. the MEASURED §3.1 hazard), §4 (reason
# taxonomy), §5 (bp-log.pl mandated means) and §6 acceptance criteria F1..F9.
#
# WRITTEN BLIND TO ANY IMPLEMENTATION. plugins/butler/scripts/bp-worker-models.pl does not exist at
# the time this file was authored. Every assertion that depends on it running is expected to fail on
# MISSING BEHAVIOUR.
#
# CLI CONTRACT ASSUMED BY THIS ORACLE (NOT spec-pinned -- the spec fixes behaviour, not flags; this
# is the test-writer's closest reasonable approximation, flagged here rather than silently baked in):
#
#   bp-worker-models.pl resolve --role <role> --package-ledger <path> --blueprint <path>
#     -> stdout: "model: <value>\nsource: <tag>\n", exit 0. <tag> is one of
#        package-role | package-default | blueprint-role | blueprint-default | built-in.
#
#   bp-worker-models.pl dispatch --role <role> --package-ledger <path> --blueprint <path> \
#       --backend-bin <path> --prompt-file <path> --log <path> --rung-timeout <secs> \
#       [--zen-enabled] [--zen-cmd <path>] [--zen-cap <n>]
#     -> invokes "<backend-bin> --model <M> --prompt-file <prompt-file>" for each rung, bounded by
#        --rung-timeout; on success prints "model: <M>\nresult: ok\n" exit 0; on exhaustion appends
#        a "## Next action" block naming worker-models-exhausted to --package-ledger, prints
#        "result: parked\nreason: worker-models-exhausted\n", and does not attempt again. Every rung
#        transition is logged via BpLog::event(--log, 'worker_model_rung', {role, model, rung,
#        reason}) -- bp-log.pl is `require`d, never reimplemented (spec §5, mandated_means).
#
# HARNESS RULES (mirroring t/79, t/81):
#   * %CLEAN_ENV strips every ambient BP_*/PATH-adjacent var this suite controls explicitly.
#   * All fixtures live under File::Temp. Nothing is written into the live blueprint dir or a real
#     ledger.
#   * Every invocation of the (fake) backend binary is wrapped in `timeout`; no assertion depends on
#     a hang finishing. F9's fake backend sleeps past its bound on purpose -- the OUTER timeout is a
#     safety net only, the ladder's OWN --rung-timeout is what the test actually asserts on.
#   * The real `opencode` binary is NEVER invoked anywhere in this file -- F9 in particular must use
#     a fake, deliberately slow backend, never the real CLI (spec explicit instruction).
#   * grep -a (not grep) anywhere this file scans for text in files that could be binary-shaped.
#   * done_testing(), not a hand-counted plan.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

(my $ROOT_PLUGIN  = "$Bin/../..")            =~ s{\\}{/}g;
(my $ROOT_SCRIPTS = "$ROOT_PLUGIN/scripts")  =~ s{\\}{/}g;
my $BP_MODELS = "$ROOT_SCRIPTS/bp-worker-models.pl";
my $BP_WORKER = "$ROOT_SCRIPTS/bp-worker.pl";
my $BP_LOG    = "$ROOT_SCRIPTS/bp-log.pl";

diag("subject under test: $BP_MODELS "
     . (-e $BP_MODELS
        ? "(present)"
        : "(ABSENT -- every criterion below that depends on it is expected to fail on MISSING BEHAVIOUR)"));

my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
my $REAL_PATH = $CLEAN_ENV{PATH} // '/usr/bin:/bin';

my $TEST_BASE = tempdir(DIR => '/root', CLEANUP => 1);
my $rn = 0;

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

sub write_file {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]+$}{};
    make_path($dir) if length($dir) && !-d $dir;
    open my $w, '>', $path or die "write $path: $!";
    binmode $w;
    print $w $bytes;
    close $w;
}
sub read_file {
    my ($path) = @_;
    return undef unless -e $path;
    open my $r, '<', $path or return undef;
    binmode $r;
    my $c = do { local $/; <$r> };
    close $r;
    return defined $c ? $c : '';
}
sub read_lines_a {
    # grep -a-equivalent: read raw bytes, split on \n, never let a binary byte kill the match.
    my ($path) = @_;
    my $c = read_file($path);
    return () unless defined $c;
    return split /\n/, $c;
}

# ---------------------------------------------------------------------------
# Fixture builders.
# ---------------------------------------------------------------------------
sub mk_package_ledger {
    my (%args) = @_;
    my $n = ++$rn;
    my $bp = "$TEST_BASE/bp$n";
    make_path("$bp/packages");
    my @L = ('---', "package: pkg$n", 'blueprint: sandbox-butler-overhaul', 'status: running');
    push @L, "model: $args{model}"                     if defined $args{model};
    push @L, "worker_backend: $args{worker_backend}"   if defined $args{worker_backend};
    if (defined $args{worker_models}) {
        push @L, 'worker_models:';
        push @L, map { "  $_" } @{ $args{worker_models} };
    }
    push @L, 'last_updated: 2026-08-01T00:00:00Z', '---', '', "# Package pkg$n", '',
             '## Next action', '', 'Fixture only.', '';
    my $ledger = "$bp/packages/pkg$n.md";
    write_file($ledger, join("\n", @L) . "\n");
    return ($bp, $ledger);
}

sub mk_blueprint_md {
    my ($bp, %args) = @_;
    my @L = ('```', 'blueprint: sandbox-butler-overhaul', 'created: 2026-08-01T00:00:00Z',
             'status: running   # spike');
    push @L, "worker_backend: $args{worker_backend}"   if defined $args{worker_backend};
    if (defined $args{worker_models}) {
        push @L, 'worker_models:';
        push @L, map { "  $_" } @{ $args{worker_models} };
    }
    push @L, '```', '', '## Overview', '', 'Fixture.', '';
    my $file = "$bp/blueprint.md";
    write_file($file, join("\n", @L) . "\n");
    return $file;
}

sub run_models {
    my ($args, %envover) = @_;
    my $errfile = "$TEST_BASE/models-stderr." . (++$rn) . ".txt";
    local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, %envover,
                  BP_MODELS_BIN => fwd($BP_MODELS), ERRPATH => fwd($errfile));
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 20 "$BP_MODELS_BIN" "$@" 2>"$ERRPATH"', 'bash', @$args)
        or die "bash: $!";
    my $out = do { local $/; <$fh> }; close $fh;
    my $rc  = $? >> 8;
    my $err = -e $errfile ? read_file($errfile) : '';
    return ($rc, defined $out ? $out : '', $err);
}

# A configurable fake backend, mirroring t/81's FAKE_OPENCODE design. Driven entirely by env vars
# so one script serves every ladder scenario. NEVER the real opencode CLI.
my $FAKEBIN = "$TEST_BASE/fakebin";
make_path($FAKEBIN);
my $FAKE_BACKEND = "$FAKEBIN/fake-model-backend";
write_file($FAKE_BACKEND, <<'SH');
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_CALLLOG:-}" ]; then
  { printf 'CALL args=[%s]\n' "$*"; } >> "$FAKE_CALLLOG"
fi
if [ -n "${FAKE_SLEEP:-}" ]; then
  sleep "$FAKE_SLEEP"
fi
if [ -n "${FAKE_STDERR_TEXT:-}" ]; then
  printf '%s\n' "$FAKE_STDERR_TEXT" >&2
fi
exit "${FAKE_EXIT:-0}"
SH
chmod 0755, $FAKE_BACKEND or die "chmod $FAKE_BACKEND: $!";

my $FAKE_ZEN = "$FAKEBIN/fake-zen";
write_file($FAKE_ZEN, <<'SH');
#!/usr/bin/env bash
set -u
if [ -n "${FAKE_ZEN_MARKER:-}" ]; then
  printf 'ZEN CALLED\n' >> "$FAKE_ZEN_MARKER"
fi
exit "${FAKE_ZEN_EXIT:-0}"
SH
chmod 0755, $FAKE_ZEN or die "chmod $FAKE_ZEN: $!";

sub run_dispatch {
    my ($args, %envover) = @_;
    my $errfile = "$TEST_BASE/dispatch-stderr." . (++$rn) . ".txt";
    local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH, %envover,
                  BP_MODELS_BIN => fwd($BP_MODELS), ERRPATH => fwd($errfile));
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 25 "$BP_MODELS_BIN" "$@" 2>"$ERRPATH"', 'bash', @$args)
        or die "bash: $!";
    my $out = do { local $/; <$fh> }; close $fh;
    my $rc  = $? >> 8;
    my $err = -e $errfile ? read_file($errfile) : '';
    return ($rc, defined $out ? $out : '', $err);
}

# ===========================================================================
# F1 (DC-1) -- resolution order proven at each level: role-in-ledger beats
# default-in-ledger beats role-in-blueprint beats default-in-blueprint beats built-in.
# ===========================================================================
{
    # Level 1: role entry in package ledger wins over everything else present.
    my ($bp, $ledger) = mk_package_ledger(
        worker_models => ['default: [model-pkg-default]', 'bp-scout: [model-pkg-role-scout]']);
    mk_blueprint_md($bp,
        worker_models => ['default: [model-bp-default]', 'bp-scout: [model-bp-role-scout]']);
    my ($rc, $out, $err) = run_models(
        ['resolve', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md"]);
    like($out, qr/^model:\s*model-pkg-role-scout\b/m,
        'F1: role entry in the PACKAGE ledger beats every other level')
        or diag("rc=$rc out=$out err=$err");
}
{
    # Level 2: default in package ledger wins when no role entry in package ledger, even though
    # blueprint carries both a role entry and a default.
    my ($bp, $ledger) = mk_package_ledger(worker_models => ['default: [model-pkg-default]']);
    mk_blueprint_md($bp,
        worker_models => ['default: [model-bp-default]', 'bp-scout: [model-bp-role-scout]']);
    my ($rc, $out, $err) = run_models(
        ['resolve', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md"]);
    like($out, qr/^model:\s*model-pkg-default\b/m,
        'F1: default in the PACKAGE ledger beats role/default in the blueprint')
        or diag("rc=$rc out=$out err=$err");
}
{
    # Level 3: role entry in blueprint wins when the package ledger carries no worker_models at all.
    my ($bp, $ledger) = mk_package_ledger();
    mk_blueprint_md($bp,
        worker_models => ['default: [model-bp-default]', 'bp-scout: [model-bp-role-scout]']);
    my ($rc, $out, $err) = run_models(
        ['resolve', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md"]);
    like($out, qr/^model:\s*model-bp-role-scout\b/m,
        'F1: role entry in the BLUEPRINT wins when the package ledger has none')
        or diag("rc=$rc out=$out err=$err");
}
{
    # Level 4: default in blueprint wins when neither ledger has a role entry.
    my ($bp, $ledger) = mk_package_ledger();
    mk_blueprint_md($bp, worker_models => ['default: [model-bp-default]']);
    my ($rc, $out, $err) = run_models(
        ['resolve', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md"]);
    like($out, qr/^model:\s*model-bp-default\b/m,
        'F1: default in the BLUEPRINT wins when neither ledger has a role entry')
        or diag("rc=$rc out=$out err=$err");
}
{
    # Level 5: built-in default when nothing anywhere is configured.
    my ($bp, $ledger) = mk_package_ledger();
    mk_blueprint_md($bp);
    my ($rc, $out, $err) = run_models(
        ['resolve', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md"]);
    like($out, qr/^model:\s*opencode\/big-pickle\b/m,
        'F1: built-in default (opencode/big-pickle) wins when nothing is configured anywhere')
        or diag("rc=$rc out=$out err=$err");
}

# ===========================================================================
# F2 (DC-2) -- a role with no entry inherits default; absent/empty worker_models: yields the
# built-in, NOT an error.
# ===========================================================================
{
    my ($bp, $ledger) = mk_package_ledger(
        worker_models => ['default: [model-pkg-default]', 'bp-reviewer: [model-pkg-role-reviewer]']);
    my ($rc, $out, $err) = run_models(
        ['resolve', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md"]);
    like($out, qr/^model:\s*model-pkg-default\b/m,
        'F2: a role with no entry of its own inherits the ledger default')
        or diag("rc=$rc out=$out err=$err");
}
{
    my ($bp, $ledger) = mk_package_ledger();  # no worker_models: key at all
    mk_blueprint_md($bp);                     # no worker_models: key at all either
    my ($rc, $out, $err) = run_models(
        ['resolve', '--role', 'bp-implementer', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md"]);
    is($rc, 0, 'F2: an absent worker_models: everywhere is NOT an error (exit 0)')
        or diag("rc=$rc out=$out err=$err");
    like($out, qr/^model:\s*opencode\/big-pickle\s*$/m,
        'F2: absent worker_models: yields the documented built-in opencode/big-pickle')
        or diag("out=$out err=$err");
}
{
    my ($bp, $ledger) = mk_package_ledger(worker_models => []);  # present but empty
    mk_blueprint_md($bp);
    my ($rc, $out, $err) = run_models(
        ['resolve', '--role', 'bp-implementer', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md"]);
    is($rc, 0, 'F2: an EMPTY worker_models: block is NOT an error (exit 0)')
        or diag("rc=$rc out=$out err=$err");
    like($out, qr/^model:\s*opencode\/big-pickle\s*$/m,
        'F2: an empty worker_models: block yields the built-in opencode/big-pickle')
        or diag("out=$out err=$err");
}

# ===========================================================================
# F3 (DC-3) -- model: (coordinator's Claude model, read by bp-launch.sh via fm_get) is untouched,
# and worker_backend:'s b32 resolution is unchanged, when worker_models: is also present on the
# SAME ledger. Regression fence: this must hold even with bp-worker-models.pl entirely absent,
# because neither fm_get nor bp-worker.pl's read_header_key may be repurposed by this package.
# ===========================================================================
{
    my ($bp, $ledger) = mk_package_ledger(
        model => 'claude-sonnet-5', worker_backend => 'claude',
        worker_models => ['default: [opencode/big-pickle]', 'bp-scout: [opencode/cheap-model]']);

    # 3a. model: still resolves via fm_get (bp-lib.sh), untouched by worker_models: being present.
    my $BP_LIB = "$ROOT_SCRIPTS/bp-lib.sh";
    my $fm_out = `bash -c '. "\$1" >/dev/null 2>&1; fm_get "\$2" model' bash "$BP_LIB" "$ledger" 2>/dev/null`;
    chomp $fm_out;
    is($fm_out, 'claude-sonnet-5',
        "F3: fm_get(\$ledger, 'model') still resolves the coordinator's Claude model unchanged "
        . 'when worker_models: is present on the same ledger');

    # 3b. worker_backend: still resolves via bp-worker.pl's own (b32, unmodified) two-level cascade.
    # backend=claude -> non-executing 4-line block per b32 §2.5/§2.7; worker_models: must not divert it.
    my $proj = "$TEST_BASE/proj" . (++$rn);
    make_path($proj);
    my $pf = "$TEST_BASE/f3-prompt." . (++$rn) . ".txt";
    write_file($pf, "f3 prompt\n");
    my $errfile = "$TEST_BASE/f3-stderr." . (++$rn) . ".txt";
    local %ENV = (%CLEAN_ENV, PATH => $REAL_PATH,
                  BP_DIR => $bp, BP_PACKAGE => (($ledger =~ m{/([^/]+)\.md$}) ? $1 : 'pkg'),
                  BP_LEDGER => $ledger, BP_PROJECT_ROOT => $proj,
                  BP_WORKER_BIN => fwd($BP_WORKER), ERRPATH => fwd($errfile));
    open(my $fh, '-|', 'bash', '-c',
         'exec timeout 20 "$BP_WORKER_BIN" --worker scout --prompt-file "$1" 2>"$ERRPATH"',
         'bash', $pf) or die "bash: $!";
    my $out = do { local $/; <$fh> }; close $fh;
    my $rc = $? >> 8;
    is($rc, 0, 'F3: bp-worker.pl still exits 0 for backend=claude with worker_models: present on the ledger');
    like($out, qr/^backend:\s*claude\s*$/m,
        "F3: worker_backend:'s b32 two-level resolution is unchanged by worker_models: being present");
}

# ===========================================================================
# Scaffolding shared by F4..F9: dispatch fixtures.
# ===========================================================================
sub mk_dispatch_fixture {
    my (%args) = @_;
    my ($bp, $ledger) = mk_package_ledger(
        worker_models => [ 'default: [' . join(', ', @{ $args{ladder} // ['fake/model-a'] }) . ']' ]);
    mk_blueprint_md($bp);
    my $log = "$TEST_BASE/rungs." . (++$rn) . ".ndjson";
    my $pf  = "$TEST_BASE/dispatch-prompt." . (++$rn) . ".txt";
    write_file($pf, $args{prompt} // "dispatch prompt\n");
    return ($bp, $ledger, $log, $pf);
}

sub events_from_log {
    my ($log) = @_;
    my @lines = grep { /\S/ } read_lines_a($log);
    return @lines;
}

# ===========================================================================
# F4 (DC-4) -- each failure class advances exactly one rung; with Zen DISABLED, no Zen call is
# even attempted (not merely that it fails) once the ladder is exhausted down to free/park.
# ===========================================================================
{
    my ($bp, $ledger, $log, $pf) = mk_dispatch_fixture(ladder => ['fake/model-a']);
    my $zen_marker = "$TEST_BASE/zen-marker." . (++$rn) . ".txt";
    my $calllog = "$TEST_BASE/calllog." . (++$rn) . ".txt";
    my ($rc, $out, $err) = run_dispatch(
        ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md",
         '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf, '--log', $log, '--rung-timeout', '5',
         '--zen-cmd', $FAKE_ZEN],
        FAKE_EXIT => 1, FAKE_STDERR_TEXT => 'Error: 401 unauthorized - invalid or missing credentials',
        FAKE_ZEN_MARKER => fwd($zen_marker), FAKE_CALLLOG => fwd($calllog));

    # POSITIVE HALF FIRST (coordinator fix at the step-3 gate). "Zen was never invoked"
    # and "no retry storm" are both trivially true when NOTHING ran — they pass against
    # an absent script and would pass against a dispatcher that does nothing at all.
    # Prove the ladder actually ran before asserting what it did not do.
    my @calls = read_lines_a($calllog);
    ok(scalar(@calls) > 0,
       'F4: the ladder actually invoked the backend at least once (otherwise the negative '
     . 'assertions below are vacuous)')
        or diag("no backend calls recorded; rc=$rc out=$out err=$err");

    ok(!-e $zen_marker, 'F4: with Zen disabled (no --zen-enabled), Zen is NEVER invoked even after exhaustion')
        or diag("rc=$rc out=$out err=$err; zen marker unexpectedly present");

    ok(scalar(@calls) <= 1 || scalar(@calls) == scalar(grep { /model-a/ } @calls),
        'F4: an auth failure on the sole configured model advances exactly one rung, not a retry storm')
        or diag('calls: ' . join('|', @calls));
}

# ===========================================================================
# F5 (DC-5) -- every rung transition logs a BpLog::event whose reason is one of §4's enumerated
# values, and PAIRWISE DISTINCT strings across the whole taxonomy (not merely "some reason present").
# ===========================================================================
{
    my %stderr_for = (
        'auth'              => 'Error: 401 Unauthorized - invalid or missing credentials',
        'rate-limit'        => 'Error: 429 Too Many Requests - rate limit exceeded',
        'window-limit'      => 'Error: usage window exhausted for this account, resets in 4h',
        'model-unavailable' => 'Error: model not found / unknown model for this provider',
        'provider-error'    => 'Error: internal provider fault, please try again later (5xx)',
    );
    my %reason_seen;
    for my $reason (sort keys %stderr_for) {
        my ($bp, $ledger, $log, $pf) = mk_dispatch_fixture(ladder => ['fake/model-a']);
        my ($rc, $out, $err) = run_dispatch(
            ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md",
             '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf, '--log', $log, '--rung-timeout', '5'],
            FAKE_EXIT => 1, FAKE_STDERR_TEXT => $stderr_for{$reason});
        my @lines = events_from_log($log);
        my ($observed) = map { /"reason"\s*:\s*"([^"]+)"/ ? $1 : () } @lines;
        $reason_seen{$reason} = $observed;
        ok(defined $observed, "F5: a $reason-shaped dispatch failure logs SOME reason via BpLog::event")
            or diag("rc=$rc out=$out err=$err log=" . join('|', @lines));
    }
    # spend-cap: only reachable via the Zen path, honouring a caller-supplied cap (spec §7: this
    # package only honours enabled+cap, no billing). A cap of 0 with Zen enabled must trip it
    # without ever calling the zen backend for real work.
    {
        my ($bp, $ledger, $log, $pf) = mk_dispatch_fixture(ladder => ['fake/model-a']);
        my ($rc, $out, $err) = run_dispatch(
            ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md",
             '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf, '--log', $log, '--rung-timeout', '5',
             '--zen-enabled', '--zen-cmd', $FAKE_ZEN, '--zen-cap', '0'],
            FAKE_EXIT => 1, FAKE_STDERR_TEXT => 'Error: 401 unauthorized - invalid or missing credentials');
        my @lines = events_from_log($log);
        my ($observed) = map { /"reason"\s*:\s*"spend-cap"/ ? 'spend-cap' : () } @lines;
        $reason_seen{'spend-cap'} = $observed;
        ok(defined $observed, 'F5: a Zen dispatch attempted against a zero cap logs reason: spend-cap')
            or diag("rc=$rc out=$out err=$err log=" . join('|', @lines));
    }
    # timeout: covered structurally by F9 below; folded into the distinctness set here too.
    {
        my ($bp, $ledger, $log, $pf) = mk_dispatch_fixture(ladder => ['fake/model-a']);
        my ($rc, $out, $err) = run_dispatch(
            ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md",
             '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf, '--log', $log, '--rung-timeout', '2'],
            FAKE_SLEEP => '30');
        my @lines = events_from_log($log);
        my ($observed) = map { /"reason"\s*:\s*"timeout"/ ? 'timeout' : () } @lines;
        $reason_seen{'timeout'} = $observed;
        ok(defined $observed, 'F5: a non-responding rung within this sub-test logs reason: timeout')
            or diag("rc=$rc out=$out err=$err log=" . join('|', @lines));
    }

    my @observed_values = grep { defined } values %reason_seen;
    my %uniq = map { ($_ => 1) } @observed_values;
    is(scalar(keys %uniq), scalar(@observed_values),
        'F5: PAIRWISE DISTINCT reason strings across the whole §4 taxonomy -- '
        . 'no two different causes collapse to the same string')
        or diag('observed: ' . join(', ', map { "$_=$reason_seen{$_}" } sort keys %reason_seen));
}

# ===========================================================================
# F6 (DC-6) -- no logged event contains credential material. Feed a token-shaped fixture through a
# failing dispatch; assert it is absent from the log, AND that the redaction is bp-log.pl's own
# (mandated means), not a local scrub reimplemented by this package.
# ===========================================================================
{
    my $token = 'sk-ant-api03-' . ('A' .. 'Z')[0] x 30;  # sk-ant-shaped, 20+ chars after prefix
    $token = 'sk-ant-api03-' . ('X' x 32);
    my $jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PYb-fVOEIC0Q';
    my ($bp, $ledger, $log, $pf) = mk_dispatch_fixture(ladder => ['fake/model-a']);
    my ($rc, $out, $err) = run_dispatch(
        ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md",
         '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf, '--log', $log, '--rung-timeout', '5'],
        FAKE_EXIT => 1,
        FAKE_STDERR_TEXT => "Error: 401 unauthorized using token $token bearer $jwt "
                          . "MARKER-RAW-STDERR-MUST-NOT-BE-LOGGED");

    my $log_content = read_file($log) // '';
    # POSITIVE HALF FIRST (coordinator fix at the step-3 gate). The two `unlike`s below
    # pass trivially against an EMPTY or absent log — "the token never appears" is true
    # of a file with nothing in it, so they would also pass against an implementation
    # that logs nothing at all. Redaction is only meaningful if something WAS logged.
    ok(length($log_content // '') > 0,
       'F6: a log was actually written (otherwise the redaction assertions below are vacuous)')
        or diag('empty/absent log — the two unlike() checks after this prove nothing on their own');
    ok(scalar(events_from_log($log)) > 0,
       'F6: the log contains at least one parsed event')
        or diag('no events parsed from the log');

    unlike($log_content, qr/\Q$token\E/, 'F6: the sk-ant-shaped token never appears in the log file');
    unlike($log_content, qr/\Q$jwt\E/,   'F6: the JWT-shaped blob never appears in the log file');

    # WHY the JWT assertion passes matters, and it is NOT what the mandated-means
    # rationale implies. bp-log.pl's redact() masks by KEY NAME
    # (token|secret|credential|access_token|refresh_token|authorization) and by the
    # VALUE pattern /sk-[A-Za-z0-9_-]{20,}/ — it does NOT recognise a JWT. So the JWT
    # is absent only because the dispatcher never logs raw backend stderr at all,
    # logging whitelisted fields instead. That protection is real but was INCIDENTAL;
    # assert it directly so it cannot silently regress. If someone later logs stderr
    # "for debuggability", this fails loudly instead of quietly leaking a bearer token.
    unlike($log_content, qr/MARKER-RAW-STDERR-MUST-NOT-BE-LOGGED/,
        'F6: raw backend stderr is NEVER copied into the log (the property the JWT case '
      . 'actually relies on — bp-log.pl does not redact JWTs)');

    # Mandated-means conformance: the script must genuinely require/use bp-log.pl, not reimplement
    # redaction locally. Absent implementation fails this honestly (file unreadable).
    my $src = read_file($BP_MODELS);
  SKIP: {
        skip('F6: bp-worker-models.pl does not exist yet -- cannot inspect mandated-means conformance', 2)
            unless defined $src;
        like($src, qr/require\s+["'].*bp-log\.pl["']/,
            'F6: bp-worker-models.pl `require`s bp-log.pl (mandated means, not reimplemented)');
        like($src, qr/BpLog::event/,
            'F6: bp-worker-models.pl genuinely calls BpLog::event (wired into the shipping path)');
    }
}

# ===========================================================================
# F7 (DC-7) -- exhausting the ladder PARKS the package with a concrete "## Next action", rather
# than looping, and no further attempt follows.
# ===========================================================================
{
    my ($bp, $ledger, $log, $pf) = mk_dispatch_fixture(ladder => ['fake/model-a', 'fake/model-b']);
    my $calllog = "$TEST_BASE/f7-calllog." . (++$rn) . ".txt";
    my ($rc, $out, $err) = run_dispatch(
        ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md",
         '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf, '--log', $log, '--rung-timeout', '5'],
        FAKE_EXIT => 1, FAKE_STDERR_TEXT => 'Error: 401 unauthorized - invalid or missing credentials',
        FAKE_CALLLOG => fwd($calllog));

    like($out, qr/parked|worker-models-exhausted/i,
        'F7: exhausting the ladder is reported as a PARK, not a silent failure')
        or diag("rc=$rc out=$out err=$err");

    my $ledger_content = read_file($ledger) // '';
    like($ledger_content, qr/##\s*Next action/,
        'F7: the package ledger carries a concrete "## Next action" section after exhaustion');
    like($ledger_content, qr/worker-models-exhausted/,
        'F7: the "## Next action" names the worker-models-exhausted decision');

    my @calls_before = read_lines_a($calllog);
    my $calls_n1 = scalar(@calls_before);
    # Re-invoke dispatch a second time against the SAME (already-parked) ledger; if parking is
    # real, this must not silently retry down the exact same ladder without acknowledging the park.
    my ($rc2, $out2, $err2) = run_dispatch(
        ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md",
         '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf, '--log', $log, '--rung-timeout', '5'],
        FAKE_EXIT => 1, FAKE_STDERR_TEXT => 'Error: 401 unauthorized - invalid or missing credentials',
        FAKE_CALLLOG => fwd($calllog));
    like($out2 . $err2, qr/parked|already|exhausted/i,
        'F7: a second dispatch against an already-parked package does not silently loop through the ladder again')
        or diag("rc2=$rc2 out2=$out2 err2=$err2");
}

# ===========================================================================
# F8 (DC-8) -- model-unavailable and rate-limit are distinguished and do NOT share a code path.
# ===========================================================================
{
    my ($bp1, $ledger1, $log1, $pf1) = mk_dispatch_fixture(ladder => ['fake/model-a']);
    my ($rc1, $out1, $err1) = run_dispatch(
        ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger1, '--blueprint', "$bp1/blueprint.md",
         '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf1, '--log', $log1, '--rung-timeout', '5'],
        FAKE_EXIT => 1, FAKE_STDERR_TEXT => 'Error: model not found / unknown model for this provider');
    my ($reason1) = map { /"reason"\s*:\s*"([^"]+)"/ ? $1 : () } events_from_log($log1);

    my ($bp2, $ledger2, $log2, $pf2) = mk_dispatch_fixture(ladder => ['fake/model-a']);
    my ($rc2, $out2, $err2) = run_dispatch(
        ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger2, '--blueprint', "$bp2/blueprint.md",
         '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf2, '--log', $log2, '--rung-timeout', '5'],
        FAKE_EXIT => 1, FAKE_STDERR_TEXT => 'Error: 429 Too Many Requests - rate limit exceeded');
    my ($reason2) = map { /"reason"\s*:\s*"([^"]+)"/ ? $1 : () } events_from_log($log2);

    # NOT a SKIP (coordinator fix at the step-3 gate). The original guarded these three
    # behind `skip unless defined $reason1 && defined $reason2` — but "no reason was
    # emitted" IS the failure DC-8 is about, so the criterion could never fail: absent
    # today because the script does not exist, and absent tomorrow if the classifier
    # were broken. A criterion whose failure mode is its own skip condition asserts
    # nothing. Assert presence first, then the classification.
    ok(defined $reason1, 'F8: a model-not-found dispatch emits a reason at all')
        or diag("no reason in log; out1=$out1 err1=$err1");
    ok(defined $reason2, 'F8: a rate-limited dispatch emits a reason at all')
        or diag("no reason in log; out2=$out2 err2=$err2");
    is($reason1 // '<none>', 'model-unavailable',
       'F8: a model-not-found dispatch classifies as model-unavailable')
        or diag("out1=$out1 err1=$err1");
    is($reason2 // '<none>', 'rate-limit',
       'F8: a 429/rate-limited dispatch classifies as rate-limit')
        or diag("out2=$out2 err2=$err2");
    isnt($reason1 // '<none-1>', $reason2 // '<none-2>',
        'F8: model-unavailable and rate-limit do NOT share a code path (distinct reason strings)');
}

# ===========================================================================
# F9 (spec §3.1, MEASURED hazard) -- a rung that does not answer within its timeout advances with
# reason: timeout and does NOT block. Deliberately slow FAKE backend, never the real opencode CLI.
# ===========================================================================
{
    my ($bp, $ledger, $log, $pf) = mk_dispatch_fixture(ladder => ['fake/model-a', 'fake/model-b']);
    my $started = time();
    my ($rc, $out, $err) = run_dispatch(
        ['dispatch', '--role', 'bp-scout', '--package-ledger', $ledger, '--blueprint', "$bp/blueprint.md",
         '--backend-bin', $FAKE_BACKEND, '--prompt-file', $pf, '--log', $log, '--rung-timeout', '2'],
        FAKE_SLEEP => '600');  # deliberately far longer than --rung-timeout; never the real CLI
    my $elapsed = time() - $started;

    ok($elapsed < 20,
        "F9: a non-responding rung does NOT block the whole ladder past its own timeout (elapsed=${elapsed}s)")
        or diag("rc=$rc out=$out err=$err");

    my @lines = events_from_log($log);
    my @timeout_events = grep { /"reason"\s*:\s*"timeout"/ } @lines;
    ok(scalar(@timeout_events) >= 1,
        'F9: the timed-out rung logs reason: timeout via BpLog::event')
        or diag('log lines: ' . join('|', @lines));
}

done_testing();
