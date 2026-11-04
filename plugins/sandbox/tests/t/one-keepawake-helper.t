#!/usr/bin/env perl
# platform: any
# 07-one-keepawake-helper (blueprint wake-and-pause-consolidation).
#
# Derived from
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/07-one-keepawake-helper-spec.md
# section 4 (AC1-AC5, AC11-AC17) plus the architect's clarification (step2
# report) that AC3's "comment line" means a line matching /^\s*#/. The rest
# of the acceptance table (AC6-AC10, revive/log-tail/rotation through the
# KeepAwake holder) lives in keepawake-helper-revive.t.
#
# This file never spawns launcher.pl, keep-awake.ps1 or powershell.exe. It
# forks only plain perl sleepers (killed in END/INT/TERM) and fresh $^X
# subprocesses whose output is captured to a File::Temp file, never an
# in-memory STDOUT (CLAUDE.md: Git-for-Windows perl fails reopening STDOUT
# onto a scalar).
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use POSIX ();
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec;

my $SANDBOX_SCRIPTS = "$Bin/../../scripts";
my $BUTLER_SCRIPTS  = "$Bin/../../../butler/scripts";
my $LAUNCHER        = "$SANDBOX_SCRIPTS/launcher.pl";
my $KEEPAWAKE_PM    = "$SANDBOX_SCRIPTS/KeepAwake.pm";
my $BP_KEEPAWAKE    = "$BUTLER_SCRIPTS/bp-keepawake.pl";

sub slurp {
    my ($f) = @_;
    open(my $fh, '<:raw', $f) or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

my $LSRC = slurp($LAUNCHER);
ok(defined $LSRC, "precondition: $LAUNCHER is readable") or BAIL_OUT("cannot read launcher.pl");

unshift @INC, $SANDBOX_SCRIPTS;
require "$BP_KEEPAWAKE";

# -----------------------------------------------------------------------
# cleanup discipline for forked plain-perl sleepers (never a real helper).
# -----------------------------------------------------------------------
my @KILL_CHILDREN;
sub reap_all {
    local $?;
    for my $pid (@KILL_CHILDREN) {
        next unless defined $pid;
        kill('KILL', $pid);
        waitpid($pid, 0);
    }
    @KILL_CHILDREN = ();
}
END { reap_all() }
$SIG{INT}  = sub { reap_all(); exit 1 };
$SIG{TERM} = sub { reap_all(); exit 1 };

sub fork_sleeper {
    my ($secs) = @_;
    $secs //= 30;
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) { sleep $secs; POSIX::_exit(0) }
    push @KILL_CHILDREN, $pid;
    return $pid;
}

# =====================================================================
# AC1 [DC1]: launcher.pl no longer defines the three deleted subs.
# =====================================================================
for my $name (qw(_keepawake_start _keepawake_alive _keepawake_reap_orphan)) {
    unlike($LSRC, qr/\bsub\s+\Q$name\E\b/, "AC1: launcher.pl has no sub $name");
}

