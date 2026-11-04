#!/usr/bin/env perl
# platform: any
# ORACLE for package 06-far-pause-session-handoff (blueprint
# wake-and-pause-consolidation), derived ONLY from
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/
# 06-far-pause-session-handoff-spec.md (AC1-AC16). NOT derived from any
# implementation: at the time this file is written, BpAwakeIntent::arm_intent
# does not exist, BpContinuityLease::touch_busy writes a bare empty file
# (not the lease_line JSON), and BpHook::StopGate has no far_paused_fleets,
# no far-pause branch in G11, and no BpAwakeIntent load. Every direct call to
# one of those not-yet-written subs goes through the AI()/SG() wrappers below,
# which turn "Undefined subroutine" into a plain undef instead of dying --
# the same technique continuity-lease-follows-arm.t's LZ() uses for
# BpContinuityLease's own not-yet-written subs.
#
# Fixtures named by the ledger: run_gate/bash_pair from
# stop-gate-starting-holder.t, continuity-lease-follows-arm.t L1/L7 for the
# posix daemon_loop/sync/converge setup and the off/off-confirm CLI dance,
# disarm-judge-dispatch.t for off/off-confirm's write_ticket binding, and
# stop-gate-single.t's write_holder/cmdline_fp_of for a live-holder fixture.
# No real fleet, orchestrator, claude, podman or launcher: every state root
# is a File::Temp tempdir, HOME/USERPROFILE are decoys, CCPRAXIS_NO_WAKELOCK=1
# is set in a BEGIN block (per the spec's fixture list), and every off-confirm
# call pins CCPRAXIS_DISARM_JUDGE_STUB so this file never spawns a real
# `claude -p`.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use File::Spec ();
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep);

(my $BUTLER = "$Bin/../..") =~ s{\\}{/}g;
my $S        = "$BUTLER/scripts";
my $HOOK     = "$BUTLER/hooks/stop-gate.sh";
my $CONT_CMD = "$S/butler-continuity.pl";
my $AGENT_MD = "$BUTLER/agents/bp-disarm-judge.md";
my $SG_PM    = "$S/BpHook/StopGate.pm";
my $CL_PM    = "$S/BpContinuityLease.pm";

require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";
require "$S/BpAwakeIntent.pm";
require "$S/BpHook/StopGate.pm";
require "$S/BpAwakeConst.pm";

my $HORIZON = BpAwakeConst::FLEET_PAUSE_HORIZON();

# ---------------------------------------------------------------------------
# process bookkeeping (house pattern, same as stop-gate-starting-holder.t /
# stop-gate-single.t).
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

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
my $TMP = tempdir(CLEANUP => 1); $TMP =~ s{\\}{/}g;
my $HOME = "$TMP/decoy-home";
my $PROJECT = "$TMP/project";
make_path($HOME, $PROJECT);
$ENV{HOME} = $ENV{USERPROFILE} = $HOME;
delete $ENV{BUTLER_STATE_DIR};

my $BASH = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve bash') unless length $BASH;

my $J = JSON::PP->new->utf8->canonical;

sub iso { my @t = gmtime($_[0]); sprintf('%04d-%02d-%02dT%02d:%02d:%02d.123Z', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]) }
sub ts  { my @t = gmtime($_[0]); sprintf('%04d-%02d-%02d %02d:%02d UTC', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]) }

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

# --- LZ/AI/SG: call a not-yet-written sub without dying this file --------
sub _soft_call {
    my ($pkg, $name, @args) = @_;
    my $code; { no strict 'refs'; $code = \&{"${pkg}::${name}"} }
    my $ret;
    my $ok = eval { $ret = $code->(@args); 1 };
    return $ok ? $ret : undef;
}
sub AI { return _soft_call('BpAwakeIntent', @_) }
sub SG { return _soft_call('BpHook::StopGate', @_) }

# --- transcript fixture: a Bash call and its result, Claude-Code shaped --
sub bash_pair {
    my (%a) = @_;
    my $use = { type => 'assistant', timestamp => iso($a{at}), message => { role => 'assistant', content => [
        { type => 'tool_use', id => $a{tuid}, name => 'Bash',
          input => { command => $a{cmd}, ($a{bg} ? (run_in_background => JSON::PP::true()) : ()) } } ] } };
    my $text = $a{bg} ? "Command running in background with ID: $a{task}. Output is being written to: x/$a{task}.output"
                      : 'held';
    my $res = { type => 'user', timestamp => iso($a{at}), message => { role => 'user', content => [
        { type => 'tool_result', tool_use_id => $a{tuid},
          content => ($a{array} ? [ { type => 'text', text => $text } ] : $text) } ] },
        ($a{bg} && !$a{no_tur} ? (toolUseResult => { backgroundTaskId => $a{task}, stdout => '', stderr => '' }) : ()) };
    return $J->encode($use) . "\n" . $J->encode($res) . "\n";
}

my $TRN = 0;
sub write_transcript {
    my (@launches) = @_;
    my $tp = "$PROJECT/trn" . (++$TRN) . ".jsonl";
    open my $fh, '>:raw', $tp or die $!;
    print $fh $J->encode({ type => 'user', message => { role => 'user', content => 'go' } }), "\n";
    for my $l (@launches) {
        print $fh bash_pair(tuid => $l->{tuid}, at => $l->{at} // (time() - 30),
            bg => (exists $l->{bg} ? $l->{bg} : 1), task => $l->{task}, cmd => $l->{cmd},
            no_tur => $l->{no_tur}, array => $l->{array});
    }
    close $fh;
    return $tp;
}

sub bgt { my ($id, $type, $st) = @_; { id => $id, type => $type, status => $st // 'running', description => "t $id" } }

sub write_paused {
    my ($runs_dir, $doc) = @_;
    make_path($runs_dir);
    if (ref $doc eq 'HASH') {
        open my $fh, '>:raw', "$runs_dir/.paused" or die $!;
        print {$fh} $J->encode($doc);
        close $fh;
    } elsif (defined $doc) {
        open my $fh, '>:raw', "$runs_dir/.paused" or die $!;
        print {$fh} $doc;
        close $fh;
    }
    return "$runs_dir/.paused";
}

# --- Addendum A fixtures: a "this project" watcher under DD/blueprints/<bp>,
# the offer record it leaves, and a child-perl runner for AC25's broken-
# BpAwakeIntent probe. Never touches the real state dir or a real judge.
# ---------------------------------------------------------------------------
sub utc_z { my @t = gmtime($_[0]); sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0]) }

# far_project_fixture(%o) -- builds a watcher whose runs dir resolves (per
# A.2.2) to DD/blueprints/<bp>/runs, with DD a fresh temp dir unless given.
# Returns ($dd, $bp, $bpdir, $relaunch, $transcript_path).
sub far_project_fixture {
    my (%o) = @_;
    my $dd = $o{dd};
    unless (defined $dd) { $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g; }
    my $bp = $o{bp} // 'farpause-bp';
    my $relaunch = $o{relaunch} // (time() + $HORIZON + 7200);
    my $bpdir = "$dd/blueprints/$bp";
    write_paused("$bpdir/runs", { reason => 'usage', relaunch_at => $relaunch });
    my $tp = write_transcript({ tuid => $o{tuid} // 'tu1', task => $o{task} // 'W1',
        cmd => "perl /x/bp-wait-for-escalation.pl $bp --bp-dir '$bpdir' --timeout 1800" });
    return ($dd, $bp, $bpdir, $relaunch, $tp);
}

sub far_pause_dir { my ($dd) = @_; return "$dd/butler-far-pause" }

sub far_pause_json_files {
    my ($dd) = @_;
    my $dir = far_pause_dir($dd);
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\A[0-9a-f]{8}\.json\z/ } readdir($dh);
    closedir $dh;
    return @f;
}

sub far_pause_tmp_files {
    my ($dd) = @_;
    my $dir = far_pause_dir($dd);
    return () unless -d $dir;
    opendir(my $dh, $dir) or return ();
    my @f = grep { /\.tmp\./ } readdir($dh);
    closedir $dh;
    return @f;
}

sub far_pause_record {
    my ($dd, $name) = @_;
    return eval { $J->decode(slurp(far_pause_dir($dd) . "/$name")) };
}

sub write_far_pause_record {
    my ($dd, $id, $doc) = @_;
    make_path(far_pause_dir($dd));
    open my $fh, '>:raw', far_pause_dir($dd) . "/$id.json" or die $!;
    print {$fh} $J->encode($doc);
    close $fh;
}

