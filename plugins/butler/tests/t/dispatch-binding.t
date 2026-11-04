#!/usr/bin/env perl
# platform: any
# Oracle for package 12-dispatch-binding (blueprint hook-continuity-remake),
# specs/12-dispatch-binding-spec.md AC-1..AC-20. plugins/butler/hooks/
# bind-dispatch.sh and BpHook/BindDispatch.pm DO NOT EXIST YET at the time
# this file is written -- every in-process case goes through GuardHarness::
# run_module() (plugins/butler/tests/lib/GuardHarness.pm), which mirrors
# BpHook::main()'s own require-and-call contract, so a missing module fails
# open (rc 0) exactly as the real wrapper would -- legibly, never a crash in
# this file. Every [W] case spawns the real bash file at that path and gets
# a plain "No such file or directory" until the implementer writes it.
# AC-20 (director reclaim) requires plugins/butler/scripts/bp-drive-next.pl
# directly, using the drive-next-inflight-set.t BpDrive::run idiom.
#
# WRITTEN BLIND TO THE IMPLEMENTATION: derived only from the spec text.
#
# Not re-expressed here (spec sec 6 "Out of scope"): any fork/subagent
# dispatch rule (package 19), registering bind-dispatch or deleting
# the old record-dispatch-package hook (package 16), write-guard resolution from
# bindings (package 13), pruning terminal members or locking inflight.json
# from the hook, a `reclaimed` key on the director's action.
#
# Runs standalone: perl this file
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname basename);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use Cwd ();
use Time::HiRes ();
use File::Find ();
use POSIX ();

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

use lib dirname(__FILE__) . '/../lib';
use GuardHarness;

# ---------------------------------------------------------------------------
# Ambient isolation for the WHOLE file, up front, before any fixture or arm()
# call runs (binding lesson: isolate_env()/fresh_state() before ANY arm).
# ---------------------------------------------------------------------------
delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
GuardHarness::isolate_env();

# ABSOLUTE, per AC-20's "require $DRIVE_SCRIPT" (require() only searches
# @INC, which no longer contains "." on modern perl -- a relative path here
# would fail to locate bp-drive-next.pl regardless of whether it exists).
(my $BUTLER_DIR = Cwd::abs_path(dirname(__FILE__) . '/../..')) =~ s{\\}{/}g;
my $WRAPPER    = 'plugins/butler/hooks/bind-dispatch.sh';
my $J = JSON::PP->new->utf8->canonical;

# ---------------------------------------------------------------------------
# Byte / JSON I/O helpers.
# ---------------------------------------------------------------------------
sub read_bytes {
    my ($p) = @_;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub write_bytes {
    my ($path, $bytes) = @_;
    (my $dir = $path) =~ s{[/\\][^/\\]*\z}{};
    make_path($dir) if length($dir) && !-d $dir;
    open(my $fh, '>:raw', $path) or die "cannot write $path: $!";
    print {$fh} $bytes;
    close $fh;
}
sub read_json {
    my ($p) = @_;
    my $raw = read_bytes($p);
    return undef unless defined $raw;
    return eval { $J->decode($raw) };
}
sub write_json {
    my ($path, $data) = @_;
    write_bytes($path, $J->encode($data) . "\n");
}

# ---------------------------------------------------------------------------
# Fixture helpers for the .drive-solo/ area this hook reads/writes.
# ---------------------------------------------------------------------------
sub fresh_data {
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/data") =~ s{\\}{/}g;
    make_path($d);
    return $d;
}

# <L>/blueprints/<bp>/packages/<pkg>.md, <L> = basename(data) after \ -> /,
# trailing slashes dropped (spec sec 2.5).
sub ledger_line {
    my ($data, $bp, $pkg) = @_;
    (my $b = $data) =~ s{\\}{/}g;
    $b =~ s{/+\z}{};
    my $L = basename($b);
    return "$L/blueprints/$bp/packages/$pkg.md";
}

sub write_inflight {
    my ($data, @members) = @_; # each { bp => ..., pkg => ... }
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/inflight.json", {
        packages => [ map { { blueprint => $_->{bp}, package => $_->{pkg}, ledger => 'ignored-by-hook', since => 1 } } @members ],
        updated_at => 1,
    });
    # Bug 20261104-164548-2d3a: the hook no longer auto-binds a member whose
    # ledger is missing or terminal (BpState::inflight_unbindable), so every
    # member listed here gets a live ledger unless the case wrote its own.
    for my $m (@members) {
        my $lp = "$data/blueprints/$m->{bp}/packages/$m->{pkg}.md";
        next if -e $lp;
        write_bytes($lp, "---\npackage: $m->{pkg}\nblueprint: $m->{bp}\nstatus: running\n"
                       . "write_set: src/$m->{pkg}/\n---\n");
    }
}
sub write_current {
    my ($data, $bp, $pkg) = @_;
    make_path("$data/.drive-solo");
    write_json("$data/.drive-solo/current.json", { blueprint => $bp, package => $pkg, recorded_at => 1 });
}

sub bindings_dir      { my ($data) = @_; return "$data/.drive-solo/bindings" }
sub bindings_history  { my ($data) = @_; return "$data/.drive-solo/bindings.jsonl" }
sub bindings_history1 { my ($data) = @_; return "$data/.drive-solo/bindings.jsonl.1" }

sub binding_files {
    my ($data) = @_;
    my $d = bindings_dir($data);
    my @files = -d $d ? sort glob("$d/*.json") : ();
    return wantarray ? @files : scalar(@files);
}
sub history_lines {
    my ($data) = @_;
    my $raw = read_bytes(bindings_history($data));
    my @lines = defined $raw ? (grep { length } split /\n/, $raw) : ();
    return wantarray ? @lines : scalar(@lines);
}

# ---------------------------------------------------------------------------
# expected_deny_text($data, @members) -- the B8 denial text for a member set
# in set order (spec sec 3, B8; $MAX_LISTED = 4).
# ---------------------------------------------------------------------------
sub expected_deny_text {
    my ($data, @members) = @_;
    my $n = scalar @members;
    my $MAX_LISTED = 4;
    my @lines = ("With $n packages in flight a dispatch prompt must name exactly one ledger path:");
    my $shown = $n > $MAX_LISTED ? $MAX_LISTED : $n;
    for my $i (0 .. $shown - 1) {
        push @lines, "  " . ledger_line($data, $members[$i]{bp}, $members[$i]{pkg});
    }
    push @lines, "  ...and " . ($n - $MAX_LISTED) . " more" if $n > $MAX_LISTED;
    return join("\n", @lines) . "\n";
}

# ---------------------------------------------------------------------------
# payload(%o) -- a Task/Agent PreToolUse (or other event) payload.
# ---------------------------------------------------------------------------
sub payload {
    my (%o) = @_;
    my $ti = {};
    $ti->{subagent_type} = $o{subagent_type} if exists $o{subagent_type};
    $ti->{prompt}        = $o{prompt}        if exists $o{prompt};
    my $p = { tool_name => $o{tool_name} // 'Task', tool_input => $ti };
    $p->{hook_event_name} = $o{event} // 'PreToolUse' unless $o{no_event_name};
    $p->{session_id}  = $o{session_id}  if exists $o{session_id};
    $p->{agent_id}    = $o{agent_id}    if exists $o{agent_id};
    $p->{tool_use_id} = $o{tool_use_id} if exists $o{tool_use_id};
    $p->{cwd}         = $o{cwd}         if exists $o{cwd};
    return $p;
}

# ---------------------------------------------------------------------------
# bd($payload, %opts) -- GuardHarness::run_module for BpHook::BindDispatch.
# ---------------------------------------------------------------------------
sub bd {
    my ($p, %opts) = @_;
    return GuardHarness::run_module('BindDispatch', $p, env => ($opts{env} // {}), args => ($opts{args} // []));
}

# ===========================================================================
# AC-1: armed driver, 1 member, Agent payload with an empty prompt.
# ===========================================================================
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' });
    my $sid = 'ac1-sid';
    GuardHarness::fresh_state();
    ok(GuardHarness::arm($sid, 'driver'), 'AC-1 setup: session armed driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);

    my $res = bd(payload(tool_name => 'Agent', session_id => $sid, tool_use_id => 'T1', prompt => ''), env => \%env);
    is($res->{rc}, 0, 'AC-1: rc 0');
    is($res->{err}, '', 'AC-1: stderr empty');

    my $rec = read_json(bindings_dir($data) . '/T1.json');
    ok(ref $rec eq 'HASH', 'AC-1: bindings/T1.json decodes to a record');
    is(ref $rec eq 'HASH' ? $rec->{package} : undef, 'p1-a', 'AC-1: bound to the sole member');

    my @hist = history_lines($data);
    is(scalar(@hist), 1, 'AC-1: bindings.jsonl gains exactly one line');
    is_deeply(eval { $J->decode($hist[0]) }, $rec, 'AC-1: the history line is identical to the lookup record')
        if @hist == 1;
}

# ===========================================================================
# AC-2: 2 members A, B; a ledger path with backslashes, then forward
# slashes, both binding to B.
# ===========================================================================
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    my $sid = 'ac2-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);

    my $prompt_bs = 'C:\\x\\.ccpraxis-local-data\\blueprints\\bpx\\packages\\p2-b.md';
    my $res1 = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt_bs), env => \%env);
    is($res1->{rc}, 0, 'AC-2: rc 0 with a backslashed prompt');
    my $rec1 = read_json(bindings_dir($data) . '/T1.json');
    is(ref $rec1 eq 'HASH' ? $rec1->{package} : undef, 'p2-b', 'AC-2: bound to B (backslashes)');

    my $prompt_fs = 'x/.ccpraxis-local-data/blueprints/bpx/packages/p2-b.md';
    my $res2 = bd(payload(session_id => $sid, tool_use_id => 'T2', prompt => $prompt_fs), env => \%env);
    is($res2->{rc}, 0, 'AC-2: rc 0 with a forward-slash prompt');
    my $rec2 = read_json(bindings_dir($data) . '/T2.json');
    is(ref $rec2 eq 'HASH' ? $rec2->{package} : undef, 'p2-b', 'AC-2: bound to B (forward slashes)');
}

