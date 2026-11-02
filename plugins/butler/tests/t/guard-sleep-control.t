#!/usr/bin/env perl
# platform: any
# guard-sleep-control.sh / BpHook::Guards::GuardSleepControl: a Bash-tool
# command that changes the machine's sleep behaviour by hand is denied, and the
# denial names the one sanctioned path (arming continuity). Read-only queries
# stay allowed, and so does everything that merely mentions the commands.
#
# WHY. On 2026-10-29 an unattended session ran `caffeinate -i -s -m -t 50400`
# by hand; its work ended at 23:01 and the assertion kept a lid-closed Mac
# awake until 08:52. The operator: "a deterministic way to interact with
# caffeinate; don't let Claude willy-nilly toggle it on and off."
#
# The deny/allow matrix runs in-process (run_module); a few rows also run
# end to end through the real wrapper, prefilter included (run_wrapper), and
# the prefilter's cost is pinned with the PATH shim: an ordinary command
# starts no perl at all.
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use HostCaps qw(tempdir_args);
use GuardHarness;

my $T = tempdir(tempdir_args(), CLEANUP => 1);
$T =~ s{\\}{/}g;
my $BSD = "$T/state";
my $SID = 'sess-sleep-guard-1';

sub payload {
    my ($cmd, %extra) = @_;
    return { session_id => $SID, transcript_path => "$T/$SID.jsonl", cwd => $T,
             hook_event_name => 'PreToolUse', tool_name => 'Bash',
             tool_input => { command => $cmd }, %extra };
}

sub run_guard {
    my ($cmd, %extra) = @_;
    return GuardHarness::run_module('Guards::GuardSleepControl', payload($cmd, %extra),
        env => { BUTLER_STATE_DIR => $BSD });
}