# run_perl_script($code, \@argv) -- runs a short perl program (house pattern,
# same bounded fork/exec/timeout shape as run_gate) and returns
# (stdout, stderr, exit_code). Used only for AC25's "load this module from a
# scratch copy next to a broken BpAwakeIntent.pm" probe -- never spawns the
# real butler-continuity.pl/claude/orchestrator.
sub run_perl_script {
    my ($code, $argv) = @_;
    my (undef, $prog) = tempfile(DIR => $TMP, SUFFIX => '.pl');
    open my $fh, '>', $prog or die $!;
    print {$fh} $code;
    close $fh;
    my (undef, $op) = tempfile(DIR => $TMP);
    my (undef, $ep) = tempfile(DIR => $TMP);
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {
        open(STDOUT, '>', $op) or _exit(126);
        open(STDERR, '>', $ep) or _exit(126);
        { no warnings 'exec'; exec($^X, $prog, @{ $argv || [] }) }
        _exit(127);
    }
    push @KILL_PIDS, $pid;
    my ($rc, $deadline) = (undef, time() + 15);
    while (time() < $deadline) {
        if (waitpid($pid, WNOHANG) == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    return (slurp($op), slurp($ep), $rc);
}

my $sidn = 0;
sub new_session {
    my (%o) = @_;
    my $root = tempdir(DIR => $TMP, CLEANUP => 1); $root =~ s{\\}{/}g;
    my $sid = sprintf('fph-%04x-%08x', ++$sidn, int(rand(0xffffffff)));
    local $ENV{BUTLER_STATE_DIR} = $root;
    BpHook::arm($sid, role => $o{role} // 'reporter', by => 'on') or die "arm failed";
    return ($root, $sid);
}

sub payload_for {
    my ($sid, $tp, $bg, %o) = @_;
    return { session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false(),
             transcript_path => $tp, cwd => $o{cwd} // $PROJECT, background_tasks => $bg };
}

sub run_gate {
    my ($root, $payload) = @_;
    my ($pfh, $pp) = tempfile(DIR => $TMP); print $pfh $J->encode($payload); close $pfh;
    my (undef, $op) = tempfile(DIR => $TMP);
    my (undef, $ep) = tempfile(DIR => $TMP);
    my $pid = fork() // die "fork: $!";
    if ($pid == 0) {
        $ENV{BUTLER_STATE_DIR} = $root;
        open(STDIN, '<', $pp) or _exit(126);
        open(STDOUT, '>', $op) or _exit(126);
        open(STDERR, '>', $ep) or _exit(126);
        { no warnings 'exec'; exec($BASH, $HOOK) }
        _exit(127);
    }
    push @KILL_PIDS, $pid;
    my ($rc, $deadline) = (undef, time() + 20);
    while (time() < $deadline) {
        if (waitpid($pid, WNOHANG) == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $err = slurp($ep);
    return ($rc, $err);
}

# --- live-holder fixture (stop-gate-single.t's write_holder/cmdline_fp_of) -
my $HAVE_PROC_CMDLINE = -r '/proc/self/cmdline' ? 1 : 0;
sub cmdline_fp_of {
    my ($pid) = @_;
    return sha1_hex('') unless $HAVE_PROC_CMDLINE;
    open(my $fh, '<:raw', "/proc/$pid/cmdline") or return sha1_hex('');
    local $/;
    my $c = <$fh>;
    close $fh;
    return sha1_hex(defined $c ? $c : '');
}
my $SLEEPER_SEQ = 0;
sub spawn_sleeper {
    # a unique per-invocation marker, so a cmdline fingerprint taken before
    # exec() lands never fingerprints the parent instead of the child (same
    # race stop-gate-single.t's spawn_sleeper guards against).
    my $tag = sprintf('%d-%d-%d', $$, ++$SLEEPER_SEQ, int(rand(1_000_000)));
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', File::Spec->devnull);
        open(STDOUT, '>', File::Spec->devnull);
        open(STDERR, '>', File::Spec->devnull);
        exec($^X, '-e', "select(undef,undef,undef,120) # sleeper-tag:$tag") or _exit(127);
    }
    push @KILL_PIDS, $pid;
    if ($HAVE_PROC_CMDLINE) {
        my $deadline = time() + 5;
        while (time() < $deadline) {
            my $c = '';
            if (open(my $fh, '<:raw', "/proc/$pid/cmdline")) {
                local $/;
                $c = <$fh>;
                close $fh;
            }
            last if defined $c && index($c, "sleeper-tag:$tag") >= 0;
            sleep(0.02);
        }
    }
    return $pid;
}
sub write_holder {
    my ($root, $sid, %o) = @_;
    my $dir = "$root/continuity/holder";
    make_path($dir);
    my $rec = {
        session_id => $sid, token => $o{token} // 'deadbeef', pid => $o{pid}, fp => $o{fp},
        items => $o{items} // [], started_at => $o{started_at} // int(time() - 10),
    };
    $rec->{deadline} = $o{deadline} if exists $o{deadline};
    open my $fh, '>:raw', "$dir/$sid.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec);
    close $fh;
}

# ===========================================================================
# AC10 (DC3, B1): BpAwakeIntent::arm_intent() is pure.
# ===========================================================================
{
    my $a = AI('arm_intent');
    is_deeply($a, { awake => 1, reason => 'armed', until => undef, handoff => 0 },
        'AC10: arm_intent() shape')
        or diag(explain($a));
    my $b = AI('arm_intent');
    ok(defined $a && defined $b && $a != $b, 'AC10: two calls return distinct hashrefs')
        if defined $a && defined $b;
    if (defined $a) {
        $a->{reason} = 'mutated';
        my $c = AI('arm_intent');
        is($c->{reason}, 'armed', 'AC10: mutating one returned hashref never changes the next call')
            if defined $c;
    }
}

# ===========================================================================
# AC11 (DC3, B2/B3): the container refresher writes the lease_line JSON,
# atomically, through daemon_loop/sync/converge -- all on the posix branch.
# Fails on today's code (touch_busy writes an empty file).
# ===========================================================================
sub decode_lease_line {
    my ($path) = @_;
    my $raw = slurp($path);
    return undef unless length $raw;
    my @lines = split /\n/, $raw;
    return undef unless @lines == 1;
    return eval { JSON::PP->new->decode($lines[0]) };
}

{
    local $BpContinuityLease::PLATFORM = 'posix';

    # -- daemon_loop, one tick, arm live -----------------------------------
    {
        my $home = tempdir(DIR => $TMP, CLEANUP => 1); $home =~ s{\\}{/}g;
        my $legacy = tempdir(DIR => $TMP, CLEANUP => 1); $legacy =~ s{\\}{/}g;
        make_path("$legacy/pending");
        local $ENV{BUTLER_STATE_DIR} = $home;
        local $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
        my $sid = 'ac11-daemon';
        ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC11 setup: armed for daemon_loop tick');
        my $lease = "$TMP/ac11-daemon-lease";
        my $before = time();
        BpContinuityLease::daemon_loop($legacy,
            tick => 1, max_iterations => 1, journal => 0,
            sleep => sub {}, log => sub {}, handover_spawn => sub { undef },
            busy_path => $lease);
        my $after = time();
        my $doc = decode_lease_line($lease);
        ok(defined $doc, 'AC11 daemon_loop: lease decodes to exactly one JSON line') or diag(slurp($lease));
        SKIP: {
            skip 'AC11 daemon_loop: no decodable line to inspect', 5 unless defined $doc;
            is($doc->{v}, 1, 'AC11 daemon_loop: v is 1');
            is($doc->{awake}, 1, 'AC11 daemon_loop: awake is 1');
            is($doc->{reason}, 'armed', 'AC11 daemon_loop: reason is armed');
            is($doc->{until}, undef, 'AC11 daemon_loop: until is null');
            ok($doc->{written_at} >= $before - 1 && $doc->{written_at} <= $after + 5,
                'AC11 daemon_loop: written_at is within 5s of now');
            my $mt = (stat($lease))[9];
            ok(defined $mt && abs($mt - $doc->{written_at}) <= 1,
                'AC11 daemon_loop: mtime == written_at (within 1s)');
        }
    }

    # -- sync($dir, active => 1, busy_path => ...) directly ------------------
    {
        my $lease = "$TMP/ac11-sync-lease";
        BpContinuityLease::sync('/irrelevant/dir', active => 1, busy_path => $lease);
        my $doc = decode_lease_line($lease);
        ok(defined $doc, 'AC11 sync: lease decodes to exactly one JSON line') or diag(slurp($lease));
        is($doc->{awake}, 1, 'AC11 sync: awake is 1') if defined $doc;
        is($doc->{reason}, 'armed', 'AC11 sync: reason is armed') if defined $doc;
    }

    # -- converge($dir, busy_path => ...) with an arm live (refresh path) ---
    {
        my $home = tempdir(DIR => $TMP, CLEANUP => 1); $home =~ s{\\}{/}g;
        my $legacy = tempdir(DIR => $TMP, CLEANUP => 1); $legacy =~ s{\\}{/}g;
        make_path("$legacy/pending");
        local $ENV{BUTLER_STATE_DIR} = $home;
        local $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
        my $sid = 'ac11-converge';
        ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC11 setup: armed for converge');
        my $lease = "$TMP/ac11-converge-lease";
        BpContinuityLease::converge($legacy, busy_path => $lease,
            spawn => sub { 9999 }, powershell_available => sub { 1 });
        my $doc = decode_lease_line($lease);
        ok(defined $doc, 'AC11 converge: lease decodes to exactly one JSON line') or diag(slurp($lease));
        is($doc->{awake}, 1, 'AC11 converge: awake is 1') if defined $doc;
        is($doc->{reason}, 'armed', 'AC11 converge: reason is armed') if defined $doc;
    }
}

# ===========================================================================
# AC12 (DC3, B4): after disarm, a further daemon_loop logs IDLE/returns done;
# the lease's mtime and bytes are unchanged.
# ===========================================================================
{
    local $BpContinuityLease::PLATFORM = 'posix';
    my $home = tempdir(DIR => $TMP, CLEANUP => 1); $home =~ s{\\}{/}g;
    my $legacy = tempdir(DIR => $TMP, CLEANUP => 1); $legacy =~ s{\\}{/}g;
    make_path("$legacy/pending");
    local $ENV{BUTLER_STATE_DIR} = $home;
    local $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
    my $sid = 'ac12-disarmed';
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC12 setup: armed');
    BpHook::disarm($sid, actor => 'agent', reason => 'a b');

    my $lease = "$TMP/ac12-lease";
    open my $fh, '>:raw', $lease or die $!;
    print {$fh} "PRIOR-CONTENT\n";
    close $fh;
    my $old = time() - 1000;
    utime($old, $old, $lease);

    my $rv = BpContinuityLease::daemon_loop($legacy,
        tick => 1, max_iterations => 1, journal => 0,
        sleep => sub {}, log => sub {}, handover_spawn => sub { undef },
        busy_path => $lease);
    is($rv, 'done', 'AC12: daemon_loop returns done once nothing is armed');
    is(slurp($lease), "PRIOR-CONTENT\n", 'AC12: the lease bytes are unchanged');
    my $mt = (stat($lease))[9];
    is($mt, $old, 'AC12: the lease mtime is unchanged');
}

# ===========================================================================
# AC13 (DC3, B5): touch_busy fallback when the temp write cannot happen.
# ===========================================================================
{
    # lease present
    {
        my $lease = "$TMP/ac13-present-lease";
        open my $fh, '>:raw', $lease or die $!;
        print {$fh} "EXISTING\n";
        close $fh;
        my $old = time() - 500;
        utime($old, $old, $lease);
        my $block = "$lease.tmp.$$";
        make_path($block);

        my $rv = BpContinuityLease::touch_busy($lease);
        is($rv, 1, 'AC13 (present): touch_busy still returns 1');
        is(slurp($lease), "EXISTING\n", 'AC13 (present): content is untouched');
        my $mt = (stat($lease))[9];
        ok(defined $mt && abs($mt - time()) <= 5, 'AC13 (present): mtime is fresh');
        ok(-d $block, 'AC13 (present): the blocking directory is left in place');
    }
    # lease absent
    {
        my $lease = "$TMP/ac13-absent-lease";
        my $block = "$lease.tmp.$$";
        make_path($block);

        my $rv = BpContinuityLease::touch_busy($lease);
        is($rv, 1, 'AC13 (absent): touch_busy returns 1');
        ok(-f $lease, 'AC13 (absent): the lease was created');
        is(slurp($lease), '', 'AC13 (absent): it is EMPTY');
        my $mt = (stat($lease))[9];
        ok(defined $mt && abs($mt - time()) <= 5, 'AC13 (absent): mtime is fresh');
        ok(-d $block, 'AC13 (absent): the blocking directory is left in place');
    }
}

# ===========================================================================
# AC14 (DC3, B6): structural guards on BpContinuityLease.pm.
# ===========================================================================
{
    my $src = slurp($CL_PM);
    ok(length($src), 'AC14 setup: BpContinuityLease.pm is readable');

    my ($body) = $src =~ /\n(sub touch_busy\s*\{.*?\n\})\n/s;
    ok(defined $body, 'AC14 setup: touch_busy body is isolated for inspection') or diag('regex did not match');
    SKIP: {
        skip 'AC14: touch_busy body not found', 2 unless defined $body;
        like($body, qr/BpAwakeIntent::lease_line\(/, 'AC14: touch_busy calls BpAwakeIntent::lease_line(');
        like($body, qr/BpAwakeIntent::arm_intent\(/, 'AC14: touch_busy calls BpAwakeIntent::arm_intent(');
    }

    unlike($src, qr/awake\s*=>\s*0/, 'AC14: no "awake => 0" literal anywhere in the file');
    unlike($src, qr/"awake"\s*:\s*0/, 'AC14: no \'"awake":0\' literal anywhere in the file');

    my ($comment) = $src =~ /((?:^#.*\n)+)sub touch_busy\s*\{/m;
    ok(defined $comment, 'AC14 setup: a comment block precedes touch_busy') or diag('no comment block found');
    unlike($comment // '', qr/Identical semantics/,
        'AC14: the comment above touch_busy no longer claims "Identical semantics"');
}

# ===========================================================================
# AC9 (DC1): structural guards on StopGate.pm.
# ===========================================================================
{
    my $src = slurp($SG_PM);
    ok(length($src), 'AC9 setup: StopGate.pm is readable');
    like($src, qr/BpAwakeIntent::want_awake\(/, 'AC9: StopGate.pm calls BpAwakeIntent::want_awake(');
    unlike($src, qr/\b115200\b/, 'AC9: StopGate.pm never hard-codes 115200');
    unlike($src, qr/\bSOLO_PAUSE_HORIZON\b/, 'AC9: StopGate.pm never mentions SOLO_PAUSE_HORIZON');
    my $stripped = $src;
    $stripped =~ s/^\s*#.*$//mg;
    # every FLEET_PAUSE_HORIZON occurrence outside a comment must be in the
    # exact call form "BpAwakeConst::FLEET_PAUSE_HORIZON()" -- find every
    # occurrence and check the form around it.
    my @occurrences;
    while ($stripped =~ /FLEET_PAUSE_HORIZON/g) { push @occurrences, pos($stripped) }
    my $all_proper = 1;
    for my $p (@occurrences) {
        # $p is the position just AFTER the matched "FLEET_PAUSE_HORIZON" (pos()
        # after a //g match). The match itself starts at $p - length(name), and
        # the required preceding phrase "horizon => BpAwakeConst::" sits before
        # that -- so the window must start well before the match, not after it.
        my $name_len = length('FLEET_PAUSE_HORIZON');
        my $start = ($p - $name_len - 40) > 0 ? ($p - $name_len - 40) : 0;
        my $window = substr($stripped, $start, ($p - $start) + 5);
        $all_proper = 0 unless $window =~ /horizon\s*=>\s*BpAwakeConst::FLEET_PAUSE_HORIZON\(\)/;
    }
    ok(!@occurrences || $all_proper,
        'AC9: every non-comment FLEET_PAUSE_HORIZON occurrence is "horizon => BpAwakeConst::FLEET_PAUSE_HORIZON()"')
        or diag("occurrences: " . scalar(@occurrences));
}

# ===========================================================================
# AC5 (DC2, B9): far_paused_fleets boundary -- H -> undef, H+1 -> one entry.
# ===========================================================================
{
    my $now = time();
    for my $case ([$HORIZON, undef, 'at the horizon: undef'],
                  [$HORIZON + 1, 1, 'one second beyond: one entry']) {
        my ($delta, $expect_entries, $label) = @$case;
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        my $bpdir = "$dd/blueprints/ac5bp";
        my $runs = "$bpdir/runs";
        my $relaunch = $now + $delta;
        write_paused($runs, { reason => 'usage', relaunch_at => $relaunch });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac5bp --bp-dir '$bpdir' --timeout 1800" });
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my $p = { transcript_path => $tp, cwd => $PROJECT };
        my $far = SG('far_paused_fleets', $p, [ { id => 'W1' } ], $now);
        if ($expect_entries) {
            is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, "AC5: $label (count)")
                or diag(defined $far ? explain($far) : 'undef');
            if (ref $far eq 'ARRAY' && @$far) {
                is($far->[0]{name}, 'ac5bp', "AC5: $label (name)");
                is($far->[0]{runs}, $runs, "AC5: $label (runs)");
                is($far->[0]{relaunch_at}, $relaunch, "AC5: $label (relaunch_at)");
            }
        } else {
            is($far, undef, "AC5: $label");
        }
    }
}

# ===========================================================================
# AC6 (DC1/DC2, B10): every fallback case answers undef in-process, plus one
# (a non-watcher second task) through the real gate, showing the RUNNING
# text.
# ===========================================================================
{
    my $now = time();
    my $far_relaunch = $now + $HORIZON + 7200;

    # (1) a second running task that is not a watcher
    {
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        write_paused("$bpdir/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac6a --bp-dir '$bpdir' --timeout 1800" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT },
            [ { id => 'W1' }, { id => 'W2' } ], $now);
        is($far, undef, 'AC6 (1): a second running task that is not a watcher -> undef');
    }
    # (2) .paused absent
    {
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        make_path("$bpdir/runs");
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac6b --bp-dir '$bpdir' --timeout 1800" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is($far, undef, 'AC6 (2): .paused absent -> undef');
    }
    # (3) .paused not JSON
    {
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        write_paused("$bpdir/runs", 'not json {{{');
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac6c --bp-dir '$bpdir' --timeout 1800" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is($far, undef, 'AC6 (3): .paused not JSON -> undef');
    }
    # (4) .paused not a HASH
    {
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        write_paused("$bpdir/runs", '[]');
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac6d --bp-dir '$bpdir' --timeout 1800" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is($far, undef, 'AC6 (4): .paused is a JSON array, not a HASH -> undef');
    }
    # (5) manual true
    {
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        write_paused("$bpdir/runs", { manual => JSON::PP::true(), relaunch_at => $far_relaunch });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac6e --bp-dir '$bpdir' --timeout 1800" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is($far, undef, 'AC6 (5): manual pause, however far -> undef');
    }
    # (6) relaunch_at absent/unparseable
    {
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        write_paused("$bpdir/runs", { reason => 'usage' });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac6f --bp-dir '$bpdir' --timeout 1800" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is($far, undef, 'AC6 (6): relaunch_at absent -> undef');
    }
    # (7) watcher launch foreground
    {
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        write_paused("$bpdir/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1', bg => 0,
            cmd => "perl /x/bp-wait-for-escalation.pl ac6g --bp-dir '$bpdir' --timeout 1800" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is($far, undef, 'AC6 (7): a foreground launch is not a watcher -> undef');
    }
    # (8) watcher launch chained
    {
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        write_paused("$bpdir/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac6h --bp-dir '$bpdir' --timeout 1800 && sleep 1" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is($far, undef, 'AC6 (8): a chained launch is not a watcher -> undef');
    }
    # (9) --bp-dir an unpredictable word
    {
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => 'perl /x/bp-wait-for-escalation.pl ac6i --bp-dir "$BPDIR" --timeout 1800' });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is($far, undef, 'AC6 (9): --bp-dir "$BPDIR" (unpredictable) -> undef');
    }
    # (10) blueprint name fails the name pattern
    {
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        write_paused("$bpdir/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl _badname --bp-dir '$bpdir' --timeout 1800" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is($far, undef, 'AC6 (10): a name failing the name pattern -> undef');
    }
    # (11) two watchers on two fleets, one within the horizon
    {
        my $bpdirA = tempdir(DIR => $TMP, CLEANUP => 1); $bpdirA =~ s{\\}{/}g;
        my $bpdirB = tempdir(DIR => $TMP, CLEANUP => 1); $bpdirB =~ s{\\}{/}g;
        write_paused("$bpdirA/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        write_paused("$bpdirB/runs", { reason => 'usage', relaunch_at => $now + $HORIZON - 3600 });
        my $tp = write_transcript(
            { tuid => 'tu1', task => 'W1', cmd => "perl /x/bp-wait-for-escalation.pl ac6ja --bp-dir '$bpdirA' --timeout 1800" },
            { tuid => 'tu2', task => 'W2', cmd => "perl /x/bp-wait-for-escalation.pl ac6jb --bp-dir '$bpdirB' --timeout 1800" },
        );
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT },
            [ { id => 'W1' }, { id => 'W2' } ], $now);
        is($far, undef, 'AC6 (11): one of two watched fleets is within the horizon -> undef');
    }

    # -- through the real gate: a non-watcher second task shows the RUNNING text
    {
        my ($root, $sid) = new_session();
        my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
        write_paused("$bpdir/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac6k --bp-dir '$bpdir' --timeout 1800" });
        my @bg = (bgt('W1', 'shell'), bgt('W2', 'shell'));
        my ($rc, $err) = run_gate($root, payload_for($sid, $tp, \@bg));
        is($rc, 2, 'AC6 real gate: still denies (RUNNING text, not far-pause)');
        like($err, qr/still running:.*\bW1\b.*\bW2\b|still running:.*\bW2\b.*\bW1\b/,
            'AC6 real gate: the RUNNING text names both work items') or diag($err);
        unlike($err, qr/^Handoff:/m, 'AC6 real gate: no Handoff line');
    }
}

# ===========================================================================
# AC7 (amended, DC1, item 3): B11/B12 rewritten under A.2.2 -- every fixture's
# runs dir now resolves to DD/blueprints/<name>/runs (the this-project check),
# since A.2.2 condition 3 rejects any watcher whose runs dir resolves
# elsewhere. B11's two-fleet reason is additionally checked through
# far_pause_reason (', '-separated, relaunch_at order).
# ===========================================================================
{
    my $now = time();
    my $far_relaunch_1 = $now + $HORIZON + 100;
    my $far_relaunch_2 = $now + $HORIZON + 7200;

    # B11: two fleets beyond the horizon, sorted by relaunch_at ascending,
    # both resolved under one project's DD/blueprints/<name>/runs.
    my ($dd11) = far_project_fixture(bp => '__unused11');    # just to mint a DD
    {
        write_paused("$dd11/blueprints/ac7a/runs", { reason => 'usage', relaunch_at => $far_relaunch_2 });
        write_paused("$dd11/blueprints/ac7b/runs", { reason => 'usage', relaunch_at => $far_relaunch_1 });
        my $tp = write_transcript(
            { tuid => 'tu1', task => 'W1', cmd => "perl /x/bp-wait-for-escalation.pl ac7a --bp-dir '$dd11/blueprints/ac7a' --timeout 1800" },
            { tuid => 'tu2', task => 'W2', cmd => "perl /x/bp-wait-for-escalation.pl ac7b --bp-dir '$dd11/blueprints/ac7b' --timeout 1800" },
        );
        local $ENV{CCPRAXIS_DATA_DIR} = $dd11;
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT },
            [ { id => 'W1' }, { id => 'W2' } ], $now);
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 2, 'AC7 B11: two entries') or diag(explain($far));
        if (ref $far eq 'ARRAY' && @$far == 2) {
            is($far->[0]{name}, 'ac7b', 'AC7 B11: the sooner relaunch_at (ac7b) sorts first');
            is($far->[1]{name}, 'ac7a', 'AC7 B11: ac7a sorts second');

            my $t = 'deadbeef';
            my $reason = SG('far_pause_reason', $t, $far);
            is($reason, "far pause, offer $t: ac7b\@$far_relaunch_1, ac7a\@$far_relaunch_2",
                'AC7 B11: far_pause_reason joins both fleets, relaunch_at order, \', \'-separated')
                or diag(defined $reason ? $reason : 'undef');
        }
    }
    # B11: two watchers on the SAME runs dir yield one entry.
    {
        my ($dd) = far_project_fixture(bp => '__unused11b');
        write_paused("$dd/blueprints/ac7c/runs", { reason => 'usage', relaunch_at => $far_relaunch_1 });
        my $tp = write_transcript(
            { tuid => 'tu1', task => 'W1', cmd => "perl /x/bp-wait-for-escalation.pl ac7c --bp-dir '$dd/blueprints/ac7c' --timeout 1800" },
            { tuid => 'tu2', task => 'W2', cmd => "perl /x/bp-wait-for-escalation.pl ac7c --bp-dir '$dd/blueprints/ac7c' --timeout 1800" },
        );
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT },
            [ { id => 'W1' }, { id => 'W2' } ], $now);
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, 'AC7 B11: two watchers on one runs dir -> one entry')
            or diag(explain($far));
    }

    # B12: --runs D uses D/.paused directly -- D must itself be
    # DD/blueprints/<name>/runs (A.2.2 condition 3), unlike the pre-addendum
    # "any D" case (now covered separately, as an undef case, by AC22).
    {
        my ($dd) = far_project_fixture(bp => '__unused12');
        my $runsD = "$dd/blueprints/ac7d/runs";
        write_paused($runsD, { reason => 'usage', relaunch_at => $far_relaunch_1 });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac7d --runs '$runsD' --timeout 1800" });
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, 'AC7 B12 (--runs): one entry') or diag(explain($far));
        is($far->[0]{runs}, $runsD, 'AC7 B12 (--runs): runs dir is D itself') if ref $far eq 'ARRAY' && @$far;
    }

    # B12: positional blueprint, no --bp-dir, CCPRAXIS_DATA_DIR resolution.
    {
        my $datadir = tempdir(DIR => $TMP, CLEANUP => 1); $datadir =~ s{\\}{/}g;
        local $ENV{CCPRAXIS_DATA_DIR} = $datadir;
        my $runs = "$datadir/blueprints/ac7ebp/runs";
        write_paused($runs, { reason => 'usage', relaunch_at => $far_relaunch_1 });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac7ebp --timeout 1800" });
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1,
            'AC7 B12 (positional + CCPRAXIS_DATA_DIR): one entry') or diag(explain($far));
        is($far->[0]{runs}, $runs, 'AC7 B12 (positional + CCPRAXIS_DATA_DIR): runs dir resolved under data_dir')
            if ref $far eq 'ARRAY' && @$far;
    }

    # B12: a relative --bp-dir resolves against the payload cwd, landing on
    # DD/blueprints/<name> (A.2.2 condition 3 requires this, not an arbitrary
    # relative target as the pre-addendum version allowed).
    {
        my ($dd) = far_project_fixture(bp => '__unused12b');
        my $runs = "$dd/blueprints/ac7f/runs";
        write_paused($runs, { reason => 'usage', relaunch_at => $far_relaunch_1 });
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac7f --bp-dir 'blueprints/ac7f' --timeout 1800" });
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my $far = SG('far_paused_fleets', { transcript_path => $tp, cwd => $dd }, [ { id => 'W1' } ], $now);
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1,
            'AC7 B12 (relative --bp-dir): one entry') or diag(explain($far));
        is($far->[0]{runs}, $runs, 'AC7 B12 (relative --bp-dir): resolved against the payload cwd')
            if ref $far eq 'ARRAY' && @$far;
    }
}

