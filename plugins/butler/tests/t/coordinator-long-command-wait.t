#!/usr/bin/env perl
# platform: any
# Regression for bug 20261104-215435-9b1e: an acxpraxis fleet coordinator
# (a headless `claude -p`) could not wait on `make check`, which outlives one
# Bash call. The harness moved its foreground call to the background, and a
# hold on that Bash task id was refused with a bare "the held ids are not
# running background subagents"; a subagent told to run it in the foreground
# returned `completed` while its command still ran, and holding that was
# refused forever.
#
# The refusal itself is correct and stays: Claude Code 2.1.282's print-mode
# wind-down keeps `-p` alive after the final result only while a background
# subagent or workflow runs, and kills every background shell after a
# 5000 ms grace. Letting the stop through on a held shell would kill the
# command being waited on. An interactive session survives the end of a turn,
# which is why the non-coordinator holder rule trusts a live holder on any
# item. What was missing was (1) a refusal that says why and names the shell,
# and (2) a documented, working shape: start the command detached, then wait
# in bounded foreground calls. This file pins all of it:
#
#   A  the holder rule, by role: a coordinator's hold on a running shell does
#      not count; on a running subagent it does; a manual session's live
#      holder on the same shell does (the interactive difference).
#   B  the coordinator refusal through the real stop-gate.sh wrapper: a held
#      shell, an un-held auto-backgrounded shell, and a held subagent that
#      returned while its own command runs all name the shell; a held
#      subagent that is running is allowed; the holder's own task is never
#      named; a dead (finished) shell is not named.
#   C  the doctrine text in coordinator-protocol/SKILL.md and the dispatch
#      prompt, and that the two doctrine commands pass the coordinator's
#      Bash guards (GuardBash, WaitShapeGuard) as written.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep time);

(my $BUTLER = "$Bin/../..") =~ s{\\}{/}g;
my $HOOK  = "$BUTLER/hooks/stop-gate.sh";
my $S     = "$BUTLER/scripts";
my $SKILL = "$BUTLER/skills/coordinator-protocol/SKILL.md";
my $DISPATCH = "$BUTLER/templates/dispatch-prompt.md";

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
my $FAKE_HOME = tempdir(CLEANUP => 1);
$FAKE_HOME =~ s{\\}{/}g;
$ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;

require "$S/BpHook.pm";
require "$S/BpHook/Guards/GuardBash.pm";
require "$S/BpHook/Guards/WaitShapeGuard.pm";

my $REAL_BASH = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH;

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub first_line { my ($t) = @_; my ($l) = split /\n/, ($t // ''); return $l // '' }

my $sidn = 0;
sub next_sid { return sprintf('clcw-%04x', ++$sidn) }

sub tmp_root { my $t = tempdir(CLEANUP => 1); $t =~ s{\\}{/}g; return $t }

# A blueprint dir with a non-terminal, fresh ledger, so the coordinator branch
# reaches its holder rule (step 4) and, failing that, refuses (step 5).
sub mk_bp {
    my $dir = tmp_root();
    make_path("$dir/runs", "$dir/packages");
    open my $l, '>:raw', "$dir/packages/p.md" or die $!;
    print {$l} "---\npackage: p\nstatus: running\nlast_updated: 2026-11-11T00:00:00Z\n---\n# p\n\n## Next action\n\nWait for make check.\n";
    close $l;
    return ($dir, "$dir/packages/p.md");
}

# The holder record, with this test process as the holder: its pid is alive,
# and where /proc exists its cmdline fingerprint matches, so the record reads
# as a live holder to the non-coordinator rule.
sub write_holder {
    my ($root, $sid, @items) = @_;
    my $cmdline = slurp("/proc/$$/cmdline");
    my %rec = (session_id => $sid, token => 'aaaaaaaa', items => [@items],
               deadline => int(time() + 1800), pid => $$);
    $rec{fp} = sha1_hex($cmdline) if length $cmdline;
    make_path("$root/continuity/holder");
    open my $fh, '>:raw', "$root/continuity/holder/$sid.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode(\%rec);
    close $fh;
}

sub payload {
    my ($sid, @bg) = @_;
    return { session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false(),
             background_tasks => [@bg] };
}

sub run_gate {
    my ($p, %env) = @_;
    my ($pfh, $ppath) = tempfile(); print {$pfh} JSON::PP->new->utf8->canonical->encode($p); close $pfh;
    my (undef, $opath) = tempfile();
    my (undef, $epath) = tempfile();
    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{$_} = $env{$_} for keys %env;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', $ppath) or _exit(126);
        open(STDOUT, '>', $opath) or _exit(126);
        open(STDERR, '>', $epath) or _exit(126);
        exec($REAL_BASH, $HOOK);
        _exit(127);
    }
    my $deadline = time() + 20;
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.02);
    }
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    my $res = { rc => $rc, out => slurp($opath), err => slurp($epath) };
    unlink $ppath, $opath, $epath;
    return $res;
}

