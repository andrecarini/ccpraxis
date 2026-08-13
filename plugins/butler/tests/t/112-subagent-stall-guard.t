#!/usr/bin/env perl
# t/112-subagent-stall-guard.t — the turn cannot end with an unguarded
# background subagent.
#
# WHY THIS GATE EXISTS, AND WHY A TEST GUARDS THE GATE.
#
# A background subagent that hangs or dies silently never wakes the session: the
# harness notifies on completion, not on "never completed". So a run dispatches
# a worker, ends the turn, and stops dead until someone notices hours later.
# This recurred, and the remedy was repeatedly recorded as guidance. Guidance did
# not hold — which is the same lesson guard-git-mutations.sh was born from, where
# a prohibited command destroyed a completed fix-batch that an instruction was
# supposed to protect. A written instruction is not an enforcement mechanism.
#
# The properties pinned here are the ones that make it enforcement rather than
# decoration:
#   * a background dispatch followed by a bare stop is DENIED (exit 2)
#   * arming a guard (a Bash command containing BP_STALL_GUARD) permits the stop
#   * a SYNCHRONOUS dispatch never blocks — it holds the turn open, so a hang is
#     already visible, and blocking it would be noise
#   * the hook is NOT bp_hook_gate'd, so it applies in drive-solo, which is the
#     exact context the failure happens in
#   * the deny CLEARS its marker, so one missed guard cannot wedge every
#     subsequent stop
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;

(my $HOOKS = "$Bin/../../hooks") =~ s{\\}{/}g;
my $GUARD = "$HOOKS/guard-subagent-stall.sh";

ok(-f $GUARD, 'guard-subagent-stall.sh exists') or BAIL_OUT('hook missing');
ok(-x $GUARD, 'guard-subagent-stall.sh is executable');

my $J = JSON::PP->new->canonical;

# fire($root, \%payload) -> ($exit, $stderr)
sub fire {
    my ($root, $payload) = @_;
    my $json = $J->encode($payload);
    my ($tmp_fh, $tmp) = File::Temp::tempfile('t112-XXXXXX', TMPDIR => 1);
    print {$tmp_fh} $json; close $tmp_fh;
    my $err = "$tmp.err";
    my $rc = system(qq{CLAUDE_PROJECT_DIR="$root" bash "$GUARD" < "$tmp" 2> "$err"});
    my $stderr = do { open my $f, '<', $err or return ($rc >> 8, ''); local $/; <$f> // '' };
    unlink $tmp, $err;
    return ($rc >> 8, $stderr);
}

sub dispatch { my ($bg, $desc) = @_;
    my %ti = (description => ($desc // 'a worker'), prompt => 'x');
    $ti{run_in_background} = $bg if defined $bg;
    return { hook_event_name => 'PostToolUse', session_id => 'sess-t112',
             tool_name => 'Task', tool_input => \%ti };
}
sub bash_cmd { my ($cmd) = @_;
    return { hook_event_name => 'PostToolUse', session_id => 'sess-t112',
             tool_name => 'Bash', tool_input => { command => $cmd } };
}
sub stop { return { hook_event_name => 'Stop', session_id => 'sess-t112' } }

# ---- 1. The core gate: dispatch then stop -> DENIED --------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my ($rc) = fire($root, dispatch(JSON::PP::true, 'b01 test-writer'));
    is($rc, 0, 'recording a background dispatch is silent and allows the tool');

    my ($src, $serr) = fire($root, stop());
    is($src, 2, 'stopping with an unguarded background dispatch is DENIED');
    like($serr, qr/BLOCKED/, 'the denial says BLOCKED');
    like($serr, qr/b01 test-writer/, 'the denial names the unguarded worker');
    like($serr, qr/REGISTER ITSELF/, 'the denial explains that a guard must prove itself, not merely exist');
    like($serr, qr/armed/,           'the denial names the registration file');
}

# arm($root, %opt) — write a guard registration like a real guard would.
#   pid      : defaults to $$ (this process, definitely alive)
#   deadline : defaults to 10 minutes out
sub arm {
    my ($root, %o) = @_;
    my $dir = "$root/.ccpraxis-local-data/.subagent-guard";
    mkdir $_ for ("$root/.ccpraxis-local-data", $dir);
    open my $f, '>', "$dir/armed" or die $!;
    printf {$f} "%s\n%s\n", ($o{pid} // $$), ($o{deadline} // (time + 600));
    close $f;
}

# ---- 2. A LIVE registered guard permits the stop ----------------------------
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::true, 'w'));
    arm($root);
    my ($src) = fire($root, stop());
    is($src, 0, 'a live guard (running pid, future deadline) permits the stop');
}