# ===========================================================================
# AC1 (amended, DC1, item 1): the real gate, far-pause fixture, under the
# A.2.4 FAR-PAUSE text (offer record, compact reason, TaskStop line). Also
# feeds AC17/AC18 (same run) and AC2/AC24 (B24, reused below).
# ===========================================================================
my ($AC1_ROOT, $AC1_SID, $AC1_ERR, $AC1_BP, $AC1_RELAUNCH, $AC1_DD, $AC1_TOKEN, $AC1_REASON);
{
    my ($root, $sid) = new_session();
    $AC1_ROOT = $root; $AC1_SID = $sid;
    ($AC1_DD, $AC1_BP, undef, $AC1_RELAUNCH, my $tp) = far_project_fixture(bp => 'farpause-bp');
    my @bg = (bgt('W1', 'shell'));
    local $ENV{CCPRAXIS_DATA_DIR} = $AC1_DD;
    my $before = time();
    my ($rc, $err) = run_gate($root, payload_for($sid, $tp, \@bg));
    my $after = time();
    $AC1_ERR = $err;
    is($rc, 2, 'AC1: far-pause fixture denies (exit 2)') or diag($err);
    like($err, qr/^Handoff: fleet \Q$AC1_BP\E resumes at \d{4}-\d\d-\d\d \d\d:\d\d UTC; come back with \/butler:reporter \Q$AC1_BP\E\.$/m,
        'AC1: the Handoff line matches exactly') or diag($err);

    ($AC1_TOKEN) = ($err =~ /Stop token: (\S+)/);
    ok(defined $AC1_TOKEN, 'AC1 setup: a Stop token was printed') or diag($err);

    like($err,
        qr/^  butler-continuity off --reason 'far pause, offer ([0-9a-f]{8}): [A-Za-z0-9][A-Za-z0-9._-]*\@[1-9][0-9]{0,10}(?:, [A-Za-z0-9][A-Za-z0-9._-]*\@[1-9][0-9]{0,10})*' --token \1$/m,
        'AC1: the off line matches the compact "far pause, offer <t>: name@epoch" shape, offer id == --token')
        or diag($err);
    ($AC1_REASON) = ($err =~ /--reason '([^']+)'/);
    ok(defined $AC1_REASON && (!defined $AC1_TOKEN || $AC1_REASON =~ /^far pause, offer \Q$AC1_TOKEN\E:/),
        'AC1: the reason\'s offer id equals the printed Stop token') or diag($err);

    like($err, qr/^Once off-confirm succeeds, stop the watcher with the TaskStop tool \(W1\): left running, it keeps waking this session\.$/m,
        'AC1 (AC18): the TaskStop instruction line is present, between the off line and the closing sentence')
        or diag($err);
    like($err, qr/End your turn with the Handoff line above\./, 'AC1: the closing sentence is present')
        or diag($err);
    unlike($err, qr/butler-hold/, 'AC1: no occurrence of butler-hold anywhere in stderr');

    my $off_pos      = index($err, "butler-continuity off --reason");
    my $taskstop_pos = index($err, 'stop the watcher with the TaskStop tool');
    my $closing_pos  = index($err, 'End your turn with the Handoff line above.');
    ok($off_pos >= 0 && $taskstop_pos >= 0 && $closing_pos >= 0
        && $off_pos < $taskstop_pos && $taskstop_pos < $closing_pos,
        'AC1 (AC18): the off line, the TaskStop line and the closing sentence appear in that order');

    my $log = slurp("$root/continuity/reasons.log");
    like($log, qr/\tgate\tfar-pause\t.*\t\Q$AC1_BP\E=\Q$AC1_RELAUNCH\E$/m,
        'AC1: reasons.log gains a far-pause line naming the fleet and its relaunch_at') or diag($log);

    # ---------------------------------------------------------------------
    # AC17 (item 1): the offer record itself -- path, every field, no temp
    # file left behind.
    # ---------------------------------------------------------------------
    SKIP: {
        skip 'AC17: no Stop token to resolve an offer record from', 11 unless defined $AC1_TOKEN;
        my $offer_path = far_pause_dir($AC1_DD) . "/$AC1_TOKEN.json";
        ok(-f $offer_path, "AC17: the offer record exists at DD/butler-far-pause/$AC1_TOKEN.json")
            or diag("dir listing: " . join(',', far_pause_json_files($AC1_DD)));
        my $doc = far_pause_record($AC1_DD, "$AC1_TOKEN.json");
        ok(ref $doc eq 'HASH', 'AC17: the offer record decodes to a HASH') or diag(slurp($offer_path));
        SKIP: {
            skip 'AC17: record did not decode, cannot inspect fields', 10 unless ref $doc eq 'HASH';
            is($doc->{v}, 1, 'AC17: v is 1');
            is($doc->{session_id}, $AC1_SID, 'AC17: session_id is this session');
            is($doc->{offer}, $AC1_TOKEN, 'AC17: offer equals the printed Stop token');
            is($doc->{reason}, $AC1_REASON, 'AC17: reason is byte-equal to the printed --reason');
            ok(defined $doc->{written_at} && $doc->{written_at} =~ /\A\d+\z/
                && $doc->{written_at} >= $before - 1 && $doc->{written_at} <= $after + 5,
                'AC17: written_at is the $now G11 used, within 5s') or diag(explain($doc));
            is($doc->{written_at_utc}, utc_z($doc->{written_at}), 'AC17: written_at_utc is gmtime(written_at)')
                if defined $doc->{written_at};
            is($doc->{valid_until_utc}, utc_z($doc->{written_at} + 1800), 'AC17: valid_until_utc is written_at + TTL (1800s)')
                if defined $doc->{written_at};
            is(ref $doc->{fleets} eq 'ARRAY' ? scalar(@{ $doc->{fleets} }) : -1, 1, 'AC17: fleets has one entry')
                or diag(explain($doc->{fleets}));
            if (ref $doc->{fleets} eq 'ARRAY' && @{ $doc->{fleets} } == 1) {
                my $f = $doc->{fleets}[0];
                is($f->{name}, $AC1_BP, 'AC17: fleets[0].name is the blueprint');
                is($f->{relaunch_at}, $AC1_RELAUNCH, 'AC17: fleets[0].relaunch_at matches .paused');
                is($f->{relaunch_at_utc}, utc_z($AC1_RELAUNCH), 'AC17: fleets[0].relaunch_at_utc is gmtime(relaunch_at)');
            }
        }
        my @tmp = far_pause_tmp_files($AC1_DD);
        is(scalar(@tmp), 0, 'AC17: no *.tmp.* temp file remains in butler-far-pause/') or diag(explain(\@tmp));
    }
}