# ===========================================================================
# AC-3: 2 members; prompt names none: rc 2, exact denial text, nothing
# written.
# ===========================================================================
{
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'ac3-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => 'nothing named here'), env => \%env);
    is($res->{rc}, 2, 'AC-3: rc 2 naming none');
    is($res->{err}, expected_deny_text($data, @members), 'AC-3: exact denial text');
    is($res->{out}, '', 'AC-3: stdout empty');
    is(scalar(binding_files($data)), 0, 'AC-3: no lookup file written');
    is(scalar(history_lines($data)), 0, 'AC-3: no history line written');
}

# ===========================================================================
# AC-4: 2 members; prompt names both: rc 2, same text, nothing written.
# ===========================================================================
{
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'ac4-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

    my $prompt = join(' ', map { ledger_line($data, $_->{bp}, $_->{pkg}) } @members);
    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
    is($res->{rc}, 2, 'AC-4: rc 2 naming both');
    is($res->{err}, expected_deny_text($data, @members), 'AC-4: same denial text as AC-3');
    is(scalar(binding_files($data)), 0, 'AC-4: nothing written');
    is(scalar(history_lines($data)), 0, 'AC-4: no history line written');
}

# ===========================================================================
# AC-5: prompt names only a ledger not in the set: rc 2, lists the 2
# in-flight ledgers; prompt names one member plus a non-member: binds to it.
# ===========================================================================
{
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'ac5-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

    my $non_member = ledger_line($data, 'bpx', 'p3-c');
    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $non_member), env => \%env);
    is($res->{rc}, 2, 'AC-5: naming only a non-member ledger denies');
    is($res->{err}, expected_deny_text($data, @members), 'AC-5: text lists the 2 in-flight ledgers');

    my $prompt2 = $non_member . ' ' . ledger_line($data, 'bpx', 'p2-b');
    my $res2 = bd(payload(session_id => $sid, tool_use_id => 'T2', prompt => $prompt2), env => \%env);
    is($res2->{rc}, 0, 'AC-5: naming a member plus a non-member binds');
    my $rec = read_json(bindings_dir($data) . '/T2.json');
    is(ref $rec eq 'HASH' ? $rec->{package} : undef, 'p2-b', 'AC-5: bound to the member (p2-b)');
}

# ===========================================================================
# AC-6: 6 members, prompt names none: exactly 6 stderr lines (header + 4
# first members + "...and 2 more"); every line at most 160 characters.
# ===========================================================================
{
    my $data = fresh_data();
    my @members = map { { bp => 'bpx', pkg => "p$_-x" } } (1 .. 6);
    write_inflight($data, @members);
    my $sid = 'ac6-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => 'nothing named here'), env => \%env);
    is($res->{rc}, 2, 'AC-6: rc 2 naming none of 6');
    is($res->{err}, expected_deny_text($data, @members), 'AC-6: exact 6-line denial text (4 listed + and-2-more)');
    my @lines = split /\n/, $res->{err};
    is(scalar(@lines), 6, 'AC-6: exactly 6 lines');
    for my $l (@lines) {
        cmp_ok(length($l), '<=', 160, 'AC-6: line length <= 160');
    }
}

# ===========================================================================
# AC-7: boundary naming -- p1-a vs p11-a (no double count); a .mdx suffix
# names nothing; a trailing sentence period after .md still names.
# ===========================================================================
{
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p11-a' });
    write_inflight($data, @members);
    my $sid = 'ac7-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

    my $res1 = bd(payload(session_id => $sid, tool_use_id => 'T1',
        prompt => 'see blueprints/bpx/packages/p11-a.md for detail'), env => \%env);
    is($res1->{rc}, 0, 'AC-7: naming p11-a.md binds');
    my $rec1 = read_json(bindings_dir($data) . '/T1.json');
    is(ref $rec1 eq 'HASH' ? $rec1->{package} : undef, 'p11-a', 'AC-7: bound to p11-a, not p1-a (no double count)');

    my $res2 = bd(payload(session_id => $sid, tool_use_id => 'T2',
        prompt => 'see blueprints/bpx/packages/p1-a.mdx here'), env => \%env);
    is($res2->{rc}, 2, 'AC-7: a .mdx suffix names nothing -- deny');

    my $res3 = bd(payload(session_id => $sid, tool_use_id => 'T3',
        prompt => 'work on blueprints/bpx/packages/p1-a.md. thanks'), env => \%env);
    is($res3->{rc}, 0, 'AC-7: a trailing sentence period still names');
    my $rec3 = read_json(bindings_dir($data) . '/T3.json');
    is(ref $rec3 eq 'HASH' ? $rec3->{package} : undef, 'p1-a', 'AC-7: bound to p1-a with a trailing period');
}

