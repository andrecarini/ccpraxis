#!/usr/bin/env perl
# platform: any
# Every podman call the launcher makes before the dashboard is BOUNDED, and a
# call that runs out of time fails its stage with a clear message instead of
# leaving the launch at "pending" forever (bug report 20261110-165535-d71b).
#
# WHAT HAPPENED. On 2026-11-10 the WSL VM under podman wedged. The launcher's
# bare-backtick `podman image inspect claude-sandbox:latest` hung with it, and
# the operator watched "skills, plugins and MCP: pending" / "(no output yet)"
# with nothing to tell it from a slow build.
#
# HOW THIS TESTS IT WITHOUT PODMAN. Nothing here runs the real podman or wsl
# (they were hung on the host this was written on) and nothing spawns
# launcher.pl. The podman seam is the launcher's $PODMAN: the subs under test
# are extracted from launcher.pl's source and evaluated with $PODMAN pointed at
# FAKE podman scripts -- one that never answers, one that answers at once, one
# that streams like a slow build. BoundedRun.pm is exercised directly.
#
# NON-VACUITY. Run against the pre-change tree (git archive HEAD), this file
# fails: BoundedRun.pm does not exist, the launcher subs are not there, and the
# source scan finds the unbounded backticks.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp ();
use POSIX ();
use Time::HiRes ();
use lib "$Bin/../../scripts";

my $SCRIPTS  = "$Bin/../../scripts";
my $LAUNCHER = "$SCRIPTS/launcher.pl";
my $WINDOWS  = ($^O =~ /\A(?:MSWin32|cygwin|msys)\z/) ? 1 : 0;

sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return undef; local $/; my $s = <$fh>; close $fh; return $s }
sub now   { return Time::HiRes::time() }
sub alive { my ($pid) = @_; return 0 unless defined $pid && $pid =~ /\A\d+\z/; return kill(0, $pid) ? 1 : 0 }

my $have_br = eval { require BoundedRun; 1 } ? 1 : 0;
ok($have_br, 'BoundedRun.pm loads') or diag($@);

# ---------------------------------------------------------------------------
# Fake podman binaries. Each records its own pid, so a test can prove the
# process that was spawned -- not merely the one perl waited on -- is gone.
# ---------------------------------------------------------------------------
my $TMP = File::Temp::tempdir('podman-bounded-XXXXXX', TMPDIR => 1, CLEANUP => 1);
$TMP =~ s{\\}{/}g;
sub fake {
    my ($name, $body) = @_;
    my $p = "$TMP/$name";
    open my $fh, '>:raw', $p or die "write $p: $!";
    print {$fh} "#!$^X\nuse strict; use warnings; \$| = 1;\n"
              . "if (defined \$ENV{FAKE_PID_FILE}) { open my \$f, '>', \$ENV{FAKE_PID_FILE}; print {\$f} \$\$; close \$f }\n"
              . $body;
    close $fh;
    chmod 0755, $p;
    return $p;
}
my $HANG   = fake('podman-hang',   "sleep 1 while 1;\n");
my $FAST   = fake('podman-fast',   "print qq{5.2.0\\n}; print STDERR qq{note\\n}; exit 0;\n");
my $FAIL   = fake('podman-fail',   "print STDERR qq{Error: cannot connect to Podman socket\\n}; exit 125;\n");
# Streams a line every 0.5 s for ~4 s: a slow build that is making progress.
my $STREAM = fake('podman-stream', "for my \$i (1 .. 8) { print qq{STEP \$i/8\\n}; select(undef, undef, undef, 0.5) } exit 0;\n");
# Prints once, then goes silent forever: a build that stopped making progress.
my $STALL  = fake('podman-stall',  "print qq{STEP 1/8\\n}; sleep 1 while 1;\n");

sub read_pid { my ($f) = @_; my $s = slurp($f); return (defined $s && $s =~ /(\d+)/) ? $1 : undef }

