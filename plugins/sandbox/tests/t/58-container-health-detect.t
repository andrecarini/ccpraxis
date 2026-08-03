#!/usr/bin/env perl
# Oracle tests for s03-container-health-detect, derived from
#   .ccpraxis-local-data/blueprints/sandbox-butler-overhaul/specs/s03-container-health-detect-spec.md
#
# IMMUTABLE ORACLE: written from the spec BEFORE the implementation exists.
# launcher.pl does not yet carry the s03:health-detect sentinel region at
# authoring time -- large parts of this file are EXPECTED to show "not ok"
# until s03 lands. Do not weaken these assertions to make a future
# implementation's life easier.
#
# THE BUG (verified from source, s03 spec S0):
#   :3031  my $start_rc = system($PODMAN, 'start', $CONTAINER_NAME);
#   :3040  if ($start_rc != 0 && $port_in_use->($start_rc)) {   # ONLY the port case
#              ... every branch inside exits ...
#          }
#   :3098  log_ev('container_start', { exit => $start_rc >> 8, ... });   # falls through
# A non-port start failure satisfies neither arm, reaches log_ev (which
# faithfully records it), and then falls through into the exec chain against
# a container that never started. Logged but not aborted.
#
# THE SEAM (s12, done): `recover_container` at launcher.pl, documented as
# "the [l] relaunch/recover sequence, and the shared recovery seam the
# ledger promises s03 (which will call it at launch time with
# reason => 'launch-detect-broken')". s03 must INVOKE it, never reimplement
# recovery.
#
# WHY A SENTINEL + EVAL HARNESS (same technique as t/53's AC-10/AC-11, itself
# following q03's precedent): launcher.pl is NEVER require'd/do'ne in this
# suite -- it is a top-level script with real side effects (locks, podman
# invocations, terminal state), so behavioural assertions about a region that
# does not exist yet cannot be made by requiring the file. Instead, this
# oracle PRESCRIBES the interface s03 must build: a self-contained, pure,
# seam-driven region between two sentinel comments that this file extracts
# as source text and evals into a throwaway package. That region must define
# exactly one sub, `s03_run_launch_gate(%seams)`, whose seven seam callbacks
# (documented below at CONTRACT) let this file drive every branch with fakes
# and NO real podman/system/subprocess anywhere.
#
# CONTRACT (s03 must implement this to turn this file green):
#   Sentinels (each occurs exactly once, BEGIN before END):
#     # >>> s03:health-detect:BEGIN
#     # <<< s03:health-detect:END
#   Region defines exactly one sub: s03_run_launch_gate(%seams) -> \%result
#   Required seam keys (all called, none reimplemented inline):
#     probe()               -> \%state { machine_ok, container_state,
#                                         image_present, exec_probe_ok }
#     start()                -> $start_rc (integer, models `podman start`)
#     is_port_failure($rc)   -> bool (models the existing $port_in_use check)
#     recover($reason)       -> invoked for a rebuild offer; production binds
#                                this to recover_container(reason => $reason)
#     abort($rc)             -> invoked for a clean non-port-failure abort;
#                                production binds this to the existing
#                                "print STDERR ...; exit(...)" idiom
#     exec()                 -> invoked only when nothing aborted/recovered;
#                                production binds this to the podman exec
#                                touch-sentinel chain
#   Logic (this is the fix, prescribed so it is independently checkable):
#     1. state = probe(); if !state.machine_ok -> return diagnosis
#        'podman machine/socket unreachable', no recover, no abort, no exec.
#     2. if state.container_state eq 'exited' && !state.image_present ->
#        recover('launch-detect-broken'); return diagnosis 'image missing',
#        no exec.
#     3. if state.container_state eq 'running' && !state.exec_probe_ok ->
#        recover('launch-detect-broken'); return diagnosis 'degraded exec
#        environment', no exec.
#     4. otherwise: start_rc = start(); if start_rc != 0: if
#        is_port_failure(start_rc) -> return delegated_port => 1 (let the
#        EXISTING, untouched port-collision code at :3040-3097 handle it --
#        C6, no regression); else -> abort(start_rc); return aborted => 1,
#        exec NOT called. if start_rc == 0 -> exec(); return exec_called=>1.
#
# Region purity (mirrors q03's R-I2): the extracted text must reference no
# $PODMAN, no system(/backtick, no literal exit(, and must not itself shell
# out to podman -- every effect must go through the seven seams above. This
# is how C5 ("no duplicated recovery logic") is checked structurally: nothing
# in the region can be a second rebuild path.
#
# No real podman/container anywhere in this file. No SKIP whose condition is
# the failure state -- absence is recorded as ok(0, ...) with a diagnostic,
# same ruling as t/53.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
open my $lfh, '<:raw', $LAUNCHER or BAIL_OUT("cannot read launcher.pl: $!");
my @lines = <$lfh>;
close $lfh;
my $src = join '', @lines;

