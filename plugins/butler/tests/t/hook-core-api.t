#!/usr/bin/env perl
# platform: any
# IMMUTABLE ORACLE for package 03-hook-core (blueprint hook-continuity-remake),
# A1-A21 of specs/03-hook-core-spec.md: BpHook's core API, exercised
# in-process (DC1, DC3).
#
# BpHook.pm DOES NOT EXIST YET at the time this file is written. Every call
# below goes through H()/HL() (see helpers, just below the use block), which
# take a reference to BpHook::<name> only at call time and catch the
# resulting "Undefined subroutine" die -- so a missing module produces a
# legible per-assertion failure ("expected X, got undef"), never a
# compile-time crash of this whole file.
#
# Every child process this file forks (A5, A7, A8) is pushed onto @KILL_PIDS;
# the END block below TERMs then KILLs everything left standing, routed
# through exit() so the reaper always runs (see the retired watcher-probe-liveness coverage's
# note on why exit() rather than the signal's default action matters here).
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec ();
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use POSIX qw(_exit);
use Cwd qw(getcwd abs_path);
use Fcntl qw(:flock);

my $HOOKPM = "$Bin/../../scripts/BpHook.pm";

my $HOOK_LOAD_ERR;
{
    local $@;
    my $ok = eval { require $HOOKPM; 1 };
    $HOOK_LOAD_ERR = $@ unless $ok;
}
diag("BpHook.pm did not load cleanly (expected until package 03 is implemented): "
   . ($HOOK_LOAD_ERR // 'unknown error')) if $HOOK_LOAD_ERR;

# ---------------------------------------------------------------------------
# H(name, @args) / HL(name, @args) -- call BpHook::<name> without ever
# crashing this file when the sub (or the whole module) does not exist.
# \&{"BpHook::$name"} is a reference to a not-yet-existing sub; CALLING it
# dies "Undefined subroutine ... called", caught below by eval. Any die the
# real implementation raises later is caught the same way. H() is scalar
# context (most of the API); HL() is list context (invocations() only).
# ---------------------------------------------------------------------------
sub H {
    my ($name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"BpHook::$name"} }
    my $ret;
    my $ok = eval { $ret = $code->(@args); 1 };
    return $ok ? $ret : undef;
}
sub HL {
    my ($name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"BpHook::$name"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? @ret : ();
}

# Raw UTF-8 bytes for "Andr\x{e9}" (\xC3\xA9), a byte string with no utf8
# flag -- the on-disk form, matching blueprint-write-api.t's own convention
# for the same glyph (its G11 fixtures).
my $ANDRE = "Andr\xC3\xA9";

sub fresh_state_root { my $t = tempdir(CLEANUP => 1); return "$t/state" }
sub andre_state_root { my $t = tempdir(CLEANUP => 1); return "$t/$ANDRE/state" }

sub scrub_env {
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
}

sub read_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

sub write_json_file {
    my ($path, $data) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} JSON::PP->new->utf8->canonical->encode($data) . "\n";
    close $fh;
}

sub read_json_file {
    my ($path) = @_;
    my $raw = read_bytes($path);
    return undef unless defined $raw;
    return eval { JSON::PP->new->decode($raw) };
}

# ---------------------------------------------------------------------------
# process bookkeeping -- real child processes used by A5 (concurrency forks),
# A7/A8/A9 (holder liveness fixtures).
# ---------------------------------------------------------------------------
my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) { next unless $pid; kill('TERM', $pid) }
    if (@KILL_PIDS) {
        select(undef, undef, undef, 0.3);
        for my $pid (@KILL_PIDS) { next unless $pid; kill('KILL', $pid) if kill(0, $pid) }
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { waitpid($pid, 0) } }
    }
    $? = 0;
}
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ===========================================================================
# A1 -- role() resolution: coordinator, judge, and the armed-file ladder.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    $ENV{BUTLER_STATE_DIR} = fresh_state_root();
    $ENV{BP_LEDGER} = '/some/ledger.md';
    for my $bp_role (undef, '', 'coordinator') {
        local %ENV = %ENV;
        if (defined $bp_role) { $ENV{BP_ROLE} = $bp_role } else { delete $ENV{BP_ROLE} }
        is(H('role', {session_id => 'S1'}), 'coordinator',
           'A1: BP_LEDGER set, BP_ROLE ' . (defined $bp_role ? "'$bp_role'" : 'unset') . ' -> coordinator');
    }
    {
        local %ENV = %ENV;
        $ENV{BP_ROLE} = 'harvest-judge';
        is(H('role', {session_id => 'S1'}), 'judge', 'A1: BP_ROLE=harvest-judge -> judge');
    }
}
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    H('arm', 'D1', role => 'driver',   by => 'arm-on-entry');
    H('arm', 'R1', role => 'reporter', by => 'arm-on-entry');
    H('arm', 'M1', role => 'manual',   by => 'arm-on-entry');
    is(H('role', {session_id => 'D1'}), 'driver',   'A1: armed role driver -> driver');
    is(H('role', {session_id => 'R1'}), 'reporter', 'A1: armed role reporter -> reporter');
    is(H('role', {session_id => 'M1'}), 'manual',   'A1: armed role manual -> manual');
    is(H('role', {session_id => 'UNARMED'}), 'manual', 'A1: unarmed session -> manual');

    my $continuity = "$root/continuity";
    make_path("$continuity/armed");
    open my $fh, '>', "$continuity/armed/EMPTY" or die $!; close $fh;
    is(H('role', {session_id => 'EMPTY'}), 'manual', 'A1: empty arm file -> manual');
    open my $fh2, '>', "$continuity/armed/BAD" or die $!;
    print {$fh2} "not json"; close $fh2;
    is(H('role', {session_id => 'BAD'}), 'manual', 'A1: corrupt (non-JSON) arm file -> manual');
}

# ===========================================================================
# A2 -- is_armed(): coordinator/judge overrides, otherwise file existence
# (a corrupt file still counts as armed).
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    $ENV{BP_LEDGER} = '/x/ledger.md';
    is(H('is_armed', undef), 1, 'A2: coordinator is_armed(undef) -> 1');
    $ENV{BP_ROLE} = 'harvest-judge';
    is(H('is_armed', 'anything'), 0, 'A2: judge is_armed -> 0');
    delete $ENV{BP_LEDGER}; delete $ENV{BP_ROLE};
    is(H('is_armed', 'NOFILE'), 0, 'A2: no arm file -> 0');
    H('arm', 'A2S', role => 'manual', by => 'arm-on-entry');
    is(H('is_armed', 'A2S'), 1, 'A2: arm file present -> 1');
    my $continuity = "$root/continuity";
    make_path("$continuity/armed");
    open my $fh, '>', "$continuity/armed/A2CORRUPT" or die $!;
    print {$fh} "{{{"; close $fh;
    is(H('is_armed', 'A2CORRUPT'), 1, 'A2: corrupt arm file still counts as armed (existence only)');
}

# ===========================================================================
# A3 -- one root, two sids: arm/disarm of A leaves every file of B
# byte-identical.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    ok(H('arm', 'A', role=>'driver', by=>'arm-on-entry'), 'A3: arm(A) succeeds');
    write_json_file("$continuity/holder/B.json",
        {session_id=>'B', pid=>$$, fp=>('x' x 40), items=>[], deadline=>time()+100});
    H('mint_stop_token', 'B', {hook_event_name=>'Stop'});

    my $b_token_file = do {
        my $name;
        if (opendir(my $dh, "$continuity/stop-tokens")) {
            my @f = grep { $_ ne '.' && $_ ne '..' && $_ !~ /\.current$/ } readdir($dh);
            closedir $dh;
            $name = $f[0];
        }
        $name // 'NOPE';
    };
    my %before = (
        holder  => read_bytes("$continuity/holder/B.json"),
        token   => read_bytes("$continuity/stop-tokens/$b_token_file"),
        current => read_bytes("$continuity/stop-tokens/B.current"),
    );

    # AC13 (spec 05-remove-silence section 4.1, DC2 -- disarm half): a
    # planted silence/A record (set_silence is removed, so hand-plant it)
    # is left byte-identical by disarm(A).
    make_path("$continuity/silence");
    write_json_file("$continuity/silence/A",
        {session_id=>'A', by=>'butler-continuity', reason=>'keep me untouched', at=>time()});
    my $silence_a_before = read_bytes("$continuity/silence/A");

    is(H('is_armed', 'A'), 1, 'A3: is_armed(A) is 1 after arm(A)');
    is(H('is_armed', 'B'), 0, 'A3: is_armed(B) is 0 (never armed)');

    ok(H('disarm', 'A', actor=>'agent', reason=>'done with A'), 'A3: disarm(A) returns 1');
    ok(!-e "$continuity/armed/A", 'A3: armed/A removed');
    my $off = read_json_file("$continuity/off/A");
    is(ref($off) eq 'HASH' ? $off->{session_id} : undef, 'A', 'A3: off/A session_id');
    is(ref($off) eq 'HASH' ? $off->{actor}      : undef, 'agent', 'A3: off/A actor');
    is(ref($off) eq 'HASH' ? $off->{reason}     : undef, 'done with A', 'A3: off/A reason');
    ok(ref($off) eq 'HASH' && defined $off->{at}, 'A3: off/A has an at field');

    is(read_bytes("$continuity/holder/B.json"),       $before{holder},  'A3: B holder untouched after disarm(A)');
    is(read_bytes("$continuity/stop-tokens/$b_token_file"), $before{token},   'A3: B stop token untouched');
    is(read_bytes("$continuity/stop-tokens/B.current"),     $before{current}, 'A3: B stop-tokens/B.current untouched');
    is(read_bytes("$continuity/silence/A"), $silence_a_before,
        'AC13: a planted silence/A record is byte-identical after disarm(A)');
}

# ===========================================================================
# A4 -- arm() refuses while off/<sid> exists (unless by=>'on'); by=>'on'
# clears off; latest_is_off tracks; invalid role/by are refused.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    H('disarm', 'A4', actor=>'agent', reason=>'off first');
    ok(-e "$continuity/off/A4", 'A4 precondition: off/A4 exists');

    is(H('arm', 'A4', role=>'manual', by=>'arm-on-entry'), 0, 'A4: arm while off exists (by != on) returns 0');
    is(H('last_error'), 'off', 'A4: last_error is off');
    ok(!-e "$continuity/armed/A4", 'A4: nothing written to armed/A4');

    is(H('arm', 'A4', role=>'manual', by=>'on'), 1, 'A4: arm(by=>on) succeeds while off exists');
    ok(!-e "$continuity/off/A4", 'A4: off/A4 removed by the by=>on arm');
    is(H('latest_is_off', 'A4'), 0, 'A4: latest_is_off tracks the removal');

    H('disarm', 'A4', actor=>'agent', reason=>'off again');
    is(H('latest_is_off', 'A4'), 1, 'A4: latest_is_off tracks re-off');

    is(H('arm', 'A4', role=>'bogus-role', by=>'on'), 0, 'A4: invalid role refused');
    is(H('arm', 'A4', role=>'manual', by=>'Not Valid!'), 0, 'A4: invalid by refused');
}

