#!/usr/bin/env perl
# platform: any
# NEW ORACLE for blueprint judged-continuity-disarm, package 01-arm-goal-
# capture: `butler-continuity on --goal <text>`, per
# specs/01-arm-goal-capture-spec.md sections 2-5 (behaviours B1-B19),
# covering done criteria DC1-DC8 as AC1-AC20 of section 4.
#
# THE --goal FLAG DOES NOT EXIST YET: butler-continuity.pl's %allowed{on}
# has no `goal` key (any --goal on `on` hits the existing unknown-flag
# usage_die()), there is no Step 2c validation block, BpHook::arm() has no
# `goal` option, and `status` prints no `goal:` line. Every assertion below
# that names a goal-shaped refusal, a stored goal, or a `goal:` status line
# is expected to fail for exactly that reason right now -- either a usage
# error (unknown flag) where the spec wants a goal-shaped refusal or a
# success, or a missing `goal:` line/key where the spec wants one present.
#
# Almanac::Thread and BpHook.pm are REAL and unchanged by this package --
# every direct library call below is called directly, ungated. Only the
# butler-continuity.pl CLI itself is run as a subprocess.
#
# Every subprocess/fixture pins HOME, USERPROFILE, ALMANAC_HOME,
# CLAUDE_CONFIG_DIR, BUTLER_STATE_DIR, CCPRAXIS_DATA_DIR and
# CLAUDE_PROJECT_DIR to fresh tempdirs (never the operator's real vault) --
# see fresh_fixture() below (house pattern, matches continuity-threads.t).
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use Digest::SHA qw(sha1_hex);
use POSIX qw(WNOHANG);
use Time::HiRes qw(sleep);
use Cwd ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
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
# process bookkeeping (house pattern, matches continuity-threads.t)
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
$ENV{HOME}                 = $DECOY;
$ENV{USERPROFILE}          = $DECOY;
$ENV{ALMANAC_HOME}         = $DECOY;
$ENV{CCPRAXIS_DATA_DIR}    = $DECOY;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

my ($PROJECT, $STATE_BASE, $CFG_DIR);

# fresh_fixture() -- a brand-new project <P>, BUTLER_STATE_DIR and
# CLAUDE_CONFIG_DIR, same convention as continuity-threads.t.
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

sub read_json_file {
    my ($p) = @_;
    my $raw = slurp($p);
    return undef unless length $raw;
    return eval { JSON::PP->new->decode($raw) };
}