# ===========================================================================
# AC-8: no denial outside an armed driver: (a) never armed, (b) manual,
# (c) reporter, (d) a different session armed driver while this session is
# unarmed; (e) [W] the same four through the real wrapper.
# ===========================================================================
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    my $prompt_none = 'nothing named here';

    GuardHarness::fresh_state();
    my $sidA = 'ac8-a';
    my $resA = bd(payload(session_id => $sidA, tool_use_id => 'TA', prompt => $prompt_none), env => { CCPRAXIS_DATA_DIR => $data });
    is($resA->{rc}, 0, 'AC-8(a): a never-armed session allows');
    is($resA->{err}, '', 'AC-8(a): stderr empty');

    GuardHarness::fresh_state();
    my $sidB = 'ac8-b';
    GuardHarness::arm($sidB, 'manual');
    my $resB = bd(payload(session_id => $sidB, tool_use_id => 'TB', prompt => $prompt_none), env => { CCPRAXIS_DATA_DIR => $data });
    is($resB->{rc}, 0, 'AC-8(b): a manual role allows');
    is($resB->{err}, '', 'AC-8(b): stderr empty');

    GuardHarness::fresh_state();
    my $sidC = 'ac8-c';
    GuardHarness::arm($sidC, 'reporter');
    my $resC = bd(payload(session_id => $sidC, tool_use_id => 'TC', prompt => $prompt_none), env => { CCPRAXIS_DATA_DIR => $data });
    is($resC->{rc}, 0, 'AC-8(c): a reporter role allows');
    is($resC->{err}, '', 'AC-8(c): stderr empty');

    GuardHarness::fresh_state();
    my $sidOther = 'ac8-other';
    GuardHarness::arm($sidOther, 'driver');
    my $sidD = 'ac8-d'; # never armed itself
    my $resD = bd(payload(session_id => $sidD, tool_use_id => 'TD', prompt => $prompt_none), env => { CCPRAXIS_DATA_DIR => $data });
    is($resD->{rc}, 0, 'AC-8(d): an unarmed session is unaffected by another armed driver session');
    is($resD->{err}, '', 'AC-8(d): stderr empty');

    is(scalar(binding_files($data)), 0, 'AC-8: nothing written across (a)-(d)');
    is(scalar(history_lines($data)), 0, 'AC-8: no history lines across (a)-(d)');
}
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    my $prompt_none = 'nothing named here';

    GuardHarness::fresh_state();
    my $sidA = 'ac8w-a';
    my $rA = GuardHarness::run_wrapper($WRAPPER, payload(session_id => $sidA, tool_use_id => 'TA', prompt => $prompt_none), env => { CCPRAXIS_DATA_DIR => $data });
    is($rA->{rc}, 0, 'AC-8(e,a) [W]: a never-armed session allows through the real wrapper');

    GuardHarness::fresh_state();
    my $sidB = 'ac8w-b';
    GuardHarness::arm($sidB, 'manual');
    my $rB = GuardHarness::run_wrapper($WRAPPER, payload(session_id => $sidB, tool_use_id => 'TB', prompt => $prompt_none), env => { CCPRAXIS_DATA_DIR => $data });
    is($rB->{rc}, 0, 'AC-8(e,b) [W]: a manual role allows through the real wrapper');

    GuardHarness::fresh_state();
    my $sidC = 'ac8w-c';
    GuardHarness::arm($sidC, 'reporter');
    my $rC = GuardHarness::run_wrapper($WRAPPER, payload(session_id => $sidC, tool_use_id => 'TC', prompt => $prompt_none), env => { CCPRAXIS_DATA_DIR => $data });
    is($rC->{rc}, 0, 'AC-8(e,c) [W]: a reporter role allows through the real wrapper');

    GuardHarness::fresh_state();
    my $sidOther = 'ac8w-other';
    GuardHarness::arm($sidOther, 'driver');
    my $sidD = 'ac8w-d';
    my $rD = GuardHarness::run_wrapper($WRAPPER, payload(session_id => $sidD, tool_use_id => 'TD', prompt => $prompt_none), env => { CCPRAXIS_DATA_DIR => $data });
    is($rD->{rc}, 0, 'AC-8(e,d) [W]: an unarmed session, another armed driver notwithstanding, allows through the real wrapper');
}

# ===========================================================================
# AC-9: ledger session (coordinator) always binds, never denies; an invalid
# BP_PACKAGE writes nothing.
# ===========================================================================
{
    my $t = tempdir(CLEANUP => 1);
    (my $proj = "$t/proj") =~ s{\\}{/}g;
    make_path("$proj/.ccpraxis-local-data");
    my $data = "$proj/.ccpraxis-local-data";
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });

    GuardHarness::fresh_state();
    my %env = (BP_LEDGER => "$proj/somepkg.md", BP_BLUEPRINT => 'bpx', BP_PACKAGE => 'p1-a', BP_PROJECT_ROOT => $proj);
    my $res = bd(payload(tool_use_id => 'T1', prompt => 'nothing named here'), env => \%env);
    is($res->{rc}, 0, 'AC-9: a ledger session binds without any denial, even naming none');
    my $rec = read_json(bindings_dir($data) . '/T1.json');
    is(ref $rec eq 'HASH' ? $rec->{blueprint} : undef, 'bpx', 'AC-9: bound blueprint bpx');
    is(ref $rec eq 'HASH' ? $rec->{package} : undef, 'p1-a', 'AC-9: bound package p1-a');

    my %env2 = (BP_LEDGER => "$proj/somepkg.md", BP_BLUEPRINT => 'bpx', BP_PACKAGE => '../x', BP_PROJECT_ROOT => $proj);
    my $res2 = bd(payload(tool_use_id => 'T2', prompt => 'nothing named here'), env => \%env2);
    is($res2->{rc}, 0, 'AC-9: rc 0 with an invalid BP_PACKAGE');
    ok(!-e (bindings_dir($data) . '/T2.json'), 'AC-9: nothing written with an invalid BP_PACKAGE');
}

# ===========================================================================
# AC-10: the record's field shapes.
# ===========================================================================
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' });
    my $sid = 'ac10-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);
    my $t0 = time();

    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', subagent_type => 'butler:bp-implementer'), env => \%env);
    is($res->{rc}, 0, 'AC-10: binds');
    my $rec = read_json(bindings_dir($data) . '/T1.json');
    ok(ref $rec eq 'HASH', 'AC-10: record decodes as a JSON object');
  SKIP: {
        skip 'AC-10: no record to inspect', 8 unless ref $rec eq 'HASH';
        is($rec->{tool_use_id}, 'T1', 'AC-10: tool_use_id');
        is($rec->{blueprint}, 'bpx', 'AC-10: blueprint');
        is($rec->{package}, 'p1-a', 'AC-10: package');
        is($rec->{session_id}, $sid, 'AC-10: session_id is the payload\'s');
        is($rec->{subagent_type}, 'butler:bp-implementer', 'AC-10: subagent_type');
        is($rec->{source}, 'bind-dispatch', 'AC-10: source is bind-dispatch');
        ok(defined $rec->{at} && $rec->{at} =~ /^\d+$/, 'AC-10: at is an integer');
        ok($rec->{at} >= $t0 - 2 && $rec->{at} <= time() + 5, 'AC-10: at is close to now');
    }

    my $res2 = bd(payload(session_id => $sid, tool_use_id => 'T2'), env => \%env);
    my $rec2 = read_json(bindings_dir($data) . '/T2.json');
    is(ref $rec2 eq 'HASH' ? $rec2->{subagent_type} : undef, '', 'AC-10: absent subagent_type -> empty string');

    my $res3 = bd(payload(session_id => $sid, tool_use_id => 'T3', subagent_type => 'a b'), env => \%env);
    my $rec3 = read_json(bindings_dir($data) . '/T3.json');
    is(ref $rec3 eq 'HASH' ? $rec3->{subagent_type} : undef, '', 'AC-10: ill-shaped subagent_type -> empty string');
}

# ===========================================================================
# AC-11 (batch C, spec 16-cutover C-2/C-3, reason DEL): 0 members allows and
# writes nothing. The current.json fallback is deleted -- a pre-existing
# current.json with no inflight.json now binds NOTHING (0 members, allowed),
# and a malformed inflight.json also gives 0 members rather than falling back
# to current.json. current.json itself is left byte-identical either way.
# ===========================================================================
{
    my $data = fresh_data();
    my $sid = 'ac11a-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);
    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1'), env => \%env);
    is($res->{rc}, 0, 'AC-11: 0 members allows');
    ok(!-e (bindings_dir($data) . '/T1.json'), 'AC-11: nothing written with 0 members');
}
{
    my $data = fresh_data();
    write_current($data, 'bpx', 'p1-a');
    my $current_before = read_json("$data/.drive-solo/current.json");
    my $sid = 'ac11b-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);
    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1'), env => \%env);
    is($res->{rc}, 0, 'AC-11 (DEL, C-3): no inflight.json, current.json present -> 0 members, allowed');
    ok(!-e (bindings_dir($data) . '/T1.json'), 'AC-11 (DEL, C-3): nothing written -- current.json no longer seeds a member');
    is_deeply(read_json("$data/.drive-solo/current.json"), $current_before,
        'AC-11 (DEL, C-3): current.json itself is left byte-identical');
}
{
    my $data = fresh_data();
    make_path("$data/.drive-solo");
    write_bytes("$data/.drive-solo/inflight.json", '{not json');
    write_current($data, 'bpx', 'p1-a');
    my $sid = 'ac11c-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);
    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1'), env => \%env);
    is($res->{rc}, 0, 'AC-11 (DEL, C-2): a malformed inflight.json gives 0 members (no current.json fallback), allowed');
    ok(!-e (bindings_dir($data) . '/T1.json'), 'AC-11 (DEL, C-2): nothing written');
}

# ===========================================================================
# AC-12: invalid or missing tool_use_id, with 1 member: allow, nothing
# written anywhere.
# ===========================================================================
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' });
    my $sid = 'ac12-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);

    my $res = bd(payload(session_id => $sid, tool_use_id => '../x'), env => \%env);
    is($res->{rc}, 0, 'AC-12: an invalid tool_use_id allows');
    is(scalar(binding_files($data)), 0, 'AC-12: no lookup file written for an invalid tool_use_id');
    is(scalar(history_lines($data)), 0, 'AC-12: no history line written either');

    my $res2 = bd(payload(session_id => $sid), env => \%env); # missing tool_use_id
    is($res2->{rc}, 0, 'AC-12: a missing tool_use_id allows');
    is(scalar(binding_files($data)), 0, 'AC-12: still nothing written');
    is(scalar(history_lines($data)), 0, 'AC-12: still no history line');
}