# ===========================================================================
# R2-m4 -- disarm() copies the armed record's transcript_path into the
# off/<sid> record it writes, so gc_sessions' off-branch is reachable
# (review m4, BpHook.pm:392-397, declined in fix-batch.md: "disarm still
# writes off without transcript_path"). Spec sec 2.3's off example is silent
# on the field, but sec's own gc_sessions row ("take transcript_path from
# the arm record, or from the off record when the arm record has none") is
# dead code for every disarmed (never re-armed) session unless disarm
# carries it forward.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my $gone_transcript = "$root/gone-m4-$$.jsonl"; # never created
    ok(H('arm', 'M4', role=>'manual', by=>'arm-on-entry', transcript_path=>$gone_transcript),
        'R2-m4 setup: arm(M4) with a transcript_path succeeds');
    ok(H('disarm', 'M4', actor=>'agent', reason=>'done'), 'R2-m4 setup: disarm(M4) succeeds');

    my $off_rec = read_json_file("$continuity/off/M4");
    is(ref($off_rec), 'HASH', 'R2-m4: off/M4 parses as a hashref');
    if (ref($off_rec) eq 'HASH') {
        is($off_rec->{transcript_path}, $gone_transcript,
            'R2-m4: off/M4 carries the transcript_path that was on armed/M4 before disarm removed it');
    } else {
        fail('R2-m4: (placeholder) off/M4 carries transcript_path -- no hashref to inspect');
    }
}

# ===========================================================================
# A5 -- concurrency: 8 forked children alternately arm/disarm one sid.
# Afterwards exactly one of armed/off exists, it parses, and no .tmp. file
# remains anywhere under the root.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my @pids;
    for my $i (0 .. 7) {
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            if ($i % 2 == 0) { H('arm', 'CONC', role=>'manual', by=>'on') }
            else             { H('disarm', 'CONC', actor=>'agent', reason=>'concurrent test') }
            _exit(0);
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;

    my $armed_exists = -e "$continuity/armed/CONC" ? 1 : 0;
    my $off_exists    = -e "$continuity/off/CONC"   ? 1 : 0;
    is($armed_exists + $off_exists, 1,
       'A5: exactly one of armed/CONC and off/CONC exists after 8 concurrent arm/disarm forks');
    if ($armed_exists) {
        ok(defined read_json_file("$continuity/armed/CONC"), 'A5: the surviving armed/CONC file parses');
    } else {
        ok(defined read_json_file("$continuity/off/CONC"), 'A5: the surviving off/CONC file parses');
    }

    my @tmp_leftover;
    for my $sub (qw(armed off)) {
        next unless -d "$continuity/$sub";
        opendir(my $dh, "$continuity/$sub") or next;
        push @tmp_leftover, grep { /\.tmp\./ } readdir($dh);
        closedir $dh;
    }
    is(scalar(@tmp_leftover), 0, 'A5: no .tmp. file remains after the concurrent forks');
}

# ===========================================================================
# A6 -- AC7/AC8 (spec 05-remove-silence section 4.1, DC2): set_silence and
# take_silence are gone from BpHook.pm's symbol table, and no "/silence/"
# state path remains in its source. Plus AC13's gc half: a planted
# silence/<sid> record for a session whose transcript is gone survives
# gc_sessions byte-identical.
# ===========================================================================
{
    ok(!defined &BpHook::set_silence, 'AC7: &BpHook::set_silence is not defined');
    ok(!defined &BpHook::take_silence, 'AC7: &BpHook::take_silence is not defined');

    my $bphook_src = read_bytes($HOOKPM);
    unlike($bphook_src, qr/set_silence/, 'AC8: BpHook.pm has no set_silence reference');
    unlike($bphook_src, qr/take_silence/, 'AC8: BpHook.pm has no take_silence reference');
    unlike($bphook_src, qr/["']\$root\/silence|["']\$ROOT\/silence/, 'AC8: BpHook.pm has no silence state path');

    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my $gone_transcript = "$root/gone-silence-$$.jsonl"; # never created
    H('arm', 'A6GC', role=>'manual', by=>'arm-on-entry', transcript_path=>$gone_transcript);
    make_path("$continuity/silence");
    write_json_file("$continuity/silence/A6GC",
        {session_id=>'A6GC', by=>'butler-continuity', reason=>'keep me untouched', at=>time()});
    my $before = read_bytes("$continuity/silence/A6GC");

    my $count = H('gc_sessions');
    is($count, 1, 'AC13 (gc half): gc_sessions collects the session whose transcript is gone');
    ok(-e "$continuity/silence/A6GC", 'AC13 (gc half): the planted silence/A6GC record still exists after gc_sessions');
    is(read_bytes("$continuity/silence/A6GC"), $before,
        'AC13 (gc half): and is byte-identical');
}

# ===========================================================================
# A7 -- holder_live: a real child process, its own /proc/<pid>/cmdline fp,
# and every §2.4 branch. SKIP when /proc/self/cmdline is absent.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

  SKIP: {
        skip 'A7: no /proc/self/cmdline on this host', 9 unless -r '/proc/self/cmdline';

        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) { sleep(30); _exit(0) }
        push @KILL_PIDS, $pid;
        my $deadline = time() + 5;
        1 while !-r "/proc/$pid/cmdline" && time() < $deadline;

        my $cmdline = read_bytes("/proc/$pid/cmdline");
        my $fp = sha1_hex($cmdline // '');
        write_json_file("$continuity/holder/A.json",
            {session_id=>'A', pid=>$pid, fp=>$fp, items=>['x1'], deadline=>time()+60});

        my $bg_running_subagent = {background_tasks => [{id=>'x1', type=>'subagent', status=>'running'}]};
        is(H('holder_live', 'A', $bg_running_subagent), 1, 'A7: live with a running x1 background task');
        is(H('holder_live', 'A', {}), 1, 'A7: live without a background_tasks array at all');
        # Decision 131: on the non-coordinator path there is no
        # background_tasks cross-check at all -- a live own holder with
        # non-empty items is live whatever background_tasks says, whether the
        # held id reads completed, is absent, or only unheld ids (x2) run.
        is(H('holder_live', 'A', {background_tasks => [{id=>'x2', type=>'subagent', status=>'running'}]}), 1,
           'A7: Decision 131 -- still live when the only running id is x2 (unheld)');
        is(H('holder_live', 'A', {background_tasks => [{id=>'x1', type=>'subagent', status=>'completed'}]}), 1,
           'A7: Decision 131 -- still live when x1 is completed');

        is(H('holder_live', 'B', $bg_running_subagent), 0, 'A7: not live for B with no record');
        write_json_file("$continuity/holder/B.json",
            {session_id=>'A', pid=>$pid, fp=>$fp, items=>['x1'], deadline=>time()+60});
        is(H('holder_live', 'B', $bg_running_subagent), 0, "A7: not live for B whose record file holds A's session_id");

        write_json_file("$continuity/holder/A.json",
            {session_id=>'A', pid=>$pid, fp=>('0' x 40), items=>['x1'], deadline=>time()+60});
        is(H('holder_live', 'A', $bg_running_subagent), 0, 'A7: not live with a wrong fp (reused pid)');

        write_json_file("$continuity/holder/A.json",
            {session_id=>'A', pid=>$pid, fp=>$fp, items=>['x1'], deadline=>time()-10});
        is(H('holder_live', 'A', $bg_running_subagent), 0, 'A7: not live with a deadline in the past');

        write_json_file("$continuity/holder/A.json",
            {session_id=>'A', pid=>$pid, fp=>$fp, items=>['x1'], deadline=>time()+4000});
        is(H('holder_live', 'A', $bg_running_subagent), 0, 'A7: not live with a deadline now+4000 (past the 3600s ceiling)');

        write_json_file("$continuity/holder/A.json",
            {session_id=>'A', pid=>$pid, fp=>$fp, items=>['x1'], deadline=>time()+60});
        kill('KILL', $pid);
        waitpid($pid, 0);
        my $dead_deadline = time() + 5;
        1 while kill(0, $pid) && time() < $dead_deadline;
        is(H('holder_live', 'A', $bg_running_subagent), 0, 'A7: not live after the child is killed and reaped');
    }
}

# ===========================================================================
# R2-L5 -- holder_live rejects an empty /proc/<pid>/cmdline read even when
# the holder record's fp is exactly sha1(''), the value that hashing an
# empty cmdline produces (redteam L5, BpHook.pm:468-470, declined in
# fix-batch.md). A real short-lived child supplies the live pid; ONLY its
# fp is corrupted (to sha1('')) -- the process itself is real and its real
# cmdline is never empty, which is exactly why the CURRENT bug needs the
# read itself to also be empty to fire. This host's cygwin /proc never
# reports that: a zombie's cmdline reads back as the literal 9-byte text
# "<defunct>", confirmed empirically (never 0 bytes), and there is no
# supported way to make a live process's own argv empty from pure Perl. So
# _read_bytes is overridden for the EXACT "/proc/<pid>/cmdline" path of this
# one pid only -- every other path (including the holder JSON file itself,
# read via _read_json -> _read_bytes) still goes through the real sub -- to
# deterministically produce the one OS condition (a defined, zero-length
# cmdline read) the redteam's fix targets, on every platform this file runs
# on, without depending on a host-specific zombie quirk.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

  SKIP: {
        skip 'R2-L5: no /proc/self/cmdline on this host', 1 unless -r '/proc/self/cmdline';

        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) { sleep(30); _exit(0) }
        push @KILL_PIDS, $pid;
        my $deadline = time() + 5;
        1 while !-r "/proc/$pid/cmdline" && time() < $deadline;

        my $empty_fp = sha1_hex('');
        write_json_file("$continuity/holder/L5.json",
            {session_id=>'L5', pid=>$pid, fp=>$empty_fp, items=>['x1'], deadline=>time()+60});
        my $bg_running_subagent = {background_tasks => [{id=>'x1', type=>'subagent', status=>'running'}]};

        my $orig_read_bytes = \&BpHook::_read_bytes;
        my $target_path = "/proc/$pid/cmdline";
        local *BpHook::_read_bytes = sub {
            my ($path) = @_;
            return '' if defined($path) && $path eq $target_path;
            return $orig_read_bytes->(@_);
        };

        is(H('holder_live', 'L5', $bg_running_subagent), 0,
            "R2-L5: holder_live is 0 when fp is sha1('') and the live process's /proc cmdline read is empty");
    }
}

