#!/usr/bin/env perl
# Regression oracle: a STOPPED podman machine must not end the launch.
#
# THE OPERATOR'S REPORT (2026-08-14): "I am now trying to launch claude-sandbox
# and it just takes me to the TUI and then back to the console. Probably because
# the podman machine is not on. The launcher should handle that and should not
# silently drop me back to the console without anything to see."
#
# Two independent defects produced that single symptom, and both are pinned here
# (the second one structurally, since it lives outside the extractable region):
#
#   1. s03_run_launch_gate returned 'podman machine/socket unreachable' the
#      instant machine_ok was false. It never tried to START the machine -- even
#      though the machine_start seam already existed and was bound into the
#      interactive [l] recover flow. The remedy was reachable only AFTER the
#      failure, never on the path that hits it first.
#
#   2. The diagnosis was raised while the TUI had STDERR redirected into a temp
#      file. The clean teardown replayed that file; END and the INT/TERM handlers
#      only restored the filehandle and left it unread. So the message existed
#      and was never delivered.
#
# NEVER executes launcher.pl -- it builds container images and starts containers.
# The gate is extracted from its sentinel-delimited region and eval'd, exactly as
# plugins/sandbox/tests/t/58-container-health-detect.t already does.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }
my $ROOT     = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $LAUNCHER = "$ROOT/plugins/sandbox/scripts/launcher.pl";

ok(-f $LAUNCHER, 'sanity: launcher.pl exists') or do { done_testing(); exit };

my $src = do {
    open my $fh, '<:raw', $LAUNCHER or die "read launcher: $!";
    local $/; <$fh>;
};

# ---------------------------------------------------------------------------
# Extract the gate region (same sentinels t/58 uses).
# ---------------------------------------------------------------------------
my $BEGIN_SENTINEL = '# >>> s03:health-detect:BEGIN';
my $END_SENTINEL   = '# <<< s03:health-detect:END';
my ($region) = $src =~ /\Q$BEGIN_SENTINEL\E.*?\n(.*?)\Q$END_SENTINEL\E/s;
ok(defined $region, 'extraction: the s03:health-detect region is present');

my $GATE;
if (defined $region) {
    my $ok = eval "package S03GateColdStart;\nuse strict;\nuse warnings;\n$region\n1;\n";  ## no critic
    ok($ok, 'extraction: the region evals cleanly') or diag("eval error: $@");
    $GATE = S03GateColdStart->can('s03_run_launch_gate') if $ok;
}
ok(defined $GATE, 'extraction: s03_run_launch_gate is callable');

unless (defined $GATE) { done_testing(); exit }

# ---------------------------------------------------------------------------
# A1 -- a stopped machine is STARTED, then the launch continues.
#
# The probe reports machine_ok=0 first and machine_ok=1 after the start, which is
# what a real cold boot looks like. The gate must call machine_start, re-probe,
# and go on to start the container -- NOT return the unreachable diagnosis.
# ---------------------------------------------------------------------------
{
    my @calls;
    my $probes = 0;
    my $res = $GATE->(
        probe => sub {
            $probes++;
            push @calls, "probe$probes";
            return {
                machine_ok      => ($probes >= 2 ? 1 : 0),
                container_state => 'exited',
                image_present   => 1,
                exec_probe_ok   => 1,
            };
        },
        machine_start   => sub { push @calls, 'machine_start'; { ok => 1, detail => 'machine started' } },
        notify          => sub { push @calls, "notify:$_[0]" },
        start           => sub { push @calls, 'start'; 0 },
        is_port_failure => sub { 0 },
        recover         => sub { push @calls, "recover:$_[0]"; 1 },
        exec            => sub { push @calls, 'exec'; 1 },
    );

    ok((grep { $_ eq 'machine_start' } @calls),
        'A1: a stopped machine triggers machine_start instead of an immediate give-up');
    is($probes, 2, 'A1: the gate RE-PROBES after starting -- "started" and "reachable" are different claims');
    ok(!defined $res->{diagnosis} || $res->{diagnosis} ne 'podman machine/socket unreachable',
        'A1: it does NOT return the unreachable diagnosis once the machine came up');
    ok((grep { $_ eq 'start' } @calls),
        'A1: the launch proceeds to start the container');
    ok((grep { /^notify:/ } @calls),
        'A1: and the operator is TOLD the machine was started -- never a silent recovery');
}