# ---- 3. FUNCTION, NOT CEREMONY ----------------------------------------------
#
# These are the cases the first design of this hook got WRONG. It cleared the
# pending set whenever a Bash command merely CONTAINED the token
# BP_STALL_GUARD — so a guard that died on launch, or watched nothing, or was
# never really a guard at all, satisfied it completely. That is the same
# can't-fail check this repo keeps paying for (a03's
# INSTALLED+SKIPPED+FAILED==ITEMS identity). A guard must now PROVE itself.
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::true, 'w'));
    fire($root, bash_cmd('echo "arming BP_STALL_GUARD now"'));   # says it; is not one
    my ($src) = fire($root, stop());
    is($src, 2, 'merely MENTIONING the guard token does not satisfy the gate');
}
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::true, 'w'));
    # pid 999999 is not running: a guard that died the moment it launched.
    arm($root, pid => 999999);
    my ($src, $serr) = fire($root, stop());
    is($src, 2, 'a registration whose process is DEAD does not satisfy the gate');
    like($serr, qr/BLOCKED/, '...and it is reported, not silently tolerated');
}
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::true, 'w'));
    arm($root, deadline => time - 60);   # alive, but its watch already ended
    my ($src) = fire($root, stop());
    is($src, 2, 'a registration whose deadline has PASSED does not satisfy the gate');
}
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::true, 'w'));
    fire($root, bash_cmd('git status --short'));
    my ($src) = fire($root, stop());
    is($src, 2, 'unrelated Bash calls do NOT satisfy the gate');
}

# ---- 4. Synchronous dispatches never block ----------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::false, 'sync worker'));
    my ($src) = fire($root, stop());
    is($src, 0, 'a SYNCHRONOUS dispatch does not require a guard (the turn stays open)');
}

# ---- 5. Absent run_in_background counts as background -----------------------
#
# The Agent tool defaults to background, so omitting the field must be treated
# as the dangerous case, not the safe one.
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(undef, 'defaulted worker'));
    my ($src) = fire($root, stop());
    is($src, 2, 'omitting run_in_background is treated as BACKGROUND and requires a guard');
}

# ---- 6. Several dispatches, one guard ---------------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::true, 'reviewer'));
    fire($root, dispatch(JSON::PP::true, 'redteam'));
    my ($src, $serr) = fire($root, stop());
    is($src, 2, 'two unguarded dispatches deny the stop');
    like($serr, qr/reviewer/ , 'the denial names the first');
    like($serr, qr/redteam/,   'the denial names the second');

    fire($root, dispatch(JSON::PP::true, 'reviewer'));
    fire($root, dispatch(JSON::PP::true, 'redteam'));
    arm($root);
    my ($ok) = fire($root, stop());
    is($ok, 0, 'one live guard may cover several dispatches (it can watch several report paths)');
}

# ---- 7. Retrying the stop does NOT bypass the gate --------------------------
#
# The first design cleared the marker as it denied, so stopping twice sailed
# through — enforcement a retry defeats is advice. The marker now survives the
# denial. It cannot wedge the session because it EXPIRES, and because
# force-stop overrides it outright.
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::true, 'w'));
    my ($first)  = fire($root, stop());
    is($first,  2, 'first stop denied');
    my ($second) = fire($root, stop());
    is($second, 2, 'stopping AGAIN is denied too — a retry does not bypass the gate');

    # ...but it is bounded. With a zero TTL the marker is already stale.
    my ($rc3) = do {
        local $ENV{BP_STALL_GUARD_TTL_S} = 0;
        my $json = $J->encode(stop());
        my ($fh, $tmp) = File::Temp::tempfile('t112-XXXXXX', TMPDIR => 1);
        print {$fh} $json; close $fh;
        my $r = system(qq{CLAUDE_PROJECT_DIR="$root" BP_STALL_GUARD_TTL_S=0 bash "$GUARD" < "$tmp" 2>/dev/null});
        unlink $tmp;
        ($r >> 8);
    };
    is($rc3, 0, 'an EXPIRED marker stops denying — the gate cannot wedge the session forever');
}

