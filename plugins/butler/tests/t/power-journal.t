#!/usr/bin/env perl
# platform: windows
#
# ORACLE for blueprint package 05-power-journal (host-wake-and-suspend),
# derived ONLY from
# .ccpraxis-local-data/blueprints/host-wake-and-suspend/specs/05-power-journal-spec.md
# section 4 (AC1-AC12) plus blueprint Decision 19 (the journal lists every
# running ccpraxis keep-awake helper -- AC3's process-scan coverage). NOT
# derived from any implementation: at the time this file is written,
# BpPowerJournal.pm does not exist at all. Every call into it goes through
# PZ() below, which turns "Undefined subroutine" into a plain undef instead
# of dying, so a missing module makes assertions FAIL for a missing-behavior
# reason, never a compile error.
#
# ISOLATION. CCPRAXIS_NO_WAKELOCK=1 is set at BEGIN. HOME/USERPROFILE,
# BUTLER_STATE_DIR and CCPRAXIS_CONTINUITY_ACTIVE_DIR are pinned to tempdirs
# before anything else touches them. CCPRAXIS_LEASE_LIVE_SCRIPT is pointed at
# BpContinuityLease.pm's own path so daemon_loop never attempts a not-live
# handover. $BpContinuityLease::PLATFORM is set 'windows' locally per block.
# No PowerShell is ever spawned: every fixture probe_argv is a real Perl
# child (a different, non-PowerShell process), and the production argv
# builder is never exercised with a live spawn.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path);
use JSON::PP ();
use MIME::Base64 qw(encode_base64);
use Time::HiRes qw(sleep time);
use POSIX qw(WNOHANG);

BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 }

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
require "$S/BpHook.pm";
require "$S/BpContinuityLease.pm";
require "$S/bp-keepawake.pl";
my $POWER_JOURNAL_MODULE = "$S/BpPowerJournal.pm";
eval { require $POWER_JOURNAL_MODULE };
my $MODULE_LOAD_ERROR = $@;

# ---------------------------------------------------------------------------
# PZ(name, @args) -- call BpPowerJournal::<name> without ever crashing this
# file when the sub (or the whole module) does not exist yet. Same idiom as
# continuity-lease-follows-arm.t's LZ().
# ---------------------------------------------------------------------------
sub PZ {
    my ($name, @args) = @_;
    my $code;
    { no strict 'refs'; $code = \&{"BpPowerJournal::$name"} }
    my @ret;
    my $ok = eval { @ret = $code->(@args); 1 };
    return $ok ? (wantarray ? @ret : $ret[0]) : undef;
}

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

# ---------------------------------------------------------------------------
# generic helpers
# ---------------------------------------------------------------------------
sub fresh_home {
    my $t = tempdir(CLEANUP => 1);
    (my $base = "$t/home") =~ s{\\}{/}g;
    make_path($base);
    return $base;
}

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

# decode_or_undef($line) -- never dies on a truncated / garbage line.
sub decode_or_undef {
    my ($line) = @_;
    my $d = eval { JSON::PP->new->utf8->decode($line) };
    return $@ ? undef : $d;
}

# probe_fixture(\%r) -> \&probe_argv seam that runs a real (non-PowerShell)
# perl child which prints base64(utf8(json(%r))) to stdout and exits 0.
sub probe_fixture {
    my ($r, %opts) = @_;
    my $json = JSON::PP->new->utf8->canonical->encode($r);
    my $b64  = encode_base64($json, '');
    my $exit = $opts{exit} // 0;
    my $code = qq{print "$b64"; exit $exit;};
    return sub { [ $^X, '-e', $code ] };
}

# probe_fixture_garbage() -> prints undecodable bytes and exits non-zero.
sub probe_fixture_garbage {
    return sub { [ $^X, '-e', 'print "garbage"; exit 3;' ] };
}

# default_probe_data(%over) -- a full, all-sections-populated probe payload
# matching the pseudocode in spec 2.2.
sub default_probe_data {
    my (%over) = @_;
    my %d = (
        v   => 1,
        err => {},
        power => { line => 'Online', pct => 0.87, chg => 'Charging' },
        plan  => { raw => "Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)\n" },
        cs    => { id => 507, t_ms => 1758700000000 },
        ka    => [],
    );
    for my $k (keys %over) { $d{$k} = $over{$k} }
    return \%d;
}

sub write_lines {
    my ($path, @lines) = @_;
    open(my $fh, '>:raw', $path) or die "open $path: $!";
    print {$fh} "$_\n" for @lines;
    close $fh;
    return;
}

sub append_bytes {
    my ($path, $bytes) = @_;
    open(my $fh, '>>:raw', $path) or die "open $path: $!";
    print {$fh} $bytes;
    close $fh;
    return;
}

sub arm_one {
    my ($sid) = @_;
    ok(BpHook::arm($sid, role => 'manual', by => 'on'), "setup: BpHook::arm($sid) succeeds");
    return;
}

# a fresh (BUTLER_STATE_DIR, CCPRAXIS_CONTINUITY_ACTIVE_DIR) pair, wired the
# same way continuity-lease-follows-arm.t wires them.
sub fresh_group {
    my $home   = fresh_home();
    my $legacy = fresh_dir('legacy');
    $ENV{BUTLER_STATE_DIR}               = $home;
    $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    $BpContinuityLease::STATE_ROOT       = BpHook::state_dir();
    return ($home, $legacy);
}

ok(1, "sanity: harness loaded" . ($MODULE_LOAD_ERROR ? " (BpPowerJournal.pm not yet present: $MODULE_LOAD_ERROR)" : ''));

# ===========================================================================
# AC1 -- one armed Windows-platform tick appends exactly one well-formed line
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac1sess');

    my $now = 1758900000;
    my $probe = default_probe_data();
    my @daemons;
    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1,
            spawn => sub { push @daemons, $_[0]; 9101 },
            powershell_available => sub { 1 },
            kill_pid => sub { },
            journal_opts => {
                now        => sub { $now },
                probe_argv => probe_fixture($probe),
            },
        );
        1;
    };
    ok($rc, 'AC1: daemon_loop completes one iteration without dying') or diag($@);

    my $jpath = "$legacy/power-journal.jsonl";
    my @lines = jsonl_lines($jpath);
    is(scalar(@lines), 1, 'AC1: exactly one line is appended to power-journal.jsonl');

    my $rec = @lines ? decode_or_undef($lines[0]) : undef;
    ok(ref $rec eq 'HASH', 'AC1: the line decodes to a JSON object') or diag($lines[0] // '<no line>');

    SKIP: {
        skip 'AC1: no decodable record to inspect', 15 unless ref $rec eq 'HASH';
        for my $key (qw(v kind ts utc local seq refresher_pid tick_s power_source
                        battery_pct plan_guid plan_name display display_basis
                        display_at helpers sessions probe)) {
            ok(exists $rec->{$key}, "AC1: tick record has key '$key'");
        }
        is($rec->{ts}, $now, 'AC1: ts equals the now seam');
        is($rec->{kind}, 'tick', 'AC1: kind is "tick"');
        is($rec->{power_source}, 'ac', 'AC1: power_source reflects PowerLineStatus Online -> ac');
        is($rec->{battery_pct}, 87, 'AC1: battery_pct reflects the fixture percentage');
        is($rec->{plan_name}, 'Balanced', 'AC1: plan_name is the text inside the last ( )');
        is($rec->{plan_guid}, '381b4222-f694-41f0-9685-ff5bb260df2e', 'AC1: plan_guid is the first GUID');
        is($rec->{display}, 'on', 'AC1: display 507 (exiting connected standby) -> on');
        is($rec->{tick_s}, 1, 'AC1: tick_s reflects the refresher tick');
    }
}

# ===========================================================================
# AC2 -- partial and total probe failure
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac2a');

    my $probe = default_probe_data(err => { plan => 'boom' });
    delete $probe->{plan};
    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1,
            spawn => sub { 9201 }, powershell_available => sub { 1 }, kill_pid => sub { },
            journal_opts => { now => sub { 1758900100 }, probe_argv => probe_fixture($probe) },
        );
        1;
    };
    ok($rc, 'AC2a: daemon_loop completes with a partial probe failure') or diag($@);

    my @lines = jsonl_lines("$legacy/power-journal.jsonl");
    my $rec = @lines ? decode_or_undef($lines[-1]) : undef;
    SKIP: {
        skip 'AC2a: no decodable record', 5 unless ref $rec eq 'HASH';
        is($rec->{plan_guid}, 'unknown', 'AC2a: plan_guid is "unknown" when the plan section failed');
        is($rec->{plan_name}, 'unknown', 'AC2a: plan_name is "unknown" when the plan section failed');
        isnt($rec->{power_source}, 'unknown', 'AC2a: the other sections are still populated (power_source)');
        ok(ref $rec->{probe} eq 'HASH', 'AC2a: probe is an object');
        is($rec->{probe}{status}, 'partial', 'AC2a: probe.status is "partial"');
    }
}
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac2b');

    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1,
            spawn => sub { 9202 }, powershell_available => sub { 1 }, kill_pid => sub { },
            journal_opts => { now => sub { 1758900200 }, probe_argv => probe_fixture_garbage() },
        );
        1;
    };
    ok($rc, 'AC2b: daemon_loop completes with an undecodable/non-zero probe') or diag($@);

    my @lines = jsonl_lines("$legacy/power-journal.jsonl");
    my $rec = @lines ? decode_or_undef($lines[-1]) : undef;
    SKIP: {
        skip 'AC2b: no decodable record', 7 unless ref $rec eq 'HASH';
        for my $key (qw(power_source battery_pct plan_guid plan_name display display_basis display_at)) {
            is($rec->{$key}, 'unknown', "AC2b: $key is \"unknown\" after a garbage/non-zero probe");
        }
        is($rec->{probe}{status}, 'error', 'AC2b: probe.status is "error"');
        ok(exists $rec->{helpers} && exists $rec->{sessions}, 'AC2b: no key is missing from the line');
    }
}

