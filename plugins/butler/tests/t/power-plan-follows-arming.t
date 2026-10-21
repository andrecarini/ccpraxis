#!/usr/bin/env perl
# platform: windows
#
# ORACLE for blueprint package 06-plan-follows-arming (host-wake-and-suspend),
# derived ONLY from
# .ccpraxis-local-data/blueprints/host-wake-and-suspend/specs/06-plan-follows-arming-spec.md
# (AC1-AC16) plus blueprint Decision 22 (the write set gains
# plugins/butler/bin/bp-power-plan and BpPowerJournal.pm, so the journal
# report renders kind:plan records instead of an unknown-kind note). NOT
# derived from any implementation: at the time this file is written,
# BpPowerPlan.pm, bp-power-plan.pl and the bin shim do not exist, and
# BpContinuityLease.pm's daemon_loop has no plan/plan_opts wiring and
# scripts/statusline.pl has no power-plan block. Every call into
# BpPowerPlan.pm goes through PP() below, which turns "Undefined
# subroutine"/a missing require into a plain undef instead of dying, so a
# missing module makes assertions FAIL for a missing-behavior reason, never
# a compile error.
#
# THE REAL POWER PLAN IS NEVER TOUCHED. Every path to powercfg goes through
# one of the spec's two seams:
#   - the `run` coderef (BpPowerPlan::reconcile's `run` / daemon_loop's
#     plan_opts.run): an in-process fake that never spawns anything;
#   - $ENV{CCPRAXIS_POWERCFG}: an absolute path to a small Perl script this
#     file writes, which BpPowerPlan::powercfg_argv (per spec 2.1 rule 1)
#     always prefers over the real powercfg.exe, in both the .t process and
#     any subprocess it spawns (the CLI, the statusline).
# The last-resort guard (powercfg_argv's own $0=~/\.t\z/ and
# CCPRAXIS_NO_WAKELOCK refusals) is exercised directly by AC-10 and never
# defeated elsewhere in this file.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use MIME::Base64 qw(encode_base64 decode_base64);
use Time::HiRes qw(sleep time);
use POSIX qw(WNOHANG);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
(my $BIN = "$Bin/../../bin") =~ s{\\}{/}g;
require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";
require "$S/bp-keepawake.pl";
require "$S/BpPowerJournal.pm";
my $POWER_PLAN_MODULE = "$S/BpPowerPlan.pm";
eval { require $POWER_PLAN_MODULE };
my $MODULE_LOAD_ERROR = $@;
my $CLI = "$S/bp-power-plan.pl";
my $SHIM = "$BIN/bp-power-plan";

# ---------------------------------------------------------------------------
# PP(name, @args) -- call BpPowerPlan::<name> without ever crashing this file
# when the sub (or the whole module) does not exist yet. Same idiom as
# power-journal.t's own PZ().
# ---------------------------------------------------------------------------
sub PP {
    my ($name, @args) = @_;
    my $code;
    { no strict 'refs'; $code = \&{"BpPowerPlan::$name"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? (wantarray ? @ret : $ret[0]) : undef;
}
sub explain_undef { return 'PP() returned undef -- BpPowerPlan.pm or the named sub does not exist yet' }

delete $ENV{$_} for grep { !/^CCPRAXIS_NO_WAKELOCK$/ && /^(?:BP_|CCPRAXIS_|CLAUDE_)/ } keys %ENV;
$ENV{CCPRAXIS_LEASE_LIVE_SCRIPT} = "$S/BpContinuityLease.pm";

my @KILL_PIDS;
END {
    for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { kill('TERM', $pid) } }
    if (@KILL_PIDS) {
        select(undef, undef, undef, 0.3);
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { kill('KILL', $pid) if kill(0, $pid) } }
        for my $pid (@KILL_PIDS) { next unless $pid; local $@; eval { waitpid($pid, WNOHANG) } }
    }
    $? = 0;
}
$SIG{$_} = sub { exit 1 } for qw(TERM INT HUP);

# ===========================================================================
# generic helpers
# ===========================================================================
sub fresh_home { my $t = tempdir(CLEANUP => 1); (my $b = "$t/home") =~ s{\\}{/}g; make_path($b); return $b }
sub fresh_dir {
    my ($suffix) = @_;
    $suffix //= 'active';
    my $t = tempdir(CLEANUP => 1);
    (my $d = "$t/$suffix") =~ s{\\}{/}g;
    make_path($d);
    return $d;
}
sub slurp {
    my ($p) = @_;
    return undef unless defined $p && -f $p;
    open(my $fh, '<:raw', $p) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}
sub jsonl_lines {
    my ($path) = @_;
    my $raw = slurp($path);
    return () unless defined $raw && length $raw;
    return split /\n/, $raw;
}
sub decode_or_undef {
    my ($line) = @_;
    my $d = eval { JSON::PP->new->utf8->decode($line) };
    return $@ ? undef : $d;
}
sub plan_records {
    my ($legacy) = @_;
    my @out;
    for my $line (jsonl_lines("$legacy/power-journal.jsonl")) {
        my $d = decode_or_undef($line);
        push @out, $d if ref $d eq 'HASH' && defined $d->{kind} && $d->{kind} eq 'plan';
    }
    return @out;
}

# a fresh (BUTLER_STATE_DIR, CCPRAXIS_CONTINUITY_ACTIVE_DIR) pair, wired the
# same way power-journal.t / continuity-lease-follows-arm.t wire them.
sub fresh_group {
    my $home   = fresh_home();
    my $legacy = fresh_dir('legacy');
    $ENV{BUTLER_STATE_DIR}               = $home;
    $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();
    return ($home, $legacy);
}

sub arm_one {
    my ($sid) = @_;
    my $t = tempdir(CLEANUP => 1);
    (my $tp = "$t/transcript.jsonl") =~ s{\\}{/}g;
    open(my $fh, '>', $tp) or die "open $tp: $!";
    print {$fh} "{}\n";
    close $fh;
    ok(BpHook::arm($sid, role => 'manual', by => 'on', transcript_path => $tp), "setup: BpHook::arm($sid) succeeds");
    return;
}

# ===========================================================================
# powercfg fixture byte-shapes (spec 2.7 / Decision 21's lesson): CRLF, the
# two-space gap, the trailing " *". Synthetic content only, no host data.
# ===========================================================================
our $BAL_GUID       = '381b4222-f694-41f0-9685-ff5bb260df2e';
our $CW_NAME         = 'Continuous work';
our $CW_GUID_STORED  = '54a34db5-af62-4d8a-ba50-af7155ee895a';

sub ga_bytes { my ($guid, $name) = @_; return "Power Scheme GUID: $guid  ($name)\r\n" }

sub list_bytes {
    my (@entries) = @_;
    my $body = '';
    for my $e (@entries) {
        $body .= "Power Scheme GUID: $e->{guid}  ($e->{name})" . ($e->{active} ? ' *' : '') . "\r\n";
    }
    return "\r\nExisting Power Schemes (* Active)\r\n-----------------------------------\r\n$body";
}

# A translated label plus a non-ASCII byte (\xED, an i-acute) in a name --
# Decision 21's own lesson: parsers must key on the GUID/parens shape, never
# on a label word, and never decode plan-name bytes.
sub list_bytes_localized {
    return "\r\nEsquemas de energ\xEDa existentes (* Activo)\r\n"
         . "-----------------------------------\r\n"
         . "GUID del esquema de energ\xEDa: $BAL_GUID  (Equilibrado) *\r\n"
         . "GUID del esquema de energ\xEDa: $CW_GUID_STORED  (Trabajo continuo)\r\n";
}

# ===========================================================================
# run_seam(%scn) -- an in-process fake for reconcile's/daemon_loop's `run`
# seam. Records every call (in argv order) and answers by verb. A call to a
# verb the caller never scripted answers a bland ok/rc0/empty result rather
# than dying, so an UNEXPECTED extra call still shows up in @calls for the
# test to catch, instead of crashing the whole file with an undef dereference.
# ===========================================================================
sub run_seam {
    my (%scn) = @_;
    my @calls;
    my $fn = sub {
        my @args = @_;
        push @calls, [ @args ];
        my $verb = defined $args[0] ? $args[0] : '';
        return $scn{getactivescheme} if $verb eq '/getactivescheme' && exists $scn{getactivescheme};
        return $scn{list}            if $verb eq '/list'            && exists $scn{list};
        return $scn{setactive}       if $verb eq '/setactive'       && exists $scn{setactive};
        return { status => 'ok', rc => 0, out => '', ms => 1 };
    };
    return ($fn, \@calls);
}
sub ok_result { my ($out) = @_; return { status => 'ok', rc => 0, out => $out, ms => 1 } }
sub rc1_result { my ($out) = @_; return { status => 'ok', rc => 1, out => (defined $out ? $out : ''), ms => 1 } }

ok(1, "sanity: harness loaded" . ($MODULE_LOAD_ERROR ? " (BpPowerPlan.pm not yet present: $MODULE_LOAD_ERROR)" : ''));

# ===========================================================================
# AC-1 (DC1) -- armed, active Balanced, cw listed by name: one /setactive to
# cw, one plan record with action:set, result:ok, wanted_basis:name.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac1sess');

    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID,      name => 'Balanced',        active => 1 },
            { guid => $CW_GUID_STORED, name => $CW_NAME },
        )),
        setactive => ok_result(''),
    );

    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1, journal => 0,
            spawn => sub { 9101 }, powershell_available => sub { 1 }, kill_pid => sub { },
            plan_opts => { run => $run },
        );
        1;
    };
    ok($rc, 'AC1: daemon_loop completes one tick without dying') or diag($@);

    my @setactive_calls = grep { $_->[0] eq '/setactive' } @$calls;
    is(scalar(@setactive_calls), 1, 'AC1: exactly one /setactive call') or diag(explain_undef());
    is($setactive_calls[0][1], $CW_GUID_STORED, 'AC1: /setactive is called with the cw guid') if @setactive_calls;

    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC1: exactly one kind:plan journal record') or diag(explain_undef());
    if (@recs) {
        my $r = $recs[0];
        is($r->{why}, 'refresher-tick', 'AC1: why is refresher-tick');
        is($r->{action}, 'set', 'AC1: action is set');
        is($r->{result}, 'ok', 'AC1: result is ok');
        is($r->{found_guid}, $BAL_GUID, 'AC1: found_guid is the active (Balanced) guid');
        is($r->{wanted_guid}, $CW_GUID_STORED, 'AC1: wanted_guid is the cw guid');
        is($r->{wanted_basis}, 'name', 'AC1: wanted_basis is name');
        is($r->{armed}, 1, 'AC1: armed count is 1');
        is_deeply($r->{arm_ids}, ['ac1sess'], 'AC1: arm_ids is [sid]');
    }
}

