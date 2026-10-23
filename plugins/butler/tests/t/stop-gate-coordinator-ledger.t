#!/usr/bin/env perl
# platform: any
# ORACLE for package 06 (blueprint hook-continuity-remake), coordinator side:
# specs/06-stop-gate-spec.md C1-C21 (DC2) -- the ledger rule the coordinator
# branch of the single Stop gate enforces (terminal + fresh + concrete Next
# action when blocked/parked), the fleet .paused resumable clause, the
# runs/<pkg>.force-stop escape hatch, the holder rule (a hollow pause is
# never a reasonless refusal), and the coordinator denial text with its stop
# token. Every case re-expressing an existing oracle's assertion names that
# assertion's own description in this file's own test description.
#
# The hook file and its perl module DO NOT EXIST YET: every case below drives
# the REAL bash wrapper on disk, so with nothing there yet a case fails
# legibly (a plain "No such file or directory", 127) rather than crashing
# this file.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Spec ();
use JSON::PP ();
use POSIX qw(WNOHANG _exit);
use Time::HiRes qw(sleep time);

(my $BUTLER = "$Bin/../..") =~ s{\\}{/}g;
my $HOOK = "$BUTLER/hooks/stop-gate.sh";
my $S    = "$BUTLER/scripts";

require "$S/BpHook.pm";    # package 03 -- real and already implemented

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
$ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;

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

sub fresh_state_root { my $t = tempdir(CLEANUP => 1); (my $r = "$t/state") =~ s{\\}{/}g; return $r }

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

sub payload_json {
    my ($sid, %extra) = @_;
    my %p = (session_id => $sid, hook_event_name => 'Stop', stop_hook_active => JSON::PP::false(),
              background_tasks => []);
    %p = (%p, %extra);
    return JSON::PP->new->utf8->canonical->encode(\%p);
}

my $sidn = 0;
sub next_sid { return sprintf('sgc-%04x', ++$sidn) }

sub state_dir_of { my ($root) = @_; return "$root/continuity" }

sub read_json_file {
    my ($p) = @_;
    return undef unless -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return eval { JSON::PP->new->utf8->decode($c) };
}

# ---------------------------------------------------------------------------
# mk_bp(status, next, %sig) -- ledger fixture, same shape as
# the retired graceful-stop-gate coverage's mk_bp: <bp>/packages/p.md with frontmatter
# package/status/last_updated, then "## Next action" + body.
# %sig: paused/shutdown/forcestop (as there), plus this file's own:
#   registry => \%hash (writes runs/registry.json, JSON::PP-encoded)
#   registry_raw => 'literal text' (for a deliberately corrupt registry)
#   crlf => 1 (status line ends "\r\n" -- C11's CRLF ledger case)
#   heading_first => 1 (first Next-action line is itself "## ..." -- empty)
# ---------------------------------------------------------------------------
my $bpn = 0;
sub mk_bp {
    my ($status, $next, %sig) = @_;
    my $dir = tempdir(CLEANUP => 1); (my $dirn = $dir) =~ s{\\}{/}g;
    $bpn++;
    make_path("$dirn/runs", "$dirn/packages");
    my $status_line = $sig{crlf} ? "status: $status\r\n" : "status: $status\n";
    my $next_block = $sig{heading_first}
        ? "## Next action\n\n## Something else\n"
        : "## Next action\n\n$next\n";
    open my $l, '>:raw', "$dirn/packages/p.md" or die $!;
    print {$l} "---\npackage: p\n$status_line" . "last_updated: 2026-06-24T00:00:00Z\n---\n# p\n\n$next_block";
    close $l;
    for my $s (qw(shutdown paused)) {
        if ($sig{$s}) { open my $h, '>', "$dirn/runs/.$s" or die $!; close $h }
    }
    if ($sig{forcestop}) { open my $h, '>', "$dirn/runs/p.force-stop" or die $!; close $h }
    if ($sig{other_forcestop}) { open my $h, '>', "$dirn/runs/other.force-stop" or die $!; close $h }
    if (exists $sig{registry}) {
        open my $r, '>:raw', "$dirn/runs/registry.json" or die $!;
        print {$r} JSON::PP->new->utf8->canonical->encode($sig{registry});
        close $r;
    }
    if (exists $sig{registry_raw}) {
        open my $r, '>:raw', "$dirn/runs/registry.json" or die $!;
        print {$r} $sig{registry_raw};
        close $r;
    }
    return ($dirn, "$dirn/packages/p.md");
}

sub ledger_bytes { my ($p) = @_; return slurp($p) }

sub env_for {
    my ($dir, $led, %extra) = @_;
    my $root = fresh_state_root();
    return (BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir,
            BUTLER_STATE_DIR => $root, %extra);
}