# ===========================================================================
# AC2 (amended, DC1, item 1/2, B24): the off + off-confirm flow, with the
# reason extracted from AC1's stderr, judged by the stub. Additionally
# checks the offer record is still present when off-confirm runs (A.2.3's
# "written_at" must still be fresh at TTL-time for the judge to see it, even
# though the real judge is never run here -- its rule is asserted as text in
# AC3/AC23).
# ===========================================================================
{
    SKIP: {
        skip 'AC2: AC1 produced no stderr to extract a reason from', 9 unless defined $AC1_ERR;
        my ($reason) = ($AC1_ERR =~ /--reason '([^']+)'/);
        ok(defined $reason, 'AC2 setup: a --reason was extracted from AC1\'s stderr') or diag($AC1_ERR);

        my $tp = "$AC1_ROOT/off-confirm.jsonl";
        open my $fh, '>', $tp or die $!; print {$fh} "{}\n"; close $fh;

        my $run_cli = sub {
            my (%env_over) = @_;
            my (undef, $o) = tempfile(DIR => $TMP);
            my (undef, $e) = tempfile(DIR => $TMP);
            my $pid = fork() // die "fork: $!";
            if ($pid == 0) {
                delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
                $ENV{BUTLER_STATE_DIR} = $AC1_ROOT;
                $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
                $ENV{$_} = $env_over{$_} for keys %env_over;
                open(STDOUT, '>', $o) or _exit(126);
                open(STDERR, '>', $e) or _exit(126);
                exec($^X, $CONT_CMD, @{ $env_over{_argv} });
                _exit(127);
            }
            push @KILL_PIDS, $pid;
            my $deadline = time() + 30;
            my $rc;
            while (time() < $deadline) {
                if (waitpid($pid, WNOHANG) == $pid) { $rc = $? >> 8; last }
                sleep(0.05);
            }
            unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
            @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
            return (slurp($o), slurp($e), $rc);
        };

        local $ENV{BUTLER_STATE_DIR} = $AC1_ROOT;
        my $p1 = { session_id => $AC1_SID, tool_use_id => 'tu-off', transcript_path => $tp, cwd => $AC1_ROOT };
        BpHook::write_ticket($p1, 'butler-continuity', ['off', '--reason', $reason]);
        my (undef, $err1, $rc1) = $run_cli->(_argv => ['off', '--reason', $reason]);
        is($rc1, 1, 'AC2: off --reason mints a disarm OTP (exit 1), proving the compact reason passed the 200-byte check')
            or diag($err1);
        my ($otp) = ($err1 =~ /^  butler-continuity off-confirm --otp ([0-9a-f]{8}) --justification '/m);
        ok(defined $otp, 'AC2: an 8-hex-char OTP was minted') or diag($err1);

        ok(defined $AC1_TOKEN && -f (far_pause_dir($AC1_DD) . "/$AC1_TOKEN.json"),
            'AC2 (B24): the offer record still exists when off-confirm is about to run');

        my $p2 = { session_id => $AC1_SID, tool_use_id => 'tu-offc', transcript_path => $tp, cwd => $AC1_ROOT };
        BpHook::write_ticket($p2, 'butler-continuity',
            ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'far pause handoff']);
        my (undef, $err2, $rc2) = $run_cli->(
            _argv => ['off-confirm', '--otp', $otp // 'deadbeef', '--justification', 'far pause handoff'],
            CCPRAXIS_DISARM_JUDGE_STUB => 'approve');
        is($rc2, 0, 'AC2: off-confirm with CCPRAXIS_DISARM_JUDGE_STUB=approve exits 0') or diag($err2);

        my $off_doc = eval { JSON::PP->new->decode(slurp("$AC1_ROOT/continuity/off/$AC1_SID")) };
        is(ref $off_doc eq 'HASH' ? $off_doc->{actor} : undef, 'agent', 'AC2: the off record\'s actor is agent');
        is(ref $off_doc eq 'HASH' ? $off_doc->{reason} : undef, $reason,
            'AC2: the off record\'s reason equals the far-pause reason');
        ok(!-e "$AC1_ROOT/continuity/armed/$AC1_SID", 'AC2: armed/<sid> is gone');

        my $tp3 = "$AC1_ROOT/post-off.jsonl";
        open my $fh3, '>', $tp3 or die $!; print {$fh3} "{}\n"; close $fh3;
        my ($rc3, $err3) = run_gate($AC1_ROOT, { session_id => $AC1_SID, hook_event_name => 'Stop',
            stop_hook_active => JSON::PP::false(), transcript_path => $tp3, cwd => $PROJECT, background_tasks => [] });
        is($rc3, 0, 'AC2: the next Stop for the now-unarmed session exits 0') or diag($err3);
    }
}