# ===========================================================================
# AC-2 (DC2) -- armed, active already cw: no /setactive, no plan record.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac2sess');

    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($CW_GUID_STORED, $CW_NAME)),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID,       name => 'Balanced' },
            { guid => $CW_GUID_STORED, name => $CW_NAME, active => 1 },
        )),
    );

    BpContinuityLease::daemon_loop($legacy,
        max_iterations => 1, tick => 1, journal => 0,
        spawn => sub { 9102 }, powershell_available => sub { 1 }, kill_pid => sub { },
        plan_opts => { run => $run },
    );

    my @setactive_calls = grep { $_->[0] eq '/setactive' } @$calls;
    is(scalar(@setactive_calls), 0, 'AC2: no /setactive call when the active plan already matches cw by name');
    my @recs = plan_records($legacy);
    is(scalar(@recs), 0, 'AC2: no kind:plan journal record when the plan is already correct');
}

# ===========================================================================
# AC-3 (DC3) -- nothing armed, active cw: the refresher's final (IDLE) pass
# sets Balanced; /list is never called; record has why:refresher-exit,
# wanted_basis:stock, armed:0.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    # nothing armed

    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($CW_GUID_STORED, $CW_NAME)),
        setactive       => ok_result(''),
    );

    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1, journal => 0,
            plan_opts => { run => $run },
        );
    };
    is($rc, 'done', 'AC3: daemon_loop exits through IDLE with "done"') or diag($@);

    my @list_calls = grep { $_->[0] eq '/list' } @$calls;
    is(scalar(@list_calls), 0, 'AC3: /list is never called when nothing is armed');
    my @setactive_calls = grep { $_->[0] eq '/setactive' } @$calls;
    is(scalar(@setactive_calls), 1, 'AC3: exactly one /setactive call') or diag(explain_undef());
    is($setactive_calls[0][1], $BAL_GUID, 'AC3: /setactive is called with the Balanced (stock) guid') if @setactive_calls;

    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC3: exactly one kind:plan journal record');
    if (@recs) {
        is($recs[0]{why}, 'refresher-exit', 'AC3: why is refresher-exit');
        is($recs[0]{wanted_basis}, 'stock', 'AC3: wanted_basis is stock');
        is($recs[0]{armed}, 0, 'AC3: armed count is 0');
    }
}

# ===========================================================================
# AC-4 (DC4) -- a manual switch is corrected on the next check, both while
# armed (-> cw) and while unarmed (-> Balanced). One record each.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac4armed');
    my $third_guid = 'aaaaaaaa-bbbb-cccc-dddd-111111111111';

    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($third_guid, 'Third Plan')),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID,       name => 'Balanced' },
            { guid => $CW_GUID_STORED, name => $CW_NAME },
        )),
        setactive => ok_result(''),
    );
    my $outcome = PP('reconcile', $legacy, run => $run, why => 'manual');
    SKIP: {
        skip 'AC4a: reconcile not implemented yet', 3 unless ref $outcome eq 'HASH';
        is($outcome->{outcome}, 'corrected', 'AC4a: armed manual switch is corrected');
        my @sc = grep { $_->[0] eq '/setactive' } @$calls;
        is(scalar(@sc), 1, 'AC4a: exactly one /setactive call');
        is($sc[0][1], $CW_GUID_STORED, 'AC4a: /setactive targets cw while armed') if @sc;
    }
    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC4a: one plan record written for the armed manual switch') or diag(explain_undef());
}
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    # nothing armed
    my $third_guid = 'aaaaaaaa-bbbb-cccc-dddd-222222222222';

    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($third_guid, 'Third Plan')),
        setactive       => ok_result(''),
    );
    my $outcome = PP('reconcile', $legacy, run => $run, why => 'manual');
    SKIP: {
        skip 'AC4b: reconcile not implemented yet', 3 unless ref $outcome eq 'HASH';
        is($outcome->{outcome}, 'corrected', 'AC4b: unarmed manual switch is corrected');
        my @sc = grep { $_->[0] eq '/setactive' } @$calls;
        is(scalar(@sc), 1, 'AC4b: exactly one /setactive call');
        is($sc[0][1], $BAL_GUID, 'AC4b: /setactive targets Balanced while unarmed') if @sc;
    }
    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC4b: one plan record written for the unarmed manual switch') or diag(explain_undef());
}

# ===========================================================================
# AC-5 (DC5) -- resolution: name-under-different-guid, case/whitespace
# insensitivity, stored-guid fallback, neither-present error (and the tick
# survives, with the heartbeat advancing), and a duplicate-cw-name correct.
# ===========================================================================
{ # (a) name matches under a DIFFERENT guid than the stored one
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac5a');
    my $other_cw_guid = 'bbbbbbbb-1111-2222-3333-444444444444';
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID,      name => 'Balanced', active => 1 },
            { guid => $other_cw_guid, name => $CW_NAME },
        )),
        setactive => ok_result(''),
    );
    my $outcome = PP('reconcile', $legacy, run => $run);
    SKIP: {
        skip 'AC5a: reconcile not implemented yet', 3 unless ref $outcome eq 'HASH';
        is($outcome->{wanted_basis}, 'name', 'AC5a: basis is name');
        is($outcome->{wanted_guid}, $other_cw_guid, 'AC5a: the set targets the NAME MATCH\'s own guid, not the stored fallback');
        my @sc = grep { $_->[0] eq '/setactive' } @$calls;
        is($sc[0][1], $other_cw_guid, 'AC5a: /setactive is called with the name-matched guid') if @sc;
    }
}
{ # (b) case-insensitive, whitespace-trimmed name match
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac5b');
    my $cw_guid2 = 'cccccccc-1111-2222-3333-444444444444';
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced', active => 1 },
            { guid => $cw_guid2, name => '  CONTINUOUS WORK  ' },
        )),
        setactive => ok_result(''),
    );
    my $outcome = PP('reconcile', $legacy, run => $run);
    SKIP: {
        skip 'AC5b: reconcile not implemented yet', 2 unless ref $outcome eq 'HASH';
        is($outcome->{wanted_basis}, 'name', 'AC5b: a case/whitespace-different name still resolves by name');
        is($outcome->{wanted_guid}, $cw_guid2, 'AC5b: the set targets that entry\'s own guid');
    }
}
{ # (c) name absent, stored guid listed -> basis stored-guid
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac5c');
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID,       name => 'Balanced', active => 1 },
            { guid => $CW_GUID_STORED, name => 'Some Other Name' },
        )),
        setactive => ok_result(''),
    );
    my $outcome = PP('reconcile', $legacy, run => $run);
    SKIP: {
        skip 'AC5c: reconcile not implemented yet', 2 unless ref $outcome eq 'HASH';
        is($outcome->{wanted_basis}, 'stored-guid', 'AC5c: falls back to the stored guid when no name matches');
        is($outcome->{wanted_guid}, $CW_GUID_STORED, 'AC5c: the set targets the stored guid');
    }
}
{ # (d) neither the name nor the stored guid is listed -> error, no set, tick survives
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac5d');
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
        list            => ok_result(list_bytes({ guid => $BAL_GUID, name => 'Balanced', active => 1 })),
    );
    my $outcome = PP('reconcile', $legacy, run => $run);
    SKIP: {
        skip 'AC5d: reconcile not implemented yet', 3 unless ref $outcome eq 'HASH';
        is($outcome->{outcome}, 'error', 'AC5d: outcome is error when cw is missing entirely');
        is($outcome->{reason}, 'continuous-work-missing', 'AC5d: reason is continuous-work-missing');
        is($outcome->{wanted_guid}, 'none', 'AC5d: wanted_guid is none');
    }
    my @sc = grep { $_->[0] eq '/setactive' } @$calls;
    is(scalar(@sc), 0, 'AC5d: no /setactive call when cw cannot be resolved');
    my @recs = plan_records($legacy);
    is(scalar(@recs), 1, 'AC5d: one error plan record is written') or diag(explain_undef());
    is($recs[0]{error}, 'continuous-work-missing', 'AC5d: the record\'s error names continuous-work-missing') if @recs;

    # ... and inside daemon_loop with 2 iterations, both ticks complete and
    # the heartbeat pid file's mtime advances. The pid file is unlinked by
    # the loop's own release() on the way out, so it is sampled DURING the
    # loop (from inside the log callback, synchronously on each TICK), never
    # after daemon_loop returns.
    my $before = int(time());
    my $pf = "$legacy/lease.pid";
    my ($run2) = run_seam(
        getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
        list            => ok_result(list_bytes({ guid => $BAL_GUID, name => 'Balanced', active => 1 })),
    );
    my @events;
    my @heartbeats;
    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 2, tick => 1, journal => 0,
            spawn => sub { 9503 }, powershell_available => sub { 1 }, kill_pid => sub { },
            plan_opts => { run => $run2 },
            log => sub {
                push @events, [ $_[0], $_[1] // '' ];
                push @heartbeats, ((-f $pf) ? (stat($pf))[9] : undef) if $_[0] eq 'TICK';
            },
        );
        1;
    };
    ok($rc, 'AC5d: daemon_loop completes 2 iterations despite a persistent cw-missing error') or diag($@);
    my @ticks = grep { $_->[0] eq 'TICK' } @events;
    is(scalar(@ticks), 2, 'AC5d: both ticks complete');
    is(scalar(@heartbeats), 2, 'AC5d: the heartbeat pid file exists at each of the 2 ticks')
        or diag('heartbeats: ' . join(',', map { defined $_ ? $_ : 'undef' } @heartbeats));
    ok((grep { defined $_ && $_ >= $before } @heartbeats),
        'AC5d: the heartbeat pid file\'s mtime advances past the loop\'s start, despite the plan error');
}
{ # (e) the active plan is a SECOND plan also named cw: correct, no set
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac5e');
    my $cw_guid_a = 'dddddddd-1111-2222-3333-444444444444';
    my $cw_guid_b = 'eeeeeeee-1111-2222-3333-444444444444';
    my ($run, $calls) = run_seam(
        getactivescheme => ok_result(ga_bytes($cw_guid_b, $CW_NAME)),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID,   name => 'Balanced' },
            { guid => $cw_guid_a,  name => $CW_NAME },
            { guid => $cw_guid_b,  name => $CW_NAME, active => 1 },
        )),
    );
    my $outcome = PP('reconcile', $legacy, run => $run);
    SKIP: {
        skip 'AC5e: reconcile not implemented yet', 1 unless ref $outcome eq 'HASH';
        is($outcome->{outcome}, 'correct', 'AC5e: the active plan is A duplicate-named cw plan, so it counts as correct');
    }
    my @sc = grep { $_->[0] eq '/setactive' } @$calls;
    is(scalar(@sc), 0, 'AC5e: no /setactive call when a duplicate-named plan is already active');
}