# ===========================================================================
# A8 -- coordinator holder_live: a dead pid is still live via a running
# subagent id; a running shell entry, or an absent background_tasks array,
# is not live.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    $ENV{BP_LEDGER} = '/x/ledger.md';
    my $continuity = "$root/continuity";

    write_json_file("$continuity/holder/CO.json",
        {session_id=>'CO', pid=>999999, fp=>('a' x 40), items=>['x1'], deadline=>time()+60});
    is(H('holder_live', 'CO', {background_tasks=>[{id=>'x1', type=>'subagent', status=>'running'}]}), 1,
       'A8: coordinator holder_live is 1 for a dead pid when a held id is a running subagent');
    is(H('holder_live', 'CO', {background_tasks=>[{id=>'x1', type=>'shell', status=>'running'}]}), 0,
       'A8: coordinator holder_live is 0 for a running shell entry (must be subagent)');
    is(H('holder_live', 'CO', {}), 0, 'A8: coordinator holder_live is 0 when background_tasks is absent');
}

# ===========================================================================
# A9 -- pid namespace discipline (DC3): a record carrying the WINPID is not
# live, and the module source never touches /proc/*/stat|status|winpid,
# tasklist, taskkill, Get-Process or ps -W.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

  SKIP: {
        skip 'A9: needs /proc/<pid>/winpid (MSYS)', 1 unless -e "/proc/$$/winpid";
        my $winpid = read_bytes("/proc/$$/winpid") // '';
        $winpid =~ s/\D+//g;
        my $cmdline = read_bytes("/proc/$$/cmdline");
        my $fp = sha1_hex($cmdline // '');
        write_json_file("$continuity/holder/W.json",
            {session_id=>'W', pid=>$winpid, fp=>$fp, items=>['x1'], deadline=>time()+60});
        is(H('holder_live', 'W', {background_tasks=>[{id=>'x1', type=>'subagent', status=>'running'}]}), 0,
           'A9: a record carrying the child\'s WINPID as pid (with the matching fp) is not live');
    }

    my $src = read_bytes($HOOKPM) // '';
    $src =~ s/#.*$//mg;
    unlike($src, qr{/proc/[^'"]*/(stat|status|winpid)\b|\btasklist\b|\btaskkill\b|Get-Process|\bps\s+-W},
        'A9: BpHook.pm source (comments stripped) never reads /proc/*/stat|status|winpid and never runs '
      . 'tasklist/taskkill/Get-Process/ps -W');
}

# ===========================================================================
# A10 -- stop tokens: mint/take/revoke/re-mint lifecycle, every mint refusal,
# and every malformed take_stop_token argument.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my $t = H('mint_stop_token', 'A10', {hook_event_name=>'Stop'});
    like($t // '', qr/^[0-9a-f]{8}$/, 'A10: mint_stop_token returns an 8-hex token');
    my $tokrec = read_json_file("$continuity/stop-tokens/" . ($t // 'NOPE'));
    is(ref($tokrec) eq 'HASH' ? $tokrec->{session_id} : undef, 'A10', 'A10: token file session_id');
    ok(ref($tokrec) eq 'HASH' && defined $tokrec->{minted_at}, 'A10: token file has minted_at');
    is(read_bytes("$continuity/stop-tokens/A10.current"), ($t // 'NOPE') . "\n",
       'A10: A10.current holds the token plus a newline');

    is(H('take_stop_token', $t), 'A10', 'A10: take_stop_token returns the sid');
    is(H('take_stop_token', $t), undef, 'A10: a second take of the same token returns undef');

    my $t2 = H('mint_stop_token', 'A10', {hook_event_name=>'Stop'});
    ok(H('revoke_stop_token', 'A10'), 'A10: revoke_stop_token(A10) succeeds');
    is(H('take_stop_token', $t2), undef, 'A10: revoke makes a fresh token untakeable');

    my $t3 = H('mint_stop_token', 'A10', {hook_event_name=>'Stop'});
    my $t4 = H('mint_stop_token', 'A10', {hook_event_name=>'Stop'});
    if (defined $t3 && defined $t4) {
        isnt($t3, $t4, 'A10: re-mint produces a different token');
    } else {
        fail('A10: re-mint produced an undef token (cannot compare)');
    }
    is(H('take_stop_token', $t3), undef, 'A10: re-mint makes the old token return undef');

    my $t5 = H('mint_stop_token', 'A10', {hook_event_name=>'Stop'});
    H('disarm', 'A10', actor=>'agent', reason=>'cleanup');
    is(H('take_stop_token', $t5), undef, 'A10: disarm revokes the current token');

    is(H('mint_stop_token', 'A10', {hook_event_name=>'SubagentStop'}), undef, 'A10: mint refused for SubagentStop');
    is(H('mint_stop_token', 'A10', {hook_event_name=>'Stop', agent_id=>'sub1'}), undef,
       'A10: mint refused for a Stop payload with agent_id');
    is(H('mint_stop_token', 'A10', {hook_event_name=>'Stop', agent_id=>['x']}), undef,
       'RV-M2: mint refused for a Stop payload with an arrayref agent_id (not treated as absent)');
    is(H('mint_stop_token', 'A10', {hook_event_name=>'Stop', agent_id=>{}}), undef,
       'RV-M2: mint refused for a Stop payload with a hashref agent_id');
    is(H('mint_stop_token', 'A10', {hook_event_name=>'PreToolUse'}), undef, 'A10: mint refused for PreToolUse');
    is(H('mint_stop_token', 'A10', undef), undef, 'A10: mint refused for an undef payload');
    is(H('mint_stop_token', '../x', {hook_event_name=>'Stop'}), undef, 'A10: mint refused for an invalid sid');

    my @before_listing = do {
        opendir(my $dh, "$continuity/stop-tokens") or ();
        $dh ? sort readdir($dh) : ();
    };
    for my $bad ('../x', 'ABCDEF12', 'abcdef123', '') {
        is(H('take_stop_token', $bad), undef, "A10: take_stop_token('$bad') returns undef");
    }
    my @after_listing = do {
        opendir(my $dh, "$continuity/stop-tokens") or ();
        $dh ? sort readdir($dh) : ();
    };
    is_deeply(\@after_listing, \@before_listing,
       'A10: the stop-tokens directory listing is unchanged by the invalid-token attempts');
}

# ===========================================================================
# A11 -- tickets: write/take lifecycle, name normalisation, expiry, and
# ambiguity.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my @argv = ('off', '--reason', 'all done now');
    my $p1 = {session_id=>'S1', tool_use_id=>'toolu_01A'};
    ok(H('write_ticket', $p1, 'butler-continuity', \@argv, operator=>0, background=>0), 'A11: write_ticket succeeds');
    my $k = sha1_hex(join("\0", 'butler-continuity', @argv));
    ok(-f "$continuity/tickets/$k/S1.toolu_01A.json", 'A11: ticket file at the exact sha1 key path');

    my $got = H('take_ticket', 'butler-continuity', \@argv);
    is(ref($got), 'HASH', 'A11: take_ticket returns a hashref');
    if (ref($got) eq 'HASH') {
        is($got->{session_id},  'S1', 'A11: ticket session_id');
        is($got->{tool_use_id}, 'toolu_01A', 'A11: ticket tool_use_id');
        is($got->{agent_id}, undef, 'A11: ticket agent_id undef when absent');
    } else {
        fail('A11: (placeholder) ticket session_id/tool_use_id/agent_id -- no hashref to inspect') for 1 .. 3;
    }
    is(H('take_ticket', 'butler-continuity', \@argv), undef, 'A11: a second take_ticket returns undef');
    is(H('take_ticket', 'butler-continuity', ['status']), undef, 'A11: a different argv returns undef');

    H('write_ticket', $p1, 'butler-hold.pl', ['x'], operator=>0, background=>0);
    my $k2 = sha1_hex(join("\0", 'butler-hold', 'x'));
    ok(-d "$continuity/tickets/$k2", 'A11: butler-hold.pl normalises to butler-hold');
    H('write_ticket', $p1, '/x/bin/butler-hold', ['y'], operator=>0, background=>0);
    my $k3 = sha1_hex(join("\0", 'butler-hold', 'y'));
    ok(-d "$continuity/tickets/$k3", 'A11: /x/bin/butler-hold normalises to butler-hold');
    is(H('write_ticket', $p1, 'bp-other', ['z'], operator=>0, background=>0), 0, 'A11: an unknown name gives 0');

    my $p_old = {session_id=>'SOLD', tool_use_id=>'toolu_old'};
    H('write_ticket', $p_old, 'butler-continuity', ['stale'], operator=>0, background=>0);
    my $k4 = sha1_hex(join("\0", 'butler-continuity', 'stale'));
    my ($old_file) = glob("$continuity/tickets/$k4/*.json");
    if ($old_file) {
        my $rec = read_json_file($old_file);
        $rec->{at} = time() - 31;
        write_json_file($old_file, $rec);
    }
    is(H('take_ticket', 'butler-continuity', ['stale']), undef, 'A11: an entry with at=now-31 is deleted and not returned');
    ok(!$old_file || !-e $old_file, 'A11: ...and the file is gone');

    my $p_future = {session_id=>'SFUT', tool_use_id=>'toolu_fut'};
    H('write_ticket', $p_future, 'butler-continuity', ['future'], operator=>0, background=>0);
    my $k5 = sha1_hex(join("\0", 'butler-continuity', 'future'));
    my ($fut_file) = glob("$continuity/tickets/$k5/*.json");
    if ($fut_file) {
        my $rec = read_json_file($fut_file);
        $rec->{at} = time() + 31;
        write_json_file($fut_file, $rec);
    }
    is(H('take_ticket', 'butler-continuity', ['future']), undef, 'A11: an entry with at=now+31 is deleted and not returned');

    my $pA = {session_id=>'SA', tool_use_id=>'toolu_a'};
    my $pB = {session_id=>'SB', tool_use_id=>'toolu_b'};
    H('write_ticket', $pA, 'butler-continuity', ['ambig'], operator=>0, background=>0);
    H('write_ticket', $pB, 'butler-continuity', ['ambig'], operator=>0, background=>0);
    is(H('take_ticket', 'butler-continuity', ['ambig']), 'ambiguous', 'A11: two sids with the same argv return the string ambiguous');
    my $k6 = sha1_hex(join("\0", 'butler-continuity', 'ambig'));
    my @remaining = glob("$continuity/tickets/$k6/*.json");
    is(scalar(@remaining), 2, 'A11: both ambiguous ticket files remain');

    is(H('write_ticket', $pA, 'butler-continuity', ['a', undef, 'b'], operator=>0, background=>0), 0,
       'A11: an argv with an undef slot gives 0');
    is(H('write_ticket', {session_id=>'SA', tool_use_id=>'../bad'}, 'butler-continuity', ['x'], operator=>0, background=>0), 0,
       'A11: a bad tuid gives 0');
    is(H('write_ticket', {session_id=>'../bad', tool_use_id=>'toolu_x'}, 'butler-continuity', ['x'], operator=>0, background=>0), 0,
       'A11: a bad sid gives 0');

    my $char_andre = "Andr\x{e9}";
    my $byte_andre = $char_andre;
    utf8::encode($byte_andre); # now a byte string, "Andr\xC3\xA9"
    my $pC = {session_id=>'SC', tool_use_id=>'toolu_c'};
    my $pD = {session_id=>'SD', tool_use_id=>'toolu_d'};
    H('write_ticket', $pC, 'butler-continuity', [$char_andre], operator=>0, background=>0);
    H('write_ticket', $pD, 'butler-continuity', [$byte_andre], operator=>0, background=>0);
    my $kc = sha1_hex(join("\0", 'butler-continuity', $byte_andre));
    ok(-f "$continuity/tickets/$kc/SC.toolu_c.json",
       'A11: a character-string Andr\x{e9} argument keys the same as the byte form (C path)');
    ok(-f "$continuity/tickets/$kc/SD.toolu_d.json", 'A11: ...and the byte-string form itself (D path)');

    # m1/L3 (redteam L3, review m1): the ticket key must be computed over the
    # UTF-8 bytes of argv with NO slash-folding -- _to_bytes is the *path*
    # normaliser (it folds \ to /) and must not be reused verbatim for argv,
    # or two different commands share one binding.
    my $pG = {session_id=>'SG', tool_use_id=>'toolu_g'};
    my $pH_ = {session_id=>'SH', tool_use_id=>'toolu_h'};
    ok(H('write_ticket', $pG, 'butler-continuity', ['off','--reason','a\\b c'], operator=>0, background=>0),
       'm1/L3: write_ticket(argv with a literal backslash) succeeds');
    ok(H('write_ticket', $pH_, 'butler-continuity', ['off','--reason','a/b c'], operator=>0, background=>0),
       'm1/L3: write_ticket(argv with a forward slash instead) succeeds');
    my $got_bs = H('take_ticket', 'butler-continuity', ['off','--reason','a\\b c']);
    is(ref($got_bs) eq 'HASH' ? $got_bs->{session_id} : undef, 'SG',
       'm1/L3: take_ticket for the backslash argv returns SG, not folded onto the slash-argv ticket');
    my $got_sl = H('take_ticket', 'butler-continuity', ['off','--reason','a/b c']);
    is(ref($got_sl) eq 'HASH' ? $got_sl->{session_id} : undef, 'SH',
       'm1/L3: take_ticket for the slash argv returns its own SH binding, untouched by the backslash write');

    # L3 (redteam): a NUL byte inside a single argv element must not collide
    # with the ticket key's "\0"-joined separator. The documented fix is to
    # refuse (return 0) any argv element containing "\0", never to silently
    # key it the same as the multi-element form.
    my $pE = {session_id=>'SE', tool_use_id=>'toolu_e'};
    my $pF = {session_id=>'SF', tool_use_id=>'toolu_f'};
    is(H('write_ticket', $pE, 'butler-continuity', ["off\0--reason\0x y"], operator=>0, background=>0), 0,
       'L3: write_ticket refuses an argv element containing a NUL byte');
    ok(H('write_ticket', $pF, 'butler-continuity', ['off','--reason','x y'], operator=>0, background=>0),
       'L3: ...and the equivalent normal 3-element argv still succeeds (no collision from the refused write)');
    my $got_nul_free = H('take_ticket', 'butler-continuity', ['off','--reason','x y']);
    is(ref($got_nul_free) eq 'HASH' ? $got_nul_free->{session_id} : undef, 'SF',
       'L3: take_ticket for the normal argv returns SF, never a binding corrupted by the refused NUL write');

    # R2-L12 -- once take_ticket consumes the LAST live ticket in a key's
    # directory, that directory itself is gone: no leftover .claimed.<pid>
    # file, and no empty tickets/<k>/ directory left to accumulate forever
    # (redteam L12, BpHook.pm take_ticket, declined in fix-batch.md as
    # "n8/L12 ... deferred as unbounded-growth cleanup").
    my $pL12 = {session_id=>'SL12', tool_use_id=>'toolu_l12'};
    ok(H('write_ticket', $pL12, 'butler-continuity', ['l12-solo'], operator=>0, background=>0),
       'R2-L12 setup: write_ticket succeeds');
    my $kL12 = sha1_hex(join("\0", 'butler-continuity', 'l12-solo'));
    ok(-d "$continuity/tickets/$kL12", 'R2-L12 setup: the ticket key directory exists before the take');
    my $gotL12 = H('take_ticket', 'butler-continuity', ['l12-solo']);
    is(ref($gotL12), 'HASH', 'R2-L12 setup: take_ticket consumes the sole (last) ticket');
    ok(!-d "$continuity/tickets/$kL12",
       'R2-L12: the ticket key directory is removed once its last ticket is taken');
    my @l12_leftovers = glob("$continuity/tickets/$kL12*") ;
    is(scalar(@l12_leftovers), 0,
       'R2-L12: no .claimed.<pid> (or any other) file is left behind under the removed key path');
}

# ===========================================================================
# A12 -- invocations(): segmentation, prefix-skipping, quoting/metachar
# refusal into argv slots, and the ignored-command-word list.
# ===========================================================================
{
    my @cases = (
        [q{butler-continuity off --reason 'tests & docs; done | ok $x !'}, 1],
        ['timeout 5 env A=1 perl -w /p/butler-continuity.pl on', 1],
        ['cd x && butler-continuity status', 1],
        ['y=$(butler-continuity status)', 1],
        ["butler-continuity off --reason 'line1\nAndr\xC3\xA9'", 1],
        ['echo butler-continuity off', 0],
        ['grep butler-continuity f', 0],
        [q{'butler-continuity off'}, 0],
        ["cat <<WORD\nbutler-continuity off\nWORD\n", 0],
        ['butler-continuity on; butler-continuity status 2>&1', 2],
    );
    for my $c (@cases) {
        my ($cmd, $n) = @$c;
        my @res = HL('invocations', $cmd, 'butler-continuity');
        (my $label = $cmd) =~ s/\n/\\n/g;
        is(scalar(@res), $n, "A12: invocations() on [$label] returns $n match(es)");
    }
    my @res = HL('invocations', 'butler-continuity --reason "$R"', 'butler-continuity');
    if (@res && ref($res[0]) eq 'ARRAY') {
        is($res[0][0], '--reason', 'A12: argv[0] preserved literally');
        is($res[0][1], undef, 'A12: the $R-bearing reason slot is undef');
    } else {
        fail('A12: (placeholder) argv[0] literal') ;
        fail('A12: (placeholder) $R-bearing slot is undef');
    }

    # RV-M3 / RT-M4: forms the review and red-team both reproduced as
    # fail-open misses for the director-call/deny-side consumers (07, 14).
    # Each is a real invocation bash actually runs; invocations() must find it.
    my @edge_cases = (
        ['{ butler-continuity status; }', 1, 'a leading bare { is a transparent literal, not an unpredictable word'],
        ['(butler-continuity status)', 1, 'a leading ( glued to the command word is stripped'],
        ['if true; then butler-continuity status; fi', 1, "'then' is a transparent prefix"],
        ['while true; do butler-continuity status; done', 1, "'do' is a transparent prefix"],
        ['! butler-continuity status', 1, "'!' is a transparent prefix"],
        ['time butler-continuity status', 1, "'time' is a transparent prefix"],
        ["cat <<<hello\nbutler-continuity off --reason q\n", 1,
         '<<< is a here-string (single line), never a heredoc -- the next line still runs'],
    );
    for my $c (@edge_cases) {
        my ($cmd, $n, $why) = @$c;
        my @res2 = HL('invocations', $cmd, 'butler-continuity');
        (my $label = $cmd) =~ s/\n/\\n/g;
        is(scalar(@res2), $n, "RV-M3/RT-M4: invocations() on [$label] returns $n match(es) ($why)");
    }

    # RV-M3 / RT-M4 (redteam M4 fix item 1): invocations()==1 cannot express
    # "this command is ONLY that invocation" -- 'butler-hold a1 && sleep 999'
    # and 'butler-hold a1; long-job' each yield exactly one invocation, which
    # over-exempts the whole compound command for any consumer checking
    # invocations()==1 (package 14's headless no-background exemption). The
    # spec names no such predicate, so this uses the name the finding
    # proposes: BpHook::sole_invocation($command, $name) -> the argv only
    # when the command is EXACTLY one invocation of $name and nothing else
    # (no other segment, no &&/|| tail, no trailing & job); otherwise undef.
    ok(defined &BpHook::sole_invocation,
        'RV-M3: BpHook::sole_invocation exists (a sole-call predicate distinct from invocations()==1)');
  SKIP: {
        my @sole_cases = (
            ['butler-hold a1',                 1, 'true for a bare single call'],
            ['butler-hold a1 && sleep 999',    0, 'false when a && tail follows (over-exemption repro)'],
            ['butler-hold a1; long-job',       0, 'false when a ; tail follows (over-exemption repro)'],
            ['sleep 1 && butler-hold a1',      0, 'false when a leading segment precedes it'],
            ['butler-hold a1 &',               0, 'false for a trailing background job'],
        );
        skip 'RV-M3: sole_invocation not yet implemented', scalar(@sole_cases)
            unless defined &BpHook::sole_invocation;
        for my $c (@sole_cases) {
            my ($cmd, $expect_true, $why) = @$c;
            my $res3 = H('sole_invocation', $cmd, 'butler-hold');
            if ($expect_true) {
                is(ref($res3), 'ARRAY', "RV-M3: sole_invocation('$cmd') $why (returns the argv)");
            } else {
                is($res3, undef, "RV-M3: sole_invocation('$cmd') $why (returns undef)");
            }
        }
    }
}

# ===========================================================================
# A13 -- session_id/agent_id validation, and path-traversal refusal across
# every function that takes a sid.
# ===========================================================================
{
    for my $bad ('../x', 'a/b', 'a\\b', '.', '', ('x' x 129)) {
        is(H('session_id', {session_id => $bad}), undef, "A13: session_id rejects '$bad'");
    }
    is(H('session_id', {session_id => undef}), undef, 'A13: session_id rejects undef');
    is(H('session_id', {session_id => 123}), undef, 'A13: session_id rejects a non-string (number)');

    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    for my $fn_call (
        ['arm',             ['../escape', role=>'manual', by=>'arm-on-entry']],
        ['disarm',          ['../escape', actor=>'agent', reason=>'x y']],
        ['holder',          ['../escape']],
        ['latest_is_off',   ['../escape']],
        ['mint_stop_token', ['../escape', {hook_event_name=>'Stop'}]],
    ) {
        my ($fn, $args) = @$fn_call;
        ok(!H($fn, @$args), "A13: $fn('../escape', ...) returns false");
    }
    ok(!-e "$root/../escape", 'A13: nothing created beside the root');
    if (opendir(my $dh, $continuity)) {
        my @entries = grep { !/^\.\.?$/ } readdir($dh);
        closedir $dh;
        ok(!(grep { /escape/ } @entries), 'A13: nothing named escape created inside the root');
    } else {
        pass('A13: continuity dir was never created (nothing to check inside it)');
    }

    is(H('agent_id', {}), undef, 'A13: agent_id undef when the key is absent');
    is(H('agent_id', {agent_id=>'sub-1'}), 'sub-1', 'A13: agent_id returns a valid id');
    is(H('agent_id', {agent_id=>'a/b'}), '?', "A13: agent_id returns '?' for an invalid id");

    # RV-M2 (review) / L2 (redteam): a non-scalar agent_id (hashref, arrayref,
    # or a JSON::PP::Boolean, which is also a ref) must count as PRESENT
    # ('?'), never as absent (undef) -- the spec's invariant is "never minted
    # for a payload that carries one", and undef reads as the main thread.
    is(H('agent_id', {agent_id=>{}}), '?', "RV-M2: agent_id returns '?' for a hashref agent_id");
    is(H('agent_id', {agent_id=>['x']}), '?', "RV-M2: agent_id returns '?' for an arrayref agent_id");
    is(H('agent_id', {agent_id=>JSON::PP::true()}), '?',
        "RV-M2: agent_id returns '?' for a JSON::PP::Boolean (true) agent_id");
    is(H('agent_id', {agent_id=>JSON::PP::false()}), '?',
        "RV-M2: agent_id returns '?' for a JSON::PP::Boolean (false) agent_id");

    # L1 (redteam): the id regexes anchor with $, not \z, so a trailing
    # newline passes validation and is joined into a path/log field.
    is(H('session_id', {session_id => "victim\n"}), undef,
        'L1: session_id rejects a trailing newline (regex must anchor with \z, not $)');
    is(H('agent_id', {agent_id => "a\n"}), '?',
        "L1: agent_id returns '?' (not the raw value) for an id with a trailing newline");
}

# ===========================================================================
# A14 -- state_dir() resolution ladder: BUTLER_STATE_DIR, HOME, USERPROFILE,
# and the fully-unset case propagating "no state root" everywhere.
# ===========================================================================
{
    {
        local %ENV = %ENV; scrub_env();
        my $t = tempdir(CLEANUP=>1);
        $ENV{BUTLER_STATE_DIR} = $t;
        is(H('state_dir'), "$t/continuity", 'A14: absolute BUTLER_STATE_DIR gives <it>/continuity');
    }
    {
        local %ENV = %ENV; scrub_env();
        $ENV{BUTLER_STATE_DIR} = 'rel/x';
        is(H('state_dir'), undef, 'A14: a relative BUTLER_STATE_DIR gives undef');
    }
    {
        local %ENV = %ENV; scrub_env();
        delete $ENV{BUTLER_STATE_DIR};
        my $home = tempdir(CLEANUP=>1);
        $ENV{HOME} = $home;
        is(H('state_dir'), "$home/.claude/butler-state/continuity",
           'A14: HOME gives <HOME>/.claude/butler-state/continuity');
    }
    {
        local %ENV = %ENV; scrub_env();
        delete $ENV{BUTLER_STATE_DIR}; delete $ENV{HOME};
        $ENV{USERPROFILE} = 'C:\\Users\\A14Fixture';
        is(H('state_dir'), 'C:/Users/A14Fixture/.claude/butler-state/continuity',
           'A14: an unset HOME with a backslash USERPROFILE gives the /-form path');
    }
    {
        local %ENV = %ENV; scrub_env();
        delete $ENV{BUTLER_STATE_DIR}; delete $ENV{HOME}; delete $ENV{USERPROFILE};
        is(H('state_dir'), undef, 'A14: all three unset gives undef');
        is(H('is_armed', 'A14X'), 0, 'A14: ...and is_armed is 0');
        is(H('arm', 'A14X', role=>'manual', by=>'arm-on-entry'), 0, 'A14: ...and arm returns 0');
        is(H('last_error'), 'no state root', 'A14: ...with last_error "no state root"');
        is(H('mint_stop_token', 'A14X', {hook_event_name=>'Stop'}), undef, 'A14: ...and mint_stop_token returns undef');
    }
}

# ===========================================================================
# A15 -- non-ASCII: arm() with a character-string transcript_path writes the
# two-byte UTF-8 form on disk, never the doubly-encoded form.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = andre_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my $char_path = "C:/Users/Andr\x{e9}/x.jsonl";
    ok(H('arm', 'A15', role=>'manual', by=>'arm-on-entry', transcript_path=>$char_path),
       'A15: arm() with a character-string transcript_path succeeds');
    my $bytes = read_bytes("$continuity/armed/A15") // '';
    ok(index($bytes, "Andr\xC3\xA9") >= 0, 'A15: the arm file contains the two-byte UTF-8 form Andr\xC3\xA9');
    ok(index($bytes, "Andr\xC3\x83") < 0, 'A15: ...and never the doubly-encoded Andr\xC3\x83 form');

    is(H('role', {session_id=>'A15'}), 'manual', 'A15: role() reads the Andr\x{e9}-rooted arm file back correctly');
    is(H('is_armed', 'A15'), 1, 'A15: is_armed() reads the Andr\x{e9}-rooted arm file back correctly');
}

# ===========================================================================
# A16 -- gc_sessions(): removes every file of a session whose transcript is
# gone, keeps sessions with a live (or André, or absent) transcript_path,
# logs a gc line, and returns the count.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my $gone_transcript = "$root/gone-$$.jsonl"; # never created
    H('arm', 'GC1', role=>'manual', by=>'arm-on-entry', transcript_path=>$gone_transcript);
    write_json_file("$continuity/holder/GC1.json",
        {session_id=>'GC1', pid=>1, fp=>('a' x 40), items=>[], deadline=>time()+60});
    H('mint_stop_token', 'GC1', {hook_event_name=>'Stop'});

    my $live_transcript = "$root/live.jsonl";
    open my $lfh, '>', $live_transcript or die $!; close $lfh;
    H('arm', 'GC2', role=>'manual', by=>'arm-on-entry', transcript_path=>$live_transcript);

    my $andre_transcript = "$root/Andr\xC3\xA9.jsonl";
    open my $afh, '>', $andre_transcript or die $!; close $afh;
    H('arm', 'GC3', role=>'manual', by=>'arm-on-entry', transcript_path=>$andre_transcript);

    H('arm', 'GC4', role=>'manual', by=>'arm-on-entry'); # no transcript_path

    my $count = H('gc_sessions');
    is($count, 1, 'A16: gc_sessions removes exactly one session (the one whose transcript is gone)');
    ok(!-e "$continuity/armed/GC1", 'A16: armed/GC1 removed');
    ok(!-e "$continuity/holder/GC1.json", 'A16: holder/GC1.json removed');
    ok(-e "$continuity/armed/GC2", 'A16: armed/GC2 kept (transcript exists)');
    ok(-e "$continuity/armed/GC3", 'A16: armed/GC3 kept (Andr\x{e9} transcript exists)');
    ok(-e "$continuity/armed/GC4", 'A16: armed/GC4 kept (no transcript_path recorded)');

    my $log = read_bytes("$continuity/reasons.log") // '';
    like($log, qr/\tgc\tgc\t-\ttranscript gone:/, 'A16: reasons.log gained a gc/gc/-/transcript-gone line');
}

# ===========================================================================
# R2-m5/L4 -- take_stop_token and gc_sessions must not proceed while a real,
# external process holds LOCK_EX on armlock/<sid> (review m5, redteam L4;
# both declined in fix-batch.md: gc "works without the lock and unlinks the
# flock target"; set_silence/take_silence/take_stop_token have "none of
# these five sub-cases oracle coverage").
#
# The M5SET (set_silence) and M5TAKE (take_silence) sub-cases that used to
# live here were removed by package 05-remove-silence
# (.ccpraxis-local-data/blueprints/judged-continuity-disarm/packages/05-remove-silence.md),
# which deletes BpHook::set_silence and BpHook::take_silence entirely
# (spec section 2.3). M5TOK (take_stop_token) and M5GC (gc_sessions) are
# unaffected and remain below.
#
# specs/03-hook-core-spec.md names a lock-timeout seam (a 10s alarm-bound
# flock returning 0 with "io: lock timeout") ONLY for arm() and disarm() --
# grepped; nothing else in the spec or architecture parameterises a timeout
# for these four functions. Per this round's own fallback instruction, only
# the observable half is pinned here: NONE of the four may return before
# the external holder releases armlock/<sid> (they may legitimately wait
# and then succeed). The alternative branch ("return a lock-timeout error
# with last_error set") has no seam to invoke deterministically and is not
# asserted; a race on the interleaving itself is not asserted either, only
# the wall-clock floor a correct wait imposes.
#
# take_stop_token's OWN redteam-suggested fix ("claim <sid>.current by
# rename before comparing") does not name armlock/<sid> as its guard --
# unlike the other three, a fix that follows that suggestion literally would
# not make this specific assertion pass. Included anyway per this round's
# explicit instruction (which asks for all four); flagged here and in the
# handback report as the one sub-case whose pass depends on the
# implementer choosing armlock/<sid> as take_stop_token's guard too, not
# merely on fixing the race redteam actually described.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";
    my $HOLD = 2; # seconds an external process holds armlock/<sid>

    # call_while_locked($sid, $code) -- forks a real process that opens and
    # flock(LOCK_EX)s armlock/<sid>, signals readiness via a tempfile, holds
    # the lock for $HOLD seconds, then releases and exits. Once the parent
    # sees the readiness file, it times $code->() and returns
    # {elapsed=>secs, ret=>.., err=>last_error} after reaping the child.
    my $call_while_locked = sub {
        my ($sid, $code) = @_;
        make_path("$continuity/armlock");
        my $lockpath = "$continuity/armlock/$sid";
        my ($rfh, $ready_path) = tempfile(); close $rfh; unlink $ready_path;

        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            open(my $lfh, '>>', $lockpath) or _exit(1);
            unless (flock($lfh, LOCK_EX)) { _exit(1) }
            open(my $rfh2, '>', $ready_path) or _exit(1); close $rfh2;
            sleep($HOLD);
            flock($lfh, LOCK_UN);
            close $lfh;
            _exit(0);
        }
        push @KILL_PIDS, $pid;

        my $deadline = time() + 5;
        1 while !-e $ready_path && time() < $deadline;
        my $ready = -e $ready_path ? 1 : 0;

        H('last_error'); # (no-op; keeps the call shape symmetric with below)
        my $t0 = time();
        my $ret = $code->();
        my $elapsed = time() - $t0;
        my $err = H('last_error');

        waitpid($pid, 0);
        return { elapsed=>$elapsed, ret=>$ret, err=>$err, ready=>$ready };
    };

    my $tok = H('mint_stop_token', 'M5TOK', {hook_event_name=>'Stop'});
    ok(defined $tok, 'R2-m5/L4 setup: mint_stop_token(M5TOK) succeeds');
    my $r3 = $call_while_locked->('M5TOK', sub { H('take_stop_token', $tok) });
    ok($r3->{ready}, 'R2-m5/L4 setup: the external holder signalled it holds armlock/M5TOK (take_stop_token case)');
    cmp_ok($r3->{elapsed}, '>=', $HOLD - 0.5,
        "R2-m5/L4: take_stop_token(\$tok bound to M5TOK) does not return before armlock/M5TOK's external "
      . "holder releases it (elapsed $r3->{elapsed}s of a ${HOLD}s hold; last_error='" . ($r3->{err} // '') . "'); "
      . "NOTE: this sub-case is unpinnable against the redteam's OWN suggested fix for take_stop_token (a "
      . "rename-claim on <sid>.current, not armlock) -- see the block comment above");

    my $gone_transcript = "$root/gone-m5-$$.jsonl"; # never created
    ok(H('arm', 'M5GC', role=>'manual', by=>'arm-on-entry', transcript_path=>$gone_transcript),
        'R2-m5/L4 setup: arm(M5GC) with a gone transcript_path succeeds');
    my $r4 = $call_while_locked->('M5GC', sub { H('gc_sessions') });
    ok($r4->{ready}, 'R2-m5/L4 setup: the external holder signalled it holds armlock/M5GC (gc_sessions case)');
    cmp_ok($r4->{elapsed}, '>=', $HOLD - 0.5,
        "R2-m5/L4: gc_sessions() does not return before armlock/M5GC's external holder releases it "
      . "(elapsed $r4->{elapsed}s of a ${HOLD}s hold; last_error='" . ($r4->{err} // '') . "')");
}

# ===========================================================================
# A17 -- log_reason(): exact line format, tab/CR/LF flattening, 300-char
# text cut, and the 1 MiB rotation.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    H('log_reason', 'A17', 'agent', 'off', "a\ttab\nand\rreturn", '/some/project');
    my $log = read_bytes("$continuity/reasons.log") // '';
    my ($line) = ($log =~ /^(.*)$/m);
    like($line // '', qr/^\S+\tA17\tagent\toff\t\/some\/project\ta tab and return$/,
        'A17: log_reason produces the exact tab/newline/CR-flattened line format');

    H('log_reason', 'A17', 'operator', 'silence', ('x' x 400), undef);
    $log = read_bytes("$continuity/reasons.log") // '';
    my @lines = split /\n/, $log;
    my $last = $lines[-1] // '';
    my (undef, undef, undef, undef, undef, $text) = split /\t/, $last, 6;
    is(length($text // ''), 300, 'A17: the text field is cut to exactly 300 characters');
    like($last, qr/\t-\t/, 'A17: an undef project is written as -');

    my $reasons_log = "$continuity/reasons.log";
    make_path($continuity);
    open my $fh, '>', $reasons_log or die $!;
    print {$fh} ('x' x (1024 * 1024 + 10));
    close $fh;
    H('log_reason', 'A17', 'agent', 'off', 'roll me', undef);
    ok(-f "$reasons_log.1", 'A17: the log rolled to .1 once it exceeded 1 MiB');
    my $new_log = read_bytes($reasons_log) // '';
    like($new_log, qr/roll me/, 'A17: the new append landed in the fresh reasons.log after rolling');
}

# ===========================================================================
# RV-M1 / RT-M5 -- log_reason() must flatten tabs/CR/LF in EVERY field, not
# only $text (spec §2.3: "Tabs, CR and LF in any field become spaces"), and
# must decode-once every field before the join so a byte-string project
# path is never double-encoded when the text carries a non-ASCII character.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    H('log_reason', 'M1SID', 'agent', 'off', 'clean text here', "pr\tj\nx");
    my $log = read_bytes("$continuity/reasons.log") // '';
    my @lines = grep { length } split /\n/, $log;
    is(scalar(@lines), 1,
        'RV-M1: a tab/newline in the project field does not forge an extra physical reasons.log line');
    like($lines[0] // '', qr/^\S+\tM1SID\tagent\toff\tpr j x\tclean text here$/,
        'RV-M1: the project field is tab/newline-flattened exactly like the text field');
}
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    # Exact redteam M5 repro: a byte-string (unflagged) André project
    # together with a non-ASCII (byte-string) reason. $ANDRE is the raw
    # UTF-8 bytes "Andr\xC3\xA9", matching what data_dir/_to_bytes/env
    # actually hand log_reason on this host.
    my $byte_project  = "C:/Users/$ANDRE/proj";
    my $nonascii_text = "done \xE2\x80\x94 ok"; # byte-string em dash
    H('log_reason', 'M1B', 'agent', 'off', $nonascii_text, $byte_project);
    my $log = read_bytes("$continuity/reasons.log") // '';
    ok(index($log, "Andr\xC3\xA9") >= 0,
        'RT-M5: the byte-string André project is written as exactly the two-byte UTF-8 form C3 A9');
    ok(index($log, "Andr\xC3\x83") < 0,
        'RT-M5: ...and never the double-encoded C3 83 C2 A9 form (the André bug)');
}

# ===========================================================================
# A18 -- load_payload/payload/payload_ok/parse_count.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $raw = JSON::PP->new->encode({session_id=>'S18'});
    H('load_payload', $raw);
    is(H('payload_ok'), 1, 'A18: valid JSON gives payload_ok 1');
    my $count_before = H('parse_count');
    H('payload'); H('payload');
    is(H('parse_count'), $count_before, 'A18: calling payload() twice leaves parse_count unchanged');

    H('load_payload', '{not json');
    is_deeply(H('payload'), {}, 'A18: bad JSON gives {}');
    is(H('payload_ok'), 0, 'A18: bad JSON gives payload_ok 0');

    H('load_payload', '[1,2,3]');
    is_deeply(H('payload'), {}, 'A18: a JSON array gives {}');
    is(H('payload_ok'), 0, 'A18: a JSON array gives payload_ok 0');

    {
        local $ENV{BP_PAYLOAD_TRUNCATED} = 1;
        H('load_payload', $raw);
        is_deeply(H('payload'), {}, 'A18: BP_PAYLOAD_TRUNCATED=1 gives {} even for otherwise-valid JSON');
        is(H('payload_ok'), 0, 'A18: ...and payload_ok 0');
    }
}

# ===========================================================================
# R6-M2 (red-team MEDIUM-2, Decision 51 re-scope): a lone (unpaired) UTF-16
# surrogate escape in the payload's free text -- one bad code unit sliced
# out of last_assistant_message, or a Node JSON.stringify artefact of an
# unpaired surrogate -- makes JSON::PP's decode die outright ("missing low
# surrogate character"). TODAY load_payload treats that exactly like any
# other malformed JSON: payload_ok=0, payload {}, so every field including
# session_id and hook_event_name is lost, and a caller (e.g. the Stop gate)
# fails open. The core must tolerate this: replace the lone surrogate with
# U+FFFD (rather than fail the whole decode) so a payload that is otherwise
# well-formed still decodes with every OTHER field intact, including
# session_id.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $raw = qq({"session_id":"R6M2","hook_event_name":"Stop","stop_hook_active":false,)
            . qq("last_assistant_message":"cut \\ud800"});
    H('load_payload', $raw);
    is(H('payload_ok'), 1,
        'R6-M2: a payload with a lone UTF-16 surrogate escape still decodes (payload_ok 1), not a fail-open {}');
    is(ref(H('payload')) eq 'HASH' ? H('payload')->{session_id} : undef, 'R6M2',
        'R6-M2: ...and session_id is recovered from the rest of the (otherwise well-formed) payload');
    is(ref(H('payload')) eq 'HASH' ? H('payload')->{hook_event_name} : undef, 'Stop',
        'R6-M2: ...and hook_event_name is recovered too');

    # the paired (valid) surrogate case must be completely unaffected --
    # this is not a blanket "strip all \u" workaround, only lone escapes.
    my $raw_paired = qq({"session_id":"R6M2B","hook_event_name":"Stop",)
                   . qq("last_assistant_message":"smile \\ud83d\\ude00"});
    H('load_payload', $raw_paired);
    is(H('payload_ok'), 1, 'R6-M2: a payload with a VALID (paired) surrogate decodes fine, unaffected by the fix');
    is(ref(H('payload')) eq 'HASH' ? H('payload')->{session_id} : undef, 'R6M2B',
        'R6-M2: ...session_id recovered for the paired-surrogate case too');
}