# ===========================================================================
# C1-C7 -- re-expressed from the retired graceful-stop-gate coverage, one assertion each, named.
# ===========================================================================
{
    # RV-M2: mk_bp fixtures always start with last_updated:
    # 2026-06-24T00:00:00Z; a regex that merely matches the timestamp SHAPE
    # would pass even with the stamp (StopGate.pm:139) deleted, since the
    # unstamped fixture value already matches that shape. Capture it before
    # the run and assert it CHANGED, and that the new value is fresh (within
    # 120s of now), the same discipline C13 already applies.
    my $OLD_STAMP = '2026-06-24T00:00:00Z';
    my ($dir, $led) = mk_bp('running', 'Re-run the implementer on the failing case.', paused => 1);
    is(ledger_bytes($led) =~ /^last_updated: \Q$OLD_STAMP\E$/m ? 1 : 0, 1,
        'C1 precondition: fixture starts with the old last_updated stamp');
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 0,
        'C1 (re-expresses the retired graceful-stop-gate coverage "gate-stop: paused + non-terminal + Next action -> allowed (resumable)"): exit 0');
    my ($new_stamp) = (ledger_bytes($led) =~ /^last_updated: (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$/m);
    ok(defined $new_stamp, 'C1: last_updated matches the fresh timestamp shape');
    SKIP: {
        skip 'C1: no stamp captured', 2 unless defined $new_stamp;
        isnt($new_stamp, $OLD_STAMP, 'C1: last_updated stamped (RV-M2: changed from the fixture\'s old value, not merely shape-matching)');
        my @t = ($new_stamp =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/);
        require Time::Local;
        my $epoch = eval { Time::Local::timegm($t[5], $t[4], $t[3], $t[2], $t[1] - 1, $t[0]) };
        cmp_ok(abs(time() - $epoch), '<=', 120, 'C1: the new last_updated is within 120s of now') if defined $epoch;
    }
}
{
    my ($dir, $led) = mk_bp('running', '', paused => 1);
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 2,
        'C2 (re-expresses the retired graceful-stop-gate coverage "gate-stop: paused + empty Next action -> blocked"): exit 2');
    like((lines_of($res->{err}))[0] // '', qr/'## Next action' is empty or a placeholder/, 'C2: line 1 contains R4');
}
{
    my ($dir, $led) = mk_bp('running', 'something', paused => 1, shutdown => 1);
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 2,
        'C3 (re-expresses the retired graceful-stop-gate coverage "gate-stop: paused+shutdown + non-terminal -> blocked (shutdown wants terminal park)"): exit 2');
    like((lines_of($res->{err}))[0] // '', qr/status 'running' is not terminal/, "C3: R2 status 'running' is not terminal");
}
{
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 2,
        'C4 (re-expresses the retired graceful-stop-gate coverage "gate-stop: no signal + non-terminal -> blocked (regression: unchanged)"): exit 2');
    like((lines_of($res->{err}))[0] // '', qr/status 'running' is not terminal/, 'C4: R2');
}
{
    my ($dir, $led) = mk_bp('parked', 'Awaiting the API-shape decision (see escalation).');
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 0,
        'C5 (re-expresses the retired graceful-stop-gate coverage "gate-stop: no signal + parked + Next action -> allowed (regression: unchanged)"): exit 0');
}
{
    my ($dir, $led) = mk_bp('parked', 'Re-run the implementer.', paused => 1);
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 2,
        'C6 (re-expresses the retired graceful-stop-gate coverage "gate-stop: paused + terminal status -> blocked (no stranding)"): exit 2');
    like((lines_of($res->{err}))[0] // '', qr/a fleet pause is active and status 'parked' is terminal/, "C6: R5 with 'parked'");

    # R6-M1 (red-team MEDIUM-1): on the pause+terminal (R5) path the holder is
    # never consulted and "finish or park the ledger: status
    # done|blocked|parked" is unfollowable (the ledger is ALREADY terminal --
    # that is exactly why R5 fired). The retired stop-gate.sh instead told the
    # agent, verbatim (stop-gate.sh:89): "Set status back to a non-terminal
    # value (running/converging) with a concrete '## Next action', then
    # stop." This coordinator denial must carry that exact old-gate guidance
    # line on this path, and must NOT carry the generic (unfollowable) line.
    like($res->{err},
        qr/Set status back to a non-terminal value \(running\/converging\) with a concrete '## Next action', then stop\./,
        "R6-M1: paused+terminal denial carries stop-gate.sh's exact pause guidance line (stop-gate.sh:89), not a park instruction it cannot follow");
    unlike($res->{err}, qr/Otherwise finish or park the ledger/,
        'R6-M1: ...and does NOT carry the generic "finish or park the ledger: status done|blocked|parked" line (unfollowable: the status is already terminal)');
}
{
    my ($dir, $led) = mk_bp('running', 'Re-run the implementer.', paused => 1);
    utime(time - 1800, time - 1800, $led);
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 2,
        'C7 (re-expresses the retired graceful-stop-gate coverage "gate-stop: paused + stale ledger -> blocked") (mtime -30 min): exit 2');
    like((lines_of($res->{err}))[0] // '', qr/the ledger is 30m stale \(limit 15m\)/, 'C7: R3 exact text');
}

