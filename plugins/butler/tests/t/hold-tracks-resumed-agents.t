#!/usr/bin/env perl
# platform: any
# ORACLE for package 38-silence-cannot-bypass-live-work (blueprint
# hook-continuity-remake), holder half: AC-1..AC-11 and AC-24 of
# specs/38-silence-cannot-bypass-live-work-spec.md, plus Decision 129's
# settled open question 2 (a resumed agent's completion arrives as a NEW
# notification under its original task id).
#
# The bug (20260926-101917-85c6): butler-hold judged a held subagent by the
# last <status> after its <task-id> in the parent transcript. A SendMessage
# resume writes no notification, only a `"resumedAgentId":"<id>"` tool
# result, so a stale `stopped` stayed the latest status and every resumed id
# was pruned on the first tick while its transcript was still growing.
#
# Derived from the spec, never from butler-hold.pl. Every holder run is a
# real subprocess through `bash plugins/butler/bin/butler-hold` with
# BUTLER_HOLD_TEST_MODE=1 and BUTLER_HOLD_TEST_TICK=0.2 (QUIET = 0.4 s), as
# continuity-holder.t does. Transcripts, subagents/ files and .output files
# are synthetic, under File::Temp dirs; BUTLER_STATE_DIR is an absolute temp
# dir and HOME/USERPROFILE are decoys. The transcript lines copy the shapes
# the harness really writes (a queue-operation notification with JSON-escaped
# newlines; a tool_result whose text carries the escaped resume marker and a
# toolUseResult carrying the plain one).
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP ();
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);

my $S      = "$Bin/../../scripts"; $S   =~ s{\\}{/}g;
my $BIN    = "$Bin/../../bin";     $BIN =~ s{\\}{/}g;
my $SCRIPT = "$S/butler-hold.pl";
my $SHIM   = "$BIN/butler-hold";

require "$S/BpHook.pm";

my $TICK = 0.2;

# ---------------------------------------------------------------------------
# process bookkeeping
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
# environment: decoy HOME, temp state root, real-state guard (AC-11)
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;

my ($REAL_BSTATE, $REAL_BSTATE_EXISTS, $REAL_BSTATE_MTIME);
{
    my $rh = (defined $ENV{HOME} && length $ENV{HOME}) ? $ENV{HOME}
           : (defined $ENV{USERPROFILE} && length $ENV{USERPROFILE}) ? $ENV{USERPROFILE}
           : undef;
    if (defined $rh) {
        (my $rhn = $rh) =~ s{\\}{/}g;
        $REAL_BSTATE        = "$rhn/.claude/butler-state";
        $REAL_BSTATE_EXISTS = -d $REAL_BSTATE ? 1 : 0;
        $REAL_BSTATE_MTIME  = $REAL_BSTATE_EXISTS ? (stat($REAL_BSTATE))[9] : undef;
    }
}