# ===========================================================================
# A19 -- main(): STDIN from a temp file, fixture BpHook::<Module> modules on
# a temp @INC dir, and every return/die/warn/name-validity path.
# ===========================================================================
{
    my $inc_dir = tempdir(CLEANUP=>1);
    make_path("$inc_dir/BpHook");
    my %fixtures = (
        Ret2  => 'sub run { return 2 }',
        Ret1  => 'sub run { return 1 }',
        Ret2x => q{sub run { return '2x' }},
        Dies  => q{sub run { die "boom A19\n" }},
        Warns => q{sub run { warn "warned A19\n"; return 0 }},
    );
    for my $mod (sort keys %fixtures) {
        open my $fh, '>', "$inc_dir/BpHook/$mod.pm" or die $!;
        print {$fh} "package BpHook::$mod;\n$fixtures{$mod}\n1;\n";
        close $fh;
    }
    local @INC = ($inc_dir, @INC);

    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my $run_main = sub {
        my (@args) = @_;
        my ($fh, $path) = tempfile();
        print {$fh} '{"session_id":"A19"}';
        close $fh;
        local *STDIN;
        open(STDIN, '<', $path) or die $!;
        my $ret = H('main', @args);
        close STDIN;
        return $ret;
    };

    is($run_main->('Ret2'),  2, 'A19: run returning 2 gives main() 2');
    is($run_main->('Ret1'),  0, 'A19: run returning 1 gives main() 0');
    is($run_main->('Ret2x'), 0, "A19: run returning '2x' gives main() 0");

    my $errlog_before = read_bytes("$continuity/hook-errors.log") // '';
    is($run_main->('Dies'), 0, 'A19: run dying gives main() 0');
    my $errlog_after = read_bytes("$continuity/hook-errors.log") // '';
    cmp_ok(length($errlog_after), '>', length($errlog_before), 'A19: a die appends (at least) one hook-errors.log line');

    is($run_main->('NoSuchFixtureXYZ'), 0, 'A19: a missing module gives main() 0');
    is($run_main->('../X'), 0, 'A19: an invalid module name (../X) gives main() 0');

    my ($errfh, $errpath) = tempfile();
    close $errfh;
    my $before_log = read_bytes("$continuity/hook-errors.log") // '';
    {
        local *STDERR;
        open(STDERR, '>', $errpath) or die $!;
        $run_main->('Warns');
        close STDERR;
    }
    my $stderr_out = read_bytes($errpath) // '';
    is($stderr_out, '', 'A19: a warn inside run writes nothing to STDERR');
    my $after_log = read_bytes("$continuity/hook-errors.log") // '';
    cmp_ok(length($after_log), '>', length($before_log), 'A19: ...and writes (at least) one line to hook-errors.log');
}