# ---- 7b. force-stop is an explicit override ---------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::true, 'w'));
    my $dir = "$root/.ccpraxis-local-data/.subagent-guard";
    open my $f, '>', "$dir/force-stop" or die $!; close $f;
    my ($src) = fire($root, stop());
    is($src, 0, 'force-stop overrides the gate outright (mirrors gate-stop.sh)');
}

# ---- 8. Sessions do not contaminate each other ------------------------------
{
    my $root = tempdir(CLEANUP => 1);
    my $d = dispatch(JSON::PP::true, 'other-session worker');
    $d->{session_id} = 'sess-other';
    fire($root, $d);
    my ($src) = fire($root, stop());   # session sess-t112
    is($src, 0, "another session's pending dispatch does not block this one");
}

# ---- 9. NOT gated: it must fire in drive-solo -------------------------------
#
# Every butler hook but guard-git-mutations.sh opens with bp_hook_gate, which
# exits 0 unless BP_LEDGER/BP_DIR/BP_PROJECT_ROOT are all set. Those come from
# bp-launch.sh, so a gated hook is INERT in a drive-solo run -- which is exactly
# where subagents are dispatched by hand and exactly where this failure bites.
{
    my $src = do { open my $f, '<', $GUARD or die; local $/; <$f> };
    unlike($src, qr/^\s*bp_hook_gate\s*$/m,
        'the hook does NOT call bp_hook_gate (it would be inert in drive-solo)');
    like($src, qr/NO bp_hook_gate here, by design/,
        '...and says so, so it is not "fixed" by someone adding one');

    # Proven behaviourally, not just by reading: no BP_* env set here at all.
    my $root = tempdir(CLEANUP => 1);
    fire($root, dispatch(JSON::PP::true, 'ungated worker'));
    my ($rc) = fire($root, stop());
    is($rc, 2, 'it denies with no BP_* contract in the environment');
}

