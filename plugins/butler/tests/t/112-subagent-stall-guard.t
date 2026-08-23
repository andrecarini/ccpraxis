#!/usr/bin/env perl
# t/112-subagent-stall-guard.t — the stop gate is a STATE MACHINE.
#
# THE FAILURE. A turn that ends mid-run schedules nothing: no notification is
# pending, nothing wakes the session, and an unattended run simply stops until
# someone notices hours later. It recurred all evening, and each time the
# remedy was written down as guidance. Guidance did not hold — the same lesson
# guard-git-mutations.sh was born from, where a prohibited command destroyed a
# completed fix-batch that an instruction was supposed to protect.
#
# TWO DETECTORS WERE TRIED FIRST, AND BOTH WERE WRONG IN THE SAME WAY.
#   1. "A Bash command containing the token BP_STALL_GUARD clears the alarm."
#      A guard that died on launch contains the token just as well as a live
#      one. It verified ceremony, not function.
#   2. "Deny if the closing prose promises work." Sidestepped by rephrasing a
#      sentence — a gate the guarded party can talk its way out of.
# A detector is only as good as its guesses. So the default is inverted:
#
#   INERT until a run demonstrably starts; then DENY until the agent RESOLVES
#   it, with exactly two resolutions and no third:
#       finish — nothing pending
#       pause  — a LIVE watcher will wake us (verified pid + future deadline)
#
# Silence is not a resolution, and neither is a plausible sentence.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

(my $HOOKS   = "$Bin/../../hooks")   =~ s{\\}{/}g;
(my $SCRIPTS = "$Bin/../../scripts") =~ s{\\}{/}g;
my $GUARD = "$HOOKS/guard-subagent-stall.sh";
my $RS    = "$SCRIPTS/bp-runstate.pl";

ok(-f $GUARD, 'guard-subagent-stall.sh exists') or BAIL_OUT('hook missing');
ok(-x $GUARD, 'guard-subagent-stall.sh is executable');
ok(-f $RS,    'bp-runstate.pl exists')          or BAIL_OUT('state machine missing');

my $J = JSON::PP->new->canonical;