# ===========================================================================
# AC-6 (DC5) -- parsers (parse_list/parse_active) across real shapes, and
# decide() exercised directly for every branch in spec 2.1.
# ===========================================================================
subtest 'AC6: parse_active / parse_list' => sub {
    my $ga_en = ga_bytes($BAL_GUID, 'Balanced');
    my $a = PP('parse_active', $ga_en);
    SKIP: {
        skip 'parse_active not implemented yet', 2 unless ref $a eq 'HASH';
        is(lc($a->{guid}), $BAL_GUID, 'AC6: parse_active reads the guid');
        is($a->{name}, 'Balanced', 'AC6: parse_active reads the name');
    }

    my $l_en = list_bytes(
        { guid => $BAL_GUID,       name => 'Balanced',  active => 1 },
        { guid => $CW_GUID_STORED, name => $CW_NAME },
    );
    my $le = PP('parse_list', $l_en);
    SKIP: {
        skip 'parse_list not implemented yet', 3 unless ref $le eq 'ARRAY';
        is(scalar(@$le), 2, 'AC6: parse_list (English, CRLF) finds two entries');
        is(lc($le->[0]{guid}), $BAL_GUID, 'AC6: entry order is preserved (Balanced first)');
        is($le->[1]{name}, $CW_NAME, 'AC6: the second entry\'s name is Continuous work');
    }

    # localised label + a non-ASCII byte in a name (Decision 21's lesson)
    my $l_loc = list_bytes_localized();
    my $llo = PP('parse_list', $l_loc);
    SKIP: {
        skip 'parse_list not implemented yet', 3 unless ref $llo eq 'ARRAY';
        is(scalar(@$llo), 2, 'AC6: parse_list survives a translated label line');
        is(lc($llo->[0]{guid}), $BAL_GUID, 'AC6: the GUID is still found under a translated label');
        like($llo->[0]{name}, qr/Equilibrado/, 'AC6: the localised (non-ASCII) name is captured, raw bytes, undecoded')
            or diag(explain_undef());
    }

    # LF-only variant of the same shape
    (my $l_lf = $l_en) =~ s/\r\n/\n/g;
    my $llf = PP('parse_list', $l_lf);
    SKIP: {
        skip 'parse_list not implemented yet', 1 unless ref $llf eq 'ARRAY';
        is(scalar(@$llf), 2, 'AC6: parse_list also works on LF-only line endings');
    }

    # a name containing parentheses -- the match must be greedy
    my $paren_line = "Power Scheme GUID: $CW_GUID_STORED  (Continuous work (custom))\r\n";
    my $lp = PP('parse_list', $paren_line);
    SKIP: {
        skip 'parse_list not implemented yet', 1 unless ref $lp eq 'ARRAY';
        is($lp->[0]{name}, 'Continuous work (custom)', 'AC6: a name containing parentheses is captured whole (greedy)');
    }

    # no GUID anywhere
    is_deeply(PP('parse_list', "no guid here at all\r\n"), [], 'AC6: parse_list with no GUID returns []');
    is(PP('parse_active', "no guid here at all\r\n"), undef, 'AC6: parse_active with no GUID returns undef');
};

subtest 'AC6: decide() branches (spec 2.1)' => sub {
    my $d;
    $d = PP('decide', armed => 0, active => $CW_GUID_STORED);
    SKIP: {
        skip 'decide not implemented yet', 2 unless ref $d eq 'HASH';
        is($d->{action}, 'set', 'decide: N=0, active != balanced -> set');
        is($d->{wanted_basis}, 'stock', 'decide: N=0 basis is stock');
    }
    $d = PP('decide', armed => 0, active => $BAL_GUID);
    SKIP: { skip 'decide not implemented yet', 1 unless ref $d eq 'HASH';
        is($d->{action}, 'none', 'decide: N=0, active == balanced -> none'); }

    $d = PP('decide', armed => 1, active => $BAL_GUID, list => undef);
    SKIP: { skip 'decide not implemented yet', 2 unless ref $d eq 'HASH';
        is($d->{action}, 'error', 'decide: N>0, list undef -> error');
        is($d->{error}, 'list-failed', 'decide: N>0, list undef -> error list-failed'); }

    my $list = [ { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME } ];
    $d = PP('decide', armed => 1, active => $BAL_GUID, list => $list);
    SKIP: { skip 'decide not implemented yet', 2 unless ref $d eq 'HASH';
        is($d->{action}, 'set', 'decide: N>0, name present, active != cw -> set');
        is($d->{wanted_basis}, 'name', 'decide: basis name'); }

    $d = PP('decide', armed => 1, active => $CW_GUID_STORED, list => $list);
    SKIP: { skip 'decide not implemented yet', 1 unless ref $d eq 'HASH';
        is($d->{action}, 'none', 'decide: N>0, active already in S (by name) -> none'); }

    my $list_stored_only = [ { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => 'Other' } ];
    $d = PP('decide', armed => 1, active => $BAL_GUID, list => $list_stored_only);
    SKIP: { skip 'decide not implemented yet', 1 unless ref $d eq 'HASH';
        is($d->{wanted_basis}, 'stored-guid', 'decide: name absent, stored guid listed -> stored-guid'); }

    my $list_missing = [ { guid => $BAL_GUID, name => 'Balanced' } ];
    $d = PP('decide', armed => 1, active => $BAL_GUID, list => $list_missing);
    SKIP: { skip 'decide not implemented yet', 2 unless ref $d eq 'HASH';
        is($d->{action}, 'error', 'decide: neither name nor stored guid -> error');
        is($d->{error}, 'continuous-work-missing', 'decide: error is continuous-work-missing'); }

    # cw_guid not in S, but two entries share the name -> first of S in list order
    my $dup_a = 'ffffffff-0000-0000-0000-000000000001';
    my $dup_b = 'ffffffff-0000-0000-0000-000000000002';
    my $list_dup = [ { guid => $BAL_GUID, name => 'Balanced' }, { guid => $dup_a, name => $CW_NAME }, { guid => $dup_b, name => $CW_NAME } ];
    $d = PP('decide', armed => 1, active => $BAL_GUID, list => $list_dup);
    SKIP: { skip 'decide not implemented yet', 1 unless ref $d eq 'HASH';
        is($d->{wanted_guid}, $dup_a, 'decide: cw_guid absent from S, duplicate names -> the FIRST of S in list order'); }
};

# ===========================================================================
# AC-7 (DC6) -- a failing call (rc=1) at each of the three steps gives one
# error record naming the step, detail rc=1, and no later call. A healthy
# retry afterwards corrects the plan.
# ===========================================================================
{
    my %step_name = (getactivescheme => 'getactive-failed', list => 'list-failed');
    for my $fail_step (qw(getactivescheme list setactive)) {
        my ($home, $legacy) = fresh_group();
        local $BpContinuityLease::PLATFORM = 'windows';
        arm_one("ac7-$fail_step");

        my %scn = (
            getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
            list            => ok_result(list_bytes(
                { guid => $BAL_GUID, name => 'Balanced', active => 1 }, { guid => $CW_GUID_STORED, name => $CW_NAME },
            )),
            setactive => ok_result(''),
        );
        $scn{$fail_step} = rc1_result('');
        my ($run, $calls) = run_seam(%scn);
        my $outcome = PP('reconcile', $legacy, run => $run);

        SKIP: {
            skip "AC7 ($fail_step): reconcile not implemented yet", 2 unless ref $outcome eq 'HASH';
            is($outcome->{outcome}, 'error', "AC7 ($fail_step): outcome is error");
            is($outcome->{detail}, 'rc=1', "AC7 ($fail_step): detail is rc=1");
        }
        my @recs = plan_records($legacy);
        is(scalar(@recs), 1, "AC7 ($fail_step): exactly one error plan record") or diag(explain_undef());

        my %expected_calls_before_fail = (getactivescheme => 0, list => 1, setactive => 2);
        is(scalar(@$calls), $expected_calls_before_fail{$fail_step} + 1,
            "AC7 ($fail_step): no call is made after the failing one") or diag(explain_undef());

        # the next reconcile with a HEALTHY seam corrects the plan (the retry)
        my ($run2, $calls2) = run_seam(
            getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
            list            => ok_result(list_bytes(
                { guid => $BAL_GUID, name => 'Balanced', active => 1 }, { guid => $CW_GUID_STORED, name => $CW_NAME },
            )),
            setactive => ok_result(''),
        );
        my $outcome2 = PP('reconcile', $legacy, run => $run2);
        SKIP: {
            skip "AC7 ($fail_step) retry: reconcile not implemented yet", 1 unless ref $outcome2 eq 'HASH';
            is($outcome2->{outcome}, 'corrected', "AC7 ($fail_step): the next check with a healthy seam corrects the plan");
        }
    }
}

