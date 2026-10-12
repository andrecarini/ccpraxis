# platform: any
# ORACLE for package 23-holder-observability (blueprint hook-continuity-remake),
# AC-1..AC-18 of specs/23-holder-observability-spec.md: the running holder
# prints a timestamped line per event (start/extension/finished/released), the
# `held`/`ext_seq` record fields, `held`/`items` pruning, the extending call's
# own "did not become" line, `local_utc_hhmm` zone hygiene, `take_ticket`
# same-session-duplicate binding (task 50), and the `butler-continuity status`
# holder line.
#
# NONE of local_utc_hhmm, the per-tick event lines, held/ext_seq, or the
# same-session take_ticket merge exist yet. Every AC below is written against
# the SPEC's shapes, not today's; most fail now for that reason (wrong line
# text, missing fields, 'ambiguous' instead of a merged hashref) -- legibly,
# not by hanging or crashing this file. A few sub-checks that the spec calls
# "unchanged" (H-parity paths, take_ticket's cross-session ambiguity, its
# stale-purge) are expected to pass today.
#
# Test hygiene mirrors plugins/butler/tests/t/continuity-holder.t: tickets are
# written in-process through BpHook (real); butler-hold/butler-continuity are
# always spawned as real subprocesses (fork + exec('bash', <shim>, @argv));
# every spawned pid goes on @KILL_PIDS, reaped in END with a bounded
# TERM-then-KILL; HOME/USERPROFILE point at a decoy tempdir; BUTLER_STATE_DIR
# is an absolute tempdir; every BP_*/CCPRAXIS_*/CLAUDE_* except
# CCPRAXIS_NO_WAKELOCK is stripped from this process and every child.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use JSON::PP ();
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep time);
use Time::Local ();

my $S   = "$Bin/../../scripts"; $S   =~ s{\\}{/}g;
my $BIN = "$Bin/../../bin";     $BIN =~ s{\\}{/}g;
my $HOLD_SHIM = "$BIN/butler-hold";
my $CONT_SHIM = "$BIN/butler-continuity";

require "$S/BpHook.pm";

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
# fixtures / environment
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my $TMPROOT = tempdir(CLEANUP => 1); $TMPROOT =~ s{\\}{/}g;
(my $PROJECT = "$TMPROOT/proj") =~ s{\\}{/}g;
make_path($PROJECT);
(my $STATE_DIR = "$TMPROOT/state") =~ s{\\}{/}g;

my $REAL_HOME        = $ENV{HOME};
my $REAL_USERPROFILE = $ENV{USERPROFILE};
my ($REAL_BSTATE, $REAL_BSTATE_EXISTS, $REAL_BSTATE_MTIME);
{
    my $rh = (defined $REAL_HOME && length $REAL_HOME) ? $REAL_HOME
           : (defined $REAL_USERPROFILE && length $REAL_USERPROFILE) ? $REAL_USERPROFILE
           : undef;
    if (defined $rh) {
        (my $rh_n = $rh) =~ s{\\}{/}g;
        $REAL_BSTATE = "$rh_n/.claude/butler-state";
        $REAL_BSTATE_EXISTS = -d $REAL_BSTATE ? 1 : 0;
        $REAL_BSTATE_MTIME  = $REAL_BSTATE_EXISTS ? (stat($REAL_BSTATE))[9] : undef;
    }
}
my $DECOY_ROOT = tempdir(CLEANUP => 1);
(my $DECOY_HOME = "$DECOY_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($DECOY_HOME);
$ENV{HOME}                  = $DECOY_HOME;
$ENV{USERPROFILE}           = $DECOY_HOME;
$ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
$ENV{BUTLER_HOLD_TEST_MODE} = 1;
# never-halt 06 (AC-19): a fixture, never-existing data root, so
# butler-hold's prompt-watch resolution (BpDataRoot::resolve) is exercised
# hermetically and stays OFF, leaving this file's own assertions unchanged.
$ENV{CCPRAXIS_DATA_DIR}     = "$TMPROOT/no-prompt-watch-data";

my $CONT_ROOT = "$STATE_DIR/continuity";

# ---------------------------------------------------------------------------
# generic helpers (mirrors continuity-holder.t)
# ---------------------------------------------------------------------------
my $TUID_N = 0;
sub next_tuid { return sprintf('tu%06x', ++$TUID_N) }
sub sid8 { return substr($_[0], 0, 8) }

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

sub write_ticket_for {
    my ($sid, $argv, $name, %o) = @_;
    my $tuid = $o{tuid} // next_tuid();
    my $p = {
        session_id      => $sid,
        tool_use_id     => $tuid,
        transcript_path => $o{transcript_path},
        cwd             => $o{cwd} // $PROJECT,
    };
    $p->{agent_id} = $o{agent_id} if exists $o{agent_id};
    my $ok = BpHook::write_ticket($p, $name, $argv,
        operator => ($o{operator} ? 1 : 0), background => (exists $o{background} ? $o{background} : 1));
    return ($ok, $tuid);
}

sub find_ticket_files {
    my ($sid, $tuid) = @_;
    my @found = glob("$CONT_ROOT/tickets/*/$sid.$tuid.json");
    return @found;
}

# count_ticket_files(...) -- glob() in scalar context is a stateful iterator,
# not a count; count_ticket_files((...)) silently returns one filename
# (or undef) instead of a count. Force list context here, once, so every
# caller gets a real integer.
sub count_ticket_files {
    my @found = find_ticket_files(@_);
    return scalar(@found);
}

sub spawn_cmd {
    my ($shim, $argv, $env_over) = @_;
    $env_over //= {};
    my (undef, $outfile) = tempfile(DIR => $TMPROOT);
    my (undef, $errfile) = tempfile(DIR => $TMPROOT);
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{CCPRAXIS_NO_WAKELOCK}  = 1;
        $ENV{HOME}                  = $DECOY_HOME;
        $ENV{USERPROFILE}           = $DECOY_HOME;
        $ENV{BUTLER_STATE_DIR}      = $STATE_DIR;
        $ENV{BUTLER_HOLD_TEST_MODE} = 1;
        $ENV{CCPRAXIS_DATA_DIR}     = "$TMPROOT/no-prompt-watch-data";
        for my $k (keys %$env_over) {
            if (defined $env_over->{$k}) { $ENV{$k} = $env_over->{$k} }
            else                          { delete $ENV{$k} }
        }
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec('bash', $shim, @$argv);
        POSIX::_exit(127);
    }
    return ($pid, $outfile, $errfile);
}