# =====================================================================
# Group A -- prerequisites that must ALREADY be true (s12 is done; if these
# fail, it is a real environment problem, not the s03 red-phase, hence
# BAIL_OUT is appropriate here only).
# =====================================================================
like($src, qr/\bsub\s+recover_container\b/,
    'prereq: s12\'s recover_container sub exists in launcher.pl')
    or BAIL_OUT('recover_container is missing -- s12 is not actually done, s03 cannot be tested');

# =====================================================================
# Group B (C6) -- the port-collision behaviour is UNCHANGED. Source-text
# assertions on the EXISTING code, outside any sentinel region. This is what
# stops the C2 fix from swallowing the existing, correct handling.
# =====================================================================
like($src, qr/if\s*\(\s*\$start_rc\s*!=\s*0\s*&&\s*\$port_in_use->\(\s*\$start_rc\s*\)\s*\)/,
    "C6: the existing port_in_use-gated if-block condition is present, unchanged");
like($src, qr/host port block\b.*is already in use.*reallocating/is,
    'C6: the create-path port-collision retry message text is present, unchanged');
like($src, qr/no free host port block available after \$tries attempt/,
    'C6: the create-path give-up message text is present, unchanged');
like($src, qr/another sandbox took this container's host ports/,
    'C6: the attach-path port-collision refusal message text is present, unchanged');
like($src, qr/This container's port mapping is fixed for its lifetime/,
    'C6: the attach-path port-collision explanation text is present, unchanged');
{
    my $exit_count = () = $src =~ /exit\s*\(\s*\$start_rc\s*>>\s*8\s*\|\|\s*1\s*\)/g;
    cmp_ok($exit_count, '>=', 2,
        'C6: at least the two existing "exit($start_rc >> 8 || 1)" port-collision exit statements are present, unchanged');
}

# =====================================================================
# Group C -- extraction harness (sentinel + eval, q03/t/53 precedent)
# =====================================================================
my $BEGIN_SENTINEL = '# >>> s03:health-detect:BEGIN';
my $END_SENTINEL   = '# <<< s03:health-detect:END';
my ($begin_idx, $end_idx, $region);
{
    my $begin_count = () = $src =~ /\Q$BEGIN_SENTINEL\E/g;
    my $end_count   = () = $src =~ /\Q$END_SENTINEL\E/g;
    is($begin_count, 1, "sentinel: BEGIN '$BEGIN_SENTINEL' occurs exactly once in launcher.pl");
    is($end_count, 1,   "sentinel: END '$END_SENTINEL' occurs exactly once in launcher.pl");
    $begin_idx = index($src, $BEGIN_SENTINEL);
    $end_idx   = index($src, $END_SENTINEL);
    ok(($begin_idx >= 0 && $end_idx >= 0 && $begin_idx < $end_idx),
        'sentinel: BEGIN appears before END');
    ($region) = $src =~ /\Q$BEGIN_SENTINEL\E.*?\n(.*?)\Q$END_SENTINEL\E/s
        if $begin_idx >= 0 && $end_idx >= 0 && $begin_idx < $end_idx;
}

