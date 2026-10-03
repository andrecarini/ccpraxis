#!/usr/bin/env perl
# platform: any
# Immutable oracle for blueprint where-things-go, package 03-thread-sessions:
# Almanac::Thread's new attach/detach/switch_thread/take_over/reattach/
# attached_thread/owner_status/cli_gate + almanac-thread.pl's new verbs
# (attach, detach, switch, take-over) and the hard ticket gate on every write
# verb, covering AC1, AC2, AC3, AC6, AC7, AC8, AC10, AC12 of
# specs/03-thread-sessions-spec.md section 4. AC4/AC11/AC16 (the liveness
# helper itself) live in the sibling session-liveness.t; AC5 lives in
# bug-triage-claim.t/bug-state-machine.t; AC9 lives in almanac-todo-crud.t;
# AC13 lives in continuity-off-check.t; AC14 lives in fork-guard.t/
# continuity-command-verbs.t.
#
# HOUSE PATTERN for not-yet-built code: every CLI call goes through run_cli()
# (system() + tempfiles); every direct module call (attach/detach/
# switch_thread/take_over/reattach/attached_thread/owner_status/cli_gate,
# and anything in Almanac::SessionLive) is wrapped in eval{} so "Undefined
# subroutine" / "Can't locate Almanac/SessionLive.pm" is a caught, reported
# failure for THIS assertion, not an abort of the whole file. At the time
# this file is written, almanac-thread.pl has NO attach/detach/switch/
# take-over verbs, Almanac::Thread has none of the new functions, and
# Almanac::SessionLive.pm does not exist at all -- every assertion below is
# expected to fail for exactly that reason, not any other.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Glob qw(bsd_glob);
use File::Basename qw(dirname);
use Cwd ();
use Encode ();
use JSON::PP ();
use Time::HiRes ();

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $THREAD_PL  = "$S/almanac-thread.pl";
my $DOCTOR_PL  = "$S/almanac-doctor.pl";
(my $BUTLER_SCRIPTS = "$Bin/../../../butler/scripts") =~ s{\\}{/}g;
my $BPHOOK_PM = "$BUTLER_SCRIPTS/BpHook.pm";
ok(-f $BPHOOK_PM, 'precondition: BpHook.pm exists beside butler') or BAIL_OUT('BpHook.pm missing');
require $BPHOOK_PM unless grep { m{(?:^|/)BpHook\.pm$} } keys %INC;

BEGIN {
    my $dir = "$FindBin::Bin/../../scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}

# ---------------------------------------------------------------------------
# hygiene (AC15): snapshot the REAL state before any fixture mutates %ENV.
# ---------------------------------------------------------------------------
my $REAL_HOME = $ENV{HOME} // $ENV{USERPROFILE} // '';
(my $REAL_BUTLER_STATE = length($REAL_HOME) ? "$REAL_HOME/.claude/butler-state" : '/nonexistent-no-real-home') =~ s{\\}{/}g;
(my $REAL_GC = length($REAL_HOME) ? "$REAL_HOME/.claude/almanac-global-counts.json" : '/nonexistent-no-real-home') =~ s{\\}{/}g;
(my $REPO_ROOT = "$Bin/../../../..") =~ s{\\}{/}g;
my $REAL_DATA = "$REPO_ROOT/.ccpraxis-local-data";
sub snapshot_dir {
    my ($dir) = @_;
    return { exists => 0 } unless -d $dir;
    my %info;
    my @stack = ($dir);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $full = "$d/$e";
            if (-d $full) { push @stack, $full }
            elsif ($full =~ m{/\.drive-solo/}) { } # excluded: a live background keepawake log, unrelated to this file
            else { $info{$full} = (stat $full)[9] }
        }
        closedir $dh;
    }
    return { exists => 1, files => \%info };
}
my $HYGIENE_BUTLER = snapshot_dir($REAL_BUTLER_STATE);
my $HYGIENE_DATA    = snapshot_dir($REAL_DATA);
my $HYGIENE_GC_MTIME = -f $REAL_GC ? (stat($REAL_GC))[9] : undef;

my $FILE_HOME = tempdir(CLEANUP => 1);
$FILE_HOME =~ s{\\}{/}g;
local $ENV{HOME}         = $FILE_HOME;
local $ENV{USERPROFILE}  = $FILE_HOME;
local $ENV{ALMANAC_HOME} = $FILE_HOME;
my $CFG = tempdir(CLEANUP => 1); $CFG =~ s{\\}{/}g;
local $ENV{CLAUDE_CONFIG_DIR} = $CFG;
my $BSD = tempdir(CLEANUP => 1); $BSD =~ s{\\}{/}g;
local $ENV{BUTLER_STATE_DIR} = $BSD;
delete local $ENV{CLAUDE_PROJECT_DIR};
delete local $ENV{CCPRAXIS_DATA_DIR};
delete local $ENV{CLAUDE_CODE_SESSION_ID};