my $TMPROOT = tempdir(CLEANUP => 1); $TMPROOT =~ s{\\}{/}g;
(my $PROJECT   = "$TMPROOT/proj")        =~ s{\\}{/}g;
(my $STATE_DIR = "$TMPROOT/state")       =~ s{\\}{/}g;
(my $FAKE_HOME = "$TMPROOT/decoy-home")  =~ s{\\}{/}g;
make_path($PROJECT, $FAKE_HOME);
$ENV{HOME}                  = $FAKE_HOME;
$ENV{USERPROFILE}           = $FAKE_HOME;
$ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
$ENV{BUTLER_HOLD_TEST_MODE} = 1;
# never-halt 06 (AC-19): a fixture, never-existing data root, so
# butler-hold's prompt-watch resolution (BpDataRoot::resolve) is exercised
# hermetically and stays OFF (no real .ccpraxis-local-data is ever touched),
# leaving this file's own assertions unchanged.
$ENV{CCPRAXIS_DATA_DIR}     = "$TMPROOT/no-prompt-watch-data";

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------
sub iso_of {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
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

sub lines_of {
    my ($text) = @_;
    my @l = split /\n/, $text;
    pop @l while @l && $l[-1] eq '';
    return @l;
}

my $TUID_N = 0;
sub next_tuid { return sprintf('tu38h%05x', ++$TUID_N) }

sub transcript_path_for { my ($sid) = @_; return "$PROJECT/$sid.jsonl" }
sub sessiondir_for      { my ($sid) = @_; return "$PROJECT/$sid" }

sub write_ticket_for {
    my ($sid, $argv) = @_;
    my $p = {
        session_id      => $sid,
        tool_use_id     => next_tuid(),
        transcript_path => transcript_path_for($sid),
        cwd             => $PROJECT,
    };
    return BpHook::write_ticket($p, 'butler-hold', $argv, operator => 0, background => 1);
}

sub spawn_hold {
    my ($argv, $seconds) = @_;
    my (undef, $outfile) = tempfile(DIR => $TMPROOT);
    my (undef, $errfile) = tempfile(DIR => $TMPROOT);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{HOME}                     = $FAKE_HOME;
        $ENV{USERPROFILE}              = $FAKE_HOME;
        $ENV{BUTLER_STATE_DIR}         = $STATE_DIR;
        $ENV{BUTLER_HOLD_TEST_MODE}    = 1;
        $ENV{BUTLER_HOLD_TEST_TICK}    = $TICK;
        $ENV{BUTLER_HOLD_TEST_SECONDS} = $seconds;
        $ENV{CCPRAXIS_NO_WAKELOCK}     = 1;
        $ENV{CCPRAXIS_DATA_DIR}        = "$TMPROOT/no-prompt-watch-data";
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        { no warnings q(exec); exec(q(bash), $SHIM, @$argv); }
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    return ($pid, $outfile, $errfile);
}

# poll_exit(pid) -> rc or undef (still running), never blocks.
# A reaped child's rc is cached, so a later wait_pid_bounded() on the same pid
# reports it instead of -1.
my %REAPED;
sub poll_exit {
    my ($pid) = @_;
    return $REAPED{$pid} if exists $REAPED{$pid};
    my $w = waitpid($pid, WNOHANG);
    return undef unless $w == $pid;
    $REAPED{$pid} = $? >> 8;
    return $REAPED{$pid};
}

sub wait_pid_bounded {
    my ($pid, $timeout) = @_;
    my $deadline = time() + $timeout;
    my $rc;
    while (time() < $deadline) {
        $rc = poll_exit($pid);
        last if defined $rc;
        sleep(0.05);
    }
    unless (defined $rc) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $rc = -1;
    }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    return $rc;
}

sub wait_for_holder {
    my ($sid, $timeout) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        my $h = BpHook::holder($sid);
        return $h if ref $h eq 'HASH';
        sleep(0.02);
    }
    return undef;
}

my %STDERR_LOG;

# finish(label, pid, out, err, timeout) -> (out, err, rc)
sub finish {
    my ($label, $pid, $outfile, $errfile, $timeout) = @_;
    my $rc  = wait_pid_bounded($pid, $timeout);
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;
    $STDERR_LOG{$label} = $err;
    return ($out, $err, $rc);
}

sub append_file {
    my ($path, $text) = @_;
    make_path(dirname($path));
    open my $fh, '>>:raw', $path or die "append $path: $!";
    print {$fh} $text;
    close $fh;
}

sub write_file {
    my ($path, $text, $mtime) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "write $path: $!";
    print {$fh} $text;
    close $fh;
    utime($mtime, $mtime, $path) if defined $mtime;
    return $path;
}

# write_agent(sid, id, mtime) -- subagents/agent-<id>.jsonl + .meta.json,
# both stamped with mtime (defaults to now: a fresh file).
sub write_agent {
    my ($sid, $id, $mtime) = @_;
    my $dir = sessiondir_for($sid) . '/subagents';
    my $jsonl = write_file("$dir/agent-$id.jsonl",
        qq({"type":"user","isSidechain":true,"agentId":"$id","message":{"role":"user","content":"go"}}\n), $mtime);
    write_file("$dir/agent-$id.meta.json", qq({"agentType":"general-purpose","description":"worker $id"}\n), $mtime);
    return $jsonl;
}

