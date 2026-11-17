#!/usr/bin/env perl
# platform: any
# ORACLE for package 07-arm-on-entry (blueprint hook-continuity-remake), the
# 23 acceptance criteria of specs/07-arm-on-entry-spec.md: a PreToolUse/Bash
# hook that arms a drive-solo session's id with role driver on its first real
# director "next" call, denies a subagent's call in a driving session, and
# stays inside the package's process budget.
#
# THE PER-HOOK FILE AND ITS LOGIC MODULE DO NOT EXIST YET at the time this
# file is written. Every in-process call below goes through a guarded
# lookup (RUN() / DNC()) that turns "Undefined subroutine" into a plain
# undef instead of dying; every subprocess (the [wrapper] ACs) legibly
# fails with a non-zero rc / "No such file or directory" until the hook file
# is written.
#
# BpHook.pm and hooks/run-hook.sh belong to package 03 and are already
# implemented; this file requires the real copies and never edits or
# recreates them.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Spec ();
use JSON::PP ();
use Config ();
use Cwd qw(getcwd);

my $BUTLER_DIR = "$Bin/../..";
my $S = "$BUTLER_DIR/scripts";
$S =~ s{\\}{/}g;
my $HOOKSH = "$BUTLER_DIR/hooks/arm-on-entry.sh";
$HOOKSH =~ s{\\}{/}g;
my $ARMPM  = "$S/BpHook/ArmOnEntry.pm";
my $BPHOOK = "$S/BpHook.pm";

require $BPHOOK; # package 03 -- real and already implemented

{
    local $@;
    eval { require $ARMPM; 1 }
        or diag("BpHook::ArmOnEntry did not load (expected until this package is "
              . "implemented): $@");
}

# ---------------------------------------------------------------------------
# RUN(payload_href) -- calls BpHook::ArmOnEntry::run(payload) without ever
# crashing this file when the sub (or the module) does not exist yet.
# DNC(command) -- same seam for director_next_call.
# ---------------------------------------------------------------------------
sub _call {
    my ($name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"BpHook::ArmOnEntry::$name"} }
    my $ret;
    my $ok = eval { $ret = $code->(@args); 1 };
    return $ok ? $ret : undef;
}
sub RUN { my ($p) = @_; return _call('run', $p) }
sub DNC { my ($cmd) = @_; return _call('director_next_call', $cmd) }

# ---------------------------------------------------------------------------
# read_bytes / iso helpers
# ---------------------------------------------------------------------------
sub read_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub mtime_of { my ($p) = @_; my @s = stat($p); return @s ? $s[9] : undef }

sub read_json_bytes {
    my ($path) = @_;
    my $raw = read_bytes($path);
    return undef unless defined $raw;
    return eval { JSON::PP->new->utf8->decode($raw) };
}

# ---------------------------------------------------------------------------
# Isolation: strip BP_*/CCPRAXIS_*/CLAUDE_* ambient env, pin HOME/USERPROFILE
# to a decoy tempdir (defense in depth, guard-asserted at the bottom of this
# file), leave BUTLER_STATE_DIR to be set per-case below.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $REAL_HOME        = $ENV{HOME};
my $REAL_USERPROFILE = $ENV{USERPROFILE};
my $REAL_STATE_ROOT;
{
    my $rh = (defined $REAL_HOME && length $REAL_HOME) ? $REAL_HOME
           : (defined $REAL_USERPROFILE && length $REAL_USERPROFILE) ? $REAL_USERPROFILE
           : undef;
    if (defined $rh) {
        (my $rh_n = $rh) =~ s{\\}{/}g;
        $REAL_STATE_ROOT = "$rh_n/.claude/butler-state/continuity";
    }
}
my $FAKE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FAKE_HOME = "$FAKE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
File::Spec->file_name_is_absolute($FAKE_HOME);
mkdir $FAKE_HOME;
$ENV{HOME}        = $FAKE_HOME;
$ENV{USERPROFILE} = $FAKE_HOME;