sub wait_pid_bounded {
    my ($pid, $timeout) = @_;
    my $deadline = time() + $timeout;
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
    return $rc;
}

sub run_cmd {
    my ($shim, $argv, $env_over, $timeout) = @_;
    my ($pid, $outfile, $errfile) = spawn_cmd($shim, $argv, $env_over);
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, $timeout // 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;
    return ($out, $err, $rc);
}

sub reap_and_log {
    my ($pid, $outfile, $errfile, $sig) = @_;
    $sig //= 'TERM';
    kill($sig, $pid) if kill(0, $pid);
    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;
    return ($out, $err, $rc);
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

sub wait_for_no_record {
    my ($sid, $timeout) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        return 1 unless -f "$CONT_ROOT/holder/$sid.json";
        sleep(0.05);
    }
    return 0;
}

sub wait_for_stdout_match {
    my ($outfile, $pattern, $timeout) = @_;
    $timeout //= 10;
    my $deadline = time() + $timeout;
    my $content = '';
    while (time() < $deadline) {
        $content = slurp($outfile);
        return $content if $content =~ $pattern;
        sleep(0.05);
    }
    return $content;
}

sub wait_for_line_count {
    my ($outfile, $n, $timeout) = @_;
    $timeout //= 10;
    my $deadline = time() + $timeout;
    my $content = '';
    while (time() < $deadline) {
        $content = slurp($outfile);
        return $content if scalar(lines_of($content)) >= $n;
        sleep(0.05);
    }
    return $content;
}

sub transcript_path_for { my ($sid) = @_; return "$PROJECT/$sid.jsonl" }