# ---- 10. THE REGISTRATION IS THE LOAD-BEARING HALF --------------------------
#
# A hook script that nothing invokes is prose with a shebang. CLAUDE.md makes
# exactly this argument about guard-git-mutations.sh -- "if the file is
# untracked, a fresh clone gets the guard script and never runs it" -- and cites
# `t/61-settings-scope-split.t` as the test that fails if the registration goes
# missing.
#
# THAT FILE DOES NOT EXIST. t/61 is 61-judge-starvation.t, and t/14 only checks a
# GENERATED settings blob for the subagent self-test (/x/hooks paths), never the
# repo's real .claude/settings.json. So the protection CLAUDE.md relies on was
# itself imaginary -- the same "claimed enforcement that isn't" this hook was
# written to end. Both registrations are asserted here instead.
{
    my $root = "$Bin/../../../..";
    my $sj   = "$root/.claude/settings.json";
    ok(-f $sj, '.claude/settings.json exists and is tracked') or BAIL_OUT('no settings.json');

    my $raw = do { open my $f, '<', $sj or die; local $/; <$f> };
    my $cfg = eval { JSON::PP->new->decode($raw) };
    ok($cfg, '.claude/settings.json is valid JSON') or diag($raw);

    my @cmds;
    for my $ev (keys %{ $cfg->{hooks} || {} }) {
        for my $blk (@{ $cfg->{hooks}{$ev} || [] }) {
            push @cmds, map { +{ event => $ev, matcher => ($blk->{matcher} // ''), cmd => ($_->{command} // '') } }
                        @{ $blk->{hooks} || [] };
        }
    }

    ok(scalar(grep { $_->{cmd} =~ /guard-git-mutations\.sh/ && $_->{event} eq 'PreToolUse' } @cmds),
       'guard-git-mutations.sh is registered PreToolUse (a prohibited command once destroyed a fix-batch)');

    ok(scalar(grep { $_->{cmd} =~ /guard-subagent-stall\.sh/ && $_->{event} eq 'Stop' } @cmds),
       'guard-subagent-stall.sh is registered as a Stop hook — without this it can never deny');

    my ($post) = grep { $_->{cmd} =~ /guard-subagent-stall\.sh/ && $_->{event} eq 'PostToolUse' } @cmds;
    ok($post, 'guard-subagent-stall.sh is registered PostToolUse — without this it never learns a dispatch happened');
    like(($post // {})->{matcher} // '', qr/Task/,
         '...and its matcher covers Task (the dispatch it must notice)');
    like(($post // {})->{matcher} // '', qr/Bash/,
         '...and Bash (the guard-arming it must notice)');
}

# ---- 11. ANNOUNCED-BUT-DIDN'T ------------------------------------------------
#
# The other half of the same disease: a turn that ends "Next I'll commit these"
# schedules nothing, so the promise is never kept and an unattended run simply
# stops. No subagent is involved, so the dispatch marker is empty and the gate
# above never fires.
#
# This half is a HEURISTIC over prose and is tested as such — the
# false-POSITIVE cases below matter as much as the true ones, because a gate
# that fires on every forward-looking sentence would be turned off within a day.
{
    # transcript($root, $text) -> path to a one-message JSONL transcript
    my $tn = 0;
    my $mk = sub {
        my ($root, $text) = @_;
        my $p = "$root/t" . (++$tn) . ".jsonl";
        open my $f, '>', $p or die $!;
        print {$f} $J->encode({ type => 'assistant',
                                message => { content => [ { type => 'text', text => $text } ] } }), "\n";
        close $f;
        return $p;
    };
    my $stop_with = sub {
        my ($root, $text) = @_;
        my $s = stop();
        $s->{transcript_path} = $mk->($root, $text);
        return (fire($root, $s))[0];
    };

    # -- true positives: a promise with nothing scheduled --
    for my $t (
        'All committed. Next I\'ll commit the stall gate and then continue.',
        'Verified from disk. I\'ll dispatch the implementer for b01.',
        'That is done. Doing it now.',
        'Once the sweep lands I\'ll run the full suite and commit.',
    ) {
        my $root = tempdir(CLEANUP => 1);
        is($stop_with->($root, $t), 2, "denied: promise with nothing scheduled — '" . substr($t,0,38) . "...'");
    }

    # -- false positives it must NOT fire on --
    for my $t (
        'Both suites are green and everything is committed. Nothing needs you.',
        'I could not determine the mechanism; criterion 1 sanctions saying so.',
        'Which would you prefer — the synthetic table, or the real backpack.json?',
        'The fleet holds no wake-lock. That is a defect and I have filed it.',
    ) {
        my $root = tempdir(CLEANUP => 1);
        is($stop_with->($root, $t), 0, "allowed: no promise — '" . substr($t,0,38) . "...'");
    }

    # -- a promise is FINE when something is scheduled to wake the session --
    {
        my $root = tempdir(CLEANUP => 1);
        arm($root);   # live guard: the run will resume on its own
        is($stop_with->($root, 'I\'ll pick this up when the worker reports.'), 0,
           'allowed: a promise is fine when a LIVE guard will resume the session');
    }

    # -- corrects, does not trap --
    {
        my $root = tempdir(CLEANUP => 1);
        my $txt  = 'Next I\'ll commit these.';
        is($stop_with->($root, $txt), 2, 'first stop denied');
        is($stop_with->($root, $txt), 0, 'stopping again is allowed — it corrects rather than traps');
    }

    # -- escape hatches --
    {
        my $root = tempdir(CLEANUP => 1);
        my $dir  = "$root/.ccpraxis-local-data/.subagent-guard";
        mkdir $_ for ("$root/.ccpraxis-local-data", $dir);
        open my $f, '>', "$dir/force-stop" or die $!; close $f;
        is($stop_with->($root, 'Next I\'ll commit these.'), 0, 'force-stop overrides the promise gate');
    }
    {
        my $root = tempdir(CLEANUP => 1);
        my $s = stop(); $s->{transcript_path} = $mk->($root, 'Next I\'ll commit these.');
        my $json = $J->encode($s);
        my ($fh, $tmp) = File::Temp::tempfile('t112-XXXXXX', TMPDIR => 1);
        print {$fh} $json; close $fh;
        my $rc = system(qq{CLAUDE_PROJECT_DIR="$root" BP_NO_PROMISE_GATE=1 bash "$GUARD" < "$tmp" 2>/dev/null});
        unlink $tmp;
        is($rc >> 8, 0, 'BP_NO_PROMISE_GATE=1 disables the heuristic half outright');
    }

    # -- missing/unreadable transcript must fail OPEN --
    {
        my $root = tempdir(CLEANUP => 1);
        my $s = stop(); $s->{transcript_path} = "$root/does-not-exist.jsonl";
        is((fire($root, $s))[0], 0, 'an unreadable transcript fails open, never blocks');
    }
}

done_testing();