# ---------------------------------------------------------------------------
# per-case state root
# ---------------------------------------------------------------------------
my $CURRENT_BASE;
sub use_base { my ($b) = @_; $ENV{BUTLER_STATE_DIR} = $b; $CURRENT_BASE = $b; return $b }
sub fresh_base {
    my $t = tempdir(CLEANUP => 1);
    (my $b = "$t/state") =~ s{\\}{/}g;
    return use_base($b);
}
sub state_root { my ($base) = @_; $base //= $CURRENT_BASE; return "$base/continuity" }
sub armed_path { my ($sid, $base) = @_; return state_root($base) . "/armed/$sid" }
sub off_path   { my ($sid, $base) = @_; return state_root($base) . "/off/$sid" }

fresh_base();

my $SID_N = 0;
my @MINTED_SIDS;
sub mk_sid { my ($tag) = @_; $SID_N++; (my $s = "s$SID_N" . ($tag // '')) =~ s/[^A-Za-z0-9_-]/-/g; $s = substr($s, 0, 48); push @MINTED_SIDS, $s; return $s }

sub payload_for {
    my (%o) = @_;
    my $p = {};
    $p->{tool_name}  = exists $o{tool_name} ? $o{tool_name} : 'Bash';
    if (exists $o{tool_input}) { $p->{tool_input} = $o{tool_input} }
    elsif (exists $o{command}) { $p->{tool_input} = { command => $o{command} } }
    $p->{session_id}      = $o{session_id}      if exists $o{session_id};
    $p->{agent_id}        = $o{agent_id}         if exists $o{agent_id};
    $p->{transcript_path} = $o{transcript_path}  if exists $o{transcript_path};
    return $p;
}

# ---------------------------------------------------------------------------
# run_captured(payload_href) -- BpHook::load_payload + RUN(), with STDOUT/
# STDERR redirected to real temp files (never an in-memory scalar).
# ---------------------------------------------------------------------------
sub run_captured {
    my ($payload) = @_;
    my $json = JSON::PP->new->utf8->canonical->encode($payload);
    BpHook::load_payload($json);
    my $p = BpHook::payload();
    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();
    open(my $saved_out, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $saved_err, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>', $out_path) or die "redirect STDOUT: $!";
    open(STDERR, '>', $err_path) or die "redirect STDERR: $!";
    my $ret = RUN($p);
    open(STDOUT, '>&', $saved_out) or die "restore STDOUT: $!";
    open(STDERR, '>&', $saved_err) or die "restore STDERR: $!";
    close $saved_out;
    close $saved_err;
    my $out = read_bytes($out_path) // '';
    my $err = read_bytes($err_path) // '';
    unlink $out_path, $err_path;
    return ($ret, $out, $err);
}

# ---------------------------------------------------------------------------
# Real bash/timeout/perl resolved to ABSOLUTE paths from the ORIGINAL PATH
# (package-03 technique, hook-core-spawn-budget.t), used by every [wrapper]
# AC and the AC22 static checks.
# ---------------------------------------------------------------------------
my $REAL_BASH_ABS = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH_ABS;

my $REAL_TIMEOUT_ABS = do { my $p = `bash -c "command -v timeout"`; chomp $p;
    # macOS has no GNU timeout: fall back to the repo's pure-perl stand-in
    # (scripts/run-tests.pl already puts it on PATH for a sweep).
    unless (length $p) { (my $d = __FILE__) =~ s{[^/\\]+\z}{}; my $s = "${d}../../../../scripts/test-bin/timeout"; $p = $s if -x $s; }
    $p };
BAIL_OUT('cannot resolve a real timeout utility on PATH') unless length $REAL_TIMEOUT_ABS;

my $REAL_PERL_ABS = do {
    my $p;
    if (File::Spec->file_name_is_absolute($^X) && -x $^X) {
        $p = $^X;
    }
    else {
        my $found = `bash -c "command -v perl"`;
        chomp $found;
        $p = (length $found && -x $found) ? $found : $Config::Config{perlpath};
    }
    $p;
};
BAIL_OUT('cannot resolve a real perl to an absolute path') unless length $REAL_PERL_ABS;

# ---------------------------------------------------------------------------
# run_wrapper(%opt) -- bash $HOOKSH < stdin, under timeout, env fully
# scrubbed and rebuilt per call. No shim: used by ACs that only need rc /
# stdout / stderr, not a process count.
# ---------------------------------------------------------------------------
sub run_wrapper {
    my (%opt) = @_;
    my $env        = $opt{env} // {};
    my $stdin_path = $opt{stdin_path};
    my $timeout    = $opt{timeout} // 10;
    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();

    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    $ENV{HOME}        = $FAKE_HOME;
    $ENV{USERPROFILE} = $FAKE_HOME;
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} }
    }

    my @cmd = ($REAL_TIMEOUT_ABS, $timeout, $REAL_BASH_ABS, $HOOKSH);
    my $inner = join(' ', map { qq("$_") } @cmd);
    $inner .= defined $stdin_path ? qq( < "$stdin_path") : ' < /dev/null';
    $inner .= qq( > "$out_path" 2> "$err_path");
    system($REAL_BASH_ABS, '-c', $inner);
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    my $out = read_bytes($out_path) // '';
    my $err = read_bytes($err_path) // '';
    unlink $out_path, $err_path;
    return { rc => $rc, out => $out, err => $err };
}

sub write_stdin_json {
    my ($payload) = @_;
    my (undef, $path) = tempfile();
    open my $fh, '>:raw', $path or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($payload);
    close $fh;
    return $path;
}

sub write_stdin_raw {
    my ($bytes) = @_;
    my (undef, $path) = tempfile();
    open my $fh, '>:raw', $path or die $!;
    print {$fh} $bytes;
    close $fh;
    return $path;
}

# ---------------------------------------------------------------------------
# build_shim() / run_shim() -- the AC19/AC20 process-budget rig, the
# package-03 build_shim/run_shim technique, pointed at the real $HOOKSH
# (which itself execs the real, already-implemented run-hook.sh).
# ---------------------------------------------------------------------------
sub build_shim {
    my $shim = tempdir(CLEANUP => 1);
    for my $pair ([bash => $REAL_BASH_ABS], [perl => $REAL_PERL_ABS]) {
        my ($name, $real) = @$pair;
        open my $fh, '>', "$shim/$name" or die $!;
        print {$fh} "#!$REAL_BASH_ABS\n";
        print {$fh} "printf '%s %s\\n' '$name' \"\$\$\" >> \"\$SHIM_LOG\"\n";
        print {$fh} "exec \"$real\" \"\$\@\"\n";
        close $fh;
        chmod 0755, "$shim/$name";
    }
    open my $jfh, '>', "$shim/jq" or die $!;
    print {$jfh} "#!$REAL_BASH_ABS\n";
    print {$jfh} "printf '%s %s\\n' 'jq' \"\$\$\" >> \"\$SHIM_LOG\"\n";
    print {$jfh} "exit 0\n";
    close $jfh;
    chmod 0755, "$shim/jq";
    return $shim;
}

sub run_shim {
    my (%opt) = @_;
    my $env        = $opt{env} // {};
    my $stdin_path = $opt{stdin_path};
    my $timeout    = $opt{timeout} // 15;
    my $shim_dir   = $opt{shim_dir} // build_shim();

    my (undef, $shim_log_path) = tempfile(); unlink $shim_log_path;
    my (undef, $out_path) = tempfile();
    my (undef, $err_path) = tempfile();

    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    $ENV{HOME}        = $FAKE_HOME;
    $ENV{USERPROFILE} = $FAKE_HOME;
    for my $k (keys %$env) {
        if (defined $env->{$k}) { $ENV{$k} = $env->{$k} } else { delete $ENV{$k} }
    }
    $ENV{SHIM_LOG} = $shim_log_path;
    unless (exists $env->{PATH}) { $ENV{PATH} = "$shim_dir:$ENV{PATH}" }

    my @inner_cmd = ("$shim_dir/bash", $HOOKSH);
    my $inner = join(' ', map { qq("$_") } @inner_cmd);
    $inner = "$REAL_TIMEOUT_ABS $timeout $inner";
    $inner .= defined $stdin_path ? qq( < "$stdin_path") : ' < /dev/null';
    $inner .= qq( > "$out_path" 2> "$err_path");

    local $SIG{ALRM} = sub { die "run_shim: hard alarm backstop exceeded\n" };
    alarm($timeout + 10);
    system($REAL_BASH_ABS, '-c', $inner);
    my $rc = ($? == -1) ? -1 : ($? >> 8);
    alarm(0);

    return {
        rc       => $rc,
        out      => read_bytes($out_path)      // '',
        err      => read_bytes($err_path)      // '',
        shim_log => read_bytes($shim_log_path) // '',
    };
}

sub count_lines { my ($log, $prefix) = @_; return scalar(grep { /^\Q$prefix\E / } split /\n/, $log) }

# ---------------------------------------------------------------------------
# Command fixtures (spec sec 4).
# ---------------------------------------------------------------------------
my $ANDRE = "Andr\xc3\xa9"; # raw UTF-8 bytes, matches the project convention.

my @AC1_CMDS = (
    'perl /c/x/plugins/butler/scripts/bp-drive-next.pl next',
    qq{perl "C:/Users/$ANDRE/.claude/ccpraxis/plugins/butler/scripts/bp-drive-next.pl" next --scope a},
    'perl C:/x/bp-drive-next.pl next',
    'perl -w ./bp-drive-next.pl next',
    q{perl 'C:\x\bp-drive-next.pl' next},
);
my @AC2_CMDS = (
    'bp-drive-next.sh next',
    'bash /c/x/bp-drive-next.sh next',
);
my @AC3_CMDS = ( 'bp-drive-next next' );
my @AC10_CMDS = (
    'cd /c/x && perl bp-drive-next.pl next',
    'grep -q x f; perl bp-drive-next.pl next',
    'perl bp-drive-next.pl next | tail -1',
    'CCPRAXIS_DATA_DIR=/c/x/.ccpraxis-local-data perl bp-drive-next.pl next',
    'env A=b timeout 60 perl bp-drive-next.pl next',
    'echo $(perl bp-drive-next.pl next)',
);
my @ARMING_CMDS = (@AC1_CMDS, @AC2_CMDS, @AC3_CMDS, @AC10_CMDS);

my @AC8_CMDS = (
    'grep -n next plugins/butler/scripts/bp-drive-next.pl',
    'sed -n 1,20p bp-drive-next.pl',
    'cat bp-drive-next.pl',
    q{echo "perl bp-drive-next.pl next"},
    q{rg 'bp-drive-next.pl next' docs},
    q{git log -S 'bp-drive-next.pl next'},
    q{perl -e 'print "bp-drive-next.pl next"'},
    "cat <<'EOF'\nperl bp-drive-next.pl next\nEOF\n",
    'bp-drive-next-helper next',
    'my-bp-drive-next.pl next',
);
my @AC9_CMDS = (
    'perl bp-drive-next.pl record-order x',
    'perl bp-drive-next.pl park p',
    'perl bp-drive-next.pl --help',
    'perl bp-drive-next.pl',
);
my @NEVER_ARM_CMDS = (@AC8_CMDS, @AC9_CMDS);

my $DENY_LINE = q{butler: a subagent may not call bp-drive-next next; only the driving session's main thread runs the director.};

# ===========================================================================
# AC1 -- each of the five perl-form commands arms S per B1.
# ===========================================================================
{
    fresh_base();
    for my $i (0 .. $#AC1_CMDS) {
        my $cmd = $AC1_CMDS[$i];
        my $sid = mk_sid("ac1-$i");
        my $tp  = "C:\\Test\\Path\\transcript-$i.jsonl";
        my ($ret, $out, $err) = run_captured(payload_for(
            session_id => $sid, command => $cmd, transcript_path => $tp));
        is($ret, 0, "AC1 case $i: run() returns 0") or diag("cmd: $cmd");
        is($out, '', "AC1 case $i: no stdout");
        is($err, '', "AC1 case $i: no stderr");
        ok(-e armed_path($sid), "AC1 case $i: armed/S exists") or next;
        my $rec = read_json_bytes(armed_path($sid));
        is(ref $rec eq 'HASH' ? $rec->{session_id} : undef, $sid, "AC1 case $i: record session_id");
        is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'driver', "AC1 case $i: record role driver");
        is(ref $rec eq 'HASH' ? $rec->{by} : undef, 'arm-on-entry', "AC1 case $i: record by arm-on-entry");
        is(ref $rec eq 'HASH' ? $rec->{transcript_path} : undef, 'C:/Test/Path/transcript-' . $i . '.jsonl',
           "AC1 case $i: transcript_path backslashes folded to /");
        like(ref $rec eq 'HASH' ? ($rec->{at} // '') : '', qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/,
             "AC1 case $i: at is ISO-8601 Z");
    }
}

# ===========================================================================
# AC2 -- the .sh form arms S.
# ===========================================================================
{
    fresh_base();
    for my $i (0 .. $#AC2_CMDS) {
        my $cmd = $AC2_CMDS[$i];
        my $sid = mk_sid("ac2-$i");
        my ($ret) = run_captured(payload_for(session_id => $sid, command => $cmd));
        is($ret, 0, "AC2 case $i: run() returns 0") or diag("cmd: $cmd");
        my $rec = read_json_bytes(armed_path($sid));
        is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'driver', "AC2 case $i: armed role driver");
    }
}

# ===========================================================================
# AC3 -- the bare shim arms S.
# ===========================================================================
{
    fresh_base();
    my $sid = mk_sid('ac3');
    my ($ret) = run_captured(payload_for(session_id => $sid, command => $AC3_CMDS[0]));
    is($ret, 0, 'AC3: run() returns 0');
    my $rec = read_json_bytes(armed_path($sid));
    is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'driver', 'AC3: bare shim arms with role driver');
}

# ===========================================================================
# AC4 [wrapper] -- AC1's first command through the real hook file.
# ===========================================================================
{
    my $base = fresh_base();
    my $sid  = mk_sid('ac4');
    my $stdin = write_stdin_json(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    my $res = run_wrapper(env => { BUTLER_STATE_DIR => $base }, stdin_path => $stdin);
    is($res->{rc}, 0, 'AC4: exit 0') or diag("stderr: $res->{err}");
    is($res->{out}, '', 'AC4: empty stdout');
    is($res->{err}, '', 'AC4: empty stderr');
    my $rec = read_json_bytes(armed_path($sid, $base));
    is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'driver', 'AC4: armed/S role driver');
    is(ref $rec eq 'HASH' ? $rec->{by} : undef, 'arm-on-entry', 'AC4: armed/S by arm-on-entry');
}

# ===========================================================================
# AC5 -- a new session id arms independently; armed/A is untouched; a
# second call for B stays a single armed/B, still role driver.
# ===========================================================================
{
    fresh_base();
    my $sidA = mk_sid('ac5a');
    my $sidB = mk_sid('ac5b');
    ok(BpHook::arm($sidA, role => 'driver', by => 'arm-on-entry'), 'AC5 setup: A armed driver');
    my $before_bytes = read_bytes(armed_path($sidA));
    my $before_mtime = mtime_of(armed_path($sidA));
    sleep(1);

    my ($ret1) = run_captured(payload_for(session_id => $sidB, command => $AC1_CMDS[0]));
    is($ret1, 0, 'AC5: first call for B returns 0');
    is(read_bytes(armed_path($sidA)), $before_bytes, 'AC5: armed/A bytes unchanged');
    is(mtime_of(armed_path($sidA)), $before_mtime, 'AC5: armed/A mtime unchanged');
    ok(-e armed_path($sidB), 'AC5: armed/B exists');

    my ($ret2) = run_captured(payload_for(session_id => $sidB, command => $AC1_CMDS[0]));
    is($ret2, 0, 'AC5: second call for B returns 0');
    my $rec = read_json_bytes(armed_path($sidB));
    is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'driver', 'AC5: armed/B still role driver after a second call');
}