my $AGENT_LINE_N = 0;
sub agent_progress_line {
    my ($id) = @_;
    $AGENT_LINE_N++;
    return qq({"type":"assistant","isSidechain":true,"agentId":"$id","message":{"role":"assistant","content":[{"type":"text","text":"step $AGENT_LINE_N"}]}}\n);
}

my $JSON = JSON::PP->new->utf8->canonical;

# notif_line(\@ids, status) -- one queue-operation record, exactly the shape
# of the incident's line 28002: every id's <task-id>, then ONE <status>.
sub notif_line {
    my ($ids, $status, %o) = @_;
    my $content = "<task-notification>\n";
    $content .= "<task-id>$_</task-id>\n" for @$ids;
    $content .= "<tool-use-id>$o{tool_use_id}</tool-use-id>\n" if defined $o{tool_use_id};
    $content .= "<status>$status</status>\n";
    if ($status eq 'stopped') {
        $content .= "<summary>" . scalar(@$ids) . " background agents didn't finish before the previous session ended.</summary>\n"
                  . "<note>No completion record was found for them in the previous session. Resume any of them by sending a message to its id with SendMessage.</note>\n";
    }
    else {
        $content .= "<summary>Agent \"worker\" finished</summary>\n"
                  . "<note>A task-notification fires each time this agent stops with no live background children of its own. "
                  . "The user can send it another message and resume it, so the same task-id may notify more than once.</note>\n";
    }
    $content .= "</task-notification>";
    return $JSON->encode({
        type      => 'queue-operation',
        operation => 'enqueue',
        timestamp => iso_of(time()),
        sessionId => 'synthetic',
        content   => $content,
    }) . "\n";
}

# The resume tool result. form: 'plain' (toolUseResult only), 'escaped'
# (tool_result text only), 'both' (exactly the incident's line 28386).
sub resume_line {
    my ($id, $form) = @_;
    my $inner = { success => JSON::PP::true(), message => "Resuming agent " . substr($id, 0, 7),
                  resumedAgentId => $id };
    my $text = ($form eq 'plain')
        ? 'Resumed.'
        : JSON::PP->new->canonical->encode($inner);
    my $rec = {
        type    => 'user',
        isSidechain => JSON::PP::false(),
        message => { role => 'user', content => [ { tool_use_id => 'toolu_resume', type => 'tool_result',
                        content => [ { type => 'text', text => $text } ] } ] },
    };
    $rec->{toolUseResult} = $inner if $form ne 'escaped';
    return $JSON->encode($rec) . "\n";
}

sub filler_line {
    my ($n) = @_;
    return $JSON->encode({ type => 'assistant', message => { role => 'assistant',
        content => [ { type => 'text', text => "unrelated line $n" } ] } }) . "\n";
}

# (?m:^) -- the anchor must stay line-anchored when this is interpolated into
# a pattern matched against the whole multi-line stdout.
my $HOLD_LINE_RE = qr/(?m:^)\d\d:\d\d \(\d\d:\d\dZ\) /;
sub finished_re { my ($id) = @_; return qr/^\d\d:\d\d \(\d\d:\d\dZ\) finished: \Q$id\E;/m }

my $sidn = 0;
sub next_sid { return sprintf('hold38-%04x-%s', ++$sidn, substr(sprintf('%x', int(time() * 1000)), -6)) }