# ===========================================================================
# AC-13 (B9): a fork/subagent dispatch follows exactly the same rule as the
# main thread's -- no fork-specific message.
# ===========================================================================
{
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'ac13-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

    my $res1 = bd(payload(session_id => $sid, tool_use_id => 'T1', agent_id => 'a1', subagent_type => 'fork',
        prompt => ledger_line($data, 'bpx', 'p2-b')), env => \%env);
    is($res1->{rc}, 0, 'AC-13: a fork dispatch naming one member binds');
    my $rec1 = read_json(bindings_dir($data) . '/T1.json');
    is(ref $rec1 eq 'HASH' ? $rec1->{package} : undef, 'p2-b', 'AC-13: bound to p2-b');

    my $res2 = bd(payload(session_id => $sid, tool_use_id => 'T2', agent_id => 'a2', subagent_type => 'fork',
        prompt => 'nothing named here'), env => \%env);
    is($res2->{rc}, 2, 'AC-13: the same fork dispatch naming none denies');
    is($res2->{err}, expected_deny_text($data, @members), 'AC-13: the deny text is the plain AC-3 text, not a fork message');
}

# ===========================================================================
# AC-14 (B10): fail-open -- a malformed payload never denies; tool_name
# Bash never denies.
# ===========================================================================
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    my $sid = 'ac14-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);

    my $res1 = bd('not json at all', env => \%env);
    is($res1->{rc}, 0, 'AC-14: a malformed JSON payload allows');
    is($res1->{out} . $res1->{err}, '', 'AC-14: a malformed JSON payload prints nothing');

    my $res2 = bd('{"tool_name":"Task","tool_i', env => \%env);
    is($res2->{rc}, 0, 'AC-14: a truncated JSON payload allows');
    is($res2->{out} . $res2->{err}, '', 'AC-14: a truncated JSON payload prints nothing');

    my $res3 = bd(payload(session_id => $sid, tool_use_id => 'T3', tool_name => 'Bash'), env => \%env);
    is($res3->{rc}, 0, 'AC-14: tool_name Bash allows');
    ok(!-e (bindings_dir($data) . '/T3.json'), 'AC-14: nothing written for a Bash dispatch');
}

# ===========================================================================
# AC-15: roll (8388609-byte bindings.jsonl rolls to .1) and lookup-file GC
# (8 days old removed, 6 days old kept).
# ===========================================================================
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' });
    make_path("$data/.drive-solo");
    my $pre_bytes = ('x' x 8388608) . "\n"; # 8388609 bytes total
    write_bytes(bindings_history($data), $pre_bytes);
    is(-s bindings_history($data), 8388609, 'AC-15 setup: bindings.jsonl pre-sized at 8388609 bytes');

    make_path(bindings_dir($data));
    my $old_lookup = bindings_dir($data) . '/old-8d.json';
    write_bytes($old_lookup, "{}\n");
    utime(time() - 8 * 86400, time() - 8 * 86400, $old_lookup);
    my $recent_lookup = bindings_dir($data) . '/old-6d.json';
    write_bytes($recent_lookup, "{}\n");
    utime(time() - 6 * 86400, time() - 6 * 86400, $recent_lookup);

    my $sid = 'ac15-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);
    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1'), env => \%env);
    is($res->{rc}, 0, 'AC-15: bind after the pre-sized history rolls it');

    is(-s bindings_history1($data), 8388609, 'AC-15: bindings.jsonl.1 holds the pre-sized bytes');
    my @new_lines = history_lines($data);
    is(scalar(@new_lines), 1, 'AC-15: the new bindings.jsonl holds exactly one line');

    ok(!-e $old_lookup, 'AC-15: an 8-day-old lookup file is gone after the bind');
    ok(-e $recent_lookup, 'AC-15: a 6-day-old lookup file remains');
}

# ===========================================================================
# AC-16 [W] (Decision 33 process budget).
# ===========================================================================
{
    GuardHarness::fresh_state();
    my $sidA = 'ac16-a';
    my $rA = GuardHarness::run_shim($WRAPPER,
        payload(session_id => $sidA, tool_use_id => 'TA', subagent_type => 'butler:bp-implementer', prompt => 'p'),
        env => {});
    is($rA->{rc}, 0, 'AC-16(a): a not-applies session allows');
    is(GuardHarness::count_lines($rA->{shim_log}, 'perl'), 0, 'AC-16(a): 0 perl launches');
    is(GuardHarness::count_lines($rA->{shim_log}, 'jq'), 0, 'AC-16(a): 0 jq launches');
}
{
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'ac16-b';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);
    my $rB = GuardHarness::run_shim($WRAPPER,
        payload(session_id => $sid, tool_use_id => 'TB', prompt => ledger_line($data, 'bpx', 'p2-b')),
        env => \%env);
    is($rB->{rc}, 0, 'AC-16(b): an applying armed-driver dispatch allows');
    cmp_ok(GuardHarness::count_lines($rB->{shim_log}, 'perl'), '<=', 1, 'AC-16(b): at most 1 perl launch');
    is(GuardHarness::count_lines($rB->{shim_log}, 'jq'), 0, 'AC-16(b): 0 jq launches');
    ok(-f (bindings_dir($data) . '/TB.json'), 'AC-16(b): the binding exists');

    my $data2 = fresh_data();
    write_inflight($data2, @members);
    my $sid2 = 'ac16-c';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid2, 'driver');
    my $rC = bd(payload(session_id => $sid2, tool_use_id => 'TC', prompt => ledger_line($data2, 'bpx', 'p2-b')),
        env => { CCPRAXIS_DATA_DIR => $data2 });
    is($rC->{parse_delta}, 0, 'AC-16(c): the payload is parsed exactly once (parse_delta == 0)');
}

# ===========================================================================
# AC-17 [W]: wrapper -- empty payload rc 0; the AC-3 denial case, identical
# text, through the real wrapper.
# ===========================================================================
{
    GuardHarness::fresh_state();
    my $r_empty = GuardHarness::run_wrapper($WRAPPER, '', env => {});
    is($r_empty->{rc}, 0, 'AC-17: an empty payload through the wrapper exits 0');
}
{
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'ac17-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');
    my $r = GuardHarness::run_wrapper($WRAPPER, payload(session_id => $sid, tool_use_id => 'T1', prompt => 'nothing named here'), env => \%env);
    is($r->{rc}, 2, 'AC-17: the denial case, end to end through the real wrapper');
    is($r->{err}, expected_deny_text($data, @members), 'AC-17: the wrapper stderr matches the in-process AC-3 text');
}