# ===========================================================================
# AC3 (amended, DC1, item 1): bp-disarm-judge.md gains the A.2.5 far-pause
# rule and no longer carries the superseded 2.5 bullet; frontmatter unchanged.
# ===========================================================================
{
    my $src = slurp($AGENT_MD);
    ok(length($src), 'AC3 setup: bp-disarm-judge.md is readable');
    like($src, qr/when the Stop gate offered it/i, 'AC3: contains "when the Stop gate offered it"');
    like($src, qr/far pause, offer <id>/, 'AC3: contains "far pause, offer <id>"');
    like($src, qr{\.ccpraxis-local-data/butler-far-pause/<id>\.json},
        'AC3: contains the offer-record path ".ccpraxis-local-data/butler-far-pause/<id>.json"');
    like($src, qr/valid_until_utc/, 'AC3: contains "valid_until_utc"');
    like($src, qr/gathered from disk by bp-disarm-digest\.pl/, 'AC3: contains "gathered from disk by bp-disarm-digest.pl"');
    like($src, qr/relaunch_at_utc/, 'AC3: contains "relaunch_at_utc"');
    like($src, qr/more than 32 h/, 'AC3: contains "more than 32 h"');
    like($src, qr/"manual"/, 'AC3: contains \'"manual"\'');
    like($src, qr/With no digest there is no time to compare/, 'AC3: contains "With no digest there is no time to compare"');
    unlike($src, qr/far pause: fleet <name> resumes at/, 'AC3: no longer contains the superseded 2.5 reason shape');

    my @lines = split /\n/, $src;
    my %pinned = (
        2 => 'name: bp-disarm-judge',
        4 => 'model: sonnet',
        5 => 'effort: medium',
        6 => 'maxTurns: 400',
        7 => 'tools: Read, Grep, Glob, Bash',
    );
    for my $ln (sort { $a <=> $b } keys %pinned) {
        (my $got = $lines[$ln - 1] // '') =~ s/\r\z//;
        is($got, $pinned{$ln}, "AC3: frontmatter line $ln is byte-equal to the pre-change value ('$pinned{$ln}')");
    }
    like($lines[2] // '', qr/^description: /, 'AC3: frontmatter line 3 still starts "description: "');
}

# ===========================================================================
# AC4 (DC2, B8): within-horizon fixture -- today's RUNNING text, unchanged.
# ===========================================================================
{
    my ($root, $sid) = new_session();
    my $bp = 'nearpause-bp';
    my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
    my $relaunch = time() + $HORIZON - 3600;
    write_paused("$bpdir/runs", { reason => 'usage', relaunch_at => $relaunch });
    my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
        cmd => "perl /x/bp-wait-for-escalation.pl $bp --bp-dir '$bpdir' --timeout 1800" });
    my @bg = (bgt('W1', 'shell'));
    my ($rc, $err) = run_gate($root, payload_for($sid, $tp, \@bg));
    is($rc, 2, 'AC4: within-horizon fixture still denies (exit 2)') or diag($err);
    like($err, qr/still running: W1\. Stop token: \S+/, 'AC4: the RUNNING text names the work and a token')
        or diag($err);
    my ($token) = ($err =~ /Stop token: (\S+)/);
    like($err, qr/^  butler-hold --token \Q$token\E W1$/m, 'AC4: a butler-hold is suggested') if defined $token;
    unlike($err, qr/^Handoff:/m, 'AC4: no Handoff line');

    my $log = slurp("$root/continuity/reasons.log");
    unlike($log, qr/\tgate\tfar-pause\t/, 'AC4: no far-pause line in reasons.log');
}