# ===========================================================================
# C8 -- re-expressed from the retired run-continuity-gaps coverage (bug 20260922-231428-6c0d),
# against CURRENT behaviour: a hold is never a reasonless pause.
# ===========================================================================
my $HAVE_PROC_CMDLINE = -r '/proc/self/cmdline' ? 1 : 0;
my $C8_SLEEPER_SEQ = 0;

# spawn_tagged_sleeper() -- RV-M1 fix: reused from stop-gate-single.t's
# spawn_sleeper technique. On this MSYS host a freshly forked child's
# /proc/<pid>/cmdline reads the PARENT's image for 50-100ms until exec
# lands, so fingerprinting immediately after fork() (as C8(d) did before
# this fix) captures the wrong image and the assertion passes for the
# wrong reason (review RV-M1). Wait, bounded to 5s at 20ms steps, until
# the child's OWN uniquely-tagged cmdline is visible.
sub spawn_tagged_sleeper {
    my $tag = sprintf('c8d-%d-%d-%d', $$, ++$C8_SLEEPER_SEQ, int(rand(1_000_000)));
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN,  '<', File::Spec->devnull);
        open(STDOUT, '>', File::Spec->devnull);
        open(STDERR, '>', File::Spec->devnull);
        exec($^X, '-e', "select(undef,undef,undef,60) # sleeper-tag:$tag") or _exit(127);
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