sub denied {
    my ($cmd, $what, %extra) = @_;
    my $res = run_guard($cmd, %extra);
    my $name = "deny: $cmd";
    $name =~ s/\n/\\n/g;
    is($res->{rc}, 2, $name) or diag($res->{err});
    like($res->{err}, qr/\ABLOCKED: \Q$what\E changes this machine's sleep behaviour by hand/, "$name -- names $what")
        if defined $what;
    my @lines = grep { length } split /\r?\n/, $res->{err};
    cmp_ok(length($_), '<=', 160, "$name -- line within 160 chars") for @lines;
    cmp_ok(scalar(@lines), '<=', 6, "$name -- at most 6 lines");
    is($res->{out}, '', "$name -- nothing on stdout");
    return $res;
}

sub allowed {
    my ($cmd) = @_;
    my $res = run_guard($cmd);
    my $name = "allow: $cmd";
    $name =~ s/\n/\\n/g;
    is($res->{rc}, 0, $name) or diag($res->{err});
    is($res->{err}, '', "$name -- silent");
}

# ---- caffeinate, every spelling ---------------------------------------------
denied('caffeinate -i -s -m -t 50400', 'caffeinate');        # the incident, verbatim
denied('caffeinate -i', 'caffeinate');
denied('/usr/bin/caffeinate -d', 'caffeinate');
denied('=caffeinate -i', 'caffeinate');                       # zsh: the path of caffeinate
denied('\\caffeinate -i', 'caffeinate');
denied('CAFFEINATE -i', 'caffeinate');                        # case-insensitive lookup on macOS
denied("'caffeinate' -i", 'caffeinate');
denied('caf""feinate -i', 'caffeinate');
denied('nohup caffeinate -i -t 3600 &', 'caffeinate');
denied('caffeinate -i -t 600 & echo started', 'caffeinate');
denied('nohup caffeinate -dims > /dev/null 2>&1 &', 'caffeinate');
denied("bash -c 'caffeinate -i -t 60'", 'caffeinate');
denied('zsh -c "caffeinate -s"', 'caffeinate');
denied("sh -lc 'nohup caffeinate -i &'", 'caffeinate');
denied("eval 'caffeinate -i'", 'caffeinate');
denied('env FOO=1 caffeinate -i', 'caffeinate');
denied('sudo caffeinate -s', 'caffeinate');
denied('sudo -u root caffeinate -s', 'caffeinate');
denied('time caffeinate -t 1', 'caffeinate');
denied('timeout 5 caffeinate -i', 'caffeinate');
denied('command caffeinate -i', 'caffeinate');
denied('exec caffeinate -i', 'caffeinate');
denied('noglob caffeinate -i', 'caffeinate');
denied('(caffeinate -i &)', 'caffeinate');
denied('echo $(caffeinate -t 1)', 'caffeinate');
denied('echo `caffeinate -t 1`', 'caffeinate');
denied('make build && caffeinate -i make test', 'caffeinate');
denied('echo -t 60 | xargs caffeinate', 'caffeinate');
denied("echo 'caffeinate -i -t 60' | sh", 'caffeinate');
denied("bash <<'EOF'\ncaffeinate -i -t 60\nEOF", 'caffeinate');
denied('c=caffeinate; $c -i', 'caffeinate');
denied(q{perl -e 'system("caffeinate -i -t 60")'}, 'caffeinate');
denied(q{python3 -c 'import subprocess; subprocess.run(["caffeinate", "-i"])'}, 'caffeinate');
denied(q{osascript -e 'do shell script "caffeinate -i -t 60"'}, 'caffeinate');
denied('killall caffeinate', 'killall caffeinate');
denied('pkill -f caffeinate', 'pkill caffeinate');

# ---- pmset writes (every verb but -g) ----------------------------------------
denied('pmset -a sleep 0', 'pmset -a');
denied('sudo pmset -c sleep 0', 'pmset -c');
denied('sudo pmset -b disablesleep 1', 'pmset -b');
denied('sudo pmset disablesleep 1', 'pmset disablesleep');
denied('pmset noidle', 'pmset noidle');
denied('pmset sleepnow', 'pmset sleepnow');
denied('pmset displaysleepnow', 'pmset displaysleepnow');
denied('sudo pmset schedule wake "11/03/26 08:00:00"', 'pmset schedule');
denied('sudo pmset -u lidwake 1', 'pmset -u');
denied('PMSET -a sleep 0', 'pmset -a');
denied("bash -c 'sudo pmset -a disablesleep 1'", 'pmset -a');
my $r = denied('pmset -a sleep 0', 'pmset -a');
like($r->{err}, qr/^Read-only pmset -g .* is allowed\.$/m, 'pmset deny: says the -g reads stay allowed');

# ---- systemd-inhibit ---------------------------------------------------------
denied('systemd-inhibit --what=sleep sleep 3600', 'systemd-inhibit');
denied('systemd-inhibit sleep 10', 'systemd-inhibit');

# ---- powercfg changes (Windows) ------------------------------------------------
denied('powercfg /change standby-timeout-ac 0', 'powercfg /change');
denied('powercfg -change -standby-timeout-ac 0', 'powercfg -change');
denied('powercfg //setactive SCHEME_MIN', 'powercfg //setactive');
denied('powercfg /requestsoverride PROCESS chrome.exe SYSTEM', 'powercfg /requestsoverride');
denied('powercfg -requestsoverride SERVICE x DISPLAY', 'powercfg -requestsoverride');
denied('POWERCFG.EXE /x -monitor-timeout-ac 0', 'powercfg /x');
denied('powercfg /hibernate off', 'powercfg /hibernate');
denied('/c/Windows/System32/powercfg.exe /change monitor-timeout-ac 0', 'powercfg /change');
denied('powershell -Command "powercfg /change standby-timeout-ac 0"', 'powercfg /change');
$r = denied('powercfg /change standby-timeout-ac 0', 'powercfg /change');
like($r->{err}, qr{^Read-only queries \(powercfg /requests, }m, 'powercfg deny: says the queries stay allowed');

# ---- the Windows assertion, and ccpraxis's own holders, run by hand --------------
denied(q{powershell -Command "Add-Type ...; [K]::SetThreadExecutionState(0x80000003)"}, 'SetThreadExecutionState');
denied('powershell -NoProfile -File C:/x/plugins/sandbox/scripts/keep-awake.ps1 -PidFile k.pid',
    'a hand-started keep-awake helper (keep-awake.ps1)');
denied('perl plugins/butler/scripts/bp-keepawake.pl hold --pid-file /tmp/k.pid',
    'a hand-started keep-awake holder (bp-keepawake.pl hold)');
denied('perl plugins/sandbox/scripts/KeepAwake.pm hold --pid-file /tmp/k.pid',
    'a hand-started keep-awake holder (keepawake.pm hold)');

# ---- allowed: reads, and mentions ------------------------------------------------
allowed($_) for (
    'pmset -g', 'pmset -g ps', 'pmset -g assertions', 'pmset -g log | tail -50', 'sudo pmset -g custom', 'pmset',
    "bash -c 'pmset -g batt'",
    'powercfg /requests', 'powercfg -requests', 'powercfg //requests', 'powercfg /list', 'powercfg /q',
    'powercfg /a', 'powercfg /requestsoverride', 'powercfg', 'POWERCFG /LASTWAKE',
    'systemd-inhibit --list',
    'grep -rn caffeinate plugins/', 'git log --grep caffeinate', 'man caffeinate', 'which caffeinate',
    'echo "never run caffeinate by hand"', q{git commit -m "keep-awake: caffeinate -i only, AC only"},
    q{perl -ne 'print if /caffeinate/' notes.md}, "cat <<'EOF' > notes.md\ncaffeinate -i\nEOF",
    'pgrep -fl caffeinate', 'ps -axo pid,command | grep caffeinate', 'pmset -g assertions | grep -i caffeinate',
    "butler-continuity on --new-thread nightly --goal 'keep going overnight'",
    'perl plugins/butler/tests/t/keepawake-shared.t',
    'CCPRAXIS_CAFFEINATE_BIN=/tmp/fake perl plugins/butler/tests/t/keepawake-shared.t',
    'perl -c plugins/butler/scripts/bp-keepawake.pl', 'perl scripts/run-tests.pl plugins/butler/tests/t/keepawake-shared.t',
    'cat plugins/sandbox/scripts/keep-awake.ps1',
);

# ---- the message names the one sanctioned path, by who is asking -----------------
{
    local $ENV{BUTLER_STATE_DIR} = $BSD;
    $r = run_guard('caffeinate -i');
    like($r->{err}, qr/^The one sanctioned way to keep it awake: arm continuity, butler-continuity on --new-thread <name> --goal '<what this is for>'\.$/m,
        'unarmed main session: the deny names arming continuity');
    like($r->{err}, qr/^The managed lock is held only while work is in flight and released when it ends or continuity is turned off\.$/m,
        'the deny says why the managed lock is the right one');
    like($r->{err}, qr/^Command: caffeinate -i$/m, 'the deny echoes the command');
    if ($^O eq 'darwin') {
        like($r->{err}, qr/^On this Mac it is caffeinate -i, only on AC power: idle sleep is held off, a closed lid always sleeps the Mac\.$/m,
            'on a Mac the deny says what the managed lock does there');
    } else {
        unlike($r->{err}, qr/On this Mac/, 'off a Mac the deny carries no Mac line');
    }
    ok(GuardHarness::fresh_state() && do { $BSD = $ENV{BUTLER_STATE_DIR}; GuardHarness::arm($SID, 'manual') },
        'setup: arm the session');
    $r = run_guard('caffeinate -i');
    like($r->{err}, qr/^This session is armed, so the managed wake-lock already keeps the machine awake while its work is in flight\.$/m,
        'armed main session: the deny says the managed lock already covers it');
    unlike($r->{err}, qr/butler-continuity on/, 'armed main session: not told to arm again');
    $r = run_guard('caffeinate -i', agent_id => 'a1b2c3');
    is($r->{rc}, 2, 'a subagent is denied too');
    like($r->{err}, qr/^Keeping the machine awake belongs to the main session's continuity arm; a subagent never manages it\.$/m,
        'subagent: told it is the main session\'s business');
}

# ---- not a Bash call, or no command: nothing to judge ------------------------------
{
    my $res = GuardHarness::run_module('Guards::GuardSleepControl',
        { %{ payload('x') }, tool_name => 'Write', tool_input => { file_path => "$T/caffeinate.txt", content => 'caffeinate -i' } },
        env => { BUTLER_STATE_DIR => $BSD });
    is($res->{rc}, 0, 'a Write naming caffeinate is not this guard\'s business');
}

# ---- end to end through the wrapper and its case-insensitive prefilter --------------
{
    my $res = GuardHarness::run_wrapper('guard-sleep-control', payload('CaFfEiNaTe -i'), env => { BUTLER_STATE_DIR => $BSD });
    is($res->{rc}, 2, 'wrapper: a mixed-case caffeinate passes the itext: prefilter and is denied');
    like($res->{err}, qr/^BLOCKED: caffeinate /, 'wrapper: with the guard\'s message');
    $res = GuardHarness::run_wrapper('guard-sleep-control', payload('pmset -g ps'), env => { BUTLER_STATE_DIR => $BSD });
    is($res->{rc}, 0, 'wrapper: pmset -g is allowed');
    is($res->{err}, '', 'wrapper: silently');

    my $shim = GuardHarness::run_shim('guard-sleep-control', payload('ls -la && git status'), env => { BUTLER_STATE_DIR => $BSD });
    is($shim->{rc}, 0, 'prefilter: an ordinary command is allowed');
    is(GuardHarness::count_lines($shim->{shim_log}, 'perl'), 0, 'prefilter: and starts no perl at all');
    $shim = GuardHarness::run_shim('guard-sleep-control', payload('POWERCFG /change x 0'), env => { BUTLER_STATE_DIR => $BSD });
    is(GuardHarness::count_lines($shim->{shim_log}, 'perl'), 1, 'prefilter: a target in any case starts exactly one perl');
    is($shim->{rc}, 2, 'prefilter: ...which denies it');
}

done_testing();