sub rs {                      # run the state machine CLI -> (exit, stdout)
    my ($root, @args) = @_;
    my $cmd = qq{perl "$RS" } . join(' ', @args) . qq{ --root "$root" 2>/dev/null};
    my $out = `$cmd`;
    return ($? >> 8, $out // '');
}
sub state_of {
    my ($root) = @_;
    my (undef, $out) = rs($root, 'status');
    my $j = eval { JSON::PP->new->decode($out) } || {};
    return $j->{state} // 'inert';
}
sub fire {                    # feed a payload to the hook -> (exit, stderr)
    my ($root, $payload) = @_;
    my ($fh, $tmp) = File::Temp::tempfile('t112-XXXXXX', TMPDIR => 1);
    print {$fh} $J->encode($payload); close $fh;
    my $err = "$tmp.err";
    my $rc  = system(qq{CLAUDE_PROJECT_DIR="$root" bash "$GUARD" < "$tmp" 2> "$err"});
    my $se  = do { open my $f, '<', $err or return ($rc >> 8, ''); local $/; <$f> // '' };
    unlink $tmp, $err;
    return ($rc >> 8, $se);
}
sub dispatch {
    my ($bg, $desc) = @_;
    my %ti = (description => ($desc // 'a worker'), prompt => 'x');
    $ti{run_in_background} = $bg if defined $bg;
    return { hook_event_name=>'PostToolUse', session_id=>'sess-t112',
             tool_name=>'Task', tool_input=>\%ti };
}
sub bash_ev {
    my ($cmd, $resp) = @_;
    return { hook_event_name=>'PostToolUse', session_id=>'sess-t112', tool_name=>'Bash',
             tool_input=>{ command=>$cmd }, tool_response=>{ stdout=>($resp // '') } };
}
sub stop { { hook_event_name=>'Stop', session_id=>'sess-t112' } }
sub newroot { my $r = tempdir(CLEANUP => 1); mkdir "$r/.ccpraxis-local-data"; return $r }

# ============================ THE STATE MACHINE ============================

{
    my $r = newroot();
    is(state_of($r), 'inert', 'a fresh project is INERT — the gate costs nothing until a run starts');

    rs($r, 'activate', '--reason', '"x"');
    is(state_of($r), 'active', 'activate -> active');

    # A pause is a CLAIM about the world, and the machine checks it.
    my ($rc1) = rs($r, 'pause', '--watcher-pid', 999999, '--until', time + 600);
    isnt($rc1, 0, 'pause REFUSED when the watcher pid is not running');
    is(state_of($r), 'active', '...and the state is unchanged by a refused pause');

    my ($rc2) = rs($r, 'pause', '--watcher-pid', $$, '--until', time - 5);
    isnt($rc2, 0, 'pause REFUSED when the deadline is already past');

    my ($rc3) = rs($r, 'pause', '--watcher-pid', $$);
    isnt($rc3, 0, 'pause REFUSED with no deadline — an unbounded pause never resumes');

    my ($rc4) = rs($r, 'pause', '--watcher-pid', $$, '--until', time + 600);
    is($rc4, 0, 'pause ACCEPTED with a live pid and a future deadline');
    is(state_of($r), 'paused', '...and the state is paused');

    rs($r, 'finish', '--reason', '"done"');
    is(state_of($r), 'finished', 'finish -> finished');
}

# A pause whose watcher DIED reverts to active by itself. Without this, a pause
# outlives its meaning and holds the gate open over an abandoned run — which is
# precisely the failure the gate exists to prevent, reintroduced through the
# resolution path.
{
    my $r = newroot();
    rs($r, 'activate');
    my ($rc) = rs($r, 'pause', '--watcher-pid', $$, '--until', time + 600);
    is($rc, 0, 'pause granted against a live watcher');
    is(state_of($r), 'paused', 'state is paused while the watcher lives');

    # Now make the SAME record stale by hand, rather than by killing a process.
    # Deliberate: perl's fork on this host is emulated and its pid semantics are
    # exactly what bit the wake-lock (see bp-keepawake.pl), so a test that killed
    # a child would be testing Windows process lifetime, not this reversion.
    # Editing the record isolates the property under test.
    my $sp = "$r/.ccpraxis-local-data/.subagent-guard/run-state.json";
    my $rec = JSON::PP->new->decode(do { open my $f,'<',$sp or die; local $/; <$f> });
    $rec->{watcher_pid} = 999999;                       # a pid that is not running
    open my $w, '>', $sp or die; print {$w} $J->encode($rec); close $w;
    is(state_of($r), 'active',
       'watcher gone -> the pause is STALE and reverts to ACTIVE on its own');

    # ...and the same for a deadline that has simply run out.
    $rec->{watcher_pid} = $$; $rec->{until} = time - 1;
    open my $w2, '>', $sp or die; print {$w2} $J->encode($rec); close $w2;
    is(state_of($r), 'active',
       'deadline passed -> the pause is STALE even though the watcher still lives');
}

# ================================ THE GATE =================================

{
    my $r = newroot();
    my ($rc) = fire($r, stop());
    is($rc, 0, 'INERT: stopping is allowed and nothing is in the way');
}

{
    my $r = newroot();
    my ($rc) = fire($r, dispatch(JSON::PP::true, 'b01 test-writer'));
    is($rc, 0, 'a background dispatch is recorded silently');
    is(state_of($r), 'active',
       'ACTIVATION IS AUTOMATIC — dispatching a background subagent starts the run');

    my ($src, $serr) = fire($r, stop());
    is($src, 2, 'ACTIVE: stopping is DENIED');
    like($serr, qr/BLOCKED/,          'the denial says BLOCKED');
    like($serr, qr/b01 test-writer/,  'the denial names the unresolved worker');
    like($serr, qr/bp-runstate\.pl finish/, 'the denial gives the finish verb');
    like($serr, qr/bp-runstate\.pl pause/,  'the denial gives the pause verb');
}

{   # A director tick that hands back work activates too — no subagent needed.
    my $r = newroot();
    fire($r, bash_ev('perl plugins/butler/scripts/bp-drive-next.pl next',
                     '{"action":"run-package","blueprint":"bp","package":"p1"}'));
    is(state_of($r), 'active', 'a director response of run-package ACTIVATES the run');
    my ($rc) = fire($r, stop());
    is($rc, 2, '...and the turn may not simply end');
}

{   # Reading the RESPONSE, not the command: asking is not the same as being
    # handed work. A tick that returns done must not start a run.
    my $r = newroot();
    fire($r, bash_ev('perl plugins/butler/scripts/bp-drive-next.pl next', '{"action":"done"}'));
    is(state_of($r), 'inert', 'a director response of done does NOT activate');
    my ($rc) = fire($r, stop());
    is($rc, 0, '...so stopping stays allowed');
}

{   # The two resolutions, end to end.
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'w'));
    is((fire($r, stop()))[0], 2, 'denied before resolving');
    rs($r, 'finish', '--reason', '"nothing pending"');
    is((fire($r, stop()))[0], 0, 'FINISH resolves it — stopping is allowed');
}
{
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'w'));
    rs($r, 'pause', '--watcher-pid', $$, '--until', time + 600, '--reason', '"watcher"');
    is((fire($r, stop()))[0], 0, 'PAUSE resolves it — stopping is allowed while the watcher lives');
}

{   # Retrying does not wear the gate down. The prose version cleared its marker
    # on denial, so a second stop sailed through; enforcement a retry defeats is
    # advice.
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'w'));
    is((fire($r, stop()))[0], 2, 'first stop denied');
    is((fire($r, stop()))[0], 2, 'second stop denied too — retrying does not bypass it');
    is((fire($r, stop()))[0], 2, 'and a third');
}

{   # Synchronous dispatches hold the turn open, so a hang is already visible.
    my $r = newroot();
    fire($r, dispatch(JSON::PP::false, 'sync worker'));
    is(state_of($r), 'inert', 'a SYNCHRONOUS dispatch does not activate a run');
    is((fire($r, stop()))[0], 0, '...and does not block the stop');
}
{   # The Agent tool defaults to background, so an absent field is the dangerous
    # case and must be treated as such.
    my $r = newroot();
    fire($r, dispatch(undef, 'defaulted worker'));
    is(state_of($r), 'active', 'omitting run_in_background counts as BACKGROUND');
}

{   # force-stop: a gate with no override can strand the operator.
    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'w'));
    my $d = "$r/.ccpraxis-local-data/.subagent-guard";
    open my $f, '>', "$d/force-stop" or die $!; close $f;
    is((fire($r, stop()))[0], 0, 'force-stop overrides the gate outright');
}