sub coord_env {
    my ($dir, $led, $root) = @_;
    return (BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir,
            BUTLER_STATE_DIR => $root);
}

my $SHELL_HINT = qr/\b(\S+) is a background shell, which claude -p kills about 5 s after the turn ends, so it cannot be held: wait for it in the foreground \(coordinator-protocol, "Waiting on a long command"\)/;

my $SHELL = { id => 'bur0vqhx8', type => 'shell', status => 'running', command => 'make check' };
my $AGENT = { id => 'a1b2c3d4e5f60718', type => 'subagent', status => 'running' };

# ===========================================================================
# A -- the holder rule, by role (BpHook::holder_live, unit).
# ===========================================================================
{
    my $root = tmp_root();
    my $sid  = next_sid();
    write_holder($root, $sid, $SHELL->{id});
    my ($dir, $led) = mk_bp();
    my $p = payload($sid, $SHELL);
    {
        local %ENV = (%ENV, coord_env($dir, $led, $root));
        is(BpHook::role($p), 'coordinator', 'A1 precondition: BP_LEDGER makes the role coordinator');
        is(BpHook::holder_live($sid, $p), 0,
            'A1: a coordinator hold on a LIVE background shell does not count (claude -p would kill the shell at the end of the turn)');
        write_holder($root, $sid, $SHELL->{id}, $AGENT->{id});
        is(BpHook::holder_live($sid, payload($sid, $SHELL, $AGENT)), 1,
            'A2: a coordinator hold that names a running background subagent counts');
        write_holder($root, $sid, $SHELL->{id});
    }
    {
        local %ENV = (%ENV, BUTLER_STATE_DIR => $root);
        delete local $ENV{BP_LEDGER};
        is(BpHook::role($p), 'manual', 'A3 precondition: without BP_LEDGER the role is manual');
        is(BpHook::holder_live($sid, $p), 1,
            'A3: a manual (interactive) session with a live holder on the same shell id is held -- the interactive difference');
    }
}