sub write_transcript {
    my ($path, %o) = @_;
    make_path(dirname($path));
    open my $fh, '>:raw', $path or die "open $path: $!";
    for my $fid (@{ $o{finished} // [] }) {
        print {$fh} "<task-notification><task-id>$fid</task-id><status>completed</status></task-notification>\n";
    }
    close $fh;
}

sub append_finished {
    my ($path, @ids) = @_;
    open my $fh, '>>:raw', $path or die "open $path: $!";
    for my $fid (@ids) {
        print {$fh} "<task-notification><task-id>$fid</task-id><status>completed</status></task-notification>\n";
    }
    close $fh;
}

# ---------------------------------------------------------------------------
# time-pair helpers (spec section 4, "Time assertions")
# ---------------------------------------------------------------------------
my $PAIR_RE = qr/(\d\d):(\d\d) \((\d\d):(\d\d)Z\)/;

# offset_minutes_at(t) -- (local - utc) mod 1440 for THIS process at epoch t,
# per the spec's own definition: Time::Local::timegm(localtime(t)) - t, in
# minutes, mod 1440.
sub offset_minutes_at {
    my ($t) = @_;
    my $secs = Time::Local::timegm(localtime($t)) - $t;
    my $mins = $secs / 60;
    $mins = $mins % 1440;
    $mins += 1440 if $mins < 0;
    return $mins;
}

# time_pair_ok_bracket($lh,$lm,$uh,$um,$t_before,$t_after) -- valid when the
# UTC half equals gmtime(t) HH:MM for some integer t in the closed bracket,
# and the pair's own (local-utc) offset equals this process's offset at that
# same t.
sub time_pair_ok_bracket {
    my ($lh, $lm, $uh, $um, $t_before, $t_after) = @_;
    my $pair_offset = (($lh * 60 + $lm) - ($uh * 60 + $um)) % 1440;
    $pair_offset += 1440 if $pair_offset < 0;
    for (my $t = int($t_before) - 1; $t <= int($t_after) + 1; $t++) {
        my @g = gmtime($t);
        next unless $g[2] == $uh && $g[1] == $um;
        return 1 if offset_minutes_at($t) == $pair_offset;
    }
    return 0;
}

# time_pair_ok_epoch($lh,$lm,$uh,$um,$epoch) -- valid only when both halves
# equal gmtime/localtime of the EXACT epoch (used for a deadline pair, whose
# epoch is known precisely from the record).
sub time_pair_ok_epoch {
    my ($lh, $lm, $uh, $um, $epoch) = @_;
    return 0 unless defined $epoch;
    my @g = gmtime($epoch);
    my @l = localtime($epoch);
    return ($g[2] == $uh && $g[1] == $um && $l[2] == $lh && $l[1] == $lm) ? 1 : 0;
}

# extract_pairs($line) -- list of [lh,lm,uh,um] for every pair in the line.
sub extract_pairs {
    my ($line) = @_;
    my @out;
    while ($line =~ /$PAIR_RE/g) {
        push @out, [ $1 + 0, $2 + 0, $3 + 0, $4 + 0 ];
    }
    return @out;
}

# @EVENT_LINES -- every real stdout line captured from a running holder or an
# extending call across AC-1..AC-10 (and M1), fed to AC-11's zone-token scan.
# Populated in place as each block below captures its own output; AC-11 (run
# after AC-10) is the only reader.
my @EVENT_LINES;

# ===========================================================================
# AC-1 (DC1) -- become prints a timestamped start line; held=items, ext_seq=0.
# ===========================================================================
{
    my $sid = 'ho-ac1-sid';
    my $tp  = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['A1', 'A2'], 'butler-hold', transcript_path => $tp, background => 1);

    my $t_before = time();
    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['A1', 'A2'],
        { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    $main::AC1_PID = $pid; $main::AC1_OUT = $outfile; $main::AC1_ERR = $errfile;

    my $h = wait_for_holder($sid, 30);
    my $t_after = time();
    ok(defined $h, 'AC-1: precondition -- a record appears after become');

    my $out = wait_for_stdout_match($outfile,
        qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until \d\d:\d\d \(\d\d:\d\dZ\): A1, A2$/m,
        30);
    my ($line1) = grep { /holding session/ } lines_of($out);
    like($line1 // '', qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until \d\d:\d\d \(\d\d:\d\dZ\): A1, A2$/,
        'AC-1: stdout line 1 matches "<T> holding session <sid8> until <D>: A1, A2"');

    SKIP: {
        skip 'AC-1: no line 1 to inspect for time pairs', 2 unless defined $line1;
        my @pairs = extract_pairs($line1);
        is(scalar(@pairs), 2, 'AC-1: line 1 carries exactly two time pairs (T and D)')
            or diag("line: $line1");
        SKIP: {
            skip 'AC-1: wrong pair count', 2 unless scalar(@pairs) == 2;
            ok(time_pair_ok_bracket(@{ $pairs[0] }, $t_before, $t_after),
                'AC-1: the leading <T> pair is valid for the spawn bracket');
            my $ddl = ref $h eq 'HASH' ? $h->{deadline} : undef;
            ok(time_pair_ok_epoch(@{ $pairs[1] }, $ddl),
                'AC-1: the <D> pair equals gmtime/localtime of the record deadline');
        }
    }

    SKIP: {
        skip 'AC-1: no record to inspect', 3 unless ref $h eq 'HASH';
        is_deeply($h->{items}, ['A1', 'A2'], 'AC-1: items = [A1, A2]');
        is_deeply($h->{held}, ['A1', 'A2'], 'AC-1: held = [A1, A2]');
        is($h->{ext_seq}, 0, 'AC-1: ext_seq = 0');
    }
}

# ===========================================================================
# AC-2 (DC2) -- extend exits 0 with exactly one "extended the running holder"
# line naming the record pid; a foreground extend behaves the same.
# ===========================================================================
{
    my $sid = 'ho-ac1-sid';   # AC-1's holder is still running
    my $tp  = transcript_path_for($sid);
    write_ticket_for($sid, ['A3'], 'butler-hold', transcript_path => $tp, background => 1);
    my $h_before = BpHook::holder($sid);

    my ($out, $err, $rc) = run_cmd($HOLD_SHIM, ['A3'], {}, 10);
    is($rc, 0, 'AC-2: a fresh extending ticket exits 0');
    is($err, '', 'AC-2: extending call stderr is empty');
    my @lines = lines_of($out);
    is(scalar(@lines), 1, 'AC-2: extending call prints exactly one stdout line');
    my $expect_pid = ref $h_before eq 'HASH' ? $h_before->{pid} : $main::AC1_PID;
    like($lines[0] // '',
        qr/^extended the running holder \(pid \Q$expect_pid\E\) until \d\d:\d\d \(\d\d:\d\dZ\); this call exits now, the holder keeps waiting$/,
        'AC-2: exact line, with the captured pid equal to the record pid');
    push @EVENT_LINES, @lines;

    write_ticket_for($sid, ['A4'], 'butler-hold', transcript_path => $tp, background => 0);
    my ($out2, $err2, $rc2) = run_cmd($HOLD_SHIM, ['A4'], {}, 10);
    is($rc2, 0, 'AC-2: a foreground (background=>0) extending ticket also exits 0');
    my @lines2 = lines_of($out2);
    is(scalar(@lines2), 1, 'AC-2: foreground extend also prints exactly one line');
    like($lines2[0] // '',
        qr/^extended the running holder \(pid \d+\) until \d\d:\d\d \(\d\d:\d\dZ\); this call exits now, the holder keeps waiting$/,
        'AC-2: foreground extend -- same line shape');
    is($err2, '', 'AC-2: foreground extend stderr is empty');
    push @EVENT_LINES, @lines2;

    my $h = BpHook::holder($sid);
    SKIP: {
        skip 'AC-2: no record', 1 unless ref $h eq 'HASH';
        cmp_ok($h->{ext_seq} // -1, '>=', 2, 'AC-2: ext_seq advanced at least twice (A3 then A4)');
    }
}

# ===========================================================================
# AC-3 (DC1) -- the RUNNING holder reports the extension within one tick.
# ===========================================================================
{
    my $sid = 'ho-ac1-sid';
    my $out = wait_for_stdout_match($main::AC1_OUT,
        qr/^\d\d:\d\d \(\d\d:\d\dZ\) extended until \d\d:\d\d \(\d\d:\d\dZ\); added: A3/m, 30);
    my ($eline) = grep { /extended until/ } lines_of($out);
    like($eline // '', qr/^\d\d:\d\d \(\d\d:\d\dZ\) extended until \d\d:\d\d \(\d\d:\d\dZ\); added: A3\b/,
        'AC-3: the running holder prints "extended until <D>; added: A3" within a bounded wait');

    my $h = BpHook::holder($sid);
    SKIP: {
        skip 'AC-3: no extension line to check the D pair against', 1 unless defined $eline && ref $h eq 'HASH';
        my @pairs = extract_pairs($eline);
        ok(scalar(@pairs) == 2 && time_pair_ok_epoch(@{ $pairs[1] }, $h->{deadline}),
            'AC-3: the extension line D pair equals gmtime/localtime of the record deadline');
    }
    SKIP: {
        skip 'AC-3: no record', 2 unless ref $h eq 'HASH';
        ok((grep { $_ eq 'A3' } @{ $h->{items} // [] }), 'AC-3: items contains A3');
        ok((grep { $_ eq 'A3' } @{ $h->{held} // [] }), 'AC-3: held contains A3');
    }
}

# ===========================================================================
# AC-4 (DC1) -- an extension naming only already-held ids: "no new ids".
# ===========================================================================
{
    my $sid = 'ho-ac1-sid';
    my $tp  = transcript_path_for($sid);
    write_ticket_for($sid, ['A1'], 'butler-hold', transcript_path => $tp, background => 1);
    my ($out, $err, $rc) = run_cmd($HOLD_SHIM, ['A1'], {}, 10);
    is($rc, 0, 'AC-4: precondition -- the already-held-id extension itself exits 0');
    is($err, '', 'AC-4: the already-held-id extension itself has empty stderr');

    my $hout = wait_for_stdout_match($main::AC1_OUT,
        qr/^\d\d:\d\d \(\d\d:\d\dZ\) extended until \d\d:\d\d \(\d\d:\d\dZ\); no new ids$/m, 30);
    like($hout, qr/^\d\d:\d\d \(\d\d:\d\dZ\) extended until \d\d:\d\d \(\d\d:\d\dZ\); no new ids$/m,
        'AC-4: the holder prints "extended until <D>; no new ids" within a bounded wait');
}

# ===========================================================================
# AC-5 (DC1, DC3) -- a finished id is pruned from items (not held); the
# holder prints the finished line within one tick.
# ===========================================================================
{
    my $sid = 'ho-ac1-sid';
    my $tp  = transcript_path_for($sid);
    my $h0  = BpHook::holder($sid);
    my @remaining_before = ref $h0 eq 'HASH' ? @{ $h0->{items} // [] } : ();
    my @expect_remaining = grep { $_ ne 'A1' } @remaining_before;

    append_finished($tp, 'A1');
    my $out = wait_for_stdout_match($main::AC1_OUT, qr/^\d\d:\d\d \(\d\d:\d\dZ\) finished: A1;/m, 30);
    my ($fline) = grep { /finished: A1;/ } lines_of($out);
    my $expect_re = join(', ', map { quotemeta($_) } @expect_remaining);
    like($fline // '',
        qr/^\d\d:\d\d \(\d\d:\d\dZ\) finished: A1; still waiting on: $expect_re$/,
        'AC-5: "finished: A1; still waiting on: <remaining ids in record order>"');

    my $h = BpHook::holder($sid);
    SKIP: {
        skip 'AC-5: no record', 2 unless ref $h eq 'HASH';
        ok(!(grep { $_ eq 'A1' } @{ $h->{items} // [] }), 'AC-5: items no longer contains A1');
        ok((grep { $_ eq 'A1' } @{ $h->{held} // [] }), 'AC-5: held still contains A1');
    }
}

# ===========================================================================
# AC-6 (DC3) -- butler-continuity status: no A1 anywhere, holder line lists
# only the remaining (pruned) items.
# ===========================================================================
{
    my $sid = 'ho-ac1-sid';
    my $tp  = transcript_path_for($sid);
    BpHook::arm($sid, role => 'manual', by => 'test', transcript_path => $tp);
    write_ticket_for($sid, ['status'], 'butler-continuity', transcript_path => $tp, background => 0);

    my ($out, $err, $rc) = run_cmd($CONT_SHIM, ['status'], {}, 10);
    is($rc, 0, 'AC-6: butler-continuity status exits 0');
    is($err, '', 'AC-6: butler-continuity status stderr is empty');
    unlike($out, qr/\bA1\b/, 'AC-6: no A1 anywhere in status output');

    my $h = BpHook::holder($sid);
    my @remaining = ref $h eq 'HASH' ? @{ $h->{items} // [] } : ();
    my $expect_re = join(', ', map { quotemeta($_) } @remaining);
    my ($hline) = grep { /^holder:/ } lines_of($out);
    like($hline // '', qr/^holder: running until \d\d:\d\d \(\d\d:\d\dZ\); still running: $expect_re$/,
        'AC-6: "holder: running until <D>; still running: <remaining ids>"');
}

# ===========================================================================
# AC-7 (DC1) -- when the last held ids finish: one finished line per id
# ("still waiting on: nothing"), then released, then one item line per held
# id in held order.
# ===========================================================================
{
    my $sid = 'ho-ac1-sid';
    my $tp  = transcript_path_for($sid);
    my $h0  = BpHook::holder($sid);
    my @held_order    = ref $h0 eq 'HASH' ? @{ $h0->{held}  // [] } : ();
    my @items_left     = ref $h0 eq 'HASH' ? @{ $h0->{items} // [] } : ();

    append_finished($tp, @items_left);

    my $out = wait_for_stdout_match($main::AC1_OUT, qr/released: every held item finished/m, 30);
    my $rc = wait_pid_bounded($main::AC1_PID, 30);
    @KILL_PIDS = grep { $_ != $main::AC1_PID } @KILL_PIDS;
    my $err = slurp($main::AC1_ERR);
    unlink $main::AC1_OUT, $main::AC1_ERR;

    is($rc, 0, 'AC-7: exits 0 within a bounded wait once every held item finishes');
    is($err, '', 'AC-7: stderr is empty');
    ok(wait_for_no_record($sid, 30), 'AC-7: the record is gone');

    my @lines = lines_of($out);
    push @EVENT_LINES, @lines;   # AC-11: this file's whole holder lifetime (start, extends, finishes, released, item report)
    my @finished_lines = grep { /finished: .*; still waiting on:/ } @lines;
    cmp_ok(scalar(@finished_lines), '>=', scalar(@items_left),
        'AC-7: at least one finished line per remaining item');
    ok((!grep { !/still waiting on: nothing$/ } @finished_lines[-1 .. -1]),
        'AC-7: the last tick\'s finished line(s) end "still waiting on: nothing"')
        if @finished_lines;
    my ($rline_idx) = grep { $lines[$_] =~ /^\d\d:\d\d \(\d\d:\d\dZ\) released: every held item finished$/ } 0 .. $#lines;
    ok(defined $rline_idx, 'AC-7: a "<T> released: every held item finished" line is present');

    SKIP: {
        skip 'AC-7: no released line to anchor the item report on', 1 unless defined $rline_idx;
        my @report = @lines[$rline_idx + 1 .. $#lines];
        is(scalar(@report), scalar(@held_order),
            'AC-7: exactly one item line per held id follows the released line');
        for my $i (0 .. $#held_order) {
            is($report[$i] // '', "$held_order[$i] finished", "AC-7: item line $i is '$held_order[$i] finished', held order");
        }
    }
}

# ===========================================================================
# AC-8 (DC1) -- deadline case: released: deadline reached, then one item line.
# ===========================================================================
{
    my $sid = 'ho-ac8-sid';
    my $tp  = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['D1'], 'butler-hold', transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['D1'],
        { BUTLER_HOLD_TEST_SECONDS => 2, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $rc = wait_pid_bounded($pid, 15);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 0, 'AC-8: deadline case exits 0');
    is($err, '', 'AC-8: deadline case stderr empty');
    my @lines = lines_of($out);
    push @EVENT_LINES, @lines;
    cmp_ok(scalar(@lines), '>=', 2, 'AC-8: at least two lines');
    like($lines[-2] // '', qr/^\d\d:\d\d \(\d\d:\d\dZ\) released: deadline reached$/,
        'AC-8: second-to-last line is "<T> released: deadline reached"');
    like($lines[-1] // '', qr/^D1 (?:still running|unknown)/, 'AC-8: last line is D1 still running or unknown');
}

# ===========================================================================
# AC-9 (DC1) -- TERM case: released: killed by a signal; exit 143; record kept.
# ===========================================================================
{
    my $sid = 'ho-ac9-sid';
    my $tp  = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['T1'], 'butler-hold', transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['T1'],
        { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 30);
    ok(defined $h, 'AC-9: precondition -- became');

    kill('TERM', $pid);
    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 143, 'AC-9: exit 143 after TERM');
    is($err, '', 'AC-9: stderr is empty even on a graceful TERM exit');
    my @lines = lines_of($out);
    push @EVENT_LINES, @lines;
    my ($rline_idx) = grep { $lines[$_] =~ /^\d\d:\d\d \(\d\d:\d\dZ\) released: killed by a signal$/ } 0 .. $#lines;
    ok(defined $rline_idx, 'AC-9: a "<T> released: killed by a signal" line is present');
    ok(defined $rline_idx && $rline_idx == $#lines - 1, 'AC-9: exactly one item line follows it')
        if defined $rline_idx;
    ok(-f "$CONT_ROOT/holder/$sid.json", 'AC-9: the record is still present after a signal exit');
    unlink "$CONT_ROOT/holder/$sid.json";
}

# ===========================================================================
# AC-10 (DC1) -- off case: BpHook::disarm while holding -> released: continuity
# is off, then the item line, exit 0.
# ===========================================================================
{
    my $sid = 'ho-ac10-sid';
    my $tp  = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['O1'], 'butler-hold', transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['O1'],
        { BUTLER_HOLD_TEST_SECONDS => 30, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 30);
    ok(defined $h, 'AC-10: precondition -- became');

    BpHook::disarm($sid, actor => 'agent', reason => 'ac10 test disarm');

    my $rc = wait_pid_bounded($pid, 10);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    is($rc, 0, 'AC-10: off case exits 0');
    is($err, '', 'AC-10: off case stderr empty');
    my @lines = lines_of($out);
    push @EVENT_LINES, @lines;
    my ($rline_idx) = grep { $lines[$_] =~ /^\d\d:\d\d \(\d\d:\d\dZ\) released: continuity is off$/ } 0 .. $#lines;
    ok(defined $rline_idx, 'AC-10: a "<T> released: continuity is off" line is present');
    ok(defined $rline_idx && $rline_idx == $#lines - 1, 'AC-10: exactly one item line follows it')
        if defined $rline_idx;
}

# ===========================================================================
# M1 (review reports/23-holder-observability-review.md, Decision 103) -- past
# the deadline, a prune write that keeps failing must not stop the holder
# from ever releasing. butler-hold.pl:864-869's "@finished2 nonempty, write
# fails -> unlock, next" branch runs unconditionally, before the
# deadline_now check is ever reached, so today a permanently-failing prune
# write spins forever instead of releasing with "deadline reached".
#
# Fixture: write_record_atomic() tries 5 attempts named
# "<holder-dir>/.holdtmp.<pid>.<1..5>". chmod on a DIRECTORY does not stop
# new files being created in it on this Windows host (measured: chmod 0555
# on a dir left it creatable), but chmod on an existing FILE's own
# permission bits does block re-opening it for write (measured: chmod 0444
# on a file makes a later open('>',...) fail with EACCES). So each of the
# five exact temp names is pre-created and marked read-only: every prune
# write this holder ever attempts fails, deterministically, without relying
# on directory permission semantics that do not hold here.
# ===========================================================================
{
    my $sid = 'ho-m1-sid';
    my $tp  = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['M1A'], 'butler-hold', transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['M1A'],
        { BUTLER_HOLD_TEST_SECONDS => 2, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 30);
    ok(defined $h, 'M1: precondition -- became');

    my @blocked_files;
    SKIP: {
        skip 'M1: no record to read the holder pid from', 1 unless ref $h eq 'HASH';
        my $holder_pid = $h->{pid};
        make_path("$CONT_ROOT/holder");
        for my $attempt (1 .. 5) {
            my $f = "$CONT_ROOT/holder/.holdtmp.$holder_pid.$attempt";
            if (open(my $fh, '>:raw', $f)) {
                print {$fh} 'blocked';
                close $fh;
                chmod(0444, $f);
                push @blocked_files, $f;
            }
        }
        is(scalar(@blocked_files), 5,
            'M1: precondition -- all five write-attempt temp names are pre-blocked read-only');
    }

    # Finish the id well before the deadline (2s): the buggy path (finished
    # id detected, write fails, unconditional "next") gets every chance to
    # run both before and after the deadline passes.
    append_finished($tp, 'M1A');

    my $rc = wait_pid_bounded($pid, 12);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($outfile);
    my $err = slurp($errfile);
    unlink $outfile, $errfile;

    chmod(0666, $_) for @blocked_files;
    unlink $_ for @blocked_files;
    unlink "$CONT_ROOT/holder/$sid.json";

    is($rc, 0, 'M1: even with every prune write failing, the holder still releases (does not spin) within a bounded time');
    my @lines = lines_of($out);
    my ($rline_idx) = grep { $lines[$_] =~ /^\d\d:\d\d \(\d\d:\d\dZ\) released: deadline reached$/ } 0 .. $#lines;
    ok(defined $rline_idx,
        'M1: it releases with "released: deadline reached" -- the finished id could never be pruned to disk, so the deadline reason (not the all-finished one) is the correct one');
    is($err, '', 'M1: stderr is empty even on the failed-write path');
}

# ===========================================================================
# AC-11 -- zone hygiene over every line REALLY captured in AC-1..AC-10
# (@EVENT_LINES, populated in place by those blocks): once every time pair is
# stripped, no line has a bare 2-5 letter uppercase token; source scan of
# butler-hold.pl and BpHook.pm for %Z / $ENV{TZ} assignment.
# ===========================================================================
{
    ok(scalar(@EVENT_LINES) > 0,
        'AC-11: precondition -- at least one real line was captured across AC-1..AC-10');

    my @bad_lines;
    for my $l (@EVENT_LINES) {
        (my $stripped = $l) =~ s/$PAIR_RE//g;
        push @bad_lines, $l if $stripped =~ /\b[A-Z]{2,5}\b/;
    }
    is(scalar(@bad_lines), 0,
        'AC-11: none of the real captured lines contain a bare 2-5 letter uppercase token once pairs are stripped')
        or diag(join("\n", @bad_lines));

    for my $f ("$S/butler-hold.pl", "$S/BpHook.pm") {
        my $src = slurp($f);
        $src =~ s/^\s*#.*$//mg;   # strip comment lines
        unlike($src, qr/%Z/, "AC-11: $f has no %Z format token (source scan, comments stripped)");
        unlike($src, qr/\$ENV\{TZ\}\s*=/, "AC-11: $f never assigns \$ENV{TZ}");
    }
}

# ===========================================================================
# AC-12 -- zone derivation: TZ=ABC-3 in the child shifts local by +3h and
# never leaks the "ABC" abbreviation.
# ===========================================================================
{
    my ($tz_ok, $skip_reason);
    {
        local $ENV{TZ} = 'ABC-3';
        POSIX::tzset() if defined &POSIX::tzset;
        my $t = time();
        my @l = localtime($t);
        my @g = gmtime($t);
        my $lmin = $l[2] * 60 + $l[1];
        my $gmin = $g[2] * 60 + $g[1];
        my $diff = (($lmin - $gmin) % 1440 + 1440) % 1440;
        $tz_ok = ($diff == 180) ? 1 : 0;
        $skip_reason = "this platform's localtime does not honour TZ=ABC-3 (diff=$diff mins, not 180)";
    }
    POSIX::tzset() if defined &POSIX::tzset;

  SKIP: {
        skip $skip_reason, 3 unless $tz_ok;
        my $sid = 'ho-ac12-sid';
        my $tp  = transcript_path_for($sid);
        write_transcript($tp);
        write_ticket_for($sid, ['Z1'], 'butler-hold', transcript_path => $tp, background => 1);
        my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['Z1'],
            { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2, TZ => 'ABC-3' });
        push @KILL_PIDS, $pid;
        my $out = wait_for_stdout_match($outfile, qr/holding session/m, 30);
        my (undef, $reap_err, undef) = reap_and_log($pid, $outfile, $errfile);
        is($reap_err, '', 'AC-12: the become-under-TZ child stderr is empty');
        my ($line1) = grep { /holding session/ } lines_of($out);
        SKIP: {
            skip 'AC-12: no start line observed', 2 unless defined $line1;
            my @pairs = extract_pairs($line1);
            SKIP: {
                skip 'AC-12: wrong pair count', 2 unless @pairs;
                my ($lh, $lm, $uh, $um) = @{ $pairs[0] };
                my $lmin = $lh * 60 + $lm;
                my $umin = $uh * 60 + $um;
                my $diff = (($lmin - $umin) % 1440 + 1440) % 1440;
                is($diff, 180, 'AC-12: local half is UTC half + 3h (mod 24) under TZ=ABC-3');
                unlike($line1, qr/ABC/, 'AC-12: the line contains no "ABC" abbreviation');
            }
        }
    }
}

# ===========================================================================
# AC-13 (DC4) -- quiet ticks: no extension, no finished item -> the record
# file is byte-identical across >= 5 ticks (2s at TICK=0.2 with no cue).
# ===========================================================================
{
    my $sid = 'ho-ac13-sid';
    my $tp  = transcript_path_for($sid);
    write_transcript($tp);
    write_ticket_for($sid, ['Q1'], 'butler-hold', transcript_path => $tp, background => 1);
    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['Q1'],
        { BUTLER_HOLD_TEST_SECONDS => 20, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 30);
    ok(defined $h, 'AC-13: precondition -- became');

    my $path = "$CONT_ROOT/holder/$sid.json";
    my $before = slurp($path);
    sleep(2);
    my $after = slurp($path);
    is($after, $before, 'AC-13: the record file is byte-identical across 2s of quiet ticks');

    my (undef, $reap_err, undef) = reap_and_log($pid, $outfile, $errfile);
    is($reap_err, '', 'AC-13: the quiet-tick holder child stderr is empty');
}

# ===========================================================================
# AC-14 -- take_ticket, in-process, same-session-duplicate binding (2.5).
# ===========================================================================
{
    # (a) two same-sid, same-argv butler-hold tickets -> hashref, no files left.
    my $sid = 'ho-ac14a-sid';
    my ($ok1, $tuid1) = write_ticket_for($sid, ['P1'], 'butler-hold', transcript_path => transcript_path_for($sid));
    my ($ok2, $tuid2) = write_ticket_for($sid, ['P1'], 'butler-hold', transcript_path => transcript_path_for($sid));
    my $r = BpHook::take_ticket('butler-hold', ['P1']);
    is(ref $r, 'HASH', 'AC-14a: two same-sid same-argv tickets -> a merged hashref (task 50)');
    SKIP: { skip 'AC-14a: not a hashref', 1 unless ref $r eq 'HASH'; is($r->{session_id}, $sid, 'AC-14a: session_id is the shared sid') }
    is(count_ticket_files(($sid, $tuid1)) + count_ticket_files(($sid, $tuid2)), 0,
        'AC-14a: no .json file left under tickets/<k>/');
}
{
    # (b) three such -> hashref, none left.
    my $sid = 'ho-ac14b-sid';
    my @tuids;
    for (1 .. 3) {
        my (undef, $t) = write_ticket_for($sid, ['P2'], 'butler-hold', transcript_path => transcript_path_for($sid));
        push @tuids, $t;
    }
    my $r = BpHook::take_ticket('butler-hold', ['P2']);
    is(ref $r, 'HASH', 'AC-14b: three same-sid same-argv tickets -> a merged hashref');
    my $left = 0;
    $left += count_ticket_files(($sid, $_)) for @tuids;
    is($left, 0, 'AC-14b: none of the three ticket files remain');
}
{
    # (c) two sessions -> 'ambiguous', both files remain (unchanged).
    my ($sid1, $sid2) = ('ho-ac14c-sid1', 'ho-ac14c-sid2');
    my (undef, $t1) = write_ticket_for($sid1, ['P3'], 'butler-hold', transcript_path => transcript_path_for($sid1));
    my (undef, $t2) = write_ticket_for($sid2, ['P3'], 'butler-hold', transcript_path => transcript_path_for($sid2));
    my $r = BpHook::take_ticket('butler-hold', ['P3']);
    is($r, 'ambiguous', "AC-14c: two sessions for one argv -> 'ambiguous' (unchanged)");
    ok(count_ticket_files(($sid1, $t1)) == 1 && count_ticket_files(($sid2, $t2)) == 1,
        'AC-14c: both ticket files remain');
    unlink $_ for find_ticket_files($sid1, $t1), find_ticket_files($sid2, $t2);
}
{
    # (d) same sid, one with agent_id => 'sub1', one without -> 'ambiguous', both remain.
    my $sid = 'ho-ac14d-sid';
    my (undef, $t1) = write_ticket_for($sid, ['P4'], 'butler-hold', transcript_path => transcript_path_for($sid), agent_id => 'sub1');
    my (undef, $t2) = write_ticket_for($sid, ['P4'], 'butler-hold', transcript_path => transcript_path_for($sid));
    my $r = BpHook::take_ticket('butler-hold', ['P4']);
    is($r, 'ambiguous', 'AC-14d: same sid, differing agent_id -> ambiguous');
    ok(count_ticket_files(($sid, $t1)) == 1 && count_ticket_files(($sid, $t2)) == 1,
        'AC-14d: both remain');
    unlink $_ for find_ticket_files($sid, $t1), find_ticket_files($sid, $t2);
}
{
    # (e) same sid, operator true + operator false -> returned operator false.
    my $sid = 'ho-ac14e-sid';
    write_ticket_for($sid, ['P5'], 'butler-hold', transcript_path => transcript_path_for($sid), operator => 1);
    write_ticket_for($sid, ['P5'], 'butler-hold', transcript_path => transcript_path_for($sid), operator => 0);
    my $r = BpHook::take_ticket('butler-hold', ['P5']);
    is(ref $r, 'HASH', 'AC-14e: precondition -- claimed as one hashref');
    SKIP: {
        skip 'AC-14e: not a hashref', 1 unless ref $r eq 'HASH';
        ok(!$r->{operator}, 'AC-14e: operator is false -- a stale ticket never upgrades to operator');
    }
}
{
    # (f) same sid, at rewritten to int(time())-5 (background true), the
    # newer ticket's own int(time()) (background false) -> false. Decision
    # 103/review m1: write_ticket's real writer always produces an integer
    # epoch (BpHook.pm imports no Time::HiRes; this FILE's own `use
    # Time::HiRes qw(time)` only overrides `time` in package main, not in
    # BpHook), so a fixture that wants to control 'at' precisely must write
    # an integer too, not rely on this file's fractional main::time().
    #
    # Review m4: the first half alone proves nothing if either ticket gets
    # silently purged as out-of-window before the merge ever compares two
    # entries -- the precondition below confirms both are still live going
    # in, and the post-condition confirms both files are gone after, so this
    # is a genuine two-entry "greatest at wins" merge, not a lone survivor
    # whose own flag happened to match.
    my $sid = 'ho-ac14f-sid';
    my (undef, $tA) = write_ticket_for($sid, ['P6'], 'butler-hold', transcript_path => transcript_path_for($sid), background => 1);
    my (undef, $tB) = write_ticket_for($sid, ['P6'], 'butler-hold', transcript_path => transcript_path_for($sid), background => 0);
    my ($fileA) = find_ticket_files($sid, $tA);
    if (defined $fileA) {
        my $d = eval { JSON::PP->new->decode(slurp($fileA)) };
        if (ref $d eq 'HASH') { $d->{at} = int(time()) - 5; open(my $fh, '>:raw', $fileA) or die $!; print {$fh} JSON::PP->new->utf8->canonical->encode($d); close $fh }
    }
    is(count_ticket_files(($sid, $tA)) + count_ticket_files(($sid, $tB)), 2,
        'AC-14f: precondition -- both the older and the newer ticket are still live going into take_ticket');
    my $r = BpHook::take_ticket('butler-hold', ['P6']);
    is(ref $r, 'HASH', 'AC-14f: precondition -- claimed as one hashref');
    SKIP: {
        skip 'AC-14f: not a hashref', 2 unless ref $r eq 'HASH';
        ok(!$r->{background}, 'AC-14f: the older (earlier at) background=>1 loses to the newer background=>0 -> false');
        is(count_ticket_files(($sid, $tA)) + count_ticket_files(($sid, $tB)), 0,
            'AC-14f: both ticket files are gone -- a real two-entry merge, not a lone survivor');
    }
}
{
    # (f, inverse) the same shape with the flags swapped: an older
    # background=>0 loses to a newer background=>1 -> true. Spec AC-14f
    # requires this half too (review m4): it is the one that actually shows
    # "base = greatest at", not merely "false tends to win".
    my $sid = 'ho-ac14f2-sid';
    my (undef, $tA) = write_ticket_for($sid, ['P6B'], 'butler-hold', transcript_path => transcript_path_for($sid), background => 0);
    my (undef, $tB) = write_ticket_for($sid, ['P6B'], 'butler-hold', transcript_path => transcript_path_for($sid), background => 1);
    my ($fileA) = find_ticket_files($sid, $tA);
    if (defined $fileA) {
        my $d = eval { JSON::PP->new->decode(slurp($fileA)) };
        if (ref $d eq 'HASH') { $d->{at} = int(time()) - 5; open(my $fh, '>:raw', $fileA) or die $!; print {$fh} JSON::PP->new->utf8->canonical->encode($d); close $fh }
    }
    is(count_ticket_files(($sid, $tA)) + count_ticket_files(($sid, $tB)), 2,
        'AC-14f (inverse): precondition -- both tickets are still live going into take_ticket');
    my $r = BpHook::take_ticket('butler-hold', ['P6B']);
    is(ref $r, 'HASH', 'AC-14f (inverse): precondition -- claimed as one hashref');
    SKIP: {
        skip 'AC-14f (inverse): not a hashref', 2 unless ref $r eq 'HASH';
        ok($r->{background}, 'AC-14f (inverse): the older background=>0 loses to the newer background=>1 -> true');
        is(count_ticket_files(($sid, $tA)) + count_ticket_files(($sid, $tB)), 0,
            'AC-14f (inverse): both ticket files are gone -- a real two-entry merge');
    }
}
{
    # same at, background true + false -> false.
    my $sid = 'ho-ac14g-sid';
    my $now = int(time());
    my (undef, $tA) = write_ticket_for($sid, ['P7'], 'butler-hold', transcript_path => transcript_path_for($sid), background => 1);
    my (undef, $tB) = write_ticket_for($sid, ['P7'], 'butler-hold', transcript_path => transcript_path_for($sid), background => 0);
    for my $t ($tA, $tB) {
        my ($f) = find_ticket_files($sid, $t);
        next unless defined $f;
        my $d = eval { JSON::PP->new->decode(slurp($f)) };
        next unless ref $d eq 'HASH';
        $d->{at} = $now;
        open(my $fh, '>:raw', $f) or next;
        print {$fh} JSON::PP->new->utf8->canonical->encode($d);
        close $fh;
    }
    my $r = BpHook::take_ticket('butler-hold', ['P7']);
    is(ref $r, 'HASH', 'AC-14g: precondition -- claimed as one hashref');
    SKIP: {
        skip 'AC-14g: not a hashref', 1 unless ref $r eq 'HASH';
        ok(!$r->{background}, 'AC-14g: equal at, mixed background -> the conservative false');
    }
}
{
    # (h) a stale (at=now-31) entry beside one live entry -> the live one wins, stale file gone.
    my $sid = 'ho-ac14h-sid';
    my (undef, $tstale) = write_ticket_for($sid, ['P8'], 'butler-hold', transcript_path => transcript_path_for($sid));
    my ($fstale) = find_ticket_files($sid, $tstale);
    if (defined $fstale) {
        my $d = eval { JSON::PP->new->decode(slurp($fstale)) };
        if (ref $d eq 'HASH') { $d->{at} = int(time()) - 31; open(my $fh, '>:raw', $fstale) or die $!; print {$fh} JSON::PP->new->utf8->canonical->encode($d); close $fh }
    }
    my (undef, $tlive) = write_ticket_for($sid, ['P8'], 'butler-hold', transcript_path => transcript_path_for($sid));
    my $r = BpHook::take_ticket('butler-hold', ['P8']);
    is(ref $r, 'HASH', 'AC-14h: the live entry is returned even with a stale sibling');
    is(count_ticket_files(($sid, $tstale)), 0, 'AC-14h: the stale file is gone (purged)');
}

# ===========================================================================
# AC-15 -- end to end: two same-sid identical-argv background tickets for
# butler-hold T1 (guard-blocked attempt + retry), one spawn -> becomes (not a
# refusal); no ticket file for that key remains.
# ===========================================================================
{
    my $sid = 'ho-ac15-sid';
    my $tp  = transcript_path_for($sid);
    write_transcript($tp);
    my (undef, $t1) = write_ticket_for($sid, ['T1'], 'butler-hold', transcript_path => $tp, background => 1);
    my (undef, $t2) = write_ticket_for($sid, ['T1'], 'butler-hold', transcript_path => $tp, background => 1);

    my ($pid, $outfile, $errfile) = spawn_cmd($HOLD_SHIM, ['T1'],
        { BUTLER_HOLD_TEST_SECONDS => 10, BUTLER_HOLD_TEST_TICK => 0.2 });
    push @KILL_PIDS, $pid;
    my $h = wait_for_holder($sid, 30);
    ok(defined $h, 'AC-15: the duplicate tickets bind and the call becomes (a record appears)');

    my $out = wait_for_stdout_match($outfile, qr/holding session/m, 30);
    like($out, qr/^\d\d:\d\d \(\d\d:\d\dZ\) holding session \Q@{[sid8($sid)]}\E until/m,
        'AC-15: a start line is printed, not a refusal');

    is(count_ticket_files(($sid, $t1)) + count_ticket_files(($sid, $t2)), 0,
        'AC-15: no ticket file for that key remains');

    my (undef, $reap_err, undef) = reap_and_log($pid, $outfile, $errfile);
    is($reap_err, '', 'AC-15: the end-to-end holder child stderr is empty');
}

# ===========================================================================
# AC-16 -- prose: each of the 4 SKILL.md files' continuity block mentions
# "foreground" and "butler-continuity status".
#
# This file must never spawn a repo-sibling .t as a "stays green,
# unmodified" floor (Decision 11 / AC-1 of tests-never-run-tests.t):
# regression across sibling files, including continuity-prose-budget.t and
# every file the old AC-17 ran, is the sweep's job (scripts/run-tests.pl),
# not this oracle's. AC-16 checks only the prose THIS package changed,
# directly against the SKILL.md text, without spawning anything.
# ===========================================================================
{
    my @skills = (
        "$Bin/../../skills/continuity/SKILL.md",
        "$Bin/../../skills/drive-solo/SKILL.md",
        "$Bin/../../skills/reporter/SKILL.md",
        "$Bin/../../skills/coordinator-protocol/SKILL.md",
    );
    for my $f (@skills) {
        my $text = slurp($f);
        my ($block) = ($text =~ /<!--\s*continuity:begin\s*-->(.*?)<!--\s*continuity:end\s*-->/s);
        $block //= '';
        ok(length($block) > 0, "AC-16: $f has a continuity:begin/end block") if $text ne '';
        like($block, qr/foreground/i, "AC-16: $f continuity block mentions 'foreground'");
        like($block, qr/butler-continuity status/, "AC-16: $f continuity block mentions 'butler-continuity status'");
    }
}

# ===========================================================================
# AC-18 (hygiene) -- every child this file spawned left an empty stderr file;
# the real butler-state check passes (asserted structurally: every spawn
# above captured stderr and either asserted it empty or discarded it after a
# TERM/KILL reap -- this final guard is the real-state check per rule).
# ===========================================================================
if (defined $REAL_BSTATE) {
    my $now_exists = -d $REAL_BSTATE ? 1 : 0;
    my $now_mtime  = $now_exists ? (stat($REAL_BSTATE))[9] : undef;
    is($now_exists, $REAL_BSTATE_EXISTS,
        'AC-18: the real ~/.claude/butler-state existence is unchanged by this whole file');
    is($now_mtime, $REAL_BSTATE_MTIME,
        'AC-18: the real ~/.claude/butler-state mtime is unchanged by this whole file');
}
else {
    ok(1, 'AC-18: no real HOME/USERPROFILE resolvable in this environment to protect');
}
is(scalar(@KILL_PIDS), 0, 'AC-18: no child process left tracked/unreaped at end of file');

done_testing();