# =====================================================================
# AC2 [DC1]: no exec/system call in launcher.pl spawns keep-awake.ps1
# directly any more -- every such spawn now lives in BpKeepAwake.
# =====================================================================
sub keepawake_spawn_hits {
    my ($src) = @_;
    my @hits;
    while ($src =~ /\b(?:exec|system)\s*[\(\{]/g) {
        my $after = pos($src);
        my $rest  = substr($src, $after);
        my $semi  = index($rest, ';');
        my $window = $semi >= 0 ? substr($rest, 0, $semi) : $rest;
        push @hits, $after if $window =~ /keep-awake/ || $window =~ /ps1/;
    }
    return @hits;
}

{
    # The detector is proven non-vacuous on an embedded fixture shaped like
    # the OLD _keepawake_start exec (spec section 4, AC2).
    my $fixture = "sub _old_spawn_fixture {\n"
                . "    exec('powershell.exe', '-NoProfile', '-File', \$win_ps1,\n"
                . "         '-PidFile', \$win_pid);\n"
                . "}\n";
    my @fixture_hits = keepawake_spawn_hits($fixture);
    is(scalar(@fixture_hits), 1, 'AC2: the detector is non-vacuous -- it flags the old-shaped exec fixture');
}

like($LSRC, qr/sub\s+_spawn_session\b/, 'AC2 precondition: launcher.pl keeps sub _spawn_session');
{
    my ($spawn_session_body) = $LSRC =~ /(sub _spawn_session \{.*?\n\})/s;
    ok(defined $spawn_session_body, 'AC2 precondition: _spawn_session body is extractable');
    like($spawn_session_body // '', qr/powershell\.exe/,
         'AC2: _spawn_session still spawns powershell.exe (the detector must not need this gone)');
}
{
    my @real_hits = keepawake_spawn_hits($LSRC);
    is(scalar(@real_hits), 0,
       'AC2: no exec/system call in launcher.pl spawns keep-awake.ps1 directly (every such spawn moved into BpKeepAwake)');
}

# =====================================================================
# AC3 [DC1]: every non-comment keep-awake.ps1 line is a pure string
# literal; no non-comment -PidFile; no $ka_helper anywhere.
# =====================================================================
{
    my @lines = split /\n/, $LSRC;
    my $pure_re = qr/^\s*'[^']*keep-awake\.ps1[^']*'\s*\.?\s*$/;
    my @ps1_offenders;
    my @pidfile_offenders;
    my $literal_count = 0;
    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        next if $line =~ /^\s*#/;    # comment, per the architect's clarification
        if ($line =~ /keep-awake\.ps1/) {
            if ($line =~ $pure_re) { $literal_count++ }
            else { push @ps1_offenders, 'line ' . ($i + 1) . ": $line" }
        }
        push @pidfile_offenders, 'line ' . ($i + 1) . ": $line" if $line =~ /-PidFile/;
    }
    is(scalar(@ps1_offenders), 0, 'AC3: every non-comment keep-awake.ps1 line is a pure string literal')
        or diag(join("\n", @ps1_offenders));
    cmp_ok($literal_count, '>=', 1, 'AC3: at least one such pure-string-literal line exists (the operator message)');
    is(scalar(@pidfile_offenders), 0, 'AC3: no non-comment line contains -PidFile')
        or diag(join("\n", @pidfile_offenders));
}
unlike($LSRC, qr/\$ka_helper\b/, 'AC3: launcher.pl contains no $ka_helper');

# =====================================================================
# AC4 [DC2]: KeepAwake.pm's FILETIME copy is gone.
# =====================================================================
{
    my $KASRC = slurp($KEEPAWAKE_PM);
    ok(defined $KASRC, 'precondition: KeepAwake.pm is readable');
    unlike($KASRC, qr/filetime_ticks/, 'AC4: KeepAwake.pm source contains no filetime_ticks');
    unlike($KASRC, qr/11644473600/,    'AC4: KeepAwake.pm source contains no 11644473600');

    require KeepAwake;
    ok(!KeepAwake->can('filetime_ticks'), "AC4: KeepAwake->can('filetime_ticks') is false after require");
}

# =====================================================================
# AC5 [B4]: BpKeepAwake::child_alive on a real forked sleeper.
# =====================================================================
{
    my $has = defined &BpKeepAwake::child_alive;
    ok($has, 'AC5 precondition: BpKeepAwake::child_alive is defined');
    SKIP: {
        skip 'BpKeepAwake::child_alive not defined yet', 5 unless $has;

        my $pid = fork_sleeper(30);
        is(BpKeepAwake::child_alive($pid), 1, 'AC5: a running forked child reads alive (1)');
        kill('KILL', $pid);
        my $deadline = time() + 10;
        my $v;
        while (time() < $deadline) {
            $v = BpKeepAwake::child_alive($pid);
            last unless $v;
            select(undef, undef, undef, 0.1);
        }
        is($v, 0, 'AC5: once killed, child_alive reads 0 within 10s of polling (and reaps it)');
        @KILL_CHILDREN = grep { defined $_ && $_ != $pid } @KILL_CHILDREN;

        is(BpKeepAwake::child_alive(undef), undef, 'AC5: child_alive(undef) is undef');
        is(BpKeepAwake::child_alive('x'),   undef, "AC5: child_alive('x') is undef");
        is(BpKeepAwake::child_alive(0),     undef, 'AC5: child_alive(0) is undef');
    }
}

# =====================================================================
# MINOR-1 (redteam-step6.md): a holder whose start() returned undef (spawn
# failed, or declined -- e.g. CCPRAXIS_NO_WAKELOCK) must not be left
# reporting running()==1 with no live handle behind it forever. That is bug
# 4eca's own class: a machine with no wake-lock, logged held=1 every tick.
# Pure repro, no real helper spawned: KeepAwake->new(start => sub { undef },
# alive => \&BpKeepAwake::child_alive), sync(1), revive.
# =====================================================================
{
    my $has = defined &BpKeepAwake::child_alive && KeepAwake->can('new');
    ok($has, 'MINOR-1 precondition: BpKeepAwake::child_alive and KeepAwake->new are available');
    SKIP: {
        skip 'MINOR-1: BpKeepAwake::child_alive or KeepAwake->new not available yet', 1 unless $has;

        my $clock = \(my $t = 1000);
        my $ka3 = KeepAwake->new(
            start    => sub { undef },
            stop     => sub { },
            alive    => \&BpKeepAwake::child_alive,
            on_event => sub { },
            now      => sub { $$clock },
        );
        $ka3->sync(1);
        # Give the revive gap a few full cycles to play out, in case the fix
        # is to retry start() under $KeepAwake::REVIVE_GAP_SECONDS rather
        # than flip running() to 0 on the very first revive().
        for (1 .. 3) {
            $ka3->revive;
            no warnings 'once';
            $$clock += $KeepAwake::REVIVE_GAP_SECONDS + 1;
        }
        ok(!($ka3->running && !defined($ka3->handle)),
            'MINOR-1: a holder whose start() declined is not left running()==1 with no live handle '
          . 'after revive() has had a chance to notice (bug 4eca\'s class)');
    }
}

# =====================================================================
# MINOR-2 (redteam-step6.md): BpKeepAwake::log_tail must report the helper's
# own RELEASE reason, not the trailing POWER-REQUEST-RELEASED/EXIT lines a
# graceful shutdown appends after it. Today's log_tail returns the literal
# last line, so this fails on a fixture whose last line is EXIT.
# =====================================================================
{
    my $has = defined &BpKeepAwake::log_tail;
    ok($has, 'MINOR-2 precondition: BpKeepAwake::log_tail is defined');
    SKIP: {
        skip 'BpKeepAwake::log_tail not defined yet', 1 unless $has;
        my (undef, $f) = tempfile(SUFFIX => '.log', UNLINK => 1);
        open(my $fh, '>:raw', $f) or die $!;
        print {$fh} "2026-10-31 22:30:07 pid=1 ASSERTED x\r\n"
                  . "2026-10-31 22:41:07 pid=1 RELEASE reason=owner-gone (owner gone)\r\n"
                  . "2026-10-31 22:41:07 pid=1 POWER-REQUEST-RELEASED\r\n"
                  . "2026-10-31 22:41:07 pid=1 EXIT wake-lock released (process exiting)\r\n";
        close $fh;
        is(BpKeepAwake::log_tail($f),
           '2026-10-31 22:41:07 pid=1 RELEASE reason=owner-gone (owner gone)',
           'MINOR-2: log_tail prefers the last RELEASE line over the trailing '
         . 'POWER-REQUEST-RELEASED/EXIT lines that follow it');
    }
}

# =====================================================================
# m2 (reviewer-step6.md): BpKeepAwake::helper_path() must be canonical -- no
# ".." segment -- so it compares equal to a pre-07 helper's -File command
# line and to any caller's own pid-path comparison.
# =====================================================================
{
    my $has = defined &BpKeepAwake::helper_path;
    ok($has, 'm2 precondition: BpKeepAwake::helper_path is defined');
    SKIP: {
        skip 'BpKeepAwake::helper_path not defined yet', 1 unless $has;
        unlike(BpKeepAwake::helper_path(), qr/\.\./,
            'm2: BpKeepAwake::helper_path() is canonical (no ".." segment)');
    }
}

# =====================================================================
# NIT-1 (redteam-step6.md): launcher.pl must pass an ABSOLUTE,
# $INSTALL_ROOT-based path to KeepAwake::load_bp_keepawake, not call it with
# no argument -- a relative launcher invocation plus the first-setup chdir
# otherwise loses the wake-lock silently.
# =====================================================================
like($LSRC, qr/KeepAwake::load_bp_keepawake\(\s*"?\$?\{?INSTALL_ROOT\b/,
    'NIT-1: launcher.pl passes an absolute $INSTALL_ROOT-based path to '
  . 'KeepAwake::load_bp_keepawake, not a bare no-argument call');

# =====================================================================
# AC11 [B2]: BpKeepAwake::lease_seconds (pure).
# =====================================================================
{
    my $has = defined &BpKeepAwake::lease_seconds;
    ok($has, 'AC11 precondition: BpKeepAwake::lease_seconds is defined');
    SKIP: {
        skip 'BpKeepAwake::lease_seconds not defined yet', 6 unless $has;
        my $HL = BpAwakeConst::HELPER_LEASE();
        is(BpKeepAwake::lease_seconds(undef), $HL, 'AC11: lease_seconds(undef) -> HELPER_LEASE');
        is(BpKeepAwake::lease_seconds({}),    $HL, 'AC11: lease_seconds({}) -> HELPER_LEASE');
        is(BpKeepAwake::lease_seconds({ lease_seconds => 'x' }), $HL,
           "AC11: lease_seconds({lease_seconds=>'x'}) -> HELPER_LEASE");
        is(BpKeepAwake::lease_seconds({ lease_seconds => -1 }), $HL,
           'AC11: lease_seconds({lease_seconds=>-1}) -> HELPER_LEASE');
        is(BpKeepAwake::lease_seconds({ lease_seconds => 0 }), 0,
           'AC11: lease_seconds({lease_seconds=>0}) -> 0');
        is(BpKeepAwake::lease_seconds({ lease_seconds => 120 }), 120,
           'AC11: lease_seconds({lease_seconds=>120}) -> 120');
    }
}

# =====================================================================
# AC12 [B1, Windows]: winify / winify_out path translation.
# =====================================================================
SKIP: {
    skip 'B1 path translation is Windows-only', 9 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    require "$SANDBOX_SCRIPTS/MountSpec.pm" unless defined &MountSpec::native_path;

    my $dir = tempdir(DIR => File::Spec->tmpdir(), CLEANUP => 1);
    open(my $fh, '>', "$dir/probe.txt") or die "write probe: $!";
    print {$fh} "x\n";
    close $fh;
    my $target = "$dir/probe.txt";

    my $wout = BpKeepAwake::winify_out($target);
    like($wout, qr{^[A-Za-z]:/}, "AC12: winify_out of a temp-mount path gives a drive path ($wout)");
    my $back = `cygpath -u "$wout"`;
    chomp $back;
    ok(-e $back && (stat($back))[7] == (stat($target))[7],
       'AC12: ...and the translated path round-trips (cygpath -u) to the same file');
    is($wout, MountSpec::native_path($target), 'AC12: winify_out equals MountSpec::native_path for the same input');

    my $win = BpKeepAwake::winify($target);
    like($win, qr{^[A-Za-z]:/}, "AC12: winify of an existing temp-mount path gives a drive path ($win)");
    is($win, MountSpec::native_path($target), 'AC12: winify equals MountSpec::native_path for the same input');

    is(BpKeepAwake::winify('C:/x/y'),     'C:/x/y', 'AC12: winify leaves a drive-letter path unchanged');
    is(BpKeepAwake::winify_out('C:/x/y'), 'C:/x/y', 'AC12: winify_out leaves a drive-letter path unchanged');

    is(BpKeepAwake::winify('/c/x'),     'C:/x', 'AC12: winify(/c/x) gives C:/x');
    is(BpKeepAwake::winify_out('/c/x'), 'C:/x', 'AC12: winify_out(/c/x) gives C:/x');
}

# =====================================================================
# AC13 [B7]: BpKeepAwake::reap_orphan with seams.
# =====================================================================
{
    my $has = defined &BpKeepAwake::reap_orphan;
    ok($has, 'AC13 precondition: BpKeepAwake::reap_orphan is defined');
    SKIP: {
        skip 'BpKeepAwake::reap_orphan not defined yet', 17 unless $has;
        skip 'B7 is Windows-only', 17 unless $^O =~ /^(MSWin32|msys|cygwin)$/;

        my $dir = tempdir(CLEANUP => 1);

        # case 1: a live, matching keep-awake.ps1 helper -> 'gone', taskkill called, pid file removed.
        {
            my $pid_f = "$dir/keepawake1.pid";
            open(my $fh, '>', $pid_f) or die $!; print {$fh} "4242\n"; close $fh;
            my @taskkill_calls;
            my $killed = 0;
            my ($result, $winpid) = BpKeepAwake::reap_orphan($pid_f,
                image_of     => sub { $killed ? undef : 'powershell.exe' },
                taskkill     => sub { push @taskkill_calls, [@_]; $killed = 1 },
                cmdline_of   => sub { 'powershell.exe -File keep-awake.ps1 -PidFile ' . BpKeepAwake::winify_out($pid_f) },
                wait_seconds => 0,
            );
            is($result, 'gone', "AC13: a live, matching helper reaps to 'gone'");
            is($winpid, 4242, "AC13: ...naming the pid file's winpid");
            is(scalar(@taskkill_calls), 1, 'AC13: taskkill is called exactly once');
            is_deeply($taskkill_calls[0], [4242, 0], 'AC13: taskkill is called with (4242, 0)');
            ok(!-f $pid_f, 'AC13: the pid file is removed');
        }

        # case 2: a reused pid whose cmdline does not name keep-awake.ps1 -> 'not-ours', no taskkill.
        {
            my $pid_f = "$dir/keepawake2.pid";
            open(my $fh, '>', $pid_f) or die $!; print {$fh} "4242\n"; close $fh;
            my @taskkill_calls;
            my ($result, $winpid) = BpKeepAwake::reap_orphan($pid_f,
                image_of     => sub { 'powershell.exe' },
                taskkill     => sub { push @taskkill_calls, [@_] },
                cmdline_of   => sub { 'powershell.exe -Command whatever' },
                wait_seconds => 0,
            );
            is($result, 'not-ours', 'AC13: a reused pid whose cmdline does not name keep-awake.ps1 is not-ours');
            is($winpid, 4242, 'AC13: ...naming the pid');
            is(scalar(@taskkill_calls), 0, 'AC13: taskkill is never called');
            ok(!-f $pid_f, 'AC13: the pid file is still removed');
        }

        # case 3: image_of returns undef immediately -> 'gone', no taskkill.
        {
            my $pid_f = "$dir/keepawake3.pid";
            open(my $fh, '>', $pid_f) or die $!; print {$fh} "4242\n"; close $fh;
            my @taskkill_calls;
            my ($result, undef) = BpKeepAwake::reap_orphan($pid_f,
                image_of => sub { undef },
                taskkill => sub { push @taskkill_calls, [@_] },
            );
            is($result, 'gone', 'AC13: an already-gone process reaps to gone');
            is(scalar(@taskkill_calls), 0, 'AC13: ...and taskkill is never called');
            ok(!-f $pid_f, 'AC13: the pid file is removed');
        }

        # case 4: no pid file -> (), and no seam called.
        {
            my $pid_f = "$dir/keepawake-missing.pid";
            my $called = 0;
            my @r = BpKeepAwake::reap_orphan($pid_f, image_of => sub { $called++; undef });
            is(scalar(@r), 0, 'AC13: a missing pid file gives ()');
            is($called, 0, 'AC13: ...and no seam is called');
        }

        # case 5: a pid file with garbage -> (), file removed, no seam called.
        {
            my $pid_f = "$dir/keepawake-garbage.pid";
            open(my $fh, '>', $pid_f) or die $!; print {$fh} "not-a-pid\n"; close $fh;
            my $called = 0;
            my @r = BpKeepAwake::reap_orphan($pid_f, image_of => sub { $called++; undef });
            is(scalar(@r), 0, 'AC13: a garbage pid file gives ()');
            is($called, 0, 'AC13: ...and no seam is called');
            ok(!-f $pid_f, 'AC13: ...and the garbage pid file is removed');
        }
    }
}

# =====================================================================
# AC14 [B10]: KeepAwake::load_bp_keepawake, each case in a FRESH perl
# subprocess, output captured to a File::Temp file (never an in-memory
# STDOUT -- CLAUDE.md's documented "Bad file descriptor" landmine).
# =====================================================================
sub run_fresh_perl {
    my ($code) = @_;
    my (undef, $codefile) = tempfile(SUFFIX => '.pl',  UNLINK => 1);
    my (undef, $outfile)  = tempfile(SUFFIX => '.out', UNLINK => 1);
    open(my $cfh, '>', $codefile) or die "write $codefile: $!";
    print {$cfh} $code;
    close $cfh;
    system("\"$^X\" \"$codefile\" > \"$outfile\" 2>&1");
    my $out = slurp($outfile) // '';
    unlink $codefile;
    unlink $outfile;
    return $out;
}

my $PROBE_TEMPLATE = q{
use strict; use warnings;
unshift @INC, '%s';
require KeepAwake;
print "BEFORE\n";
my ($ok, $why) = KeepAwake::load_bp_keepawake(%s);
print "AFTER\n";
print "OK=" . (defined($ok) ? $ok : 'undef') . "\n";
print "WHY=" . (defined($why) ? $why : 'undef') . "\n";
for my $name (qw(spawn child_alive stop_child reap_orphan log_tail self_winpid)) {
    print "DEF-$name=" . (defined(&{"BpKeepAwake::$name"}) ? 1 : 0) . "\n";
}
};

sub parse_probe {
    my ($out) = @_;
    my %h;
    $h{silent} = ($out =~ /BEFORE\nAFTER\n/) ? 1 : 0;
    ($h{ok})  = $out =~ /^OK=(.*)$/m;
    ($h{why}) = $out =~ /^WHY=(.*)$/m;
    $h{defs} = {};
    while ($out =~ /^DEF-(\w+)=(\d)$/mg) { $h{defs}{$1} = $2 }
    return \%h;
}

{
    # case 1: the real tree -> (1, undef), six subs defined, silent.
    my $code = sprintf($PROBE_TEMPLATE, $SANDBOX_SCRIPTS, '');
    my $out  = run_fresh_perl($code);
    my $p    = parse_probe($out);
    is($p->{ok},  '1',     'AC14: load_bp_keepawake() against the real tree gives ok=1') or diag($out);
    is($p->{why}, 'undef', 'AC14: ...and no reason');
    for my $name (qw(spawn child_alive stop_child reap_orphan log_tail self_winpid)) {
        is($p->{defs}{$name}, 1, "AC14: BpKeepAwake::$name is defined after a successful load");
    }
    ok($p->{silent}, 'AC14: the call itself prints nothing');
}

{
    # case 2: a nonexistent path -> (0, 'missing: <path>').
    my $missing = "$SANDBOX_SCRIPTS/does-not-exist-07-one-keepawake-helper.pl";
    my $code = sprintf($PROBE_TEMPLATE, $SANDBOX_SCRIPTS, "'$missing'");
    my $out  = run_fresh_perl($code);
    my $p    = parse_probe($out);
    is($p->{ok}, '0', 'AC14: a nonexistent path gives ok=0') or diag($out);
    is($p->{why}, "missing: $missing", 'AC14: ...with the missing: reason naming the path');
    ok($p->{silent}, 'AC14: the call itself prints nothing');
}

{
    # case 3: a fixture file that dies at load -> (0, 'load failed: ...').
    my $dir = tempdir(CLEANUP => 1);
    my $dying = "$dir/dying.pl";
    open(my $fh, '>', $dying) or die $!;
    print {$fh} "die \"boom\\n\";\n";
    close $fh;
    my $code = sprintf($PROBE_TEMPLATE, $SANDBOX_SCRIPTS, "'$dying'");
    my $out  = run_fresh_perl($code);
    my $p    = parse_probe($out);
    is($p->{ok}, '0', 'AC14: a fixture that dies at load gives ok=0') or diag($out);
    like($p->{why} // '', qr/^load failed:/, 'AC14: ...with a load failed: reason');
    ok($p->{silent}, 'AC14: the call itself prints nothing');
}

{
    # case 4: a fixture defining only BpKeepAwake::spawn -> incomplete.
    my $dir = tempdir(CLEANUP => 1);
    my $incomplete = "$dir/incomplete.pl";
    open(my $fh, '>', $incomplete) or die $!;
    print {$fh} "package BpKeepAwake; sub spawn { } 1;\n";
    close $fh;
    my $code = sprintf($PROBE_TEMPLATE, $SANDBOX_SCRIPTS, "'$incomplete'");
    my $out  = run_fresh_perl($code);
    my $p    = parse_probe($out);
    is($p->{ok}, '0', 'AC14: a fixture defining only spawn gives ok=0') or diag($out);
    is($p->{why}, 'incomplete: BpKeepAwake::child_alive undefined', 'AC14: ...naming the first missing sub');
    ok($p->{silent}, 'AC14: the call itself prints nothing');
}

{
    # case 5: KeepAwake.pm copied into a fixture plugins/sandbox/scripts with
    # NO plugins/butler beside it -> the default path resolution gives
    # 'missing: ...' and nothing dies.
    my $dir = tempdir(CLEANUP => 1);
    my $fix_sandbox_scripts = "$dir/plugins/sandbox/scripts";
    make_path($fix_sandbox_scripts);
    my $real_kapm = slurp($KEEPAWAKE_PM);
    open(my $fh, '>', "$fix_sandbox_scripts/KeepAwake.pm") or die $!;
    print {$fh} $real_kapm;
    close $fh;
    my $code = sprintf($PROBE_TEMPLATE, $fix_sandbox_scripts, '');
    my $out  = run_fresh_perl($code);
    my $p    = parse_probe($out);
    is($p->{ok}, '0', 'AC14: a butler-less fixture gives ok=0 (no plugins/butler beside plugins/sandbox)') or diag($out);
    like($p->{why} // '', qr/^missing:/, 'AC14: ...with a missing: reason');
    ok($p->{silent}, 'AC14: the call itself prints nothing');
}

# =====================================================================
# AC15 [B11, Windows]: require bp-keepawake.pl by its drive-letter path.
# =====================================================================
SKIP: {
    skip 'B11 drive-letter require is Windows-only', 1 unless $^O =~ /^(MSWin32|msys|cygwin)$/;
    my $win_path = `cygpath -w "$BP_KEEPAWAKE"`;
    chomp $win_path;
    $win_path =~ s{\\}{/}g;
    my $code = sprintf(q{
use strict; use warnings;
require '%s';
print((-f BpKeepAwake::helper_path()) ? 1 : 0);
}, $win_path);
    my $out = run_fresh_perl($code);
    is($out, '1', "AC15: requiring bp-keepawake.pl by its drive-letter path ($win_path) leaves -f BpKeepAwake::helper_path() true")
        or diag("drive-letter path: $win_path\noutput: $out");
}

# =====================================================================
# AC16 [B5]: BpKeepAwake::stop_child on a real forked sleeper.
# =====================================================================
{
    my $has = defined &BpKeepAwake::stop_child;
    ok($has, 'AC16 precondition: BpKeepAwake::stop_child is defined');
    SKIP: {
        skip 'BpKeepAwake::stop_child not defined yet', 5 unless $has;

        my $pid = fork_sleeper(30);
        my $pidfile = "$Bin/.one-keepawake-stop-$$.pid";
        open(my $fh, '>', $pidfile) or die $!; print {$fh} "x\n"; close $fh;
        is(BpKeepAwake::stop_child($pid, $pidfile), 1, 'AC16: stop_child on a running child gives 1');
        @KILL_CHILDREN = grep { defined $_ && $_ != $pid } @KILL_CHILDREN;
        ok(!kill(0, $pid), 'AC16: the child is gone');
        ok(!-f $pidfile, 'AC16: the pid file is removed');

        my $pidfile2 = "$Bin/.one-keepawake-stop2-$$.pid";
        open(my $fh2, '>', $pidfile2) or die $!; print {$fh2} "x\n"; close $fh2;
        is(BpKeepAwake::stop_child(undef, $pidfile2), 0, 'AC16: stop_child(undef, pidfile) gives 0');
        ok(!-f $pidfile2, 'AC16: ...but still removes the pid file');
    }
}

# =====================================================================
# AC17: comment contract in bp-keepawake.pl.
# =====================================================================
{
    my $BPSRC = slurp($BP_KEEPAWAKE);
    ok(defined $BPSRC, 'precondition: bp-keepawake.pl is readable');
    unlike($BPSRC, qr/EMULATED/i, 'AC17: bp-keepawake.pl no longer claims fork is EMULATED');
    unlike($BPSRC, qr/PSEUDO/i,   'AC17: bp-keepawake.pl no longer claims a PSEUDO pid');
    like($BPSRC, qr/07-one-keepawake-helper/,
         'AC17: bp-keepawake.pl cites the fork measurement (ledger 07-one-keepawake-helper, 2026-11-04)');
}

# =====================================================================
# package 08 (host-awake-actuator): the launcher owns no helper of its own
# any more. It publishes a registry entry (through KeepAwake::registry_seams
# / HostAwake::publish) and actuates nothing directly: no BpKeepAwake::spawn(,
# stop_child(, child_alive, or _power_plan_hold. KeepAwake::load_host_awake(
# is called with an $INSTALL_ROOT-based path, NIT-1 style.
# =====================================================================
unlike($LSRC, qr/BpKeepAwake::spawn\s*\(/,
    'package 08: launcher.pl calls BpKeepAwake::spawn( nowhere (it owns no helper)');
unlike($LSRC, qr/BpKeepAwake::stop_child\s*\(/,
    'package 08: launcher.pl calls BpKeepAwake::stop_child( nowhere');
unlike($LSRC, qr/BpKeepAwake::child_alive\b/,
    'package 08: launcher.pl names BpKeepAwake::child_alive nowhere');
unlike($LSRC, qr/_power_plan_hold\b/,
    'package 08: launcher.pl names _power_plan_hold nowhere');
like($LSRC, qr/KeepAwake::load_host_awake\(\s*"?\$?\{?INSTALL_ROOT\b/,
    'package 08: launcher.pl passes an absolute $INSTALL_ROOT-based path to '
  . 'KeepAwake::load_host_awake, not a bare no-argument call');

# =====================================================================
# package 08 AC17 [DC5, Decision 13]: KeepAwake::load_host_awake, each case
# in a FRESH perl subprocess (same discipline as AC14's load_bp_keepawake
# probes above). Never loaded in-process, so a dying fixture cannot take
# this test file down with it.
# =====================================================================
my $HOST_AWAKE_PM = "$BUTLER_SCRIPTS/HostAwake.pm";
my $HA_PROBE_TEMPLATE = q{
use strict; use warnings;
unshift @INC, '%s';
require KeepAwake;
print "BEFORE\n";
my ($ok, $why) = KeepAwake::load_host_awake(%s);
print "AFTER\n";
print "OK=" . (defined($ok) ? $ok : 'undef') . "\n";
print "WHY=" . (defined($why) ? $why : 'undef') . "\n";
};

{
    # case 1: the real tree -> (1, undef), silent.
    my $code = sprintf($HA_PROBE_TEMPLATE, $SANDBOX_SCRIPTS, "'$HOST_AWAKE_PM'");
    my $out  = run_fresh_perl($code);
    my $p    = parse_probe($out);
    is($p->{ok},  '1',     'package 08 AC17: load_host_awake(<real path>) against the real tree gives ok=1') or diag($out);
    is($p->{why}, 'undef', 'package 08 AC17: ...and no reason');
    ok($p->{silent}, 'package 08 AC17: the call itself prints nothing');
}

{
    # case 2: a nonexistent path -> (0, 'missing: <path>').
    my $missing = "$BUTLER_SCRIPTS/does-not-exist-08-host-awake-actuator.pm";
    my $code = sprintf($HA_PROBE_TEMPLATE, $SANDBOX_SCRIPTS, "'$missing'");
    my $out  = run_fresh_perl($code);
    my $p    = parse_probe($out);
    is($p->{ok}, '0', 'package 08 AC17: a nonexistent path gives ok=0') or diag($out);
    is($p->{why}, "missing: $missing", 'package 08 AC17: ...with the missing: reason naming the path');
    ok($p->{silent}, 'package 08 AC17: the call itself prints nothing');
}

{
    # case 3: a fixture defining only HostAwake::publish -> incomplete,
    # naming HostAwake::withdraw as the first missing sub (spec 2.6's order:
    # publish, withdraw, sandbox_id, host_side, BpAwakeConst::state_root).
    my $dir = tempdir(CLEANUP => 1);
    my $incomplete = "$dir/incomplete-hostawake.pl";
    open(my $fh, '>', $incomplete) or die $!;
    print {$fh} "package HostAwake; sub publish { } 1;\n";
    close $fh;
    my $code = sprintf($HA_PROBE_TEMPLATE, $SANDBOX_SCRIPTS, "'$incomplete'");
    my $out  = run_fresh_perl($code);
    my $p    = parse_probe($out);
    is($p->{ok}, '0', 'package 08 AC17: a fixture defining only HostAwake::publish gives ok=0') or diag($out);
    is($p->{why}, 'incomplete: HostAwake::withdraw undefined',
        'package 08 AC17: ...naming HostAwake::withdraw as the first missing sub');
    ok($p->{silent}, 'package 08 AC17: the call itself prints nothing');
}

done_testing();