# ===========================================================================
# B -- the coordinator refusal through the real stop-gate.sh wrapper.
# ===========================================================================
{
    # B1: bug item 1 -- the auto-backgrounded make check, held.
    my ($dir, $led) = mk_bp();
    my $root = tmp_root();
    my $sid  = next_sid();
    write_holder($root, $sid, $SHELL->{id});
    my $res = run_gate(payload($sid, $SHELL), coord_env($dir, $led, $root));
    is($res->{rc}, 2, 'B1: a coordinator holding a running background shell is refused (exit 2)');
    my $l1 = first_line($res->{err});
    like($l1, qr/^Coordinator stop refused: the held ids are not running background subagents; /,
        'B1: line 1 keeps the R6 reason');
    like($l1, $SHELL_HINT, 'B1: line 1 explains why a shell cannot be held and where the foreground wait is documented');
    my ($named) = $l1 =~ $SHELL_HINT;
    is($named, $SHELL->{id}, 'B1: the refusal names the held shell');
}
{
    # B2: the same shell, not held: the ledger refusal names it too, so the
    # coordinator never tries to hold it.
    my ($dir, $led) = mk_bp();
    my $root = tmp_root();
    my $sid  = next_sid();
    my $res = run_gate(payload($sid, $SHELL), coord_env($dir, $led, $root));
    is($res->{rc}, 2, 'B2: an un-held auto-backgrounded shell and a non-terminal ledger -> exit 2');
    my $l1 = first_line($res->{err});
    like($l1, qr/^Coordinator stop refused: status 'running' is not terminal; /, 'B2: line 1 keeps the ledger reason');
    like($l1, $SHELL_HINT, 'B2: line 1 names the shell');
}
{
    # B3: bug item 2 -- the held subagent returned (gone from the payload)
    # while the command it started still runs; that command shows up in the
    # parent's background_tasks as a shell of its own (measured, package 08
    # of hook-continuity-remake). Refused, naming the nested shell.
    my ($dir, $led) = mk_bp();
    my $root = tmp_root();
    my $sid  = next_sid();
    write_holder($root, $sid, $AGENT->{id});
    my $nested = { id => 'bekzbi53d', type => 'shell', status => 'running', command => 'make check' };
    my $res = run_gate(payload($sid, { %$AGENT, status => 'completed' }, $nested), coord_env($dir, $led, $root));
    is($res->{rc}, 2, 'B3: a held subagent that returned while its own command runs is refused (exit 2)');
    my ($named) = first_line($res->{err}) =~ $SHELL_HINT;
    is($named, 'bekzbi53d', 'B3: the refusal names the nested command\'s shell, not the finished subagent');
}
{
    # B4: the holder's own task is a running shell too; it is never named.
    my ($dir, $led) = mk_bp();
    my $root = tmp_root();
    my $sid  = next_sid();
    write_holder($root, $sid, $AGENT->{id});
    my $holder_task = { id => 'bhold0001', type => 'shell', status => 'running',
                        command => "butler-hold --token aaaaaaaa $AGENT->{id}" };
    my $res = run_gate(payload($sid, { %$AGENT, status => 'completed' }, $holder_task), coord_env($dir, $led, $root));
    is($res->{rc}, 2, 'B4: precondition: the held subagent is finished -> exit 2');
    my $l1 = first_line($res->{err});
    like($l1, qr/the held ids are not running background subagents/, 'B4: R6');
    unlike($l1, qr/is a background shell/, 'B4: a butler-hold task is never named as a shell to wait on');
}
{
    # B5: a finished (dead) shell is not running work: no hint.
    my ($dir, $led) = mk_bp();
    my $root = tmp_root();
    my $sid  = next_sid();
    write_holder($root, $sid, $SHELL->{id});
    my $res = run_gate(payload($sid, { %$SHELL, status => 'completed' }), coord_env($dir, $led, $root));
    is($res->{rc}, 2, 'B5: a coordinator holding a finished shell is refused (exit 2)');
    my $l1 = first_line($res->{err});
    like($l1, qr/the held ids are not running background subagents\. Stop token: [0-9a-f]{8}$/,
        'B5: line 1 is the bare R6 reason -- a dead shell is not named');
}
{
    # B6: the sanctioned hold -- a running background subagent -- still lets
    # the coordinator stop, even with a shell running beside it.
    my ($dir, $led) = mk_bp();
    my $root = tmp_root();
    my $sid  = next_sid();
    write_holder($root, $sid, $AGENT->{id});
    my $res = run_gate(payload($sid, $AGENT, $SHELL), coord_env($dir, $led, $root));
    is($res->{rc}, 0, 'B6: a coordinator holding a running background subagent may stop (exit 0)');
    is($res->{err}, '', 'B6: no refusal text');
}
{
    # B7: four lines exactly, as the coordinator text has always been.
    my ($dir, $led) = mk_bp();
    my $root = tmp_root();
    my $sid  = next_sid();
    write_holder($root, $sid, $SHELL->{id});
    my $res = run_gate(payload($sid, $SHELL), coord_env($dir, $led, $root));
    my @l = grep { length } split /\n/, $res->{err};
    is(scalar @l, 4, 'B7: the refusal with the shell hint is still exactly 4 lines');
    unlike($res->{err}, qr/butler-continuity/, 'B7: the coordinator text never names butler-continuity');
}

# ===========================================================================
# C -- the doctrine.
# ===========================================================================
my $skill = slurp($SKILL);
ok(length $skill, "C0: $SKILL is readable");
my ($block) = $skill =~ /<!-- continuity:begin -->(.*?)<!-- continuity:end -->/s;
$block //= '';
my ($section) = $skill =~ /^#### Waiting on a long command\n(.*?)^#### /ms;
$section //= '';
ok(length $section, 'C1: coordinator-protocol has a "Waiting on a long command" section, the one the refusal points at');

like($block, qr/Never hold a Bash task id, nor a subagent that returned while its own command runs/,
    'C2: the continuity block forbids holding a Bash task id and a returned subagent');
like($block, qr/`claude -p` kills every background shell/, 'C2: and says why');