# ===========================================================================
# MUST-FIX 1 (review 05-review.md) -- BatteryLifePercent is a real 0.0-1.0
# float (SystemInformation.PowerStatus), never an already-scaled 0-100
# integer. A real float must be multiplied by 100 to become a percentage,
# and a value outside [0.0, 1.0] (the old 255-sentinel's equivalent) must be
# reported as "unknown" rather than silently truncated/rounded into range.
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('mf1-zero');
    my $probe0 = default_probe_data(power => { line => 'Online', pct => 0.0, chg => 'Charging' });
    BpContinuityLease::daemon_loop($legacy, max_iterations => 1, tick => 1,
        spawn => sub { 9301 }, powershell_available => sub { 1 }, kill_pid => sub { },
        journal_opts => { now => sub { 1758900300 }, probe_argv => probe_fixture($probe0) });
    my $rec0 = decode_or_undef((jsonl_lines("$legacy/power-journal.jsonl"))[-1] // '');
    is(ref($rec0) eq 'HASH' ? $rec0->{battery_pct} : undef, 0,
        'MUST-FIX 1: a real float BatteryLifePercent of 0.0 gives 0, not "unknown" or a truncated non-zero value');
}
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('mf1-full');
    my $probe1 = default_probe_data(power => { line => 'Online', pct => 1.0, chg => 'Charging' });
    BpContinuityLease::daemon_loop($legacy, max_iterations => 1, tick => 1,
        spawn => sub { 9302 }, powershell_available => sub { 1 }, kill_pid => sub { },
        journal_opts => { now => sub { 1758900301 }, probe_argv => probe_fixture($probe1) });
    my $rec1 = decode_or_undef((jsonl_lines("$legacy/power-journal.jsonl"))[-1] // '');
    is(ref($rec1) eq 'HASH' ? $rec1->{battery_pct} : undef, 100,
        'MUST-FIX 1: a real float BatteryLifePercent of 1.0 gives 100, never 1 (the off-by-100 bug)');
}
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('mf1-oor');
    # 2.55 stands in for the old 255-sentinel's equivalent on the new 0.0-1.0
    # scale: a value outside [0.0, 1.0] must never be reported as a real pct.
    my $probeOOR = default_probe_data(power => { line => 'Online', pct => 2.55, chg => 'Charging' });
    BpContinuityLease::daemon_loop($legacy, max_iterations => 1, tick => 1,
        spawn => sub { 9303 }, powershell_available => sub { 1 }, kill_pid => sub { },
        journal_opts => { now => sub { 1758900302 }, probe_argv => probe_fixture($probeOOR) });
    my $recOOR = decode_or_undef((jsonl_lines("$legacy/power-journal.jsonl"))[-1] // '');
    is(ref($recOOR) eq 'HASH' ? $recOOR->{battery_pct} : undef, 'unknown',
        'MUST-FIX 1: a BatteryLifePercent outside [0.0, 1.0] is "unknown", never rounded into range');
}
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('mf1-nobatt');
    my $probeNone = default_probe_data(power => { line => 'Online', pct => 0.0, chg => 'NoSystemBattery' });
    BpContinuityLease::daemon_loop($legacy, max_iterations => 1, tick => 1,
        spawn => sub { 9304 }, powershell_available => sub { 1 }, kill_pid => sub { },
        journal_opts => { now => sub { 1758900303 }, probe_argv => probe_fixture($probeNone) });
    my $recNone = decode_or_undef((jsonl_lines("$legacy/power-journal.jsonl"))[-1] // '');
    is(ref($recNone) eq 'HASH' ? $recNone->{battery_pct} : undef, 'none',
        'MUST-FIX 1: BatteryChargeStatus NoSystemBattery gives battery_pct "none" (a real observation, not unknown)');
}

# ===========================================================================
# AC3 -- helpers_from_state: continuity pidfile + process-scan, merge/dedup
# (also the seam for Decision 19: every running keep-awake helper is listed)
# ===========================================================================
{
    my $dir = fresh_dir('ac3');
    open(my $pf, '>', "$dir/keepawake.pid") or die $!;
    print {$pf} "4242\n";
    close $pf;

    write_lines("$dir/keepawake.log",
        '2026-09-24 03:20:00 pid=4242 REASON text=ccpraxis keep-awake: execution required -- owner x winpid=4242',
        '2026-09-24 03:20:01 pid=4242 OWNER winpid=4242',
        '2026-09-24 03:20:02 pid=4242 ASSERTED flags=ES_CONTINUOUS|ES_SYSTEM_REQUIRED',
        '2026-09-24 03:20:03 pid=4242 POWER-REQUEST-CREATED',
        '2026-09-24 03:20:04 pid=9999 ASSERTED flags=ES_CONTINUOUS|ES_SYSTEM_REQUIRED',
        '2026-09-24 03:20:05 pid=9999 POWER-REQUEST-CREATED',
    );

    my $scan = [ { pid => 4242, cmd => "powershell.exe -File keep-awake.ps1 -PidFile $dir/keepawake.pid -LogFile $dir/keepawake.log" } ];
    my $helpers = PZ('helpers_from_state', $dir, $scan);
    ok(ref $helpers eq 'ARRAY', 'AC3: helpers_from_state returns an arrayref') or diag(explain_undef());
    SKIP: {
        skip 'AC3: helpers_from_state not implemented yet', 6 unless ref $helpers eq 'ARRAY';
        my ($h) = grep { $_->{winpid} eq 4242 } @$helpers;
        ok($h, 'AC3: helpers[] has an entry for winpid 4242');
        is($h->{source}, 'continuity-pidfile', 'AC3: its source is continuity-pidfile') if $h;
        ok($h && $h->{alive}, 'AC3: alive is true when the scan lists the winpid') if $h;
        is_deeply([ sort @{ $h->{requests} } ], [ 'EXECUTION', 'SYSTEM' ],
            'AC3: requests are EXECUTION+SYSTEM after ASSERTED + POWER-REQUEST-CREATED') if $h && ref $h->{requests} eq 'ARRAY';
    }

    append_bytes("$dir/keepawake.log", "2026-09-24 03:20:06 pid=4242 POWER-REQUEST-DEGRADED\n");
    my $helpers2 = PZ('helpers_from_state', $dir, $scan);
    SKIP: {
        skip 'AC3: helpers_from_state not implemented yet', 1 unless ref $helpers2 eq 'ARRAY';
        my ($h2) = grep { $_->{winpid} eq 4242 } @$helpers2;
        is_deeply([ sort @{ $h2->{requests} } ], [ 'SYSTEM' ],
            'AC3: POWER-REQUEST-DEGRADED removes EXECUTION, leaving SYSTEM') if $h2 && ref $h2->{requests} eq 'ARRAY';
    }

    my $helpers3 = PZ('helpers_from_state', $dir, []);
    SKIP: {
        skip 'AC3: helpers_from_state not implemented yet', 2 unless ref $helpers3 eq 'ARRAY';
        my ($h3) = grep { $_->{winpid} eq 4242 } @$helpers3;
        ok($h3 && !$h3->{alive}, 'AC3: with the scan omitting 4242, alive is false') if $h3;
        is_deeply($h3->{requests}, [], 'AC3: a dead process holds nothing (requests [])') if $h3;
    }

    my $dir2 = fresh_dir('ac3-second');
    my $scan_two = [
        { pid => 4242, cmd => "powershell.exe -File keep-awake.ps1 -PidFile $dir/keepawake.pid -LogFile $dir/keepawake.log" },
        { pid => 5555, cmd => "powershell.exe -File keep-awake.ps1 -PidFile $dir2/keepawake.pid -LogFile $dir2/keepawake.log" },
    ];
    my $helpers4 = PZ('helpers_from_state', $dir, $scan_two);
    SKIP: {
        skip 'AC3: helpers_from_state not implemented yet', 2 unless ref $helpers4 eq 'ARRAY';
        is(scalar(grep { $_->{winpid} eq 4242 } @$helpers4), 1,
            'AC3 (Decision 19): the continuity helper (4242) is never duplicated even though the scan also names it');
        ok((grep { $_->{winpid} eq 5555 && $_->{source} eq 'process-scan' } @$helpers4),
            'AC3 (Decision 19): a second, independently-running keep-awake helper (5555) is listed too');
    }
}

sub explain_undef { return 'PZ() returned undef -- BpPowerJournal.pm or the named sub does not exist yet' }