{
    # (a) holder record for sid unexpired, item is a running "shell" task -> R6.
    my $sid = next_sid();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $root = fresh_state_root();
    make_path(state_dir_of($root) . "/holder");
    open my $fh, '>:raw', state_dir_of($root) . "/holder/$sid.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode(
        { session_id => $sid, token => 'aaaaaaaa', items => ['T1'], deadline => int(time() + 1800) });
    close $fh;
    my $res = run_gate(payload_json($sid, background_tasks => [{ id => 'T1', type => 'shell', status => 'running' }]),
        BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir, BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, 'C8(a): a held item that is a running "shell" (not subagent) task -> exit 2');
    like((lines_of($res->{err}))[0] // '', qr/the held ids are not running background subagents/, 'C8(a): R6');
}
{
    # (b) item absent from background_tasks -> R6.
    my $sid = next_sid();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $root = fresh_state_root();
    make_path(state_dir_of($root) . "/holder");
    open my $fh, '>:raw', state_dir_of($root) . "/holder/$sid.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode(
        { session_id => $sid, token => 'aaaaaaaa', items => ['T1'], deadline => int(time() + 1800) });
    close $fh;
    my $res = run_gate(payload_json($sid, background_tasks => []),
        BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir, BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, 'C8(b): the held item absent from background_tasks -> exit 2');
    like((lines_of($res->{err}))[0] // '', qr/the held ids are not running background subagents/, 'C8(b): R6');
}
{
    # (c) record deadline in the past -> R2 (the ledger reason), not R6.
    my $sid = next_sid();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $root = fresh_state_root();
    make_path(state_dir_of($root) . "/holder");
    open my $fh, '>:raw', state_dir_of($root) . "/holder/$sid.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode(
        { session_id => $sid, token => 'aaaaaaaa', items => ['T1'], deadline => int(time() - 10) });
    close $fh;
    my $res = run_gate(payload_json($sid, background_tasks => [{ id => 'T1', type => 'subagent', status => 'running' }]),
        BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir, BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, 'C8(c): a record whose deadline is in the past -> exit 2');
    like((lines_of($res->{err}))[0] // '', qr/status 'running' is not terminal/, 'C8(c): R2, not R6 (an expired hold is no hold)');
}
{
    # (d) armed non-coordinator, live holder process but held id not running -> deny (continuity text).
    my $sid = next_sid();
    my $root = fresh_state_root();
    local %ENV = %ENV;
    $ENV{BUTLER_STATE_DIR} = $root; $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
    BpHook::arm($sid, role => 'manual', by => 'arm-on-entry');
    my $pid = spawn_tagged_sleeper();    # RV-M1: tag+wait, not a bare fork/exec race
    my $fp = do {
        require Digest::SHA;
        if ($HAVE_PROC_CMDLINE) {
            open my $cfh, '<:raw', "/proc/$pid/cmdline"; local $/; my $c = $cfh ? <$cfh> : ''; close $cfh if $cfh;
            Digest::SHA::sha1_hex(defined $c ? $c : '');
        } else { '' }
    };
    make_path(state_dir_of($root) . "/holder");
    open my $fh, '>:raw', state_dir_of($root) . "/holder/$sid.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode(
        { session_id => $sid, token => 'aaaaaaaa', pid => $pid, fp => $fp, items => ['T1'], deadline => int(time() + 1800) });
    close $fh;
    my $res = run_gate(payload_json($sid, background_tasks => [{ id => 'Q', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);
    # Decision 131: on the non-coordinator path a live own holder allows the
    # Stop whether the held id reads completed, is absent, or only unheld
    # work runs -- no background_tasks cross-check at all (unlike the
    # coordinator path, which keeps it; see C8(a)-(c) above). Q running but
    # T1 (the actually held id) absent from background_tasks used to deny;
    # it now allows.
    is($res->{rc}, 0, 'C8(d): Decision 131 -- armed, live own holder, held id T1 not in background_tasks -> exit 0 anyway');
    is($res->{err}, '', 'C8(d): Decision 131 -- exit 0 means no denial text at all');

    # RV-M1 positive control retained: the SAME record, with T1 (the
    # actually-held item) reported running -> exit 0 too, for the same
    # Decision 131 reason (a live holder never needs the cross-check).
    my $res_ctrl = run_gate(payload_json($sid, background_tasks => [{ id => 'T1', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);
    is($res_ctrl->{rc}, 0, 'C8(d) RV-M1 positive control: same record, T1 actually running -> exit 0 (fixture is live)');

    kill('TERM', $pid) if kill(0, $pid);
    waitpid($pid, 0);
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
}
{
    # (d-dead) C8(d)'s original intent kept as a DEAD-holder variant: once
    # the holder process is gone, holder_live is 0 and the non-coordinator
    # path falls through to running_work/the continuity deny text (not the
    # coordinator text -- BP_LEDGER unset), same as before Decision 131.
    my $sid = next_sid();
    my $root = fresh_state_root();
    local %ENV = %ENV;
    $ENV{BUTLER_STATE_DIR} = $root; $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
    BpHook::arm($sid, role => 'manual', by => 'arm-on-entry');
    my $pid = spawn_tagged_sleeper();
    my $fp = do {
        require Digest::SHA;
        if ($HAVE_PROC_CMDLINE) {
            open my $cfh, '<:raw', "/proc/$pid/cmdline"; local $/; my $c = $cfh ? <$cfh> : ''; close $cfh if $cfh;
            Digest::SHA::sha1_hex(defined $c ? $c : '');
        } else { '' }
    };
    make_path(state_dir_of($root) . "/holder");
    open my $fh, '>:raw', state_dir_of($root) . "/holder/$sid.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode(
        { session_id => $sid, token => 'aaaaaaaa', pid => $pid, fp => $fp, items => ['T1'], deadline => int(time() + 1800) });
    close $fh;
    kill('KILL', $pid);
    waitpid($pid, 0);
    my $dead_deadline = time() + 5;
    1 while kill(0, $pid) && time() < $dead_deadline;
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;

    my $res = run_gate(payload_json($sid, background_tasks => [{ id => 'Q', type => 'subagent', status => 'running' }]),
        BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, 'C8(d-dead): armed, DEAD own holder, held id T1 not running in background_tasks -> exit 2');
    like($res->{err}, qr/Continuity is on for this session/, 'C8(d-dead): the continuity text (not the coordinator text -- BP_LEDGER unset)');
}
{
    # (e) the "no new refusal" half: a terminal, fresh ledger is allowed
    # whatever holder record exists (none, expired, hollow).
    for my $variant (
        ['no holder record'    => undef],
        ['expired holder'      => { deadline => int(time() - 10) }],
        ['hollow (non-running)' => { deadline => int(time() + 1800), items => ['T1'] }],
    ) {
        my ($label, $holder) = @$variant;
        my $sid = next_sid();
        my ($dir, $led) = mk_bp('parked', 'Reviewed and closed.');
        my $root = fresh_state_root();
        if (defined $holder) {
            make_path(state_dir_of($root) . "/holder");
            open my $fh, '>:raw', state_dir_of($root) . "/holder/$sid.json" or die $!;
            print {$fh} JSON::PP->new->utf8->canonical->encode({ session_id => $sid, token => 'aaaaaaaa', %$holder });
            close $fh;
        }
        my $res = run_gate(payload_json($sid, background_tasks => []),
            BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir, BUTLER_STATE_DIR => $root);
        is($res->{rc}, 0, "C8(e) [$label]: a terminal, fresh ledger is allowed regardless of the holder record");
    }
}

# ===========================================================================
# C9 -- ledger missing -> R1, also under .paused.
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1); (my $dirn = $dir) =~ s{\\}{/}g;
    make_path("$dirn/runs", "$dirn/packages");
    my $led = "$dirn/packages/p.md";    # never created
    my $res = run_gate(payload_json(next_sid()), env_for($dirn, $led));
    is($res->{rc}, 2, 'C9: ledger missing -> exit 2');
    like((lines_of($res->{err}))[0] // '', qr/the ledger does not exist/, 'C9: R1');

    open my $h, '>', "$dirn/runs/.paused" or die $!; close $h;
    my $res2 = run_gate(payload_json(next_sid()), env_for($dirn, $led));
    is($res2->{rc}, 2, 'C9: ledger missing under .paused -> exit 2');
    like((lines_of($res2->{err}))[0] // '', qr/the ledger does not exist/, 'C9: R1 under .paused too');
}

# ===========================================================================
# C10 -- terminal but stale 20 min -> R3 (limit 15m); with
# BP_LEDGER_FRESH_MIN=60 -> exit 0.
# ===========================================================================
{
    my ($dir, $led) = mk_bp('parked', 'Reviewed and closed.');
    utime(time - 1200, time - 1200, $led);
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 2, 'C10: terminal but stale 20 minutes -> exit 2');
    like((lines_of($res->{err}))[0] // '', qr/the ledger is 20m stale \(limit 15m\)/, 'C10: R3 with limit 15m');

    my $res2 = run_gate(payload_json(next_sid()), env_for($dir, $led, BP_LEDGER_FRESH_MIN => 60));
    is($res2->{rc}, 0, 'C10: with BP_LEDGER_FRESH_MIN=60 -> exit 0');
}

# ===========================================================================
# C11 -- Next action R4 across statuses; done exempt; dropped with a
# concrete Next action allowed; CRLF status line treated as 'parked'.
# ===========================================================================
{
    for my $status (qw(blocked parked dropped)) {
        for my $variant (['empty' => ''], ['placeholder' => '<fill this in>']) {
            my ($label, $next) = @$variant;
            my ($dir, $led) = mk_bp($status, $next);
            my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
            is($res->{rc}, 2, "C11: status '$status' with $label Next action -> exit 2");
            like((lines_of($res->{err}))[0] // '', qr/'## Next action' is empty or a placeholder/, "C11: $status/$label -> R4");
        }
        my ($dir, $led) = mk_bp($status, 'anything', heading_first => 1);
        my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
        is($res->{rc}, 2, "C11: status '$status' with a '## ...' heading as the first line -> exit 2 (R4)");
    }
    {
        my ($dir, $led) = mk_bp('done', '');
        my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
        is($res->{rc}, 0, 'C11: done with empty Next action -> exit 0');
    }
    {
        my ($dir, $led) = mk_bp('dropped', 'Nothing further needed.');
        my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
        is($res->{rc}, 0, 'C11: dropped with a concrete Next action -> exit 0');
    }
    {
        my ($dir, $led) = mk_bp('parked', 'Awaiting review.', crlf => 1);
        my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
        is($res->{rc}, 0, "C11: status line 'status: parked\\r' (CRLF ledger) -> treated as 'parked' -> exit 0");
    }
}

# ===========================================================================
# C12 -- runs/p.force-stop with a non-terminal ledger -> exit 0, file
# removed, ledger bytes unchanged; runs/other.force-stop only -> exit 2.
# ===========================================================================
{
    my ($dir, $led) = mk_bp('running', 'keep going', forcestop => 1);
    my $before = ledger_bytes($led);
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 0, 'C12: runs/p.force-stop with a non-terminal ledger -> exit 0');
    ok(!-e "$dir/runs/p.force-stop", 'C12: the force-stop file is removed');
    is(ledger_bytes($led), $before, 'C12: ledger bytes unchanged');

    my ($dir2, $led2) = mk_bp('running', 'keep going', other_forcestop => 1);
    my $res2 = run_gate(payload_json(next_sid()), env_for($dir2, $led2));
    is($res2->{rc}, 2, "C12: runs/other.force-stop only -> exit 2 (a force-stop for another package is ignored)");
}

# ===========================================================================
# C13 -- allowed terminal stop: stamp, line count/other bytes unchanged;
# registry status update, keeping other keys; corrupt registry -> untouched.
# ===========================================================================
{
    my ($dir, $led) = mk_bp('parked', 'Reviewed and closed.',
        registry => { packages => { p => { attempts => 2 } }, x => 1 });
    my $before_lines = scalar(lines_of(ledger_bytes($led)));
    my $before = ledger_bytes($led);
    (my $before_no_ts = $before) =~ s/^last_updated:.*$//m;
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 0, 'C13: allowed terminal stop -> exit 0');
    my $after = ledger_bytes($led);
    my ($ts) = ($after =~ /^last_updated: (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)$/m);
    ok(defined $ts, 'C13: last_updated matches the fresh timestamp shape');
    SKIP: {
        skip 'C13: no timestamp captured', 2 unless defined $ts;
        my @t = ($ts =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/);
        require Time::Local;
        my $epoch = eval { Time::Local::timegm($t[5], $t[4], $t[3], $t[2], $t[1] - 1, $t[0]) };
        cmp_ok(abs(time() - $epoch), '<=', 120, 'C13: within 120s of now') if defined $epoch;
        is(scalar(lines_of($after)), $before_lines, 'C13: line count unchanged');
    }
    (my $after_no_ts = $after) =~ s/^last_updated:.*$//m;
    is($after_no_ts, $before_no_ts, 'C13: all other lines identical');

    my $reg = read_json_file("$dir/runs/registry.json");
    is(ref($reg) eq 'HASH' ? $reg->{packages}{p}{status} : undef, 'parked',
        'C13: registry.json packages.p.status becomes "parked"');
    is(ref($reg) eq 'HASH' ? $reg->{packages}{p}{attempts} : undef, 2, 'C13: attempts kept');
    is(ref($reg) eq 'HASH' ? $reg->{x} : undef, 1, 'C13: top-level x kept');

    my ($dir2, $led2) = mk_bp('parked', 'Reviewed and closed.', registry_raw => '{not json');
    my $reg_before = slurp("$dir2/runs/registry.json");
    my $res2 = run_gate(payload_json(next_sid()), env_for($dir2, $led2));
    is($res2->{rc}, 0, 'C13: a registry containing {not json -> the stop still exits 0');
    is(slurp("$dir2/runs/registry.json"), $reg_before, 'C13: ...and the registry is byte-identical afterwards');
}

# ===========================================================================
# C14 -- a denied stop leaves the ledger and registry byte-identical.
# ===========================================================================
{
    my ($dir, $led) = mk_bp('running', 'keep going',
        registry => { packages => { p => { attempts => 2 } } });
    my $led_before = ledger_bytes($led);
    my $reg_before = slurp("$dir/runs/registry.json");
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led));
    is($res->{rc}, 2, 'C14: precondition -- the stop is denied');
    is(ledger_bytes($led), $led_before, 'C14: the ledger is byte-identical');
    is(slurp("$dir/runs/registry.json"), $reg_before, 'C14: the registry is byte-identical');
}

# ===========================================================================
# C15 -- the coordinator denial text: exactly 4 lines, exact shape, no
# butler-continuity mention, token takeable.
# ===========================================================================
{
    my $sid = next_sid();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $res = run_gate(payload_json($sid), env_for($dir, $led));
    is($res->{rc}, 2, 'C15: precondition -- denied');
    my @lines = lines_of($res->{err});
    is(scalar(@lines), 4, 'C15: exactly 4 lines');
    my ($reason, $tok) = ($lines[0] // '') =~ /^Coordinator stop refused: (.+)\. Stop token: ([0-9a-f]{8})$/;
    ok(defined $tok, 'C15: line 1 matches "Coordinator stop refused: <reason>. Stop token: <t>" with 8 hex')
        or diag($lines[0] // '');
    SKIP: {
        skip 'C15: no token extracted', 4 unless defined $tok;
        is($lines[2], "  butler-hold --token $tok <id> [<id> ...]", 'C15: line 3 exact');
        is($lines[3], "Otherwise finish or park the ledger: status done|blocked|parked, a concrete '## Next action' when blocked or parked, last_updated from iso_now.",
            'C15: line 4 exact');
        unlike($res->{err}, qr/butler-continuity/, 'C15: stderr contains no butler-continuity');
    }
}
{
    # Re-run with a captured state root so take_stop_token can be checked
    # against the exact root the gate wrote into.
    my $sid = next_sid();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $root = fresh_state_root();
    my $res = run_gate(payload_json($sid),
        BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir, BUTLER_STATE_DIR => $root);
    my ($tok) = ($res->{err} =~ /Stop token: ([0-9a-f]{8})/);
    ok(defined $tok, 'C15: precondition -- a token was minted');
    SKIP: {
        skip 'C15: no token', 1 unless defined $tok;
        local %ENV = %ENV;
        $ENV{BUTLER_STATE_DIR} = $root;
        is(BpHook::take_stop_token($tok), $sid, 'C15: take_stop_token(<t>) returns sid');
    }
}

# ===========================================================================
# C16 -- the holder rule: unexpired record whose item is a running subagent
# allows, even with a dead pid and garbage fp; background_tasks absent denies.
# ===========================================================================
{
    my $sid = next_sid();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $root = fresh_state_root();
    make_path(state_dir_of($root) . "/holder");
    open my $fh, '>:raw', state_dir_of($root) . "/holder/$sid.json" or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode(
        { session_id => $sid, token => 'aaaaaaaa', pid => 999999999, fp => 'garbage-not-a-real-fp',
          items => ['T1'], deadline => int(time() + 1800) });
    close $fh;
    my $res = run_gate(payload_json($sid, background_tasks => [{ id => 'T1', type => 'subagent', status => 'running' }]),
        BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir, BUTLER_STATE_DIR => $root);
    is($res->{rc}, 0, 'C16: non-terminal ledger + unexpired record + running held subagent -> exit 0 (pid dead, fp garbage: no pid check for a coordinator)');

    my $sid2 = next_sid();
    my ($dir2, $led2) = mk_bp('running', 'keep going');
    my $root2 = fresh_state_root();
    make_path(state_dir_of($root2) . "/holder");
    open my $fh2, '>:raw', state_dir_of($root2) . "/holder/$sid2.json" or die $!;
    print {$fh2} JSON::PP->new->utf8->canonical->encode(
        { session_id => $sid2, token => 'aaaaaaaa', pid => 999999999, fp => 'garbage', items => ['T1'], deadline => int(time() + 1800) });
    close $fh2;
    my $res2 = run_gate(payload_json($sid2),    # no background_tasks key at all
        BP_LEDGER => $led2, BP_DIR => $dir2, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir2, BUTLER_STATE_DIR => $root2);
    is($res2->{rc}, 2, 'C16: same, but background_tasks absent -> exit 2 (a coordinator requires the array)');
}

# ===========================================================================
# C17 -- AC12 (spec 05-remove-silence B6): a hand-planted valid-shape
# silence record plus non-terminal ledger denies; the silence file is left
# in place (it is never read by the coordinator path either); no
# armed/<sid> file needed.
# ===========================================================================
{
    my $sid = next_sid();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $root = fresh_state_root();
    local %ENV = %ENV;
    $ENV{BUTLER_STATE_DIR} = $root; $ENV{HOME} = $FAKE_HOME; $ENV{USERPROFILE} = $FAKE_HOME;
    my $sdir = state_dir_of($root) . '/silence';
    make_path($sdir);
    open my $fh, '>', "$sdir/$sid" or die $!;
    print {$fh} JSON::PP->new->encode({
        session_id => $sid, by => 'butler-continuity', reason => 'reporting progress now', at => time(),
    });
    close $fh;
    my $res = run_gate(payload_json($sid),
        BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir, BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, 'AC12: a planted silence record plus a non-terminal ledger -> exit 2 (silence/off/armed never read here)');
    ok(-e "$sdir/$sid", 'AC12: the planted silence file still exists');
}

# ===========================================================================
# C18 -- stop-tokens unstoreable -> still exit 2, token-less variant.
# ===========================================================================
{
    my $sid = next_sid();
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $root = fresh_state_root();
    make_path(state_dir_of($root));
    open my $fh, '>', state_dir_of($root) . "/stop-tokens" or die $!;
    close $fh;
    my $res = run_gate(payload_json($sid),
        BP_LEDGER => $led, BP_DIR => $dir, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir, BUTLER_STATE_DIR => $root);
    is($res->{rc}, 2, 'C18: stop-tokens is a regular file -> still exit 2');
    my @lines = lines_of($res->{err});
    is($lines[0] // '', "Coordinator stop refused: status 'running' is not terminal.", 'C18: line 1 (token-less)');
    is($lines[2] // '', '  butler-hold <id> [<id> ...]', 'C18: line 3 (token-less)');
}

# ===========================================================================
# C19 -- BP_ROLE=harvest-judge, non-terminal ledger -> exit 0.
# ===========================================================================
{
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $res = run_gate(payload_json(next_sid()), env_for($dir, $led, BP_ROLE => 'harvest-judge'));
    is($res->{rc}, 0, 'C19: BP_ROLE=harvest-judge, non-terminal ledger -> exit 0 (role skip)');
}

# ===========================================================================
# C20 -- BP_DIR unset: .paused/force-stop not consulted, no registry
# written; the ledger rule still applies.
# ===========================================================================
{
    my ($dir, $led) = mk_bp('running', 'keep going', paused => 1, forcestop => 1,
        registry => { packages => {} });
    my $root = fresh_state_root();
    my $res = run_gate(payload_json(next_sid()),
        BP_LEDGER => $led, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir, BUTLER_STATE_DIR => $root);   # BP_DIR unset
    is($res->{rc}, 2, 'C20: BP_DIR unset -- .paused/force-stop are not consulted, non-terminal ledger still denies');
    my $reg_after = read_json_file("$dir/runs/registry.json");
    is(ref($reg_after) eq 'HASH' ? (exists $reg_after->{packages}{p} ? 1 : 0) : undef, 0,
        'C20: no registry write happened (packages.p was never added)');
    ok(-e "$dir/runs/p.force-stop", 'C20: the force-stop file was never consulted/removed');

    my ($dir2, $led2) = mk_bp('parked', 'Reviewed and closed.');
    my $res2 = run_gate(payload_json(next_sid()),
        BP_LEDGER => $led2, BP_PACKAGE => 'p', BP_PROJECT_ROOT => $dir2, BUTLER_STATE_DIR => $root);
    is($res2->{rc}, 0, 'C20: BP_DIR unset -- a terminal fresh ledger is still allowed');
}

# ===========================================================================
# C21 -- SubagentStop with agent_id in a coordinator env, non-terminal
# ledger -> exit 0 (G1 fires before the coordinator branch is ever reached).
# ===========================================================================
{
    my ($dir, $led) = mk_bp('running', 'keep going');
    my $payload = JSON::PP->new->utf8->canonical->encode(
        { session_id => next_sid(), hook_event_name => 'SubagentStop', agent_id => 'sub1', background_tasks => [] });
    my $res = run_gate($payload, env_for($dir, $led));
    is($res->{rc}, 0, 'C21: SubagentStop with agent_id, coordinator env, non-terminal ledger -> exit 0');
}

# ===========================================================================
# R6-M4 (red-team MEDIUM-4): _registry_sync does an unlocked read-modify-
# write of runs/registry.json. 4 coordinators (p, q, r, s), each with a
# terminal, fresh ledger, stop in parallel against ONE shared registry, for
# 15 rounds; no round may lose any of the 4 packages' status update to a
# sibling's concurrent write (the red-team measured >=1 lost in 5 of 15).
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1); (my $dirn = $dir) =~ s{\\}{/}g;
    make_path("$dirn/runs", "$dirn/packages");
    my @pkgs = qw(p q r s);
    my %led;
    for my $pkg (@pkgs) {
        my $ledp = "$dirn/packages/$pkg.md";
        $led{$pkg} = $ledp;
    }
    open my $r, '>:raw', "$dirn/runs/registry.json" or die $!;
    print {$r} JSON::PP->new->utf8->canonical->encode(
        { packages => { map { $_ => { attempts => 0 } } @pkgs } });
    close $r;

    my $checked = 0;
    my $lost    = 0;
    for my $round (1 .. 15) {
        for my $pkg (@pkgs) {
            open my $l, '>:raw', $led{$pkg} or die $!;
            print {$l} "---\npackage: $pkg\nstatus: parked\nlast_updated: 2026-06-24T00:00:00Z\n---\n# $pkg\n\n## Next action\n\nReviewed round $round.\n";
            close $l;
        }
        my @pids;
        for my $pkg (@pkgs) {
            my $pid = fork();
            die "fork: $!" unless defined $pid;
            if ($pid == 0) {
                my $croot = fresh_state_root();
                run_gate(payload_json(next_sid()),
                    BP_LEDGER => $led{$pkg}, BP_DIR => $dirn, BP_PACKAGE => $pkg,
                    BP_PROJECT_ROOT => $dirn, BUTLER_STATE_DIR => $croot);
                _exit(0);
            }
            push @pids, $pid;
        }
        waitpid($_, 0) for @pids;

        my $reg = read_json_file("$dirn/runs/registry.json");
        for my $pkg (@pkgs) {
            $checked++;
            my $status = ref($reg) eq 'HASH' ? $reg->{packages}{$pkg}{status} : undef;
            $lost++ unless defined $status && $status eq 'parked';
        }
    }
    is($lost, 0, "R6-M4: 4 coordinators stopping in parallel across 15 rounds never lose a registry status update (0 of $checked lost)");
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

done_testing();