# ===========================================================================
# AC-8 (DC6) -- a hanging /getactivescheme is bounded: reconcile returns
# under 6s wall clock with error:getactive-failed, detail:timeout. Uses a
# REAL subprocess fake (never the real powercfg): CCPRAXIS_POWERCFG.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac8');

    # Decision 24 (coordinator follow-up): reconcile() with no explicit `run`
    # now needs a live-root match, so this direct-to-the-default-path call
    # needs the override plus a matching <root>/.continuity-active arm dir.
    my $override_root = fresh_dir('ac8-live-root');
    $legacy = "$override_root/.continuity-active";
    make_path($legacy);
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $ENV{CCPRAXIS_POWER_PLAN_LIVE_ROOT}  = $override_root;

    my ($fake, $ctrl) = write_fake_powercfg(getactivescheme => { sleep => 60 });
    local $ENV{CCPRAXIS_POWERCFG} = $fake;
    local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl;
    local $BpPowerPlan::POWERCFG_TIMEOUT_SECONDS = 1;

    my $t0 = time();
    my $outcome = PP('reconcile', $legacy);
    my $elapsed = time() - $t0;
    ok($elapsed < 6, "AC8: reconcile returns within 6s wall clock despite a 60s hang (took ${elapsed}s)")
        or diag(explain_undef());
    SKIP: {
        skip 'AC8: reconcile not implemented yet', 2 unless ref $outcome eq 'HASH';
        is($outcome->{reason}, 'getactive-failed', 'AC8: reason is getactive-failed');
        is($outcome->{detail}, 'timeout', 'AC8: detail is timeout');
    }
}

# ===========================================================================
# AC-9 (DC6) -- containment: a `run` seam that dies never stops the tick. The
# loop completes both iterations, lease.log gains PLAN-ERROR, and the
# heartbeat is touched.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac9');
    my $before = int(time());

    my $pf = "$legacy/lease.pid";
    my @events;
    my @heartbeats;
    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 2, tick => 1, journal => 0,
            spawn => sub { 9901 }, powershell_available => sub { 1 }, kill_pid => sub { },
            plan_opts => { run => sub { die "fixture: plan run must die\n" } },
            log => sub {
                push @events, [ $_[0], $_[1] // '' ];
                push @heartbeats, ((-f $pf) ? (stat($pf))[9] : undef) if $_[0] eq 'TICK';
            },
        );
        1;
    };
    ok($rc, 'AC9: daemon_loop completes both iterations even though the plan run seam dies') or diag($@);

    my @tokens = map { $_->[0] } @events;
    is(scalar(grep { $_ eq 'TICK' } @tokens), 2, 'AC9: both ticks complete');
    ok((grep { $_ eq 'PLAN-ERROR' } @tokens), 'AC9: lease.log gains a PLAN-ERROR line') or diag(join(' ', @tokens));

    # The pid file is unlinked by the loop's own release() on the way out, so
    # the heartbeat is sampled DURING the loop (inside the log callback,
    # synchronously on each TICK), never after daemon_loop returns.
    is(scalar(@heartbeats), 2, 'AC9: the heartbeat pid file exists at each of the 2 ticks')
        or diag('heartbeats: ' . join(',', map { defined $_ ? $_ : 'undef' } @heartbeats));
    ok((grep { defined $_ && $_ >= $before } @heartbeats),
        'AC9: the heartbeat is touched despite the dying plan step');
}

# ===========================================================================
# AC-10 (DC5, DC6) -- guards: no run + no CCPRAXIS_POWERCFG under a .t
# refuses; a non-windows platform never calls the seam; a relative
# CCPRAXIS_POWERCFG path is refused.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    arm_one('ac10-guard');
    local $ENV{CCPRAXIS_POWERCFG};
    delete $ENV{CCPRAXIS_POWERCFG};
    local $BpContinuityLease::PLATFORM = 'windows';

    is(PP('powercfg_argv', '/getactivescheme'), undef,
        'AC10: powercfg_argv returns undef under this .t with no CCPRAXIS_POWERCFG') or diag(explain_undef());

    # Decision 24 (coordinator follow-up): the structural live-root check now
    # runs before the old $0/CCPRAXIS_NO_WAKELOCK last-resort guard, so
    # without a live-root match this call would be skipped/not-live-install
    # regardless of the $0=~/\.t\z/ condition AC10 means to exercise. Give it
    # a matching override + arm dir so the OLD guard is what actually fires.
    my $ac10_root = fresh_dir('ac10-live-root');
    $legacy = "$ac10_root/.continuity-active";
    make_path($legacy);
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $ENV{CCPRAXIS_POWER_PLAN_LIVE_ROOT}  = $ac10_root;

    my $outcome = PP('reconcile', $legacy);
    SKIP: {
        skip 'AC10: reconcile not implemented yet', 2 unless ref $outcome eq 'HASH';
        is($outcome->{outcome}, 'skipped', 'AC10: reconcile with no run/CCPRAXIS_POWERCFG is skipped');
        is($outcome->{reason}, 'guard', 'AC10: the skip reason is guard');
    }
    my @recs = plan_records($legacy);
    is(scalar(@recs), 0, 'AC10: no plan record is written for a guard skip');
}
for my $plat (qw(posix unsupported)) {
    my ($home, $legacy) = fresh_group();
    arm_one("ac10-$plat");
    local $BpContinuityLease::PLATFORM = $plat;
    my ($run, $calls) = run_seam(getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')));
    my $outcome = PP('reconcile', $legacy, run => $run);
    SKIP: {
        skip "AC10 ($plat): reconcile not implemented yet", 2 unless ref $outcome eq 'HASH';
        is($outcome->{outcome}, 'skipped', "AC10 ($plat): outcome is skipped");
        is($outcome->{reason}, 'not-windows', "AC10 ($plat): reason is not-windows");
    }
    is(scalar(@$calls), 0, "AC10 ($plat): the run seam is never called on a non-windows platform");
}
{
    local $ENV{CCPRAXIS_POWERCFG} = 'relative/path/fake-powercfg.pl';
    is(PP('powercfg_argv', '/list'), undef, 'AC10: a relative CCPRAXIS_POWERCFG path gives undef, never a fallback');
}

# ===========================================================================
# AC-11 (DC1) -- the plan record carries every 2.2 key, and utc matches /Z$/.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac11');
    my ($run) = run_seam(
        getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
        list            => ok_result(list_bytes(
            { guid => $BAL_GUID, name => 'Balanced', active => 1 }, { guid => $CW_GUID_STORED, name => $CW_NAME },
        )),
        setactive => ok_result(''),
    );
    PP('reconcile', $legacy, run => $run, why => 'manual');
    my @recs = plan_records($legacy);
    SKIP: {
        skip 'AC11: no plan record written yet', 20 unless @recs;
        my $r = $recs[0];
        for my $key (qw(v kind ts utc local pid why armed arm_ids found_guid found_name
                        wanted_guid wanted_name wanted_basis action result error detail rc ms)) {
            ok(exists $r->{$key}, "AC11: plan record has key '$key'");
        }
        like($r->{utc}, qr/Z$/, 'AC11: utc ends in Z');
        is($r->{kind}, 'plan', 'AC11: kind is "plan"');
        is($r->{v}, 1, 'AC11: v is 1');
    }
}

# ===========================================================================
# AC-12 (DC8) -- the CLI, run as a real subprocess against the fake env.
# ===========================================================================
sub run_cli {
    my ($script, @args) = @_;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec($^X, $script, @args);
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    my $deadline = time() + 30;
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.05);
    }
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    return (slurp($outfile) // '', slurp($errfile) // '', $rc);
}

# write_fake_powercfg(%behavior) -> ($fake_script_path, $control_path). One
# fixed dispatcher script (per file, reused across calls); each caller gets
# its OWN control file so concurrent scenarios never interfere. %behavior:
# { getactivescheme|list|setactive => { out => bytes, rc => int, sleep => s } }
my $FAKE_POWERCFG_SCRIPT;
sub write_fake_powercfg {
    my (%behavior) = @_;
    unless (defined $FAKE_POWERCFG_SCRIPT) {
        my (undef, $path) = tempfile();
        open(my $fh, '>', $path) or die "open $path: $!";
        print {$fh} <<'PERLSRC';
use strict; use warnings;
use MIME::Base64 ();
use JSON::PP ();
my $control = $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL};
my %cfg;
if (defined $control && -f $control) {
    open(my $cf, '<:raw', $control) or exit 9;
    local $/; my $raw = <$cf>; close $cf;
    my $d = eval { JSON::PP::decode_json($raw) };
    %cfg = %$d if ref $d eq 'HASH';
}
my $verb = shift(@ARGV) // '';
my $key = $verb eq '/getactivescheme' ? 'getactivescheme'
        : $verb eq '/list'            ? 'list'
        : $verb eq '/setactive'       ? 'setactive'
        : 'unknown';
if (defined $ENV{CCPRAXIS_TEST_POWERCFG_CALL_LOG}) {
    open(my $lfh, '>>', $ENV{CCPRAXIS_TEST_POWERCFG_CALL_LOG}) or exit 9;
    print {$lfh} join(' ', $verb, @ARGV), "\n";
    close $lfh;
}
my $c = (ref $cfg{$key} eq 'HASH') ? $cfg{$key} : {};
if ($c->{sleep}) { sleep($c->{sleep}) }
if (defined $c->{out_b64}) {
    binmode(STDOUT);
    print MIME::Base64::decode_base64($c->{out_b64});
}
exit(defined $c->{rc} ? $c->{rc} : 0);
PERLSRC
        close $fh;
        $FAKE_POWERCFG_SCRIPT = $path;
    }
    my %ctrl;
    for my $k (qw(getactivescheme list setactive)) {
        next unless ref $behavior{$k} eq 'HASH';
        my %c;
        $c{rc} = $behavior{$k}{rc} if defined $behavior{$k}{rc};
        $c{sleep} = $behavior{$k}{sleep} if defined $behavior{$k}{sleep};
        $c{out_b64} = encode_base64($behavior{$k}{out}, '') if defined $behavior{$k}{out};
        $ctrl{$k} = \%c;
    }
    my (undef, $ctrl_path) = tempfile();
    open(my $cf, '>', $ctrl_path) or die "open $ctrl_path: $!";
    print {$cf} JSON::PP->new->utf8->encode(\%ctrl);
    close $cf;
    return ($FAKE_POWERCFG_SCRIPT, $ctrl_path);
}