SKIP: {
    skip 'BoundedRun.pm missing', 1 unless $have_br;

    # --- the hang: a wall-clock timeout fires, kills, reaps -----------------
    {
        my $pf = "$TMP/hang.pid";
        local $ENV{FAKE_PID_FILE} = $pf;
        my $t0 = now();
        my $r = BoundedRun::run(cmd => [ $HANG, 'image', 'inspect', 'x' ], timeout => 2);
        my $took = now() - $t0;
        ok($r->{timed_out}, 'hang: a podman that never answers is timed out');
        is($r->{reason}, 'timeout', 'hang: the reason is the wall clock');
        is($r->{rc}, BoundedRun::TIMEOUT_RC(), 'hang: rc is the timeout code (124 << 8)');
        cmp_ok($took, '>=', 1.9, 'hang: it waited for the bound');
        cmp_ok($took, '<', 12, "hang: and returned soon after it (took ${took}s), not forever");
        ok($r->{reaped}, 'hang: the killed child was reaped');
        my $fp = read_pid($pf);
        ok(defined $fp, 'hang: the fake recorded its pid');
        ok(!alive($fp), 'hang: the fake podman process is gone');
        is_deeply(BoundedRun::active_pids(), [], 'hang: nothing left in the active set');
    }

    # --- the same hang through a SHELL string (the backtick form) ----------
    {
        my $pf = "$TMP/hang-sh.pid";
        local $ENV{FAKE_PID_FILE} = $pf;
        my $r = BoundedRun::run(cmd => qq{"$HANG" image inspect x 2>&1}, timeout => 2);
        ok($r->{timed_out}, 'hang via sh: timed out');
        my $fp = read_pid($pf);
        ok(defined $fp && !alive($fp), 'hang via sh: the grandchild podman (under sh) is gone too');
    }

    # --- a fast podman passes untouched ------------------------------------
    {
        my $t0 = now();
        my $r = BoundedRun::run(cmd => [ $FAST, 'version' ], timeout => 20);
        ok(!$r->{timed_out}, 'fast: not timed out');
        is($r->{rc}, 0, 'fast: rc 0');
        is($r->{out}, "5.2.0\n", 'fast: stdout captured');
        is($r->{err}, "note\n", 'fast: stderr captured apart from stdout');
        cmp_ok(now() - $t0, '<', 5, 'fast: returned promptly');
        my $m = BoundedRun::run(cmd => [ $FAST ], timeout => 20, merge => 1);
        like($m->{out}, qr/5\.2\.0/, 'merge: stdout present');
        like($m->{out}, qr/note/, 'merge: stderr joined into stdout');
        my $f = BoundedRun::run(cmd => [ $FAIL ], timeout => 20);
        is($f->{rc} >> 8, 125, 'a quick failure keeps its own exit code');
        ok(!$f->{timed_out}, 'a quick failure is not a timeout');
        my $s = BoundedRun::run(cmd => qq{"$FAST" version 2>/dev/null}, timeout => 20);
        is($s->{out}, "5.2.0\n", 'shell-string form honours its own redirections');
    }

    # --- a streaming build is NOT killed by the inactivity watchdog --------
    {
        my @lines;
        my $r = BoundedRun::run(cmd => [ $STREAM, 'build', '.' ], idle_timeout => 2, merge => 1,
                                on_output => sub { push @lines, $_[0] });
        ok(!$r->{timed_out}, 'stream: a build that keeps printing outlives a 2 s idle watchdog (~4 s run)');
        is($r->{rc}, 0, 'stream: rc 0');
        is(scalar(@lines), 8, 'stream: every line reached on_output');
        is($lines[0], "STEP 1/8\n", 'stream: lines arrive whole');
    }
    # ... and one that stops printing IS
    {
        my $t0 = now();
        my @lines;
        my $r = BoundedRun::run(cmd => [ $STALL, 'build', '.' ], idle_timeout => 2, merge => 1,
                                on_output => sub { push @lines, $_[0] });
        ok($r->{timed_out}, 'stall: a build silent past the idle bound is stopped');
        is($r->{reason}, 'idle', 'stall: the reason is inactivity');
        is(scalar(@lines), 1, 'stall: its output so far was still delivered');
        cmp_ok(now() - $t0, '<', 12, 'stall: returned soon after the bound');
    }

    # --- on_tick runs while waiting, and kill_active ends a run mid-flight --
    {
        my ($ticks, $seen) = (0, undef);
        my $r = BoundedRun::run(cmd => [ $HANG ], timeout => 30,
            on_tick => sub {
                $ticks++;
                if ($_[0] >= 1 && !defined $seen) { $seen = BoundedRun::active_pids(); BoundedRun::kill_active() }
            });
        cmp_ok($ticks, '>', 3, 'on_tick is called repeatedly during a wait');
        ok(ref $seen eq 'ARRAY' && @$seen == 1, 'active_pids names the running child');
        ok(!$r->{timed_out} && $r->{reaped}, 'kill_active ended the run long before its 30 s bound');
        ok(!alive($seen->[0]), 'kill_active: the child is gone');
    }

    # --- Windows: the WHOLE tree dies, not just the direct child -----------
    # Measured while writing this: kill('KILL', msys_pid) ends the direct
    # native child but leaves its children running. This is the one place
    # that needs a real native tree; cmd.exe and ping.exe are harmless.
    SKIP: {
        skip 'native process tree only on Windows', 2 unless $WINDOWS;
        my $count = sub { scalar grep { /\APING\.EXE\s/i } `tasklist 2>/dev/null` };
        my $before = $count->();
        local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
        my $r = BoundedRun::run(cmd => [ 'cmd.exe', '/c', 'ping.exe', '-n', '60', '127.0.0.47' ],
                                timeout => 3);
        ok($r->{timed_out}, 'tree: cmd.exe -> ping.exe timed out');
        Time::HiRes::sleep(0.5);
        is($count->(), $before, 'tree: the grandchild ping.exe was killed with its parent (taskkill /T via WINPID)');
    }

    # --- limits and classification -----------------------------------------
    is_deeply({ BoundedRun::limits('probe',  {}) }, { timeout => 20 },       'limits: probe 20 s');
    is_deeply({ BoundedRun::limits('query',  {}) }, { timeout => 30 },       'limits: query 30 s');
    is_deeply({ BoundedRun::limits('mutate', {}) }, { timeout => 180 },      'limits: mutate 180 s');
    is_deeply({ BoundedRun::limits('stream', {}) }, { idle_timeout => 900 }, 'limits: stream = 15 min idle, no wall clock');
    is_deeply({ BoundedRun::limits('bogus',  {}) }, { timeout => 30 },       'limits: an unknown kind is still bounded');
    is_deeply({ BoundedRun::limits('query', { SANDBOX_PODMAN_QUERY_TIMEOUT => '45' }) }, { timeout => 45 },
              'limits: env override');
    is_deeply({ BoundedRun::limits('query', { SANDBOX_PODMAN_QUERY_TIMEOUT => '4; rm' }) }, { timeout => 30 },
              'limits: a non-numeric override is ignored');
    my %kind = (
        'build -t x .'            => 'stream', 'image build .'       => 'stream',
        'pull alpine'             => 'stream', 'image inspect x'     => 'query',
        'inspect c'               => 'query',  'ps -a'               => 'query',
        'machine list'            => 'query',  'machine inspect'     => 'query',
        'info --format x'         => 'query',  'version'             => 'query',
        'start c'                 => 'mutate', 'create --name c i'   => 'mutate',
        'rm -f c'                 => 'mutate', 'exec c touch /tmp/x' => 'mutate',
        'machine start'           => 'mutate', '--log-level debug build .' => 'stream',
    );
    for my $k (sort keys %kind) {
        is(BoundedRun::podman_kind(split / /, $k), $kind{$k}, "podman_kind($k) = $kind{$k}");
    }

    # --- the message --------------------------------------------------------
    {
        my @l = BoundedRun::unresponsive_lines(cmd => [ 'C:/x/podman.exe', 'image', 'inspect', 'claude-sandbox:latest' ],
                                               reason => 'timeout', limit => 30,
                                               stage => 'preflight checks', windows => 1);
        my $t = join "\n", @l;
        like($t, qr/podman is not responding -- the WSL VM may be wedged/, 'message: says what is wrong');
        like($t, qr/`podman\.exe image inspect claude-sandbox:latest` did not answer within 30s/, 'message: names the call and the bound');
        like($t, qr/failed at 'preflight checks'/, 'message: names the stage');
        my ($i1) = grep { $l[$_] =~ /wsl --shutdown --force/ } 0 .. $#l;
        my ($i2) = grep { $l[$_] =~ /Restart-Service WSLService -Force/ } 0 .. $#l;
        my ($i3) = grep { $l[$_] =~ /wslservice\.exe and vmmem in Task Manager/ } 0 .. $#l;
        my ($i4) = grep { $l[$_] =~ /Reboot/ } 0 .. $#l;
        ok(defined $i1 && defined $i2 && defined $i3 && defined $i4, 'message: carries the whole remedy ladder');
        ok(defined $i4 && $i1 < $i2 && $i2 <= $i3 && $i3 < $i4, 'message: ladder is cheapest first');
        like($l[$i2] // '', qr/administrator/i, 'message: the service restart says it needs admin');
        my $idle = join "\n", BoundedRun::unresponsive_lines(cmd => 'podman build .', reason => 'idle', limit => 900, windows => 1);
        like($idle, qr/produced no output for 15 min/, 'message: the idle form says "no output", in minutes');
        my $nix = join "\n", BoundedRun::unresponsive_lines(cmd => 'podman ps', reason => 'timeout', limit => 30, windows => 0);
        unlike($nix, qr/wsl/i, 'message: no WSL advice off Windows');
    }
}

# ===========================================================================
# The launcher's own glue, through its $PODMAN seam.
# ===========================================================================
my $SRC = slurp($LAUNCHER);
ok(defined $SRC, 'launcher.pl read');
$SRC //= '';

sub extract_sub {
    my ($name) = @_;
    return undef unless $SRC =~ /^(sub \Q$name\E \{\n.*?\n\}\n)/ms;
    return $1;
}

my @GLUE = qw(_is_podman_cmd _launch_wait_tick _launch_current_stage _podman_unresponsive_fail
              _bounded_run _qx_bounded _preflight_podman_probe _capture_out_err _tee_system _run_timed);
my %body;
for my $n (@GLUE) { $body{$n} = extract_sub($n); ok(defined $body{$n}, "launcher.pl defines $n") }

package LauncherGlue;
our ($PODMAN, $LAUNCH_HOST, $LAUNCH_STAGES, $LAUNCH_LOG, $LAUNCH_PODMAN_FATAL, $LAUNCH_WAIT_LAST_PAINT,
     $WINDOWS_FAMILY, $TRANSCRIPT);
our (@LOG, @FAILED, @VISIBLE, @SHOWN, $REPAINTS);
sub log_ev         { push @LOG, [@_]; return 1 }
sub _launch_fail   { push @FAILED, [@_]; return 1 }
sub _fail_visibly  { push @VISIBLE, @_; return 1 }
sub reset_terminal { return 1 }
sub _launch_repaint { $REPAINTS++; return 1 }
sub _tx_write      { return 1 }
sub _tee_display   { push @SHOWN, $_[0]; return 1 }
package main;

my $glue_ok = 0;
SKIP: {
    skip 'launcher glue or BoundedRun missing', 1 unless $have_br && !grep { !defined $body{$_} } @GLUE;
    require tui::LaunchScreens;
    require LaunchLog;
    require SandboxLock;
    # exit inside the glue must not end this test: it dies with a marker.
    my $code = "package LauncherGlue;\nno strict 'vars';\nuse subs 'exit';\nsub exit { die \"EXIT:\$_[0]\\n\" }\n"
             . join('', map { $body{$_} } @GLUE) . "\n1;\n";
    $glue_ok = eval $code;
    ok($glue_ok, 'the extracted glue compiles') or diag($@);
}

sub reset_glue {
    my (%o) = @_;
    $LauncherGlue::PODMAN              = $o{podman};
    $LauncherGlue::WINDOWS_FAMILY      = $WINDOWS;
    $LauncherGlue::LAUNCH_PODMAN_FATAL = exists $o{fatal} ? $o{fatal} : 1;
    $LauncherGlue::LAUNCH_WAIT_LAST_PAINT = 0;
    $LauncherGlue::LAUNCH_HOST         = $o{host};
    $LauncherGlue::TRANSCRIPT          = undef;
    $LauncherGlue::LAUNCH_STAGES       = tui::LaunchScreens::stages_init(undef);
    @LauncherGlue::LOG = @LauncherGlue::FAILED = @LauncherGlue::VISIBLE = @LauncherGlue::SHOWN = ();
    $LauncherGlue::REPAINTS = 0;
}

SKIP: {
    skip 'glue did not compile', 1 unless $glue_ok;

    # --- preflight probe, hung podman: the FIRST stage fails, clearly -------
    {
        reset_glue(podman => $HANG, host => { mode => 'tui', active => 1 });
        tui::LaunchScreens::stage_begin($LauncherGlue::LAUNCH_STAGES, 'preflight', time);
        local $ENV{SANDBOX_PODMAN_PROBE_TIMEOUT} = 2;
        my $t0 = now();
        my $ok = eval { LauncherGlue::_preflight_podman_probe(); 1 };
        my $err = $@;
        ok(!$ok && $err =~ /\AEXIT:1\b/, 'preflight + hung podman: the launch exits 1 ...');
        cmp_ok(now() - $t0, '<', 12, '... within the probe bound, not forever');
        is($LauncherGlue::FAILED[0][0], 'preflight', '... failing the preflight stage');
        is($LauncherGlue::FAILED[0][1], 'podman is not responding', '... with the stage message');
        my $v = join "\n", @LauncherGlue::VISIBLE;
        like($v, qr/podman is not responding/, 'the operator sees "podman is not responding"');
        like($v, qr/version --format/, 'the message names the call that hung');
        like($v, qr/preflight checks/, 'the message names the stage by its label');
        like($v, qr/wsl --shutdown --force/, 'the remedy ladder is printed') if $WINDOWS;
        ok((grep { $_->[0] eq 'launch_failed' && $_->[1]{reason} eq 'podman not responding' } @LauncherGlue::LOG),
           'a launch_failed event is logged');
        cmp_ok($LauncherGlue::REPAINTS, '>=', 1, 'the frame repainted while waiting (elapsed time can advance)');
    }

    # --- preflight probe, healthy podman: passes ---------------------------
    {
        reset_glue(podman => $FAST);
        local $ENV{SANDBOX_PODMAN_PROBE_TIMEOUT} = 20;
        my $r = eval { LauncherGlue::_preflight_podman_probe() };
        ok($r && !$r->{timed_out} && $r->{rc} == 0, 'preflight + fast podman: passes');
        is(scalar(@LauncherGlue::FAILED), 0, 'preflight + fast podman: nothing failed');
    }

    # --- preflight probe, STOPPED machine (quick error): not a preflight fail
    {
        reset_glue(podman => $FAIL);
        my $r = eval { LauncherGlue::_preflight_podman_probe() };
        ok($r && !$r->{timed_out}, 'preflight + quick "cannot connect": returns (the machine-start path handles it)');
        is(scalar(@LauncherGlue::FAILED), 0, 'preflight + quick error: no stage failed');
    }

    # --- a backtick-replacement query between stages: blamed on the next stage
    {
        reset_glue(podman => $HANG);
        tui::LaunchScreens::stage_end($LauncherGlue::LAUNCH_STAGES, 'preflight', 'ok', time);
        local $ENV{SANDBOX_PODMAN_QUERY_TIMEOUT} = 2;
        my $ok = eval { LauncherGlue::_qx_bounded(qq{$HANG image inspect claude-sandbox:latest 2>&1}); 1 };
        ok(!$ok && $@ =~ /\AEXIT:1/, '_qx_bounded + hung podman: fatal during the launch');
        is($LauncherGlue::FAILED[0][0], 'select', 'between stages, the failure belongs to the stage being prepared');
    }

    # --- after the dashboard is up: bounded, but NOT fatal ------------------
    {
        reset_glue(podman => $HANG, fatal => 0);
        local $ENV{SANDBOX_PODMAN_QUERY_TIMEOUT} = 2;
        my $out = eval { LauncherGlue::_qx_bounded(qq{$HANG ps 2>/dev/null}) };
        my $rc = $?;
        ok(defined $out, '_qx_bounded after the dashboard: returns instead of exiting');
        is($rc, 124 << 8, '... with $? = the timeout code');
        is(scalar(@LauncherGlue::FAILED), 0, '... and fails no stage');
        my $rt = eval { LauncherGlue::_run_timed(qq{$HANG machine list 2>/dev/null}, 2) };
        ok(!defined $rt, '_run_timed keeps its contract: undef on timeout');
    }

    # --- _capture_out_err routes podman through the bound -------------------
    {
        reset_glue(podman => $FAST);
        my ($rc, $out, $err) = LauncherGlue::_capture_out_err($FAST, 'image', 'inspect', 'x');
        is($rc, 0, '_capture_out_err(podman): rc');
        is($out, "5.2.0\n", '_capture_out_err(podman): stdout');
        is($err, "note\n", '_capture_out_err(podman): stderr kept apart');
        reset_glue(podman => $HANG);
        local $ENV{SANDBOX_PODMAN_QUERY_TIMEOUT} = 2;
        my $ok = eval { LauncherGlue::_capture_out_err($HANG, 'image', 'inspect', 'x'); 1 };
        ok(!$ok && $@ =~ /\AEXIT:1/, '_capture_out_err(hung podman): fatal during the launch');
    }

    # --- _tee_system: a streaming build survives; a hung start does not ----
    {
        reset_glue(podman => $STREAM);
        local $ENV{SANDBOX_PODMAN_IDLE_TIMEOUT} = 2;
        my $rc = LauncherGlue::_tee_system($STREAM, 'build', '-t', 'x', '.');
        is($rc, 0, '_tee_system(podman build): a build streaming every 0.5 s for ~4 s is not killed by a 2 s idle watchdog');
        is(scalar(@LauncherGlue::SHOWN), 8, '_tee_system(podman build): every line was displayed as it came');
        is(scalar(@LauncherGlue::FAILED), 0, '_tee_system(podman build): nothing failed');

        reset_glue(podman => $HANG);
        local $ENV{SANDBOX_PODMAN_MUTATE_TIMEOUT} = 2;
        my $t0 = now();
        my $ok = eval { LauncherGlue::_tee_system($HANG, 'start', 'c'); 1 };
        ok(!$ok && $@ =~ /\AEXIT:1/, '_tee_system(hung podman start): fatal');
        cmp_ok(now() - $t0, '<', 12, '_tee_system(hung podman start): within the mutate bound');

        reset_glue(podman => $STREAM);
        local $ENV{SANDBOX_PODMAN_MUTATE_TIMEOUT} = 1;
        local $ENV{SANDBOX_PODMAN_IDLE_TIMEOUT}   = 2;
        my $rc2 = eval { LauncherGlue::_tee_system({ kind => 'stream' }, $STREAM, 'exec', 'c', 'bash', '-c', 'install') };
        is($rc2, 0, '_tee_system({ kind => stream }): a long exec gets the watchdog, not the 1 s mutate clock');
    }
}

# ===========================================================================
# Structure of the launch flow (launcher.pl is not loadable, so: its source).
# ===========================================================================
{
    (my $code = $SRC) =~ s/^\s*#.*$//mg;
    my $dash = index($code, "_launch_stage_begin('dashboard')");
    ok($dash > 0, "the dashboard stage begin is located");
    my $launch = substr($code, 0, $dash > 0 ? $dash : length $code);
    # Strip the definitions that are deliberately not launch-phase podman
    # calls: CLI detection (`podman --version` never reaches the VM) and the
    # interactive session exec (run_claude: it IS the session).
    $launch =~ s/^sub _detect_container_cli \{.*?^\}\n//ms;
    $launch =~ s/^sub run_claude \{.*?^\}\n//ms;
    my @raw;
    push @raw, $1 while $launch =~ /(`\s*(?:\$PODMAN|wsl)\b[^`]{0,60})/g;
    push @raw, $1 while $launch =~ /(\bsystem\s*\(\s*"?\$PODMAN\b[^;]{0,60})/g;
    push @raw, $1 while $launch =~ /(\bopen\s*\(?\s*my\s+\$\w+\s*,\s*'-\|'\s*,\s*\$PODMAN\b[^;]{0,60})/g;
    is(scalar(@raw), 0, 'no unbounded podman/wsl backtick, system() or open-pipe before the dashboard')
        or diag(join("
", map { "unbounded: $_" } @raw));

    my $p_begin = index($code, "_launch_stage_begin('preflight')");
    my $probe   = index($code, "_preflight_podman_probe();");
    my $img     = index($code, 'image inspect $IMAGE_LATEST');
    my $p_end   = index($code, "_launch_stage_end('preflight'");
    ok($p_begin > 0 && $probe > $p_begin, 'preflight begins, then probes podman');
    ok($img > $probe, 'the probe runs before the first image inspect');
    ok($p_end > $img, 'preflight ends only after the image probe');
    my $sel = index($code, "_launch_stage_begin('select')");
    ok($probe > 0 && $sel > $probe, 'the probe runs before the skills/plugins/MCP stage');

    my $off = index($code, '$LAUNCH_PODMAN_FATAL = 0;');
    ok($off > 0 && $off < $dash, 'podman timeouts stop being fatal only as the dashboard stage begins');

    like($code, qr/_tee_system\(\{ kind => 'stream' \}, \$PODMAN, 'exec', \$CONTAINER_NAME,\s*'bash', '-c', \$install_script\)/,
         'the backpack install gets the inactivity watchdog');
    like($code, qr/BoundedRun::kill_active\(\)/, 'teardown kills an in-flight podman child');
}

# ===========================================================================
# The stage line shows elapsed time once a stage has run long enough.
# ===========================================================================
{
    require tui::LaunchScreens;
    my $has = defined &tui::LaunchScreens::STAGE_ELAPSED_AFTER;
    ok($has, 'tui::LaunchScreens::STAGE_ELAPSED_AFTER exists');
    my $after = $has ? tui::LaunchScreens::STAGE_ELAPSED_AFTER() : 10;
    my $row = sub {
        my ($now, $state, $started) = @_;
        my $stages = tui::LaunchScreens::stages_init([ 'preflight', 'select' ]);
        $stages->[1]{state}   = $state;
        $stages->[1]{started} = $started;
        my %seams = defined $now ? (now => sub { $now }) : ();
        my $host = tui::LaunchScreens::make_host(mode => 'tui', %seams);
        $host->{stages} = $stages;
        my $scr = tui::LaunchScreens::progress_screen($host, 120, 30);
        my $line = $scr->{panels}[0]{lines}[1];
        return join '', map { $_->{text} } @$line;
    };
    like($row->(1000 + 75, 'active', 1000), qr/skills, plugins and MCP\s+active  1m\z/,
         'an active stage running 75 s shows "1m"');
    like($row->(1000 + $after + 1, 'active', 1000), qr/active  <1m\z/,
         'past the threshold, under a minute shows "<1m"');
    like($row->(1000 + $after - 2, 'active', 1000), qr/active\z/, 'under the threshold: no figure, the panel stays still');
    like($row->(1000 + 600, 'ok', 1000), qr/ok\z/, 'a finished stage shows no running time');
    like($row->(undef, 'active', 1000), qr/active\z/, 'with no clock seam: no figure (backwards compatible)');
}

# ===========================================================================
# Nothing leaked. The first version of the tree-kill passed every per-call
# check above and still left each timed-out SHELL-STRING fake running (an
# MSYS sh -> perl grandchild has no live Windows parent for taskkill /T to
# follow). Every fake podman ran from $TMP, so any process whose command line
# names $TMP is a leak.
# ===========================================================================
SKIP: {
    skip 'no /proc to inspect', 1 unless -d '/proc';
    Time::HiRes::sleep(0.5);
    my @left;
    if (opendir my $dh, '/proc') {
        for my $p (grep { /\A\d+\z/ && $_ != $$ } readdir $dh) {
            open my $fh, '<', "/proc/$p/cmdline" or next;
            local $/; my $c = <$fh> // ''; close $fh;
            push @left, $p if index($c, $TMP) >= 0;
        }
        closedir $dh;
    }
    is_deeply(\@left, [], 'no fake podman process outlived its timeout');
    kill('KILL', @left) if @left;
}

done_testing();