# ===========================================================================
# AC8 (DC2, B13): a live holder lets the stop through even on a far-paused
# fleet.
# ===========================================================================
{
    my ($root, $sid) = new_session();
    my $bp = 'heldpause-bp';
    my $bpdir = tempdir(DIR => $TMP, CLEANUP => 1); $bpdir =~ s{\\}{/}g;
    write_paused("$bpdir/runs", { reason => 'usage', relaunch_at => time() + $HORIZON + 7200 });
    my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
        cmd => "perl /x/bp-wait-for-escalation.pl $bp --bp-dir '$bpdir' --timeout 1800" });
    my $holder_pid = spawn_sleeper();
    write_holder($root, $sid, pid => $holder_pid, fp => cmdline_fp_of($holder_pid),
        items => ['W1'], deadline => int(time() + 1800));
    my @bg = (bgt('W1', 'shell'));
    my ($rc, $err) = run_gate($root, payload_for($sid, $tp, \@bg));
    is($rc, 0, 'AC8: a live holder lets the stop through, even on a far-paused fleet') or diag($err);
    unlike($err, qr/Stop token/, 'AC8: nothing is asked of the agent');
}

# ===========================================================================
# AC19 (DC1/DC2, item 1, B18 a-c): offer-record lifecycle through the real
# gate. Each sub-case starts from a fresh "after B17" far-pause fixture
# (independent sessions/DD, all generically "session S") to keep the three
# scenarios from interfering with each other's record bookkeeping.
# ===========================================================================
{
    # (a) a far Stop, then .paused moves within the horizon: the next Stop
    # shows RUNNING text, and no record with this session's id remains.
    {
        my ($dd, $bp, $bpdir, undef, $tp1) = far_project_fixture(bp => 'ac19a-bp');
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my ($root, $sid) = new_session();
        my @bg = (bgt('W1', 'shell'));
        my ($rc1, $err1) = run_gate($root, payload_for($sid, $tp1, \@bg));
        is($rc1, 2, 'AC19(a) setup: the initial far Stop denies') or diag($err1);
        like($err1, qr/^Handoff:/m, 'AC19(a) setup: the initial far Stop shows the Handoff line');

        write_paused("$bpdir/runs", { reason => 'usage', relaunch_at => time() + $HORIZON - 3600 });
        my $tp2 = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl $bp --bp-dir '$bpdir' --timeout 1800" });
        my ($rc2, $err2) = run_gate($root, payload_for($sid, $tp2, \@bg));
        is($rc2, 2, 'AC19(a): the within-horizon Stop still denies (RUNNING text)') or diag($err2);
        unlike($err2, qr/^Handoff:/m, 'AC19(a): no Handoff line this time');

        my @mine = grep {
            my $d = far_pause_record($dd, $_);
            ref $d eq 'HASH' && ($d->{session_id} // '') eq $sid
        } far_pause_json_files($dd);
        is(scalar(@mine), 0, 'AC19(a): no live record with this session\'s id remains') or diag(explain(\@mine));
    }

    # (b) a second far Stop: the first offer's file is gone, the second
    # exists, and exactly one record carries this session's id.
    {
        my ($dd, $bp, $bpdir, undef, $tp1) = far_project_fixture(bp => 'ac19b-bp');
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my ($root, $sid) = new_session();
        my @bg = (bgt('W1', 'shell'));
        my ($rc1, $err1) = run_gate($root, payload_for($sid, $tp1, \@bg));
        is($rc1, 2, 'AC19(b) setup: the first far Stop denies') or diag($err1);
        my ($t1) = ($err1 =~ /Stop token: (\S+)/);
        ok(defined $t1, 'AC19(b) setup: a first token t1 was minted') or diag($err1);

        my $tp2 = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl $bp --bp-dir '$bpdir' --timeout 1800" });
        my ($rc2, $err2) = run_gate($root, payload_for($sid, $tp2, \@bg));
        is($rc2, 2, 'AC19(b): the second far Stop denies') or diag($err2);
        my ($t2) = ($err2 =~ /Stop token: (\S+)/);
        ok(defined $t2, 'AC19(b): a second token t2 was minted') or diag($err2);

        SKIP: {
            skip 'AC19(b): no two distinct tokens to compare', 3 unless defined $t1 && defined $t2;
            ok($t1 ne $t2, 'AC19(b): t1 and t2 are distinct tokens');
            ok(!-e (far_pause_dir($dd) . "/$t1.json"), 'AC19(b): the old t1.json is gone');
            ok(-e (far_pause_dir($dd) . "/$t2.json"), 'AC19(b): the new t2.json exists');
        }
        my @mine = grep {
            my $d = far_pause_record($dd, $_);
            ref $d eq 'HASH' && ($d->{session_id} // '') eq $sid
        } far_pause_json_files($dd);
        is(scalar(@mine), 1, 'AC19(b): exactly one record carries this session\'s id') or diag(explain(\@mine));
    }

    # (c) a far Stop, then a live holder for the same session: exit 0, and
    # no record for this session remains.
    {
        my ($dd, $bp, $bpdir, undef, $tp1) = far_project_fixture(bp => 'ac19c-bp');
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my ($root, $sid) = new_session();
        my @bg = (bgt('W1', 'shell'));
        my ($rc1, $err1) = run_gate($root, payload_for($sid, $tp1, \@bg));
        is($rc1, 2, 'AC19(c) setup: the far Stop denies') or diag($err1);

        my $tp2 = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl $bp --bp-dir '$bpdir' --timeout 1800" });
        my $holder_pid = spawn_sleeper();
        write_holder($root, $sid, pid => $holder_pid, fp => cmdline_fp_of($holder_pid),
            items => ['W1'], deadline => int(time() + 1800));
        my ($rc2, $err2) = run_gate($root, payload_for($sid, $tp2, \@bg));
        is($rc2, 0, 'AC19(c): the Stop with a live holder exits 0') or diag($err2);

        my @mine = grep {
            my $d = far_pause_record($dd, $_);
            ref $d eq 'HASH' && ($d->{session_id} // '') eq $sid
        } far_pause_json_files($dd);
        is(scalar(@mine), 0, 'AC19(c): no record for this session remains') or diag(explain(\@mine));
    }

    # (d) another session T's expired record is swept by S's armed Stop,
    # while T's fresh record is kept. $TTL is read from the package var when
    # the addendum has defined it; until then the spec's own literal (1800)
    # stands in only to CONSTRUCT the fixture, never to judge the result.
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        my $ttl = defined $BpHook::StopGate::FAR_OFFER_TTL ? $BpHook::StopGate::FAR_OFFER_TTL : 1800;
        my $now = time();
        write_far_pause_record($dd, 'aaaaaaaa', {
            v => 1, session_id => 'other-session-T', offer => 'aaaaaaaa', reason => 'far pause, offer aaaaaaaa: x@1',
            written_at => $now - $ttl - 60, written_at_utc => utc_z($now - $ttl - 60),
            valid_until_utc => utc_z($now - 60), fleets => [],
        });
        write_far_pause_record($dd, 'bbbbbbbb', {
            v => 1, session_id => 'other-session-T', offer => 'bbbbbbbb', reason => 'far pause, offer bbbbbbbb: y@1',
            written_at => $now, written_at_utc => utc_z($now),
            valid_until_utc => utc_z($now + $ttl), fleets => [],
        });
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my ($root, $sid) = new_session();
        my $tp = "$root/idle-ac19d.jsonl";
        open my $fh, '>', $tp or die $!; print {$fh} "{}\n"; close $fh;
        run_gate($root, payload_for($sid, $tp, []));    # any armed Stop sweeps -- idle text is fine

        ok(!-e (far_pause_dir($dd) . "/aaaaaaaa.json"), 'AC19(d): the expired record of another session is removed');
        ok(-e (far_pause_dir($dd) . "/bbbbbbbb.json"), 'AC19(d): the fresh record of another session is kept');
    }
}

# ===========================================================================
# AC20 (DC2, item 1, B19): the offer record cannot be written (a plain FILE
# pre-created at DD/butler-far-pause) -- the gate falls back to the RUNNING
# text, and writes no far-pause reasons.log line.
# ===========================================================================
{
    my ($dd, $bp, undef, undef, $tp) = far_project_fixture(bp => 'ac20-bp');
    open my $fh, '>', "$dd/butler-far-pause" or die $!;
    print {$fh} "blocker, not a directory\n";
    close $fh;

    local $ENV{CCPRAXIS_DATA_DIR} = $dd;
    my ($root, $sid) = new_session();
    my @bg = (bgt('W1', 'shell'));
    my ($rc, $err) = run_gate($root, payload_for($sid, $tp, \@bg));
    is($rc, 2, 'AC20: write-failure fixture still denies (exit 2)') or diag($err);
    like($err, qr/still running: W1\. Stop token: \S+/, 'AC20: the RUNNING text names the work (fallback)')
        or diag($err);
    my ($token) = ($err =~ /Stop token: (\S+)/);
    like($err, qr/^  butler-hold --token \Q$token\E W1$/m, 'AC20: a butler-hold is suggested (fallback)')
        if defined $token;
    unlike($err, qr/^Handoff:/m, 'AC20: no Handoff line');

    my $log = slurp("$root/continuity/reasons.log");
    unlike($log, qr/\tgate\tfar-pause\t/, 'AC20: no far-pause line in reasons.log');
}

# ===========================================================================
# AC21 (DC1/DC2, item 2, B20): far_pause_reason's 200-byte cap, in-process at
# the 200/201-byte boundary and empty-list case, plus the real-gate overflow
# fallback (two far fleets whose names push the reason past 200 bytes).
# ===========================================================================
{
    my $r = SG('far_pause_reason', '0123abcd', [ { name => 'N', relaunch_at => 1793892555 } ]);
    is($r, 'far pause, offer 0123abcd: N@1793892555', 'AC21: far_pause_reason basic shape');

    my $prefix = 'far pause, offer 0123abcd: ';
    my $suffix = '@1793892555';
    my $name_len = 200 - length($prefix) - length($suffix);
    ok($name_len > 0, 'AC21 setup: a 200-byte boundary name is constructible');
    SKIP: {
        skip 'AC21: cannot construct the 200-byte boundary name', 2 unless $name_len > 0;
        my $name200 = ('a' x ($name_len - 1)) . 'Z';
        my $r200 = SG('far_pause_reason', '0123abcd', [ { name => $name200, relaunch_at => 1793892555 } ]);
        is($r200, "$prefix$name200$suffix", 'AC21: exactly 200 bytes -> the string itself')
            or diag(defined $r200 ? length($r200) : 'undef');

        my $name201 = $name200 . 'x';
        my $r201 = SG('far_pause_reason', '0123abcd', [ { name => $name201, relaunch_at => 1793892555 } ]);
        is($r201, undef, 'AC21: 201 bytes -> undef');
    }

    my $rempty = SG('far_pause_reason', '0123abcd', []);
    is($rempty, undef, 'AC21: an empty fleet list -> undef');

    # -- real gate: two far fleets whose names overflow the 200-byte cap ---
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        my $relaunch = time() + $HORIZON + 7200;
        my ($long1, $long2) = ('a' x 100, 'b' x 100);
        for my $bp ($long1, $long2) {
            write_paused("$dd/blueprints/$bp/runs", { reason => 'usage', relaunch_at => $relaunch });
        }
        my $tp = write_transcript(
            { tuid => 'tu1', task => 'W1', cmd => "perl /x/bp-wait-for-escalation.pl $long1 --bp-dir '$dd/blueprints/$long1' --timeout 1800" },
            { tuid => 'tu2', task => 'W2', cmd => "perl /x/bp-wait-for-escalation.pl $long2 --bp-dir '$dd/blueprints/$long2' --timeout 1800" },
        );
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my ($root, $sid) = new_session();
        my @bg = (bgt('W1', 'shell'), bgt('W2', 'shell'));
        my ($rc, $err) = run_gate($root, payload_for($sid, $tp, \@bg));
        is($rc, 2, 'AC21 (real gate): the overflow fixture still denies') or diag($err);
        like($err, qr/still running:.*W1.*W2|still running:.*W2.*W1/, 'AC21 (real gate): the RUNNING text names both items')
            or diag($err);
        unlike($err, qr/^Handoff:/m, 'AC21 (real gate): no Handoff line (fell back from overflow)');
        my @overflow_files = far_pause_json_files($dd);
        is(scalar(@overflow_files), 0, 'AC21 (real gate): no offer record was written on overflow');
    }
}

# ===========================================================================
# AC22 (DC1/DC2, item 3, B21): project-rooted resolution -- every undef and
# one-entry case in-process through far_paused_fleets, plus the
# CCPRAXIS_DATA_DIR env-prefix case through the real gate.
# ===========================================================================
{
    my $now = time();
    my $far_relaunch = $now + $HORIZON + 7200;

    # ac22_far(%o) -- runs far_paused_fleets with a single watcher W1 whose
    # launch command is %o{cmd}, under the given (possibly absent)
    # CCPRAXIS_DATA_DIR/CLAUDE_PROJECT_DIR and payload cwd.
    my $ac22_far = sub {
        my (%o) = @_;
        local $ENV{CCPRAXIS_DATA_DIR};
        if (defined $o{dd}) { $ENV{CCPRAXIS_DATA_DIR} = $o{dd} } else { delete $ENV{CCPRAXIS_DATA_DIR} }
        local $ENV{CLAUDE_PROJECT_DIR};
        if (exists $o{cpd}) { $ENV{CLAUDE_PROJECT_DIR} = $o{cpd} } else { delete $ENV{CLAUDE_PROJECT_DIR} }
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1', cmd => $o{cmd} });
        return SG('far_paused_fleets', { transcript_path => $tp, cwd => $o{cwd} // $PROJECT }, [ { id => 'W1' } ],
            $o{now} // $now);
    };

    # -- undef cases ---------------------------------------------------
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        my $outside = tempdir(DIR => $TMP, CLEANUP => 1); $outside =~ s{\\}{/}g;
        write_paused("$outside/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $far = $ac22_far->(dd => $dd, cmd => "perl /x/bp-wait-for-escalation.pl ac22a --runs '$outside/runs' --timeout 1800");
        is($far, undef, 'AC22: --runs outside DD/blueprints -> undef');
    }
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        my $outside = tempdir(DIR => $TMP, CLEANUP => 1); $outside =~ s{\\}{/}g;
        write_paused("$outside/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $far = $ac22_far->(dd => $dd, cmd => "perl /x/bp-wait-for-escalation.pl ac22b --bp-dir '$outside' --timeout 1800");
        is($far, undef, 'AC22: --bp-dir outside DD/blueprints -> undef');
    }
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        write_paused("$dd/blueprints/other/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $far = $ac22_far->(dd => $dd, cmd => "perl /x/bp-wait-for-escalation.pl ac22c --bp-dir '$dd/blueprints/other' --timeout 1800");
        is($far, undef, 'AC22: positional name mismatched against --bp-dir\'s blueprint -> undef');
    }
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        write_paused("$dd/blueprints/ac22d/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $far = $ac22_far->(dd => $dd,
            cmd => "perl /x/bp-wait-for-escalation.pl ac22d --bp-dir '$dd/blueprints/ac22d/../ac22d' --timeout 1800");
        is($far, undef, 'AC22: a --bp-dir containing a .. segment -> undef');
    }
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        write_paused("$dd/blueprints/ac22e/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $far = $ac22_far->(dd => $dd,
            cmd => "CCPRAXIS_DATA_DIR=/somewhere/else perl /x/bp-wait-for-escalation.pl ac22e --bp-dir '$dd/blueprints/ac22e' --timeout 1800");
        is($far, undef, 'AC22: a CCPRAXIS_DATA_DIR= env-prefix in the launch command -> undef');
    }
    {
        my $cwd = tempdir(DIR => $TMP, CLEANUP => 1); $cwd =~ s{\\}{/}g;
        my $far = $ac22_far->(dd => undef, cpd => undef,
            cmd => "perl /x/bp-wait-for-escalation.pl ac22f --timeout 1800", cwd => $cwd);
        is($far, undef, 'AC22: no data dir resolves (no env var, cwd carries no .ccpraxis-local-data) -> undef');
    }

    # -- one-entry cases -------------------------------------------------
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        my $runs = "$dd/blueprints/ac22g/runs";
        write_paused($runs, { reason => 'usage', relaunch_at => $far_relaunch });
        my $far = $ac22_far->(dd => $dd, cmd => "perl /x/bp-wait-for-escalation.pl --runs '$runs' --timeout 1800");
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, 'AC22: --runs DD/blueprints/<name>/runs, no positional -> one entry')
            or diag(explain($far));
        is($far->[0]{name}, 'ac22g', 'AC22: the name is the runs dir\'s parent basename') if ref $far eq 'ARRAY' && @$far;
    }
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        write_paused("$dd/blueprints/ac22h/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        (my $bs = "$dd/blueprints/ac22h") =~ s{/}{\\}g;
        my $far = $ac22_far->(dd => $dd, cmd => "perl /x/bp-wait-for-escalation.pl ac22h --bp-dir '$bs' --timeout 1800");
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, 'AC22: --bp-dir with backslashes -> one entry') or diag(explain($far));
    }
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        write_paused("$dd/blueprints/ac22i/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $far = $ac22_far->(dd => $dd, cmd => "perl /x/bp-wait-for-escalation.pl ac22i --bp-dir '$dd/blueprints/ac22i/' --timeout 1800");
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, 'AC22: --bp-dir with a trailing slash -> one entry') or diag(explain($far));
    }
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        write_paused("$dd/blueprints/ac22j/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        (my $dd_posix = $dd) =~ s{^([A-Za-z]):}{'/' . lc($1)}e;
        my $far = $ac22_far->(dd => $dd, cmd => "perl /x/bp-wait-for-escalation.pl ac22j --bp-dir '$dd_posix/blueprints/ac22j' --timeout 1800");
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, 'AC22: --bp-dir given as /c/... while DD is C:/... -> one entry (case-insensitive drive letter)')
            or diag(explain($far));
    }
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        write_paused("$dd/blueprints/ac22k/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $far = $ac22_far->(dd => $dd, cmd => "perl /x/bp-wait-for-escalation.pl ac22k --timeout 1800");
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, 'AC22: positional blueprint alone (CCPRAXIS_DATA_DIR resolution) -> one entry')
            or diag(explain($far));
    }
    {
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        write_paused("$dd/blueprints/ac22l/runs", { reason => 'usage', relaunch_at => $far_relaunch });
        my $far = $ac22_far->(dd => $dd, cwd => "$dd/blueprints",
            cmd => "perl /x/bp-wait-for-escalation.pl ac22l --bp-dir 'ac22l' --timeout 1800");
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, 'AC22: a relative --bp-dir resolved against the payload cwd -> one entry')
            or diag(explain($far));
    }

    # -- through the real gate: the env-prefix case shows the RUNNING text --
    {
        my ($dd, $bp, $bpdir, $relaunch, undef) = far_project_fixture(bp => 'ac22m-bp');
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "CCPRAXIS_DATA_DIR=/somewhere/else perl /x/bp-wait-for-escalation.pl $bp --bp-dir '$bpdir' --timeout 1800" });
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        my ($root, $sid) = new_session();
        my @bg = (bgt('W1', 'shell'));
        my ($rc, $err) = run_gate($root, payload_for($sid, $tp, \@bg));
        is($rc, 2, 'AC22 (real gate): the env-prefix fixture still denies') or diag($err);
        like($err, qr/still running: W1\. Stop token: \S+/, 'AC22 (real gate): the RUNNING text (env-prefix is unresolvable)')
            or diag($err);
        unlike($err, qr/^Handoff:/m, 'AC22 (real gate): no Handoff line');
    }
}