{
    # Decision 24 (coordinator follow-up): reconcile() now refuses
    # (not-live-install) unless the live-root check passes, so the CLI here
    # needs CCPRAXIS_POWER_PLAN_LIVE_ROOT plus an arm-state dir that is
    # exactly <that root>/.continuity-active -- the CLI subprocess inherits
    # both from this block's %ENV.
    my $home         = fresh_home();
    my $override_root = fresh_dir('ac12-live-root');
    my $legacy       = "$override_root/.continuity-active";
    make_path($legacy);
    local $ENV{BUTLER_STATE_DIR}               = $home;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $ENV{CCPRAXIS_POWER_PLAN_LIVE_ROOT}  = $override_root;
    local $BpContinuityLease::STATE_ROOT        = BpHook::state_dir();
    arm_one('ac12sid');

    my ($fake, $ctrl) = write_fake_powercfg(
        getactivescheme => { out => ga_bytes($BAL_GUID, 'Balanced') },
        list            => { out => list_bytes(
            { guid => $BAL_GUID, name => 'Balanced', active => 1 }, { guid => $CW_GUID_STORED, name => $CW_NAME },
        ) },
        setactive => { rc => 0 },
    );

    local $ENV{CCPRAXIS_POWERCFG} = $fake;
    local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl;

    SKIP: {
        skip 'AC12: bp-power-plan.pl does not exist yet', 12 unless -f $CLI;
        my ($out, $err, $rc) = run_cli($CLI, 'reconcile');
        is($rc, 0, 'AC12: reconcile exits 0 against a corrected fake plan') or diag("stderr: $err");
        like($out, qr/^armed: 1 \(ac12sid\)$/m, 'AC12: stdout has the armed: line') or diag($out);
        like($out, qr/^found: 381b4222-f694-41f0-9685-ff5bb260df2e/m, 'AC12: stdout has the found: line') or diag($out);
        like($out, qr/^wanted: \Q$CW_GUID_STORED\E \(Continuous work, name\)$/m, 'AC12: stdout has the wanted: line') or diag($out);
        like($out, qr/^result: corrected$/m, 'AC12: stdout has result: corrected') or diag($out);

        my @recs = plan_records($legacy);
        is(scalar(@recs), 1, 'AC12: one plan record with why:manual is written');
        is($recs[0]{why}, 'manual', 'AC12: why is manual') if @recs;

        # run again with the fake now reporting cw already active
        my ($fake2, $ctrl2) = write_fake_powercfg(
            getactivescheme => { out => ga_bytes($CW_GUID_STORED, $CW_NAME) },
            list            => { out => list_bytes(
                { guid => $BAL_GUID, name => 'Balanced' }, { guid => $CW_GUID_STORED, name => $CW_NAME, active => 1 },
            ) },
        );
        local $ENV{CCPRAXIS_POWERCFG} = $fake2;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl2;
        my ($out2, $err2, $rc2) = run_cli($CLI, 'reconcile');
        is($rc2, 0, 'AC12: a second reconcile with the plan already correct exits 0') or diag("stderr: $err2");
        like($out2, qr/^result: correct$/m, 'AC12: result: correct when the plan is already cw') or diag($out2);
        my @recs2 = plan_records($legacy);
        is(scalar(@recs2), 1, 'AC12: no NEW plan record is written when the plan is already correct');

        # --why statusline puts why:statusline in the record
        local $ENV{CCPRAXIS_POWERCFG} = $fake;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl;
        my ($out3, $err3, $rc3) = run_cli($CLI, 'reconcile', '--why', 'statusline');
        is($rc3, 0, 'AC12: --why statusline exits 0') or diag("stderr: $err3");
        my @recs3 = plan_records($legacy);
        is($recs3[-1]{why}, 'statusline', 'AC12: --why statusline is recorded as why:statusline') if @recs3;

        # a fake with /list rc=1
        my ($fake4, $ctrl4) = write_fake_powercfg(
            getactivescheme => { out => ga_bytes($BAL_GUID, 'Balanced') },
            list            => { rc => 1 },
        );
        local $ENV{CCPRAXIS_POWERCFG} = $fake4;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl4;
        my ($out4, $err4, $rc4) = run_cli($CLI, 'reconcile');
        is($rc4, 1, 'AC12: exit 1 when /list fails');
        like($out4, qr/^result: error: list-failed \(rc=1\)$/m, 'AC12: result: error: list-failed (rc=1)') or diag($out4);

        # no verb, or an unknown verb
        my (undef, undef, $rc5) = run_cli($CLI);
        is($rc5, 2, 'AC12: no verb exits 2');
        my (undef, undef, $rc6) = run_cli($CLI, 'bogus');
        is($rc6, 2, 'AC12: an unknown verb exits 2');
    }
}

# ===========================================================================
# AC-13 (DC7) -- CLI marker prune: --why statusline removes an 8-day-old
# plan-checked/<sid> entry and keeps a fresh one.
# ===========================================================================
{
    # Decision 24 (coordinator follow-up): same live-root override as AC12,
    # so this CLI subprocess's reconcile does not hit not-live-install.
    my $home         = fresh_home();
    my $override_root = fresh_dir('ac13-live-root');
    my $legacy       = "$override_root/.continuity-active";
    make_path($legacy);
    local $ENV{BUTLER_STATE_DIR}               = $home;
    local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $ENV{CCPRAXIS_POWER_PLAN_LIVE_ROOT}  = $override_root;
    local $BpContinuityLease::STATE_ROOT        = BpHook::state_dir();
    arm_one('ac13sid');

    my $root = BpHook::state_dir();
    make_path("$root/plan-checked");
    open(my $ofh, '>', "$root/plan-checked/old-sid") or die $!;
    close $ofh;
    open(my $ffh, '>', "$root/plan-checked/fresh-sid") or die $!;
    close $ffh;
    my $old_t = time() - 8 * 86400;
    utime($old_t, $old_t, "$root/plan-checked/old-sid");

    my ($fake, $ctrl) = write_fake_powercfg(
        getactivescheme => { out => ga_bytes($BAL_GUID, 'Balanced') },
        list            => { out => list_bytes(
            { guid => $BAL_GUID, name => 'Balanced', active => 1 }, { guid => $CW_GUID_STORED, name => $CW_NAME },
        ) },
        setactive => { rc => 0 },
    );
    local $ENV{CCPRAXIS_POWERCFG} = $fake;
    local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl;

    SKIP: {
        skip 'AC13: bp-power-plan.pl does not exist yet', 2 unless -f $CLI;
        run_cli($CLI, 'reconcile', '--why', 'statusline');
        ok(!-e "$root/plan-checked/old-sid", 'AC13: an 8-day-old plan-checked marker is pruned');
        ok(-e "$root/plan-checked/fresh-sid", 'AC13: a fresh plan-checked marker is kept');
    }
}

# ===========================================================================
# AC-14, AC-15 (DC7) -- statusline: once per session, cheap on later draws.
# Windows-only (SKIP with reason elsewhere).
# ===========================================================================
(my $STATUSLINE = "$Bin/../../../../scripts/statusline.pl") =~ s{\\}{/}g;

sub write_plan_cli_stub {
    my ($logpath) = @_;
    my (undef, $path) = tempfile();
    open(my $fh, '>', $path) or die "open $path: $!";
    print {$fh} <<'PERLSRC';
my $log = $ENV{CCPRAXIS_TEST_PLAN_CLI_LOG};
if (defined $log) {
    open(my $fh, '>>', $log) or exit 9;
    print {$fh} join(' ', @ARGV), "\n";
    close $fh;
}
sleep(8);
if (defined $log) {
    open(my $fh2, '>>', $log) or exit 9;
    print {$fh2} "done\n";
    close $fh2;
}
exit 0;
PERLSRC
    close $fh;
    return $path;
}

# run_statusline_stdin(\%payload, %env) -> ($stdout, $rc, $elapsed_seconds)
sub run_statusline_stdin {
    my ($payload, %env) = @_;
    my (undef, $inpath) = tempfile();
    open(my $ifh, '>', $inpath) or die $!;
    print {$ifh} JSON::PP->new->utf8->encode($payload);
    close $ifh;
    my (undef, $outfile) = tempfile();
    my (undef, $errfile) = tempfile();

    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        for my $k (keys %env) {
            if (defined $env{$k}) { $ENV{$k} = $env{$k} } else { delete $ENV{$k} }
        }
        open(STDIN,  '<', $inpath) or POSIX::_exit(126);
        open(STDOUT, '>', $outfile) or POSIX::_exit(126);
        open(STDERR, '>', $errfile) or POSIX::_exit(126);
        exec($^X, $STATUSLINE);
        POSIX::_exit(127);
    }
    push @KILL_PIDS, $pid;
    my $t0 = time();
    my $deadline = $t0 + 15;
    my $rc;
    while (time() < $deadline) {
        my $w = waitpid($pid, WNOHANG);
        if ($w == $pid) { $rc = $? >> 8; last }
        sleep(0.02);
    }
    my $elapsed = time() - $t0;
    unless (defined $rc) { kill('KILL', $pid); waitpid($pid, 0); $rc = -1 }
    @KILL_PIDS = grep { $_ != $pid } @KILL_PIDS;
    return (slurp($outfile) // '', $rc, $elapsed);
}