sub spawn_cmd {
    my ($env_over, @args) = @_;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        my %eo = %$env_over;
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        $ENV{BUTLER_STATE_DIR}     = $STATE_BASE;
        $ENV{CLAUDE_PROJECT_DIR}   = $PROJECT;
        $ENV{CLAUDE_CONFIG_DIR}    = $CFG_DIR;
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

# ---------------------------------------------------------------------------
# the missing-goal message (spec 2.4). Byte-exact, used by AC1/AC2/AC3.
# ---------------------------------------------------------------------------
my $MISSING_GOAL_MSG =
    "on needs --goal '<what this session is for>': it is stored with the arm so a later stop can be "
  . "checked against it. If the operator asked for this session to be armed, paraphrase their request; "
  . "if you are arming on your own initiative, state your own rationale.";
my $MISSING_GOAL_STDERR = "butler-continuity: $MISSING_GOAL_MSG\n";
my $WORDCOUNT_STDERR = "butler-continuity: --goal needs at least two words saying what this session is for.\n";
my $BYTEBUDGET_STDERR = "butler-continuity: --goal is at most 200 bytes; it goes into the arm record.\n";

# ===========================================================================
# AC1 (DC1): on --new-thread <n> with no --goal refuses, byte-exact, before
# anything is armed or any thread created. Same for --thread <n> (an
# existing handed-off thread fixture) and for --role driver --new-thread <n>.
# (behaviours B1, B2)
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac1new');
    write_ticket_argv($sid, ['on', '--new-thread', 'ac1t']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'ac1t');
    is($rc, 1, 'AC1 [--new-thread, no goal]: exits 1');
    is($err, $MISSING_GOAL_STDERR, 'AC1 [--new-thread, no goal]: stderr is exactly the missing-goal message');
    is($out, '', 'AC1 [--new-thread, no goal]: stdout empty');
    ok(!-e state_root() . "/armed/$sid", 'AC1 [--new-thread, no goal]: nothing armed');
    my $t = eval { Almanac::Thread::read_thread('ac1t', root => $PROJECT) };
    ok($@, 'AC1 [--new-thread, no goal]: thread ac1t was never created');
}
{
    fresh_fixture();
    # an existing, handed-off thread fixture: created and handed off by
    # another session BEFORE this call, so Step 2b's thread rule is
    # satisfied and only Step 2c's missing-goal check can block it.
    my $owner = sess_id('ac1owner');
    eval { Almanac::Thread::create_thread('ac1h', owner_kind => 'session', owner_id => $owner,
        actor => 'session', root => $PROJECT) };
    eval { Almanac::Thread::record_event('ac1h', 'handed-off', session => $owner, actor => 'session',
        reason => 'done for now', root => $PROJECT) };
    my $before = slurp("$PROJECT/.ccpraxis-local-data/almanac/thread/ac1h.md");

    my $sid = sess_id('ac1thread');
    write_ticket_argv($sid, ['on', '--thread', 'ac1h']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--thread', 'ac1h');
    is($rc, 1, 'AC1 [--thread, no goal]: exits 1');
    is($err, $MISSING_GOAL_STDERR, 'AC1 [--thread, no goal]: stderr is exactly the missing-goal message');
    is($out, '', 'AC1 [--thread, no goal]: stdout empty');
    ok(!-e state_root() . "/armed/$sid", 'AC1 [--thread, no goal]: nothing armed');
    my $after = slurp("$PROJECT/.ccpraxis-local-data/almanac/thread/ac1h.md");
    is($after, $before, 'AC1 [--thread, no goal]: the handed-off thread record is untouched (never attached)');
}
{
    fresh_fixture();
    my $sid = sess_id('ac1driver');
    write_ticket_argv($sid, ['on', '--role', 'driver', '--new-thread', 'ac1d']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--role', 'driver', '--new-thread', 'ac1d');
    is($rc, 1, 'AC1 [--role driver --new-thread, no goal]: exits 1');
    is($err, $MISSING_GOAL_STDERR, 'AC1 [--role driver --new-thread, no goal]: stderr is exactly the missing-goal message');
    is($out, '', 'AC1 [--role driver --new-thread, no goal]: stdout empty');
    ok(!-e state_root() . "/armed/$sid", 'AC1 [--role driver --new-thread, no goal]: nothing armed');
}

# ===========================================================================
# AC2 (DC1): the missing-goal stderr carries the "what to write and why"
# guidance -- a wording change cannot drop it and still pass.
# ===========================================================================
{
    like($MISSING_GOAL_STDERR, qr/--goal/, 'AC2: the missing-goal message mentions --goal');
    like($MISSING_GOAL_STDERR, qr/paraphrase their request/, 'AC2: ...and "paraphrase their request"');
    like($MISSING_GOAL_STDERR, qr/state your own rationale/, 'AC2: ...and "state your own rationale"');
}

# ===========================================================================
# AC3 (DC1, DC7 regression): bare `on` and `on --role driver` with no thread
# still produce the byte-exact R1 refusal -- the thread rule (Step 2b) wins
# over the missing-goal check (Step 2c) even when goal is also absent.
# continuity-threads.t's own AC1 is the primary, UNMODIFIED oracle for this;
# this is a light cross-check for traceability from this file.
# ===========================================================================
{
    my $R1 = "butler-continuity: on needs a thread: butler-continuity on --new-thread <name> starts one; "
           . "butler-continuity on --thread <name> resumes a handed-off one or takes over one whose owner is dead.\n";
    for my $case (['on', []], ['on --role driver', ['--role', 'driver']]) {
        my ($label, $extra) = @$case;
        fresh_fixture();
        my $sid = sess_id('ac3');
        write_ticket_argv($sid, ['on', @$extra]);
        my ($out, $err, $rc) = run_cmd({}, 'on', @$extra);
        is($rc, 1, "AC3 [$label]: exits 1");
        is($err, $R1, "AC3 [$label]: stderr is exactly R1, not the missing-goal message");
        ok(!-e state_root() . "/armed/$sid", "AC3 [$label]: nothing armed");
    }
}

# ===========================================================================
# AC4 (DC2): on --new-thread <n> --goal '<2+ words>' arms successfully and
# persists the goal. (behaviour B4)
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac4');
    my $tp  = ensure_transcript($sid, time());
    write_ticket_argv($sid, ['on', '--new-thread', 'ac4t', '--goal', 'ship the parser fix'], transcript_path => $tp);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'ac4t', '--goal', 'ship the parser fix');
    is($rc, 0, 'AC4: on --new-thread --goal exits 0') or diag("stderr: $err");

    my $raw = slurp(state_root() . "/armed/$sid");
    my @nl = $raw =~ /\n/g;
    is(scalar(@nl), 1, 'AC4: the arm record file has exactly one newline (one JSON line + trailing newline)')
        or diag("raw bytes: " . unpack('H*', $raw));
    my $d = read_json_file(state_root() . "/armed/$sid");
    is(ref $d, 'HASH', 'AC4: the arm record decodes to a HASH');
    SKIP: {
        skip 'AC4: record did not decode', 3 unless ref $d eq 'HASH';
        is($d->{goal}, 'ship the parser fix', 'AC4: goal eq "ship the parser fix"');
        is($d->{role}, 'manual', 'AC4: role eq manual');
        is($d->{by}, 'on', 'AC4: by eq on');
    }
}

