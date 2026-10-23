#!/usr/bin/env perl
# platform: any
# ORACLE for package 06 (blueprint hook-continuity-remake), non-coordinator
# side: specs/06-stop-gate-spec.md S1-S21 (DC1) + B1-B4 (DC3). The single
# Stop gate's decision table (G1-G11): unarmed allow, own-live-holder allow,
# a denial's exact 7-line continuity text and minted token, every retired
# override ignored, and the Decision-33 process budget for
# a session the gate does not apply to.
#
# The hook file and its perl module DO NOT EXIST YET: every subprocess run
# below invokes the REAL bash wrapper on disk, so with nothing there yet a
# case either sees a plain "No such file or directory" (127) or, once the
# wrapper exists but its module does not, an unconditional allow via the
# core's fail-open -- either way a case fails legibly rather than crashing
# this file.
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
use Time::HiRes qw(sleep time);

(my $BUTLER = "$Bin/../..") =~ s{\\}{/}g;
my $HOOK = "$BUTLER/hooks/stop-gate.sh";
my $S    = "$BUTLER/scripts";

require "$S/BpHook.pm";    # package 03 -- real and already implemented

# ---------------------------------------------------------------------------
# process bookkeeping -- every spawned child (subprocess gate runs, holder
# fixtures) is reaped here, TERM then KILL, routed through exit() so END
# always runs.
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

# ---------------------------------------------------------------------------
# guard: never touch the real ~/.claude or ~/.ccpraxis-local-data
# ---------------------------------------------------------------------------
my ($REAL_BSTATE, $REAL_BSTATE_EXISTS, $REAL_BSTATE_MTIME);
{
    my $rh = $ENV{HOME} // $ENV{USERPROFILE};
    if (defined $rh && length $rh) {
        (my $rhn = $rh) =~ s{\\}{/}g;
        $REAL_BSTATE = "$rhn/.claude/butler-state";
        $REAL_BSTATE_EXISTS = -d $REAL_BSTATE ? 1 : 0;
        $REAL_BSTATE_MTIME  = $REAL_BSTATE_EXISTS ? (stat($REAL_BSTATE))[9] : undef;
    }
}
my $FAKE_HOME_ROOT = tempdir(CLEANUP => 1);
(my $FAKE_HOME = "$FAKE_HOME_ROOT/decoy-home") =~ s{\\}{/}g;
make_path($FAKE_HOME);
$ENV{HOME}        = $FAKE_HOME;
$ENV{USERPROFILE} = $FAKE_HOME;

my $ANDRE_SEG = "Andr\xC3\xA9";    # raw UTF-8 bytes, matches package-05 convention
sub fresh_state_root { my $t = tempdir(CLEANUP => 1); (my $r = "$t/state") =~ s{\\}{/}g; return $r }
sub andre_state_root { my $t = tempdir(CLEANUP => 1); (my $r = "$t/$ANDRE_SEG/state") =~ s{\\}{/}g; return $r }

my $REAL_BASH_ABS = do { my $p = `bash -c "command -v bash"`; chomp $p; $p };
BAIL_OUT('cannot resolve a real bash on PATH') unless length $REAL_BASH_ABS;

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

# ---------------------------------------------------------------------------
# run_gate(payload_json, %env) -> {rc, out, err}. Real subprocess through
# the actual stop-gate.sh, stdin from a File::Temp payload file, bounded by
# a hard alarm backstop, output captured to File::Temp files.
# ---------------------------------------------------------------------------
sub run_gate {
    my ($payload_json, %env) = @_;
    my ($pfh, $ppath) = tempfile(); print {$pfh} $payload_json; close $pfh;
    my (undef, $opath) = tempfile();
    my (undef, $epath) = tempfile();

    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    for my $k (keys %env) {
        if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
    }

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', $ppath) or _exit(126);
        open(STDOUT, '>', $opath) or _exit(126);
        open(STDERR, '>', $epath) or _exit(126);
        exec($REAL_BASH_ABS, $HOOK);
        _exit(127);
    }
    push @KILL_PIDS, $pid;
    my $deadline = time() + 15;
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.02);
    }
    unless (defined $rc) {
        kill('KILL', $pid);
        waitpid($pid, 0);
        $rc = -1;
    }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    my $out = slurp($opath);
    my $err = slurp($epath);
    unlink $ppath, $opath, $epath;
    return { rc => $rc, out => $out, err => $err };
}

my $STOPGATE_PM = "$S/BpHook/StopGate.pm";

sub load_stopgate {
    return 1 if $INC{'BpHook/StopGate.pm'};
    local $@;
    return eval { require $STOPGATE_PM; 1 };
}

# run_gate_inprocess(payload_json, %env) -> {rc, err, loaded}. Mirrors the
# in-process seam: BpHook::load_payload, then BpHook::StopGate::run($p),
# with STDERR dup'ed to a File::Temp file.
sub run_gate_inprocess {
    my ($payload_json, %env) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    for my $k (keys %env) {
        if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
    }
    BpHook::load_payload($payload_json);
    my $p = BpHook::payload();

    my (undef, $epath) = tempfile();
    open(my $saved_err, '>&', \*STDERR) or die "dup STDERR: $!";
    close STDERR;
    open(STDERR, '>', $epath) or die "reopen STDERR: $!";

    my $loaded = load_stopgate();
    my $rc;
    if ($loaded) {
        local $@;
        $rc = eval { BpHook::StopGate::run($p) };
        $rc = 0 unless defined $rc && $rc == 2;
    }

    close STDERR;
    open(STDERR, '>&', $saved_err) or die "restore STDERR: $!";
    close $saved_err;
    my $err = slurp($epath);
    unlink $epath;
    return { rc => (defined $rc ? $rc : 0), err => $err, loaded => $loaded };
}