SKIP: {
    my $on_windows = ($^O =~ /^(MSWin32|msys|cygwin)$/) ? 1 : 0;
    skip 'AC14/AC15: statusline power-plan block is exercised only on the Windows host', 1 unless $on_windows;
    skip 'AC14: statusline.pl not found at the expected path', 1 unless -f $STATUSLINE;

    subtest 'AC14: statusline once-per-session power-plan reconcile' => sub {
        my $home = fresh_home();
        # Decision 23: the spawn path is provable only while the state is at
        # its real defaults -- BUTLER_STATE_DIR and CCPRAXIS_CONTINUITY_ACTIVE_DIR
        # both unset, HOME/USERPROFILE resolved instead -- so $cont follows
        # _state_dir()'s HOME-fallback branch, not a BUTLER_STATE_DIR override.
        my $cont = "$home/.claude/butler-state/continuity";
        make_path($cont);
        my $logpath = fresh_home() . '/plan-cli.log';
        my $stub = write_plan_cli_stub($logpath);

        my %base_env = (
            CCPRAXIS_SANDBOX => undef,
            BUTLER_STATE_DIR => undef,
            CCPRAXIS_CONTINUITY_ACTIVE_DIR => undef,
            HOME => $home, USERPROFILE => $home,
            CCPRAXIS_POWER_PLAN_CLI => $stub,
            CCPRAXIS_TEST_PLAN_CLI_LOG => $logpath,
            CCPRAXIS_POWER_PLAN_STATUSLINE => undef,
        );

        my ($out, $rc, $elapsed) = run_statusline_stdin({ session_id => 'stln-S' }, %base_env);
        is($rc, 0, 'AC14a: the first draw exits 0');
        ok($elapsed < 6, "AC14a: the first draw reaches stdout EOF in under 6s (took ${elapsed}s)");

        SKIP: {
            skip 'AC14a: no power-plan block yet -- no marker to check', 1
                unless -e "$cont/plan-checked/stln-S";
            ok(1, 'AC14a: the marker plan-checked/stln-S exists');
        }
        ok(-e "$cont/plan-checked/stln-S", 'AC14a: the marker plan-checked/stln-S exists after the first draw');

        my $saw_invocation = 0;
        my $saw_done = 0;
        my $deadline = time() + 20;
        while (time() < $deadline) {
            my $text = slurp($logpath) // '';
            if ($text =~ /^reconcile --why statusline$/m) { $saw_invocation = 1 }
            if ($text =~ /^done$/m) { $saw_done = 1; last }
            sleep(0.2);
        }
        ok($saw_invocation, 'AC14a: within 20s the CLI log shows one invocation with argv "reconcile --why statusline"');
        ok($saw_done, 'AC14a: the stub\'s "done" line eventually appears (proving the child ran to completion undetached)');

        # (b) two more draws with the same sid: still exactly one invocation
        my ($out2, $rc2) = run_statusline_stdin({ session_id => 'stln-S' }, %base_env);
        my ($out3, $rc3) = run_statusline_stdin({ session_id => 'stln-S' }, %base_env);
        select(undef, undef, undef, 3);
        my $text_after = slurp($logpath) // '';
        my $count = () = $text_after =~ /^reconcile --why statusline$/mg;
        is($count, 1, 'AC14b: two further draws with the same sid start no new CLI invocation');

        # (c) a new sid brings the count to 2
        my ($out4, $rc4) = run_statusline_stdin({ session_id => 'stln-S2' }, %base_env);
        my $deadline2 = time() + 20;
        my $count2 = 0;
        while (time() < $deadline2) {
            $count2 = () = (slurp($logpath) // '') =~ /^reconcile --why statusline$/mg;
            last if $count2 >= 2;
            sleep(0.2);
        }
        is($count2, 2, 'AC14c: a new sid brings the invocation count to 2');
        ok(-e "$cont/plan-checked/stln-S2", 'AC14c: the marker plan-checked/stln-S2 exists for the new sid');
    };

    subtest 'AC14d: nothing is spawned or written in the off-path cases' => sub {
        # S2 fix (report 06-review.md): a BUTLER_STATE_DIR override made every
        # case here pass via Decision 23's own env-guard, never via the
        # case's own condition. Dropped, so each draw follows the real
        # HOME-derived default location (as AC14a does) and the sandbox/
        # session-id/off-switch/CLI/continuity-dir condition under test is
        # what actually decides the outcome.
        my %cases = (
            'sandbox on'              => { CCPRAXIS_SANDBOX => '1' },
            'no session_id'           => { session_id_absent => 1 },
            'statusline off-switch'   => { CCPRAXIS_POWER_PLAN_STATUSLINE => '0' },
            'no CLI resolvable'       => { CCPRAXIS_POWER_PLAN_CLI => undef },
            'no continuity dir'       => { no_continuity_dir => 1 },
        );
        for my $label (sort keys %cases) {
            my $home = fresh_home();
            my $cont = "$home/.claude/butler-state/continuity";
            make_path($cont) unless $cases{$label}{no_continuity_dir};
            my $logpath = fresh_home() . '/plan-cli.log';
            my $stub = write_plan_cli_stub($logpath);
            my $sid = 'offpath-' . ($label =~ s/\W+/-/gr);

            my %env = (
                CCPRAXIS_SANDBOX => undef,
                BUTLER_STATE_DIR => undef,
                CCPRAXIS_CONTINUITY_ACTIVE_DIR => undef,
                HOME => $home, USERPROFILE => $home,
                CCPRAXIS_POWER_PLAN_CLI => $stub, CCPRAXIS_TEST_PLAN_CLI_LOG => $logpath,
                CCPRAXIS_POWER_PLAN_STATUSLINE => undef,
            );
            for my $k (keys %{ $cases{$label} }) {
                next if $k eq 'session_id_absent' || $k eq 'no_continuity_dir';
                $env{$k} = $cases{$label}{$k};
            }
            my $payload = $cases{$label}{session_id_absent} ? {} : { session_id => $sid };

            my ($out, $rc) = run_statusline_stdin($payload, %env);
            is($rc, 0, "AC14d ($label): the draw still exits 0");
            select(undef, undef, undef, 1);
            ok(!-e "$cont/plan-checked/$sid", "AC14d ($label): no marker is written") if !$cases{$label}{session_id_absent};
            my $log_text = slurp($logpath) // '';
            unlike($log_text, qr/^reconcile --why statusline$/m, "AC14d ($label): nothing is spawned");
        }
    };

    subtest 'Decision 23: overridden state never triggers a real reconcile' => sub {
        # Both env vars, checked separately, must each be able to suppress
        # the spawn on their own -- the guard is "either is set", not "both".
        # Both candidate continuity dirs are pre-created so the ONLY reason
        # nothing fires is the guard, never a missing -d $pp_state check.
        for my $label (sort qw(BUTLER_STATE_DIR CCPRAXIS_CONTINUITY_ACTIVE_DIR)) {
            my $home = fresh_home();
            my $fake = fresh_dir('fake-state');
            make_path("$home/.claude/butler-state/continuity");
            make_path("$fake/continuity");
            my $logpath = fresh_home() . '/plan-cli.log';
            my $stub = write_plan_cli_stub($logpath);
            my $sid = 'dec23-' . lc($label);

            my %env = (
                CCPRAXIS_SANDBOX => undef,
                BUTLER_STATE_DIR => undef,
                CCPRAXIS_CONTINUITY_ACTIVE_DIR => undef,
                HOME => $home, USERPROFILE => $home,
                CCPRAXIS_POWER_PLAN_CLI => $stub,
                CCPRAXIS_TEST_PLAN_CLI_LOG => $logpath,
                CCPRAXIS_POWER_PLAN_STATUSLINE => undef,
            );
            $env{$label} = $fake;

            my ($out, $rc) = run_statusline_stdin({ session_id => $sid }, %env);
            is($rc, 0, "Decision 23 ($label set): the draw still exits 0");
            select(undef, undef, undef, 1);

            ok(!-e $logpath, "Decision 23 ($label set): no invocation file is written")
                or diag('log contents: ' . (slurp($logpath) // '<absent>'));

            ok(!-e "$home/.claude/butler-state/continuity/plan-checked/$sid",
                "Decision 23 ($label set): no plan-checked marker under the HOME-derived default location");
            ok(!-e "$fake/continuity/plan-checked/$sid",
                "Decision 23 ($label set): no plan-checked marker under the overridden location");
        }
    };

    subtest 'AC15: later-draw cost stays within 100ms of the off-switch baseline' => sub {
        # S2 fix: previously BUTLER_STATE_DIR => $home pointed the resolver at
        # $home while the marker was written under $home/continuity -- two
        # different locations -- so the marker draw took the Decision 23
        # env-guard's "nothing spawned, nothing checked" exit rather than the
        # real -e-marker-so-skip-the-CLI path. Drop the override and put the
        # marker at the real HOME-derived default location so the "marker"
        # timing run actually walks the -e check it claims to measure.
        my $home = fresh_home();
        my $cont = "$home/.claude/butler-state/continuity";
        make_path($cont);
        make_path("$cont/plan-checked");
        open(my $mfh, '>', "$cont/plan-checked/perf-sid") or die $!;
        close $mfh;
        my $stub = write_plan_cli_stub(fresh_home() . '/unused.log');

        my %env_marker = (
            CCPRAXIS_SANDBOX => undef,
            BUTLER_STATE_DIR => undef,
            CCPRAXIS_CONTINUITY_ACTIVE_DIR => undef,
            HOME => $home, USERPROFILE => $home,
            CCPRAXIS_POWER_PLAN_CLI => $stub, CCPRAXIS_POWER_PLAN_STATUSLINE => undef,
        );
        my %env_off = (%env_marker, CCPRAXIS_POWER_PLAN_STATUSLINE => '0');

        my @diffs;
        for (1 .. 7) {
            my (undef, undef, $t_marker) = run_statusline_stdin({ session_id => 'perf-sid' }, %env_marker);
            my (undef, undef, $t_off)    = run_statusline_stdin({ session_id => 'perf-sid' }, %env_off);
            push @diffs, abs($t_marker - $t_off) * 1000;
        }
        my @sorted = sort { $a <=> $b } @diffs;
        my $median = $sorted[int(@sorted / 2)];
        ok($median <= 100, "AC15: the median later-draw timing difference is at most 100ms (got ${median}ms)")
            or diag('diffs (ms): ' . join(', ', map { sprintf('%.1f', $_) } @diffs));
    };
}

# ===========================================================================
# AC-16 (DC6, DC7) -- source checks on statusline.pl and BpPowerPlan.pm.
# ===========================================================================
subtest 'AC16: source checks' => sub {
    my $sl_src = slurp($STATUSLINE);
    ok(defined $sl_src, 'AC16: statusline.pl is readable') or return;

    my @begins = ($sl_src =~ /# -- power-plan:begin --/g);
    my @ends   = ($sl_src =~ /# -- power-plan:end --/g);
    is(scalar(@begins), 1, 'AC16: exactly one power-plan:begin marker');
    is(scalar(@ends), 1, 'AC16: exactly one power-plan:end marker');

    if (@begins && @ends) {
        my ($pp_start) = $sl_src =~ /()# -- power-plan:begin --/;
        my $pp_start_pos = index($sl_src, '# -- power-plan:begin --');
        my $pp_end_pos   = index($sl_src, '# -- power-plan:end --');
        ok($pp_start_pos >= 0 && $pp_end_pos > $pp_start_pos, 'AC16: begin precedes end');
        my $block = substr($sl_src, $pp_start_pos, $pp_end_pos - $pp_start_pos);
        unlike($block, qr/\brequire\b/, 'AC16: the power-plan block contains no "require"');

        for my $existing (qw(continuity-badge pending-decisions)) {
            my $b_pos = index($sl_src, "# -- $existing:begin --");
            my $e_pos = index($sl_src, "# -- $existing:end --");
            next if $b_pos < 0 || $e_pos < 0;
            my $overlap = ($pp_start_pos >= $b_pos && $pp_start_pos <= $e_pos)
                       || ($pp_end_pos   >= $b_pos && $pp_end_pos   <= $e_pos);
            ok(!$overlap, "AC16: the power-plan block does not lie inside the $existing block");
        }
    }

    # the S7 use allow-list (spec 2.4 / continuity-question-queue.t S7)
    # Same list as continuity-question-queue.t's S7, Cwd included (core perl,
    # loaded at the top of statusline.pl since 4fd54de).
    my %allow = map { $_ => 1 } qw(strict warnings JSON::PP Time::Piece File::Basename POSIX Encode constant Carp List::Util Scalar::Util Cwd);
    my @use_lines = ($sl_src =~ /^\s*use\s+([A-Za-z0-9:_]+)/mg);
    my @bad = grep { !$allow{$_} } @use_lines;
    is_deeply(\@bad, [], 'AC16: every "use" line in statusline.pl stays within the S7 allow-list') or diag(join(', ', @bad));

    my $pp_src = slurp("$S/BpPowerPlan.pm");
    SKIP: {
        skip 'AC16: BpPowerPlan.pm does not exist yet', 3 unless defined $pp_src;
        unlike($pp_src, qr/`[^`]*powercfg/i, 'AC16: BpPowerPlan.pm names no backtick invoking powercfg');
        unlike($pp_src, qr/qx(?:\{|\(|\/)[^)}\/]*powercfg/i, 'AC16: BpPowerPlan.pm names no qx invoking powercfg');
        unlike($pp_src, qr/system\([^)]*powercfg/i, 'AC16: BpPowerPlan.pm names no system() invoking powercfg');
    }
};

# ===========================================================================
# The bin shim (Decision 22 write-set widening): plugins/butler/bin/bp-power-plan
# execs bp-power-plan.pl with the same argv and exit code, same shape as
# bin/bp-power-journal (power-journal.t's AC9-shim pattern).
# ===========================================================================
{
    my $bash_ok = eval { `bash --version 2>&1`; $? == 0 };
    SKIP: {
        skip 'bin shim: bp-power-plan.pl or the shim does not exist yet', 2 unless -f $CLI && -f $SHIM;
        skip 'bin shim: bash not available on this host', 2 unless $bash_ok;

        my ($direct_out, undef, $direct_rc) = run_cli($CLI); # no verb -> usage + exit 2, no side effects

        my (undef, $shim_outfile) = tempfile();
        my (undef, $shim_errfile) = tempfile();
        my $spid = fork();
        die "fork: $!" unless defined $spid;
        if ($spid == 0) {
            open(STDOUT, '>', $shim_outfile) or POSIX::_exit(126);
            open(STDERR, '>', $shim_errfile) or POSIX::_exit(126);
            exec('bash', $SHIM);
            POSIX::_exit(127);
        }
        push @KILL_PIDS, $spid;
        waitpid($spid, 0);
        my $shim_rc = $? >> 8;
        @KILL_PIDS = grep { $_ != $spid } @KILL_PIDS;
        my $shim_out = slurp($shim_outfile) // '';

        is($shim_rc, $direct_rc, 'bin shim: bp-power-plan (no verb) exits with the same code as the .pl directly');
        is($shim_out, $direct_out, 'bin shim: bp-power-plan (no verb) gives byte-identical stdout to the .pl directly');
    }
}

# ===========================================================================
# Decision 22 -- the journal report renders kind:plan records instead of an
# "unknown kind: plan" note. Direct call to BpPowerJournal::build_timeline
# (that module IS present today) with a synthetic kind:plan record.
# ===========================================================================
{
    my $plan_rec = {
        v => 1, kind => 'plan', ts => 1758950000, utc => '2026-09-27T00:00:00Z', local => '2026-09-26T20:00:00-04:00',
        pid => 4321, why => 'refresher-tick', armed => 1, arm_ids => ['renderme'],
        found_guid => $BAL_GUID, found_name => 'Balanced',
        wanted_guid => $CW_GUID_STORED, wanted_name => $CW_NAME, wanted_basis => 'name',
        action => 'set', result => 'ok', error => '', detail => '', rc => 0, ms => 42,
    };
    my $entries = BpPowerJournal::build_timeline(
        journal_lines => [ $plan_rec ], events => [], transcript => undef,
        since_ms => ($plan_rec->{ts} - 60) * 1000, until_ms => ($plan_rec->{ts} + 60) * 1000,
    );
    ok(ref $entries eq 'ARRAY', 'Decision 22: build_timeline returns an arrayref for a kind:plan record');

    my @plan_entries = grep { ref $_ eq 'HASH' && ($_->{kind} // '') eq 'plan' } @$entries;
    my @unknown_notes = grep {
        ref $_ eq 'HASH' && ($_->{kind} // '') eq 'note' && ($_->{note} // '') =~ /unknown kind:\s*plan/
    } @$entries;

    ok(scalar(@plan_entries) >= 1,
        'Decision 22: a kind:plan journal record renders as its own "plan" timeline entry')
        or diag('entries: ' . JSON::PP->new->canonical->encode($entries));
    is(scalar(@unknown_notes), 0,
        'Decision 22: a kind:plan record no longer falls through to an "unknown kind: plan" note');

    if (@plan_entries) {
        my $e = $plan_entries[0];
        is($e->{why}, 'refresher-tick', 'Decision 22: the rendered plan entry carries its own why');
        is($e->{action}, 'set', 'Decision 22: the rendered plan entry carries its own action');
        is($e->{result}, 'ok', 'Decision 22: the rendered plan entry carries its own result');
        is($e->{found_guid}, $BAL_GUID, 'Decision 22: the rendered plan entry carries found_guid');
        is($e->{wanted_guid}, $CW_GUID_STORED, 'Decision 22: the rendered plan entry carries wanted_guid');
    }
}

# ===========================================================================
# Decision 24 -- the structural "live install" rule. BpPowerPlan may run
# /setactive (even through the CCPRAXIS_POWERCFG fake) only when (a) its own
# module file resolves inside <x>/.claude/ccpraxis/plugins/butler/scripts/
# and (b) the arm-state dir reconcile() was given is exactly
# <that same ccpraxis root>/.continuity-active. Otherwise: outcome skipped,
# reason not-live-install, and no powercfg call at all -- not even through
# the CCPRAXIS_POWERCFG fake.
#
# SAFETY NOTE (binding, do not relax): these tests never leave
# CCPRAXIS_POWERCFG unset while calling reconcile() with no explicit `run`.
# Decision 24 was written after the exact vulnerability this rule closes hit
# the operator's REAL power plan twice via a spawned refresher with no `run`
# seam and no CCPRAXIS_POWERCFG (report 06-review.md, M1). A CCPRAXIS_POWERCFG
# fake is set in every case below (including the "mirrors lease-refresher-
# hygiene.t" ones the ledger describes as "no CCPRAXIS_POWERCFG"), because
# Windows' CreateProcess searches the System32 directory for a bare
# "powercfg.exe" BEFORE it ever consults PATH, so a PATH-shadowing sentinel
# cannot reliably intercept a bare-name real invocation on this host -- it is
# not a safe substitute here. The fake's own per-call log
# (CCPRAXIS_TEST_POWERCFG_CALL_LOG) is what proves "never invoked, not even
# through the fake": if the structural guard fails open, the call lands on
# this harmless fake, never on the real binary, and the log makes that call
# visible so the assertion still catches the guard being missing.
# $0 is localised to a non-".t" path and CCPRAXIS_NO_WAKELOCK is deleted in
# every case, so the OLD last-resort guard ($0=~/\.t\z/, CCPRAXIS_NO_WAKELOCK)
# is defeated first -- exactly the M1 incident's own child conditions -- so a
# pass here is attributable to the NEW structural rule alone, not the old one
# happening to still apply. BUTLER_STATE_DIR and CCPRAXIS_CONTINUITY_ACTIVE_DIR
# are left deleted too, so no other env-var guard can be the reason either.
# ===========================================================================

# copy_tree(src, dst) -- same idiom as lease-refresher-hygiene.t's own copier
# (File::Copy::Recursive is not core). Used to load BpPowerPlan.pm from a
# path other than this file's own $S, so its own module-file location (and
# whatever it requires relative to that) is genuinely elsewhere on disk.
sub copy_tree {
    my ($src, $dst) = @_;
    make_path($dst) unless -d $dst;
    opendir(my $dh, $src) or die "opendir $src: $!";
    for my $entry (readdir $dh) {
        next if $entry eq '.' || $entry eq '..';
        my $s = "$src/$entry";
        my $d = "$dst/$entry";
        if (-d $s) { copy_tree($s, $d) }
        else       { require File::Copy; File::Copy::copy($s, $d) or die "copy $s -> $d: $!" }
    }
    closedir $dh;
    return;
}

# require_bpp($path) -- (re-)load BpPowerPlan.pm from $path in this same
# process. A different absolute path is a fresh %INC entry, so this redefines
# the BpPowerPlan:: subs in place to reflect $path's own __FILE__ -- no
# subprocess needed, so no extra process can ever reach a real powercfg.exe
# outside what CCPRAXIS_POWERCFG governs. Subroutine-redefinition warnings are
# expected and silenced.
sub require_bpp {
    my ($path) = @_;
    ok(-f $path, "Decision24: $path exists before it is required") or return 0;
    my $ok;
    { local $SIG{__WARN__} = sub { }; local $@; $ok = eval { no warnings 'redefine'; require $path; 1 }; diag($@) unless $ok; }
    return $ok;
}

subtest 'Decision 24: the structural live-install rule' => sub {
    my $healthy_fake_behavior = sub {
        return (
            getactivescheme => ok_result(ga_bytes($BAL_GUID, 'Balanced')),
            list            => ok_result(list_bytes(
                { guid => $BAL_GUID, name => 'Balanced', active => 1 }, { guid => $CW_GUID_STORED, name => $CW_NAME },
            )),
            setactive => ok_result(''),
        );
    };

    # (1a) module loaded from the CLONE's own scripts dir ($S) -- never under
    # a .claude/ccpraxis layout, since this checked-out repo lives elsewhere.
    subtest 'module path (a): the clone itself is not the live install' => sub {
        local $0 = '/tmp/decision24-sim/BpContinuityLease.pm';
        local $ENV{CCPRAXIS_NO_WAKELOCK}; delete $ENV{CCPRAXIS_NO_WAKELOCK};
        local $ENV{BUTLER_STATE_DIR}; delete $ENV{BUTLER_STATE_DIR};
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR}; delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};

        my ($fake, $ctrl) = write_fake_powercfg($healthy_fake_behavior->());
        my $calllog = fresh_home() . '/call.log';
        local $ENV{CCPRAXIS_POWERCFG} = $fake;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CALL_LOG} = $calllog;

        my $arm_dir = fresh_dir('d24-1a-arm');
        my $outcome = PP('reconcile', $arm_dir);
        SKIP: {
            skip 'Decision24 (1a): reconcile not implemented yet', 2 unless ref $outcome eq 'HASH';
            is($outcome->{outcome}, 'skipped', '1a: outcome is skipped when loaded from the clone path');
            is($outcome->{reason}, 'not-live-install', '1a: reason is not-live-install');
        }
        ok(!-e $calllog, '1a: the CCPRAXIS_POWERCFG fake recorded no call at all')
            or diag('call log: ' . (slurp($calllog) // '<absent>'));
    };

    # (1b) module loaded from a SCRATCH copy of the whole scripts dir, with
    # CCPRAXIS_NO_WAKELOCK deleted -- exactly lease-refresher-hygiene.t's own
    # copy_tree("$REPO_BUTLER_SCRIPTS", ".../live/plugins/butler/scripts")
    # shape, which is what let the real M1 incident's refresher child through:
    # a "live"-named copy that is still not the live INSTALL.
    subtest 'module path (a): a scratch copy of the scripts dir is not the live install' => sub {
        my $scratch = tempdir(CLEANUP => 1);
        (my $scratch_fwd = $scratch) =~ s{\\}{/}g;
        copy_tree($S, "$scratch_fwd/live/plugins/butler/scripts");
        my $scratch_module = "$scratch_fwd/live/plugins/butler/scripts/BpPowerPlan.pm";
        require_bpp($scratch_module) or return;

        local $0 = "$scratch_fwd/live/plugins/butler/scripts/BpContinuityLease.pm";
        local $ENV{CCPRAXIS_NO_WAKELOCK}; delete $ENV{CCPRAXIS_NO_WAKELOCK};
        local $ENV{BUTLER_STATE_DIR}; delete $ENV{BUTLER_STATE_DIR};
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR}; delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};

        my ($fake, $ctrl) = write_fake_powercfg($healthy_fake_behavior->());
        my $calllog = fresh_home() . '/call.log';
        local $ENV{CCPRAXIS_POWERCFG} = $fake;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CALL_LOG} = $calllog;

        my $arm_dir = fresh_dir('d24-1b-arm');
        my $outcome = PP('reconcile', $arm_dir);
        SKIP: {
            skip 'Decision24 (1b): reconcile not implemented yet', 2 unless ref $outcome eq 'HASH';
            is($outcome->{outcome}, 'skipped', '1b: outcome is skipped when loaded from a scratch copy');
            is($outcome->{reason}, 'not-live-install', '1b: reason is not-live-install');
        }
        ok(!-e $calllog, '1b: the CCPRAXIS_POWERCFG fake recorded no call at all')
            or diag('call log: ' . (slurp($calllog) // '<absent>'));

        require_bpp($POWER_PLAN_MODULE); # restore the clone copy for later subtests
    };

    # (2) the CCPRAXIS_POWER_PLAN_LIVE_ROOT override IS set (so rule (a) has a
    # root to match against), but the arm-state dir passed to reconcile() is
    # NOT that root's .continuity-active -- rule (b) fails on its own.
    subtest 'arm-state dir (b): a live-root override, but the wrong arm-state dir' => sub {
        my $override_root = fresh_dir('d24-2-live-root');
        local $ENV{CCPRAXIS_POWER_PLAN_LIVE_ROOT} = $override_root;
        local $ENV{CCPRAXIS_NO_WAKELOCK}; delete $ENV{CCPRAXIS_NO_WAKELOCK};
        local $ENV{BUTLER_STATE_DIR}; delete $ENV{BUTLER_STATE_DIR};
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR}; delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};

        my ($fake, $ctrl) = write_fake_powercfg($healthy_fake_behavior->());
        my $calllog = fresh_home() . '/call.log';
        local $ENV{CCPRAXIS_POWERCFG} = $fake;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CALL_LOG} = $calllog;

        # deliberately NOT $override_root/.continuity-active
        my $wrong_arm_dir = fresh_dir('d24-2-arm');
        my $outcome = PP('reconcile', $wrong_arm_dir);
        SKIP: {
            skip 'Decision24 (2): reconcile not implemented yet', 2 unless ref $outcome eq 'HASH';
            is($outcome->{outcome}, 'skipped', '2: outcome is skipped when the arm-state dir is not .continuity-active');
            is($outcome->{reason}, 'not-live-install', '2: reason is not-live-install');
        }
        ok(!-e $calllog, '2: the CCPRAXIS_POWERCFG fake recorded no call at all')
            or diag('call log: ' . (slurp($calllog) // '<absent>'));
    };

    # (3) both rules hold via the override: CCPRAXIS_POWER_PLAN_LIVE_ROOT names
    # a root, and the arm-state dir is exactly <that root>/.continuity-active.
    # reconcile() now DOES proceed -- but only ever through the CCPRAXIS_POWERCFG
    # fake, so the positive path stays safe to exercise (per the coordinator's
    # follow-up: an override-sourced root is reachable only through the fake or
    # an explicit `run` seam, never the real powercfg.exe).
    subtest 'both (a) and (b) hold via the override: reconcile proceeds, only through the fake' => sub {
        my $override_root = fresh_dir('d24-3-live-root');
        local $ENV{CCPRAXIS_POWER_PLAN_LIVE_ROOT} = $override_root;
        local $ENV{CCPRAXIS_NO_WAKELOCK}; delete $ENV{CCPRAXIS_NO_WAKELOCK};
        local $ENV{BUTLER_STATE_DIR}; delete $ENV{BUTLER_STATE_DIR};
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR}; delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};

        my ($fake, $ctrl) = write_fake_powercfg($healthy_fake_behavior->());
        my $calllog = fresh_home() . '/call.log';
        local $ENV{CCPRAXIS_POWERCFG} = $fake;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CONTROL} = $ctrl;
        local $ENV{CCPRAXIS_TEST_POWERCFG_CALL_LOG} = $calllog;

        my $arm_dir = "$override_root/.continuity-active";
        make_path($arm_dir);
        my $outcome = PP('reconcile', $arm_dir);
        SKIP: {
            skip 'Decision24 (3): reconcile not implemented yet', 2 unless ref $outcome eq 'HASH';
            isnt($outcome->{outcome}, 'skipped', '3: outcome is not skipped when both (a) and (b) hold')
                or diag('reason: ' . ($outcome->{reason} // '<none>'));
            isnt(($outcome->{reason} // ''), 'not-live-install', '3: reason is not not-live-install');
        }
        my $call_text = slurp($calllog) // '';
        ok(length($call_text) > 0, '3: the CCPRAXIS_POWERCFG fake recorded at least one call')
            or diag('call log: <absent or empty>');
        like($call_text, qr{^/getactivescheme}m, '3: the recorded call includes /getactivescheme')
            or diag("call log: $call_text");
    };

    # (4) coordinator follow-up: an override-sourced live root is reachable
    # ONLY through the CCPRAXIS_POWERCFG fake or an explicit `run` seam, never
    # the real powercfg.exe -- so with the override plus a matching arm dir
    # and NO CCPRAXIS_POWERCFG at all, reconcile must not reach powercfg: it
    # is skipped, rather than falling back to a real invocation. This is the
    # one case in this subtest that deliberately leaves CCPRAXIS_POWERCFG
    # unset; it is safe only because the override itself forecloses the real
    # fallback, per the coordinator's explicit guarantee.
    subtest 'override root forecloses the real powercfg.exe fallback entirely' => sub {
        my $override_root = fresh_dir('d24-4-live-root');
        my $arm_dir = "$override_root/.continuity-active";
        make_path($arm_dir);
        local $ENV{CCPRAXIS_POWER_PLAN_LIVE_ROOT} = $override_root;
        local $ENV{CCPRAXIS_POWERCFG}; delete $ENV{CCPRAXIS_POWERCFG};
        local $ENV{CCPRAXIS_NO_WAKELOCK}; delete $ENV{CCPRAXIS_NO_WAKELOCK};
        local $ENV{BUTLER_STATE_DIR}; delete $ENV{BUTLER_STATE_DIR};
        local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR}; delete $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};

        my $outcome = PP('reconcile', $arm_dir);
        SKIP: {
            skip 'Decision24 (4): reconcile not implemented yet', 1 unless ref $outcome eq 'HASH';
            is($outcome->{outcome}, 'skipped', '4: outcome is skipped when the override root has no CCPRAXIS_POWERCFG fake')
                or diag('reason: ' . ($outcome->{reason} // '<none>'));
        }
    };
};

done_testing();
