#!/usr/bin/env perl
# platform: any
# NEW ORACLE for blueprint where-things-go, package 04-continuity-threads:
# butler-continuity.pl's thread-attach semantics for `on`/`off`/`status`, per
# specs/04-continuity-threads-spec.md sections 2.3-2.7 and 3 (behaviours
# 1-18), covering done criteria 1, 2, 3 (partial), 4 (partial), 5, 6 as
# AC1-AC10, AC12, AC15, AC16 of section 4.
#
# THE THREAD-ATTACH FLAG PARSING, THE OFF DOING-GATE, THE HAND-OFF AND THE
# STATUS THREAD LINE DO NOT EXIST YET in butler-continuity.pl at the time
# this file is written. Every assertion naming R1-R13 or a thread-attach
# behaviour is expected to fail for exactly that reason: the CLI does not
# yet accept --new-thread/--thread, so `on` and `off` run exactly as they do
# today (an unknown-flag usage error, or the pre-package-04 one-liner).
#
# Almanac::Thread (package 03) and BpHook.pm (package 02) are REAL and
# unchanged by this package -- every direct library call below (create_thread,
# attach, take_over, add_task, set_task_status, record_event, archive_if_done,
# read_thread, log_entries, tasks) is called directly, ungated, per spec 2.2
# ("Fixture threads are created and attached through the library directly").
# Only the butler-continuity.pl CLI itself is run as a subprocess.
#
# Every subprocess/fixture pins HOME, USERPROFILE, ALMANAC_HOME,
# CLAUDE_CONFIG_DIR, BUTLER_STATE_DIR, CCPRAXIS_DATA_DIR and
# CLAUDE_PROJECT_DIR to fresh tempdirs (never the operator's real vault) --
# see fresh_fixture() below.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Copy qw(copy);
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep);
use Cwd ();

(my $S     = "$Bin/../../scripts") =~ s{\\}{/}g;              # plugins/butler/scripts
(my $ALM_S = "$Bin/../../../almanac/scripts") =~ s{\\}{/}g;    # plugins/almanac/scripts
my $CMD = "$S/butler-continuity.pl";

require "$S/BpHook.pm";