# ===========================================================================
# AC-18: registration. Package 12 built bind-dispatch.sh additive-only, not
# registered anywhere (Decision 19) -- but package 16's cutover is exactly
# what wires it in, so the pre-cutover "not registered anywhere" premise is
# retired here (Decision 34, SW: the switch from unregistered to registered
# is what this package does). hooks.json now registers it on PreToolUse
# Task|Agent (spec 16 sec 2.3); settings.json never has and still does not.
# ===========================================================================
{
    my $hooks_json = "$BUTLER_DIR/hooks/hooks.json";
    my $settings_json = "$BUTLER_DIR/../../.claude/settings.json";
    ok(-f $hooks_json, 'AC-18 precondition: hooks.json exists');
    ok(-f $settings_json, 'AC-18 precondition: .claude/settings.json exists');
    like(read_bytes($hooks_json) // '', qr/bind-dispatch/,
        'AC-18: hooks.json registers bind-dispatch.sh now that package 16 has cut over');
    unlike(read_bytes($settings_json) // '', qr/bind-dispatch/, 'AC-18: .claude/settings.json does not mention bind-dispatch');
}

# ===========================================================================
# AC-19: bound_since($data, $bp, $pkg, $since), a pure reader for the
# director.
# ===========================================================================
{
    my $data = fresh_data();
    make_path("$data/.drive-solo");
    my $require_ok = eval { require BpHook::BindDispatch; 1 };
    ok($require_ok, 'AC-19 precondition: BpHook::BindDispatch can be required')
        or diag("require failed: $@ (package 12 has not written BindDispatch.pm yet)");
  SKIP: {
        skip 'AC-19: BpHook::BindDispatch not available yet', 6 unless $require_ok;

        is(BpHook::BindDispatch::bound_since($data, 'bpx', 'p1-a', 1000), 0, 'AC-19: no files -> 0');

        write_bytes(bindings_history($data),
            $J->encode({ tool_use_id => 'T1', blueprint => 'bpx', package => 'p1-a', source => 'bind-dispatch', at => 1000 }) . "\n");
        is(BpHook::BindDispatch::bound_since($data, 'bpx', 'p1-a', 1000), 1, 'AC-19: a line with at == since -> 1');

        write_bytes(bindings_history($data),
            $J->encode({ tool_use_id => 'T2', blueprint => 'bpx', package => 'p1-a', source => 'bind-dispatch', at => 999 }) . "\n");
        is(BpHook::BindDispatch::bound_since($data, 'bpx', 'p1-a', 1000), 0, 'AC-19: at == since-1 -> 0');

        write_bytes(bindings_history($data),
            $J->encode({ tool_use_id => 'T3', blueprint => 'bpx', package => 'other', source => 'bind-dispatch', at => 1000 }) . "\n");
        is(BpHook::BindDispatch::bound_since($data, 'bpx', 'p1-a', 1000), 0, 'AC-19: a line for another package -> 0');

        unlink bindings_history($data);
        write_bytes(bindings_history1($data),
            $J->encode({ tool_use_id => 'T4', blueprint => 'bpx', package => 'p1-a', source => 'bind-dispatch', at => 1000 }) . "\n");
        is(BpHook::BindDispatch::bound_since($data, 'bpx', 'p1-a', 1000), 1, 'AC-19: a match only in bindings.jsonl.1 -> 1');

        unlink bindings_history1($data);   # the previous step's genuine match must not answer this one
        my $long_line = $J->encode({ tool_use_id => 'T5', blueprint => 'bpx', package => 'p1-a', source => 'bind-dispatch', at => 1000, pad => ('x' x 5000) }) . "\n";
        write_bytes(bindings_history($data), "not json at all\n" . $long_line);
        is(BpHook::BindDispatch::bound_since($data, 'bpx', 'p1-a', 1000), 0, 'AC-19: bad-JSON and over-4096-byte lines are ignored');
    }
}

# ===========================================================================
# AC-20: director reclaim (bp-drive-next.pl), hermetic per drive-next-
# inflight-set.t's own idiom (BpDrive::run with injected now/opts,
# BUTLER_CONCURRENCY=1).
# ===========================================================================
my $NOW20 = 1_830_297_600; # fixed epoch, 2028-01-01T00:00:00Z

sub ac20_write_pkg_ledger {
    my ($bp_dir, $bp_name, $key, $status, $write_set) = @_;
    write_bytes("$bp_dir/packages/$key.md",
        "---\npackage: $key\nblueprint: $bp_name\nstatus: $status\n"
      . "model: sonnet\nmax_turns: 80\nwrite_set: $write_set\n"
      . "test_paths: $write_set\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# $key\n");
}
sub ac20_make_bp_dir {
    my ($data, $name, $pkgs) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");
    my $md = "# $name\n\n## Package status\n\n"
           . "| pkg | deliverable | depends_on | model | status |\n"
           . "|-----|-------------|------------|-------|--------|\n";
    for my $p (@$pkgs) { $md .= "| $p->{key} | thing | - | sonnet | $p->{status} |\n"; }
    write_bytes("$bp/blueprint.md", $md);
    for my $p (@$pkgs) { ac20_write_pkg_ledger($bp, $name, $p->{key}, $p->{status}, $p->{write_set}); }
    return $bp;
}
sub ac20_ledger_prefix {
    my ($data, $bp, $pkg) = @_;
    my $b = $data;
    $b =~ s{[\\/]+$}{};
    my $L = basename($b);
    return "$L/blueprints/$bp/packages/$pkg.md";
}
sub ac20_run_director {
    my ($argv, $opts) = @_;
    $opts //= {};
    $opts->{now}                  //= sub { $NOW20 };
    $opts->{verdict}              //= sub { { action => 'ok' } };
    $opts->{spawn}                //= sub { };
    $opts->{kill_pid}             //= sub { };
    $opts->{powershell_available} //= sub { 0 };
    return BpDrive::run($argv, $opts);
}
sub ac20_capture_run {
    my ($argv, $opts) = @_;
    my (undef, $opath) = tempfile();
    my (undef, $epath) = tempfile();
    open(my $oldout, '>&STDOUT') or die "dup STDOUT: $!";
    open(my $olderr, '>&STDERR') or die "dup STDERR: $!";
    open(STDOUT, '>:raw', $opath) or die "reopen STDOUT: $!";
    open(STDERR, '>:raw', $epath) or die "reopen STDERR: $!";
    $| = 1;
    my $rc = eval { ac20_run_director($argv, $opts) };
    my $err = $@;
    open(STDOUT, '>&', $oldout) or die "restore STDOUT: $!";
    open(STDERR, '>&', $olderr) or die "restore STDERR: $!";
    close $oldout;
    close $olderr;
    my $out  = read_bytes($opath) // '';
    my $eout = read_bytes($epath) // '';
    unlink $opath, $epath;
    die $err if $err;
    return ($rc, $out, $eout);
}
sub ac20_run_next {
    my ($data, $argv, $opts) = @_;
    local $ENV{CCPRAXIS_DATA_DIR} = $data;
    return ac20_capture_run($argv, $opts);
}
sub ac20_decode_line {
    my ($out) = @_;
    (my $line = $out) =~ s/\n\z//;
    return eval { $J->decode($line) };
}

{
    my $DRIVE_SCRIPT = "$BUTLER_DIR/scripts/bp-drive-next.pl";
    my $require_ok = eval { require $DRIVE_SCRIPT; 1 };
    ok($require_ok, 'AC-20 precondition: bp-drive-next.pl can be required')
        or diag("require failed: $@");

  SKIP: {
        skip 'AC-20: bp-drive-next.pl not requirable', 1 unless $require_ok;

        # ── case 1: pending, since = now-1800, no binding -> reclaimed ──────
        {
            my $data = tempdir(CLEANUP => 1);
            ac20_make_bp_dir($data, 'bpx', [{ key => 'p1-a', status => 'pending', write_set => 'a/' }]);
            my $dsdir = "$data/.drive-solo";
            make_path($dsdir);
            write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW20 });
            write_json("$dsdir/inflight.json", { packages => [
                { blueprint => 'bpx', package => 'p1-a', ledger => ac20_ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW20 - 1800 },
            ], updated_at => $NOW20 - 1800 });

            local $ENV{BUTLER_CONCURRENCY} = '1';
            my ($rc, $out) = ac20_run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW20 } });
            is($rc, 0, 'AC-20(reclaim): exits 0');
            my $act = ac20_decode_line($out);
            is(ref $act eq 'HASH' ? $act->{action} : undef, 'run-package', 'AC-20(reclaim): action is run-package');
            is(ref $act eq 'HASH' ? $act->{package} : undef, 'p1-a', 'AC-20(reclaim): the reclaimed package is handed out');

            my $run_md = read_bytes("$dsdir/run.md") // '';
            like($run_md, qr/RECLAIM bpx\/p1-a/, 'AC-20(reclaim): run.md gains the RECLAIM line');

            my $set = read_json("$dsdir/inflight.json");
            my ($e) = (ref $set eq 'HASH' && ref $set->{packages} eq 'ARRAY')
                ? (grep { $_->{package} eq 'p1-a' } @{ $set->{packages} }) : ();
            ok(defined $e, 'AC-20(reclaim): the entry stays in the set');
          SKIP: {
                skip 'AC-20(reclaim): no entry to check since on', 1 unless defined $e;
                is($e->{since}, $NOW20, 'AC-20(reclaim): since is reset to now');
            }
        }

        # ── case 2: since = now-1799 -> not reclaimed ───────────────────────
        {
            my $data = tempdir(CLEANUP => 1);
            ac20_make_bp_dir($data, 'bpx', [{ key => 'p1-a', status => 'pending', write_set => 'a/' }]);
            my $dsdir = "$data/.drive-solo";
            make_path($dsdir);
            write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW20 });
            write_json("$dsdir/inflight.json", { packages => [
                { blueprint => 'bpx', package => 'p1-a', ledger => ac20_ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW20 - 1799 },
            ], updated_at => $NOW20 - 1799 });

            local $ENV{BUTLER_CONCURRENCY} = '1';
            my ($rc, $out) = ac20_run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW20 } });
            is($rc, 0, 'AC-20(too-recent): exits 0');
            my $act = ac20_decode_line($out);
            my $act_key = (ref $act eq 'HASH' ? ($act->{action} // '') . '/' . ($act->{package} // '') : '');
            isnt($act_key, 'run-package/p1-a', 'AC-20(too-recent): p1-a is not reclaimed 1s short of the 1800s threshold');
        }

        # ── case 3: a binding at >= since -> not reclaimed ──────────────────
        {
            my $data = tempdir(CLEANUP => 1);
            ac20_make_bp_dir($data, 'bpx', [{ key => 'p1-a', status => 'pending', write_set => 'a/' }]);
            my $dsdir = "$data/.drive-solo";
            make_path($dsdir);
            my $since = $NOW20 - 1800;
            write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW20 });
            write_json("$dsdir/inflight.json", { packages => [
                { blueprint => 'bpx', package => 'p1-a', ledger => ac20_ledger_prefix($data, 'bpx', 'p1-a'), since => $since },
            ], updated_at => $since });
            write_bytes("$dsdir/bindings.jsonl",
                $J->encode({ tool_use_id => 'Tbound', blueprint => 'bpx', package => 'p1-a', source => 'bind-dispatch', at => $since }) . "\n");

            local $ENV{BUTLER_CONCURRENCY} = '1';
            my ($rc, $out) = ac20_run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW20 } });
            is($rc, 0, 'AC-20(bound): exits 0');
            my $act = ac20_decode_line($out);
            my $act_key = (ref $act eq 'HASH' ? ($act->{action} // '') . '/' . ($act->{package} // '') : '');
            isnt($act_key, 'run-package/p1-a', 'AC-20(bound): a bound-since dispatch prevents reclaim');
        }

        # ── case 4: ledger running -> not reclaimed ─────────────────────────
        {
            my $data = tempdir(CLEANUP => 1);
            ac20_make_bp_dir($data, 'bpx', [{ key => 'p1-a', status => 'running', write_set => 'a/' }]);
            my $dsdir = "$data/.drive-solo";
            make_path($dsdir);
            write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW20 });
            write_json("$dsdir/inflight.json", { packages => [
                { blueprint => 'bpx', package => 'p1-a', ledger => ac20_ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW20 - 1800 },
            ], updated_at => $NOW20 - 1800 });

            local $ENV{BUTLER_CONCURRENCY} = '1';
            my ($rc, $out) = ac20_run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW20 } });
            is($rc, 0, 'AC-20(running): exits 0');
            my $act = ac20_decode_line($out);
            my $act_key = (ref $act eq 'HASH' ? ($act->{action} // '') . '/' . ($act->{package} // '') : '');
            isnt($act_key, 'run-package/p1-a', 'AC-20(running): a running ledger is never reclaimed');
        }

        # ── case 5 (batch C, spec 16-cutover, reason SW): the reclaim rule
        # fires regardless of BUTLER_CONCURRENCY's value -- there is no more
        # "switch off" state in which it is suppressed.
        {
            my $data = tempdir(CLEANUP => 1);
            ac20_make_bp_dir($data, 'bpx', [{ key => 'p1-a', status => 'pending', write_set => 'a/' }]);
            my $dsdir = "$data/.drive-solo";
            make_path($dsdir);
            write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW20 });
            write_json("$dsdir/inflight.json", { packages => [
                { blueprint => 'bpx', package => 'p1-a', ledger => ac20_ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW20 - 1800 },
            ], updated_at => $NOW20 - 1800 });

            local $ENV{BUTLER_CONCURRENCY};
            delete $ENV{BUTLER_CONCURRENCY};
            my ($rc, $out) = ac20_run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW20 } });
            is($rc, 0, 'SW: exits 0');
            my $act = $J->decode($out);
            is($act->{action}, 'run-package', 'SW: reclaim still hands out p1-a with BUTLER_CONCURRENCY unset');
            is($act->{package}, 'p1-a', 'SW: p1-a is the reclaimed package');
            my $run_md = read_bytes("$dsdir/run.md") // '';
            like($run_md, qr/RECLAIM bpx\/p1-a/, 'SW: the RECLAIM line IS written -- the rule is unconditional now');
        }
    }
}