# ===========================================================================
# A20 -- deny()/context().
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    $ENV{BUTLER_STATE_DIR} = fresh_state_root();

    my ($fh, $path) = tempfile();
    close $fh;
    my $rc;
    {
        local *STDERR;
        open(STDERR, '>', $path) or die $!;
        $rc = H('deny', 'a', 'b');
        close STDERR;
    }
    is($rc, 2, 'A20: deny(...) returns 2');
    is(read_bytes($path), "a\nb\n", 'A20: deny(...) writes "a\nb\n" to STDERR');
}
{
    local %ENV = %ENV; scrub_env();
    $ENV{BUTLER_STATE_DIR} = fresh_state_root();

    my ($fh, $path) = tempfile();
    close $fh;
    my $rc;
    {
        local *STDOUT;
        open(STDOUT, '>', $path) or die $!;
        $rc = H('context', 'x');
        close STDOUT;
    }
    is($rc, 0, 'A20: context(...) returns 0');
    my $out = read_bytes($path) // '';
    my $decoded = eval { JSON::PP->new->decode($out) };
    if (ref($decoded) eq 'HASH' && ref($decoded->{hookSpecificOutput}) eq 'HASH') {
        is($decoded->{hookSpecificOutput}{additionalContext}, 'x', 'A20: context JSON carries the text');
        is($decoded->{hookSpecificOutput}{hookEventName}, 'PostToolUse',
           'A20: default hookEventName is PostToolUse when no payload was loaded');
    } else {
        fail('A20: (placeholder) context JSON carries the text -- output did not decode as expected') ;
        fail('A20: (placeholder) default hookEventName is PostToolUse') ;
    }
}