sub payload_json {
    my ($sid, %extra) = @_;
    my %p = (session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false());
    %p = (%p, %extra);
    return JSON::PP->new->utf8->canonical->encode(\%p);
}

sub state_dir_of { my ($root) = @_; return "$root/continuity" }

sub arm_session {
    my ($root, $sid, %opts) = @_;
    local %ENV = %ENV;
    delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
    $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
    $ENV{BUTLER_STATE_DIR} = $root;
    my $ok = BpHook::arm($sid, role => ($opts{role} // 'manual'), by => 'arm-on-entry');
    return $ok;
}

# plant_silence($root, $sid, %o) -- hand-plant a valid-shape silence/<sid>
# record directly on disk (spec 05-remove-silence section 2.2/B6):
# set_silence is removed, so this writes the old valid JSON shape itself.
sub plant_silence {
    my ($root, $sid, %opts) = @_;
    my $dir = state_dir_of($root) . '/silence';
    make_path($dir);
    my $path = "$dir/$sid";
    open my $fh, '>:raw', $path or die "plant_silence: $!";
    print {$fh} (defined $opts{raw} ? $opts{raw} : JSON::PP->new->encode({
        session_id => $sid, by => 'butler-continuity',
        reason => ($opts{reason} // 'reporting progress now'), at => time(),
    }));
    close $fh;
    return $path;
}

sub read_json_file {
    my ($p) = @_;
    return undef unless -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return eval { JSON::PP->new->utf8->decode($c) };
}

sub read_first_line {
    my ($p) = @_;
    return undef unless -f $p;
    open my $fh, '<:raw', $p or return undef;
    my $l = <$fh>;
    close $fh;
    $l =~ s/\s+\z// if defined $l;
    return $l;
}

# ---------------------------------------------------------------------------
# holder fixtures (per spec sec 4): a real spawned child, a holder/<sid>.json
# written directly (never via a command), and the child killed at END.
# ---------------------------------------------------------------------------
my $HAVE_PROC_CMDLINE = -r '/proc/self/cmdline' ? 1 : 0;

my $SLEEPER_SEQ = 0;
sub spawn_sleeper {
    # a unique per-invocation marker, not just the shared "sleep" shell of
    # the command: two sleepers otherwise exec byte-identical argv, so a
    # cmdline fingerprint could never distinguish "this child" from "some
    # other live child" (needed by S9's "fp of a different live child").
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
    # fork/exec race: on this MSYS host /proc/<pid>/cmdline of a freshly
    # forked child reads the PARENT's cmdline for 50-100ms, until exec
    # lands. Wait, bounded to 5s at 20ms steps, until the child's OWN
    # tagged cmdline is visible, so callers never fingerprint the parent
    # (or, worse, another child's already-landed cmdline).
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

sub kill_sleeper {
    my ($pid) = @_;
    return unless $pid;
    kill('TERM', $pid) if kill(0, $pid);
    my $deadline = time() + 5;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        last if $w == $pid;
        sleep(0.05);
    }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
}

sub cmdline_fp_of {
    my ($pid) = @_;
    return sha1_hex('') unless $HAVE_PROC_CMDLINE;
    open(my $fh, '<:raw', "/proc/$pid/cmdline") or return sha1_hex('');
    local $/;
    my $c = <$fh>;
    close $fh;
    return sha1_hex(defined $c ? $c : '');
}

sub write_holder {
    my ($root, $sid, %o) = @_;
    my $dir = state_dir_of($root) . "/holder";
    make_path($dir);
    my $rec = {
        session_id => $sid,
        token      => $o{token} // 'deadbeef',
        pid        => $o{pid},
        fp         => $o{fp},
        items      => $o{items} // [],
        started_at => $o{started_at} // int(time() - 10),
    };
    $rec->{deadline} = $o{deadline} if exists $o{deadline};
    delete $rec->{pid} unless exists $o{pid};
    delete $rec->{fp}  unless exists $o{fp};
    open my $fh, '>:raw', state_dir_of($root) . "/holder/$sid.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec);
    close $fh;
}

my $sidn = 0;
sub next_sid { return sprintf('sg1-%04x', ++$sidn) }

# ===========================================================================
# S1 -- unarmed session Stop -> allow; no token file.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    my $res = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    is($res->{rc}, 0, 'S1: unarmed session Stop -> exit 0');
    is($res->{err}, '', 'S1: stderr empty');
    ok(!-e (state_dir_of($root) . "/stop-tokens/$sid.current"), 'S1: no stop-tokens/<sid>.current created');
}

# ===========================================================================
# S2 -- armed, no holder -> deny with the exact 7-line continuity text.
# ===========================================================================
my ($S2_ROOT, $S2_SID, $S2_TOKEN);
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $res = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, 'S2 (re-expresses the retired graceful-stop-gate coverage "gate-stop: no signal + non-terminal -> blocked"): subprocess exit 2');
    is($res->{out}, '', 'S2: stdout empty');
    my @lines = lines_of($res->{err});
    is(scalar(@lines), 6, 'S2: stderr is exactly 6 lines') or diag("stderr:\n$res->{err}");
    my ($tok) = ($lines[0] // '') =~ /Stop token: ([0-9a-f]{8})\z/;
    ok(defined $tok, 'S2: line 1 carries an 8-hex token') or diag($lines[0] // '');
    SKIP: {
        skip 'S2: no token extracted', 5 unless defined $tok;
        # 2.4.3 (spec 05-remove-silence): the idle deny text, with the
        # escape-hatch/silence lines deleted outright.
        # 04-docs-and-wiring (spec 2.8): two-step off + emergency-stop mention.
        my $expected = <<"TXT";
Continuity is on for this session and no holder is running. Stop token: $tok
Waiting on a subagent or background task? Hold it, as a background Bash tool call:
  butler-hold --token $tok <id> [<id> ...]
All work done? Turn continuity off (two steps: off mints an OTP, then off-confirm with it), as a Bash tool call:
  butler-continuity off --reason '<what is done>' --token $tok
(Genuine ccpraxis/Claude-Code defect, not just finished work? butler-continuity emergency-stop --reason '<the actual defect>' instead -- not a normal option.)
TXT
        is($res->{err}, $expected, 'S2: stderr is exactly the updated continuity template (two-step off + emergency-stop mention) with the token substituted in all 3 places');
        like($res->{err}, qr/butler-hold/, 'S2: stderr contains butler-hold');
        like($res->{err}, qr/butler-continuity off --reason/, 'S2: stderr contains butler-continuity off --reason');
        unlike($res->{err}, qr/silence/, 'AC14: stderr contains no "silence"');
        $S2_ROOT = $root; $S2_SID = $sid; $S2_TOKEN = $tok;
    }
}

# ===========================================================================
# S3 -- the minted token resolves via BpHook::take_stop_token.
# ===========================================================================
SKIP: {
    skip 'S3: S2 did not mint a token', 3 unless defined $S2_TOKEN;
    local %ENV = %ENV;
    $ENV{BUTLER_STATE_DIR} = $S2_ROOT;
    my $tok_data = read_json_file(state_dir_of($S2_ROOT) . "/stop-tokens/$S2_TOKEN");
    is(ref($tok_data) eq 'HASH' ? $tok_data->{session_id} : undef, $S2_SID,
        'S3: stop-tokens/<t> decodes with session_id = sid');
    is(read_first_line(state_dir_of($S2_ROOT) . "/stop-tokens/$S2_SID.current"), $S2_TOKEN,
        'S3: <sid>.current holds t');
    # take_stop_token consumes it -- run it last.
    is(BpHook::take_stop_token($S2_TOKEN), $S2_SID, 'S3: BpHook::take_stop_token(t) returns sid');
}

# ===========================================================================
# S4 -- two consecutive denials mint different tokens; the first is revoked;
# a holder-allowed Stop after a denial also revokes it.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $r1 = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    my ($t1) = ($r1->{err} =~ /Stop token: ([0-9a-f]{8})/);
    my $r2 = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    my ($t2) = ($r2->{err} =~ /Stop token: ([0-9a-f]{8})/);
    ok(defined $t1 && defined $t2, 'S4: precondition -- both denials minted a token');
    SKIP: {
        skip 'S4: no tokens to compare', 3 unless defined $t1 && defined $t2;
        isnt($t1, $t2, 'S4: two consecutive denials yield different tokens');
        local %ENV = %ENV;
        $ENV{BUTLER_STATE_DIR} = $root;
        ok(!-e (state_dir_of($root) . "/stop-tokens/$t1"), 'S4: after the second denial, the first token file is gone');
        is(BpHook::take_stop_token($t1), undef, 'S4: take_stop_token(first) is undef');
    }

    # a holder-allowed stop after a denial also revokes the pending token
    # (S5's fixture: spawn_sleeper, write_holder items ['B'], background_tasks
    # running B).
    my $sid2 = next_sid();
    arm_session($root, $sid2);
    my $rd = run_gate(payload_json($sid2), BUTLER_STATE_DIR => $root);
    my ($td) = ($rd->{err} =~ /Stop token: ([0-9a-f]{8})/);
    ok(defined $td, 'S4: precondition -- a denial for sid2 minted a token');
    my $pid = spawn_sleeper();
    write_holder($root, $sid2, pid => $pid, fp => cmdline_fp_of($pid), items => ['B'], deadline => int(time() + 1800));
    my $rs = run_gate(payload_json($sid2, background_tasks => [{ id => 'B', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);
    is($rs->{rc}, 0, 'S4: the holder-allowed stop exits 0');
    SKIP: {
        skip 'S4: no token to check', 1 unless defined $td;
        local %ENV = %ENV;
        $ENV{BUTLER_STATE_DIR} = $root;
        ok(!-e (state_dir_of($root) . "/stop-tokens/$td"), 'S4: ...and the pending denial token is revoked too');
    }
    kill_sleeper($pid);
}

# ===========================================================================
# S5-S9 -- the holder rule.
# ===========================================================================
{
    # S5: live own holder + held id running in background_tasks -> allow.
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $pid = spawn_sleeper();
    write_holder($root, $sid, pid => $pid, fp => cmdline_fp_of($pid), items => ['B'], deadline => int(time() + 1800));
    my $res = run_gate(payload_json($sid, background_tasks => [{ id => 'B', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);
    is($res->{rc}, 0, 'S5: live own holder + held id running -> exit 0');
    is($res->{err}, '', 'S5: stderr empty');
    local %ENV = %ENV; $ENV{BUTLER_STATE_DIR} = $root;
    ok(!-e (state_dir_of($root) . "/stop-tokens/$sid.current"), 'S5: no <sid>.current');
    kill_sleeper($pid);
}
{
    # S6: live own holder, no background_tasks key at all -> allow.
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $pid = spawn_sleeper();
    write_holder($root, $sid, pid => $pid, fp => cmdline_fp_of($pid), items => ['B'], deadline => int(time() + 1800));
    my $res = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    is($res->{rc}, 0, 'S6: live own holder, payload without background_tasks -> exit 0');
    kill_sleeper($pid);
}
{
    # S7 (Decision 131): live own holder with non-empty items -> allow, no
    # matter what background_tasks says. A live holder is itself a
    # background task whose exit re-invokes the session, so the Stop is
    # allowed (exit 0, empty stderr, no <sid>.current) whether the held id
    # is completed, absent, or only unheld work runs.
    my @cases = (
        ['held id completed'   => [{ id => 'B', type => 'subagent', status => 'completed' }]],
        ['only non-held running' => [{ id => 'Q', type => 'subagent', status => 'running' }]],
        ['empty background_tasks' => []],
    );
    for my $c (@cases) {
        my ($label, $bg) = @$c;
        my $root = fresh_state_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        my $pid = spawn_sleeper();
        write_holder($root, $sid, pid => $pid, fp => cmdline_fp_of($pid), items => ['B'], deadline => int(time() + 1800));
        my $res = run_gate(payload_json($sid, background_tasks => $bg), BUTLER_STATE_DIR => $root);
        is($res->{rc}, 0, "S7 [$label]: exit 0");
        is($res->{err}, '', "S7 [$label]: stderr empty");
        local %ENV = %ENV; $ENV{BUTLER_STATE_DIR} = $root;
        ok(!-e (state_dir_of($root) . "/stop-tokens/$sid.current"), "S7 [$label]: no <sid>.current");
        kill_sleeper($pid);
    }
}
{
    # S7b (Decision 131): a live own holder with an EMPTY items record never
    # counts as holder_live -- deny.
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $pid = spawn_sleeper();
    write_holder($root, $sid, pid => $pid, fp => cmdline_fp_of($pid), items => [], deadline => int(time() + 1800));
    my $res = run_gate(payload_json($sid, background_tasks => [{ id => 'B', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, 'S7b: live own holder with items=[] -> exit 2');
    kill_sleeper($pid);
}
{
    # S8: another session's live holder never counts.
    my $root  = fresh_state_root();
    my $sid   = next_sid();
    my $other = next_sid();
    arm_session($root, $sid);
    my $pid = spawn_sleeper();
    write_holder($root, $other, pid => $pid, fp => cmdline_fp_of($pid), items => ['B'], deadline => int(time() + 1800));
    my $res = run_gate(payload_json($sid, background_tasks => [{ id => 'B', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, "S8: another session's holder record (holder/<other>.json) -> exit 2");
    kill_sleeper($pid);

    my $sid2 = next_sid();
    my $pid2 = spawn_sleeper();
    arm_session($root, $sid2);
    write_holder($root, $sid2, session_id_override => $other, pid => $pid2, fp => cmdline_fp_of($pid2),
        items => ['B'], deadline => int(time() + 1800));
    # holder/<sid2>.json naming a different session_id: overwrite the file directly.
    my $rec = read_json_file(state_dir_of($root) . "/holder/$sid2.json");
    $rec->{session_id} = $other;
    open my $fh, '>:raw', state_dir_of($root) . "/holder/$sid2.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($rec);
    close $fh;
    my $res2 = run_gate(payload_json($sid2, background_tasks => [{ id => 'B', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);
    is($res2->{rc}, 2, 'S8: holder/<sid>.json naming another session_id -> exit 2');
    kill_sleeper($pid2);
}
{
    # S9 (edge): stale records -> exit 2 each.
    my $root = fresh_state_root();
    my $bg = [{ id => 'B', type => 'subagent', status => 'running' }];

    my $sid1 = next_sid(); arm_session($root, $sid1);
    my $pid1 = spawn_sleeper();
    write_holder($root, $sid1, pid => $pid1, fp => cmdline_fp_of($pid1), items => ['B'], deadline => int(time() - 10));
    is(run_gate(payload_json($sid1, background_tasks => $bg), BUTLER_STATE_DIR => $root)->{rc}, 2,
        'S9: deadline in the past -> exit 2');
    kill_sleeper($pid1);

    my $sid2 = next_sid(); arm_session($root, $sid2);
    my $pid2 = spawn_sleeper();
    write_holder($root, $sid2, pid => $pid2, fp => cmdline_fp_of($pid2), items => ['B']);   # no deadline key
    is(run_gate(payload_json($sid2, background_tasks => $bg), BUTLER_STATE_DIR => $root)->{rc}, 2,
        'S9: no deadline -> exit 2');
    kill_sleeper($pid2);

    my $sid3 = next_sid(); arm_session($root, $sid3);
    my $pid3 = spawn_sleeper();
    my $fp3  = cmdline_fp_of($pid3);
    kill_sleeper($pid3);    # kill it now, before the gate ever runs
    write_holder($root, $sid3, pid => $pid3, fp => $fp3, items => ['B'], deadline => int(time() + 1800));
    is(run_gate(payload_json($sid3, background_tasks => $bg), BUTLER_STATE_DIR => $root)->{rc}, 2,
        'S9: pid of a killed child -> exit 2');

  SKIP: {
        skip 'S9: /proc/self/cmdline unavailable on this host', 1 unless $HAVE_PROC_CMDLINE;
        my $sid4 = next_sid(); arm_session($root, $sid4);
        my $pid4 = spawn_sleeper();
        my $other_pid = spawn_sleeper();
        write_holder($root, $sid4, pid => $pid4, fp => cmdline_fp_of($other_pid), items => ['B'], deadline => int(time() + 1800));
        is(run_gate(payload_json($sid4, background_tasks => $bg), BUTLER_STATE_DIR => $root)->{rc}, 2,
            "S9: fp of a different live child's cmdline -> exit 2");
        kill_sleeper($pid4);
        kill_sleeper($other_pid);
    }
}

# ===========================================================================
# S10 -- AC9 (spec 05-remove-silence B6): a planted valid-shape silence
# record never allows a stop. G9 is deleted outright -- a planted record is
# never read, consumed or acted on by the gate.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    plant_silence($root, $sid);
    my $r1 = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    is($r1->{rc}, 2, 'AC9: first Stop with a planted silence record -> exit 2');
    ok(-e (state_dir_of($root) . "/silence/$sid"), 'AC9: the planted silence/<sid> record still exists');
    my $r2 = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    is($r2->{rc}, 2, 'AC9: second Stop -> exit 2 too');
}

# ===========================================================================
# S11 (edge) -- AC11 (spec 05-remove-silence B6): a planted silence record
# is inert. A live holder + a planted record still allows the stop (the
# holder, not the silence record), and the record is left in place --
# Decision 50's one-turn consumption no longer applies since there is no
# silence consumer at all.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $pid = spawn_sleeper();
    write_holder($root, $sid, pid => $pid, fp => cmdline_fp_of($pid), items => ['B'], deadline => int(time() + 1800));
    plant_silence($root, $sid);
    my $res = run_gate(payload_json($sid, background_tasks => [{ id => 'B', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);
    is($res->{rc}, 0, 'AC11: live holder allows the stop');
    ok(-e (state_dir_of($root) . "/silence/$sid"),
        'AC11: the planted silence/<sid> record still exists -- not read, so not consumed');
    kill_sleeper($pid);

    # The holder is now gone (no re-hold). A later Stop of the SAME session
    # must be denied on its own merits; the inert silence record never
    # strands it into an allow.
    my $res2 = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    is($res2->{rc}, 2,
        'AC11: a later Stop with no holder -> DENIED (the planted silence record is never read)');
}

# ===========================================================================
# S12 (edge) -- AC10 (spec 05-remove-silence B6): an empty (touch-created)
# silence file does not allow, and the gate leaves it in place (it is never
# read, so never removed either).
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $dir = state_dir_of($root) . "/silence";
    make_path($dir);
    open my $fh, '>', "$dir/$sid" or die $!;
    close $fh;
    my $res = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, 'AC10: an empty silence/<sid> file does not allow -> exit 2');
    ok(-e "$dir/$sid", 'AC10: the empty silence file still exists afterward');
}

# ===========================================================================
# S13 -- retired overrides are never honoured.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $proj = tempdir(CLEANUP => 1); (my $projn = $proj) =~ s{\\}{/}g;
    my $home = tempdir(CLEANUP => 1); (my $homen = $home) =~ s{\\}{/}g;
    my $data = "$projn/.ccpraxis-local-data";
    make_path("$data/.drive-solo", "$data/.subagent-guard/$sid", "$homen/.claude/ccpraxis/.continuity-active/$sid");

    my @files = (
        "$data/.drive-solo/.stop-ok",
        "$data/.drive-solo/.run-finished",
        "$data/.drive-solo/.run-finished.consumed",
        "$data/.reporter-stop-ok",
        "$data/.subagent-guard/force-stop",
        "$data/.subagent-guard/$sid/force-stop",
        "$homen/.claude/ccpraxis/.continuity-active/$sid.stop-ok",
    );
    for my $f (@files) { open my $fh, '>', $f or die "$f: $!"; close $fh }

    my %env_common = (BUTLER_STATE_DIR => $root, CLAUDE_PROJECT_DIR => $projn, HOME => $homen, USERPROFILE => $homen);

    for my $f (@files) {
        my $res = run_gate(payload_json($sid), %env_common);
        is($res->{rc}, 2, "S13: with only $f present -> still exit 2");
        ok(-e $f, "S13: $f still exists afterwards");
    }
    my $res_env = run_gate(payload_json($sid), %env_common,
        CCPRAXIS_DRIVE_STOP_OK => 1, CCPRAXIS_REPORTER_STOP_OK => 1, CCPRAXIS_CONTINUITY_STOP_OK => 1);
    is($res_env->{rc}, 2, 'S13: the three CCPRAXIS_*_STOP_OK env vars, alone -> still exit 2');

    my $res_all = run_gate(payload_json($sid), %env_common,
        CCPRAXIS_DRIVE_STOP_OK => 1, CCPRAXIS_REPORTER_STOP_OK => 1, CCPRAXIS_CONTINUITY_STOP_OK => 1);
    is($res_all->{rc}, 2, 'S13: every override file and env var together -> still exit 2');
    ok((-e $_ ? 1 : 0), "S13: $_ still exists after the combined run") for @files;
}

# ===========================================================================
# S14 (edge) -- retired registry markers do not arm.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    my $home = tempdir(CLEANUP => 1); (my $homen = $home) =~ s{\\}{/}g;
    for my $reg (qw(.continuity-active .drive-solo-active .reporter-active)) {
        make_path("$homen/.claude/ccpraxis/$reg");
        open my $fh, '>', "$homen/.claude/ccpraxis/$reg/$sid" or die $!;
        close $fh;
    }
    my $res = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root, HOME => $homen, USERPROFILE => $homen);
    is($res->{rc}, 0, 'S14: retired registry markers present, no armed/<sid> file -> exit 0');
}

# ===========================================================================
# S15 -- SubagentStop / agent_id payloads always allow; an earlier denial's
# token stays takeable afterwards.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $r_deny = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    my ($tok) = ($r_deny->{err} =~ /Stop token: ([0-9a-f]{8})/);
    ok(defined $tok, 'S15: precondition -- a denial minted a token for sid');

    my $sub_payload = JSON::PP->new->utf8->canonical->encode({
        session_id => $sid, hook_event_name => 'SubagentStop', agent_id => 'a1b2c3',
        background_tasks => [{ id => 'a1b2c3', type => 'subagent', status => 'running' }],
    });
    my $r1 = run_gate($sub_payload, BUTLER_STATE_DIR => $root);
    is($r1->{rc}, 0, 'S15: SubagentStop, armed, no holder -> exit 0');
    is($r1->{err}, '', 'S15: SubagentStop -> stderr empty');

    my $stop_agent_payload = JSON::PP->new->utf8->canonical->encode({
        session_id => $sid, hook_event_name => 'Stop', agent_id => 'a1b2c3',
    });
    my $r2 = run_gate($stop_agent_payload, BUTLER_STATE_DIR => $root);
    is($r2->{rc}, 0, 'S15: Stop payload with agent_id -> exit 0');
    is($r2->{err}, '', 'S15: Stop+agent_id -> stderr empty');

    SKIP: {
        skip 'S15: no token to verify', 1 unless defined $tok;
        local %ENV = %ENV; $ENV{BUTLER_STATE_DIR} = $root;
        is(BpHook::take_stop_token($tok), $sid, 'S15: the earlier denial token is still takeable afterwards');
    }
}

# ===========================================================================
# S16 -- stop_hook_active changes nothing; no cap across 5 runs.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    for my $i (1 .. 5) {
        my $res = run_gate(payload_json($sid, stop_hook_active => JSON::PP::true()), BUTLER_STATE_DIR => $root);
        is($res->{rc}, 2, "S16: run $i of 5 with stop_hook_active true -> exit 2 (no cap)");
    }
}

# ===========================================================================
# S17 (edge) -- armed/<sid> mtime is refreshed to now on every run.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $armed_path = state_dir_of($root) . "/armed/$sid";
    utime(time() - 3600, time() - 3600, $armed_path);
    run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);    # denial path
    my $mt1 = (stat($armed_path))[9];
    ok(defined $mt1 && abs(time() - $mt1) <= 60, 'S17: after a denied Stop, armed/<sid> mtime is within 60s of now');

    utime(time() - 3600, time() - 3600, $armed_path);
    my $pid = spawn_sleeper();
    write_holder($root, $sid, pid => $pid, fp => cmdline_fp_of($pid), items => ['B'], deadline => int(time() + 1800));
    run_gate(payload_json($sid, background_tasks => [{ id => 'B', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);    # allow path
    my $mt2 = (stat($armed_path))[9];
    ok(defined $mt2 && abs(time() - $mt2) <= 60, 'S17: after an allowed (holder) Stop, armed/<sid> mtime is also within 60s of now');
    kill_sleeper($pid);
}

# ===========================================================================
# S18 (edge, fail open) -- stop-tokens is a regular file: mint fails, allow,
# hook-errors.log gets a StopGate line.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $dir = state_dir_of($root);
    open my $fh, '>', "$dir/stop-tokens" or die $!;
    close $fh;
    my $res = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    is($res->{rc}, 0, 'S18: stop-tokens as a regular file -> subprocess exit 0 (fail open, G10)');
    is($res->{err}, '', 'S18: stderr empty');
    like(slurp("$dir/hook-errors.log"), qr/StopGate/, 'S18: hook-errors.log has a line containing StopGate');
}

# ===========================================================================
# S19 (edge) -- missing/relative state root, unparseable payload, and a
# payload with no session_id all allow, in both subprocess and in-process.
# ===========================================================================
{
    my $sid = next_sid();
    my $res_sub = run_gate(payload_json($sid), BUTLER_STATE_DIR => 'relative/dir');
    is($res_sub->{rc}, 0, 'S19: relative BUTLER_STATE_DIR, armed nowhere -> subprocess exit 0');

    my $res_in = run_gate_inprocess(payload_json($sid), BUTLER_STATE_DIR => 'relative/dir');
    SKIP: {
        skip 'S19: StopGate.pm not implemented yet', 1 unless $res_in->{loaded};
        is($res_in->{rc}, 0, 'S19: relative BUTLER_STATE_DIR, armed nowhere -> in-process 0');
    }

    my $root = fresh_state_root();
    my $res_notjson = run_gate('not json', BUTLER_STATE_DIR => $root);
    is($res_notjson->{rc}, 0, 'S19: payload "not json" -> exit 0');

    my $res_nosid = run_gate(JSON::PP->new->encode({ hook_event_name => 'Stop' }), BUTLER_STATE_DIR => $root);
    is($res_nosid->{rc}, 0, 'S19: payload without session_id -> exit 0');
}

# ===========================================================================
# R6-M2 (red-team MEDIUM-2): JSON::PP rejects a lone (unpaired) UTF-16
# surrogate escape (e.g. one bad code unit sliced out of
# last_assistant_message) with "missing low surrogate character", which
# TODAY makes load_payload's decode fail entirely -- payload_ok=0, payload
# {} -- and G1/G2 then read no session_id, so an ARMED session with NO
# HOLDER silently ALLOWS on a single malformed code unit, with nothing
# logged (red-team's "stranding" finding). Decision 51 requires the core to
# tolerate a lone surrogate (replacing it with U+FFFD) rather than failing
# the whole decode open. So: armed, no holder, a payload whose
# last_assistant_message carries one unpaired \ud800 -> the session_id must
# still be recovered and the Stop must still be DENIED (exit 2), never
# silently allowed.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $raw = qq({"session_id":"$sid","hook_event_name":"Stop","stop_hook_active":false,)
            . qq("last_assistant_message":"cut \\ud800"});
    my $res = run_gate($raw, BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2,
        'R6-M2: armed, no holder, payload with a lone UTF-16 surrogate escape -> exit 2 (the core tolerates it, not a silent fail-open allow)');
    like($res->{err}, qr/Continuity is on for this session/,
        'R6-M2: ...with the continuity denial text (session_id was recovered despite the surrogate)');
}

# ===========================================================================
# S20 (edge) -- a corrupt arm file (existence is the contract) still denies
# with the continuity text.
# ===========================================================================
{
    for my $variant ([garbage => 'garbage{'], [empty => '']) {
        my ($label, $content) = @$variant;
        my $root = fresh_state_root();
        my $sid  = next_sid();
        my $dir = state_dir_of($root) . "/armed";
        make_path($dir);
        open my $fh, '>', "$dir/$sid" or die $!;
        print {$fh} $content;
        close $fh;
        my $res = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
        is($res->{rc}, 2, "S20 [$label arm file]: exit 2");
        like($res->{err}, qr/Continuity is on for this session/, "S20 [$label arm file]: the continuity text");
    }
}

# ===========================================================================
# S21 (edge) -- judge role allows, even with an arm file and no ledger.
# ===========================================================================
{
    my $root = fresh_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $tmp = tempdir(CLEANUP => 1);
    my $res = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root,
        BP_LEDGER => "$tmp/x.md", BP_ROLE => 'harvest-judge');
    is($res->{rc}, 0, 'S21: judge role -> exit 0');
    is($res->{err}, '', 'S21: judge role -> stderr empty');
}

# ===========================================================================
# André path (S per spec sec 4: at least one case under a path containing
# André).
# ===========================================================================
{
    my $root = andre_state_root();
    my $sid  = next_sid();
    arm_session($root, $sid);
    my $res = run_gate(payload_json($sid), BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, "Andr\x{e9}-rooted BUTLER_STATE_DIR: armed, no holder -> exit 2");
    like($res->{err}, qr/Continuity is on for this session/, "Andr\x{e9}-rooted BUTLER_STATE_DIR: the continuity text");
}

# ===========================================================================
# B1-B4 (DC3) -- the process budget, package-03 PATH-shim technique.
# ===========================================================================
{
    my $REAL_TIMEOUT_ABS = do { my $p = `bash -c "command -v timeout"`; chomp $p; $p };
    BAIL_OUT('cannot resolve a real timeout utility on PATH') unless length $REAL_TIMEOUT_ABS;

    use Config ();
    my $REAL_PERL_ABS = do {
        my $p;
        if (File::Spec->file_name_is_absolute($^X) && -x $^X) { $p = $^X }
        else {
            my $found = `bash -c "command -v perl"`; chomp $found;
            $p = (length $found && -x $found) ? $found : $Config::Config{perlpath};
        }
        $p;
    };
    BAIL_OUT('cannot resolve a real perl to an absolute path') unless length $REAL_PERL_ABS;

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
        for my $tool (qw(jq awk date stat mv touch)) {
            open my $fh, '>', "$shim/$tool" or die $!;
            print {$fh} "#!$REAL_BASH_ABS\n";
            print {$fh} "printf '%s %s\\n' '$tool' \"\$\$\" >> \"\$SHIM_LOG\"\n";
            print {$fh} "exit 0\n";
            close $fh;
            chmod 0755, "$shim/$tool";
        }
        return $shim;
    }

    sub run_shim {
        my (%opt) = @_;
        my ($lfh, $shim_log_path) = tempfile(); close $lfh; unlink $shim_log_path;
        my (undef, $out_path) = tempfile();
        my (undef, $err_path) = tempfile();

        local %ENV = %ENV;
        delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
        for my $k (keys %{ $opt{env} }) {
            if (defined $opt{env}{$k}) { $ENV{$k} = $opt{env}{$k} } else { delete $ENV{$k} }
        }
        $ENV{SHIM_LOG} = $shim_log_path;
        my $shim_dir = $opt{shim_dir} // build_shim();
        unless (exists $opt{env}{PATH}) { $ENV{PATH} = "$shim_dir:$ENV{PATH}" }

        my @inner_cmd = ("$shim_dir/bash", $opt{script});
        my $inner = join(' ', map { qq("$_") } @inner_cmd);
        $inner = "$REAL_TIMEOUT_ABS $opt{timeout} $inner";
        $inner .= defined $opt{stdin_path} ? qq( < "$opt{stdin_path}") : ' < /dev/null';
        $inner .= qq( > "$out_path" 2> "$err_path");

        local $SIG{ALRM} = sub { die "run_shim: hard alarm backstop exceeded\n" };
        alarm($opt{timeout} + 15);
        system($REAL_BASH_ABS, '-c', $inner);
        my $rc = ($? == -1) ? -1 : ($? >> 8);
        alarm(0);

        return { rc => $rc, out => slurp($out_path) // '', err => slurp($err_path) // '',
                 shim_log => slurp($shim_log_path) // '' };
    }

    sub count_lines { my ($log, $prefix) = @_; return scalar(grep { /^\Q$prefix\E / } split /\n/, $log) }

    # B1: process budget, gate does not apply.
    {
        my $root = fresh_state_root();
        my $sid  = next_sid();
        my $other = next_sid();
        arm_session($root, $other);    # a DIFFERENT session is armed
        my ($pfh, $ppath) = tempfile(); print {$pfh} payload_json($sid); close $pfh;
        my $res = run_shim(script => $HOOK, env => { BUTLER_STATE_DIR => $root },
            stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 0, 'B1: not-applies session (a different session IS armed) -> exit 0');
        is(count_lines($res->{shim_log}, 'perl'), 0, 'B1: 0 perl launches');
        for my $tool (qw(jq awk date stat mv touch)) {
            is(count_lines($res->{shim_log}, $tool), 0, "B1: 0 $tool launches");
        }
        my @bash_lines = grep { /^bash / } split /\n/, $res->{shim_log};
        cmp_ok(scalar(@bash_lines), '<=', 2, 'B1: at most 2 bash lines');
        my %pids = map { (split ' ', $_)[1] => 1 } @bash_lines;
        is(scalar(keys %pids), @bash_lines ? 1 : 0, 'B1: one pid');
    }

    # B2: judge -> exactly 1 perl, one pid, 0 of every other tool.
    {
        my $root = fresh_state_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        my ($pfh, $ppath) = tempfile(); print {$pfh} payload_json($sid); close $pfh;
        my $tmp = tempdir(CLEANUP => 1);
        my $res = run_shim(script => $HOOK,
            env => { BUTLER_STATE_DIR => $root, BP_LEDGER => "$tmp/x.md", BP_ROLE => 'harvest-judge' },
            stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 0, 'B2: judge -> exit 0');
        is(count_lines($res->{shim_log}, 'perl'), 1, 'B2: exactly 1 perl');
        for my $tool (qw(jq awk date stat mv touch)) {
            is(count_lines($res->{shim_log}, $tool), 0, "B2: 0 $tool launches");
        }
        my @perl_lines = grep { /^perl / } split /\n/, $res->{shim_log};
        my @bash_lines = grep { /^bash / } split /\n/, $res->{shim_log};
        my %pids = map { (split ' ', $_)[1] => 1 } (@perl_lines, @bash_lines);
        is(scalar(keys %pids), 1, 'B2: all logged pids equal');
    }

    # B3: applies path, armed + no holder -> exactly 1 perl, one pid, exit 2.
    {
        my $root = fresh_state_root();
        my $sid  = next_sid();
        arm_session($root, $sid);
        my ($pfh, $ppath) = tempfile(); print {$pfh} payload_json($sid); close $pfh;
        my $res = run_shim(script => $HOOK, env => { BUTLER_STATE_DIR => $root },
            stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 2, 'B3: applies path, armed + no holder -> exit 2');
        is(count_lines($res->{shim_log}, 'perl'), 1, 'B3: exactly 1 perl');
        for my $tool (qw(jq awk date stat mv touch)) {
            is(count_lines($res->{shim_log}, $tool), 0, "B3: 0 $tool launches");
        }
        my @perl_lines = grep { /^perl / } split /\n/, $res->{shim_log};
        my @bash_lines = grep { /^bash / } split /\n/, $res->{shim_log};
        my %pids = map { (split ' ', $_)[1] => 1 } (@perl_lines, @bash_lines);
        is(scalar(keys %pids), 1, 'B3: one pid');
    }

    # B4: coordinator allow path (terminal fresh ledger, registry present).
    {
        my $bp = tempdir(CLEANUP => 1); (my $bpn = $bp) =~ s{\\}{/}g;
        make_path("$bpn/packages", "$bpn/runs");
        open my $l, '>', "$bpn/packages/p.md" or die $!;
        my $now = do { my @t = gmtime(time()); sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]) };
        print {$l} "---\npackage: p\nstatus: parked\nlast_updated: $now\n---\n# p\n\n## Next action\n\nAwait review.\n";
        close $l;
        open my $r, '>', "$bpn/runs/registry.json" or die $!;
        print {$r} '{"packages":{"p":{"attempts":1}}}';
        close $r;
        my ($pfh, $ppath) = tempfile(); print {$pfh} payload_json(next_sid(), background_tasks => []); close $pfh;
        my $res = run_shim(script => $HOOK,
            env => { BP_LEDGER => "$bpn/packages/p.md", BP_DIR => $bpn, BP_PACKAGE => 'p' },
            stdin_path => $ppath, timeout => 10);
        is($res->{rc}, 0, 'B4: coordinator allow path -> exit 0');
        is(count_lines($res->{shim_log}, 'perl'), 1, 'B4: exactly 1 perl');
        for my $tool (qw(jq awk date stat mv touch)) {
            is(count_lines($res->{shim_log}, $tool), 0, "B4: 0 $tool launches");
        }
        my @perl_lines = grep { /^perl / } split /\n/, $res->{shim_log};
        my @bash_lines = grep { /^bash / } split /\n/, $res->{shim_log};
        my %pids = map { (split ' ', $_)[1] => 1 } (@perl_lines, @bash_lines);
        is(scalar(keys %pids), 1, 'B4: one pid');
        my $reg = read_json_file("$bpn/runs/registry.json");
        is(ref($reg) eq 'HASH' ? $reg->{packages}{p}{status} : undef, 'parked',
            'B4: registry.json status updated (proves sync without jq)');
    }
}

# ---------------------------------------------------------------------------
# hermeticity guard: the real ~/.claude/butler-state tree was never touched.
# ---------------------------------------------------------------------------
if (defined $REAL_BSTATE) {
    my $exists_after = -d $REAL_BSTATE ? 1 : 0;
    is($exists_after, $REAL_BSTATE_EXISTS, 'hygiene: real ~/.claude/butler-state existence unchanged');
    if ($REAL_BSTATE_EXISTS && $exists_after) {
        is((stat($REAL_BSTATE))[9], $REAL_BSTATE_MTIME, 'hygiene: real ~/.claude/butler-state mtime unchanged');
    }
}

# ===========================================================================
# AC8 (spec 05-remove-silence section 4.1, DC2): no set_silence/take_silence
# reference and no "/silence/" state path remain in StopGate.pm's source.
# ===========================================================================
{
    my $sg_src = slurp($STOPGATE_PM);
    unlike($sg_src, qr/set_silence/, 'AC8: StopGate.pm has no set_silence reference');
    unlike($sg_src, qr/take_silence/, 'AC8: StopGate.pm has no take_silence reference');
}

done_testing();