# ===========================================================================
# AC5 (DC2): the B5 inputs each refuse with the exact word-count message;
# nothing is armed.
# ===========================================================================
{
    for my $case (['one word', ['--goal', 'fix']],
                   ['punctuation only', ['--goal', '!!! ???']],
                   ['zero-width spaces only', ['--goal', "\x{200b}\x{200b}"]],
                   ['--goal with no value', ['--goal']]) {
        my ($label, $extra) = @$case;
        fresh_fixture();
        my $sid = sess_id('ac5');
        write_ticket_argv($sid, ['on', '--new-thread', 'ac5t', @$extra]);
        my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'ac5t', @$extra);
        is($rc, 1, "AC5 [$label]: exits 1");
        is($err, $WORDCOUNT_STDERR, "AC5 [$label]: stderr is exactly the word-count message");
        ok(!-e state_root() . "/armed/$sid", "AC5 [$label]: nothing armed");
    }
}

# ===========================================================================
# AC6 (DC3): a 2+-word goal of 201+ sanitized UTF-8 bytes refuses exactly
# with the byte-budget message; exactly 200 bytes is accepted; a non-ASCII
# goal that is 201 BYTES but fewer than 201 CHARACTERS is also refused
# (proves the budget is bytes, not characters).
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac6over');
    my $long = join(' ', ('word') x 50);   # 50 words, 249 bytes
    write_ticket_argv($sid, ['on', '--new-thread', 'ac6a', '--goal', $long]);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'ac6a', '--goal', $long);
    is($rc, 1, 'AC6 [201+ bytes]: exits 1');
    is($err, $BYTEBUDGET_STDERR, 'AC6 [201+ bytes]: stderr is exactly the byte-budget message');
    ok(!-e state_root() . "/armed/$sid", 'AC6 [201+ bytes]: nothing armed');
}
{
    fresh_fixture();
    my $sid = sess_id('ac6exact');
    # 198 'a's + a space + a 1-char word = 200 bytes, 2 words.
    my $exact = ('a' x 198) . ' b';
    is(length($exact), 200, 'AC6 fixture: the exact-200 goal really is 200 bytes');
    write_ticket_argv($sid, ['on', '--new-thread', 'ac6b', '--goal', $exact]);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'ac6b', '--goal', $exact);
    is($rc, 0, 'AC6 [exactly 200 bytes]: exits 0') or diag("stderr: $err");
    ok(-e state_root() . "/armed/$sid", 'AC6 [exactly 200 bytes]: armed');
}
{
    fresh_fixture();
    my $sid = sess_id('ac6nonascii');
    # 100 space-separated single-letter words ("é", U+00E9 repeated with
    # spaces): a genuine 2+-word goal (not one repeated-letter run), 199
    # characters, 299 UTF-8 bytes once encoded -- over the 200-byte budget
    # while staying under 201 characters, so this exercises the byte-budget
    # path specifically rather than the word-count path.
    my $nonascii = join(' ', ("\x{e9}") x 100);
    utf8::upgrade($nonascii);
    my $char_count = length($nonascii);
    ok($char_count < 201, 'AC6 fixture: the non-ASCII goal is under 201 CHARACTERS') or diag("chars: $char_count");
    utf8::encode(my $bytes = $nonascii);
    ok(length($bytes) > 200, 'AC6 fixture: the non-ASCII goal is over 200 BYTES') or diag('bytes: ' . length($bytes));
    write_ticket_argv($sid, ['on', '--new-thread', 'ac6c', '--goal', $nonascii]);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'ac6c', '--goal', $nonascii);
    is($rc, 1, 'AC6 [non-ASCII, over-budget in bytes only]: exits 1, proving the cap is bytes not chars');
    is($err, $BYTEBUDGET_STDERR, 'AC6 [non-ASCII, over-budget in bytes only]: stderr is exactly the byte-budget message');
    ok(!-e state_root() . "/armed/$sid", 'AC6 [non-ASCII, over-budget in bytes only]: nothing armed');
}