# ===========================================================================
# AC-1 (DC1) -- stopped, then a plain-form resume; quiet file -> never pruned.
# ===========================================================================
{
    my $sid = next_sid();
    my $X   = 'a1f0000000000001a';
    my $old = int(time()) - 600;
    write_agent($sid, $X, $old);
    write_file(transcript_path_for($sid), notif_line([$X], 'stopped') . filler_line(1) . resume_line($X, 'plain'));
    write_ticket_for($sid, [$X]);
    my ($pid, $o, $e) = spawn_hold([$X], 2);
    my ($out, $err, $rc) = finish('AC-1', $pid, $o, $e, 20);
    my @l = lines_of($out);
    is($rc, 0, 'AC-1: the holder exits 0');
    unlike($out, finished_re($X), 'AC-1: no "finished: X" line -- a resume after a stopped notification is live');
    like($l[-2] // '', qr/${HOLD_LINE_RE}released: deadline reached$/, 'AC-1: second-to-last line is "released: deadline reached"')
        or diag("stdout:\n$out");
    is($l[-1] // '', "$X still running (last activity @{[iso_of($old)]})",
        'AC-1: last line is "X still running (last activity <iso(now-600)>)"');
}

# ===========================================================================
# AC-2 (DC1) -- as AC-1 with only the JSON-escaped resume form.
# ===========================================================================
{
    my $sid = next_sid();
    my $X   = 'a2f0000000000002b';
    my $old = int(time()) - 600;
    write_agent($sid, $X, $old);
    my $resume = resume_line($X, 'escaped');
    ok(index($resume, qq(\\"resumedAgentId\\":\\"$X\\")) >= 0 && index($resume, qq("resumedAgentId":"$X")) < 0,
        'AC-2: fixture sanity -- the resume line carries ONLY the escaped form');
    write_file(transcript_path_for($sid), notif_line([$X], 'stopped') . $resume);
    write_ticket_for($sid, [$X]);
    my ($pid, $o, $e) = spawn_hold([$X], 2);
    my ($out, $err, $rc) = finish('AC-2', $pid, $o, $e, 20);
    my @l = lines_of($out);
    is($rc, 0, 'AC-2: exit 0');
    unlike($out, finished_re($X), 'AC-2: no "finished: X" line with only the escaped resume form');
    like($l[-2] // '', qr/${HOLD_LINE_RE}released: deadline reached$/, 'AC-2: released: deadline reached')
        or diag("stdout:\n$out");
    is($l[-1] // '', "$X still running (last activity @{[iso_of($old)]})", 'AC-2: X still running with the file mtime');
}

# ===========================================================================
# AC-3 (DC1) -- completed, no resume, but the agent file keeps growing for
# the whole hold -> never pruned.
# ===========================================================================
{
    my $sid = next_sid();
    my $X   = 'a3f0000000000003c';
    my $jsonl = write_agent($sid, $X, undef);
    write_file(transcript_path_for($sid), notif_line([$X], 'completed'));
    write_ticket_for($sid, [$X]);
    my ($pid, $o, $e) = spawn_hold([$X], 3);
    my $rc;
    my $hard = time() + 20;
    while (time() < $hard) {
        append_file($jsonl, agent_progress_line($X));
        $rc = poll_exit($pid);
        last if defined $rc;
        sleep(0.1);
    }
    my ($out, $err, $rc2) = finish('AC-3', $pid, $o, $e, 5);
    $rc = $rc2 unless defined $rc;
    my @l = lines_of($out);
    is($rc, 0, 'AC-3: exit 0');
    unlike($out, finished_re($X), 'AC-3: no "finished: X" line while the agent transcript keeps growing')
        or diag("stdout:\n$out");
    like($l[-1] // '', qr/^\Q$X\E still running \(last activity \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\)$/,
        'AC-3: the end report says X still running (...)');
}

# ===========================================================================
# AC-4 (DC1) -- AC-1's fixture, 20 s hold; a newer completed notification
# then releases it early (Decision 129: the resumed agent's completion is a
# new notification under the same id).
# ===========================================================================
{
    my $sid = next_sid();
    my $X   = 'a4f0000000000004d';
    my $old = int(time()) - 600;
    write_agent($sid, $X, $old);
    my $tp = transcript_path_for($sid);
    write_file($tp, notif_line([$X], 'stopped') . filler_line(1) . resume_line($X, 'plain'));
    write_ticket_for($sid, [$X]);
    my ($pid, $o, $e) = spawn_hold([$X], 20);
    my $h = wait_for_holder($sid, 10);
    ok(defined $h, 'AC-4: precondition -- the holder record appears');
    sleep(0.5);
    my $before = slurp($o);
    unlike($before, finished_re($X), 'AC-4: before the completion is appended, X has not been reported finished');
    my $t_append = time();
    append_file($tp, notif_line([$X], 'completed', tool_use_id => 'toolu_orig4'));
    my ($out, $err, $rc) = finish('AC-4', $pid, $o, $e, 10);
    my $t_exit = time();
    my @l = lines_of($out);
    is($rc, 0, 'AC-4: exit 0 within 10 s of the completion');
    cmp_ok($t_exit - $t_append, '<', 10, 'AC-4: released within 10 s');
    cmp_ok($t_exit, '<', (ref $h eq 'HASH' ? $h->{deadline} : 0), 'AC-4: ...and before the deadline');
    like($out, qr/${HOLD_LINE_RE}finished: \Q$X\E; still waiting on: nothing$/m,
        'AC-4: "finished: X; still waiting on: nothing"') or diag("stdout:\n$out");
    like($l[-2] // '', qr/${HOLD_LINE_RE}released: every held item finished$/, 'AC-4: released: every held item finished');
    is($l[-1] // '', "$X finished", 'AC-4: X finished');
}

# ===========================================================================
# AC-5 (DC1) -- completed, file quiet for 600 s -> released early.
# ===========================================================================
{
    my $sid = next_sid();
    my $X   = 'a5f0000000000005e';
    write_agent($sid, $X, int(time()) - 600);
    write_file(transcript_path_for($sid), notif_line([$X], 'completed'));
    write_ticket_for($sid, [$X]);
    my $t0 = time();
    my ($pid, $o, $e) = spawn_hold([$X], 30);
    my ($out, $err, $rc) = finish('AC-5', $pid, $o, $e, 15);
    my @l = lines_of($out);
    is($rc, 0, 'AC-5: exit 0');
    cmp_ok(time() - $t0, '<', 15, 'AC-5: released early, well before the 30 s deadline');
    like($l[-2] // '', qr/${HOLD_LINE_RE}released: every held item finished$/, 'AC-5: released: every held item finished')
        or diag("stdout:\n$out");
    is($l[-1] // '', "$X finished", 'AC-5: X finished');
}

# ===========================================================================
# AC-6 (DC1) -- completed; file appended every 0.1 s for 1.5 s, then left
# alone -> released within 10 s of the last append, never before it.
# ===========================================================================
{
    my $sid = next_sid();
    my $X   = 'a6f0000000000006f';
    my $jsonl = write_agent($sid, $X, undef);
    write_file(transcript_path_for($sid), notif_line([$X], 'completed'));
    write_ticket_for($sid, [$X]);
    my ($pid, $o, $e) = spawn_hold([$X], 30);
    my $early = 0;
    my $t_start = time();
    my $t_last;
    while (time() - $t_start < 1.5) {
        # checked BEFORE each append, so any hit is strictly earlier than the last append
        $early = 1 if slurp($o) =~ finished_re($X);
        append_file($jsonl, agent_progress_line($X));
        $t_last = time();
        sleep(0.1);
    }
    my ($out, $err, $rc) = finish('AC-6', $pid, $o, $e, 10 + (time() - $t_last));
    my $t_exit = time();
    is($early, 0, 'AC-6: "finished: X" never appeared before the last append');
    is($rc, 0, 'AC-6: exit 0');
    cmp_ok($t_exit - $t_last, '<=', 10.5, 'AC-6: released within 10 s of the last append');
    like($out, finished_re($X), 'AC-6: a "finished: X" line appears once the file is quiet') or diag("stdout:\n$out");
    is((lines_of($out))[-1] // '', "$X finished", 'AC-6: X finished');
}

# ===========================================================================
# AC-7 (DC1) -- one notification for P, Q, R with a single stopped status;
# P and Q resumed; all quiet. R is released, P and Q are held.
# ===========================================================================
{
    my $sid = next_sid();
    my ($P, $Q, $R) = ('a7p0000000000007a', 'a7q0000000000007b', 'a7r0000000000007c');
    my $old = int(time()) - 600;
    write_agent($sid, $_, $old) for ($P, $Q, $R);
    my $literal = "<task-id>$P</task-id><task-id>$Q</task-id><task-id>$R</task-id><status>stopped</status>";
    my $notif = $JSON->encode({ type => 'queue-operation', operation => 'enqueue', content => "<task-notification>$literal</task-notification>" }) . "\n";
    write_file(transcript_path_for($sid), $notif . resume_line($P, 'both') . resume_line($Q, 'both'));
    write_ticket_for($sid, [$P, $Q, $R]);
    my ($pid, $o, $e) = spawn_hold([$P, $Q, $R], 3);
    my ($out, $err, $rc) = finish('AC-7', $pid, $o, $e, 20);
    my @l = lines_of($out);
    is($rc, 0, 'AC-7: exit 0');
    like($out, finished_re($R), 'AC-7: a "finished: R" line appears (stopped, never resumed)') or diag("stdout:\n$out");
    unlike($out, finished_re($P), 'AC-7: P is never reported finished');
    unlike($out, finished_re($Q), 'AC-7: Q is never reported finished');
    like($l[-4] // '', qr/${HOLD_LINE_RE}released: deadline reached$/, 'AC-7: released: deadline reached');
    is($l[-3] // '', "$P still running (last activity @{[iso_of($old)]})", 'AC-7: P ends as still running');
    is($l[-2] // '', "$Q still running (last activity @{[iso_of($old)]})", 'AC-7: Q ends as still running');
    is($l[-1] // '', "$R finished", 'AC-7: R finished');
}

# ===========================================================================
# AC-8 (DC1) -- a resume for X1 is not a resume for X.
# ===========================================================================
{
    my $sid = next_sid();
    my $X   = 'a8f0000000000008';
    write_agent($sid, $X, int(time()) - 600);
    write_file(transcript_path_for($sid), notif_line([$X], 'completed') . resume_line("${X}1", 'both'));
    write_ticket_for($sid, [$X]);
    my ($pid, $o, $e) = spawn_hold([$X], 30);
    my ($out, $err, $rc) = finish('AC-8', $pid, $o, $e, 15);
    my @l = lines_of($out);
    is($rc, 0, 'AC-8: exit 0 early');
    like($l[-2] // '', qr/${HOLD_LINE_RE}released: every held item finished$/, 'AC-8: released: every held item finished')
        or diag("stdout:\n$out");
    is($l[-1] // '', "$X finished", 'AC-8: X is released as finished despite a resume for X1');
}

# ===========================================================================
# AC-9 (DC1) -- a task item keeps today's semantics; a resume line for it is
# ignored.
# ===========================================================================
{
    my $sid = next_sid();
    my $B   = 'b9task0000000009';
    my $opath = write_file("$TMPROOT/ac9/$B.output", "output\n", time());
    my $shown = ($opath =~ m{^[A-Za-z]:}) ? do { (my $w = $opath) =~ s{/}{\\}g; $w } : $opath;
    write_file(transcript_path_for($sid),
        "Output is being written to: $shown\n" . notif_line([$B], 'completed') . resume_line($B, 'both'));
    ok(!glob(sessiondir_for($sid) . "/subagents/agent-$B.*"), 'AC-9: fixture sanity -- no subagents/agent-B.* exists');
    write_ticket_for($sid, [$B]);
    my ($pid, $o, $e) = spawn_hold([$B], 30);
    my ($out, $err, $rc) = finish('AC-9', $pid, $o, $e, 15);
    my @l = lines_of($out);
    is($rc, 0, 'AC-9: exit 0 early');
    like($l[-2] // '', qr/${HOLD_LINE_RE}released: every held item finished$/, 'AC-9: released: every held item finished')
        or diag("stdout:\n$out");
    is($l[-1] // '', "$B finished", 'AC-9: task item B is finished, as today');
}

# ===========================================================================
# AC-10 (DC1, DC5) -- AC-5 behind ~8 MiB of adversarial lines, each holding
# X and several resumedAgentId markers for OTHER ids (prefix-sharing ones
# included). Must stay linear: X finished within 30 s.
# ===========================================================================
{
    my $sid = next_sid();
    my $X   = 'aaf000000000000a';
    write_agent($sid, $X, int(time()) - 600);
    my $tp = transcript_path_for($sid);
    make_path(dirname($tp));
    open my $fh, '>:raw', $tp or die "write $tp: $!";
    my $bytes = 0;
    my $n = 0;
    while ($bytes < 8 * 1024 * 1024) {
        $n++;
        # Q = a literal double quote, BQ = the JSON-escaped one (backslash + quote).
        my ($Q, $BQ) = ('"', '\\"');
        my $line = "{${Q}type${Q}:${Q}user${Q},${Q}n${Q}:$n,${Q}text${Q}:${Q}about $X and its siblings${Q},"
                 . "${Q}toolUseResult${Q}:{${Q}resumedAgentId${Q}:${Q}${X}9${Q}},"
                 . "${Q}content${Q}:${Q}{${BQ}resumedAgentId${BQ}:${BQ}${X}_${BQ},${BQ}x${BQ}:1}"
                 . " resumedAgentId resumedAgentId${BQ}:${BQ}${Q},"
                 . "${Q}r${Q}:[{${Q}resumedAgentId${Q}:${Q}b$n${Q}},{${Q}resumedAgentId${Q} : ${Q}c$n${Q}},"
                 . "{${Q}resumedAgentId${Q}:${Q}${X}x$n${Q}}]}\n";
        print {$fh} $line;
        $bytes += length $line;
    }
    print {$fh} notif_line([$X], 'completed');
    close $fh;
    write_ticket_for($sid, [$X]);
    my $t0 = time();
    my ($pid, $o, $e) = spawn_hold([$X], 120);
    my ($out, $err, $rc) = finish('AC-10', $pid, $o, $e, 30);
    is($rc, 0, 'AC-10: the holder exits 0 within 30 s behind ~8 MiB of adversarial lines')
        or diag(sprintf('elapsed %.1fs', time() - $t0));
    is((lines_of($out))[-1] // '', "$X finished", 'AC-10: X finished');
}

# ===========================================================================
# Decision 129 replay -- the incident exactly as observed: one stopped
# notification for four ids, SendMessage resume markers (escaped text plus
# plain toolUseResult) for two of them, one resumed transcript that keeps
# growing, one never resumed. The growing one is held; the never-resumed one
# is released; a later completion notification under each resumed id
# releases it.
# ===========================================================================
{
    my $sid = next_sid();
    my ($A, $B, $C, $D) = ('a673b36db836845e5', 'a95ceb9ef668c7242', 'a7cca1ebb09fa7a5f', 'a5587d10baddd3920');
    my $old = int(time()) - 600;
    my $jsonl_a = write_agent($sid, $A, undef);
    write_agent($sid, $B, $old);
    write_agent($sid, $C, $old);
    write_agent($sid, $D, $old);
    my $tp = transcript_path_for($sid);
    write_file($tp, notif_line([$A, $B, $C, $D], 'stopped')
                  . join('', map { filler_line($_) } 1 .. 20)
                  . resume_line($A, 'both')
                  . filler_line(21)
                  . resume_line($B, 'both')
                  . filler_line(22));
    write_ticket_for($sid, [$A, $B, $C]);
    my ($pid, $o, $e) = spawn_hold([$A, $B, $C], 30);

    my $early_a = 0;
    my $early_b = 0;
    my $t_start = time();
    while (time() - $t_start < 2.5) {
        my $now = slurp($o);
        $early_a = 1 if $now =~ finished_re($A);
        $early_b = 1 if $now =~ finished_re($B);
        append_file($jsonl_a, agent_progress_line($A));
        append_file($tp, filler_line(100 + int((time() - $t_start) * 10)));    # the parent transcript keeps growing too
        sleep(0.1);
    }
    my $mid = slurp($o);
    is($early_a, 0, 'D129-replay: the resumed agent whose transcript keeps growing is never reported finished');
    is($early_b, 0, 'D129-replay: the resumed, quiet agent is never reported finished');
    like($mid, qr/${HOLD_LINE_RE}finished: \Q$C\E; still waiting on: \Q$A\E, \Q$B\E$/m,
        'D129-replay: the stopped, never-resumed agent is released (stale stops still release)') or diag("stdout:\n$mid");
    ok(!defined poll_exit($pid), 'D129-replay: the holder is still holding after 2.5 s of growth');

    # A's own completion notification, under its original task id.
    my $t_a = time();
    append_file($tp, notif_line([$A], 'completed', tool_use_id => 'toolu_resumeA'));
    my $got_a = '';
    my $dl = time() + 10;
    while (time() < $dl) {
        $got_a = slurp($o);
        last if $got_a =~ finished_re($A);
        sleep(0.05);
    }
    like($got_a, qr/${HOLD_LINE_RE}finished: \Q$A\E; still waiting on: \Q$B\E$/m,
        'D129-replay: a later completion notification under the same id releases the resumed agent')
        or diag("stdout:\n$got_a");
    unlike($got_a, finished_re($B), 'D129-replay: B (resumed, no completion yet) is still held');

    append_file($tp, notif_line([$B], 'completed', tool_use_id => 'toolu_resumeB'));
    my ($out, $err, $rc) = finish('D129-replay', $pid, $o, $e, 10);
    my @l = lines_of($out);
    is($rc, 0, 'D129-replay: exit 0 once every held item finished');
    like($out, qr/${HOLD_LINE_RE}finished: \Q$B\E; still waiting on: nothing$/m, 'D129-replay: finished: B; still waiting on: nothing');
    like($l[-4] // '', qr/${HOLD_LINE_RE}released: every held item finished$/, 'D129-replay: released: every held item finished');
    is_deeply([@l[-3 .. -1]], ["$A finished", "$B finished", "$C finished"], 'D129-replay: end report, in held order');
}

# ===========================================================================
# AC-11 (DC1) -- holder stderr empty everywhere; real state untouched.
# ===========================================================================
{
    my @labels = sort keys %STDERR_LOG;
    cmp_ok(scalar(@labels), '>=', 10, 'AC-11: stderr was captured for every holder run');
    for my $label (@labels) {
        is($STDERR_LOG{$label}, '', "AC-11: holder stderr is empty ($label)");
    }
    SKIP: {
        skip 'AC-11: no real HOME/USERPROFILE to guard', 2 unless defined $REAL_BSTATE;
        is(-d $REAL_BSTATE ? 1 : 0, $REAL_BSTATE_EXISTS, 'AC-11: the real ~/.claude/butler-state existence is unchanged');
        is($REAL_BSTATE_EXISTS ? (stat($REAL_BSTATE))[9] : undef, $REAL_BSTATE_MTIME,
            'AC-11: the real ~/.claude/butler-state mtime is unchanged');
    }
}

# ===========================================================================
# AC-24 (DC5) -- butler-hold.pl gains no subprocess construct.
# ===========================================================================
{
    my $src = slurp($SCRIPT);
    ok(length $src, 'AC-24: butler-hold.pl is readable');
    $src =~ s/^__(?:END|DATA)__\b.*\z//ms;
    $src =~ s/^=[a-zA-Z].*?^=cut\b[^\n]*//msg;          # POD
    my @code = grep { !/^\s*#/ } split /\n/, $src;       # whole-line comments
    s/\s+#[^'"]*$// for @code;                            # trailing comments with no quote after the #
    my $code = join("\n", @code);
    my @hits;
    push @hits, 'system' if $code =~ /\bsystem\s*[\(\$'"]/;
    push @hits, 'exec'   if $code =~ /\bexec\s*[\(\$'"{]/;
    push @hits, 'backticks' if $code =~ /`/;
    push @hits, 'qx'     if $code =~ /\bqx\s*[^\w\s=,;]/;
    push @hits, 'fork'   if $code =~ /\bfork\s*(?:\(|;)/;
    push @hits, 'pipe-open' if $code =~ /\bopen\s*\(?[^;]*?,\s*['"](?:-\||\|-)['"]/
                            || $code =~ /\bopen\s*\(?[^;]*?,\s*['"][^'"]*\|\s*['"]/
                            || $code =~ /\bopen\s*\(?[^;]*?,\s*['"]\s*\|/;
    is_deeply(\@hits, [], 'AC-24: butler-hold.pl has no system/exec/backticks/qx/fork/pipe-open');
}

done_testing();