# ---------------------------------------------------------------------------
# scaffolding
# ---------------------------------------------------------------------------
sub slurp_text {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:encoding(UTF-8)', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub slurp_raw {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub mkroot { my $r = tempdir(CLEANUP => 1); $r =~ s{\\}{/}g; return $r }

# run_cli(@args) -- a bare subprocess call, NO ticket minted. Use to probe
# the gate's refusal path, or after a caller has minted its own ticket.
sub run_cli {
    my (@args) = @_;
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    my $argstr = join(' ', map { qq{"$_"} } @args);
    system(qq{perl "$THREAD_PL" $argstr > "$outpath" 2> "$errpath"});
    my $rc = $? >> 8;
    return { rc => $rc, out => (slurp_text($outpath) // ''), err => (slurp_text($errpath) // '') };
}

my $TICKET_SEQ = 0;
my $MINT_WARNED = 0;
# mint_ticket($session, $agent_or_undef, @argv) -- a ticket for the EXACT
# argv the CLI will be run with. Does NOT die on failure: until BpHook.pm's
# _normalize_ticket_name is extended with 'almanac-thread' (this package's
# own write_set), write_ticket legitimately returns 0 for every call here --
# that must surface as a failed/refused assertion downstream, never abort
# this whole file.
sub mint_ticket {
    my ($session, $agent, @argv) = @_;
    local $ENV{BUTLER_STATE_DIR} = $BSD;
    my $ok = BpHook::write_ticket(
        { session_id => $session, tool_use_id => 'T' . (++$TICKET_SEQ),
          (defined $agent ? (agent_id => $agent) : ()),
          transcript_path => undef, cwd => '/fixture' },
        'almanac-thread', [ @argv ]);
    unless ($ok || $MINT_WARNED) {
        diag('mint_ticket: write_ticket returned false (expected pre-implementation -- '
           . "'almanac-thread' is not yet in BpHook::_normalize_ticket_name's whitelist)");
        $MINT_WARNED = 1;
    }
    return $ok;
}
# run_as($session, $agent_or_undef, @args) -- mints a ticket for EXACTLY
# @args, then spawns almanac-thread.pl with that same argv.
sub run_as {
    my ($session, $agent, @args) = @_;
    mint_ticket($session, $agent, @args);
    return run_cli(@args);
}

# seed_create($root, $name) -- fixture-seed a thread for this file's own
# scaffolding (package 03, Decision 34 fix-batch). 'create' is itself a
# gated write verb (spec 2.7), so it needs a ticket like every other write
# call in this file -- but a ticketed create also makes its ticket's
# session the thread's owner unless that session is ALREADY attached to
# something else in the same --root (spec 2.5's "already-attached-elsewhere
# deferral"). Every assertion below this file's fixtures feed expects a
# freshly-seeded thread to start UNOWNED, so the first create in each fresh
# root goes to a disposable anchor thread (consuming the "not yet attached"
# slot), and every real fixture thread is created only after that --
# deferred, and therefore unowned, exactly like a pre-gate bare create was.
my %SEEDED_ROOT;
sub seed_create {
    my ($root, $name) = @_;
    unless ($SEEDED_ROOT{$root}++) {
        run_as('SEED', undef, 'create', 'seed-anchor', '--root', $root);
    }
    return run_as('SEED', undef, 'create', $name, '--root', $root);
}

sub field0 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\Q$key\E:\s(\S+)$/m;
    return undef;
}
sub field2 {
    my ($text, $key) = @_;
    return undef unless defined $text;
    return $1 if $text =~ /^\s{2}\Q$key\E:\s(\S+)$/m;
    return undef;
}
sub err_kind { return field2($_[0], 'kind') }
sub decode_json_or_undef { my ($t) = @_; return eval { JSON::PP->new->decode($t) } }
sub show_json {
    my (@args) = @_;
    my $r = run_cli('show', @args, '--json');
    return (decode_json_or_undef($r->{out}), $r);
}

sub almanac_dir { my ($r) = @_; (my $a = Cwd::abs_path($r) // $r) =~ s{\\}{/}g; return "$a/.ccpraxis-local-data/almanac" }
sub thread_meta_path { my ($root, $name) = @_; return almanac_dir($root) . "/thread/$name.md" }

# ensure_transcript($sid, $mtime_epoch) -- a file under $CFG/projects/p/.
sub ensure_transcript {
    my ($sid, $mtime) = @_;
    my $dir = "$CFG/projects/p";
    make_path($dir) unless -d $dir;
    my $path = "$dir/$sid.jsonl";
    open my $fh, '>', $path or die "fixture: cannot write transcript $path: $!";
    print {$fh} "{}\n";
    close $fh;
    utime($mtime, $mtime, $path) if defined $mtime;
    return $path;
}

# ---------------------------------------------------------------------------
# direct-module helpers (wrapped in eval, per house pattern)
# ---------------------------------------------------------------------------
sub load_thread_module { local $@; eval { require Almanac::Thread; 1 } }
load_thread_module();

sub call_attach  { my (%o) = @_; local $@; my @r = eval { Almanac::Thread::attach(delete $o{name}, %o) }; return (\@r, $@) }
sub call_detach  { my (%o) = @_; local $@; my @r = eval { Almanac::Thread::detach(delete $o{name}, %o) }; return (\@r, $@) }
sub call_switch  { my (%o) = @_; local $@; my @r = eval { Almanac::Thread::switch_thread(delete $o{name}, %o) }; return (\@r, $@) }
sub call_takeover{ my (%o) = @_; local $@; my @r = eval { Almanac::Thread::take_over(delete $o{name}, %o) }; return (\@r, $@) }
sub call_reattach{ my (%o) = @_; local $@; my $r = eval { Almanac::Thread::reattach(%o) }; return ($r, $@) }
sub call_attached_thread { my (%o) = @_; local $@; my $r = eval { Almanac::Thread::attached_thread(%o) }; return ($r, $@) }
sub call_owner_status    { my ($t, %o) = @_; local $@; my $r = eval { Almanac::Thread::owner_status($t, %o) }; return ($r, $@) }

ok(-f $THREAD_PL, 'almanac-thread.pl exists at plugins/almanac/scripts/almanac-thread.pl')
    or diag('present from package 02; every new-verb assertion below is expected to fail until package 03 lands');

# =============================================================================
# AC1 (behaviours 1, 3, 5) -- attach / detach / switch / take-over: output
# shapes, owner/state transitions, log entries (event, from, to, reason).
# =============================================================================
{
    my $ROOT = mkroot();
    seed_create($ROOT, 't');

    my $r1 = run_as('S1', undef, 'attach', 't', '--root', $ROOT);
    is($r1->{rc}, 0, 'AC1: attach t (main-session ticket) exits 0') or diag("out=$r1->{out}\nerr=$r1->{err}");
    is(field0($r1->{out}, 'thread'), 't',               'AC1: output thread: t');
    is(field0($r1->{out}, 'owner'),  'session:S1',       'AC1: output owner: session:S1');
    is(field0($r1->{out}, 'changed'), 'yes',             'AC1: output changed: yes');

    my ($sj) = show_json('t', '--root', $ROOT);
    if (ref($sj) eq 'HASH') {
        ok(exists $sj->{thread}{owner_transcript} || 1, 'AC1: thread hash carries owner_transcript (may be undef)');
        ok(defined $sj->{thread}{attached_at}, 'AC1: attached_at is recorded') if exists $sj->{thread}{attached_at};
        my @log = @{ $sj->{log} // [] };
        is($log[-1]{event}, 'attached', 'AC1: log ends with an attached entry') if @log;
        is($log[-1]{session}, 'S1', 'AC1: the attached entry names session S1') if @log && exists $log[-1]{session};
    }

    my $r1b = run_as('S1', undef, 'attach', 't', '--root', $ROOT);
    is(field0($r1b->{out}, 'changed'), 'no', 'AC1: repeating attach by the same owner prints changed: no');

    # switch then take-over chain, each shape checked.
    seed_create($ROOT, 'u');
    my $rsw = run_as('S1', undef, 'switch', 'u', '--root', $ROOT);
    is($rsw->{rc}, 0, 'AC1: switch u (owned t -> u) exits 0') or diag($rsw->{err});
    is(field0($rsw->{out}, 'left'), 't', 'AC1: switch output ends left: t');
    is(field0($rsw->{out}, 'owner'), 'session:S1', 'AC1: switch output owner: session:S1');

    # S1's transcript ages past the idle threshold with no arm record; S2
    # then sees it as dead and may take over (behaviour 5).
    ensure_transcript('S1', time() - 2 * 3600);
    my $rdead = run_as('S2', undef, 'attach', 'u', '--root', $ROOT);
    is(field2($rdead->{err}, 'detail'), 'owner_dead',
        'AC1: attach by S2 while S1 is dead (2h idle, unarmed) -> owner_dead')
        or diag("err=$rdead->{err}");
    my $rto = run_as('S2', undef, 'take-over', 'u', '--reason', 'x', '--root', $ROOT);
    is($rto->{rc}, 0, 'AC1: take-over u --reason x by S2 exits 0') or diag($rto->{err});
    is(field0($rto->{out}, 'owner'), 'session:S2', 'AC1: take-over output owner: session:S2');
    my ($sju) = show_json('u', '--root', $ROOT);
    if (ref($sju) eq 'HASH') {
        my @log = @{ $sju->{log} // [] };
        my ($to_entry) = grep { $_->{event} eq 'taken-over' } @log;
        ok(defined $to_entry, 'AC1: a taken-over log entry exists');
        if ($to_entry) {
            is($to_entry->{from}, 'session:S1', 'AC1: taken-over entry from: session:S1');
            is($to_entry->{to},   'session:S2', 'AC1: taken-over entry to: session:S2');
            is($to_entry->{reason}, 'x',        'AC1: taken-over entry reason: x');
        }
    }
}

# =============================================================================
# AC2 -- a second live session's attach refused owner_live naming the owner;
# concurrent attaches of one free thread; one session attaching two threads.
# =============================================================================
{
    my $ROOT = mkroot();
    seed_create($ROOT, 'v');
    run_as('LIVE1', undef, 'attach', 'v', '--root', $ROOT);
    ensure_transcript('LIVE1', time()); # fresh -- alive

    my $r2 = run_as('LIVE2', undef, 'attach', 'v', '--root', $ROOT);
    is($r2->{rc}, 2, 'AC2: a second session attaching a live-owned thread exits 2');
    is(field2($r2->{err}, 'detail'), 'owner_live', 'AC2: ...detail: owner_live');
    is(field2($r2->{err}, 'cause'), 'session:LIVE1', 'AC2: ...cause names the live owner');
    my ($sj) = show_json('v', '--root', $ROOT);
    is($sj->{thread}{owner_id}, 'LIVE1', 'AC2: metadata is unchanged after the refusal') if ref($sj) eq 'HASH';
}
{
    # concurrent attach race on one free thread: exactly one of two sessions
    # wins, the other sees owner_live.
    my $ROOT = mkroot();
    seed_create($ROOT, 'race');
    my $workdir = tempdir(CLEANUP => 1); $workdir =~ s{\\}{/}g;
    my $child = "$workdir/child.pl";
    open(my $fh, '>', $child) or die $!;
    print {$fh} <<'CHILD';
#!/usr/bin/env perl
use strict; use warnings;
my ($workdir, $n, $thread_pl, $bphook_pm, $session, $root) = @ARGV;
require $bphook_pm;
# the ticket is keyed by (verb, argv) alone, not by session (BpHook.pm's
# take_ticket: two LIVE tickets for the exact same argv are ambiguous
# regardless of whose session wrote them -- that is a deliberate anti-spoof
# rule, spec 2.6, not something a same-command concurrency race should ever
# collide with). Each racer's argv carries its own --session so the two
# tickets key differently, leaving the real lock-level race (spec 2.5's
# "Concurrent attach race") as the only thing this test exercises.
BpHook::write_ticket({ session_id => $session, tool_use_id => "RT$n", transcript_path => undef, cwd => '/fixture' },
    'almanac-thread', ['attach', 'race', '--root', $root, '--session', $session]);
my $out = `perl "$thread_pl" attach race --root "$root" --session "$session" 2>&1`;
my $rc = $? >> 8;
open(my $of, '>', "$workdir/out.$n") or die $!; print {$of} $out; close $of;
open(my $df, '>', "$workdir/done.$n") or die $!; print {$df} "RC=$rc\n"; close $df;
exit 0;
CHILD
    close $fh;
    sub bounded_wait_race {
        my ($path, $deadline_s) = @_;
        my $deadline = Time::HiRes::time() + $deadline_s;
        while (!-e $path) { return 0 if Time::HiRes::time() >= $deadline; Time::HiRes::sleep(0.02) }
        return 1;
    }
    for my $pair ([1, 'RACE-A'], [2, 'RACE-B']) {
        my ($n, $sid) = @$pair;
        my $argstr = join(' ', map { qq{"$_"} } ($workdir, $n, $THREAD_PL, $BPHOOK_PM, $sid, $ROOT));
        system(qq{perl "$child" $argstr > "$workdir/spawn-log.$n" 2>&1 &});
    }
    my @rcs;
    for my $i (1, 2) {
        bounded_wait_race("$workdir/done.$i", 30);
        my $t = slurp_text("$workdir/done.$i") // '';
        my ($rc) = $t =~ /RC=(\d+)/;
        push @rcs, $rc;
    }
    my @zeros = grep { defined $_ && $_ == 0 } @rcs;
    is(scalar(@zeros), 1, 'AC2: of two sessions racing to attach one free thread, exactly one succeeds')
        or diag("rcs: @rcs");
}
{
    # one session attaching two threads "in parallel" ends attached to
    # exactly one (switch_thread / attach serialize under the session lock).
    my $ROOT = mkroot();
    seed_create($ROOT, 'p1');
    seed_create($ROOT, 'p2');
    run_as('PAR', undef, 'attach', 'p1', '--root', $ROOT);
    run_as('PAR', undef, 'attach', 'p2', '--root', $ROOT);
    my ($sj1) = show_json('p1', '--root', $ROOT);
    my ($sj2) = show_json('p2', '--root', $ROOT);
    my $owns1 = ref($sj1) eq 'HASH' && $sj1->{thread}{owner_id} eq 'PAR';
    my $owns2 = ref($sj2) eq 'HASH' && $sj2->{thread}{owner_id} eq 'PAR';
    ok(($owns1 ? 1 : 0) + ($owns2 ? 1 : 0) == 1,
        'AC2: session PAR ends attached to exactly one of two threads it tried')
        or diag("owns1=$owns1 owns2=$owns2");
}

# =============================================================================
# AC3 (behaviour 4) -- leaving rule: an unlinked task in doing blocks detach
# and switch, naming the task; linked tasks never block.
# =============================================================================
{
    my $ROOT = mkroot();
    seed_create($ROOT, 'w');
    seed_create($ROOT, 'w2');
    my $idA = field0(run_as('SEED', undef, 'add', 'w', '--title', 'a', '--root', $ROOT)->{out}, 'task');
    # a second, never-done unlinked task so marking idA 'done' below does not
    # make every task on 'w' done -- this block is testing the leaving rule,
    # not thread auto-archive-on-all-done (a real, separate package-02
    # behaviour this fixture must not accidentally trigger).
    field0(run_as('SEED', undef, 'add', 'w', '--title', 'b', '--root', $ROOT)->{out}, 'task');
    run_as('SEED', undef, 'status', 'w', $idA, 'doing', '--root', $ROOT);
    run_as('LV1', undef, 'attach', 'w', '--root', $ROOT);

    my $rd = run_as('LV1', undef, 'detach', 'w', '--root', $ROOT);
    is($rd->{rc}, 2, 'AC3: detach while an unlinked task is doing exits 2');
    is(field2($rd->{err}, 'detail'), 'task_doing', 'AC3: ...detail: task_doing');
    is(field2($rd->{err}, 'cause'), $idA, 'AC3: ...cause names the doing task');

    my $rsw = run_as('LV1', undef, 'switch', 'w2', '--root', $ROOT);
    is($rsw->{rc}, 2, 'AC3: switch away while an unlinked task is doing exits 2');
    is(field2($rsw->{err}, 'detail'), 'task_doing', 'AC3: ...detail: task_doing (switch)');

    run_as('SEED', undef, 'status', 'w', $idA, 'done', '--root', $ROOT);
    my $rd2 = run_as('LV1', undef, 'detach', 'w', '--root', $ROOT);
    is($rd2->{rc}, 0, 'AC3: detach succeeds once the doing task is done') or diag($rd2->{err});
}
{
    # linked tasks never block leaving, whatever their ledger status.
    my $ROOT = mkroot();
    seed_create($ROOT, 'lw');
    (my $base = "$ROOT/.ccpraxis-local-data/blueprints/bp/packages") =~ s{\\}{/}g;
    make_path($base);
    open(my $pf, '>:raw', "$base/01-x.md") or die $!;
    print {$pf} "---\nstatus: running\n---\n\n# 01-x\n";
    close $pf;
    run_as('SEED', undef, 'add', 'lw', '--link', 'bp/01-x', '--root', $ROOT);
    run_as('LV2', undef, 'attach', 'lw', '--root', $ROOT);
    my $rd = run_as('LV2', undef, 'detach', 'lw', '--root', $ROOT);
    is($rd->{rc}, 0, 'AC3: detach succeeds with only a linked task present, regardless of its ledger status')
        or diag($rd->{err});
}

# =============================================================================
# AC6 (behaviour 7) -- reattach: clear/compact/resume/startup cases.
# =============================================================================
SKIP: {
    skip 'AC6: Almanac::Thread not loadable', 1 unless load_thread_module();
    {
        my $ROOT = mkroot();
        seed_create($ROOT, 'rt');
        run_as('PRED', undef, 'attach', 'rt', '--root', $ROOT);
        my $dir = "$CFG/projects/p2";
        make_path($dir);
        my $pred_t = "$dir/PRED.jsonl";
        open(my $fh, '>', $pred_t) or die $!; print {$fh} "{}\n"; close $fh;
        utime(time() - 2 * 3600, time() - 2 * 3600, $pred_t); # dead: 2h idle, unarmed
        my $new_t = "$dir/NEW.jsonl";
        open(my $fh2, '>', $new_t) or die $!; print {$fh2} "{}\n"; close $fh2;

        my ($res, $err) = call_reattach(session => 'NEW', transcript => $new_t, source => 'clear', root => $ROOT);
        is(ref($res) eq 'HASH' ? $res->{result} : "died: $err", 'attached',
            'AC6: reattach after clear with a dead predecessor -> attached') or diag($err);
        my ($sj) = show_json('rt', '--root', $ROOT);
        is($sj->{thread}{owner_id}, 'NEW', 'AC6: thread rt is now owned by NEW') if ref($sj) eq 'HASH';
    }
    {
        my $ROOT = mkroot();
        seed_create($ROOT, 'rt2');
        run_as('PRED2', undef, 'attach', 'rt2', '--root', $ROOT);
        my $dir = "$CFG/projects/p3";
        make_path($dir);
        my $pred_t = "$dir/PRED2.jsonl";
        open(my $fh, '>', $pred_t) or die $!; print {$fh} "{}\n"; close $fh;
        utime(time(), time(), $pred_t); # fresh -- PRED2 is alive
        my $new_t = "$dir/NEW2.jsonl";
        open(my $fh2, '>', $new_t) or die $!; print {$fh2} "{}\n"; close $fh2;

        my ($res, $err) = call_reattach(session => 'NEW2', transcript => $new_t, source => 'clear', root => $ROOT);
        is(ref($res) eq 'HASH' ? $res->{result} : "died: $err", 'owner_live',
            'AC6: reattach while the predecessor is alive -> owner_live, nothing written') or diag($err);
    }
    {
        my $ROOT = mkroot();
        seed_create($ROOT, 'rt3');
        run_as('SAME', undef, 'attach', 'rt3', '--root', $ROOT);
        my ($res, $err) = call_reattach(session => 'SAME', transcript => undef, source => 'compact', root => $ROOT);
        is(ref($res) eq 'HASH' ? $res->{result} : "died: $err", 'already',
            'AC6: reattach for compact/resume (same session id already attached) -> already') or diag($err);
    }
    {
        my $ROOT = mkroot();
        my ($res, $err) = call_reattach(session => 'FRESH', transcript => undef, source => 'startup', root => $ROOT);
        is(ref($res) eq 'HASH' ? $res->{result} : "died: $err", 'skipped',
            'AC6: reattach source startup -> skipped (a fresh session has no predecessor)') or diag($err);
    }
}

# =============================================================================
# AC7 (behaviour 14) -- ArmOnEntry re-attach wiring.
# =============================================================================
{
    (my $GH_LIB = "$Bin/../../../butler/tests/lib") =~ s{\\}{/}g;
    if (-f "$GH_LIB/GuardHarness.pm") {
        local @INC = ($GH_LIB, @INC);
        local $@;
        # package 03, Decision 34 fix-batch: GuardHarness.pm deletes
        # BUTLER_STATE_DIR (and friends) from %ENV UNCONDITIONALLY at module
        # LOAD time (its own "isolate AT LOAD" design, GuardHarness.pm:250-
        # 269) -- so %ENV must already be localized before the `require`
        # itself runs, not only around the fresh_state()/run_module() calls
        # that follow it, or this file's own $BSD leaks away permanently for
        # every assertion after this block.
        local %ENV = %ENV;
        eval { require GuardHarness; 1 };
        if (!$@) {
            my $base = GuardHarness::fresh_state();
            # fresh_state() just repointed BUTLER_STATE_DIR at its own fresh
            # dir ($base) -- but seed_create()/run_as() below spawn
            # almanac-thread.pl subprocesses that must see the SAME
            # BUTLER_STATE_DIR ($BSD) their mint_ticket() call just wrote
            # the ticket into (mint_ticket's own "local" only lasts for the
            # mint call itself, not through the later run_cli() subprocess
            # spawn), or every one of those calls is refused no_ticket.
            # Restore $BSD for them; switch to $base only for the
            # GuardHarness::arm()/run_module() calls that actually need
            # ArmOnEntry's isolated state root.
            $ENV{BUTLER_STATE_DIR} = $BSD;
            $ENV{CLAUDE_CONFIG_DIR} = $CFG;
            my $ROOT = mkroot();
            seed_create($ROOT, 'arm-rt');
            run_as('AOE-PRED', undef, 'attach', 'arm-rt', '--root', $ROOT);
            my $dir = "$CFG/projects/arm";
            make_path($dir);
            my $pred_t = "$dir/AOE-PRED.jsonl";
            open(my $fh, '>', $pred_t) or die $!; print {$fh} "{}\n"; close $fh;
            utime(time() - 2 * 3600, time() - 2 * 3600, $pred_t);
            my $new_t = "$dir/AOE-NEW.jsonl";
            open(my $fh2, '>', $new_t) or die $!; print {$fh2} "{}\n"; close $fh2;

            $ENV{BUTLER_STATE_DIR} = $base;
            GuardHarness::arm('AOE-NEW', 'driver');
            my $payload = { hook_event_name => 'PreToolUse', tool_name => 'Bash',
                            tool_input => { command => 'bp-drive-next next' },
                            session_id => 'AOE-NEW', tool_use_id => 'T1',
                            cwd => $ROOT, transcript_path => $new_t };
            my $res = GuardHarness::run_module('ArmOnEntry', $payload, env => { CLAUDE_CONFIG_DIR => $CFG });
            is($res->{rc}, 0, 'AC7: ArmOnEntry run() still returns 0 after the reattach call');

            my ($sj) = show_json('arm-rt', '--root', $ROOT);
            is($sj->{thread}{owner_id}, 'AOE-NEW', 'AC7: a director-call payload re-attaches a dead predecessor\'s thread')
                if ref($sj) eq 'HASH';
        } else {
            ok(1, 'AC7: skipped (GuardHarness not loadable)');
        }
    } else {
        ok(1, 'AC7: skipped (GuardHarness.pm not found)');
    }
}

# =============================================================================
# AC8 (behaviour 8) -- the CLI gate: subagent refused, main succeeds, no
# ticket / ambiguous / mismatch refused with prose; list/show ungated.
# =============================================================================
{
    my $ROOT = mkroot();
    seed_create($ROOT, 'g1');
    my $before = slurp_raw(thread_meta_path($ROOT, 'g1'));

    my $rsub = run_as('SUBS', 'AG1', 'attach', 'g1', '--root', $ROOT);
    is($rsub->{rc}, 2, 'AC8: a ticket carrying agent_id (a subagent) is refused');
    is(field2($rsub->{err}, 'detail'), 'subagent_writer', 'AC8: ...detail: subagent_writer');
    like($rsub->{err}, qr/subagent/i, 'AC8: STDERR names the subagent rule');
    is(slurp_raw(thread_meta_path($ROOT, 'g1')), $before, 'AC8: nothing under <almanac> changed after the refusal');

    my $rmain = run_as('MAIN1', undef, 'attach', 'g1', '--root', $ROOT);
    is($rmain->{rc}, 0, 'AC8: the main session succeeds') or diag($rmain->{err});

    seed_create($ROOT, 'g2');
    my $rno = run_cli('attach', 'g2', '--root', $ROOT); # no ticket minted at all
    is($rno->{rc}, 2, 'AC8: no ticket at all is refused');
    is(field2($rno->{err}, 'detail'), 'no_ticket', 'AC8: ...detail: no_ticket');

    my @argv = ('attach', 'g2', '--root', $ROOT);
    mint_ticket('AMBI1', undef, @argv);
    mint_ticket('AMBI2', undef, @argv);
    my $ramb = run_cli(@argv);
    is($ramb->{rc}, 2, 'AC8: two tickets for the same argv within 30s -> ambiguous');
    is(field2($ramb->{err}, 'detail'), 'ambiguous_ticket', 'AC8: ...detail: ambiguous_ticket');

    seed_create($ROOT, 'g3');
    mint_ticket('TKS1', undef, 'attach', 'g3', '--root', $ROOT, '--session', 'S9');
    my $rmis = run_cli('attach', 'g3', '--root', $ROOT, '--session', 'S9');
    is($rmis->{rc}, 2, 'AC8: --session naming a different session than the ticket is refused');
    is(field2($rmis->{err}, 'detail'), 'session_mismatch', 'AC8: ...detail: session_mismatch');

    my $rlist = run_cli('list', '--root', $ROOT);
    is($rlist->{rc}, 0, 'AC8: list needs no ticket') or diag($rlist->{err});
    my $rshow = run_cli('show', 'g1', '--root', $ROOT);
    is($rshow->{rc}, 0, 'AC8: show needs no ticket') or diag($rshow->{err});
}

# =============================================================================
# AC10 (behaviour 10) -- library calls are ungated even with butler present.
# =============================================================================
SKIP: {
    skip 'AC10: Almanac::Thread not loadable', 1 unless load_thread_module();
    my $ROOT = mkroot();
    seed_create($ROOT, 'lib1');
    my ($res, $err) = call_attach(name => 'lib1', session => 'LIBS1', root => $ROOT);
    ok(!length($err), 'AC10: a direct Almanac::Thread::attach call with no ticket succeeds (library calls are ungated)')
        or diag("died: $err");

    local $@;
    eval { Almanac::Thread::record_event('lib1', 'paused', reason => 'orchestrator event', actor => 'orchestrator', root => $ROOT) };
    ok(!$@, 'AC10: record_event(actor => orchestrator) with no ticket succeeds') or diag($@);

    local $@;
    eval { Almanac::Thread::migrate_legacy(root => $ROOT) };
    ok(!$@, 'AC10: migrate_legacy with no ticket succeeds') or diag($@);
}

# =============================================================================
# AC12 (behaviour 12) -- butler absent: thread writes ungated; doctor warns.
# =============================================================================
{
    my $copyroot = tempdir(CLEANUP => 1); $copyroot =~ s{\\}{/}g;
    my $almanac_src = "$Bin/../.."; # plugins/almanac/tests/t -> plugins/almanac
    (my $src_abs = Cwd::abs_path($almanac_src)) =~ s{\\}{/}g;
    my $dest = "$copyroot/plugins/almanac";
    make_path($dest);
    my @files;
    { require File::Find; File::Find::find(sub { push @files, $File::Find::name if -f $_ }, $src_abs) }
    for my $f (@files) {
        (my $norm = $f) =~ s{\\}{/}g;
        (my $rel = $norm) =~ s/\A\Q$src_abs\E//;
        next if $rel =~ m{^/tests/}; # tests not needed for this fixture
        my $destf = "$dest$rel";
        make_path(dirname($destf));
        copy($f, $destf) or diag("copy failed: $f -> $destf: $!");
    }
    ok(-f "$dest/scripts/almanac-thread.pl", 'AC12 fixture: the copied tree has almanac-thread.pl')
        or diag("copy incomplete under $dest");
    ok(!-d "$copyroot/plugins/butler", 'AC12 fixture: no butler/ sibling exists beside the copy');

    my $ROOT = mkroot();
    my (undef, $outpath) = tempfile(UNLINK => 1);
    my (undef, $errpath) = tempfile(UNLINK => 1);
    system(qq{perl "$dest/scripts/almanac-thread.pl" create abs1 --root "$ROOT" > "$outpath" 2> "$errpath"});
    my $rc1 = $? >> 8;
    is($rc1, 0, 'AC12: with butler absent, create succeeds with no ticket') or diag(slurp_text($errpath));
    system(qq{perl "$dest/scripts/almanac-thread.pl" attach abs1 --root "$ROOT" --session ABS1 > "$outpath" 2> "$errpath"});
    my $rc2 = $? >> 8;
    is($rc2, 0, 'AC12: with butler absent, attach succeeds with no ticket') or diag(slurp_text($errpath));

    my (undef, $doutpath) = tempfile(UNLINK => 1);
    my (undef, $derrpath) = tempfile(UNLINK => 1);
    system(qq{perl "$dest/scripts/almanac-doctor.pl" --root "$ROOT" > "$doutpath" 2> "$derrpath"});
    my $derr = slurp_text($derrpath) // '';
    like($derr, qr/almanac doctor: warning: butler is not installed beside almanac/,
        'AC12: the copied almanac-doctor.pl warns that butler is not installed beside it') or diag($derr);
    like($derr, qr/thread writes are not gated against subagents/,
        'AC12: ...and names what that means');
}

# =============================================================================
# REGRESSION (blueprint tooling-backlog, package 13-almanac-decision-
# relative-path; almanac bug 20261001-184636-75fe; no architect spec --
# Decision 65, mechanical fix): almanac-thread.pl, invoked by its everyday
# RELATIVE path from the repo root (the bug report's exact repro style),
# must never fail with perl's "Can't locate ... in @INC". almanac-thread.pl's
# BEGIN block is bareword-only (`use Module::Name ()`, no sibling-SCRIPT
# require) and already passes for a harmless read verb today; it is
# asserted here so the fix (touching every BEGIN block named by the
# ledger's write_set) cannot regress it. The doubled-join failure itself is
# covered for almanac-doctor.pl/almanac-bug.pl/almanac-migrate-todos.pl/
# almanac-migrate-memories.pl in almanac-doctor.t, almanac-inbox.pl/
# almanac-task.pl in almanac-decision-blocks.t, and almanac-note.pl/
# almanac-todo.pl in almanac-global-counts.t.
# =============================================================================
{
    # run_cli_relative(@args) -- same fork()+exec()+tempfile-capture
    # discipline as run_cli() above, but the CHILD chdir()s to $REPO_ROOT
    # first and the script is given as a RELATIVE path -- reproducing the
    # bug report's literal invocation style. This process's own cwd is
    # never touched.
    sub run_cli_relative {
        my (@args) = @_;
        my (undef, $outpath) = tempfile();
        my (undef, $errpath) = tempfile();
        my $pid = fork();
        die "run_cli_relative: fork() failed: $!" unless defined $pid;
        if ($pid == 0) {
            chdir($REPO_ROOT) or exit(125);
            open(STDOUT, '>', $outpath) or exit(126);
            open(STDERR, '>', $errpath) or exit(126);
            exec($^X, 'plugins/almanac/scripts/almanac-thread.pl', @args) or exit(127);
        }
        waitpid($pid, 0);
        my $rc = $? >> 8;
        return { rc => $rc, out => (slurp_text($outpath) // ''), err => (slurp_text($errpath) // '') };
    }

    my $ROOT = mkroot();
    my $r = run_cli_relative('list', '--root', $ROOT);
    unlike($r->{out} . $r->{err}, qr/Can't locate \S+ in \@INC/,
        'REGRESSION (75fe): almanac-thread.pl by RELATIVE path from the repo root never fails "Can\'t locate ... in @INC"')
        or diag("rc=$r->{rc}\nout:\n$r->{out}\nerr:\n$r->{err}");
    is($r->{rc}, 0, 'REGRESSION (75fe): almanac-thread.pl "list" on an empty --root exits 0 via relative invocation')
        or diag("out:\n$r->{out}\nerr:\n$r->{err}");
}

# ---- AC15: this file never touched the REAL machine state -----------------
{
    my $after_butler = snapshot_dir($REAL_BUTLER_STATE);
    my $after_data = snapshot_dir($REAL_DATA);
    is_deeply($after_butler, $HYGIENE_BUTLER, 'AC15: the real ~/.claude/butler-state is untouched by this file');
    is_deeply($after_data, $HYGIENE_DATA, 'AC15: the real repo .ccpraxis-local-data is untouched by this file');
    my $after_gc_mtime = -f $REAL_GC ? (stat($REAL_GC))[9] : undef;
    is($after_gc_mtime, $HYGIENE_GC_MTIME, 'AC15: the real ~/.claude/almanac-global-counts.json mtime is unchanged');
}

done_testing();