my $GATE;   # coderef for s03_run_launch_gate, once (if) extraction succeeds
if (!defined $region) {
    ok(0, 'extraction: the s03:health-detect region evals cleanly into a fresh package (region not found in launcher.pl -- s03 not yet implemented)');
    ok(0, "extraction: the resulting package ->can('s03_run_launch_gate') (region not found)");
} else {
    my $harness = "package S03Gate;\nuse strict;\nuse warnings;\n" . $region . "\n1;\n";
    my $eval_ok = eval $harness;   ## no critic
    my $eval_err = $@;
    ok($eval_ok, 'extraction: the s03:health-detect region evals cleanly into a fresh package under use strict/warnings')
        or diag("eval error: $eval_err");
    if ($eval_ok) {
        $GATE = S03Gate->can('s03_run_launch_gate');
        ok(defined $GATE, "extraction: the resulting package ->can('s03_run_launch_gate')");
    } else {
        ok(0, "extraction: the resulting package ->can('s03_run_launch_gate') (region failed to eval)");
    }
}

# ---- region purity (C5 structural half: no second rebuild path can hide in
#      the extracted text; every effect must go through the seven seams) ----
if (!defined $region) {
    ok(0, 'purity (C5): extracted region references no $PODMAN (region not found)');
    ok(0, 'purity (C5): extracted region contains no system(/backtick/exit( (region not found)');
} else {
    unlike($region, qr/\$PODMAN\b/, 'purity (C5): extracted region references no $PODMAN -- all podman effects must be seam calls');
    unlike($region, qr/\bsystem\s*\(|`[^`]*`/, 'purity (C5): extracted region contains no system(/backtick -- no private subprocess path');
    unlike($region, qr/\bexit\s*\(/, 'purity (C5): extracted region contains no literal exit( -- abort must go through the abort seam, not a private exit');
}

# =====================================================================
# Group D -- seam harness for driving s03_run_launch_gate with fakes
# =====================================================================

# build_seams(%over) -> (\%seams, \@calls)
# @calls records seam invocation as [name, @args], pushed BEFORE the override
# runs, so a dying override still leaves a call record.
sub build_seams {
    my (%over) = @_;
    my @calls;
    my %default = (
        probe          => sub { { machine_ok => 1, container_state => 'running', image_present => 1, exec_probe_ok => 1 } },
        start          => sub { 0 },
        is_port_failure => sub { 0 },
        recover        => sub { 1 },
        abort          => sub { 1 },
        exec           => sub { 1 },
    );
    my %seams;
    for my $name (keys %default) {
        my $impl = exists $over{$name} ? $over{$name} : $default{$name};
        $seams{$name} = sub {
            push @calls, [ $name, @_ ];
            return $impl->(@_);
        };
    }
    return (\%seams, \@calls);
}

sub call_count {
    my ($calls, $name) = @_;
    return scalar grep { $_->[0] eq $name } @$calls;
}

SKIP: {
    skip 'S03Gate::s03_run_launch_gate not available -- s03 not yet implemented', 20
        unless defined $GATE;

    # ---- C1: exited container, image absent -> broken branch invokes the
    #      shared seam (asserted as a CALL, not as a rebuild happening by
    #      some other means). ----
    {
        my ($seams, $calls) = build_seams(
            probe => sub { { machine_ok => 1, container_state => 'exited', image_present => 0, exec_probe_ok => 1 } },
        );
        my $result = $GATE->(%$seams);
        is(call_count($calls, 'recover'), 1, 'C1: recover_container seam invoked exactly once for exited+image-absent');
        is(call_count($calls, 'exec'), 0, 'C1: podman exec is never reached for a broken container');
        my ($recover_call) = grep { $_->[0] eq 'recover' } @$calls;
        is($recover_call->[1], 'launch-detect-broken', "C1: recover invoked with reason => 'launch-detect-broken'");
        like($result->{diagnosis}, qr/image/i, 'C1: diagnosis mentions the image being the cause');
    }

    # ---- C2 (the core bug): a non-port `podman start` nonzero exit ABORTS
    #      CLEANLY -- no fall-through to `podman exec`.
    #      VACUITY GATE: first assert the start actually failed and was
    #      classified as non-port, THEN assert exec was not reached. A
    #      control/sanity scenario (successful start) proves this file's own
    #      harness CAN observe exec being called, so the failure-scenario's
    #      exec_called==0 is not trivially true for every scenario. ----
    {
        # control scenario: healthy probe + successful start -> exec IS called.
        my ($seams_ok, $calls_ok) = build_seams();
        my $result_ok = $GATE->(%$seams_ok);
        is(call_count($calls_ok, 'exec'), 1, 'C2 control: a successful start DOES reach podman exec (proves the harness can detect exec being called)');
        is($result_ok->{aborted} ? 1 : 0, 0, 'C2 control: a successful start is not reported as aborted');

        # failure scenario: healthy probe, start() returns a non-port nonzero rc.
        my ($seams, $calls) = build_seams(
            start           => sub { 17 << 8 },
            is_port_failure => sub { 0 },
        );
        my $start_rc = $seams->{start}->();
        # vacuity: the start actually failed, and it was classified non-port,
        # BEFORE we trust the "exec not reached" assertion below.
        isnt($start_rc, 0, 'C2 vacuity: the simulated start actually failed (non-zero rc)');
        ok(!$seams->{is_port_failure}->($start_rc), 'C2 vacuity: the failure was classified as NOT a port collision');
        @$calls = ();   # the two vacuity probes above are not part of the gate's own call log

        my $result = $GATE->(%$seams);
        is(call_count($calls, 'exec'), 0, 'C2: podman exec is NOT reached after a non-port start failure');
        is($result->{aborted} ? 1 : 0, 1, 'C2: the non-port start failure is reported as a clean abort');
        is(call_count($calls, 'abort'), 1, 'C2: the abort seam was invoked exactly once');
        is(call_count($calls, 'recover'), 0, 'C2: the non-port abort does not go through the rebuild seam (it is not a rebuild scenario)');
    }

    # ---- C3: running-but-degraded container (bash/curl probe fails) ->
    #      diagnosis + rebuild offer via the shared seam. ----
    {
        my ($seams, $calls) = build_seams(
            probe => sub { { machine_ok => 1, container_state => 'running', image_present => 1, exec_probe_ok => 0 } },
        );
        my $result = $GATE->(%$seams);
        is(call_count($calls, 'recover'), 1, 'C3: recover_container seam invoked exactly once for a degraded running container');
        is(call_count($calls, 'exec'), 0, 'C3: podman exec is never reached for a degraded container');
        my ($recover_call) = grep { $_->[0] eq 'recover' } @$calls;
        is($recover_call->[1], 'launch-detect-broken', "C3: recover invoked with reason => 'launch-detect-broken'");
    }

    # ---- C4: the three causes produce THREE DISTINCT human-readable
    #      diagnoses -- compared TO EACH OTHER, not merely non-empty. ----
    {
        my ($seams_machine, undef) = build_seams(
            probe => sub { { machine_ok => 0, container_state => 'unknown', image_present => 0, exec_probe_ok => 0 } },
        );
        my $diag_machine = $GATE->(%$seams_machine)->{diagnosis};

        my ($seams_image, undef) = build_seams(
            probe => sub { { machine_ok => 1, container_state => 'exited', image_present => 0, exec_probe_ok => 1 } },
        );
        my $diag_image = $GATE->(%$seams_image)->{diagnosis};

        my ($seams_degraded, undef) = build_seams(
            probe => sub { { machine_ok => 1, container_state => 'running', image_present => 1, exec_probe_ok => 0 } },
        );
        my $diag_degraded = $GATE->(%$seams_degraded)->{diagnosis};

        ok(length($diag_machine) && length($diag_image) && length($diag_degraded),
            'C4: all three diagnoses are non-empty (necessary, not sufficient)');
        isnt($diag_machine, $diag_image, 'C4: machine-unreachable diagnosis differs from image-missing diagnosis');
        isnt($diag_machine, $diag_degraded, 'C4: machine-unreachable diagnosis differs from degraded-exec diagnosis');
        isnt($diag_image, $diag_degraded, 'C4: image-missing diagnosis differs from degraded-exec diagnosis');

        # the machine-unreachable case is explicitly "nothing to rebuild" (spec
        # 1.3) -- it must not invoke the rebuild seam.
        {
            my ($seams_m2, $calls_m2) = build_seams(
                probe => sub { { machine_ok => 0, container_state => 'unknown', image_present => 0, exec_probe_ok => 0 } },
            );
            $GATE->(%$seams_m2);
            is(call_count($calls_m2, 'recover'), 0,
                'C4: machine-unreachable does not invoke recover (nothing to rebuild; the runtime itself is down)');
        }
    }

    # ---- C5 (behavioural half): no duplicated recovery logic -- the seam is
    #      actually called (vacuity: assert it WAS called) before asserting
    #      no second rebuild path exists structurally (Group C above). ----
    {
        my ($seams, $calls) = build_seams(
            probe => sub { { machine_ok => 1, container_state => 'exited', image_present => 0, exec_probe_ok => 1 } },
        );
        $GATE->(%$seams);
        ok(call_count($calls, 'recover') > 0, 'C5 vacuity: the shared seam was actually invoked in the broken-container scenario');
    }
}

# =====================================================================
# Group E (C5, whole-file half) -- recover_container remains the SINGLE
# implementation: exactly one sub definition, no second one appended
# elsewhere in launcher.pl that also does container recreation.
# =====================================================================
{
    my $recover_sub_count = () = $src =~ /\bsub\s+recover_container\b/g;
    is($recover_sub_count, 1, 'C5: exactly one sub recover_container definition exists in launcher.pl (no duplicate)');

    # No second, differently-named sub whose body looks like a rebuild path
    # (podman rm + podman create in the same sub, outside recover_container).
    my @other_rebuild_subs;
    while ($src =~ /\bsub\s+(\w+)\s*\{/g) {
        my $name = $1;
        next if $name eq 'recover_container';
        my $start = pos($src) - length($&) + index($&, '{');
        # crude balanced-brace body extraction, reusing the same idiom as
        # elsewhere in this suite (t/47's _balanced_braces).
        my $depth = 0; my $i = $start; my $len = length($src);
        for (; $i < $len; $i++) {
            my $c = substr($src, $i, 1);
            if ($c eq '{') { $depth++ } elsif ($c eq '}') { $depth--; last if $depth == 0 }
        }
        next if $depth != 0;
        my $body = substr($src, $start, $i - $start + 1);
        # Tight, code-shape regexes (not loose word matches) so prose like
        # "pre-create call site" or "podman rm -f" inside a COMMENT can't
        # false-positive (enforce_container_config_shape's H3 reap comment
        # hit exactly that with a looser check during authoring). Require
        # the actual call shapes this codebase uses: system($PODMAN, 'rm', ...)
        # for the reap, and either system($PODMAN, 'create', ...) or the
        # @podman_args create-args idiom (build_create_args / system(@podman_args))
        # for the (re)create half.
        my $does_rm     = $body =~ /system\s*\(\s*\$PODMAN\s*,\s*['"]rm['"]/;
        my $does_create = $body =~ /system\s*\(\s*\$PODMAN\s*,\s*['"]create['"]/
                        || $body =~ /system\s*\(\s*\@podman_args\s*\)/
                        || $body =~ /\bbuild_create_args\b/;
        push @other_rebuild_subs, $name if $does_rm && $does_create;
    }
    is_deeply(\@other_rebuild_subs, [],
        'C5: no sub other than recover_container both rm\'s and re-create\'s the container')
        or diag('candidate duplicate rebuild subs: ' . join(', ', @other_rebuild_subs));
}

done_testing();