# ---------------------------------------------------------------------------
# A2 -- if the machine genuinely cannot start, still abort, but SAY SO.
#
# The fix must not become "always continue": an unstartable machine has to keep
# failing, and the failure has to be announced rather than swallowed.
# ---------------------------------------------------------------------------
{
    my @calls;
    my $res = $GATE->(
        probe           => sub { push @calls, 'probe'; { machine_ok => 0, container_state => 'exited',
                                                         image_present => 1, exec_probe_ok => 1 } },
        machine_start   => sub { push @calls, 'machine_start'; { ok => 0, detail => 'rc 125: no wsl' } },
        notify          => sub { push @calls, "notify:$_[0]" },
        start           => sub { push @calls, 'start'; 0 },
        is_port_failure => sub { 0 },
        recover         => sub { push @calls, "recover:$_[0]"; 1 },
        exec            => sub { push @calls, 'exec'; 1 },
    );
    is($res->{diagnosis}, 'podman machine/socket unreachable',
        'A2: an unstartable machine still aborts the launch');
    ok(!(grep { $_ eq 'start' } @calls),
        'A2: and never proceeds to start a container against a dead runtime');
    my ($note) = grep { /^notify:/ } @calls;
    ok(defined $note, 'A2: the failure is announced, not swallowed');
    like($note // '', qr/could not be started/,
        'A2: and the message says the machine could not be started');
    like($note // '', qr/rc 125: no wsl/,
        'A2: carrying podman\'s own reason through, not a generic string');
}

# ---------------------------------------------------------------------------
# A3 -- a healthy machine is left completely alone.
#
# The common path must not pay for the cold-start remedy: no start attempt, no
# second probe, no notification noise.
# ---------------------------------------------------------------------------
{
    my @calls;
    my $probes = 0;
    $GATE->(
        probe           => sub { $probes++; { machine_ok => 1, container_state => 'exited',
                                              image_present => 1, exec_probe_ok => 1 } },
        machine_start   => sub { push @calls, 'machine_start'; { ok => 1 } },
        notify          => sub { push @calls, "notify:$_[0]" },
        start           => sub { push @calls, 'start'; 0 },
        is_port_failure => sub { 0 },
        recover         => sub { 1 },
        exec            => sub { 1 },
    );
    ok(!(grep { $_ eq 'machine_start' } @calls),
        'A3: a running machine is never restarted');
    is($probes, 1, 'A3: and is probed exactly once');
    ok(!(grep { /^notify:/ } @calls), 'A3: no notification noise on the healthy path');
}

# ---------------------------------------------------------------------------
# A4 -- the STDERR capture is DRAINED, not merely restored, on every exit.
#
# Structural, because END/INT/TERM are file-scope and outside the extractable
# region. The distinction is the whole bug: restoring the filehandle hands the
# terminal back, delivering the captured text is what the operator actually
# needed. Asserting "no bare restore remains" is what stops a future edit
# reverting to the silent form.
# ---------------------------------------------------------------------------
like($src, qr/sub\s+_stderr_capture_drain\b/,
    'A4: a shared _stderr_capture_drain() exists');

my ($drain_body) = $src =~ /sub\s+_stderr_capture_drain\s*\{(.*?)\n\}/s;
ok(defined $drain_body, 'A4: its body is locatable');
like($drain_body // '', qr/print\s+STDERR\s+\$captured/,
    'A4: it PRINTS the captured text -- not just a "see the log" pointer');