BEGIN {
    my $dir = "$FindBin::Bin/../../../almanac/scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}
require Almanac::Thread;
require Almanac::Store;

# ---------------------------------------------------------------------------
# process bookkeeping (house pattern, matches continuity-command-verbs.t)
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

# ---------------------------------------------------------------------------
# hygiene: HOME/USERPROFILE/ALMANAC_HOME pinned to a decoy for this whole
# file; never the operator's real vault.
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
my $DECOY_ROOT = tempdir(CLEANUP => 1);
(my $DECOY = "$DECOY_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($DECOY);
$ENV{HOME}               = $DECOY;
$ENV{USERPROFILE}        = $DECOY;
$ENV{ALMANAC_HOME}       = $DECOY;
$ENV{CCPRAXIS_DATA_DIR}  = $DECOY;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my ($PROJECT, $STATE_BASE, $CFG_DIR);

# fresh_fixture() -- a brand-new project <P>, BUTLER_STATE_DIR and
# CLAUDE_CONFIG_DIR, per the spec's "Fixtures" paragraph (section 3). Sets
# the globals spawn_cmd()/run_cmd() read, and also the ambient %ENV (for the
# in-process Thread fixture calls below, several of which resolve root via
# cwd rather than an explicit root=> when a helper doesn't pass one).
sub fresh_fixture {
    my $pt = tempdir(CLEANUP => 1);
    (my $p = "$pt/project") =~ s{\\}{/}g;
    make_path("$p/.ccpraxis-local-data");
    my $st = tempdir(CLEANUP => 1);
    (my $state = "$st/state") =~ s{\\}{/}g;
    my $ct = tempdir(CLEANUP => 1);
    (my $cfg = "$ct/config") =~ s{\\}{/}g;

    $PROJECT    = $p;
    $STATE_BASE = $state;
    $CFG_DIR    = $cfg;
    $ENV{CLAUDE_PROJECT_DIR} = $PROJECT;
    $ENV{BUTLER_STATE_DIR}   = $STATE_BASE;
    $ENV{CLAUDE_CONFIG_DIR}  = $CFG_DIR;
    return ($PROJECT, $STATE_BASE, $CFG_DIR);
}

sub state_root { return "$STATE_BASE/continuity" }

sub s8 { my ($sid) = @_; return substr($sid, 0, 8) }

# thread_pl_abs() -- <TP> per spec: Cwd::abs_path of almanac-thread.pl
# beside butler's scripts dir, forward-slashed; undef if absent.
sub thread_pl_abs {
    my $p = Cwd::abs_path("$S/../../almanac/scripts/almanac-thread.pl");
    return undef unless defined $p;
    $p =~ s{\\}{/}g;
    return $p;
}

sub slurp {
    my ($p) = @_;
    return '' unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return '';
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

my $SID_N = 0;
sub sess_id {
    my ($tag) = @_;
    my $safe = defined $tag ? $tag : '';
    $safe =~ s/[^A-Za-z0-9_-]/-/g;
    my $id = substr('s' . $safe . sha1_hex((defined $tag ? $tag : '') . rand() . time() . (++$SID_N)), 0, 24);
    die "sess_id($tag) produced an invalid session id: $id" unless $id =~ /^[A-Za-z0-9_-]{1,128}$/;
    return $id;
}

# ensure_transcript($sid, $mtime) -- thread-sessions.t's own convention,
# under THIS file's current $CFG_DIR.
sub ensure_transcript {
    my ($sid, $mtime) = @_;
    my $dir = "$CFG_DIR/projects/p";
    make_path($dir) unless -d $dir;
    my $path = "$dir/$sid.jsonl";
    open my $fh, '>', $path or die "fixture: cannot write transcript $path: $!";
    print {$fh} "{}\n";
    close $fh;
    utime($mtime, $mtime, $path) if defined $mtime;
    return $path;
}

my $TUID_N = 0;
sub next_tuid { return sprintf('tu%06x', ++$TUID_N) }

# write_ticket_argv(sid, argv, %opts) -- continuity-command-verbs.t's own
# convention.
sub write_ticket_argv {
    my ($sid, $argv, %o) = @_;
    my $tuid = $o{tuid} // next_tuid();
    my $p = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        transcript_path => $o{transcript_path} // ensure_transcript($sid, undef),
        cwd             => $o{cwd} // $PROJECT,
    };
    $p->{agent_id} = $o{agent_id} if exists $o{agent_id};
    my $ok = BpHook::write_ticket($p, 'butler-continuity', $argv,
        operator => ($o{operator} ? 1 : 0), background => ($o{background} ? 1 : 0));
    return ($ok, $tuid, $p);
}

sub find_ticket_file {
    my ($sid, $tuid) = @_;
    my $root = state_root();
    my @found = glob("$root/tickets/*/$sid.$tuid.json");
    return $found[0];
}

sub read_json_file {
    my ($p) = @_;
    my $raw = slurp($p);
    return undef unless length $raw;
    return eval { JSON::PP->new->decode($raw) };
}

# spawn_cmd / run_cmd -- the continuity-command-verbs.t house pattern,
# reading the CURRENT globals (so fresh_fixture() above must run first in
# each block).
sub spawn_cmd {
    my ($env_over, @args) = @_;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        my %eo = %$env_over;
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{BUTLER_STATE_DIR}  = $STATE_BASE;
        $ENV{CLAUDE_PROJECT_DIR} = $PROJECT;
        $ENV{CLAUDE_CONFIG_DIR}  = $CFG_DIR;
        $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
        for my $k (keys %eo) {
            if (defined $eo{$k}) { $ENV{$k} = $eo{$k} }
            else                 { delete $ENV{$k} }
        }
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec($^X, $CMD, @args);
        POSIX::_exit(127);
    }
    return ($pid, $outfile, $errfile);
}

sub wait_cmd {
    my ($pid, $outfile, $errfile, %o) = @_;
    my $deadline = time() + ($o{timeout} // 30);
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $rc = -1;
    }
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;
    return ($out, $err, $rc);
}

sub run_cmd {
    my ($env_over, @args) = @_;
    my ($pid, $o, $e) = spawn_cmd($env_over, @args);
    push @KILL_PIDS, $pid;
    my @r = wait_cmd($pid, $o, $e);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    return @r;
}

# lib(sub) -- run a direct Almanac::Thread call, reporting a die via diag
# instead of aborting this whole file (fixtures only; the library itself is
# real and expected to work).
sub lib_ok {
    my ($label, $code) = @_;
    my @r;
    my $ok = eval { @r = $code->(); 1 };
    ok($ok, "fixture: $label") or diag("died: $@");
    return @r;
}

# mark_task_done_direct($thread, $task_id, %opt) -- sets an unlinked task's
# status to 'done' via Almanac::Store directly, NOT through
# Almanac::Thread::set_task_status, so Thread.pm's own _archive_check never
# runs and the thread does not auto-archive before the CLI call under test.
# Spec section 3 behaviour 10: "unlinked `done` tasks made by direct Store
# fixture" is the prescribed way to reach an all-done-but-still-live thread.
sub mark_task_done_direct {
    my ($thread, $id, %opt) = @_;
    $opt{root} = $PROJECT unless defined $opt{root};
    my $store = Almanac::Store->open(scope => 'project', type => Almanac::Thread::tasks_type($thread), root => $opt{root});
    my $rec = $store->read($id);
    $store->update($id, expect => { rev => $rec->{rev}, fields => $rec->{fields} }, set => { status => 'done' });
}

# write_ledger($path, $status) -- a minimal blueprint package ledger with
# frontmatter `status:`, per spec section 3 behaviour 16.
sub write_ledger {
    my ($path, $status) = @_;
    (my $dir = $path) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>', $path or die "write $path: $!";
    print {$fh} "---\nstatus: $status\n---\n\n# fixture package\n";
    close $fh;
}

# ===========================================================================
# AC1: `on` without a thread arg refuses with R1, both forms named, byte-
# exact, arms nothing, writes no thread. Same for `on --role driver`.
# (behaviour 1)
# ===========================================================================
{
    my $R1 = "butler-continuity: on needs a thread: butler-continuity on --new-thread <name> starts one; "
           . "butler-continuity on --thread <name> resumes a handed-off one or takes over one whose owner is dead.\n";
    for my $case (['on', []], ['on --role driver', ['--role', 'driver']]) {
        my ($label, $extra) = @$case;
        fresh_fixture();
        my $sid = sess_id('ac1');
        write_ticket_argv($sid, ['on', @$extra]);
        my ($out, $err, $rc) = run_cmd({}, 'on', @$extra);
        is($rc, 1, "AC1 [$label]: exits 1");
        is($err, $R1, "AC1 [$label]: stderr is exactly R1, both forms named");
        is($out, '', "AC1 [$label]: stdout empty");
        ok(!-e state_root() . "/armed/$sid", "AC1 [$label]: nothing armed");
        ok(!-d "$PROJECT/.ccpraxis-local-data/almanac/thread", "AC1 [$label]: no thread store created");
    }
}

# ===========================================================================
# AC2: `on --new-thread t1` creates and attaches (behaviour 2).
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac2');
    my $tp  = ensure_transcript($sid, time());
    write_ticket_argv($sid, ['on', '--new-thread', 't1'], transcript_path => $tp);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 't1');
    is($rc, 0, 'AC2: on --new-thread t1 exits 0') or diag("stderr: $err");
    is($err, '', 'AC2: stderr empty');

    my $TP = thread_pl_abs();
    my $expect = "continuity on for session " . s8($sid) . " (role manual, thread t1).\n"
               . "Thread t1 created and attached to this session.\n"
               . "Chart thread t1 now: add a task for each step still ahead and mark the current one doing.\n"
               . (defined $TP ? "  perl \"$TP\" show t1 | add t1 --title '<step>' | status t1 <id> doing|blocked|done\n" : '');
    is($out, $expect, 'AC2: stdout is exactly the 2.4.3 "created" shape');

    my $th = eval { Almanac::Thread::read_thread('t1', root => $PROJECT) };
    ok(!$@, 'AC2: read_thread(t1) succeeds') or diag($@);
    SKIP: {
        skip 'AC2: read_thread failed, cannot inspect fields', 4 unless ref $th eq 'HASH';
        is($th->{state}, 'live', 'AC2: state is live');
        is($th->{owner_kind}, 'session', 'AC2: owner_kind is session');
        is($th->{owner_id}, $sid, 'AC2: owner_id is the calling session');
        (my $tp_folded = $tp) =~ s{\\}{/}g;
        is($th->{owner_transcript}, $tp_folded, 'AC2: owner_transcript is the folded transcript path');
    }
    my $log = eval { Almanac::Thread::log_entries('t1', root => $PROJECT) };
    is(ref $log eq 'ARRAY' ? scalar(@$log) : -1, 1, 'AC2: exactly one log entry');
    if (ref $log eq 'ARRAY' && @$log) {
        is($log->[0]{event}, 'created', 'AC2: the one log entry is "created"');
        is($log->[0]{session}, $sid, 'AC2: the log entry session is the calling session');
        is($log->[0]{actor}, 'session', 'AC2: the log entry actor is "session"');
    }
    ok(-e state_root() . "/armed/$sid", 'AC2: the session is armed');
}