# ===========================================================================
# AC7 (DC2, DC4): a goal with a newline, a tab, an ANSI escape and a
# zero-width space, 2+ visible words, is stored and later printed as its
# sanitize_text() form (one line, controls stripped, whitespace collapsed,
# trimmed).
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac7');
    my $raw_goal = "ship\tthe\nparser\x1b[31m fix\x{200b}";
    write_ticket_argv($sid, ['on', '--new-thread', 'ac7t', '--goal', $raw_goal]);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'ac7t', '--goal', $raw_goal);
    is($rc, 0, 'AC7: on with a control/ANSI/zero-width goal exits 0') or diag("stderr: $err");
    my $d = read_json_file(state_root() . "/armed/$sid");
    ok(ref $d eq 'HASH' && defined $d->{goal} && $d->{goal} !~ /\n|\t|\x1b/,
        'AC7: the stored goal has no raw newline, tab or ANSI escape byte')
        or diag('stored goal: ' . (ref $d eq 'HASH' ? ($d->{goal} // '(undef)') : '(no record)'));

    write_ticket_argv($sid, ['status']);
    my ($sout, $serr, $src) = run_cmd({}, 'status');
    is($src, 0, 'AC7: status exits 0');
    my @lines = split /\n/, $sout;
    my ($gl) = grep { /^goal: / } @lines;
    ok(defined $gl, 'AC7: status prints a goal: line') or diag("stdout: $sout");
    if (defined $gl) {
        unlike($gl, qr/\n|\t|\x1b/, 'AC7: the printed goal line has no raw newline, tab or ANSI escape byte');
    }
}

# ===========================================================================
# AC8 (DC4): status's exact line shape for an armed session with a goal.
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac8');
    write_ticket_argv($sid, ['on', '--new-thread', 'ac8t', '--goal', 'ship the parser fix']);
    run_cmd({}, 'on', '--new-thread', 'ac8t', '--goal', 'ship the parser fix');

    write_ticket_argv($sid, ['status']);
    my ($out, $err, $rc) = run_cmd({}, 'status');
    is($rc, 0, 'AC8: status exits 0') or diag("stderr: $err");
    my @lines = split /\n/, $out;
    like($lines[0] // '', qr/^session \S+: armed \(role manual, since \S+\)$/,
        'AC8: line index 0 matches the armed-session shape');
    is($lines[1], 'goal: ship the parser fix', 'AC8: line index 1 is exactly "goal: ship the parser fix"');
    like($lines[2] // '', qr/^thread: /, 'AC8: line index 2 starts "thread: "');
}

# ===========================================================================
# AC9 (DC4): a non-ASCII goal round-trips through status in correct UTF-8,
# with no double-encoding signature (\xc3\x83).
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac9');
    my $goal = "Andr\x{e9} fixes the caf\x{e9} parser";
    write_ticket_argv($sid, ['on', '--new-thread', 'ac9t', '--goal', $goal]);
    run_cmd({}, 'on', '--new-thread', 'ac9t', '--goal', $goal);

    write_ticket_argv($sid, ['status']);
    my ($out, $err, $rc) = run_cmd({}, 'status');
    is($rc, 0, 'AC9: status exits 0') or diag("stderr: $err");
    utf8::encode(my $want_bytes = $goal);
    my $count = () = $out =~ /\Q$want_bytes\E/g;
    is($count, 1, 'AC9: the UTF-8 bytes of the goal appear exactly once in status stdout')
        or diag('stdout bytes: ' . unpack('H*', $out));
    unlike($out, qr/\xc3\x83/, 'AC9: no double-encoding signature (\xc3\x83) in status stdout');
}

# ===========================================================================
# AC10 (DC5): a coordinator's `on` ignores --goal entirely (present,
# absent, well-formed or malformed) and status shows no goal: line.
# ===========================================================================
{
    for my $case (['bare on', []],
                   ['well-formed goal', ['--goal', 'x y']],
                   ['malformed one-word goal', ['--goal', 'x']],
                   ['thread plus empty goal', ['--new-thread', 't', '--goal', '']]) {
        my ($label, $extra) = @$case;
        fresh_fixture();
        my $sid = sess_id('ac10');
        write_ticket_argv($sid, ['on', @$extra]);
        my ($out, $err, $rc) = run_cmd({ BP_LEDGER => '/x/ledger.md' }, 'on', @$extra);
        is($rc, 0, "AC10 [$label]: exits 0") or diag("stderr: $err");
        is($out, "continuity is on by construction for a coordinator; nothing to do.\n",
            "AC10 [$label]: stdout is exactly the nothing-to-do line");
        ok(!-e state_root() . "/armed/$sid", "AC10 [$label]: armed/<sid> absent");

        write_ticket_argv($sid, ['status']);
        my ($sout, $serr, $src) = run_cmd({ BP_LEDGER => '/x/ledger.md' }, 'status');
        is($src, 0, "AC10 [$label]: status exits 0");
        my @lines = split /\n/, $sout;
        is($lines[0], 'session ' . s8($sid) . ': armed (coordinator)', "AC10 [$label]: status line 0 is the coordinator line");
        ok(!(grep { /^goal:/ } @lines), "AC10 [$label]: status prints no goal: line");
    }
}

# ===========================================================================
# AC11 (DC6): a pre-package arm record with no goal, and every other
# non-string/empty/corrupt shape, surfaces as "goal: (no goal recorded)",
# never a crash.
# ===========================================================================
{
    my @cases = (
        ['no goal key', sub { { session_id => $_[0], role => 'manual', by => 'on', at => '2020-01-01T00:00:00.000Z' } }],
        ['goal empty string', sub { { session_id => $_[0], role => 'manual', by => 'on', at => '2020-01-01T00:00:00.000Z', goal => '' } }],
        ['goal null', sub { { session_id => $_[0], role => 'manual', by => 'on', at => '2020-01-01T00:00:00.000Z', goal => undef } }],
        ['goal array', sub { { session_id => $_[0], role => 'manual', by => 'on', at => '2020-01-01T00:00:00.000Z', goal => [] } }],
        ['goal object', sub { { session_id => $_[0], role => 'manual', by => 'on', at => '2020-01-01T00:00:00.000Z', goal => {} } }],
    );
    for my $case (@cases) {
        my ($label, $builder) = @$case;
        fresh_fixture();
        my $sid = sess_id('ac11');
        my $root = state_root();
        make_path("$root/armed");
        open my $fh, '>', "$root/armed/$sid" or die $!;
        print {$fh} JSON::PP->new->encode($builder->($sid));
        close $fh;

        write_ticket_argv($sid, ['status']);
        my ($out, $err, $rc) = run_cmd({}, 'status');
        is($rc, 0, "AC11 [$label]: status exits 0") or diag("stderr: $err");
        my @lines = split /\n/, $out;
        is($lines[1], 'goal: (no goal recorded)', "AC11 [$label]: line index 1 is exactly the no-goal-recorded line");
    }
    {
        fresh_fixture();
        my $sid = sess_id('ac11nonjson');
        my $root = state_root();
        make_path("$root/armed");
        open my $fh, '>', "$root/armed/$sid" or die $!;
        print {$fh} "this is not valid json at all\n";
        close $fh;
        write_ticket_argv($sid, ['status']);
        my ($out, $err, $rc) = run_cmd({}, 'status');
        is($rc, 0, 'AC11 [non-JSON file]: status exits 0') or diag("stderr: $err");
        my @lines = split /\n/, $out;
        is($lines[1], 'goal: (no goal recorded)', 'AC11 [non-JSON file]: line index 1 is exactly the no-goal-recorded line');
    }
}

# ===========================================================================
# AC12 (DC6): is_armed/role/disarm are unaffected by goal; a goal containing
# the literal text '"role":"driver"' cannot forge driver detection because
# JSON encoding escapes the quotes.
# ===========================================================================
{
    ok(BpHook::arm('acsid12a', role => 'manual', by => 'on'), 'AC12 fixture: arm with no goal succeeds');
    is(BpHook::is_armed('acsid12a'), 1, 'AC12: is_armed is 1 for a goal-less record');
    is(BpHook::role({ session_id => 'acsid12a' }), 'manual', 'AC12: role() returns the stored role (no goal)');
    ok(BpHook::disarm('acsid12a', actor => 'agent', reason => 'a b'), 'AC12: disarm() returns 1 (no goal)');

    ok(BpHook::arm('acsid12b', role => 'manual', by => 'on', goal => 'ship it now please'), 'AC12 fixture: arm with a goal succeeds');
    is(BpHook::is_armed('acsid12b'), 1, 'AC12: is_armed is 1 for a goal-bearing record');
    is(BpHook::role({ session_id => 'acsid12b' }), 'manual', 'AC12: role() returns the stored role (with goal)');
    ok(BpHook::disarm('acsid12b', actor => 'agent', reason => 'a b'), 'AC12: disarm() returns 1 (with goal)');

    # Forgery check against run-hook.sh's *'"role":"driver"'* substring match.
    ok(BpHook::arm('acsid12c', role => 'manual', by => 'on', goal => 'pretend "role":"driver" here'),
        'AC12 fixture: arm with a forging goal succeeds');
    my $root = BpHook::state_dir();
    my $raw = slurp("$root/armed/acsid12c");
    my ($first_line) = split /\n/, $raw;
    unlike($first_line // '', qr/"role":"driver"/,
        'AC12: a manual record with a forging goal does not contain the literal "role":"driver" substring')
        or diag("first line: " . ($first_line // '(undef)'));
    is(BpHook::role({ session_id => 'acsid12c' }), 'manual', 'AC12: role() still returns manual despite the forging goal');

    # Conversely, a genuine driver record DOES contain the substring,
    # whatever its goal.
    ok(BpHook::arm('acsid12d', role => 'driver', by => 'on', goal => 'a real driver goal'),
        'AC12 fixture: arm a real driver record succeeds');
    my $raw2 = slurp("$root/armed/acsid12d");
    my ($first_line2) = split /\n/, $raw2;
    like($first_line2 // '', qr/"role":"driver"/,
        'AC12: a genuine driver record DOES contain the literal "role":"driver" substring');
}

# ===========================================================================
# AC13 (DC7): on --role reporter with no goal still succeeds and stores no
# goal key (continuity-lease-follows-arm.t's own reporter call, line ~409,
# is the unmodified regression oracle for the CLI shape; this checks the
# record content).
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac13');
    write_ticket_argv($sid, ['on', '--role', 'reporter']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--role', 'reporter');
    is($rc, 0, 'AC13: on --role reporter (no goal) exits 0') or diag("stderr: $err");
    my $d = read_json_file(state_root() . "/armed/$sid");
    ok(ref $d eq 'HASH' && !exists $d->{goal}, 'AC13: the reporter record has no goal key at all')
        or diag("record: " . (ref $d eq 'HASH' ? join(',', keys %$d) : '(no record)'));
}

# ===========================================================================
# AC14 (DC7 edge): on --role reporter --goal '<2+ words>' stores the goal;
# on --role reporter --goal one refuses with the word-count message.
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac14ok');
    write_ticket_argv($sid, ['on', '--role', 'reporter', '--goal', 'watch the build queue']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--role', 'reporter', '--goal', 'watch the build queue');
    is($rc, 0, 'AC14 [reporter with a valid goal]: exits 0') or diag("stderr: $err");
    my $d = read_json_file(state_root() . "/armed/$sid");
    is(ref $d eq 'HASH' ? $d->{goal} : undef, 'watch the build queue', 'AC14: goal eq "watch the build queue"');
}
{
    fresh_fixture();
    my $sid = sess_id('ac14bad');
    write_ticket_argv($sid, ['on', '--role', 'reporter', '--goal', 'one']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--role', 'reporter', '--goal', 'one');
    is($rc, 1, 'AC14 [reporter with a one-word goal]: exits 1');
    is($err, $WORDCOUNT_STDERR, 'AC14 [reporter with a one-word goal]: stderr is exactly the word-count message');
    ok(!-e state_root() . "/armed/$sid", 'AC14 [reporter with a one-word goal]: nothing armed');
}

# ===========================================================================
# AC15 (DC8): re-arm preserve through the CLI then a direct no-goal arm()
# call (ArmOnEntry's own shape): the prior goal survives, the role updates.
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac15');
    write_ticket_argv($sid, ['on', '--new-thread', 'ac15t', '--goal', 'ship the parser fix']);
    run_cmd({}, 'on', '--new-thread', 'ac15t', '--goal', 'ship the parser fix');

    ok(BpHook::arm($sid, role => 'driver', by => 'arm-on-entry'), 'AC15: the no-goal re-arm returns 1');
    my $d = read_json_file(state_root() . "/armed/$sid");
    is(ref $d eq 'HASH' ? $d->{goal} : undef, 'ship the parser fix', 'AC15: the goal is still "ship the parser fix"');
    is(ref $d eq 'HASH' ? $d->{role} : undef, 'driver', 'AC15: the role is now driver');

    write_ticket_argv($sid, ['status']);
    my ($out, $err, $rc) = run_cmd({}, 'status');
    my @lines = split /\n/, $out;
    is($lines[1], 'goal: ship the parser fix', 'AC15: status line index 1 is still "goal: ship the parser fix"');
}

# ===========================================================================
# AC16 (DC8): an explicit new goal replaces the old one (in-process, and
# through a second CLI on call); goal => '' or undef preserves it; a
# reporter re-arm over a goal-bearing record preserves it too.
# ===========================================================================
{
    ok(BpHook::arm('acsid16a', role => 'manual', by => 'on', goal => 'first purpose'), 'AC16 fixture: initial arm with goal A');
    ok(BpHook::arm('acsid16a', role => 'manual', by => 'on', goal => 'new purpose here'), 'AC16: replace returns 1');
    is(BpHook::state_dir() && read_json_file(BpHook::state_dir() . "/armed/acsid16a")->{goal}, 'new purpose here',
        'AC16: in-process replace: goal is now "new purpose here"');
}
{
    fresh_fixture();
    my $sid = sess_id('ac16cli');
    write_ticket_argv($sid, ['on', '--new-thread', 'ac16t', '--goal', 'first goal text']);
    run_cmd({}, 'on', '--new-thread', 'ac16t', '--goal', 'first goal text');
    write_ticket_argv($sid, ['on', '--thread', 'ac16t', '--goal', 'second goal text']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--thread', 'ac16t', '--goal', 'second goal text');
    is($rc, 0, 'AC16 [CLI replace]: the second on exits 0') or diag("stderr: $err");
    my $d = read_json_file(state_root() . "/armed/$sid");
    is(ref $d eq 'HASH' ? $d->{goal} : undef, 'second goal text', 'AC16 [CLI replace]: goal is now "second goal text"');
}
{
    ok(BpHook::arm('acsid16b', role => 'manual', by => 'on', goal => 'keep this one'), 'AC16 fixture: initial arm with a goal');
    ok(BpHook::arm('acsid16b', role => 'manual', by => 'on', goal => ''), 'AC16 [empty string]: re-arm returns 1');
    is(read_json_file(BpHook::state_dir() . "/armed/acsid16b")->{goal}, 'keep this one',
        'AC16 [empty string]: the prior goal is preserved');
    ok(BpHook::arm('acsid16b', role => 'manual', by => 'on', goal => undef), 'AC16 [undef]: re-arm returns 1');
    is(read_json_file(BpHook::state_dir() . "/armed/acsid16b")->{goal}, 'keep this one',
        'AC16 [undef]: the prior goal is preserved');
}
{
    fresh_fixture();
    my $sid = sess_id('ac16reporter');
    write_ticket_argv($sid, ['on', '--new-thread', 'ac16r', '--goal', 'reporter preserve goal']);
    run_cmd({}, 'on', '--new-thread', 'ac16r', '--goal', 'reporter preserve goal');
    write_ticket_argv($sid, ['on', '--role', 'reporter']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--role', 'reporter');
    is($rc, 0, 'AC16 [reporter re-arm over a goal-bearing record]: exits 0') or diag("stderr: $err");
    my $d = read_json_file(state_root() . "/armed/$sid");
    is(ref $d eq 'HASH' ? $d->{goal} : undef, 'reporter preserve goal',
        'AC16 [reporter re-arm]: the goal is preserved');
}

# ===========================================================================
# AC17 (DC8 edge, DC6): arm() with no goal over no prior record, and over a
# corrupt prior record, returns 1 and writes a record with no goal key.
# ===========================================================================
{
    ok(BpHook::arm('acsid17a', role => 'manual', by => 'on'), 'AC17 [no prior record]: arm() returns 1');
    my $d = read_json_file(BpHook::state_dir() . "/armed/acsid17a");
    ok(ref $d eq 'HASH' && !exists $d->{goal}, 'AC17 [no prior record]: no goal key in the written record');
}
{
    my $root = BpHook::state_dir();
    make_path("$root/armed");
    open my $fh, '>', "$root/armed/acsid17b" or die $!;
    print {$fh} "not json garbage at all\n";
    close $fh;
    ok(BpHook::arm('acsid17b', role => 'manual', by => 'on'), 'AC17 [corrupt prior record]: arm() returns 1');
    my $d = read_json_file("$root/armed/acsid17b");
    ok(ref $d eq 'HASH' && !exists $d->{goal}, 'AC17 [corrupt prior record]: no goal key in the written record');
}

# ===========================================================================
# AC18 (DC2 robustness): arm() with a reference goal returns 0, last_error
# is "bad goal", and the prior record on disk is unchanged.
# ===========================================================================
{
    ok(BpHook::arm('acsid18', role => 'manual', by => 'on', goal => 'a prior real goal'), 'AC18 fixture: initial arm succeeds');
    my $before = slurp(BpHook::state_dir() . "/armed/acsid18");
    my $ok = BpHook::arm('acsid18', role => 'manual', by => 'on', goal => [1]);
    is($ok, 0, 'AC18: arm() with an array-ref goal returns 0');
    is(BpHook::last_error(), 'bad goal', 'AC18: last_error() is exactly "bad goal"');
    my $after = slurp(BpHook::state_dir() . "/armed/acsid18");
    is($after, $before, 'AC18: the prior record on disk is byte-unchanged');
}

# ===========================================================================
# AC19 (DC1/DC2 parse): off --goal and status --goal are usage errors (an
# unknown flag on those verbs); a repeated --goal on `on` is a usage error.
# ===========================================================================
{
    fresh_fixture();
    my $sid = sess_id('ac19off');
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), 'AC19 fixture: armed directly');
    write_ticket_argv($sid, ['off', '--goal', 'a b']);
    my ($out, $err, $rc) = run_cmd({}, 'off', '--goal', 'a b');
    is($rc, 1, 'AC19 [off --goal]: exits 1');
    like($err, qr/^butler-continuity: usage:/, 'AC19 [off --goal]: stderr starts with the usage prefix');
}
{
    fresh_fixture();
    my $sid = sess_id('ac19status');
    write_ticket_argv($sid, ['status', '--goal', 'a b']);
    my ($out, $err, $rc) = run_cmd({}, 'status', '--goal', 'a b');
    is($rc, 1, 'AC19 [status --goal]: exits 1');
    like($err, qr/^butler-continuity: usage:/, 'AC19 [status --goal]: stderr starts with the usage prefix');
}
{
    fresh_fixture();
    my $sid = sess_id('ac19dup');
    write_ticket_argv($sid, ['on', '--new-thread', 'ac19t', '--goal', 'a b', '--goal', 'c d']);
    my ($out, $err, $rc) = run_cmd({}, 'on', '--new-thread', 'ac19t', '--goal', 'a b', '--goal', 'c d');
    is($rc, 1, 'AC19 [repeated --goal on on]: exits 1');
    like($err, qr/^butler-continuity: usage:/, 'AC19 [repeated --goal on on]: stderr starts with the usage prefix');
    ok(!-e state_root() . "/armed/$sid", 'AC19 [repeated --goal on on]: nothing armed');
}

# ===========================================================================
# AC20 (structure): NOT independently tested here -- `perl -c` on the two
# changed files, and plan-restored-on-last-off.t's existing block-shape
# assertions over every top-level `if ($verb eq 'on') {` block, are enforced
# by that pre-existing oracle (outside this package's test_paths) once Step
# 2c actually exists. Noted per spec sec 4 ("you don't need to write a new
# test for it").
# ===========================================================================

done_testing();