# ===========================================================================
# AC4 -- sessions via live_arms, and active_reason parity
# ===========================================================================
{
    my $home = fresh_home();
    $ENV{BUTLER_STATE_DIR} = $home;
    local $BpContinuityLease::STATE_ROOT = BpHook::state_dir();
    my $root = BpHook::state_dir();

    my ($sidA, $sidB, $sidOld) = qw(ac4a ac4b ac4old);
    for my $sid ($sidA, $sidB, $sidOld) { arm_one($sid) }

    make_path("$root/holder");
    open(my $hfh, '>', "$root/holder/$sidA.json") or die $!;
    print {$hfh} JSON::PP->new->encode({ session_id => $sidA, items => [ 'a1', 'a2' ] });
    close $hfh;

    my $old_armed = "$root/armed/$sidOld";
    my $old_t = time() - 13 * 3600;
    utime($old_t, $old_t, $old_armed);

    my @arms = PZ('live_arms', "$home"); # legacy dir isn't used by live_arms itself; module resolves its own root
    my $lz = eval { BpContinuityLease::live_arms($root) };
    my $arms_ref = defined($lz) ? $lz : (PZ('live_arms', $root));
    ok(ref $arms_ref eq 'ARRAY', 'AC4: live_arms($root) returns an arrayref') or diag('live_arms not implemented yet');
    SKIP: {
        skip 'AC4: live_arms not implemented yet', 3 unless ref $arms_ref eq 'ARRAY';
        my @sids = sort map { $_->{sid} } @$arms_ref;
        is_deeply(\@sids, [ sort($sidA, $sidB) ], 'AC4: live_arms lists exactly the two live sids, excluding the stale one');
        my ($a) = grep { $_->{sid} eq $sidA } @$arms_ref;
        is_deeply($a->{workers} // 'MISSING', [ 'a1', 'a2' ], 'AC4: workers come from the holder items') if $a;
    }

    my $legacy = fresh_dir('ac4-legacy');
    $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR} = $legacy;
    local $BpContinuityLease::STATE_ROOT = $root;
    my $reason = BpContinuityLease::active_reason($legacy);
    ok(ref $reason eq 'HASH' && $reason->{arms} == 2,
       'AC4: active_reason still reports arms=2 (unchanged pre/post live_arms re-expression)');
}

# ===========================================================================
# AC5 -- a dying journal step never breaks the refresher
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac5sess');

    # AC5 asks for evidence that ONE tick still completes cleanly around the
    # dying journal step -- not for lease.pid to survive PAST daemon_loop's
    # return, which max_iterations-bounded runs always unlink via the
    # unconditional post-loop release() (existing, unrelated behavior). So a
    # custom log seam captures the event ORDER inside that single tick: TICK
    # (sync already ran) -> JOURNAL-ERROR (the eval around the journal step
    # swallowed the die) -> only THEN does the loop exit and RELEASE run.
    my @events;
    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1,
            spawn => sub { 9501 }, powershell_available => sub { 1 }, kill_pid => sub { },
            journal_opts => { probe_argv => sub { die "fixture: tick must die\n" } },
            log => sub { push @events, [ $_[0], $_[1] // '' ] },
        );
        1;
    };
    ok($rc, 'AC5: daemon_loop completes the iteration even though the journal step dies') or diag($@);

    my @tokens = map { $_->[0] } @events;
    my ($tick_i)  = grep { $tokens[$_] eq 'TICK' } 0 .. $#tokens;
    my ($jerr_i)  = grep { $tokens[$_] eq 'JOURNAL-ERROR' } 0 .. $#tokens;
    my ($rel_i)   = grep { $tokens[$_] eq 'RELEASE' } 0 .. $#tokens;
    ok(defined $tick_i, 'AC5: the tick still logs TICK (sync already ran) despite the journal step dying')
        or diag(join(' ', @tokens));
    ok(defined $jerr_i, 'AC5: lease.log gains a JOURNAL-ERROR line')
        or diag(join(' ', @tokens));
    ok(defined($tick_i) && defined($jerr_i) && defined($rel_i) && $tick_i < $jerr_i && $jerr_i < $rel_i,
        'AC5: the order is TICK, then JOURNAL-ERROR, then RELEASE -- the tick is intact, not cut short')
        or diag(join(' ', @tokens));

    my ($jerr_detail) = map { $_->[1] } grep { $_->[0] eq 'JOURNAL-ERROR' } @events;
    unlike($jerr_detail // '', qr/\n/, 'AC5: the JOURNAL-ERROR detail is a single line (no raw multi-line exception text)');
}

# ===========================================================================
# MUST-FIX 4 (review 05-review.md) -- an append that fails must not be
# silent forever. append_record itself must report failure (0), and tick()
# must surface that failure through the same JOURNAL-ERROR eval path as any
# other journal-step exception -- never just discard the return value.
# Simulated by making the journal PATH itself a directory, so any open for
# append fails deterministically without needing a real full disk or ACL.
# ===========================================================================
{
    my $dir = fresh_dir('mustfix4-direct');
    make_path("$dir/power-journal.jsonl"); # a directory sits where the file should be
    my $direct = PZ('append_record', $dir, { v => 1, kind => 'tick', seq => 1, ts => 1 });
    is($direct, 0, 'MUST-FIX 4: append_record returns 0 (never dies) when the journal path is unwritable');
}
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('mustfix4sess');
    make_path("$legacy/power-journal.jsonl"); # a directory, not a file -- append must fail

    my @events;
    my $rc = eval {
        BpContinuityLease::daemon_loop($legacy,
            max_iterations => 1, tick => 1,
            spawn => sub { 9502 }, powershell_available => sub { 1 }, kill_pid => sub { },
            journal_opts => { now => sub { 1758900400 }, probe_argv => probe_fixture(default_probe_data()) },
            log => sub { push @events, [ $_[0], $_[1] // '' ] },
        );
        1;
    };
    ok($rc, 'MUST-FIX 4: daemon_loop still completes the iteration when the journal cannot be written') or diag($@);

    my @tokens = map { $_->[0] } @events;
    ok((grep { $_ eq 'JOURNAL-ERROR' } @tokens),
        'MUST-FIX 4: a failed append_record (not just a dying probe) still produces a JOURNAL-ERROR line')
        or diag(join(' ', @tokens));
}

# ===========================================================================
# AC6 -- nothing armed writes nothing; non-windows platforms write nothing
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    # armed/ is empty (no arm() call at all)

    BpContinuityLease::daemon_loop($legacy, max_iterations => 1, tick => 1,
        spawn => sub { die "must not spawn -- nothing armed\n" });
    ok(!-e "$legacy/power-journal.jsonl", 'AC6: no journal file exists after a run with nothing armed');
}
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('ac6pre');
    BpContinuityLease::daemon_loop($legacy, max_iterations => 1, tick => 1,
        spawn => sub { 9601 }, powershell_available => sub { 1 }, kill_pid => sub { },
        journal_opts => { probe_argv => probe_fixture(default_probe_data()) });
    my $size_before = (-e "$legacy/power-journal.jsonl") ? (stat("$legacy/power-journal.jsonl"))[7] : undef;

    BpHook::disarm('ac6pre', actor => 'agent', reason => 'a b');
    BpContinuityLease::daemon_loop($legacy, max_iterations => 1, tick => 1,
        spawn => sub { die "must not spawn -- nothing armed now\n" });
    my $size_after = (-e "$legacy/power-journal.jsonl") ? (stat("$legacy/power-journal.jsonl"))[7] : undef;
    is($size_after, $size_before, 'AC6: with a pre-existing journal, its size is unchanged once nothing is armed');
}
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'posix';
    arm_one('ac6posix');
    BpContinuityLease::daemon_loop($legacy, max_iterations => 1, tick => 1);
    ok(!-e "$legacy/power-journal.jsonl", 'AC6: no journal file on the posix platform, even with a live arm');
}