# ===========================================================================
# FIX-ROUND REGRESSIONS (12-dispatch-binding, review + red-team round).
# Everything below is labelled R9-<id> per the ledger's fix-round scope.
# Written against specs/12-dispatch-binding-spec.md, blueprint Decision 67,
# reports/12-dispatch-binding/review.md and redteam.md -- NOT against the
# implementation (except where a fix's own text names a concrete mechanism,
# e.g. redteam.md M2's suggested bindings/.gc-stamp path, cited inline).
# ===========================================================================

sub dispatch_snapshot {
    my ($dir) = @_;
    my %s;
    File::Find::find({ no_chdir => 1, wanted => sub { my @st = stat($_); $s{$_} = "$st[7]:$st[9]" if @st } }, $dir)
        if -d $dir;
    return \%s;
}

sub ledger_decl {
    my ($data, $bp, $pkg) = @_;
    return 'Ledger: ' . ledger_line($data, $bp, $pkg);
}

# ===========================================================================
# R9-D67 (blueprint Decision 67): the one-ledger rule reads ONLY an explicit
# labelled "Ledger: <path>" line, never a bare prose mention. Not implemented
# yet -- every assertion below is expected RED until the fix lands.
# ===========================================================================
{
    # A prose mention of a dependency's ledger, alongside a labelled Ledger:
    # line for the REAL in-flight package: binds to the Ledger: line, never
    # the prose mention (redteam M1's reproduction, proven the other way).
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'r9d67a-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);

    my $prompt = "Implement package p2-b. It builds on the output recorded in "
               . ledger_line($data, 'bpx', 'p1-a') . ".\n"
               . ledger_decl($data, 'bpx', 'p2-b') . "\n";
    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
    is($res->{rc}, 0, 'R9-D67: a labelled Ledger: line binds even with a dependency mentioned in prose');
    my $rec = read_json(bindings_dir($data) . '/T1.json');
    is(ref $rec eq 'HASH' ? $rec->{package} : undef, 'p2-b',
        "R9-D67: bound to the Ledger: line's package, not the prose-mentioned dependency");
}
{
    # A bare prose mention, with NO Ledger: line at all, never binds: deny.
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'r9d67b-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

    my $prompt = 'see ' . ledger_line($data, 'bpx', 'p2-b') . ' for context, no ledger line here';
    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt), env => \%env);
    is($res->{rc}, 2, 'R9-D67: a bare prose mention (no Ledger: line) never binds -- denied');
}
{
    # Zero Ledger: lines with 2 in flight: denied with the "none" text.
    # Two Ledger: lines: denied with a DISTINCT "too many" text.
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'r9d67c-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => 'nothing named here, no Ledger: line'), env => \%env);
    is($res->{rc}, 2, 'R9-D67: zero Ledger: lines denies');
    like($res->{err}, qr/\bnone\b/i, 'R9-D67: the zero-lines denial uses the "none" text');
    my $none_text = $res->{err};

    my $prompt2 = ledger_decl($data, 'bpx', 'p1-a') . "\n" . ledger_decl($data, 'bpx', 'p2-b') . "\n";
    my $res2 = bd(payload(session_id => $sid, tool_use_id => 'T2', prompt => $prompt2), env => \%env);
    is($res2->{rc}, 2, 'R9-D67: two Ledger: lines denies');
    like($res2->{err}, qr/too many/i, 'R9-D67: the two-lines denial uses the "too many" text');
    isnt($res2->{err}, $none_text, 'R9-D67: the none-text and the too-many-text are distinct messages');
}
{
    # .md.lock and .md~ never count as ledgers, even inside a Ledger: line.
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'r9d67d-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');

    my $prompt_lock = 'Ledger: ' . ledger_line($data, 'bpx', 'p2-b') . '.lock';
    my $res1 = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => $prompt_lock), env => \%env);
    is($res1->{rc}, 2, 'R9-D67: a "Ledger: ....md.lock" line names nothing -- denied (zero valid lines)');

    my $prompt_tilde = 'Ledger: ' . ledger_line($data, 'bpx', 'p2-b') . '~';
    my $res2 = bd(payload(session_id => $sid, tool_use_id => 'T2', prompt => $prompt_tilde), env => \%env);
    is($res2->{rc}, 2, 'R9-D67: a "Ledger: ....md~" line names nothing -- denied (zero valid lines)');
}