like($section, qr/one recommended shape/, 'C3: the section names itself the one recommended shape');
like($section, qr/at most 600000 ms/, 'C3: the Bash ceiling');
like($section, qr/CLAUDE_AUTO_BACKGROUND_TASKS=1/, 'C3: what moves a long call to the background');
like($section, qr/kills every background shell after\s+a 5 s grace/, 'C3: the -p wind-down fact');
like($section, qr/reads `completed`/, 'C3: the subagent-reads-completed fact');
like($section, qr/`timeout: 600000`/, 'C3: the wait call\'s Bash timeout');

my ($start_cmd) = $section =~ /```bash\n(setsid nohup .*?)\n```/s;
my ($wait_cmd)  = $section =~ /```bash\n(timeout 540 tail --pid=<pid> .*?)\n```/s;
ok(defined $start_cmd, 'C4: the section shows the detached start command');
ok(defined $wait_cmd,  'C4: the section shows the bounded foreground wait command');
like($start_cmd // '', qr/echo \$\? > "\$1\/check\.rc"/, 'C4: the start command records the exit code');
like($start_cmd // '', qr/echo "pid=\$!"/, 'C4: the start command prints the pid');
like($wait_cmd // '', qr/elif kill -0 <pid> 2>\/dev\/null; then echo running; else echo "died without an exit code"; fi$/,
    'C4: the wait command tells running from finished from killed');

unlike($skill, qr/launch it with\s+`run_in_background`, then \*\*end your turn\*\*/,
    'C5: the old instruction for coordinators to background a long build is gone');
like($skill, qr/\| a background Bash task, held or left running at the end of a coordinator turn \| the backgrounded job \| `NONE` \| BANNED \|/,
    'C5: the wait-shape table bans a held background Bash task');
like($skill, qr/\| a subagent that returned while a command it started still runs, held \| the subagent's command \| `NONE` \| BANNED \|/,
    'C5: and a held subagent that returned while its command runs');
like($skill, qr/\| a long command, started detached and waited on in bounded foreground calls \(coordinators\) \| the process that pid names \| `pid_alive` \| SANCTIONED \|/,
    'C5: and sanctions the detached-start, foreground-wait shape');

my $dispatch = slurp($DISPATCH);
unlike($dispatch, qr/launch long-running\s+work with `run_in_background`/,
    'C6: the coordinator dispatch prompt no longer tells it to background long work');
like($dispatch, qr/"Waiting on a long command"/, 'C6: it points at the long-command section');

# C7: the two doctrine commands, exactly as written, pass the coordinator's
# own Bash guards -- the doctrine is not a shape the hooks would deny.
{
    my ($dir, $led) = mk_bp();
    local %ENV = (%ENV, coord_env($dir, $led, tmp_root()), BP_ROLE => 'coordinator',
                  BP_REPORT_DIR => "$dir/reports", BP_WRITE_SET => 'src/**');
    (my $wait_real = $wait_cmd // '') =~ s/<pid>/4242/g;
    for my $case (['start', $start_cmd // ''], ['wait', $wait_real]) {
        my ($name, $cmd) = @$case;
        my $p = { session_id => next_sid(), hook_event_name => 'PreToolUse', tool_name => 'Bash',
                  tool_input => { command => $cmd, timeout => 600000 }, cwd => $dir };
        my (undef, $epath) = tempfile();
        my ($gb, $ws);
        {
            open(my $save, '>&', \*STDERR) or die $!;
            open(STDERR, '>', $epath) or die $!;
            $gb = eval { BpHook::Guards::GuardBash::run($p) };
            $ws = eval { BpHook::Guards::WaitShapeGuard::run($p) };
            open(STDERR, '>&', $save) or die $!;
        }
        my $why = slurp($epath);
        unlink $epath;
        is($gb, 0, "C7: GuardBash allows the doctrine's $name command in a coordinator") or diag $why;
        is($ws, 0, "C7: WaitShapeGuard allows the doctrine's $name command in a coordinator") or diag $why;
    }
    # Non-vacuity of C7 itself: the same harness does see a denial.
    my $p = { session_id => next_sid(), hook_event_name => 'PreToolUse', tool_name => 'Bash',
              tool_input => { command => 'while true; do sleep 5; done' }, cwd => $dir };
    my (undef, $epath) = tempfile();
    open(my $save, '>&', \*STDERR) or die $!;
    open(STDERR, '>', $epath) or die $!;
    my $ws = eval { BpHook::Guards::WaitShapeGuard::run($p) };
    open(STDERR, '>&', $save) or die $!;
    unlink $epath;
    is($ws, 2, 'C7 control: the same harness reports a wait-loop denial');
}

done_testing();