for my $ctx ('END', '$SIG{INT}', '$SIG{TERM}') {
    my ($line) = grep { index($_, $ctx) >= 0 && /_stderr_capture/ } split /\n/, $src;
    ok(defined $line, "A4: $ctx touches the STDERR capture at all");
    like($line // '', qr/_stderr_capture_drain\(\)/,
        "A4: $ctx DRAINS the capture rather than only restoring the handle");
}

unlike($src, qr/open\(STDERR, '>&', \$STDERR_CAPTURE_SAVED\) if \$STDERR_CAPTURE_SAVED;/,
    'A4: no bare restore-without-drain survives anywhere');

# ---------------------------------------------------------------------------
# A5 -- the machine is checked BEFORE the image build, not only in the gate.
#
# The gate fix (A1-A3) shipped first and did nothing for the operator, because
# on a cold host `podman build` dies long before the gate is reached:
#
#   image_build_failed exit 125
#   unable to connect to Podman socket ... connectex: No connection could be made
#
# Measured from their own launch transcript. Fixing a late stage while an earlier
# one still aborts is how a fix looks applied and changes nothing -- so the check
# has to sit at the first podman operation that can hit a cold machine.
# ---------------------------------------------------------------------------
like($src, qr/sub\s+_ensure_machine_ready\b/,
    'A5: a pre-build machine readiness check exists');

my ($build_body) = $src =~ /sub\s+build_image\s*\{(.*?)\n\}/s;
ok(defined $build_body, 'A5: build_image is locatable');
like($build_body // '', qr/_ensure_machine_ready/,
    'A5: build_image consults it BEFORE running podman build');

# Ordering, not merely presence: the check must precede the build invocation.
if (defined $build_body) {
    my $check_at = index($build_body, '_ensure_machine_ready');
    my $build_at = index($build_body, "'build'");
    ok($check_at >= 0 && $build_at >= 0 && $check_at < $build_at,
        'A5: and it precedes the podman build call, not follows it');
}

# ---------------------------------------------------------------------------
# A6 -- a failure is shown AFTER the TUI is torn down, and then held.
#
# The operator's second, independent complaint: "the launcher dropping out when
# something goes wrong and me being unable to see the error." The message was
# printed while the alternate screen buffer was still active; leaving that buffer
# restores the pre-TUI screen and ERASES it. Emitted, rendered, wiped -- which
# from the outside is identical to printing nothing.
#
# So the contract is an ORDER: leave the alt screen, drain the capture, print,
# then hold. Asserted structurally because it lives at file scope, outside the
# extractable region.
# ---------------------------------------------------------------------------
like($src, qr/sub\s+_fail_visibly\b/, 'A6: _fail_visibly exists');

my ($fv) = $src =~ /sub\s+_fail_visibly\s*\{(.*?)\n\}/s;
ok(defined $fv, 'A6: its body is locatable');

if (defined $fv) {
    my $leave = index($fv, 'host_leave');
    my $drain = index($fv, '_stderr_capture_drain');
    my $print = index($fv, 'print STDERR "$_\\n"');
    $print = index($fv, 'print STDERR') if $print < 0;
    ok($leave >= 0, 'A6: it leaves the TUI host');
    ok($drain >= 0, 'A6: it drains the captured STDERR');
    ok(($leave < $drain), 'A6: leaves the alt screen BEFORE draining');
    ok(($drain < $print), 'A6: and prints only AFTER both -- nothing can be erased by the restore');
    like($fv, qr/-t STDIN/,
        'A6: the hold is gated on an interactive terminal, never in a pipe or hook');
    like($fv, qr/CCPRAXIS_NO_PAUSE/,
        'A6: and is overridable, so it cannot wedge an automated run');
}

# The build failure path must use it -- that is the path the operator actually hit.
like($build_body // '', qr/_fail_visibly/,
    'A6: the image-build failure path reports through _fail_visibly');

done_testing();