# ===========================================================================
# A21 -- data_dir(): CCPRAXIS_DATA_DIR, CLAUDE_PROJECT_DIR, the payload cwd
# ladder with cwd restoration, and the drive-letter fixed point.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $t = tempdir(CLEANUP=>1);
    make_path("$t/.ccpraxis-local-data");
    $ENV{CCPRAXIS_DATA_DIR} = $t;
    is(H('data_dir', {}), $t, 'A21: an absolute CCPRAXIS_DATA_DIR wins');
}
{
    local %ENV = %ENV; scrub_env();
    my $t = tempdir(CLEANUP=>1);
    make_path("$t/.ccpraxis-local-data");
    $ENV{CLAUDE_PROJECT_DIR} = $t;
    is(H('data_dir', {}), "$t/.ccpraxis-local-data", 'A21: CLAUDE_PROJECT_DIR with .ccpraxis-local-data returns it');
}
{
    local %ENV = %ENV; scrub_env();
    my $t = tempdir(CLEANUP=>1); # no .ccpraxis-local-data inside
    my $cwd_before = getcwd();

    # The walk-up BpProjectRoot performs climbs ancestors of $t looking for
    # .ccpraxis-local-data. On this host, a real one lives at
    # C:/Users/<user>/.ccpraxis-local-data (the steward backup root) --
    # legitimate, but it sits ABOVE every tempdir, so the walk-up finds it
    # and the "no .ccpraxis-local-data anywhere above" precondition this
    # assertion needs cannot be met here. Detect that instead of asserting
    # blindly against it.
    my $ancestor_hit;
    {
        my $dir = abs_path($t) // File::Spec->rel2abs($t);
        while (1) {
            if (-d "$dir/.ccpraxis-local-data") { $ancestor_hit = $dir; last }
            my $parent = dirname($dir);
            last if $parent eq $dir; # reached the root
            $dir = $parent;
        }
    }

  SKIP: {
        skip "A21: host has $ancestor_hit; the walk-up cannot be isolated here", 1
            if defined $ancestor_hit;
        my $result = H('data_dir', {cwd=>$t});
        is($result, undef, 'A21: a payload cwd without .ccpraxis-local-data returns undef');
    }
    is(getcwd(), $cwd_before, 'A21: cwd is restored after data_dir()');
}
{
    # RV-M4 (review): the assertion above sits INSIDE the ancestor-hit SKIP
    # on this host (every tempdir here sits under C:/Users/<user>, where a
    # real .ccpraxis-local-data is the steward backup root), so "cwd is
    # restored" degenerates to comparing cwd with itself and the walk-up
    # defect it is meant to catch cannot fire. BP_PROJECT_ROOT (honoured by
    # BpProjectRoot::resolve BEFORE any cwd-based walk-up, see
    # BpProjectRoot.pm) isolates the same code path deterministically on
    # every host: data_dir() still chdir()s into $t and chdir()s back, but
    # resolve() answers from the env var instead of walking real ancestors,
    # so the "no .ccpraxis-local-data anywhere above" precondition is
    # actually met and this runs UNCONDITIONALLY, never inside a SKIP.
    local %ENV = %ENV; scrub_env();
    my $t = tempdir(CLEANUP=>1); # no .ccpraxis-local-data inside
    my $cwd_before = getcwd();
    $ENV{BP_PROJECT_ROOT} = $t;
    my $result = H('data_dir', {cwd=>$t});
    is($result, undef,
        'RV-M4: data_dir(cwd) returns undef when BP_PROJECT_ROOT is isolated to a dir with no .ccpraxis-local-data');
    is(getcwd(), $cwd_before, 'RV-M4: cwd is restored after data_dir() in the BP_PROJECT_ROOT-isolated case');
}
{
    local %ENV = %ENV; scrub_env();
  SKIP: {
        skip 'A21: drive-letter case is Windows-specific', 1
            unless $^O eq 'MSWin32' || $^O eq 'msys' || $^O eq 'cygwin';
        local $SIG{ALRM} = sub { die "A21 alarm: data_dir(cwd=>'C:/') did not terminate within 20s\n" };
        alarm(20);
        my $ok = eval { H('data_dir', {cwd=>'C:/'}); 1 };
        alarm(0);
        ok($ok, 'A21: data_dir(cwd=>"C:/") terminates under a 20s alarm (drive-letter fixed point)')
            or diag($@);
    }
}