# ===========================================================================
# AC23 (DC1, item 1): structural guards -- StopGate.pm names the new subs and
# the offer-record directory, and clears offers between clear_running_snapshot
# (G7b) and holder_live (G8).
# ===========================================================================
{
    my $src = slurp($SG_PM);
    like($src, qr/\bfar_pause_reason\b/, 'AC23: StopGate.pm contains far_pause_reason');
    like($src, qr/butler-far-pause/, 'AC23: StopGate.pm contains "butler-far-pause"');
    like($src, qr/_clear_far_offers/, 'AC23: StopGate.pm contains _clear_far_offers');

    my $pos_crs    = index($src, 'clear_running_snapshot');
    my $pos_clear  = index($src, '_clear_far_offers');
    my $pos_holder = index($src, 'holder_live');
    ok($pos_crs >= 0 && $pos_clear >= 0 && $pos_holder >= 0
        && $pos_crs < $pos_clear && $pos_clear < $pos_holder,
        'AC23: _clear_far_offers is called after clear_running_snapshot and before holder_live')
        or diag("clear_running_snapshot=$pos_crs _clear_far_offers=$pos_clear holder_live=$pos_holder");
}

# ===========================================================================
# AC24 (DC2, item 3/6, B22): relaunch_at sanity -- a plain, sane integer only.
# Always otherwise beyond the horizon, so the only variable is the value's
# shape/size (and, separately, $now's own shape).
# ===========================================================================
{
    my $base_now = time();
    my $far_relaunch_val = $base_now + $HORIZON + 7200;
    my $max_ahead = defined $BpHook::StopGate::FAR_RELAUNCH_MAX_AHEAD
        ? $BpHook::StopGate::FAR_RELAUNCH_MAX_AHEAD : 366 * 86400;

    # ac24_far($relaunch_value, $now) -- writes a .paused with that raw
    # relaunch_at value (JSON-encoded, so the value's own Perl-ness decides
    # number vs string) and calls far_paused_fleets with $now.
    my $ac24_far = sub {
        my ($val, $now) = @_;
        my $dd = tempdir(DIR => $TMP, CLEANUP => 1); $dd =~ s{\\}{/}g;
        my $bpdir = "$dd/blueprints/ac24bp";
        my $runs = "$bpdir/runs";
        make_path($runs);
        open my $fh, '>:raw', "$runs/.paused" or die $!;
        print {$fh} $J->encode({ reason => 'usage', relaunch_at => $val });
        close $fh;
        my $tp = write_transcript({ tuid => 'tu1', task => 'W1',
            cmd => "perl /x/bp-wait-for-escalation.pl ac24bp --bp-dir '$bpdir' --timeout 1800" });
        local $ENV{CCPRAXIS_DATA_DIR} = $dd;
        return SG('far_paused_fleets', { transcript_path => $tp, cwd => $PROJECT }, [ { id => 'W1' } ], $now);
    };

    for my $case (
        [ '2026-12-01T00:00:00Z', $base_now, 'an ISO string' ],
        [ 'soon', $base_now, '"soon"' ],
        [ $far_relaunch_val + 0.5, $base_now, 'a JSON number with a fractional part' ],
        [ '99999999999999999999', $base_now, 'an absurdly large numeric string' ],
        [ $base_now + $max_ahead + 1, $base_now, 'one second beyond the sanity cap' ],
    ) {
        my ($val, $now, $label) = @$case;
        my $far = $ac24_far->($val, $now);
        is($far, undef, "AC24: relaunch_at is $label -> undef");
    }

    for my $case (
        [ sprintf('%d', $far_relaunch_val), $base_now, 'a JSON string of digits' ],
        [ $base_now + $max_ahead, $base_now, 'exactly at the sanity cap' ],
    ) {
        my ($val, $now, $label) = @$case;
        my $far = $ac24_far->($val, $now);
        is(ref $far eq 'ARRAY' ? scalar(@$far) : -1, 1, "AC24: relaunch_at is $label -> one entry")
            or diag(explain($far));
    }

    is($ac24_far->($far_relaunch_val, undef), undef, 'AC24: $now undef -> undef');
    is($ac24_far->($far_relaunch_val, '12.5'), undef, 'AC24: $now "12.5" (non-integer) -> undef');
}