# ===========================================================================
# AC6 -- idempotent refresh: mtime touched, bytes identical.
# ===========================================================================
{
    fresh_base();
    my $sid = mk_sid('ac6');
    ok(BpHook::arm($sid, role => 'driver', by => 'arm-on-entry'), 'AC6 setup: armed driver');
    utime(1000000000, 1000000000, armed_path($sid)) or diag("utime failed: $!");
    my $before_bytes = read_bytes(armed_path($sid));
    my $test_start = time();

    my ($ret) = run_captured(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    is($ret, 0, 'AC6: run() returns 0');
    is(read_bytes(armed_path($sid)), $before_bytes, 'AC6: bytes identical after refresh');
    my $after_mtime = mtime_of(armed_path($sid));
    ok(defined $after_mtime && $after_mtime >= $test_start - 5, 'AC6: mtime touched to now');
}

# ===========================================================================
# AC7 -- role upgrade: manual/reporter becomes driver.
# ===========================================================================
for my $prior_role (qw(manual reporter)) {
    fresh_base();
    my $sid = mk_sid("ac7-$prior_role");
    ok(BpHook::arm($sid, role => $prior_role, by => 'on'), "AC7 setup ($prior_role): armed");
    my ($ret) = run_captured(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    is($ret, 0, "AC7 ($prior_role): run() returns 0");
    my $rec = read_json_bytes(armed_path($sid));
    is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'driver', "AC7 ($prior_role): role upgraded to driver");
}

# ===========================================================================
# AC8 -- mentions arm nothing.
# ===========================================================================
{
    fresh_base();
    for my $i (0 .. $#AC8_CMDS) {
        my $cmd = $AC8_CMDS[$i];
        my $sid = mk_sid("ac8-$i");
        my ($ret) = run_captured(payload_for(session_id => $sid, command => $cmd));
        is($ret, 0, "AC8 case $i: run() returns 0") or diag("cmd: $cmd");
        ok(!-e armed_path($sid), "AC8 case $i: armed/S was not created") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC9 -- other verbs create nothing.
# ===========================================================================
{
    fresh_base();
    for my $i (0 .. $#AC9_CMDS) {
        my $cmd = $AC9_CMDS[$i];
        my $sid = mk_sid("ac9-$i");
        my ($ret) = run_captured(payload_for(session_id => $sid, command => $cmd));
        is($ret, 0, "AC9 case $i: run() returns 0") or diag("cmd: $cmd");
        ok(!-e armed_path($sid), "AC9 case $i: armed/S was not created") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC10 -- compound / chained / piped / substituted forms each arm S.
# ===========================================================================
{
    fresh_base();
    for my $i (0 .. $#AC10_CMDS) {
        my $cmd = $AC10_CMDS[$i];
        my $sid = mk_sid("ac10-$i");
        my ($ret) = run_captured(payload_for(session_id => $sid, command => $cmd));
        is($ret, 0, "AC10 case $i: run() returns 0") or diag("cmd: $cmd");
        my $rec = read_json_bytes(armed_path($sid));
        is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'driver', "AC10 case $i: arms with role driver")
            or diag("cmd: $cmd");
    }
}

# ===========================================================================
# AC11 -- another session's files are untouched; only armed/S is created.
# ===========================================================================
{
    fresh_base();
    my $sidB = mk_sid('ac11b');
    my $sidC = mk_sid('ac11c');
    my $sidD = mk_sid('ac11d');
    my $sidS = mk_sid('ac11s');
    ok(BpHook::arm($sidB, role => 'manual', by => 'on'), 'AC11 setup: B armed manual');
    ok(BpHook::disarm($sidC, actor => 'agent', reason => 'not today thanks'), 'AC11 setup: C off');
    ok(BpHook::arm($sidD, role => 'driver', by => 'arm-on-entry'), 'AC11 setup: D armed driver');

    my %before = map { $_ => [ read_bytes(armed_path($_)) // read_bytes(off_path($_)),
                                (mtime_of(armed_path($_)) // mtime_of(off_path($_))) ] }
                 ($sidB, $sidC, $sidD);
    sleep(1);

    my ($ret) = run_captured(payload_for(session_id => $sidS, command => $AC1_CMDS[0]));
    is($ret, 0, 'AC11: run() for S returns 0');
    ok(-e armed_path($sidS), 'AC11: armed/S created');

    is(read_bytes(armed_path($sidB)), $before{$sidB}[0], 'AC11: armed/B bytes unchanged');
    is(mtime_of(armed_path($sidB)), $before{$sidB}[1], 'AC11: armed/B mtime unchanged');
    is(read_bytes(off_path($sidC)), $before{$sidC}[0], 'AC11: off/C bytes unchanged');
    is(mtime_of(off_path($sidC)), $before{$sidC}[1], 'AC11: off/C mtime unchanged');
    is(read_bytes(armed_path($sidD)), $before{$sidD}[0], 'AC11: armed/D bytes unchanged');
    is(mtime_of(armed_path($sidD)), $before{$sidD}[1], 'AC11: armed/D mtime unchanged');
}

# ===========================================================================
# AC12 -- Decision 36: an off session is not re-armed, for either actor.
#
# REASON CODE F2 (package 16 fix-batch, red-team H1): Decision 36's "not
# re-armed" is now enforced by an explicit DENY (exit 2, with a one-line
# "run `butler-continuity on` first" instruction), not a silent allow.
# Before this fix an off session's `next` returned 0 with nothing armed,
# so the director handed out concurrent packages to a caller bind-dispatch
# and guard-writes never covered (H1's reproduction). This assertion is
# widened, not weakened: it still requires "armed/S was not created" and
# "off/S byte-identical" exactly as before, and additionally requires the
# call be REFUSED rather than merely inert.
# ===========================================================================
for my $actor (qw(agent operator)) {
    fresh_base();
    my $sid = mk_sid("ac12-$actor");
    ok(BpHook::disarm($sid, actor => $actor, reason => 'done for today'), "AC12 ($actor) setup: off written");
    my $before = read_bytes(off_path($sid));

    my ($ret, undef, $err) = run_captured(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    is($ret, 2, "AC12 ($actor): run() returns 2 (F2: denied, not silently allowed)");
    like($err, qr/butler-continuity on/, "AC12 ($actor): the denial tells the agent to run `butler-continuity on` first");
    ok(!-e armed_path($sid), "AC12 ($actor): armed/S was not created");
    is(read_bytes(off_path($sid)), $before, "AC12 ($actor): off/S byte-identical");
}

# ===========================================================================
# AC13 -- an operator 'on' clears the off and the next call finds no off.
# ===========================================================================
{
    fresh_base();
    my $sid = mk_sid('ac13');
    ok(BpHook::disarm($sid, actor => 'agent', reason => 'done for today'), 'AC13 setup: off written');
    ok(BpHook::arm($sid, role => 'driver', by => 'on'), 'AC13 setup: on clears off');
    ok(!-e off_path($sid), 'AC13 setup: off/S is gone after on');

    my ($ret) = run_captured(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    is($ret, 0, 'AC13: run() returns 0');
    my $rec = read_json_bytes(armed_path($sid));
    is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'driver', 'AC13: armed/S role driver');
    ok(!-e off_path($sid), 'AC13: off/S remains absent');
}

# ===========================================================================
# AC14 -- a subagent's call when the session is not driving is a no-op.
# ===========================================================================
{
    fresh_base();
    my $sid_unarmed = mk_sid('ac14-unarmed');
    my ($ret1) = run_captured(payload_for(
        session_id => $sid_unarmed, agent_id => 'a1b2', command => $AC1_CMDS[0]));
    is($ret1, 0, 'AC14: subagent call on an unarmed session returns 0');
    ok(!-e armed_path($sid_unarmed), 'AC14: nothing written for the unarmed session');

    my $sid_manual = mk_sid('ac14-manual');
    ok(BpHook::arm($sid_manual, role => 'manual', by => 'on'), 'AC14 setup: manual armed');
    my $before = read_bytes(armed_path($sid_manual));
    my ($ret2) = run_captured(payload_for(
        session_id => $sid_manual, agent_id => 'a1b2', command => $AC1_CMDS[0]));
    is($ret2, 0, 'AC14: subagent call on a manual session returns 0');
    is(read_bytes(armed_path($sid_manual)), $before, 'AC14: manual session file unchanged');
}

# ===========================================================================
# AC15 [wrapper] -- a subagent's real "next" call in a driving session is
# denied; a mention in the same shape exits 0 with no stderr.
# ===========================================================================
{
    my $base = fresh_base();
    my $sid = mk_sid('ac15');
    ok(BpHook::arm($sid, role => 'driver', by => 'arm-on-entry'), 'AC15 setup: armed driver');
    my $before_bytes = read_bytes(armed_path($sid, $base));
    my $before_mtime = mtime_of(armed_path($sid, $base));
    sleep(1);

    my $stdin1 = write_stdin_json(payload_for(
        session_id => $sid, agent_id => 'a1b2', command => $AC1_CMDS[0]));
    my $res1 = run_wrapper(env => { BUTLER_STATE_DIR => $base }, stdin_path => $stdin1);
    is($res1->{rc}, 2, 'AC15: a subagent real next call exits 2');
    is($res1->{err}, "$DENY_LINE\n", 'AC15: stderr is exactly the deny line');
    is($res1->{out}, '', 'AC15: stdout empty');
    is(read_bytes(armed_path($sid, $base)), $before_bytes, 'AC15: armed/S bytes unchanged');
    is(mtime_of(armed_path($sid, $base)), $before_mtime, 'AC15: armed/S mtime unchanged');

    my $stdin2 = write_stdin_json(payload_for(
        session_id => $sid, agent_id => 'a1b2', command => 'grep bp-drive-next x'));
    my $res2 = run_wrapper(env => { BUTLER_STATE_DIR => $base }, stdin_path => $stdin2);
    is($res2->{rc}, 0, 'AC15: a subagent mention exits 0');
    is($res2->{err}, '', 'AC15: a subagent mention has empty stderr');
}

# ===========================================================================
# AC16 -- BP_LEDGER (coordinator/judge) writes nothing.
# ===========================================================================
{
    fresh_base();
    my $sid = mk_sid('ac16');
    local $ENV{BP_LEDGER} = '/c/x/ledger.md';
    my ($ret) = run_captured(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    is($ret, 0, 'AC16: run() under BP_LEDGER returns 0');
    ok(!-e armed_path($sid), 'AC16: nothing written under BP_LEDGER');
}

# ===========================================================================
# AC17 -- fail-open. In-process cases first, then the two [wrapper] cases.
# ===========================================================================
{
    fresh_base();
    my $sid = mk_sid('ac17-edit');
    my ($ret) = run_captured(payload_for(session_id => $sid, tool_name => 'Edit', command => $AC1_CMDS[0]));
    is($ret, 0, 'AC17: tool_name Edit -> run() returns 0');
    ok(!-e armed_path($sid), 'AC17: tool_name Edit -> nothing written');
}
{
    fresh_base();
    my ($ret) = run_captured(payload_for(session_id => '../x', command => $AC1_CMDS[0]));
    is($ret, 0, "AC17: session_id '../x' -> run() returns 0");
    ok(!-e state_root() . '/armed', 'AC17: session_id \'../x\' -> the armed/ dir was not even created');
}
{
    fresh_base();
    my $p = payload_for(command => $AC1_CMDS[0]);
    delete $p->{session_id};
    my ($ret) = run_captured($p);
    is($ret, 0, 'AC17: session_id absent -> run() returns 0');
    ok(!-e state_root() . '/armed', 'AC17: session_id absent -> the armed/ dir was not even created');
}
for my $bad_command (42, [1, 2]) {
    fresh_base();
    my $sid = mk_sid('ac17-cmd');
    my ($ret) = run_captured(payload_for(session_id => $sid, tool_input => { command => $bad_command }));
    is($ret, 0, 'AC17: tool_input.command not a plain string -> run() returns 0');
    ok(!-e armed_path($sid), 'AC17: tool_input.command not a plain string -> nothing written');
}
{
    # R8-m4 (review m4): "run() returns 0" alone would still pass if a
    # regression resolved the relative root against the cwd and wrote
    # rel/dir/continuity/... there. chdir into an isolated, empty tempdir
    # for the duration of the call and assert it is STILL empty afterwards.
    my $tmp = tempdir(CLEANUP => 1);
    my $prev_cwd = getcwd();
    chdir($tmp) or die "chdir $tmp: $!";
    local $ENV{BUTLER_STATE_DIR} = 'rel/dir';
    my $sid = mk_sid('ac17-relstate');
    my ($ret) = run_captured(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    is($ret, 0, 'AC17: relative BUTLER_STATE_DIR -> run() returns 0');
    opendir(my $dh, $tmp) or die "opendir $tmp: $!";
    my @entries = grep { !/^\.\.?$/ } readdir($dh);
    closedir $dh;
    is_deeply(\@entries, [],
        'R8-m4: relative BUTLER_STATE_DIR -> nothing written into the tempdir cwd (no rel/dir/... escape)');
    chdir($prev_cwd) or die "chdir back to $prev_cwd: $!";
}
{
    my $tmp = tempdir(CLEANUP => 1);
    my $prev_cwd = getcwd();
    chdir($tmp) or die "chdir $tmp: $!";
    local $ENV{BUTLER_STATE_DIR};
    local $ENV{HOME};
    local $ENV{USERPROFILE};
    delete $ENV{BUTLER_STATE_DIR};
    delete $ENV{HOME};
    delete $ENV{USERPROFILE};
    my $sid = mk_sid('ac17-nohome');
    my ($ret) = run_captured(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    is($ret, 0, 'AC17: BUTLER_STATE_DIR/HOME/USERPROFILE all unset -> run() returns 0');
    opendir(my $dh, $tmp) or die "opendir $tmp: $!";
    my @entries = grep { !/^\.\.?$/ } readdir($dh);
    closedir $dh;
    is_deeply(\@entries, [],
        'R8-m4: all three unset -> nothing written into the tempdir cwd');
    chdir($prev_cwd) or die "chdir back to $prev_cwd: $!";
}
{
    my $tmp = tempdir(CLEANUP => 1);
    my $prev_cwd = getcwd();
    chdir($tmp) or die "chdir $tmp: $!";
    local $ENV{BUTLER_STATE_DIR};
    local $ENV{HOME};
    local $ENV{USERPROFILE};
    delete $ENV{BUTLER_STATE_DIR};
    $ENV{HOME} = 'rel/home';
    $ENV{USERPROFILE} = 'rel/home';
    my $sid = mk_sid('ac17-relhome');
    my ($ret) = run_captured(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    is($ret, 0, 'AC17: BUTLER_STATE_DIR unset, HOME/USERPROFILE relative -> run() returns 0');
    opendir(my $dh, $tmp) or die "opendir $tmp: $!";
    my @entries = grep { !/^\.\.?$/ } readdir($dh);
    closedir $dh;
    is_deeply(\@entries, [],
        'R8-m4: relative HOME/USERPROFILE -> nothing written into the tempdir cwd (no rel/home/... escape)');
    chdir($prev_cwd) or die "chdir back to $prev_cwd: $!";
}
{
    my $base = fresh_base();
    my $stdin = write_stdin_raw('{"session_id":"x", "tool_input":{"command":"bp-drive-next next"' ); # truncated/invalid, contains the needle
    my $res = run_wrapper(env => { BUTLER_STATE_DIR => $base }, stdin_path => $stdin);
    is($res->{rc}, 0, 'AC17 [wrapper]: invalid JSON containing bp-drive-next -> exit 0');
    is($res->{out}, '', 'AC17 [wrapper]: invalid JSON -> empty stdout');
    is($res->{err}, '', 'AC17 [wrapper]: invalid JSON -> empty stderr');
}
{
    my $base = fresh_base();
    my $stdin = write_stdin_raw('');
    my $res = run_wrapper(env => { BUTLER_STATE_DIR => $base }, stdin_path => $stdin);
    is($res->{rc}, 0, 'AC17 [wrapper]: empty stdin -> exit 0');
    is($res->{out}, '', 'AC17 [wrapper]: empty stdin -> empty stdout');
    is($res->{err}, '', 'AC17 [wrapper]: empty stdin -> empty stderr');
}

# ===========================================================================
# AC18 -- non-ASCII: state root and transcript_path both hold André,
# byte-exact, not double-encoded.
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $andre_base = "$t/$ANDRE/state") =~ s{\\}{/}g;
    use_base($andre_base);
    my $sid = mk_sid('ac18');
    my $tp = "$t/$ANDRE/transcript.jsonl";
    # $tp is a raw UTF-8 BYTE string (no utf8 flag, per $ANDRE's own
    # definition above). run_captured() JSON-encodes the payload with
    # JSON::PP->new->utf8->encode, which treats an unflagged string's bytes
    # as individual Latin-1 code points and re-encodes them -- double
    # encoding C3 A9 into C3 83 C2 A9 before BpHook::ArmOnEntry::run() ever
    # sees it. Decode a COPY to the character string ("Andr\x{e9}...") so
    # ->utf8->encode does its one, correct, UTF-8 encoding of the real
    # codepoint; the byte-exact assertions below are unaffected, since the
    # module's own write path still lands on disk as the same two bytes.
    my $tp_chars = $tp;
    utf8::decode($tp_chars) or die "AC18 fixture: utf8::decode failed for '$tp_chars'";
    my ($ret) = run_captured(payload_for(session_id => $sid, command => $AC1_CMDS[0], transcript_path => $tp_chars));
    is($ret, 0, 'AC18: run() under an André-rooted state dir returns 0');
    ok(-e armed_path($sid, $andre_base), 'AC18: armed/S was created under the André root');
    my $raw = read_bytes(armed_path($sid, $andre_base)) // '';
    like($raw, qr/\Q$ANDRE\E/, 'AC18: the recorded bytes contain the raw UTF-8 André sequence');
    unlike($raw, qr/\xc3\x83/, 'AC18: no double-encoding signature in the recorded bytes');
}

# ===========================================================================
# AC19 [wrapper, shim] -- not-applies: 0 perl, 0 jq, <=2 bash lines, one pid.
# ===========================================================================
{
    my $base = fresh_base();
    my $stdin = write_stdin_json(payload_for(session_id => mk_sid('ac19'), command => 'ls -la'));
    my $res = run_shim(env => { BUTLER_STATE_DIR => $base }, stdin_path => $stdin, timeout => 10);
    is($res->{rc}, 0, 'AC19: exit 0') or diag("stderr: $res->{err}");
    is(count_lines($res->{shim_log}, 'perl'), 0, 'AC19: 0 perl launches');
    is(count_lines($res->{shim_log}, 'jq'),   0, 'AC19: 0 jq launches');
    my @bash_lines = grep { /^bash / } split /\n/, $res->{shim_log};
    cmp_ok(scalar(@bash_lines), '<=', 2, 'AC19: at most 2 bash lines');
    my %pids = map { (split ' ', $_)[1] => 1 } @bash_lines;
    is(scalar(keys %pids), @bash_lines ? 1 : 0, 'AC19: one pid across the bash lines');
}

# ===========================================================================
# AC20 [wrapper, shim] -- applies: exactly 1 perl, 0 jq, one pid lineage,
# armed/S written.
# ===========================================================================
{
    my $base = fresh_base();
    my $sid = mk_sid('ac20');
    my $stdin = write_stdin_json(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    my $res = run_shim(env => { BUTLER_STATE_DIR => $base }, stdin_path => $stdin, timeout => 10);
    is($res->{rc}, 0, 'AC20: exit 0') or diag("stderr: $res->{err}");
    is(count_lines($res->{shim_log}, 'perl'), 1, 'AC20: exactly 1 perl launch');
    is(count_lines($res->{shim_log}, 'jq'),   0, 'AC20: 0 jq launches');
    my @perl_lines = grep { /^perl / } split /\n/, $res->{shim_log};
    my @bash_lines = grep { /^bash / } split /\n/, $res->{shim_log};
    my %pids = map { (split ' ', $_)[1] => 1 } (@perl_lines, @bash_lines);
    is(scalar(keys %pids), 1, 'AC20: every logged pid is equal (one exec chain)');
    ok(-e armed_path($sid, $base), 'AC20: armed/S was written');
}

# ===========================================================================
# AC21 -- run() never re-parses the payload.
# ===========================================================================
{
    fresh_base();
    my $sid = mk_sid('ac21');
    my $json = JSON::PP->new->utf8->canonical->encode(payload_for(session_id => $sid, command => $AC1_CMDS[0]));
    BpHook::load_payload($json);
    my $pc_before = BpHook::parse_count();
    RUN(BpHook::payload());
    my $pc_after = BpHook::parse_count();
    is($pc_after, $pc_before, 'AC21: parse_count is unchanged by run()');
}

# ===========================================================================
# AC22 -- static checks on the hook file and the module.
# ===========================================================================
{
    ok(-f $HOOKSH, 'AC22: the per-hook file exists on disk')
        or diag("missing: $HOOKSH (not written yet)");
    SKIP: {
        skip 'AC22: hook file missing, cannot check its shape', 2 unless -f $HOOKSH;
        my $rc = system($REAL_BASH_ABS, '-n', $HOOKSH);
        is($rc, 0, 'AC22: bash -n passes');
        my @lines = grep { /\S/ } split /\n/, (read_bytes($HOOKSH) // '');
        is($lines[-1] // '', 'exec bash "$d/run-hook.sh" ArmOnEntry --pre text:bp-drive-next -- "$@"',
           'AC22: the last non-blank line is exactly the documented exec line');
    }

    ok(-f $ARMPM, 'AC22: the logic module exists on disk')
        or diag("missing: $ARMPM (not written yet)");
    SKIP: {
        skip 'AC22: module missing, cannot perl -c it', 1 unless -f $ARMPM;
        my $rc = system($REAL_PERL_ABS, "-I$S", '-c', $ARMPM);
        is($rc, 0, 'AC22: perl -c on BpHook/ArmOnEntry.pm passes');
    }
}

# ===========================================================================
# AC23 -- director_next_call(): 1 for every arming command, 0 for every
# mention/other-verb command and for undef.
# ===========================================================================
{
    for my $i (0 .. $#ARMING_CMDS) {
        is(DNC($ARMING_CMDS[$i]), 1, "AC23: director_next_call() is 1 for arming command $i")
            or diag("cmd: $ARMING_CMDS[$i]");
    }
    for my $i (0 .. $#NEVER_ARM_CMDS) {
        is(DNC($NEVER_ARM_CMDS[$i]), 0, "AC23: director_next_call() is 0 for non-arming command $i")
            or diag("cmd: $NEVER_ARM_CMDS[$i]");
    }
    is(DNC(undef), 0, 'AC23: director_next_call(undef) is 0');
}

# ===========================================================================
# R8-B1 -- Decision 55 (review B1, redteam H1): a director call whose
# command word carries an unexpandable prefix (~/..., ${VAR}/..., $VAR/...)
# must still arm the session, end to end through director_next_call() and
# ArmOnEntry::run(). This is the dominant real-world shape (per the
# redteam's own transcript citation: 7 of 8 director calls in one drive-solo
# session used the ~/... form), so this is the case that decides whether
# arm-on-entry is inert in practice, not just against the AC1 fixtures.
# ===========================================================================
{
    fresh_base();
    my @cmds = (
        'perl ~/.claude/ccpraxis/plugins/butler/scripts/bp-drive-next.pl next',
        'perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-drive-next.pl" next',
        'perl $HOME/x/bp-drive-next.pl next',
        'perl "$P/bp-drive-next.pl" next',
        'bash ~/.claude/ccpraxis/plugins/butler/bin/bp-drive-next.sh next',
    );
    for my $i (0 .. $#cmds) {
        my $cmd = $cmds[$i];
        is(DNC($cmd), 1, "R8-B1: director_next_call() is 1 for command $i") or diag("cmd: $cmd");
        my $sid = mk_sid("r8b1-$i");
        my ($ret) = run_captured(payload_for(session_id => $sid, command => $cmd));
        is($ret, 0, "R8-B1: run() returns 0 for command $i") or diag("cmd: $cmd");
        my $rec = read_json_bytes(armed_path($sid));
        is(ref $rec eq 'HASH' ? $rec->{role} : undef, 'driver',
            "R8-B1: command $i arms with role driver despite the unexpandable prefix") or diag("cmd: $cmd");
    }
}

# ===========================================================================
# Guard (R4 discipline) -- nothing in this file ever reached the operator's
# real ~/.claude or ~/.ccpraxis-local-data. Every case above set
# BUTLER_STATE_DIR explicitly except the two AC17 sub-cases that
# deliberately test the HOME/USERPROFILE fallback, and those pinned HOME/
# USERPROFILE to an unrelated relative or decoy value, never the real one.
#
# A plain before/after existence check of the real armed/ dir is vacuous on
# any host where continuity has ever armed a real session (it already
# exists, so "existed -> exists" can never fail). Instead: (1) prove nothing
# fell back to the decoy HOME pinned above, and (2) prove that none of the
# session ids THIS FILE minted (never a real UUID) exists under the real
# root -- independent of whatever the real root already contains. Access to
# the real root is per-path -e probes only, never a directory listing.
# ===========================================================================
{
    my $DECOY_ROOT = "$FAKE_HOME/.claude/butler-state/continuity";
    ok(!-e "$DECOY_ROOT/armed" && !-e "$DECOY_ROOT/off",
       'guard: nothing fell back to HOME -- the decoy home has no continuity armed/ or off/');

    ok(scalar(@MINTED_SIDS) > 0, 'guard: this file minted session ids to check');

    if (defined $REAL_STATE_ROOT) {
        my @leaked = grep { -e "$REAL_STATE_ROOT/armed/$_" || -e "$REAL_STATE_ROOT/off/$_" } @MINTED_SIDS;
        is_deeply(\@leaked, [],
            'guard: no session id minted by this file exists under the real ~/.claude/butler-state/continuity (armed/ or off/)');
    }
    else {
        pass('guard: no real HOME/USERPROFILE was available to check (nothing to protect)');
    }
}

$? = 0;
done_testing();