{   # NOT bp_hook_gate'd: it must fire in drive-solo, which is where subagents
    # are dispatched by hand and where this failure actually happens.
    my $src = do { open my $f, '<', $GUARD or die; local $/; <$f> };
    unlike($src, qr/^\s*bp_hook_gate\s*$/m,
        'the hook does NOT call bp_hook_gate (it would be inert in drive-solo)');
    like($src, qr/NO bp_hook_gate here, by design/,
        '...and says so, so nobody "fixes" it by adding one');

    my $r = newroot();
    fire($r, dispatch(JSON::PP::true, 'ungated worker'));
    is((fire($r, stop()))[0], 2, 'it denies with no BP_* contract in the environment');
}

{   # No prose anywhere in the DECISION. The gate must not be talkable-out-of.
    #
    # Comments are stripped first, on purpose: the header explains at length why
    # the token and prose-matching designs were wrong, so it legitimately
    # contains both strings. What must not contain them is the executable part.
    my $src = do { open my $f, '<', $GUARD or die; local $/; <$f> };
    my $code = join "\n", grep { !/^\s*#/ } split /\n/, $src;

    unlike($code, qr/\bnext\b.{0,20}I\x27ll/i,
        'the executable gate does not pattern-match the assistant\'s prose (the sidesteppable design)');
    unlike($code, qr/BP_STALL_GUARD/,
        'the executable gate does not accept a magic token in a command (the ceremony design)');
    like($code, qr/bp-runstate\.pl/,
        'the decision is delegated to the state machine');
}

# ---- THE REGISTRATION IS THE LOAD-BEARING HALF ------------------------------
#
# A hook nothing invokes is prose with a shebang. CLAUDE.md makes this argument
# about guard-git-mutations.sh and cited t/61-settings-scope-split.t as its
# protection — a file that DOES NOT EXIST (t/61 is 61-judge-starvation.t, and
# t/14 only checks a generated blob for the subagent self-test). The protection
# was itself imaginary. Both registrations are asserted here instead.
{
    my $sj = "$Bin/../../../../.claude/settings.json";
    ok(-f $sj, '.claude/settings.json exists and is tracked') or BAIL_OUT('no settings.json');
    my $cfg = eval { JSON::PP->new->decode(do { open my $f,'<',$sj or die; local $/; <$f> }) };
    ok($cfg, '.claude/settings.json is valid JSON');

    my @cmds;
    for my $ev (keys %{ $cfg->{hooks} || {} }) {
        for my $blk (@{ $cfg->{hooks}{$ev} || [] }) {
            push @cmds, map { +{ event=>$ev, matcher=>($blk->{matcher}//''), cmd=>($_->{command}//'') } }
                        @{ $blk->{hooks} || [] };
        }
    }
    ok(scalar(grep { $_->{cmd} =~ /guard-git-mutations\.sh/ && $_->{event} eq 'PreToolUse' } @cmds),
       'guard-git-mutations.sh is registered PreToolUse');
    ok(scalar(grep { $_->{cmd} =~ /guard-subagent-stall\.sh/ && $_->{event} eq 'Stop' } @cmds),
       'guard-subagent-stall.sh is registered Stop — without this it can never deny');
    my ($post) = grep { $_->{cmd} =~ /guard-subagent-stall\.sh/ && $_->{event} eq 'PostToolUse' } @cmds;
    ok($post, 'guard-subagent-stall.sh is registered PostToolUse — without this it never activates');
    like(($post//{})->{matcher}//'', qr/Task/, '...its matcher covers Task');
    like(($post//{})->{matcher}//'', qr/Bash/, '...and Bash');
}

# ======================= THE PENDING SET HAS A LIFECYCLE ====================
#
# Closes almanac report 20260819-014748-0b41, filed against this hook. The
# pending-dispatch file was APPEND-ONLY and nothing ever truncated it, so the
# denial message listed every background dispatch of the whole session under the
# heading "this turn". By the end of a long unattended run that is dozens of
# entries, most hours old and already resolved -- noise burying the two lines an
# operator needs.
#
# Broad write, no clear: the same shape as the runs/needs-you/ defect package
# t07 exists to fix, which is why the two were closed together. The rule that
# resolves both is the same one -- clear when the thing the record tracked is
# demonstrably over.
{
    my $r = newroot();
    my $state = "$r/.ccpraxis-local-data/.subagent-guard/sess-t112";

    fire($r, dispatch(1, 'worker one'));
    fire($r, dispatch(1, 'worker two'));
    ok(-s $state, 'pending-set precondition: two background dispatches are recorded');

    # A DENIED stop must NOT clear. A dispatch made two turns ago and still
    # unresolved is still unresolved, and dropping it would hide exactly what
    # this hook exists to surface.
    my (undef, $denied) = fire($r, stop());
    like($denied, qr/worker one/, 'a denied Stop still names the earlier dispatch');
    like($denied, qr/worker two/, '...and the later one');
    ok(-s $state, 'a DENIED Stop leaves the pending set intact -- an unresolved dispatch stays reported');

    # ...and the heading no longer claims a window the file never had.
    unlike($denied, qr/dispatch\(es\) this turn/,
        'the denial no longer says "this turn" about a set that spans the session');
    like($denied, qr/since the last resolved turn/,
        'it names the window the set actually covers');

    # A RESOLVED run means every recorded dispatch is accounted for, so an
    # ALLOWED stop clears.
    my $rs = "$Bin/../../scripts/bp-runstate.pl";
  SKIP: {
        skip('bp-runstate.pl not found', 3) unless -f $rs;
        system(qq{perl "$rs" finish --root "$r" --reason "test" >/dev/null 2>&1});
        my ($rc2, $err2) = fire($r, stop());
        is($rc2, 0, 'a finished run lets the turn end');
        is($err2, '', '...silently');
        ok(!-s $state, 'and an ALLOWED Stop clears the pending set, so the next turn starts from empty');
    }

    # Non-vacuity: the clear is real, not an artefact of the file never having
    # been written. A fresh dispatch after the clear must reappear.
    fire($r, dispatch(1, 'worker three'));
    my (undef, $again) = fire($r, stop());
    like($again, qr/worker three/, 'a dispatch AFTER the clear is reported again');
    unlike($again, qr/worker one/,
        'and the cleared ones do not come back -- the truncation is a real reset, not a display filter');
}

done_testing();