# ===========================================================================
# AC25 (DC3, item 5): BpContinuityLease survives a broken BpAwakeIntent.
# A scratch copy of BpContinuityLease.pm/bp-keepawake.pl/BpAwakeConst.pm next
# to a BpAwakeIntent.pm that dies on load, in a CHILD perl (never this
# process's own BpContinuityLease, which must keep working). Plus structural
# guards on the real file.
# ===========================================================================
{
    my $cpdir = tempdir(DIR => $TMP, CLEANUP => 1); $cpdir =~ s{\\}{/}g;
    for my $f (qw(BpContinuityLease.pm bp-keepawake.pl BpAwakeConst.pm)) {
        my $data = slurp("$S/$f");
        ok(length($data), "AC25 setup: $f is readable to copy") or next;
        open my $fh, '>:raw', "$cpdir/$f" or die $!;
        print {$fh} $data;
        close $fh;
    }
    open my $bfh, '>:raw', "$cpdir/BpAwakeIntent.pm" or die $!;
    print {$bfh} "package BpAwakeIntent;\nuse strict;\nuse warnings;\ndie \"deliberately broken\\n\";\n1;\n";
    close $bfh;

    my $prog = <<'PERL';
require "$ARGV[0]/BpContinuityLease.pm";
my $rv = BpContinuityLease::touch_busy($ARGV[1]);
print "RV=", (defined $rv ? $rv : 'undef'), "\n";
PERL

    # (A) absent path -> created EMPTY with a fresh mtime, child exits 0.
    my $lease_a = "$cpdir/lease-absent";
    my ($o1, $e1, $rc1) = run_perl_script($prog, [$cpdir, $lease_a]);
    is($rc1, 0, 'AC25: a child loading BpContinuityLease.pm over a broken BpAwakeIntent.pm exits 0 (absent lease)')
        or diag($e1);
    like($o1, qr/RV=1/, 'AC25: touch_busy on an absent path still returns 1') or diag($o1);
    ok(-f $lease_a, 'AC25: the lease file was created');
    is(slurp($lease_a), '', 'AC25: it is EMPTY (the 05 bare-touch fallback)');

    # (B) existing content -> unchanged.
    my $lease_b = "$cpdir/lease-present";
    open my $lfh, '>:raw', $lease_b or die $!; print {$lfh} "PRIOR-CONTENT\n"; close $lfh;
    my $old = time() - 500; utime($old, $old, $lease_b);
    my ($o2, $e2, $rc2) = run_perl_script($prog, [$cpdir, $lease_b]);
    is($rc2, 0, 'AC25: a child loading over a broken BpAwakeIntent.pm exits 0 (existing lease)') or diag($e2);
    like($o2, qr/RV=1/, 'AC25: touch_busy on an existing path still returns 1') or diag($o2);
    is(slurp($lease_b), "PRIOR-CONTENT\n", 'AC25: existing content is left unchanged');

    # -- structural: the real file guards the require and the touch_busy body
    my $src = slurp($CL_PM);
    like($src, qr/eval\s*\{\s*require\s*"\$DIR\/BpAwakeIntent\.pm"/,
        'AC25: the BpAwakeIntent require line sits inside eval {');
    my ($body) = $src =~ /\n(sub touch_busy\s*\{.*?\n\})\n/s;
    ok(defined $body, 'AC25 setup: touch_busy body is isolated for inspection') or diag('regex did not match');
    SKIP: {
        skip 'AC25: touch_busy body not found', 1 unless defined $body;
        like($body, qr/defined\s*&BpAwakeIntent::lease_line/,
            "AC25: touch_busy's body tests defined &BpAwakeIntent::lease_line");
    }
}

# ===========================================================================
# AC26 (DC3, item 6): refresh()'s header comment no longer claims "Stats and
# utimes only" or "every 60s slice", and now names converge and the busy
# lease.
# ===========================================================================
{
    my $src = slurp($CL_PM);
    my ($comment) = $src =~ /((?:^#.*\n)+)sub refresh\s*\{/m;
    ok(defined $comment, 'AC26 setup: a comment block precedes sub refresh') or diag('no comment block found');
    SKIP: {
        skip 'AC26: no comment block found', 4 unless defined $comment;
        unlike($comment, qr/Stats and utimes only/, 'AC26: no longer contains "Stats and utimes only"');
        unlike($comment, qr/every 60s slice/, 'AC26: no longer contains "every 60s slice"');
        like($comment, qr/converge/, 'AC26: contains "converge"');
        like($comment, qr/busy lease/, 'AC26: contains "busy lease"');
    }
}

# ===========================================================================
# AC27 (DC5): AC16 again, after this addendum -- every file in the ledger's
# test_paths passes on the Windows host. NOT a per-file assertion this file
# can make (it cannot judge a sibling file's own exit code as a correctness
# oracle about itself); validated externally by the driver's run-tests.pl
# sweep over test_paths, recorded in the step-7 report.
# ===========================================================================

done_testing();