# ===========================================================================
# AC7 -- rotation keeps the journal bounded and contiguous
# ===========================================================================
{
    my $dir = fresh_dir('ac7');
    local $BpPowerJournal::JOURNAL_MAX_BYTES = 4096;
    # With JOURNAL_MAX_BYTES=4096 and JOURNAL_KEEP=4, at most 5 files
    # (current + 4 kept generations) survive at once, so at most
    # 5 * (4096 / <line length>) records can remain live. Each fixture
    # line here is 48 bytes (canonical JSON: {"kind":"tick","seq":N,
    # "ts":M,"v":1}\n for a 3-4 digit seq), i.e. 85 lines/file, i.e. at
    # most 5*85=425 records can survive -- so writing only 300 (as this
    # test previously did) can never evict seq 1. Writing 500 forces at
    # least 500-425=75 records of eviction, genuinely exercising it.
    my $LINE_COUNT = 500;
    my $ok_all = 1;
    for my $seq (1 .. $LINE_COUNT) {
        my $rec = { v => 1, kind => 'tick', seq => $seq, ts => 1758900000 + $seq };
        my $r = PZ('append_record', $dir, $rec);
        $ok_all = 0 unless $r;
    }
    ok($ok_all, "AC7: $LINE_COUNT append_record calls all report success") or diag(explain_undef());

    my @files = grep { -f $_ } map { "$dir/power-journal.jsonl" . ($_ ? ".$_" : '') } (0 .. 4);
    SKIP: {
        skip 'AC7: no journal files produced -- append_record not implemented yet', 4 unless @files;
        ok(scalar(@files) <= 5, 'AC7: at most 5 files exist (current + 4 kept generations)');
        my $over = 0;
        for my $f (@files) { $over = 1 if (stat($f))[7] > 4096 }
        ok(!$over, 'AC7: every file is <= JOURNAL_MAX_BYTES');

        my @cur_lines = jsonl_lines("$dir/power-journal.jsonl");
        my $last = @cur_lines ? decode_or_undef($cur_lines[-1]) : undef;
        is($last->{seq}, $LINE_COUNT, "AC7: the last line of the current file has seq $LINE_COUNT") if ref $last eq 'HASH';

        my @all_seqs;
        for my $g (reverse(1 .. 4), 0) {
            my $f = $g ? "$dir/power-journal.jsonl.$g" : "$dir/power-journal.jsonl";
            next unless -f $f;
            push @all_seqs, map { my $d = decode_or_undef($_); ref $d eq 'HASH' ? $d->{seq} : () } jsonl_lines($f);
        }
        my $contiguous = 1;
        for my $i (1 .. $#all_seqs) { $contiguous = 0 if $all_seqs[$i] != $all_seqs[$i - 1] + 1 }
        ok($contiguous && $all_seqs[-1] == $LINE_COUNT,
            "AC7: seqs across .4 .. current are strictly increasing and contiguous up to $LINE_COUNT")
            or diag("seqs: @all_seqs");
        ok(!(grep { $_ == 1 } @all_seqs), 'AC7: seq 1 is gone');
    }
}

# ===========================================================================
# AC8 -- build_timeline: journal spans, events, transcript, flags
# ===========================================================================
{
    my $t0 = 1758900000;
    my @journal_recs;
    my $seq = 1;
    # 60s ticks up to t0+300, then a 1800s hole, then resume with a 100s gap
    # (no flag), then three DC runs with requests, the last with requests [].
    for my $ts ($t0, $t0 + 60, $t0 + 120, $t0 + 180, $t0 + 240, $t0 + 300) {
        push @journal_recs, { v => 1, kind => 'tick', ts => $ts, seq => $seq++, refresher_pid => 111,
            tick_s => 60, power_source => 'ac', battery_pct => 90, plan_guid => 'g1', plan_name => 'Balanced',
            display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown',
            helpers => [], sessions => [], probe => { status => 'ok', ms => 10, age_s => 0, error => '' } };
    }
    my $after_hole = $t0 + 300 + 1800;
    push @journal_recs, { v => 1, kind => 'tick', ts => $after_hole, seq => $seq++, refresher_pid => 111,
        tick_s => 60, power_source => 'ac', battery_pct => 88, plan_guid => 'g1', plan_name => 'Balanced',
        display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown',
        helpers => [], sessions => [], probe => { status => 'ok', ms => 10, age_s => 0, error => '' } };
    my $after_100 = $after_hole + 100;
    push @journal_recs, { v => 1, kind => 'tick', ts => $after_100, seq => $seq++, refresher_pid => 111,
        tick_s => 60, power_source => 'ac', battery_pct => 87, plan_guid => 'g1', plan_name => 'Balanced',
        display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown',
        helpers => [], sessions => [], probe => { status => 'ok', ms => 10, age_s => 0, error => '' } };

    # Each DC run below is built from ticks spaced exactly 60s apart (== the
    # fixture's own tick_s), so the GAP flag's ">2 ticks" rule (>120s) is
    # never spuriously tripped inside a run -- only the one deliberate
    # 1800s hole above should ever produce a GAP.
    my $dc_start = $after_100 + 60;
    my $dc_requests = [ { source => 'continuity-pidfile', winpid => 4242, alive => 1, requests => [ 'EXECUTION' ],
                          owner_winpid => 111, owner_desc => 'x', last => 'x', last_at => 'x', pidfile => 'x' } ];
    # Run 1: 480s, held requests throughout -- qualifies for BATTERY-CUTOFF.
    for my $ts (map { $dc_start + 60 * $_ } 0 .. 8) {
        push @journal_recs, { v => 1, kind => 'tick', ts => $ts, seq => $seq++, refresher_pid => 111,
            tick_s => 60, power_source => 'dc', battery_pct => 60, plan_guid => 'g1', plan_name => 'Balanced',
            display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown',
            helpers => $dc_requests, sessions => [], probe => { status => 'ok', ms => 10, age_s => 0, error => '' } };
    }
    # Run 2: 240s, held requests throughout -- too short to cut off.
    my $dc2_start = $dc_start + 60 * 8 + 60;
    for my $ts (map { $dc2_start + 60 * $_ } 0 .. 4) {
        push @journal_recs, { v => 1, kind => 'tick', ts => $ts, seq => $seq++, refresher_pid => 111,
            tick_s => 60, power_source => 'dc', battery_pct => 40, plan_guid => 'g1', plan_name => 'Balanced',
            display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown',
            helpers => $dc_requests, sessions => [], probe => { status => 'ok', ms => 10, age_s => 0, error => '' } };
    }
    # Run 3: 480s, but requests [] throughout -- long enough, never held.
    my $dc3_start = $dc2_start + 60 * 4 + 60;
    for my $ts (map { $dc3_start + 60 * $_ } 0 .. 8) {
        push @journal_recs, { v => 1, kind => 'tick', ts => $ts, seq => $seq++, refresher_pid => 111,
            tick_s => 60, power_source => 'dc', battery_pct => 20, plan_guid => 'g1', plan_name => 'Balanced',
            display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown',
            helpers => [], sessions => [], probe => { status => 'ok', ms => 10, age_s => 0, error => '' } };
    }
    # A deliberately truncated final line (a hard freeze mid-write) -- not
    # decoded as a real record. jsonl_lines/decode_or_undef path exercised
    # directly against the encoded-then-truncated JSON text.
    my $truncated_line = substr(JSON::PP->new->utf8->canonical->encode($journal_recs[0]), 0, 20);

    # Real shape (M0e / review MUST-FIX 3, measured on this host): the
    # rendered Message is multi-line, with a blank line 2 and the actual
    # "Reason:" text on line 3 -- never on line 1. A reader that keeps only
    # the first line (as the pre-fix-batch code did) can never see "lid" or
    # "button" here, so LID-OR-BUTTON could never fire on a real event.
    my $events = [
        { xml => event_xml(42,  $t0 + 90,  'Kernel-Power'),
          message => "The system is entering sleep.\n\nReason: Lid Close." },
        { xml => event_xml(506, $dc_start - 10, 'Kernel-Power'),
          message => "The system is entering connected standby.\n\nReason: Idle Timeout." },
        { xml => event_xml(507, $t0 + 100, 'Kernel-Power'), message => 'The system is exiting connected standby.' },
        { xml => event_xml(107, $t0 + 110, 'Kernel-Power'), message => 'The system has resumed from sleep.' },
        { xml => event_xml(105, $t0 + 50, 'Kernel-Power'), message => 'The system power source has changed.' },
        { xml => event_xml(41,  $t0 + 5, 'Kernel-Power'), message => 'The system has rebooted without cleanly shutting down first.' },
        { xml => event_xml(6008, $t0 + 3, 'EventLog'), message => 'The previous system shutdown was unexpected.' },
        { xml => event_xml(9999, $t0 + 2, 'Microsoft-Windows-Other'), message => 'not tracked' },
    ];

    my $transcript = tempfile_named();
    write_lines($transcript,
        JSON::PP->new->encode({ timestamp => epoch_to_iso($t0 + 10) }),
        JSON::PP->new->encode({ timestamp => epoch_to_iso($t0 + 60) }),
        JSON::PP->new->encode({ timestamp => epoch_to_iso($t0 + 500) }), # >300s from the previous point
    );

    my $entries = PZ('build_timeline',
        journal_lines => [ @journal_recs, { __truncated_raw => $truncated_line } ],
        events        => $events,
        transcript    => $transcript,
        since_ms      => ($t0 - 3600) * 1000,
        until_ms      => ($dc3_start + 600) * 1000,
    );
    ok(ref $entries eq 'ARRAY', 'AC8: build_timeline returns an arrayref') or diag(explain_undef());

    SKIP: {
        skip 'AC8: build_timeline not implemented yet', 8 unless ref $entries eq 'ARRAY';
        my @t_ms = map { $_->{t_ms} } @$entries;
        my $nondecreasing = 1;
        for my $i (1 .. $#t_ms) { $nondecreasing = 0 if $t_ms[$i] < $t_ms[$i - 1] }
        ok($nondecreasing, 'AC8: entries are non-decreasing by t_ms');

        my @gaps = grep { $_->{kind} eq 'flag' && $_->{flag} eq 'GAP' } @$entries;
        is(scalar(@gaps), 1, 'AC8: exactly one GAP flag');
        if (@gaps) {
            is($gaps[0]{from_ms}, $t0 * 1000 + 300000, 'AC8: GAP from_ms is the last tick before the hole') or diag(explain_gap($gaps[0]));
            is($gaps[0]{to_ms}, $after_hole * 1000, 'AC8: GAP to_ms is the first tick after the hole');
        }

        my @sleeps = grep { $_->{kind} eq 'flag' && $_->{flag} eq 'SLEEP' } @$entries;
        is(scalar(@sleeps), 1, 'AC8: exactly one SLEEP flag, at the 42 event');

        my @standbys = grep { $_->{kind} eq 'flag' && $_->{flag} eq 'STANDBY' } @$entries;
        is(scalar(@standbys), 1, 'AC8: exactly one STANDBY flag, at the 506 event');

        # MUST-FIX 3 (review): the real message is multi-line with the
        # "Reason:" text on line 3 (see the events fixture above). A reader
        # that only looks at the first line can never see "Lid" here, so
        # this must fire from the WHOLE message, not just its first line.
        # The 506 event's own reason is "Idle Timeout" (no lid/button), so
        # exactly one LID-OR-BUTTON must fire, at the 42's own time.
        my @lidbtn = grep { $_->{kind} eq 'flag' && $_->{flag} eq 'LID-OR-BUTTON' } @$entries;
        is(scalar(@lidbtn), 1,
            'MUST-FIX 3: exactly one LID-OR-BUTTON fires, from the 42 whose Reason line (line 3) says "Lid"')
            or diag('lidbtn: ' . JSON::PP->new->encode(\@lidbtn));
        is($lidbtn[0]{t_ms}, ($t0 + 90) * 1000,
            'MUST-FIX 3: LID-OR-BUTTON sits at the 42 event\'s own time, not the 506\'s') if @lidbtn;

        my @cutoffs = grep { $_->{kind} eq 'flag' && $_->{flag} eq 'BATTERY-CUTOFF' } @$entries;
        is(scalar(@cutoffs), 1, 'AC8: exactly one BATTERY-CUTOFF (the 480s runs qualify, the 240s run does not, and the requests-[] run does not)');
        is($cutoffs[0]{t_ms}, ($dc_start + 300) * 1000, 'AC8: BATTERY-CUTOFF fires at the run start + 300s') if @cutoffs;

        my @unclean = grep { $_->{kind} eq 'flag' && $_->{flag} eq 'UNCLEAN-SHUTDOWN' } @$entries;
        is(scalar(@unclean), 2, 'AC8: UNCLEAN-SHUTDOWN for both the 41 and the 6008');

        ok(!(grep { $_->{kind} eq 'event' && ($_->{id} // -1) == 9999 } @$entries),
            'AC8: the foreign-provider event is absent from the timeline');

        my @transcript_spans = grep { $_->{kind} eq 'transcript' } @$entries;
        ok(scalar(@transcript_spans) == 2,
            'AC8: the transcript coalesces into two spans per the 300s rule (t0+10/t0+60 together, t0+500 alone)')
            or diag('spans: ' . scalar(@transcript_spans));
    }
}

# ===========================================================================
# MUST-FIX 2 (review 05-review.md) -- a journal span that BEGAN before the
# window must still be shown, clipped to the window, not dropped whole. A
# steady 24h+ unattended run reported with the default 24h --since window
# must show journal coverage for every hour of that window: the run started
# at some t0 well before "now", so the ticks nearest "now - 24h" all belong
# to ONE long span that began hours before the window opened. If spans are
# windowed by their start time (from_ms) instead of by overlap, that whole
# span -- and therefore every hour of a steady run -- is dropped, which
# reads exactly like "the machine was not running" (Decision 4's absence-
# misread), for precisely the use case (Decision 13) the journal exists for.
# ===========================================================================
{
    my $t0 = 1758800000;                 # run start, well before the window
    my $window_hours = 26;               # the run is 26h+ of steady ticks
    my @recs;
    my $seq = 1;
    for my $i (0 .. $window_hours * 60) { # one tick per minute, 60s apart
        push @recs, { v => 1, kind => 'tick', ts => $t0 + 60 * $i, seq => $seq++, refresher_pid => 111,
            tick_s => 60, power_source => 'ac', battery_pct => 90, plan_guid => 'g1', plan_name => 'Balanced',
            display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown',
            helpers => [], sessions => [], probe => { status => 'ok', ms => 10, age_s => 0, error => '' } };
    }
    my $run_end_ts = $recs[-1]{ts};
    my $since_ms = ($run_end_ts - 24 * 3600) * 1000;   # default-shaped "--since 24h"
    my $until_ms = $run_end_ts * 1000;

    my $entries = PZ('build_timeline',
        journal_lines => \@recs, events => [], transcript => undef,
        since_ms => $since_ms, until_ms => $until_ms,
    );
    ok(ref $entries eq 'ARRAY', 'MUST-FIX 2: build_timeline returns an arrayref over the steady 26h run')
        or diag(explain_undef());
    SKIP: {
        skip 'MUST-FIX 2: build_timeline not implemented yet', 4 unless ref $entries eq 'ARRAY';
        my @spans = grep { $_->{kind} eq 'journal' } @$entries;
        ok(scalar(@spans) >= 1,
            'MUST-FIX 2: at least one journal span is present -- the run is not reported as empty')
            or diag('entries: ' . scalar(@$entries));

        # The whole 26h run is one unbroken key-span (nothing in its key
        # changes), so there must be EXACTLY one span, and it must be
        # CLIPPED to the window's start, not dropped because it began
        # hours before "--since".
        is(scalar(@spans), 1,
            'MUST-FIX 2: the steady run is exactly one span (not silently split, not dropped)')
            or diag('spans: ' . JSON::PP->new->encode(\@spans));
        if (@spans) {
            is($spans[0]{from_ms}, $since_ms,
                'MUST-FIX 2: the span is CLIPPED to since_ms, not shown starting at its true (pre-window) start');
            is($spans[0]{to_ms}, $until_ms,
                'MUST-FIX 2: the span extends through the end of the window');
        }
    }
}

sub explain_gap { my ($g) = @_; return JSON::PP->new->encode($g) }

sub tempfile_named {
    my (undef, $path) = tempfile();
    return $path;
}

sub epoch_to_iso {
    my ($epoch) = @_;
    my @t = gmtime($epoch);
    return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# event_xml($id, $epoch, $provider) -- minimal Get-WinEvent ToXml() shape,
# enough for parse_event_xml (spec 2.6) to extract Provider/@Name, EventID
# and TimeCreated/@SystemTime.
sub event_xml {
    my ($id, $epoch, $provider) = @_;
    my $iso = epoch_to_iso($epoch);
    return qq{<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System>}
         . qq{<Provider Name="$provider"/><EventID>$id</EventID>}
         . qq{<TimeCreated SystemTime="$iso"/></System><EventData></EventData></Event>};
}

# event_xml_positional($id, $epoch, $provider, @values) -- a real-shaped
# ToXml() fixture for events whose <EventData> children are POSITIONAL
# <Data> elements with NO Name attribute (measured on a real host's 6008,
# M0 2026-09-26: "the real 6008 event's <Data> children have NO Name
# attribute"). @values are synthetic-only stand-ins for the fields Windows
# actually ships there (the previous shutdown time text and similar).
sub event_xml_positional {
    my ($id, $epoch, $provider, @values) = @_;
    my $iso = epoch_to_iso($epoch);
    my $data = join('', map { my $v = $_; $v =~ s/&/&amp;/g; qq{<Data>$v</Data>} } @values);
    return qq{<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System>}
         . qq{<Provider Name="$provider"/><EventID>$id</EventID>}
         . qq{<TimeCreated SystemTime="$iso"/></System><EventData>$data</EventData></Event>};
}

# flatten_values($x) -- every scalar leaf reachable from a hashref/arrayref/
# scalar, for asserting "the value is readable somewhere in the parsed
# structure" without assuming a specific positional-Data schema (indexed
# keys vs a bare array) that the spec does not pin down.
sub flatten_values {
    my ($x) = @_;
    return () unless defined $x;
    if (ref $x eq 'HASH')  { return map { flatten_values($_) } values %$x }
    if (ref $x eq 'ARRAY') { return map { flatten_values($_) } @$x }
    return ($x);
}

# ===========================================================================
# AC8 (real-shaped positional Data) -- a genuine 6008 fixture, built the way
# Windows actually emits it (unnamed, positional <Data> children -- see M0's
# finding quoted above the event_xml_positional() sub), still produces an
# UNCLEAN-SHUTDOWN timeline entry at the event's own time, and the values
# inside those positional <Data> children are still readable from the
# parsed event/entry -- not silently dropped because they lack @Name.
# ===========================================================================
{
    my $pos_epoch = 1758950000;
    my $prev_shutdown_text = '9/26/2026 3:14:00 AM';   # synthetic, not host data
    my $unexpected_text    = 'unexpected';              # synthetic, not host data
    my $pos_event = {
        xml     => event_xml_positional(6008, $pos_epoch, 'EventLog', $prev_shutdown_text, $unexpected_text),
        message => 'The previous system shutdown was unexpected.',
    };

    my $rec = { v => 1, kind => 'tick', ts => $pos_epoch, seq => 1, refresher_pid => 222,
        tick_s => 60, power_source => 'ac', battery_pct => 91, plan_guid => 'g1', plan_name => 'Balanced',
        display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown',
        helpers => [], sessions => [], probe => { status => 'ok', ms => 5, age_s => 0, error => '' } };

    my $entries = PZ('build_timeline',
        journal_lines => [ $rec ],
        events        => [ $pos_event ],
        transcript    => undef,
        since_ms      => ($pos_epoch - 60) * 1000,
        until_ms      => ($pos_epoch + 60) * 1000,
    );
    ok(ref $entries eq 'ARRAY', 'AC8 (positional Data): build_timeline returns an arrayref for the positional-6008 fixture')
        or diag(explain_undef());

    SKIP: {
        skip 'AC8 (positional Data): build_timeline not implemented yet, or parse_event_xml does not yet handle positional Data', 3
            unless ref $entries eq 'ARRAY';

        my @unclean = grep { $_->{kind} eq 'flag' && $_->{flag} eq 'UNCLEAN-SHUTDOWN' } @$entries;
        is(scalar(@unclean), 1, 'AC8 (positional Data): exactly one UNCLEAN-SHUTDOWN entry for the real-shaped 6008');
        is($unclean[0]{t_ms}, $pos_epoch * 1000, 'AC8 (positional Data): it sits at the 6008 event\'s own time')
            if @unclean;

        my @leaves = @unclean ? flatten_values($unclean[0]) : ();
        ok((grep { defined && index($_, $prev_shutdown_text) >= 0 } @leaves),
            'AC8 (positional Data): the previous-shutdown-time text from the unnamed <Data> children is readable somewhere in the entry')
            or diag('leaves: ' . join('|', grep { defined } @leaves));
    }
}

# ===========================================================================
# AC9 -- CLI: bp-power-journal.pl report
# ===========================================================================
{
    my $CLI = "$S/bp-power-journal.pl";
    ok(-f $CLI, 'AC9 sanity: bp-power-journal.pl exists in the write set') or diag(explain_undef());

    my $dir = fresh_dir('ac9');
    my $rec = { v => 1, kind => 'tick', ts => 1758900000, seq => 1, refresher_pid => 1, tick_s => 60,
        power_source => 'ac', battery_pct => 90, plan_guid => 'g', plan_name => 'Balanced', display => 'on',
        display_basis => 'kernel-power-506-507', display_at => 'unknown', helpers => [], sessions => [],
        probe => { status => 'ok', ms => 1, age_s => 0, error => '' } };
    PZ('append_record', $dir, $rec);

    my $events_file = tempfile_named();
    write_lines($events_file, JSON::PP->new->canonical->encode([
        { xml => event_xml(42, 1758900050, 'Kernel-Power'), message => 'lid closed' },
        { xml => event_xml(6008, 1758900005, 'EventLog'), message => 'unexpected shutdown' },
    ]));

    my $transcript = tempfile_named();
    write_lines($transcript, JSON::PP->new->encode({ timestamp => epoch_to_iso(1758900010) }));

    SKIP: {
        skip 'AC9: bp-power-journal.pl does not exist yet', 8 unless -f $CLI;
        my ($out_json, $err_json, $rc_json) = run_cli($CLI,
            'report', '--dir', $dir, '--events-file', $events_file, '--transcript', $transcript,
            '--since', 1758899000, '--until', 1758900200, '--format', 'json');
        is($rc_json, 0, 'AC9: report --format json exits 0') or diag("stderr: $err_json");
        my @jlines = grep { length } split /\n/, $out_json;
        my $decoded_all = 1;
        for my $l (@jlines) { $decoded_all = 0 unless decode_or_undef($l) }
        ok($decoded_all, 'AC9: every stdout line of --format json decodes as JSON');

        my ($out_text, $err_text, $rc_text) = run_cli($CLI,
            'report', '--dir', $dir, '--events-file', $events_file, '--transcript', $transcript,
            '--since', 1758899000, '--until', 1758900200, '--format', 'text');
        is($rc_text, 0, 'AC9: report --format text exits 0') or diag("stderr: $err_text");
        like($out_text, qr/!!\s+SLEEP/, 'AC9 text: contains "!! SLEEP"');
        like($out_text, qr/!!\s+UNCLEAN-SHUTDOWN/, 'AC9 text: contains a flag line for the unclean shutdown');

        my (undef, undef, $rc_badtime) = run_cli($CLI, 'report', '--dir', $dir, '--since', 'notatime', '--until', 'z');
        is($rc_badtime, 2, 'AC9: an unparseable --since exits 2');

        my (undef, undef, $rc_order) = run_cli($CLI, 'report', '--dir', $dir, '--since', 1758900200, '--until', 1758899000);
        is($rc_order, 2, 'AC9: --since later than --until exits 2');

        my (undef, undef, $rc_nosuch) = run_cli($CLI, 'report', '--dir', $dir, '--session', 'nosuchsession');
        is($rc_nosuch, 1, 'AC9: --session with no resolvable transcript exits 1');
    }

    # Off Windows there is no System event log: the report says so and still
    # renders the journal, instead of spawning a powershell.exe that is not
    # there and calling the log unreadable.
    SKIP: {
        skip 'AC9 (non-Windows): the live System log reader is real on Windows', 3
            if $^O =~ /^(MSWin32|msys|cygwin)$/;
        my ($out, $err, $rc) = run_cli($CLI, 'report', '--dir', $dir,
            '--since', 1758899000, '--until', 1758900200, '--format', 'text');
        is($rc, 0, 'AC9 (non-Windows): a live-events report exits 0') or diag("stderr: $err");
        like($out, qr/the Windows System event log does not exist on \Q$^O\E/,
            'AC9 (non-Windows): the note names the real reason');
        unlike($out, qr/failed to spawn|exited nonzero/, 'AC9 (non-Windows): no powershell.exe was attempted');
    }
}

# ===========================================================================
# MUST-FIX 5 (review 05-review.md) -- an empty System-log result must be
# reported as an empty list, never as "System log unreadable". PowerShell's
# `@() | ConvertTo-Json` (no -InputObject) really does emit nothing at all
# (measured), so the events-file fixture here is a literal empty JSON array
# "[]", exactly what a correctly-written probe emits for a quiet window --
# never an empty/missing file, which would be a different (and real)
# unreadable case.
# ===========================================================================
{
    my $CLI = "$S/bp-power-journal.pl";
    my $dir = fresh_dir('mustfix5');
    PZ('append_record', $dir, { v => 1, kind => 'tick', ts => 1758900000, seq => 1, refresher_pid => 1,
        tick_s => 60, power_source => 'ac', battery_pct => 90, plan_guid => 'g', plan_name => 'Balanced',
        display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown', helpers => [],
        sessions => [], probe => { status => 'ok', ms => 1, age_s => 0, error => '' } });

    my $empty_events_file = tempfile_named();
    write_lines($empty_events_file, '[]');

    SKIP: {
        skip 'MUST-FIX 5: bp-power-journal.pl does not exist yet', 3 unless -f $CLI;
        my ($out_text, $err_text, $rc_text) = run_cli($CLI,
            'report', '--dir', $dir, '--events-file', $empty_events_file,
            '--since', 1758899000, '--until', 1758900200, '--format', 'text');
        is($rc_text, 0, 'MUST-FIX 5: report exits 0 with an empty (but present) events array') or diag("stderr: $err_text");
        unlike($out_text, qr/unreadable/i,
            'MUST-FIX 5: an empty events array is never reported as "System log unreadable"')
            or diag($out_text);

        my ($out_json, undef, $rc_json) = run_cli($CLI,
            'report', '--dir', $dir, '--events-file', $empty_events_file,
            '--since', 1758899000, '--until', 1758900200, '--format', 'json');
        my @jlines = grep { length } split /\n/, $out_json;
        my $has_unreadable_note = grep {
            my $d = decode_or_undef($_); ref $d eq 'HASH' && ($d->{note} // '') =~ /unreadable/i
        } @jlines;
        ok($rc_json == 0 && !$has_unreadable_note,
            'MUST-FIX 5: --format json carries no "unreadable" note for a genuinely empty events array');
    }
}

# ===========================================================================
# SHOULD-FIX (review): text/json entry checks the original AC9 fixture never
# exercised. The AC9 fixture above has no GAP and no DC run, so "the same
# flags as AC8" was never actually checked for GAP/BATTERY-CUTOFF, and the
# text format was never checked for "!! GAP"/"!! BATTERY-CUTOFF" lines. This
# fixture adds a real gap (a >2-tick hole) and a qualifying DC-held run.
# ===========================================================================
{
    my $CLI = "$S/bp-power-journal.pl";
    my $dir = fresh_dir('shouldfix-flags');
    my $t0 = 1758920000;
    my $seq = 1;
    for my $ts ($t0, $t0 + 60, $t0 + 120) {
        PZ('append_record', $dir, { v => 1, kind => 'tick', ts => $ts, seq => $seq++, refresher_pid => 1,
            tick_s => 60, power_source => 'ac', battery_pct => 90, plan_guid => 'g', plan_name => 'Balanced',
            display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown', helpers => [],
            sessions => [], probe => { status => 'ok', ms => 1, age_s => 0, error => '' } });
    }
    my $after_hole = $t0 + 120 + 600; # > 2 ticks (120s) later -- a real GAP
    my $dc_requests = [ { source => 'continuity-pidfile', winpid => 4242, alive => 1, requests => [ 'EXECUTION' ],
                          owner_winpid => 1, owner_desc => 'x', last => 'x', last_at => 'x', pidfile => 'x' } ];
    for my $i (0 .. 8) { # 9 ticks * 60s = 480s, held throughout -- qualifies for BATTERY-CUTOFF
        PZ('append_record', $dir, { v => 1, kind => 'tick', ts => $after_hole + 60 * $i, seq => $seq++, refresher_pid => 1,
            tick_s => 60, power_source => 'dc', battery_pct => 50, plan_guid => 'g', plan_name => 'Balanced',
            display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown', helpers => $dc_requests,
            sessions => [], probe => { status => 'ok', ms => 1, age_s => 0, error => '' } });
    }
    my $until_ts = $after_hole + 60 * 8 + 60;

    SKIP: {
        skip 'SHOULD-FIX (flags): bp-power-journal.pl does not exist yet', 4 unless -f $CLI;
        my ($out_text, $err_text, $rc_text) = run_cli($CLI,
            'report', '--dir', $dir, '--no-events', '--since', $t0 - 60, '--until', $until_ts, '--format', 'text');
        is($rc_text, 0, 'SHOULD-FIX (flags): report exits 0 over the gap+cutoff fixture') or diag("stderr: $err_text");
        like($out_text, qr/!!\s+GAP/, 'SHOULD-FIX (flags): text output contains "!! GAP"') or diag($out_text);
        like($out_text, qr/!!\s+BATTERY-CUTOFF/, 'SHOULD-FIX (flags): text output contains "!! BATTERY-CUTOFF"')
            or diag($out_text);

        my ($out_json, undef, $rc_json) = run_cli($CLI,
            'report', '--dir', $dir, '--no-events', '--since', $t0 - 60, '--until', $until_ts, '--format', 'json');
        my @jlines = grep { length } split /\n/, $out_json;
        my @flags = map { my $d = decode_or_undef($_); (ref $d eq 'HASH' && $d->{kind} eq 'flag') ? $d->{flag} : () } @jlines;
        ok($rc_json == 0 && (grep { $_ eq 'GAP' } @flags) && (grep { $_ eq 'BATTERY-CUTOFF' } @flags),
            'SHOULD-FIX (flags): --format json carries the same GAP and BATTERY-CUTOFF flags as the text output')
            or diag('flags: ' . join(',', @flags));
    }
}

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

# ===========================================================================
# AC10 -- seams: the .t guard, refusal notes, and forbidden calls
# ===========================================================================
{
    is(PZ('probe_argv'), undef, 'AC10: probe_argv() returns undef when $0 ends in .t');

    my $dir = fresh_dir('ac10');
    my $rec = PZ('build_tick_record', $dir, tick_s => 60);
    SKIP: {
        skip 'AC10: build_tick_record not implemented yet', 1 unless ref $rec eq 'HASH';
        is($rec->{probe}{status}, 'skipped', 'AC10: a tick with default seams writes probe.status "skipped" (no spawn)');
    }

    if (-f "$S/BpPowerJournal.pm") {
        my $src = slurp("$S/BpPowerJournal.pm") // '';
        unlike($src, qr/NtSuspendProcess/, 'AC10: BpPowerJournal.pm never names NtSuspendProcess');
        unlike($src, qr/SuspendThread/, 'AC10: BpPowerJournal.pm never names SuspendThread');
        unlike($src, qr/kill\(\s*['"]STOP['"]/, 'AC10: BpPowerJournal.pm never calls kill(\'STOP\'...)');
        unlike($src, qr/kill\s+['"]STOP['"]/, 'AC10: BpPowerJournal.pm never calls kill \'STOP\'...');
        unlike($src, qr/-Verb\s+RunAs/, 'AC10: BpPowerJournal.pm never elevates via -Verb RunAs');
        unlike($src, qr{powercfg\s*/requests}, 'AC10: BpPowerJournal.pm never calls powercfg /requests');
        unlike($src, qr/Start-Process/, 'AC10: BpPowerJournal.pm never calls Start-Process');
    } else {
        fail('AC10: BpPowerJournal.pm source scan skipped -- the module does not exist yet');
    }

    my $legacy_home = fresh_home();
    local $ENV{HOME} = $legacy_home;
    local $ENV{USERPROFILE} = $legacy_home;
    delete local $ENV{CCPRAXIS_CONTINUITY_ACTIVE_DIR};
    like(BpContinuityLease::legacy_dir(), qr/^\Q$legacy_home\E/,
        'AC10: legacy_dir() resolves under this test\'s own tempdir, never the real HOME');
}

# ===========================================================================
# AC11 -- the probe never blocks the tick, and the rate limit holds
# ===========================================================================
{
    my $dir = fresh_dir('ac11-hang');
    my $pidfile = "$dir/probe-child.pid";
    my $hang_code = qq{open(my \$f,'>','$pidfile') or die \$!; print \$f "\$\$"; close \$f; sleep 60;};

    my $t_start = time();
    my $rec = PZ('tick', $dir,
        now => sub { 1758900000 }, tick_s => 60, probe_timeout => 2,
        probe_argv => sub { [ $^X, '-e', $hang_code ] }, cache => {});
    my $elapsed = time() - $t_start;

    ok(defined $rec, 'AC11: tick() returns rather than hanging') or diag(explain_undef());
    SKIP: {
        skip 'AC11: tick not implemented yet', 4 unless defined $rec;
        ok($elapsed <= 6, "AC11: tick() returned within 6s wall (took ${elapsed}s)");
        is($rec->{probe}{status}, 'timeout', 'AC11: probe.status is "timeout"');
        my $all_unknown = 1;
        for my $k (qw(power_source battery_pct plan_guid plan_name display)) {
            $all_unknown = 0 unless ($rec->{$k} // '') eq 'unknown';
        }
        ok($all_unknown, 'AC11: all probe fields are "unknown" after a timeout');

        my $child_pid = do {
            my $deadline = time() + 3;
            my $p;
            while (time() < $deadline) { $p = -f $pidfile ? do { open(my $f, '<', $pidfile); my $l = <$f>; close $f; $l } : undef; last if $p; sleep(0.1) }
            $p;
        };
        SKIP: {
            skip 'AC11: could not read the hung child\'s recorded pid', 1 unless defined $child_pid && $child_pid =~ /^\d+$/;
            ok(!kill(0, $child_pid), 'AC11: after the timeout, the hung child is no longer alive (kill(0,...) is false)');
        }
    }
}
{
    my $dir = fresh_dir('ac11-rate');
    my $count_file = "$dir/spawn-count";
    # Build a real probe fixture that ALSO increments the counter file, so
    # we can tell whether a real spawn happened without depending on any
    # internal cache implementation detail.
    my $probe_data = default_probe_data();
    my $json = JSON::PP->new->utf8->canonical->encode($probe_data);
    my $b64  = encode_base64($json, '');
    my $code = qq{open(my \$f,'>>','$count_file'); print \$f "x"; close \$f; print "$b64";};
    my $counting_probe_argv = sub { [ $^X, '-e', $code ] };

    my $cache = {};
    my $r1 = PZ('tick', $dir, now => sub { 1758900000 }, tick_s => 60, probe_argv => $counting_probe_argv, cache => $cache);
    my $r2 = PZ('tick', $dir, now => sub { 1758900030 }, tick_s => 60, probe_argv => $counting_probe_argv, cache => $cache);
    ok(defined $r1 && defined $r2, 'AC11 rate: two tick() calls 30s apart both return') or diag(explain_undef());
    SKIP: {
        skip 'AC11 rate: tick not implemented yet', 3 unless defined $r1 && defined $r2;
        my $spawns = -f $count_file ? length(slurp($count_file) // '') : 0;
        is($spawns, 1, 'AC11 rate: the probe is actually spawned exactly once across two ticks 30s apart');
        is($r2->{probe}{status}, 'cached', 'AC11 rate: the second line has probe.status "cached"');
        is($r2->{probe}{age_s}, 30, 'AC11 rate: age_s is 30, the true age of the cached data');
    }

    my $r3 = PZ('tick', $dir, now => sub { 1758900030 + 200 }, tick_s => 60,
        probe_argv => sub { [ $^X, '-e', 'exit 9;' ] }, cache => $cache);
    SKIP: {
        skip 'AC11 rate: tick not implemented yet', 1 unless defined $r3;
        is($r3->{power_source}, 'unknown',
            'AC11 rate: 200s later (> 3x the 55s interval) with a now-failing probe, fields are "unknown", not stale');
    }
}

# ===========================================================================
# AC12 -- non-ASCII directory name, non-ASCII plan name
# ===========================================================================
{
    my $base = tempdir(CLEANUP => 1);
    # SHOULD-FIX 3 (review): use the REAL UTF-8 bytes of "e"-acute (C3 A9),
    # not the single Latin-1 codepoint U+00E9. HOME/USERPROFILE on a real
    # Windows host carry the actual UTF-8 byte sequence, never a Latin-1
    # byte, so a fixture built from \x{e9} never exercises the decode-once
    # path this package's Character discipline rule (spec 2.1) actually
    # protects against.
    (my $unicode_dir = "$base/Andr\xc3\xa9-power") =~ s{\\}{/}g;
    make_path($unicode_dir);
    ok(-d $unicode_dir, 'AC12 setup: a tempdir containing non-ASCII bytes in its name exists');

    local $BpPowerJournal::JOURNAL_MAX_BYTES = 2048;

    # keepawake.pid/log under the non-ASCII dir, so the continuity-pidfile
    # path (SHOULD-FIX 3: "the helper's log path bytes intact... is not
    # asserted") is actually exercised, not just the process-scan path.
    open(my $pf, '>', "$unicode_dir/keepawake.pid") or die $!;
    print {$pf} "7777\n";
    close $pf;
    write_lines("$unicode_dir/keepawake.log",
        '2026-09-24 03:20:00 pid=7777 ASSERTED flags=ES_CONTINUOUS|ES_SYSTEM_REQUIRED',
        '2026-09-24 03:20:01 pid=7777 POWER-REQUEST-CREATED',
    );

    # plan_name comes from the probe's already-decoded JSON, which is why
    # this uses the wide character \x{ed} (a real Perl character string,
    # per spec 2.1: "Strings from the probe ... are already characters.
    # They are never re-encoded") while the DIRECTORY name above uses raw
    # UTF-8 bytes -- two different sources with two different disciplines.
    my $probe = default_probe_data(
        plan => { raw => "Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Trabalho cont\x{ed}nuo)\n" },
        ka   => [ { pid => 7777, cmd => "powershell.exe -File keep-awake.ps1 -PidFile $unicode_dir/keepawake.pid -LogFile $unicode_dir/keepawake.log" } ],
    );

    my $rec;
    for my $i (1 .. 3) {
        $rec = PZ('tick', $unicode_dir, now => sub { 1758900000 + $i }, tick_s => 60,
            probe_argv => probe_fixture($probe), cache => {});
    }
    ok(defined $rec, 'AC12: tick() succeeds against a non-ASCII directory') or diag(explain_undef());

    SKIP: {
        skip 'AC12: tick not implemented yet', 6 unless defined $rec;
        is($rec->{plan_name}, "Trabalho cont\x{ed}nuo", 'AC12: plan_name preserves the non-ASCII character');

        SKIP: {
            skip 'AC12: helpers_from_state not populating this tick record', 1
                unless ref $rec->{helpers} eq 'ARRAY';
            my ($h) = grep { $_->{winpid} eq 7777 } @{ $rec->{helpers} };
            ok($h && index($h->{pidfile} // '', "Andr\x{e9}-power") >= 0,
                'AC12: the continuity helper\'s pidfile path keeps the accented character intact, as a Perl character, not mangled bytes')
                or diag($h ? ($h->{pidfile} // '<undef>') : '<no helper for winpid 7777>');
        }

        my $jpath = "$unicode_dir/power-journal.jsonl";
        my $raw_bytes = slurp($jpath) // '';
        my $expect_bytes = "Trabalho cont\xc3\xadnuo"; # UTF-8 for "contínuo"
        ok(index($raw_bytes, $expect_bytes) >= 0,
            'AC12: the raw file bytes contain the correct UTF-8 encoding of the accented character (C3 AD)')
            or diag(unpack('H*', substr($raw_bytes, 0, 400)));
        # A standalone check, not OR'd with the encoding-presence check
        # above: C3 83 is the UTF-8 encoding of U+00C3 (Latin capital
        # A-tilde), the tell-tale byte a double-encode of C3 A9/C3 AD
        # produces. This must be able to fail on its own.
        ok(index($raw_bytes, "\xc3\x83") < 0,
            'AC12: no double-encoding artifact (C3 83) is present anywhere in the raw file bytes');

        my @lines = jsonl_lines($jpath);
        my $entries = PZ('build_timeline', journal_lines => [ map { decode_or_undef($_) } @lines ],
            events => [], transcript => undef, since_ms => 0, until_ms => (time() + 3600) * 1000);
        ok(ref $entries eq 'ARRAY', 'AC12: build_timeline reads the rotated non-ASCII-path journal back without dying');
    }

    my $CLI = "$S/bp-power-journal.pl";
    SKIP: {
        skip 'AC12: bp-power-journal.pl does not exist yet', 1 unless -f $CLI;
        my $transcript = "$unicode_dir/transcript.jsonl";
        write_lines($transcript, JSON::PP->new->encode({ timestamp => epoch_to_iso(time()) }));
        my (undef, $err, $rc) = run_cli($CLI, 'report', '--dir', $unicode_dir, '--transcript', $transcript, '--no-events', '--format', 'json');
        is($rc, 0, 'AC12: the CLI --transcript accepts a path under the non-ASCII directory') or diag("stderr: $err");
    }
}

# ===========================================================================
# SHOULD-FIX (review item 2) -- a helper log whose only flag-setting lines
# for a winpid sit BEFORE the last-8-MiB tail window must report requests
# "unknown" (an honest "cannot tell"), never "[]" ("holds nothing"), because
# [] also silently defeats BATTERY-CUTOFF detection (spec 2.4.4, review
# item 2). Simulated with a log padded past 8 MiB of filler for a DIFFERENT
# pid, after the one real winpid's flag-setting lines.
# ===========================================================================
{
    my $dir = fresh_dir('shouldfix-tail');
    my $log = "$dir/keepawake.log";
    open(my $fh, '>:raw', $log) or die $!;
    print {$fh} "2026-09-24 03:00:00 pid=7777 ASSERTED flags=ES_CONTINUOUS|ES_SYSTEM_REQUIRED\n";
    print {$fh} "2026-09-24 03:00:01 pid=7777 POWER-REQUEST-CREATED\n";
    my $filler = '2026-09-24 03:00:02 pid=9999 NOISE ' . ('x' x 60) . "\n";
    my $n = int((9 * 1024 * 1024) / length($filler)) + 1; # >9 MiB total, well past the 8 MiB tail
    print {$fh} $filler for 1 .. $n;
    close $fh;

    my $reqs = PZ('requests_from_log', $log, 7777);
    ok(ref $reqs eq 'HASH', 'SHOULD-FIX (tail): requests_from_log returns a hashref') or diag(explain_undef());
    SKIP: {
        skip 'SHOULD-FIX (tail): requests_from_log not implemented yet', 1 unless ref $reqs eq 'HASH';
        is($reqs->{requests}, 'unknown',
            'SHOULD-FIX (tail): flag-setting lines older than the 8 MiB tail window give requests "unknown", never []')
            or diag(JSON::PP->new->encode($reqs));
    }
}

# ===========================================================================
# SHOULD-FIX (review item 6) -- the newest-506/507 display proxy must not
# report a stale state across an unclean reboot. If the probe's newest
# 506/507 sample belongs to a PRIOR boot (a different boot_id than the
# current one), display must be "unknown", never the pre-reboot value.
#
# NOTE: the spec (written before this review finding) has no field for
# "current boot id" or "event boot id". This test names the seam
# `boot_id` (top-level, current boot) and `cs.boot_id` (the sampled
# event's own BootId), matching the review's own vocabulary ("the newest
# event's BootId is not the current boot's"). If the implementer's actual
# seam differs, the failure here should be read as a naming mismatch to
# reconcile with the driver, not as "the behavior is unneeded."
# ===========================================================================
{
    my ($home, $legacy) = fresh_group();
    local $BpContinuityLease::PLATFORM = 'windows';
    arm_one('shouldfix6');
    my $probe = default_probe_data(
        cs       => { id => 507, t_ms => 1758700000000, boot_id => 'BOOT-PRE-REBOOT' },
        boot_id  => 'BOOT-POST-REBOOT',
    );
    BpContinuityLease::daemon_loop($legacy, max_iterations => 1, tick => 1,
        spawn => sub { 9701 }, powershell_available => sub { 1 }, kill_pid => sub { },
        journal_opts => { now => sub { 1758900500 }, probe_argv => probe_fixture($probe) });
    my $rec = decode_or_undef((jsonl_lines("$legacy/power-journal.jsonl"))[-1] // '');
    is(ref($rec) eq 'HASH' ? $rec->{display} : undef, 'unknown',
        'SHOULD-FIX (reboot): the newest 506/507 event from a PRIOR boot never reports a stale display state after an unclean reboot')
        or diag(ref($rec) eq 'HASH' ? JSON::PP->new->encode($rec) : 'undecodable');
}

# ===========================================================================
# SHOULD-FIX (review item 1 / B13) -- a journal line that cannot be decoded
# (a hard-freeze-truncated trailing line) is skipped AND counted; the count
# is surfaced in the report's header/notes, not silently swallowed.
# ===========================================================================
{
    my $CLI = "$S/bp-power-journal.pl";
    my $dir = fresh_dir('shouldfix-b13');
    PZ('append_record', $dir, { v => 1, kind => 'tick', ts => 1758930000, seq => 1, refresher_pid => 1,
        tick_s => 60, power_source => 'ac', battery_pct => 90, plan_guid => 'g', plan_name => 'Balanced',
        display => 'on', display_basis => 'kernel-power-506-507', display_at => 'unknown', helpers => [],
        sessions => [], probe => { status => 'ok', ms => 1, age_s => 0, error => '' } });
    # A hard-freeze-shaped truncated line: a valid JSON prefix, no closing
    # brace, no trailing newline -- exactly what an interrupted syswrite
    # under O_APPEND leaves behind (spec 5).
    append_bytes("$dir/power-journal.jsonl", '{"v":1,"kind":"tick","ts":175893');

    SKIP: {
        skip 'SHOULD-FIX B13: bp-power-journal.pl does not exist yet', 2 unless -f $CLI;
        my ($out_text, $err_text, $rc_text) = run_cli($CLI,
            'report', '--dir', $dir, '--no-events', '--since', 1758929000, '--until', 1758931000, '--format', 'text');
        is($rc_text, 0, 'SHOULD-FIX B13: report exits 0 with a truncated trailing journal line present')
            or diag("stderr: $err_text");
        like($out_text, qr/skipped=1\b/,
            'SHOULD-FIX B13: the header counts the one truncated/undecodable journal line (skipped=1)')
            or diag($out_text);
    }
}

# ===========================================================================
# SHOULD-FIX (review item 4 / AC9 shim) -- bin/bp-power-journal must give
# byte-identical --help output and exit code to the .pl it shims, exactly
# like bin/butler-hold (spec 2.7's shim-shape requirement).
# ===========================================================================
{
    my $CLI  = "$S/bp-power-journal.pl";
    (my $shim = "$Bin/../../bin/bp-power-journal") =~ s{\\}{/}g;
    my $bash_ok = eval { `bash --version 2>&1`; $? == 0 };
    SKIP: {
        skip 'AC9 shim: bp-power-journal.pl or the shim does not exist yet', 2 unless -f $CLI && -f $shim;
        skip 'AC9 shim: bash not available on this host', 2 unless $bash_ok;

        my ($direct_out, undef, $direct_rc) = run_cli($CLI, '--help');

        my (undef, $shim_outfile) = tempfile();
        my (undef, $shim_errfile) = tempfile();
        my $spid = fork();
        die "fork: $!" unless defined $spid;
        if ($spid == 0) {
            open(STDOUT, '>', $shim_outfile) or POSIX::_exit(126);
            open(STDERR, '>', $shim_errfile) or POSIX::_exit(126);
            exec('bash', $shim, '--help');
            POSIX::_exit(127);
        }
        push @KILL_PIDS, $spid;
        waitpid($spid, 0);
        my $shim_rc = $? >> 8;
        @KILL_PIDS = grep { $_ != $spid } @KILL_PIDS;
        my $shim_out = slurp($shim_outfile) // '';

        is($shim_rc, $direct_rc, 'AC9 shim: bin/bp-power-journal --help exits with the same code as the .pl directly');
        is($shim_out, $direct_out, 'AC9 shim: bin/bp-power-journal --help gives byte-identical stdout to the .pl directly');
    }
}

# ===========================================================================
# SHOULD-FIX (review item 4 / AC10) -- "the default events reader returns a
# refusal note without spawning" is asserted directly via an in-process
# report_main call, where $0 (this .t file) triggers the same guard
# probe_argv() already uses. No subprocess is needed for this seam: it is
# about report_main() called with $0 ending in .t, never about the CLI
# child process (whose own $0 is bp-power-journal.pl, not a .t file).
# ===========================================================================
{
    my $dir = fresh_dir('ac10-events-refusal');
    my $out_file = tempfile_named();
    open(my $saved_stdout, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(STDOUT, '>', $out_file) or die "redirect STDOUT: $!";
    my $rc = PZ('report_main', 'report', '--dir', $dir, '--format', 'json');
    open(STDOUT, '>&', $saved_stdout) or die "restore STDOUT: $!";
    close $saved_stdout;

    SKIP: {
        skip 'AC10 (events refusal): report_main not implemented yet', 2 unless defined $rc;
        is($rc, 0, 'AC10 (events refusal): report_main exits 0 under the .t guard, with no events source given');
        my $out = slurp($out_file) // '';
        my @jlines = grep { length } split /\n/, $out;
        my $has_note = grep { my $d = decode_or_undef($_); ref $d eq 'HASH' && exists $d->{note} } @jlines;
        ok($has_note,
            'AC10 (events refusal): the default events reader adds a refusal note instead of spawning, under the .t guard')
            or diag($out);
    }
}

done_testing();