# ===========================================================================
# R7-warn -- main() reads STDIN and calls load_payload() BEFORE it installs
# $SIG{__WARN__} (BpHook.pm:1283-1293: load_payload($raw) at line 1286 runs
# ahead of the "local $SIG{__WARN__} = ..." at line 1293). A malformed
# payload makes load_payload()'s decode fail and warn() (BpHook.pm:1218,
# "BpHook: payload decode failed: ...") fires with no handler installed yet,
# so the message leaks to real STDERR instead of being captured into
# <state>/continuity/hook-errors.log. Every hook wrapper's contract (AC17)
# is that stdout/stderr from a malformed payload are empty; this is the
# in-process seam where that leak actually originates.
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my ($fh, $stdin_path) = tempfile();
    print {$fh} '{not json';
    close $fh;

    my ($errfh, $errpath) = tempfile();
    close $errfh;

    my $before_log = read_bytes("$continuity/hook-errors.log") // '';

    {
        local *STDIN;
        open(STDIN, '<', $stdin_path) or die $!;
        local *STDERR;
        open(STDERR, '>', $errpath) or die $!;
        H('main', 'NoSuchFixtureForR7Warn');
        close STDERR;
        close STDIN;
    }

    my $stderr_out = read_bytes($errpath) // '';
    is($stderr_out, '',
        'R7-warn: main() with a malformed payload writes NOTHING to STDERR');

    my $after_log = read_bytes("$continuity/hook-errors.log") // '';
    cmp_ok(length($after_log), '>', length($before_log),
        'R7-warn: ...and the decode failure is appended to hook-errors.log instead');
    my @new_lines = grep { length } split /\n/, substr($after_log, length($before_log));
    is(scalar(@new_lines), 1,
        'R7-warn: exactly one hook-errors.log line is added for the one decode failure');
    like($new_lines[0] // '', qr/\tNoSuchFixtureForR7Warn\tBpHook: payload decode failed:/,
        'R8-m2: the one logged line is the decode-failure warning itself, not merely any one line '
      . '(review m2: an implementation that dropped the decode warning and logged only a require '
      . 'failure would also produce one line and pass the count-only assertion above)');
}

# ===========================================================================
# R7-timeout -- invocations() wrapped in `timeout` with a short-form flag
# that takes its OWN argument as a separate word (-k SECS, -s SIGNAL) must
# still find the wrapped command. BpHook.pm's timeout-prefix skip
# (_reduce_and_match, around the "if ($lit eq 'timeout')" branch) skips
# every leading '-'-prefixed flag token, then unconditionally treats the
# NEXT word as the timeout duration -- but for `-k 5` or `-s KILL`, that
# next word is the flag's OWN value ("5"/"KILL"), not the duration, so the
# real duration ("60"/"30") is what gets skipped and parsing desyncs onto
# the wrong word, and invocations() finds nothing. `--signal=TERM` (a
# single '='-joined token) and a bare `timeout 10 X` (no flags at all) are
# both unaffected by that desync and must keep working exactly as today.
# ===========================================================================
{
    my @timeout_cases = (
        ['timeout -k 5 60 X', 'X', 1, [],
         '-k with a separate SECS argument (the repro)'],
        ['timeout -s KILL 30 X', 'X', 1, [],
         '-s with a separate SIGNAL argument'],
        ['timeout --signal=TERM 5 X', 'X', 1, [],
         '--signal=TERM as one =-joined token (must keep working)'],
        ['timeout 10 X', 'X', 1, [],
         'a bare duration with no flags (must keep working)'],
        ['timeout --kill-after 5 60 X', 'X', 1, [],
         'R8-m3: --kill-after with a separate-argument long form (review m3, untested branch)'],
        ['timeout -p 60 X', 'X', 1, [],
         'R8-m3: a flag-only short option (-p, preserve-status) before the duration'],
        ['timeout -f 60 X', 'X', 1, [],
         'R8-m3: a flag-only short option (-f, foreground) before the duration'],
        ['timeout -v 60 X', 'X', 1, [],
         'R8-m3: a flag-only short option (-v, verbose) before the duration'],
        ['timeout --preserve-status 60 X', 'X', 1, [],
         'R8-m3: a flag-only long option (--preserve-status) before the duration'],
        ['timeout --foreground 60 X', 'X', 1, [],
         'R8-m3: a flag-only long option (--foreground) before the duration'],
        ['timeout -- 60 X', 'X', 1, [],
         'R8-m3: a bare -- option terminator before the duration'],
    );
    for my $c (@timeout_cases) {
        my ($cmd, $name, $n, $argv, $why) = @$c;
        my @res = HL('invocations', $cmd, $name);
        is(scalar(@res), $n, "R7-timeout: invocations('$cmd', '$name') returns $n match(es) ($why)");
        if ($n && @res) {
            is_deeply($res[0], $argv, "R7-timeout: ...with argv " . (@$argv ? join(',', @$argv) : '[]') . " ($why)");
        }
    }

    # The literal real-world command this package guards against: a
    # bp-drive-next.pl launch wrapped in `timeout -k 5 60`, run through
    # perl. invocations() searches for the script itself ('bp-drive-next');
    # BpHook.pm's own perl/bash/sh interpreter-skip (already covered by A12)
    # steps over the 'perl' word once the timeout desync above is fixed, so
    # the match lands on the script and 'next' survives into argv.
    my $real_cmd = 'timeout -k 5 60 perl /x/bp-drive-next.pl next';
    my @real_res = HL('invocations', $real_cmd, 'bp-drive-next');
    is(scalar(@real_res), 1,
        "R7-timeout: invocations('$real_cmd', 'bp-drive-next') finds the perl /x/bp-drive-next.pl next invocation");
    if (@real_res && ref($real_res[0]) eq 'ARRAY') {
        is($real_res[0][0], 'next',
            "R7-timeout: ...and its argv carries 'next'");
    } else {
        fail("R7-timeout: (placeholder) argv carries 'next' -- no arrayref returned");
    }
}