# ===========================================================================
# R9-RM1/TM3 (review M1 / redteam M3): bound_since over a large history
# returns quickly. CHOICE: a generous timing bound (2s, the reviewer's own
# suggested figure), not a decode-count seam -- the spec exposes no such
# counter and none exists in the module today, so a seam would itself be new
# API surface. ~20k independently-valid, non-matching lines are generated
# hermetically in this tempdir; the bound is generous enough to be stable
# across hosts while still failing today, where every line is decoded fresh.
# ===========================================================================
{
    my $require_ok = eval { require BpHook::BindDispatch; 1 };
    ok($require_ok, 'R9-RM1/TM3 precondition: BpHook::BindDispatch can be required')
        or diag("require failed: $@");
  SKIP: {
        skip 'R9-RM1/TM3: BpHook::BindDispatch not available yet', 2 unless $require_ok;
        my $data = fresh_data();
        make_path("$data/.drive-solo");
        my @lines;
        for my $i (0 .. 19_999) {
            push @lines, $J->encode({
                tool_use_id => "Tx$i", blueprint => 'bpx', package => "other-$i",
                source => 'bind-dispatch', at => 500,
            });
        }
        write_bytes(bindings_history1($data), join("\n", @lines) . "\n");

        my $t0 = Time::HiRes::time();
        my $hit = BpHook::BindDispatch::bound_since($data, 'bpx', 'p1-a', 500);
        my $elapsed = Time::HiRes::time() - $t0;
        is($hit, 0, 'R9-RM1/TM3: no matching line among ~20k non-matching lines -> 0');
        cmp_ok($elapsed, '<', 2.0, 'R9-RM1/TM3: bound_since over ~20k lines returns in well under 2s');
    }
}

# ===========================================================================
# R9-TM2 (redteam M2): GC runs at most once per window (a stamp file), and
# also removes .tmp.<pid> leftovers past an age. ASSUMPTION (from redteam.md
# M2's own fix text, the only concrete name on offer): the stamp lives at
# bindings/.gc-stamp.
# ===========================================================================
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' });
    my $sid = 'r9tm2-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);
    my $bdir = bindings_dir($data);

    my $res1 = bd(payload(session_id => $sid, tool_use_id => 'T1'), env => \%env);
    is($res1->{rc}, 0, 'R9-TM2 setup: T1 binds (the very first bind for this data dir)');

    # A stale lookup file created AFTER T1's bind, inside the rate-limit
    # window: a bind right away must NOT collect it (GC throttled).
    my $stale_in_window = "$bdir/stale-in-window.json";
    write_bytes($stale_in_window, "{}\n");
    utime(time() - 8 * 86400, time() - 8 * 86400, $stale_in_window);

    my $res2 = bd(payload(session_id => $sid, tool_use_id => 'T2'), env => \%env);
    is($res2->{rc}, 0, 'R9-TM2: T2 binds');
    ok(-e $stale_in_window,
        'R9-TM2: a stale file created inside the GC window is NOT collected on the very next bind (rate-limited)');

    # Force the window to have elapsed (backdate the stamp past 1h). Leave a
    # crash leftover .tmp.<pid> file past the cleanup age too: the next bind
    # must run GC and clean up both.
    my $stamp = "$bdir/.gc-stamp";
    write_bytes($stamp, '') unless -e $stamp;
    utime(time() - 3700, time() - 3700, $stamp);
    my $tmp_leftover = "$bdir/toolu-crashed.json.tmp.999999";
    write_bytes($tmp_leftover, "{}\n");
    utime(time() - 8 * 86400, time() - 8 * 86400, $tmp_leftover);

    my $res3 = bd(payload(session_id => $sid, tool_use_id => 'T3'), env => \%env);
    is($res3->{rc}, 0, 'R9-TM2: T3 binds');
    ok(!-e $tmp_leftover, 'R9-TM2: a stale .tmp.<pid> crash leftover is collected once the window has elapsed');
    ok(!-e $stale_in_window, 'R9-TM2: the earlier stale file is collected too, once GC actually runs');
    ok(-e $stamp && (stat($stamp))[9] >= time() - 5, 'R9-TM2: the stamp is touched (mtime updated) when GC runs');
}

# ===========================================================================
# R9-LOW: three independent low-severity fixes from the red-team round.
# ===========================================================================

# (a) batch C (spec 16-cutover C-3, reason SW): the kill switch is gone --
# a naming-none dispatch with 2+ members is ALWAYS denied now, with
# BUTLER_CONCURRENCY unset, "0" or any other value making no difference
# (nothing in non-test code reads it any more).
for my $conc (undef, '0', '1') {
    my $data = fresh_data();
    my @members = ({ bp => 'bpx', pkg => 'p1-a' }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'r9low-switch-sid-' . (defined $conc ? $conc : 'unset');
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);
    $env{BUTLER_CONCURRENCY} = $conc if defined $conc;

    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => 'nothing named here'), env => \%env);
    is($res->{rc}, 2,
        'SW (C-3): a naming-none dispatch with 2+ members is denied regardless of BUTLER_CONCURRENCY ('
      . (defined $conc ? $conc : 'unset') . ')');
    ok(!-e (bindings_dir($data) . '/T1.json'), 'SW (C-3): nothing bound on the deny');
}

# (b) hook and director agree on the data dir.
{
    my $t = tempdir(CLEANUP => 1);
    (my $proj = "$t/proj") =~ s{\\}{/}g;
    my $data = "$proj/.ccpraxis-local-data";
    make_path($data);
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' });
    my $sid = 'r9low-datadir-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (BP_PROJECT_ROOT => $proj);   # deliberately no CCPRAXIS_DATA_DIR/CLAUDE_PROJECT_DIR

    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1'), env => \%env);
    is($res->{rc}, 0, 'R9-LOW(data-dir): rc 0 with only BP_PROJECT_ROOT set');
    ok(-f (bindings_dir($data) . '/T1.json'),
        'R9-LOW(data-dir): the driver-path hook resolves the SAME data dir as the director via BP_PROJECT_ROOT');
}

# (c) a roll under concurrent binds loses no binding, and the history stays
# bounded at two generations (.1 plus current) by design -- it does NOT
# retain every generation ever rolled. DRIVER RULING (fix-batch): a forced
# tiny threshold that demands unbounded retention is rejected; the threshold
# here is instead computed from the exact line count and size so that AT
# MOST ONE roll happens during the concurrent phase, and a second, separate
# phase then proves the bound: after a second roll, .1 holds only the
# generation that was current immediately before it -- not an accumulation
# of the first roll's content too.
{
    my $data = fresh_data();
    my $dsdir = "$data/.drive-solo";
    make_path($dsdir);
    my $require_ok = eval { require BpHook::BindDispatch; 1 };
    ok($require_ok, 'R9-LOW(roll) precondition: BpHook::BindDispatch can be required')
        or diag("require failed: $@");
  SKIP: {
        skip 'R9-LOW(roll): BpHook::BindDispatch not available yet', 3 unless $require_ok;
        my ($NPROC, $NPER) = (12, 300);

        # Exact total bytes the concurrent phase will append, computed from
        # the deterministic (c,i) id lengths (the only variable part of the
        # line -- "at" is a fixed-digit-count epoch for the run's duration).
        # threshold = exact_total/2 guarantees: (a) at least one roll (the
        # threshold is strictly less than the total appended), and (b) at
        # most one roll (whatever remains after the crossing line is <=
        # threshold, since remaining = total - S1 <= total - threshold =
        # threshold when S1 > threshold).
        my $sample_at = time();
        my $exact_total = 0;
        for my $c (1 .. $NPROC) {
            for my $i (1 .. $NPER) {
                $exact_total += length($J->encode({
                    tool_use_id => "T${c}_$i", blueprint => 'bpx', package => 'p1-a',
                    source => 'bind-dispatch', at => $sample_at,
                }) . "\n");
            }
        }
        my $roll_bytes = int($exact_total / 2);
        local $BpHook::BindDispatch::HISTORY_ROLL_BYTES = $roll_bytes;

        my @pids;
        for my $c (1 .. $NPROC) {
            my $pid = fork();
            die "fork failed: $!" unless defined $pid;
            if ($pid == 0) {
                for my $i (1 .. $NPER) {
                    my $line = $J->encode({
                        tool_use_id => "T${c}_$i", blueprint => 'bpx', package => 'p1-a',
                        source => 'bind-dispatch', at => time(),
                    }) . "\n";
                    BpHook::BindDispatch::_append_history($dsdir, $line);
                }
                POSIX::_exit(0);
            }
            push @pids, $pid;
        }
        waitpid($_, 0) for @pids;

        my $cur_path = "$dsdir/bindings.jsonl";
        my $one_path = "$dsdir/bindings.jsonl.1";

        my %count;
        for my $f ($cur_path, $one_path) {
            my $raw = read_bytes($f);
            next unless defined $raw;
            for my $l (grep { length } split /\n/, $raw) {
                my $rec = eval { $J->decode($l) };
                $count{ $rec->{tool_use_id} }++ if ref $rec eq 'HASH' && defined $rec->{tool_use_id};
            }
        }
        is(scalar(keys %count), $NPROC * $NPER,
            'R9-LOW(roll): every one of the ' . ($NPROC * $NPER) . ' concurrently appended lines is present in .1 plus current');
        ok(!(grep { $count{$_} != 1 } keys %count),
            'R9-LOW(roll): every one of those lines appears exactly once -- none duplicated across .1 and current');

        # ---------------------------------------------------------------
        # Second phase (sequential -- no concurrency needed to prove the
        # bound): grow "current" past the threshold again, capture its
        # content right before the crossing append, then force the crossing
        # append and check .1 now holds EXACTLY that captured content --
        # not the earlier .1 generation too.
        # ---------------------------------------------------------------
        while (-s $cur_path <= $roll_bytes) {
            BpHook::BindDispatch::_append_history($dsdir, $J->encode({
                tool_use_id => 'filler', blueprint => 'bpx', package => 'p1-a',
                source => 'bind-dispatch', at => time(), pad => ('x' x 200),
            }) . "\n");
        }
        my $gen_before_2nd_roll = read_bytes($cur_path);
        BpHook::BindDispatch::_append_history($dsdir, $J->encode({
            tool_use_id => 'TRIGGER2', blueprint => 'bpx', package => 'p1-a',
            source => 'bind-dispatch', at => time(),
        }) . "\n");
        is(read_bytes($one_path), $gen_before_2nd_roll,
            'R9-LOW(roll): after a second roll, .1 holds only the generation that was just current -- bounded, not accumulated');
    }
}

