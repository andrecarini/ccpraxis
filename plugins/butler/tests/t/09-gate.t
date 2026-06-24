#!/usr/bin/env perl
# A4 graceful-stop gate — the allow-park/deny-work matrix (bp_gate_verdict), the
# stop-signal detection + precedence (bp_active_stop_signal), the gate-stop.sh
# resumable-pause clause, and the gate-shutdown.sh PreToolUse wiring. The pure
# decision + signal helpers run anywhere (pure bash); gate-stop's pause clause
# needs no jq either. The full gate-shutdown wiring needs jq (the hook is
# fail-closed on a missing jq, as in production), so it is jq-gated and runs in
# the sandbox where jq is present.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $LIB   = "$HOOKS/lib.sh";
my $GATE  = "$HOOKS/gate-shutdown.sh";
my $GSTOP = "$HOOKS/gate-stop.sh";
my $TRACK = "$HOOKS/track-dispatch.sh";

my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; $o =~ /\S/ ? 1 : 0 };

plan tests => 38;

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
(my $ROOT_FWD = $ROOT) =~ s{\\}{/}g;
my $pn = 0;
sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

# --- bash invocation helpers (list form: bypasses cmd.exe; argv passed cleanly) -

# pure verdict: source lib.sh, call bp_gate_verdict TOOL PCLASS SIG
sub verdict {
    my ($tool, $pc, $sig) = @_;
    local $ENV{LIBSH} = $LIB;
    open(my $f, '-|', 'bash', '-c',
         'source "$LIBSH"; bp_gate_verdict "$1" "$2" "$3"', 'h', $tool, $pc, $sig)
        or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

# signal detection: set BP_DIR/BP_PACKAGE, call bp_active_stop_signal
sub signal {
    my ($dir, $pkg) = @_;
    local $ENV{LIBSH}     = $LIB;
    local $ENV{BP_DIR}    = $dir;
    local $ENV{BP_PACKAGE}= $pkg;
    open(my $f, '-|', 'bash', '-c', 'source "$LIBSH"; bp_active_stop_signal')
        or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

sub realpath_m {
    my ($p) = @_; local $ENV{P} = $p;
    open(my $f, '-|', 'bash', '-c', 'realpath -m "$P"') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f; $o =~ s/\s+\z//; return $o;
}

# run gate-shutdown.sh with a JSON payload on stdin + a BP_* env; (exit, out)
sub run_gate {
    my ($payload, %env) = @_;
    my $pf = "$ROOT/payload." . (++$pn) . ".json";
    open my $w, '>', $pf or die; print $w $payload; close $w;
    local %ENV = (%ENV, %env, GATEPATH => fwd($GATE), PFILE => fwd($pf));
    open(my $f, '-|', 'bash', '-c', '"$GATEPATH" < "$PFILE" 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

# run gate-stop.sh (Stop hook, reads no stdin payload) with a BP_* env; (exit, out)
sub run_gstop {
    my (%env) = @_;
    local %ENV = (%ENV, %env, GSPATH => fwd($GSTOP));
    open(my $f, '-|', 'bash', '-c', '"$GSPATH" < /dev/null 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

# run track-dispatch.sh with a BP_* env (its stop-signal early-exit runs before jq)
sub run_track {
    my (%env) = @_;
    local %ENV = (%ENV, %env, TKPATH => fwd($TRACK));
    open(my $f, '-|', 'bash', '-c', '"$TKPATH" < /dev/null 2>&1') or die "bash: $!";
    my $o = do { local $/; <$f> }; close $f;
    return ($? >> 8, $o);
}

# build a fresh blueprint dir under $ROOT; returns (BP_DIR_msys, BP_LEDGER_msys)
my $bpn = 0;
sub mk_bp {
    my ($status, $next, %sig) = @_;   # ledger status + Next-action body + signal flags
    my $win = "$ROOT/bp" . (++$bpn);
    mkdir $win; mkdir "$win/runs"; mkdir "$win/packages";
    open my $l, '>', "$win/packages/p.md" or die;
    print $l "---\npackage: p\nstatus: $status\nlast_updated: 2026-06-24T00:00:00Z\n---\n# p\n\n## Next action\n\n$next\n";
    close $l;
    for my $s (qw(shutdown paused)) { if ($sig{$s}) { open my $h,'>',"$win/runs/.$s" or die; close $h } }
    if ($sig{forcestop}) { open my $h,'>',"$win/runs/p.force-stop" or die; close $h }
    my $dir = realpath_m(fwd($win));
    return ($dir, "$dir/packages/p.md");
}

# =========================================================================
# bp_gate_verdict — the allow-park / deny-work matrix
# =========================================================================
is(verdict('Task','-',0),               'allow', 'no signal: Task allowed');
is(verdict('Edit','worksite',0),        'allow', 'no signal: worksite edit allowed');
is(verdict('Task','-',1),               'deny',  'stop: Task (new worker) denied');
is(verdict('Edit','worksite',1),        'deny',  'stop: Edit into worksite denied');
is(verdict('Write','worksite',1),       'deny',  'stop: Write into worksite denied');
is(verdict('MultiEdit','worksite',1),   'deny',  'stop: MultiEdit into worksite denied');
is(verdict('NotebookEdit','worksite',1),'deny',  'stop: NotebookEdit into worksite denied');
is(verdict('Edit','ledger',1),          'allow', 'stop: ledger park-write (Edit) allowed');
is(verdict('Write','ledger',1),         'allow', 'stop: ledger park-write (Write) allowed');
is(verdict('Bash','-',1),               'allow', 'stop: Bash (finalize/park) allowed');
is(verdict('Read','-',1),               'allow', 'stop: Read (non-mutating) allowed');
is(verdict('Grep','-',1),               'allow', 'stop: Grep (non-mutating) allowed');

# =========================================================================
# bp_active_stop_signal — detection + precedence
# =========================================================================
{
    my $win = "$ROOT/sig"; mkdir $win; mkdir "$win/runs";
    my $dir = realpath_m(fwd($win));
    is(signal($dir,'p'), '', 'signal: none when no marker present');

    open my $h,'>',"$win/runs/.paused" or die; close $h;
    is(signal($dir,'p'), 'paused', 'signal: .paused detected');

    open $h,'>',"$win/runs/p.force-stop" or die; close $h;
    is(signal($dir,'p'), 'forcestop', 'signal: force-stop wins over paused');

    open $h,'>',"$win/runs/.shutdown" or die; close $h;
    is(signal($dir,'p'), 'shutdown', 'signal: shutdown wins over all');

    unlink "$win/runs/.shutdown";
    is(signal($dir,'p'), 'forcestop', 'signal: forcestop after shutdown cleared');

    unlink "$win/runs/p.force-stop";
    is(signal($dir,'p'), 'paused', 'signal: paused after forcestop cleared');

    # a force-stop for a DIFFERENT package must not register for this one
    open $h,'>',"$win/runs/other.force-stop" or die; close $h;
    unlink "$win/runs/.paused";
    is(signal($dir,'p'), '', 'signal: another package force-stop is not ours');
}

# =========================================================================
# gate-stop.sh — resumable-pause clause (no jq needed)
# =========================================================================
{
    # .paused + non-terminal + concrete Next action -> clean resumable stop (0)
    my ($dir,$led) = mk_bp('running', 'Re-run the implementer on the failing case.', paused=>1);
    my ($rc,$out) = run_gstop(BP_DIR=>$dir, BP_LEDGER=>$led, BP_PACKAGE=>'p', BP_PROJECT_ROOT=>$dir);
    is($rc, 0, 'gate-stop: paused + non-terminal + Next action -> allowed (resumable)');
}
{
    # .paused + non-terminal + EMPTY Next action -> blocked (resume needs a handoff)
    my ($dir,$led) = mk_bp('running', '', paused=>1);
    my ($rc,$out) = run_gstop(BP_DIR=>$dir, BP_LEDGER=>$led, BP_PACKAGE=>'p', BP_PROJECT_ROOT=>$dir);
    is($rc, 2, 'gate-stop: paused + empty Next action -> blocked');
}
{
    # .paused AND .shutdown -> shutdown wants a terminal park: pause clause skipped,
    # falls through to the terminal-status requirement -> non-terminal blocked
    my ($dir,$led) = mk_bp('running', 'something', paused=>1, shutdown=>1);
    my ($rc,$out) = run_gstop(BP_DIR=>$dir, BP_LEDGER=>$led, BP_PACKAGE=>'p', BP_PROJECT_ROOT=>$dir);
    is($rc, 2, 'gate-stop: paused+shutdown + non-terminal -> blocked (shutdown wants terminal park)');
}
{
    # no signal + non-terminal -> the existing terminal-status gate still blocks
    my ($dir,$led) = mk_bp('running', 'keep going');
    my ($rc,$out) = run_gstop(BP_DIR=>$dir, BP_LEDGER=>$led, BP_PACKAGE=>'p', BP_PROJECT_ROOT=>$dir);
    is($rc, 2, 'gate-stop: no signal + non-terminal -> blocked (regression: unchanged)');
}
{
    # no signal + terminal parked + fresh + Next action -> allowed (regression)
    my ($dir,$led) = mk_bp('parked', 'Awaiting the API-shape decision (see escalation).');
    my ($rc,$out) = run_gstop(BP_DIR=>$dir, BP_LEDGER=>$led, BP_PACKAGE=>'p', BP_PROJECT_ROOT=>$dir);
    is($rc, 0, 'gate-stop: no signal + parked + Next action -> allowed (regression: unchanged)');
}
{
    # C1: .paused + TERMINAL status -> blocked (a terminal package would be stranded,
    # never auto-resumed). This is the asymmetry the gate exists to protect.
    my ($dir,$led) = mk_bp('parked', 'Re-run the implementer.', paused=>1);
    my ($rc,$out) = run_gstop(BP_DIR=>$dir, BP_LEDGER=>$led, BP_PACKAGE=>'p', BP_PROJECT_ROOT=>$dir);
    is($rc, 2, 'gate-stop: paused + terminal status -> blocked (no stranding)');
}
{
    # C2: .paused + non-terminal + Next action but a STALE ledger -> blocked (the
    # warm resume must hand off current state).
    my ($dir,$led) = mk_bp('running', 'Re-run the implementer.', paused=>1);
    utime(time-1800, time-1800, "$ROOT/bp$bpn/packages/p.md");   # backdate 30 min
    my ($rc,$out) = run_gstop(BP_DIR=>$dir, BP_LEDGER=>$led, BP_PACKAGE=>'p', BP_PROJECT_ROOT=>$dir);
    is($rc, 2, 'gate-stop: paused + stale ledger -> blocked');
}

# =========================================================================
# track-dispatch.sh — phantom-marker guard under a stop signal (no jq path)
# =========================================================================
{
    my ($dir,$led) = mk_bp('running', 'x', paused=>1);
    my ($rc,$out) = run_track(BP_DIR=>$dir, BP_LEDGER=>$led, BP_PACKAGE=>'p', BP_PROJECT_ROOT=>$dir);
    is($rc, 0, 'track-dispatch: stop signal -> early exit 0 (before jq)');
    ok(! -e "$ROOT/bp$bpn/runs/p.active-worker", 'track-dispatch: no phantom active-worker marker written under a stop');
}

# =========================================================================
# gate-shutdown.sh — PreToolUse wiring (needs jq; runs in the sandbox)
# =========================================================================
SKIP: {
    skip "jq not available on this host (gate-shutdown is fail-closed without it)", 10 unless $have_jq;

    my ($dir) = mk_bp('running', 'x');                       # no signals yet
    my %env = (BP_DIR=>$dir, BP_LEDGER=>"$dir/packages/p.md", BP_PACKAGE=>'p', BP_PROJECT_ROOT=>$dir);
    my $task = $J->encode({ tool_name=>'Task', tool_input=>{ subagent_type=>'butler:bp-implementer' } });

    my ($rc) = run_gate($task, %env);
    is($rc, 0, 'gate-shutdown: no signal -> Task allowed');

    open my $h,'>',"$ROOT/bp$bpn/runs/.shutdown" or die; close $h;  # raise shutdown
    my ($rc2,$out2) = run_gate($task, %env);
    is($rc2, 2, 'gate-shutdown: shutdown -> Task denied');
    like($out2, qr/shutdown/i, 'gate-shutdown: deny message names the shutdown');

    my $edit_ledger = $J->encode({ tool_name=>'Edit', cwd=>$dir, tool_input=>{ file_path=>"$dir/packages/p.md" } });
    my ($rc3) = run_gate($edit_ledger, %env);
    is($rc3, 0, 'gate-shutdown: shutdown -> ledger park-write allowed');

    # A real worksite path OUTSIDE both the blueprint dir and /tmp. The /tmp scratch
    # exemption mirrors guard-writes.sh; in-container File::Temp dirs live under /tmp,
    # so a tempdir-relative "worksite" would be wrongly exempt — use a stable absolute
    # path that is neither BP_DIR nor /tmp.
    my $edit_work = $J->encode({ tool_name=>'Edit', cwd=>$dir, tool_input=>{ file_path=>'/srv/project/src/work.pl' } });
    my ($rc4) = run_gate($edit_work, %env);
    is($rc4, 2, 'gate-shutdown: shutdown -> worksite edit denied');

    unlink "$ROOT/bp$bpn/runs/.shutdown";
    open $h,'>',"$ROOT/bp$bpn/runs/.paused" or die; close $h;       # raise pause
    my ($rc5,$out5) = run_gate($task, %env);
    is($rc5, 2, 'gate-shutdown: paused -> Task denied');
    like($out5, qr/resume/i, 'gate-shutdown: pause message promises auto-resume');

    unlink "$ROOT/bp$bpn/runs/.paused";
    open $h,'>',"$ROOT/bp$bpn/runs/p.force-stop" or die; close $h;  # raise force-stop
    my ($rc6) = run_gate($task, %env);
    is($rc6, 2, 'gate-shutdown: force-stop -> Task denied');

    # H2: a mutating tool with no file_path is suspicious -> fail closed (deny)
    open $h,'>',"$ROOT/bp$bpn/runs/.shutdown" or die; close $h;
    my $edit_nopath = $J->encode({ tool_name=>'Edit', cwd=>$dir, tool_input=>{} });
    my ($rc7) = run_gate($edit_nopath, %env);
    is($rc7, 2, 'gate-shutdown: edit with no file_path -> denied (fail closed)');

    # L1: a payload with no tool_name under an active stop -> fail closed (deny)
    my $notool = $J->encode({ tool_input=>{ file_path=>"$dir/x" } });
    my ($rc8) = run_gate($notool, %env);
    is($rc8, 2, 'gate-shutdown: missing tool_name -> denied (fail closed)');
}