# ===========================================================================
# AC3: `on --thread` resumes a handed-off thread (behaviour 5) and is a
# no-op for its current owner (behaviour 6).
# ===========================================================================
{
    fresh_fixture();
    lib_ok('create thread h, owned by s1x', sub {
        Almanac::Thread::create_thread('h', owner_kind => 'session', owner_id => 's1x',
            actor => 'session', root => $PROJECT);
    });
    lib_ok('hand off h from s1x', sub {
        Almanac::Thread::record_event('h', 'handed-off', session => 's1x', actor => 'session',
            reason => 'first slice done', root => $PROJECT);
    });

    my $sid2 = sess_id('ac3resume');
    write_ticket_argv($sid2, ['on', '--thread', 'h']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--thread', 'h');
    is($rc, 0, 'AC3: on --thread h (handed off) exits 0 for a new owner') or diag("stderr: $err");
    like($out, qr/Thread h resumed\.\n/, 'AC3: the mode line is "Thread h resumed."');

    my $th = eval { Almanac::Thread::read_thread('h', root => $PROJECT) };
    is(ref $th eq 'HASH' ? $th->{owner_id} : undef, $sid2, 'AC3: owner is now the resuming session');
    is(ref $th eq 'HASH' ? $th->{state} : undef, 'live', 'AC3: state is live again');
    my $log = eval { Almanac::Thread::log_entries('h', root => $PROJECT) };
    if (ref $log eq 'ARRAY' && @$log) {
        is($log->[-1]{event}, 'attached', 'AC3: the last log entry is "attached"');
        is($log->[-1]{session}, $sid2, 'AC3: ...for the resuming session');
    }

    # behaviour 6: on --thread h BY ITS CURRENT OWNER -> no-op.
    my $before = slurp("$PROJECT/.ccpraxis-local-data/almanac/thread/h.md");
    write_ticket_argv($sid2, ['on', '--thread', 'h']);
    my ($out2, $err2, $rc2) = run_cmd({}, 'on', '--thread', 'h');
    is($rc2, 0, 'AC3: a second on --thread h by the SAME owner exits 0') or diag("stderr: $err2");
    like($out2, qr/Thread h is already attached to this session\.\n/,
        'AC3: the mode line is "Thread h is already attached to this session."');
    my $after = slurp("$PROJECT/.ccpraxis-local-data/almanac/thread/h.md");
    is($after, $before, 'AC3: the thread record is byte-identical after the no-op');
}

# ===========================================================================
# AC4: `on --thread` on the dead-owner fixture takes it over, logging
# taken-over with from/to/reason (behaviour 7, F12).
# ===========================================================================
{
    fresh_fixture();
    my $t_d = ensure_transcript('D', time());
    lib_ok('create thread d', sub { Almanac::Thread::create_thread('d', root => $PROJECT) });
    lib_ok('attach d to session D', sub {
        Almanac::Thread::attach('d', session => 'D', transcript => $t_d, actor => 'session', root => $PROJECT);
    });
    ok(BpHook::arm('D', role => 'manual', by => 'on'), 'AC4 fixture: BpHook::arm(D) succeeds');
    my $old = time() - 14 * 3600;   # > ARMED_SECONDS (13h): owner D reads as dead
    utime($old, $old, $t_d);

    my $sid3 = sess_id('ac4takeover');
    write_ticket_argv($sid3, ['on', '--thread', 'd']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--thread', 'd');
    is($rc, 0, 'AC4: on --thread d (dead owner) exits 0') or diag("stderr: $err");
    like($out, qr/\QThread d taken over from session:D; its owner is no longer live.\E\n/,
        'AC4: the mode line names the dead owner');

    my $th = eval { Almanac::Thread::read_thread('d', root => $PROJECT) };
    is(ref $th eq 'HASH' ? $th->{owner_id} : undef, $sid3, 'AC4: owner is now the taking-over session');
    my $log = eval { Almanac::Thread::log_entries('d', root => $PROJECT) };
    if (ref $log eq 'ARRAY' && @$log) {
        is($log->[-1]{event}, 'taken-over', 'AC4: the last log entry is "taken-over"');
        is($log->[-1]{from}, 'session:D', 'AC4: from is session:D');
        is($log->[-1]{to}, "session:$sid3", 'AC4: to is the taking-over session');
        is($log->[-1]{reason}, 'previous owner is no longer live', 'AC4: the reason is the fixed take-over reason');
        is($log->[-1]{session}, $sid3, 'AC4: the log entry session is the taking-over session');
    }
}

# ===========================================================================
# AC5: `on --thread` on the live-owner fixture is refused R11, nothing armed
# or written (behaviour 7).
# ===========================================================================
{
    fresh_fixture();
    my $t_l = ensure_transcript('L', time());
    lib_ok('create thread l', sub { Almanac::Thread::create_thread('l', root => $PROJECT) });
    lib_ok('attach l to session L', sub {
        Almanac::Thread::attach('l', session => 'L', transcript => $t_l, actor => 'session', root => $PROJECT);
    });
    ok(BpHook::arm('L', role => 'manual', by => 'on'), 'AC5 fixture: BpHook::arm(L) succeeds');
    # mtime left at "now": L stays live.

    my $before = slurp("$PROJECT/.ccpraxis-local-data/almanac/thread/l.md");
    my $sid3 = sess_id('ac5live');
    write_ticket_argv($sid3, ['on', '--thread', 'l']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--thread', 'l');
    is($rc, 1, 'AC5: on --thread l (live owner) exits 1');
    is($err, "butler-continuity: thread l belongs to session:L, which is still live; it cannot be taken over "
           . "until its owner hands it off or goes idle.\n",
        'AC5: stderr is exactly R11, naming session:L');
    ok(!-e state_root() . "/armed/$sid3", 'AC5: the taking-over session is not armed');
    my $after = slurp("$PROJECT/.ccpraxis-local-data/almanac/thread/l.md");
    is($after, $before, 'AC5: the thread record is byte-identical (nothing written)');
}

# ===========================================================================
# AC6: validation and name/state refusals R2, R3, R4, R6, R8, R9 (behaviours
# 3, 4), each byte-exact on STDERR, exit 1.
# ===========================================================================
{
    # R2: both --new-thread and --thread given.
    fresh_fixture();
    my $sid = sess_id('ac6r2');
    write_ticket_argv($sid, ['on', '--new-thread', 'a', '--thread', 'b']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'a', '--thread', 'b');
    is($rc, 1, 'AC6 R2: exits 1');
    is($err, "butler-continuity: on takes --new-thread <name> or --thread <name>, not both.\n",
        'AC6 R2: stderr is exactly R2');
}
{
    # R3: a bad thread name; the ticket is NOT consumed.
    fresh_fixture();
    my $sid = sess_id('ac6r3');
    my (undef, $tuid) = write_ticket_argv($sid, ['on', '--new-thread', 'Bad_Name']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'Bad_Name');
    is($rc, 1, 'AC6 R3: exits 1');
    is($err, "butler-continuity: a thread name is 1-64 lowercase letters, digits and hyphens, "
           . "starting with a letter or digit.\n",
        'AC6 R3: stderr is exactly R3');
    ok(defined find_ticket_file($sid, $tuid), 'AC6 R3: the ticket is NOT consumed');
}
{
    # R4: --role reporter together with a thread flag.
    fresh_fixture();
    my $sid = sess_id('ac6r4');
    write_ticket_argv($sid, ['on', '--role', 'reporter', '--thread', 'a']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--role', 'reporter', '--thread', 'a');
    is($rc, 1, 'AC6 R4: exits 1');
    is($err, "butler-continuity: a reporter only reads threads; arm it with butler-continuity on "
           . "--role reporter alone.\n",
        'AC6 R4: stderr is exactly R4');
}
{
    # R6 / R8: thread-already-exists, and this-session-already-attached.
    fresh_fixture();
    my $sid1 = sess_id('ac6r8owner');
    write_ticket_argv($sid1, ['on', '--new-thread', 't1']);
    run_cmd({}, 'on', '--new-thread', 't1');

    my $sid2 = sess_id('ac6r6other');
    write_ticket_argv($sid2, ['on', '--new-thread', 't1']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 't1');
    is($rc, 1, 'AC6 R6: a second session creating the same name exits 1');
    is($err, "butler-continuity: thread t1 already exists; resume it with butler-continuity on --thread t1\n",
        'AC6 R6: stderr is exactly R6');
    ok(!-e state_root() . "/armed/$sid2", 'AC6 R6: the second session is not armed');

    write_ticket_argv($sid1, ['on', '--new-thread', 't2']);
    my ($out2, $err2, $rc2) = run_cmd({}, 'on', '--new-thread', 't2');
    is($rc2, 1, 'AC6 R8: the ALREADY-ATTACHED session creating a new thread exits 1');
    is($err2, "butler-continuity: this session is already attached to thread t1; re-arm on it with "
            . "butler-continuity on --thread t1, or hand it off first with butler-continuity off --reason '<why>'\n",
        'AC6 R8: stderr is exactly R8, naming t1');
    my $t2 = eval { Almanac::Thread::read_thread('t2', root => $PROJECT) };
    ok($@, 'AC6 R8: thread t2 was never created (read_thread dies not_found)');
}
{
    # R9: on --thread of a thread that does not exist.
    fresh_fixture();
    my $sid = sess_id('ac6r9');
    write_ticket_argv($sid, ['on', '--thread', 'nope']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--thread', 'nope');
    is($rc, 1, 'AC6 R9: exits 1');
    is($err, "butler-continuity: no thread nope in this project; start it with butler-continuity on "
            . "--new-thread nope\n",
        'AC6 R9: stderr is exactly R9');
}

# ===========================================================================
# AC7: off with an unlinked doing task refuses R13, naming every doing task;
# linked tasks never block; nothing changes (behaviour 9).
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac7');
    write_ticket_argv($sid, ['on', '--new-thread', 't-doing']);
    run_cmd({}, 'on', '--new-thread', 't-doing');

    my $task; lib_ok('add the doing task', sub {
        $task = Almanac::Thread::add_task('t-doing', title => 'write the tests', actor => 'session', root => $PROJECT);
    });
    lib_ok('set it to doing', sub {
        Almanac::Thread::set_task_status('t-doing', $task->{id}, 'doing', actor => 'session', root => $PROJECT);
    });
    # a linked task, whatever its ledger status, never blocks (it is excluded
    # from the unlinked-only doing check).
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/01-a.md", 'pending');
    lib_ok('add a linked task (never blocks)', sub {
        Almanac::Thread::add_task('t-doing', link => 'fx/01-a', actor => 'session', root => $PROJECT);
    });

    my $before = slurp("$PROJECT/.ccpraxis-local-data/almanac/thread/t-doing.md");
    write_ticket_argv($sid, ['off', '--reason', 'stopping here now']);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--reason', 'stopping here now');
    is($rc, 1, 'AC7: off refuses while an unlinked task is doing');
    my $TP = thread_pl_abs();
    my $tail = defined $TP ? "perl \"$TP\" status t-doing $task->{id} done|pending|blocked"
                            : "almanac thread status t-doing $task->{id} done|pending|blocked";
    is($err, "butler-continuity: off refused: thread t-doing still has a task doing: $task->{id} write the tests. "
           . "Set each one done, pending or blocked first ($tail), then run off again.\n",
        'AC7: stderr is exactly R13, naming the doing task');
    ok(-e state_root() . "/armed/$sid", 'AC7: the session is still armed');
    ok(!-e state_root() . "/off/$sid", 'AC7: no off/<sid> record was written');
    my $after = slurp("$PROJECT/.ccpraxis-local-data/almanac/thread/t-doing.md");
    is($after, $before, 'AC7: the thread record is byte-identical (nothing written)');
}

# ===========================================================================
# AC8: otherwise off sets handed-off, logs the reason, lists open tasks, and
# archives an all-done thread (behaviours 8, 10, 11).
# ===========================================================================
{
    # Part 1: hand-off, not archived (one unlinked pending task left open; a
    # linked task whose ledger says "running" never appears in the listing).
    fresh_fixture();
    my $sid = sess_id('ac8handoff');
    write_ticket_argv($sid, ['on', '--new-thread', 't-hand']);
    run_cmd({}, 'on', '--new-thread', 't-hand');

    my $pending_task; lib_ok('add the pending task', sub {
        $pending_task = Almanac::Thread::add_task('t-hand', title => 'write slice 2', actor => 'session', root => $PROJECT);
    });
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/01-a.md", 'running');
    lib_ok('add the linked running task', sub {
        Almanac::Thread::add_task('t-hand', link => 'fx/01-a', actor => 'session', root => $PROJECT);
    });

    write_ticket_argv($sid, ['off', '--reason', 'first slice done']);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--reason', 'first slice done');
    is($rc, 0, 'AC8: off --reason exits 0') or diag("stderr: $err");

    my $TP = thread_pl_abs();
    my $expect = "continuity off for session " . s8($sid) . " (actor agent); reason logged.\n"
               . "Thread t-hand handed off; the reason is in its log.\n"
               . "Still open in thread t-hand; chart any that are stale now:\n"
               . "  $pending_task->{id} pending write slice 2\n"
               . (defined $TP ? "  perl \"$TP\" status t-hand <id> pending|blocked|done|obsoleted\n" : '');
    is($out, $expect, 'AC8: stdout is exactly the off line, the hand-off line, and the open-task listing');

    my $th = eval { Almanac::Thread::read_thread('t-hand', root => $PROJECT) };
    is(ref $th eq 'HASH' ? $th->{state} : undef, 'handed-off', 'AC8: thread state is handed-off');
    my $log = eval { Almanac::Thread::log_entries('t-hand', root => $PROJECT) };
    if (ref $log eq 'ARRAY' && @$log) {
        is($log->[-1]{event}, 'handed-off', 'AC8: the last log entry is "handed-off"');
        is($log->[-1]{session}, $sid, 'AC8: ...for the off-ing session');
        is($log->[-1]{actor}, 'session', 'AC8: ...with actor session');
        is($log->[-1]{reason}, 'first slice done', 'AC8: ...and the exact reason');
    }
    # AC9 (stop guard unchanged): off/<sid> carries the same fields as before
    # this package.
    my $off = read_json_file(state_root() . "/off/$sid");
    is(ref $off eq 'HASH' ? $off->{actor} : undef, 'agent', 'AC9: off/<sid> still has actor agent');
    ok(!-e state_root() . "/armed/$sid", 'AC9: the session is no longer armed');
}
{
    # Part 2: every task done -> handed off AND archived in the same call.
    fresh_fixture();
    my $sid = sess_id('ac8archive');
    write_ticket_argv($sid, ['on', '--new-thread', 't-done']);
    run_cmd({}, 'on', '--new-thread', 't-done');
    my $t; lib_ok('add a task, mark it done', sub {
        $t = Almanac::Thread::add_task('t-done', title => 'only step', actor => 'session', root => $PROJECT);
    });
    # direct Store write (spec 3 behaviour 10): avoids Thread.pm's own
    # _archive_check, which would otherwise archive the thread right here --
    # before the `off` call below is what's under test -- since this is its
    # only task.
    lib_ok('mark it done', sub {
        mark_task_done_direct('t-done', $t->{id});
    });

    write_ticket_argv($sid, ['off', '--reason', 'all done here']);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--reason', 'all done here');
    is($rc, 0, 'AC8 archive: off --reason exits 0') or diag("stderr: $err");
    is($out, "continuity off for session " . s8($sid) . " (actor agent); reason logged.\n"
           . "Thread t-done handed off and archived: all its tasks are done.\n",
        'AC8 archive: stdout is exactly the off line and the archived line');
    my $th = eval { Almanac::Thread::read_thread('t-done', root => $PROJECT) };
    is(ref $th eq 'HASH' ? $th->{state} : undef, 'archived', 'AC8 archive: state is archived');
    my $log = eval { Almanac::Thread::log_entries('t-done', root => $PROJECT) };
    is(ref $log eq 'ARRAY' && @$log ? $log->[-1]{event} : undef, 'archived',
        'AC8 archive: the log ends "archived"');
}
{
    # behaviour 11: off with no attached thread -> exactly the existing off
    # line; a 201-byte reason refuses R10, still armed.
    fresh_fixture();
    my $sid = sess_id('ac8nothread');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC8 (no thread) setup: armed directly');
    write_ticket_argv($sid, ['off', '--reason', 'nothing to hand off']);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--reason', 'nothing to hand off');
    is($rc, 0, 'AC8 (no thread): off --reason exits 0');
    is($out, "continuity off for session " . s8($sid) . " (actor agent); reason logged.\n",
        'AC8 (no thread): stdout is exactly the existing off line');

    fresh_fixture();
    my $sid2 = sess_id('ac8r10');
    ok(BpHook::arm($sid2, role => 'manual', by => 'on'), 'AC8 R10 setup: armed directly');
    my $long_reason = join(' ', ('word') x 50);   # 50 words, 249 bytes: passes the existing two-word check, fails R10
    write_ticket_argv($sid2, ['off', '--reason', $long_reason]);
    my ($out2, $err2, $rc2) = run_cmd({}, 'off', '--reason', $long_reason);
    is($rc2, 1, 'AC8 R10: a 201-byte reason refuses');
    is($err2, "butler-continuity: --reason is at most 200 bytes; it goes into the thread log.\n",
        'AC8 R10: stderr is exactly R10');
    ok(-e state_root() . "/armed/$sid2", 'AC8 R10: still armed');
}

# ===========================================================================
# AC10: a BP_LEDGER coordinator and --role reporter arm with no thread
# (behaviour 12).
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac10coord');
    write_ticket_argv($sid, ['on']);
    my ($out, $err, $rc) = run_cmd({ BP_LEDGER => '/x/ledger.md' }, 'on');
    is($rc, 0, 'AC10: a BP_LEDGER coordinator on exits 0');
    like($out, qr/nothing to do/, 'AC10: ...with the by-construction line');
    ok(!-d "$PROJECT/.ccpraxis-local-data/almanac/thread", 'AC10: no thread store was created');
}
{
    fresh_fixture();
    my $sid = sess_id('ac10reporter');
    write_ticket_argv($sid, ['on', '--role', 'reporter']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--role', 'reporter');
    is($rc, 0, 'AC10: on --role reporter exits 0') or diag("stderr: $err");
    is($out, "continuity on for session " . s8($sid) . " (role reporter).\n",
        'AC10: stdout is exactly the one-liner, no thread, no chart line');
    ok(-e state_root() . "/armed/$sid", 'AC10: the reporter session is armed');
    my $armed = read_json_file(state_root() . "/armed/$sid");
    is(ref $armed eq 'HASH' ? $armed->{role} : undef, 'reporter', 'AC10: armed role is reporter');

    write_ticket_argv($sid, ['status']);
    my ($sout, $serr, $src) = run_cmd({}, 'status');
    is($src, 0, 'AC10: status for the reporter session exits 0');
    my @lines = split /\n/, $sout;
    ok((grep { $_ eq 'thread: none' } @lines), 'AC10: status prints "thread: none" for the reporter session');
}

# ===========================================================================
# AC12: status's thread: line -- format, position, "none", bar arithmetic
# (behaviour 13).
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac12');
    write_ticket_argv($sid, ['on', '--new-thread', 't-status']);
    run_cmd({}, 'on', '--new-thread', 't-status');

    my $done_task; lib_ok('add unlinked done task', sub {
        $done_task = Almanac::Thread::add_task('t-status', title => 'finished', actor => 'session', root => $PROJECT);
    });
    # direct Store write (spec 3 behaviour 10): avoids Thread.pm's own
    # _archive_check, which would otherwise archive the thread right here --
    # it is the only task at this point -- before the remaining tasks below
    # are added.
    lib_ok('mark it done', sub {
        mark_task_done_direct('t-status', $done_task->{id});
    });
    lib_ok('add unlinked doing task "draft"', sub {
        my $t = Almanac::Thread::add_task('t-status', title => 'draft', actor => 'session', root => $PROJECT);
        Almanac::Thread::set_task_status('t-status', $t->{id}, 'doing', actor => 'session', root => $PROJECT);
    });
    lib_ok('add unlinked doing task "review"', sub {
        my $t = Almanac::Thread::add_task('t-status', title => 'review', actor => 'session', root => $PROJECT);
        Almanac::Thread::set_task_status('t-status', $t->{id}, 'doing', actor => 'session', root => $PROJECT);
    });
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/bp/packages/02-x.md", 'pending');
    lib_ok('add linked pending task bp/02-x', sub {
        Almanac::Thread::add_task('t-status', link => 'bp/02-x', actor => 'session', root => $PROJECT);
    });

    write_ticket_argv($sid, ['status']);
    my ($out, $err, $rc) = run_cmd({}, 'status');
    is($rc, 0, 'AC12: status exits 0') or diag("stderr: $err");
    my @lines = split /\n/, $out;
    my ($thread_line) = grep { /^thread: / } @lines;
    # the bar glyphs (U+25B0 full / U+25B1 empty) as raw UTF-8 bytes -- $out
    # was read ':raw', so it holds bytes, never decoded wide characters.
    my $FULL  = "\xe2\x96\xb0";
    my $EMPTY = "\xe2\x96\xb1";
    my $bar = ($FULL x 2) . ($EMPTY x 8);   # f = int(1*10/4) = 2
    is($thread_line, "thread: t-status $bar 1/4  doing: draft (+1)  next: bp/02-x",
        'AC12: the thread line matches name, bar (f=2), 1/4, doing (+1), next') or diag(defined $thread_line ? $thread_line : '(no thread: line found)');

    # Not attached -> "thread: none".
    my $sid2 = sess_id('ac12none');
    write_ticket_argv($sid2, ['status']);
    my ($out2, $err2, $rc2) = run_cmd({}, 'status');
    my @lines2 = split /\n/, $out2;
    ok((grep { $_ eq 'thread: none' } @lines2), 'AC12: an unattached session shows "thread: none"');
}

# ===========================================================================
# AC15: archive-if-done archives a fixture thread whose linked packages are
# all done or dropped, but not one still parked (behaviour 16, F13); the
# drive-solo done row runs archive-if-done before turning continuity off
# (behaviour 17).
# ===========================================================================
{
    fresh_fixture();
    lib_ok('create thread arch', sub { Almanac::Thread::create_thread('arch', root => $PROJECT) });
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/01-a.md", 'pending');
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/02-b.md", 'pending');
    lib_ok('link fx/01-a', sub { Almanac::Thread::add_task('arch', link => 'fx/01-a', root => $PROJECT) });
    lib_ok('link fx/02-b', sub { Almanac::Thread::add_task('arch', link => 'fx/02-b', root => $PROJECT) });

    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/01-a.md", 'done');
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/02-b.md", 'dropped');
    my ($th, $changed) = eval { Almanac::Thread::archive_if_done('arch', root => $PROJECT) };
    ok(!$@, 'AC15: archive_if_done(arch) does not die') or diag($@);
    is($changed, 1, 'AC15: archive_if_done reports changed=1 when done+dropped');
    is(ref $th eq 'HASH' ? $th->{state} : undef, 'archived', 'AC15: thread state is archived');
    my $log = eval { Almanac::Thread::log_entries('arch', root => $PROJECT) };
    is(ref $log eq 'ARRAY' && @$log ? $log->[-1]{event} : undef, 'archived', 'AC15: the log ends "archived"');

    # the negative control: 04-d parked instead of done/dropped -> no change.
    # Both ledgers start "pending" so linking does not auto-archive the
    # thread (add_task's own archive check) before the second link lands --
    # the same two-step shape the "arch" fixture above already uses.
    lib_ok('create thread noarch', sub { Almanac::Thread::create_thread('noarch', root => $PROJECT) });
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/03-c.md", 'pending');
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/04-d.md", 'pending');
    lib_ok('link fx/03-c', sub { Almanac::Thread::add_task('noarch', link => 'fx/03-c', root => $PROJECT) });
    lib_ok('link fx/04-d', sub { Almanac::Thread::add_task('noarch', link => 'fx/04-d', root => $PROJECT) });
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/03-c.md", 'done');
    write_ledger("$PROJECT/.ccpraxis-local-data/blueprints/fx/packages/04-d.md", 'parked');
    my ($th2, $changed2) = eval { Almanac::Thread::archive_if_done('noarch', root => $PROJECT) };
    is($changed2, 0, 'AC15: a still-parked linked task leaves changed=0');
    is(ref $th2 eq 'HASH' ? $th2->{state} : undef, 'live', 'AC15: thread stays live');
}
{
    my $skill = "$Bin/../../skills/drive-solo/SKILL.md";
    my $next  = "$Bin/../../skills/drive-solo/SKILL.next.md";
    my $target = -e $next ? $next : $skill;
    my $text = slurp($target);
    my @lines = split /\n/, $text;
    my @done_rows = grep { /^\|\s*`done`\s*\|/ } @lines;
    is(scalar(@done_rows), 1, 'AC15: exactly one drive-solo row matches /^\|\s*`done`\s*\|/');
    SKIP: {
        skip 'AC15: no done row to inspect', 2 unless @done_rows == 1;
        my $row = $done_rows[0];
        my $archive_idx    = index($row, 'almanac thread archive-if-done');
        my $continuity_idx = index($row, 'turn continuity off');
        ok($archive_idx >= 0, 'AC15: the done row names "almanac thread archive-if-done"');
        ok($archive_idx >= 0 && $continuity_idx >= 0 && $archive_idx < $continuity_idx,
            'AC15: archive-if-done is run BEFORE "turn continuity off" in the same row');
    }
}

# ===========================================================================
# AC16: an almanac-absent butler copy arms without a thread (behaviour 15);
# the subagent refusal precedes any thread write (behaviour 14).
# ===========================================================================
{
    # copy_tree -- same convention as continuity-command-verbs.t's AC-31.
    sub copy_tree_ct {
        my ($src, $dst) = @_;
        return unless -d $src;
        make_path($dst);
        my @stack = ('');
        while (@stack) {
            my $rel = pop @stack;
            my $sdir = length($rel) ? "$src/$rel" : $src;
            opendir(my $dh, $sdir) or next;
            my @entries = readdir($dh);
            closedir $dh;
            for my $e (@entries) {
                next if $e eq '.' || $e eq '..';
                my $srel = length($rel) ? "$rel/$e" : $e;
                my $sp = "$src/$srel";
                my $dp = "$dst/$srel";
                if (-d $sp) { make_path($dp); push @stack, $srel }
                else {
                    (my $ddir = $dp) =~ s{/[^/]+$}{};
                    make_path($ddir) if length $ddir;
                    copy($sp, $dp);
                }
            }
        }
    }
    my $iso_root = tempdir(CLEANUP => 1);
    (my $iso = "$iso_root/butler") =~ s{\\}{/}g;
    copy_tree_ct("$S", "$iso/scripts");
    ok(-f "$iso/scripts/butler-continuity.pl", 'AC16 fixture: the isolated copy carries butler-continuity.pl');
    ok(!-e "$iso_root/almanac", 'AC16 fixture: the isolated copy has no sibling almanac/ directory');

    fresh_fixture();
    my $sid = sess_id('ac16noalm');
    write_ticket_argv($sid, ['on']);

    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec($^X, "$iso/scripts/butler-continuity.pl", 'on');
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    my ($out, $err, $rc) = wait_cmd($pid, $outfile, $errfile);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    is($rc, 0, 'AC16: on (no sibling almanac) exits 0') or diag("stderr: $err");
    is($out, "continuity on for session " . s8($sid) . " (role manual).\n",
        'AC16: on (no sibling almanac) prints exactly the thread-free one-liner');
}
{
    # behaviour 14: a subagent ticket for `on --new-thread t9` -> the
    # existing subagent refusal, thread t9 not created.
    fresh_fixture();
    my $sid = sess_id('ac16subagent');
    write_ticket_argv($sid, ['on', '--new-thread', 't9'], agent_id => 'sub1');
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 't9');
    is($rc, 1, 'AC16: a subagent ticket for on --new-thread t9 refuses');
    like($err, qr/subagent/, 'AC16: the refusal names a subagent');
    my $t9 = eval { Almanac::Thread::read_thread('t9', root => $PROJECT) };
    ok($@, 'AC16: thread t9 was never created');
}

# ===========================================================================
# M1 (Decision 38 fix-batch): R13's <TP> must come out byte-correct when the
# plugin install path itself contains a non-ASCII character. review-1.md's
# M1: task titles come back UTF8-flagged from Almanac::Thread while $TP is
# raw bytes from Cwd::abs_path; concatenating the two in one refuse() string
# upgrades $TP's high-bit bytes as Latin-1, which _bytes() then double-
# encodes. Reproduced here (not just on the ASCII clone path AC7 uses) by
# running an ISOLATED COPY of both butler/scripts and almanac/scripts under a
# tempdir whose own path contains "caf\xc3\xa9" (UTF-8 bytes for "café"),
# same isolated-copy idiom as AC16's copy_tree_ct, so <TP> itself is
# non-ASCII rather than the project cwd (which is what the implementer's
# earlier probe varied, per review-1.md's "why the tests miss it").
# ===========================================================================
{
    my $iso_root = tempdir(CLEANUP => 1);
    (my $iso = "$iso_root/caf\xc3\xa9/plugins") =~ s{\\}{/}g;
    copy_tree_ct("$S", "$iso/butler/scripts");
    copy_tree_ct("$ALM_S", "$iso/almanac/scripts");
    my $iso_cmd = "$iso/butler/scripts/butler-continuity.pl";
    ok(-f $iso_cmd, 'M1 fixture: the isolated non-ASCII-path copy carries butler-continuity.pl');
    my $iso_thread_pl = Cwd::abs_path("$iso/almanac/scripts/almanac-thread.pl");
    ok(defined $iso_thread_pl && -f $iso_thread_pl, 'M1 fixture: the isolated copy carries almanac-thread.pl');
    $iso_thread_pl =~ s{\\}{/}g;
    like($iso_thread_pl, qr/caf\xc3\xa9/, 'M1 fixture: the isolated install path really does contain the non-ASCII bytes')
        or diag("resolved TP: " . unpack('H*', $iso_thread_pl));

    # run_iso_cmd($argv) -- spawn_cmd()/run_cmd(), but against $iso_cmd
    # instead of the file-global $CMD (house pattern: AC16's inline fork).
    my $run_iso = sub {
        my (@args) = @_;
        my (undef, $outfile) = tempfile();
        my (undef, $errfile) = tempfile();
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            open(STDOUT, '>', $outfile) or POSIX::_exit(126);
            open(STDERR, '>', $errfile) or POSIX::_exit(126);
            exec($^X, $iso_cmd, @args);
            POSIX::_exit(127);
        }
        push @KILL_PIDS, $pid;
        my @r = wait_cmd($pid, $outfile, $errfile);
        @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
        return @r;
    };

    fresh_fixture();
    my $sid = sess_id('m1nonascii');
    write_ticket_argv($sid, ['on', '--new-thread', 't-m1']);
    my ($oon, $eon, $rcon) = $run_iso->('on', '--new-thread', 't-m1');
    is($rcon, 0, 'M1: on --new-thread via the non-ASCII-path copy exits 0') or diag("stderr: $eon");

    my $task; lib_ok('M1 fixture: add the doing task', sub {
        $task = Almanac::Thread::add_task('t-m1', title => 'write the garbled-path test', actor => 'session', root => $PROJECT);
    });
    lib_ok('M1 fixture: set it to doing', sub {
        Almanac::Thread::set_task_status('t-m1', $task->{id}, 'doing', actor => 'session', root => $PROJECT);
    });

    write_ticket_argv($sid, ['off', '--reason', 'stopping here now']);
    my ($ooff, $eoff, $rcoff) = $run_iso->('off', '--reason', 'stopping here now');
    is($rcoff, 1, 'M1: off via the non-ASCII-path copy still refuses R13 while the task is doing');

    my $expect = "butler-continuity: off refused: thread t-m1 still has a task doing: $task->{id} write the "
               . "garbled-path test. Set each one done, pending or blocked first (perl \"$iso_thread_pl\" status "
               . "t-m1 $task->{id} done|pending|blocked), then run off again.\n";
    is($eoff, $expect, 'M1: R13 is byte-exact, including a byte-correct (not mis-encoded) non-ASCII <TP>')
        or diag('got: ' . unpack('H*', $eoff) . "\nwant: " . unpack('H*', $expect));

    # Defense-in-depth per the review's diagnosis: the double-encoding
    # signature is \xc3\x83 (an upgraded-then-re-encoded 0xc3 byte). A
    # byte-correct "é" is \xc3\xa9 and must never produce that signature.
    unlike($eoff, qr/\xc3\x83/, "M1: no mojibake double-encoding signature (\\xc3\\x83) in R13's stderr bytes");
}

# ===========================================================================
# S1 (Decision 38 fix-batch): a store error anywhere in the project's thread
# directory must not be swallowed into a silent "not attached". Both
# reviewers found Almanac::Thread::attached_thread/list_threads map ANY
# Store error to undef/empty rather than surfacing it, which lets `status`
# print "thread: none" instead of "unknown", lets `off` skip both the doing
# gate (R13) and the hand-off with no warning at all, and lets `on
# --new-thread` bypass the "already attached" (R8) check. Fixture: one
# legitimately-attached thread with a doing unlinked task, plus one
# unparseable record written DIRECTLY into the store directory (bypassing
# Almanac::Thread/Store's own writer entirely -- raw bytes, no frontmatter),
# same as redteam-1.md's reproduction ("a junk file thread/zzz.md appears").
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('s1corrupt');
    write_ticket_argv($sid, ['on', '--new-thread', 't-legit']);
    run_cmd({}, 'on', '--new-thread', 't-legit');

    my $task; lib_ok('S1 fixture: add the doing task on t-legit', sub {
        $task = Almanac::Thread::add_task('t-legit', title => 'in progress work', actor => 'session', root => $PROJECT);
    });
    lib_ok('S1 fixture: set it to doing', sub {
        Almanac::Thread::set_task_status('t-legit', $task->{id}, 'doing', actor => 'session', root => $PROJECT);
    });

    my $thread_dir = "$PROJECT/.ccpraxis-local-data/almanac/thread";
    ok(-d $thread_dir, 'S1 fixture: the thread store directory exists before corruption');
    my $corrupt_path = "$thread_dir/zzz.md";
    open my $cfh, '>:raw', $corrupt_path or die "S1 fixture: cannot write corrupt record $corrupt_path: $!";
    print {$cfh} "this is not a valid almanac record: no frontmatter, no fields, just garbage\n";
    close $cfh;
    ok(-f $corrupt_path, 'S1 fixture: the corrupt sibling record file exists');

    # --- S1a: status must say "unknown", never "none", once the store
    # cannot be listed cleanly (spec 2.6: "any die below -> unknown"). ---
    write_ticket_argv($sid, ['status']);
    my ($sout, $serr, $src) = run_cmd({}, 'status');
    is($src, 0, 'S1a: status still exits 0 with a corrupted sibling record present') or diag("stderr: $serr");
    my @slines = split /\n/, $sout;
    ok((grep { $_ eq 'thread: unknown' } @slines),
        'S1a: status prints "thread: unknown" (not "thread: none") when the store cannot be listed')
        or diag("stdout: $sout");
    ok(!(grep { $_ eq 'thread: none' } @slines),
        'S1a: status does NOT print "thread: none" while the attached thread cannot be confirmed');

    # --- S1c (run BEFORE off, which disarms the session regardless of
    # outcome): the one-thread-per-session check (R8) must still refuse a
    # second `on --new-thread`, even though attached_thread cannot
    # positively confirm t-legit while the store errors. Run before S1b so
    # the session is still armed+attached when this is exercised. ---
    write_ticket_argv($sid, ['on', '--new-thread', 't-second']);
    my ($o3, $e3, $rc3) = run_cmd({}, 'on', '--new-thread', 't-second');
    is($rc3, 1, 'S1c: on --new-thread t-second is refused -- not silently allowed -- '
              . 'when the already-attached check cannot be confirmed cleanly')
        or diag("stdout: $o3 / stderr: $e3");
    my $t_second = eval { Almanac::Thread::read_thread('t-second', root => $PROJECT) };
    ok($@, 'S1c: thread t-second was never created');

    # --- S1b: off must not be a silent, signal-free no-op. It may refuse
    # (R13-shaped, since the hidden thread still has a doing task) or
    # disarm-with-warning, but current behaviour -- exit 0, empty stdout
    # extras, empty stderr, thread left live+owned with its doing task
    # untouched -- is exactly the silent bypass both reviewers flagged. ---
    my $before = slurp("$thread_dir/t-legit.md");
    write_ticket_argv($sid, ['off', '--reason', 'stopping with a corrupt sibling present']);
    my ($o2, $e2, $rc2) = run_cmd({}, 'off', '--reason', 'stopping with a corrupt sibling present');
    ok($rc2 != 0 || $e2 =~ /\S/,
        'S1b: off is not a silent no-op (refuses, or warns on stderr) when the thread store cannot be listed')
        or diag("rc=$rc2 stdout=$o2 stderr=$e2");
    my $after = slurp("$thread_dir/t-legit.md");
    if ($rc2 == 0 && $e2 !~ /\S/) {
        is($after, $before, 'S1b (diagnostic): with no signal at all, the thread record was at least left untouched');
    }
}

done_testing();