# ===========================================================================
# R9-m2 (review MINOR gap): AC-20's reclaim precedence, sort order and
# blueprint scope, none of which the original oracle pinned.
# ===========================================================================
{
    my $require_ok = eval { require "$BUTLER_DIR/scripts/bp-drive-next.pl"; 1 };
    ok($require_ok, 'R9-m2 precondition: bp-drive-next.pl can be required')
        or diag("require failed: $@");
  SKIP: {
        skip 'R9-m2: bp-drive-next.pl not requirable', 1 unless $require_ok;

        # sort order + reclaim beats a ready package.
        {
            my $data = tempdir(CLEANUP => 1);
            ac20_make_bp_dir($data, 'bpx', [
                { key => 'p1-a', status => 'pending', write_set => 'a/' },
                { key => 'p2-b', status => 'pending', write_set => 'b/' },
                { key => 'p3-c', status => 'pending', write_set => 'c/' },
            ]);
            my $dsdir = "$data/.drive-solo";
            make_path($dsdir);
            write_json("$dsdir/order.json", { order => ['bpx'], recorded_at => $NOW20 });
            write_json("$dsdir/inflight.json", { packages => [
                { blueprint => 'bpx', package => 'p2-b', ledger => ac20_ledger_prefix($data, 'bpx', 'p2-b'), since => $NOW20 - 1800 },
                { blueprint => 'bpx', package => 'p1-a', ledger => ac20_ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW20 - 1800 },
            ], updated_at => $NOW20 - 1800 });

            local $ENV{BUTLER_CONCURRENCY} = '1';
            my ($rc, $out) = ac20_run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW20 } });
            is($rc, 0, 'R9-m2(order): exits 0');
            my $act = ac20_decode_line($out);
            is(ref $act eq 'HASH' ? $act->{action} : undef, 'run-package', 'R9-m2(order): reclaim wins over a disjoint ready package (p3-c)');
            is(ref $act eq 'HASH' ? $act->{package} : undef, 'p1-a', 'R9-m2(order): p1-a sorts first and is the one reclaimed, not p2-b nor p3-c');
            my $run_md = read_bytes("$dsdir/run.md") // '';
            like($run_md, qr/RECLAIM bpx\/p1-a/, 'R9-m2(order): the RECLAIM line names p1-a');
            unlike($run_md, qr/RECLAIM bpx\/p2-b/, 'R9-m2(order): p2-b is not also reclaimed this call');
        }

        # blueprint scope.
        {
            my $data = tempdir(CLEANUP => 1);
            ac20_make_bp_dir($data, 'bpx', [{ key => 'p1-a', status => 'pending', write_set => 'a/' }]);
            ac20_make_bp_dir($data, 'bpy', [{ key => 'q1-a', status => 'pending', write_set => 'q/' }]);
            my $dsdir = "$data/.drive-solo";
            make_path($dsdir);
            write_json("$dsdir/order.json", { order => ['bpx', 'bpy'], recorded_at => $NOW20 });
            write_json("$dsdir/inflight.json", { packages => [
                { blueprint => 'bpx', package => 'p1-a', ledger => ac20_ledger_prefix($data, 'bpx', 'p1-a'), since => $NOW20 - 1800 },
                { blueprint => 'bpy', package => 'q1-a', ledger => ac20_ledger_prefix($data, 'bpy', 'q1-a'), since => $NOW20 - 1800 },
            ], updated_at => $NOW20 - 1800 });

            local $ENV{BUTLER_CONCURRENCY} = '1';
            my ($rc, $out) = ac20_run_next($data, ['next', '--scope', 'all'], { now => sub { $NOW20 } });
            is($rc, 0, 'R9-m2(scope): exits 0');
            my $act = ac20_decode_line($out);
            is(ref $act eq 'HASH' ? "$act->{blueprint}/$act->{package}" : undef, 'bpx/p1-a',
                'R9-m2(scope): only the visited blueprint (bpx) is reclaimed from, in order');
            my $run_md = read_bytes("$dsdir/run.md") // '';
            unlike($run_md, qr/RECLAIM bpy/, "R9-m2(scope): bpy's aged, unbound entry is not reclaimed while bpx is visited");
        }
    }
}

# ===========================================================================
# R9-m5 (review MINOR gap): the B8 line-cut path is exercised with a
# real-sized (120-character) name on both sides of the ledger line.
# ===========================================================================
{
    my $data = fresh_data();
    my $long_bp  = 'b' . ('y' x 119);
    my $long_pkg = 'p' . ('z' x 119);
    my @members = ({ bp => $long_bp, pkg => $long_pkg }, { bp => 'bpx', pkg => 'p2-b' });
    write_inflight($data, @members);
    my $sid = 'r9m5-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data, BUTLER_CONCURRENCY => '1');
    my $res = bd(payload(session_id => $sid, tool_use_id => 'T1', prompt => 'nothing named here'), env => \%env);
    is($res->{rc}, 2, 'R9-m5: denies with a 120-character-name member present');
    my @lines = split /\n/, $res->{err};
    my ($cut_line) = grep { /\.\.\.\z/ } @lines;
    ok(defined $cut_line, 'R9-m5: the over-length member line is cut (ends in ...)');
  SKIP: {
        skip 'R9-m5: no cut line to inspect', 1 unless defined $cut_line;
        is(length($cut_line), 160, 'R9-m5: the cut line is exactly 160 characters (157 + "...")');
    }
}

# ===========================================================================
# R9-m6 (review MINOR gap): AC-12's "no file outside bindings/" is asserted
# directly, by snapshotting the whole data tree.
# ===========================================================================
{
    my $data = fresh_data();
    write_inflight($data, { bp => 'bpx', pkg => 'p1-a' });
    my $sid = 'r9m6-sid';
    GuardHarness::fresh_state();
    GuardHarness::arm($sid, 'driver');
    my %env = (CCPRAXIS_DATA_DIR => $data);
    my $before = dispatch_snapshot($data);
    my $res = bd(payload(session_id => $sid, tool_use_id => '../x'), env => \%env);
    is($res->{rc}, 0, 'R9-m6: an invalid tool_use_id allows');
    is_deeply(dispatch_snapshot($data), $before,
        'R9-m6: no file anywhere under the data dir changed -- nothing written outside bindings/');
}

done_testing();