# ===========================================================================
# R8-B1 -- Decision 55 (review B1, redteam H1): invocations() must find a
# director call whose command word carries an unexpandable prefix (~/...,
# $HOME/..., ${CLAUDE_PLUGIN_ROOT}/..., $VAR/...) by falling back, at the
# command-word position only, to the literal basename after the last
# unquoted / or \. Argv words are unaffected: 'next' must still be literal.
# This is the dominant real-world shape (per the redteam's own transcript
# citation), so a tokenizer that never falls back to the basename leaves
# the arm-on-entry hook inert for almost every real drive-solo call.
# ===========================================================================
{
    my @cases = (
        ['perl ~/.claude/ccpraxis/plugins/butler/scripts/bp-drive-next.pl next', 'bp-drive-next'],
        ['perl "${CLAUDE_PLUGIN_ROOT}/scripts/bp-drive-next.pl" next', 'bp-drive-next'],
        ['perl $HOME/x/bp-drive-next.pl next', 'bp-drive-next'],
        ['perl "$P/bp-drive-next.pl" next', 'bp-drive-next'],
        ['bash ~/.claude/ccpraxis/plugins/butler/bin/bp-drive-next.sh next', 'bp-drive-next'],
    );
    for my $c (@cases) {
        my ($cmd, $name) = @$c;
        my @res = HL('invocations', $cmd, $name);
        is(scalar(@res), 1,
            "R8-B1: invocations('$cmd', '$name') finds the call despite the unexpandable prefix");
        if (@res && ref($res[0]) eq 'ARRAY') {
            is($res[0][0], 'next', "R8-B1: ...and argv[0] is 'next' for [$cmd]");
        } else {
            fail("R8-B1: (placeholder) argv[0] is 'next' -- no match returned for [$cmd]");
        }
    }
}

# ===========================================================================
# R8-M2 -- Decision 55 (redteam M2): an env-assignment prefix whose VALUE
# contains an expansion ($PWD, etc) must not make the prefix-skip loop treat
# the assignment word itself as the (unpredictable) command word -- the
# assignment's raw text still matches NAME=... unquoted, so it stays a
# transparent prefix regardless of how unpredictable its value is.
# ===========================================================================
{
    my $cmd = 'X="$PWD/a" perl /x/bp-drive-next.pl next';
    my @res = HL('invocations', $cmd, 'bp-drive-next');
    is(scalar(@res), 1,
        "R8-M2: invocations() finds the call behind an env-assignment prefix with a \$-bearing value [$cmd]");
    if (@res && ref($res[0]) eq 'ARRAY') {
        is($res[0][0], 'next', 'R8-M2: ...and argv[0] is next');
    } else {
        fail('R8-M2: (placeholder) argv[0] is next -- no match returned');
    }
}

# ===========================================================================
# R8-RTM1 -- Decision 55 (review M1): a heredoc body must never be parsed as
# a live invocation regardless of the exact delimiter spelling (a space
# before a quoted word, an unquoted bare word, or the <<- dash form), and a
# '#' comment must never be parsed as live even when its text holds
# backticks or $( ) that would otherwise look executable.
# ===========================================================================
{
    my @cases = (
        ["cat > f << 'EOF'\nperl /x/bp-drive-next.pl next\nEOF\n",
         q{<< 'EOF' with a space before the quoted delimiter}],
        ["cat > f << EOF\nperl /x/bp-drive-next.pl next\nEOF\n",
         '<< EOF with a space before an unquoted delimiter'],
        ["cat > f <<-EOF\nperl /x/bp-drive-next.pl next\nEOF\n",
         '<<-EOF (the dash/tab-strip form)'],
        ['ls  # perl /x/bp-drive-next.pl next; echo', 'a # comment holding a live-looking ; tail'],
        ['ls  # `perl /x/bp-drive-next.pl next`', 'a # comment holding backticks'],
        ['ls  # $(perl /x/bp-drive-next.pl next)', 'a # comment holding $( )'],
    );
    for my $c (@cases) {
        my ($cmd, $why) = @$c;
        my @res = HL('invocations', $cmd, 'bp-drive-next');
        (my $label = $cmd) =~ s/\n/\\n/g;
        is(scalar(@res), 0, "R8-RTM1: invocations() on [$label] finds nothing ($why)");
    }
}

# ===========================================================================
# R8-RVM1 -- review M1: BpHook::main must log a missing/require-failing
# module to hook-errors.log even when the payload decodes to something
# other than a hash (a JSON array, JSON null, or a BP_PAYLOAD_TRUNCATED=1
# truncation of an otherwise well-formed payload) -- payload_ok() is false
# in every one of those cases too, but load_payload() never fires a decode
# warning for any of them, so BpHook.pm:1317's "log the require failure only
# if payload_ok()" guard leaves the require failure unlogged EVERYWHERE.
# And when the payload IS malformed AND the module IS present and loadable,
# main() must still log EXACTLY ONE line (R7-warn's existing rule, pinned
# here again with a real, loadable module so this sub-case cannot be
# satisfied by an implementation that merely stops logging the require
# failure at all).
# ===========================================================================
{
    my $inc_dir = tempdir(CLEANUP=>1);
    make_path("$inc_dir/BpHook");
    open my $fh, '>', "$inc_dir/BpHook/R8Ok.pm" or die $!;
    print {$fh} "package BpHook::R8Ok;\nsub run { return 0 }\n1;\n";
    close $fh;
    local @INC = ($inc_dir, @INC);

    local %ENV = %ENV; scrub_env();
    my $root = fresh_state_root();
    $ENV{BUTLER_STATE_DIR} = $root;
    my $continuity = "$root/continuity";

    my $run_main_stdin = sub {
        my ($raw, @args) = @_;
        my ($fh2, $path) = tempfile();
        print {$fh2} $raw if defined $raw;
        close $fh2;
        local *STDIN;
        open(STDIN, '<', $path) or die $!;
        my $ret = H('main', @args);
        close STDIN;
        return $ret;
    };

    for my $case (
        ['[]',   'NoSuchModuleR8A', 'a JSON array payload'],
        ['null', 'NoSuchModuleR8B', 'a JSON null payload'],
    ) {
        my ($raw, $mod, $why) = @$case;
        my $before = read_bytes("$continuity/hook-errors.log") // '';
        $run_main_stdin->($raw, $mod);
        my $after = read_bytes("$continuity/hook-errors.log") // '';
        cmp_ok(length($after), '>', length($before),
            "R8-RVM1: main() logs the missing module '$mod' to hook-errors.log even with $why");
    }

    {
        local $ENV{BP_PAYLOAD_TRUNCATED} = 1;
        my $before = read_bytes("$continuity/hook-errors.log") // '';
        $run_main_stdin->('{"session_id":"R8T"}', 'NoSuchModuleR8C');
        my $after = read_bytes("$continuity/hook-errors.log") // '';
        cmp_ok(length($after), '>', length($before),
            'R8-RVM1: main() logs the missing module even when BP_PAYLOAD_TRUNCATED=1 truncates '
          . 'an otherwise well-formed payload');
    }

    {
        my $before = read_bytes("$continuity/hook-errors.log") // '';
        $run_main_stdin->('{not json', 'R8Ok');
        my $after = read_bytes("$continuity/hook-errors.log") // '';
        my @new_lines = grep { length } split /\n/, substr($after, length($before));
        is(scalar(@new_lines), 1,
            'R8-RVM1: a malformed payload with a present, loadable module logs exactly one '
          . 'hook-errors.log line (R7-warn\'s rule, pinned against a real module)');
    }
}

# ===========================================================================
# R8-L3 -- redteam L3: when no state root can be resolved at all (BUTLER_
# STATE_DIR/HOME/USERPROFILE all unset or unusable), a malformed payload's
# decode failure must still never leak to STDERR -- _append_hook_error()
# returns silently when state_dir() is undef, so the chosen fallback here is
# "silent exit 0, nowhere to log, nothing on stderr" (the other option named
# in the package brief, an explicit STDERR fallback, is NOT chosen: AC17's
# "empty stdout/stderr on fail-open" contract applies with or without a
# resolvable root, so staying silent keeps that contract uniform rather than
# carving out an exception for the no-root case).
# ===========================================================================
{
    local %ENV = %ENV; scrub_env();
    delete $ENV{BUTLER_STATE_DIR}; delete $ENV{HOME}; delete $ENV{USERPROFILE};

    my ($fh, $stdin_path) = tempfile();
    print {$fh} '{not json';
    close $fh;
    my ($errfh, $errpath) = tempfile();
    close $errfh;

    {
        local *STDIN;
        open(STDIN, '<', $stdin_path) or die $!;
        local *STDERR;
        open(STDERR, '>', $errpath) or die $!;
        my $ret = H('main', 'NoSuchFixtureForR8L3');
        close STDERR;
        close STDIN;
        is($ret, 0, 'R8-L3: main() with no resolvable state root and a malformed payload returns 0');
    }
    my $stderr_out = read_bytes($errpath) // '';
    is($stderr_out, '',
        'R8-L3: ...and writes NOTHING to STDERR (chosen fallback: silent, not a STDERR leak)');
}

$? = 0;
done_testing();
