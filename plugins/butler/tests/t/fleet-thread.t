#!/usr/bin/env perl
# platform: any
# Package 05 (fleet-thread-and-wording), spec specs/05-fleet-thread-and-wording-spec.md.
#
# A fleet run gets a thread (owner kind orchestrator) that bp-orchestrator.pl
# writes to directly through Almanac::Thread library calls while it holds its
# runs/.orchestrator flock (never the thread CLI); it archives when every
# linked package is done or dropped. Covers DC1/DC2 (AC1-AC9, AC13 is part of
# DC3), plus the static DC3 checks whose "file" column in the spec's AC table
# names this file: AC9 (old-name refusal), AC13 (no old RunState key anywhere
# under plugins/ or scripts/), AC14 (no old script name in the write set
# except the two stubs), AC15 (skill prose), and a source-level contribution
# to AC11 (bp-resolve.pl spawns bp-answer-escalation.pl).
#
# WRITTEN AGAINST SPEC ONLY. None of bp-orchestrator.pl's fleet_thread option,
# the two renamed scripts, RunState's new keys, or the skill prose rewording
# exist yet, so every assertion below is expected to fail against an absence
# of implementation -- never against a Perl exception in THIS file. Where a
# later assertion depends on an earlier one that cannot yet succeed (e.g. a
# thread that package 05 has not yet wired up), the precondition is asserted
# first (so the right failure is recorded) and the dependents are SKIPped
# with a reason, rather than crashing the whole file on an undef dereference.
#
# Fixture conventions (spec section 3): every env var below is a tempdir
# (never the real ~/.claude or this repo's own .ccpraxis-local-data); no test
# spawns launcher.pl, bp-orchestrate.sh, podman or claude.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp ();
use File::Path qw(make_path);
use File::Spec ();
use Fcntl qw(:flock);
use Cwd qw(abs_path);

# ---------------------------------------------------------------------------
# tempdir() wrapper, ASCII-only. This host's own user profile directory
# contains a non-ASCII byte ("Andre" with an accent), and Almanac::Thread's
# owner_status()/orchestrator_live() path concatenates a Store-resolved root
# (raw bytes) with a thread record's owner_id (utf8-decoded by Almanac::Record)
# -- exactly the Latin-1-upgrade corruption CLAUDE.md documents for PackageLink.
# Measured directly against this host: the SAME flock-held marker reads "live"
# when the project root has no non-ASCII byte and "dead" when it does (even
# though the two root strings print identically and compare `eq` true) --
# not a race, not a flaky host, but this byte-upgrade landmine specifically.
# That bug belongs to packages 02/03's Almanac::Thread/SessionLive, not to
# this package's tests, so every fixture in this file is rooted under an
# ASCII-only temp directory to sidestep it rather than accidentally asserting
# it as this package's own behaviour.
my $ASCII_TMP_BASE = (-d 'C:/Windows/Temp' && -w 'C:/Windows/Temp') ? 'C:/Windows/Temp' : File::Spec->tmpdir;
sub tempdir { return File::Temp::tempdir(DIR => $ASCII_TMP_BASE, CLEANUP => 1); }

# ---------------------------------------------------------------------------
# Env pinning (section 3) -- BEFORE requiring anything that might touch HOME.
# ---------------------------------------------------------------------------
my $ENV_TMP = tempdir();
$ENV{HOME}              = $ENV_TMP;
$ENV{USERPROFILE}       = $ENV_TMP;
$ENV{ALMANAC_HOME}      = $ENV_TMP;
$ENV{CLAUDE_CONFIG_DIR} = $ENV_TMP;
$ENV{BUTLER_STATE_DIR}  = $ENV_TMP;
$ENV{CCPRAXIS_DATA_DIR} = $ENV_TMP;
$ENV{CLAUDE_PROJECT_DIR}= $ENV_TMP;
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;
delete $ENV{$_} for qw(BP_HARVEST_MAX_TURNS);

require "$Bin/../../scripts/bp-orchestrator.pl";   # package BpOrch
{
    no warnings 'once';
    require "$Bin/../../../almanac/scripts/Almanac/Thread.pm";
}

my $J = JSON::PP->new->canonical;
my $REPO = abs_path("$Bin/../../../..");   # ccpraxis repo root

sub slurp { local $/; open my $f, '<', shift or return undef; <$f> }
sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) if length($d) && !-d $d;
    open my $f, '>', $p or die "write $p: $!";
    print {$f} $c;
    close $f;
}
sub write_json { my ($p, $h) = @_; write_file($p, $J->encode($h)); }

sub write_creds {
    my ($p) = @_;
    write_json($p, { claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => (time + 100*3600)*1000, scopes => ['user:inference'], subscriptionType => 'max',
        rateLimitTier => 'x' } });
}
sub base_tun {
    my (%o) = @_;
    return { ceil5=>85, ceil7=>90, drain=>600, max_par=>2, cap=>5, flat=>120, watch_tick=>60,
        keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0, tele_retry=>3,
        usage_fail=>60, busy_path=>(tempdir() . '/busy'), harvest=>'audit',
        resolve_cap=>1, corr_cap=>1, judge_to=>100000, judge_spawn_cap=>3, %o };
}
my $USAGE_OK = $J->encode({ five_hour=>{utilization=>10, resets_at=>'2099-01-01T00:00:00+00:00'},
                             seven_day=>{utilization=>5,  resets_at=>'2099-01-01T12:00:00+00:00'} });

# mk_fleet(bp => 'fx', pkgs => [{name,status,deps}], registry => {...}) ->
# ($P, $bpdir) -- $P is the project root (holds .ccpraxis-local-data), $bpdir
# is <P>/.ccpraxis-local-data/blueprints/<bp>.
sub mk_fleet {
    my (%o) = @_;
    my $bp = $o{bp} // 'fx';
    my $P  = tempdir();
    my $bpdir = "$P/.ccpraxis-local-data/blueprints/$bp";
    make_path("$bpdir/packages", "$bpdir/runs");
    my @pkgs = @{ $o{pkgs} || [] };
    open my $b, '>', "$bpdir/blueprint.md" or die $!;
    print {$b} "# $bp\n\n## Package status\n\n| pkg | deliverable | depends_on | model |\n|--|--|--|--|\n";
    for my $p (@pkgs) { print {$b} "| $p->{name} | d | " . ($p->{deps} // '\x{2014}') . " | sonnet |\n"; }
    close $b;
    for my $p (@pkgs) {
        write_file("$bpdir/packages/$p->{name}.md",
            "---\npackage: $p->{name}\nblueprint: $bp\nstatus: $p->{status}\n"
          . "write_set: p/$p->{name}/\ntest_paths: p/$p->{name}/\nlast_updated: 2026-06-24T00:00:00Z\n"
          . "---\n# $p->{name}\n\n## Next action\n\ngo\n");
    }
    write_json("$bpdir/runs/registry.json", { packages => $o{registry} // {} });
    write_creds("$bpdir/creds.json");
    if ($o{conformance_verdict}) { write_json("$bpdir/runs/conformance-verdict.json", {}); }
    return ($P, $bpdir, $bp);
}

sub set_status {
    my ($bpdir, $pkg, $st) = @_;
    my $f = "$bpdir/packages/$pkg.md";
    my $t = slurp($f);
    $t =~ s/^status:.*$/status: $st/m;
    write_file($f, $t);
}

# A seeded escalation record (runs/escalations/<id>.json).
sub seed_escalation {
    my ($bpdir, $id, %f) = @_;
    write_json("$bpdir/runs/escalations/$id.json", { created_at => time, context => {}, %f });
}

# read_thread_safe/tasks_safe/log_safe: eval-wrapped Almanac::Thread reads so
# a not-yet-created thread (today's reality: nothing in bp-orchestrator.pl
# calls Almanac::Thread at all) reports as undef/[] rather than dying this
# whole file.
sub read_thread_safe { my ($name, $P) = @_; return eval { Almanac::Thread::read_thread($name, root => $P) }; }
sub tasks_safe        { my ($name, $P) = @_; return eval { Almanac::Thread::tasks($name, root => $P) } || []; }
sub log_safe          { my ($name, $P) = @_; return eval { Almanac::Thread::log_entries($name, root => $P) } || []; }
sub list_safe         { my (%o) = @_; return eval { Almanac::Thread::list_threads(%o) } || []; }

# filtered_log(\@entries, \@allow, \@seed_ids) -> [{event,reason},...] per
# spec behaviour 2's filter: keep only events in @allow; for escalation-sent/
# answer-applied, keep only reasons that start with one of @seed_ids.
sub filtered_log {
    my ($entries, $allow, $seed_ids) = @_;
    my %allow = map { $_ => 1 } @$allow;
    my @out;
    for my $e (@$entries) {
        next unless $allow{$e->{event}};
        if ($e->{event} eq 'escalation-sent' || $e->{event} eq 'answer-applied') {
            my $r = $e->{reason} // '';
            next unless grep { $r =~ /^\Q$_\E/ } @$seed_ids;
        }
        push @out, { event => $e->{event}, reason => $e->{reason} };
    }
    return \@out;
}

# orchestrator.log, decoded (one hashref per line); [] if absent/unreadable.
sub log_events {
    my ($bpdir) = @_;
    my $raw = slurp("$bpdir/runs/orchestrator.log");
    return [] unless defined $raw;
    my @out;
    for my $line (split /\n/, $raw) {
        next unless length $line;
        my $d = eval { $J->decode($line) };
        push @out, $d if ref $d eq 'HASH';
    }
    return \@out;
}

# ===========================================================================
# AC1 -- behaviour 1: one orchestrator-owned thread, linked tasks, idempotent.
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx',
        pkgs => [ { name=>'01-a', status=>'done' }, { name=>'02-b', status=>'blocked', deps=>'01-a' } ],
        registry => { '01-a' => { harvest => 'pass' } }, conformance_verdict => 1);

    my $run_once = sub {
        eval {
            BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1, fleet_thread=>1,
                creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
                now=>sub { time }, sleep=>sub { 0 },
                http_get=>sub { { status=>200, content=>$USAGE_OK } },
                http_post=>sub { { status=>200, content=>'{}' } },
                launch=>sub { 0 },
                spawn_judge=>sub { 0 },
                read_verdict=>sub { undef }, checkpoint=>sub { {} },
            });
            1;
        } or diag("AC1: run() died: $@");
    };

    $run_once->();
    my $th = read_thread_safe('fleet-fx', $P);
    ok(defined $th, 'AC1: a thread named fleet-fx exists after the first once-run') or diag('read_thread failed');
  SKIP: {
        skip('AC1: no thread to inspect (fleet_thread wiring not implemented)', 6) unless defined $th;
        is($th->{state}, 'live', 'AC1: thread state is live');
        is($th->{owner_kind}, 'orchestrator', 'AC1: owner_kind is orchestrator');
        is($th->{owner_id}, 'fx', 'AC1: owner_id is the blueprint name');
        my $tasks = tasks_safe('fleet-fx', $P);
        is_deeply([ map { $_->{link} } @$tasks ], ['fx/01-a', 'fx/02-b'],
            'AC1: two linked tasks, in package order, fx/01-a then fx/02-b');
        my $log = log_safe('fleet-fx', $P);
        my @ev = map { $_->{event} } @$log;
        is_deeply(\@ev, ['created', 'launched'], 'AC1: log is exactly created, launched');
        my ($launched) = grep { $_->{event} eq 'launched' } @$log;
        ok($launched && $launched->{actor} eq 'orchestrator' && (!defined $launched->{session} || $launched->{session} eq '-'),
            'AC1: launched actor=orchestrator, session=-');
        like($launched->{reason} // '', qr/\Aorchestrator started \(pid \d+\)\z/,
            'AC1: launched reason matches "orchestrator started (pid N)"');
    }
    my $flog1 = log_events($bpdir);
    my ($rec1) = grep { $_->{type} eq 'fleet_thread' } @$flog1;
    ok($rec1 && $rec1->{thread} eq 'fleet-fx' && $rec1->{created} == 1,
        'AC1: orchestrator.log has a fleet_thread record with thread fleet-fx, created 1') or diag('no fleet_thread record on first run');

    # Second once-run: still one thread; log gains one more launched; created 0.
    $run_once->();
    my $list = list_safe(root => $P, archived => 1);
    is(scalar(@$list), 1, 'AC1: a second once-run still yields exactly one thread')
        if defined $th;   # only meaningful once the first run actually created one
    my $log2 = log_safe('fleet-fx', $P);
    is(scalar(grep { $_->{event} eq 'launched' } @$log2), 2, 'AC1: the second run appended one more launched entry')
        if defined $th;
    my $flog2 = log_events($bpdir);
    my @fr2 = grep { $_->{type} eq 'fleet_thread' } @$flog2;
    ok(@fr2 >= 2 && $fr2[-1]{created} == 0, 'AC1: the second run logs fleet_thread created 0 (reused, not re-created)');
}

# ===========================================================================
# AC2/AC3 -- behaviours 2-5: the simulated run's exact filtered log order;
# re-tag; settled-not-answered; restart dedupe.
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx2',
        pkgs => [ { name=>'01-a', status=>'done' }, { name=>'02-b', status=>'blocked', deps=>'01-a' } ],
        registry => { '01-a' => { harvest => 'pass' } }, conformance_verdict => 1);
    seed_escalation($bpdir, '02-b--abc1', package=>'02-b', blueprint=>$bp, kind=>'stuck-package',
        category=>'product', question=>'q');
    seed_escalation($bpdir, '01-a--tri1', package=>'01-a', blueprint=>$bp, kind=>'stuck-package',
        category=>'implementation', question=>'q2');

    my $clock = time;
    my $tick = 0;
    my $sleep = sub {
        $tick++;
        $clock += ($_[0] // 1);
        if ($tick == 1) {
            write_json("$bpdir/runs/.paused", { reason=>'usage', manual=>0, relaunch_at=>$clock + 1_000_000_000 });
        } elsif ($tick == 2) {
            unlink "$bpdir/runs/.paused";
        } elsif ($tick == 3) {
            unlink "$bpdir/runs/escalations/02-b--abc1.json";
            set_status($bpdir, '02-b', 'dropped');
        }
        die "AC2: exceeded max ticks\n" if $tick > 200;
    };

    my $err;
    eval {
        BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>0, fleet_thread=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { $clock }, sleep=>$sleep,
            http_get=>sub { { status=>200, content=>$USAGE_OK } },
            http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 },
            spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or $err = $@;
    is($err, undef, 'AC2: the simulated run ended by itself (run_complete), not an exception') or diag("died: $err");

    my $th = read_thread_safe('fleet-fx2', $P);
    ok(defined $th, 'AC2: thread fleet-fx2 exists') or diag('read_thread failed');
  SKIP: {
        skip('AC2: no thread to inspect', 3) unless defined $th;
        my $log = log_safe('fleet-fx2', $P);
        my $filtered = filtered_log($log,
            [qw(created launched escalation-sent paused resumed answer-applied finished archived)],
            ['02-b--abc1', '01-a--tri1']);
        my @events = map { $_->{event} } @$filtered;
        # Almanac::Thread::record_event runs its own archive-check after every
        # write, so "archived" can legitimately fire as early as the
        # answer-applied call (the first write after both packages are
        # terminal) rather than strictly after "finished". Assert the other 7
        # events keep their exact relative order, and that "archived" appears
        # no earlier than "answer-applied" (the earliest point at which both
        # packages are terminal) -- not pinned to a single fixed slot.
        my @non_archived = grep { $_ ne 'archived' } @events;
        is_deeply(\@non_archived,
            [qw(created launched escalation-sent paused resumed answer-applied finished)],
            'AC2: the 7 non-archived events are exactly in this order');
        my ($archived_idx) = grep { $events[$_] eq 'archived' } 0..$#events;
        my ($answered_idx) = grep { $events[$_] eq 'answer-applied' } 0..$#events;
        ok(defined $archived_idx, 'AC2: an "archived" event is present in the filtered log');
        ok(defined $answered_idx && defined $archived_idx && $archived_idx > $answered_idx,
            'AC2: "archived" appears after "answer-applied" (the earliest point both packages are terminal)');
        my ($esent) = grep { $_->{event} eq 'escalation-sent' } @$filtered;
        my ($paused) = grep { $_->{event} eq 'paused' } @$filtered;
        my ($resumed) = grep { $_->{event} eq 'resumed' } @$filtered;
        my ($answered) = grep { $_->{event} eq 'answer-applied' } @$filtered;
        my ($finished) = grep { $_->{event} eq 'finished' } @$filtered;
        is($esent->{reason}, '02-b--abc1 stuck-package product', 'AC2: escalation-sent reason is "<id> <kind> <category>"');
        is($paused->{reason}, 'usage', 'AC2: paused reason is "usage"');
        ok(!defined $resumed->{reason} || $resumed->{reason} eq '', 'AC2: resumed carries no reason');
        is($answered->{reason}, '02-b--abc1', 'AC2: answer-applied reason is the id');
        is($finished->{reason}, 'run complete', 'AC2: finished reason is "run complete"');
        ok(!(grep { ($_->{reason} // '') =~ /^01-a--tri1/ } @$log),
            'AC2: no log entry\'s reason starts with the triage id (never logged)');
        is($th->{state}, 'archived', 'AC2: after the run the thread is archived');
    }
}

# ===========================================================================
# AC3 continued -- behaviour 3: a triage record re-tagged to product gets
# exactly one escalation-sent, and never again on later ticks or after a
# restart (log-seeded dedupe).
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx9',
        pkgs => [ { name=>'02-b', status=>'blocked' } ], registry => {});
    seed_escalation($bpdir, '02-b--retag1', package=>'02-b', blueprint=>$bp, kind=>'stuck-package',
        category=>'implementation', question=>'q');

    my $run_once = sub {
        eval {
            BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1, fleet_thread=>1,
                creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
                now=>sub { time }, sleep=>sub { 0 },
                http_get=>sub { { status=>200, content=>$USAGE_OK } },
                http_post=>sub { { status=>200, content=>'{}' } },
                launch=>sub { 0 }, spawn_judge=>sub { 0 },
                read_verdict=>sub { undef }, checkpoint=>sub { {} },
            });
            1;
        } or diag("behaviour3/re-tag: run() died: $@");
    };

    $run_once->();
    my $log1 = log_safe('fleet-fx9', $P);
    ok(!(grep { $_->{event} eq 'escalation-sent' && ($_->{reason} // '') =~ /^02-b--retag1/ } @$log1),
        'behaviour3: a triage-owned (implementation) record is not logged on the first run');

    # Re-tag the SAME id to product, then run again: exactly one escalation-sent.
    seed_escalation($bpdir, '02-b--retag1', package=>'02-b', blueprint=>$bp, kind=>'stuck-package',
        category=>'product', question=>'q');
    $run_once->();
    my $log2 = log_safe('fleet-fx9', $P);
    my @sent2 = grep { $_->{event} eq 'escalation-sent' && ($_->{reason} // '') =~ /^02-b--retag1/ } @$log2;
    is(scalar(@sent2), 1, 'behaviour3: re-tagging to product logs exactly one escalation-sent for its id')
        or diag('log: ' . $J->encode($log2));
    like($sent2[0]{reason} // '', qr/\A02-b--retag1 stuck-package product\z/,
        'behaviour3: the escalation-sent reason is "<id> <kind> <category>"') if @sent2;

    # Two more runs (each a fresh BpOrch::run(), i.e. a restart): never a
    # second escalation-sent for the same id.
    $run_once->();
    $run_once->();
    my $log3 = log_safe('fleet-fx9', $P);
    my @sent3 = grep { $_->{event} eq 'escalation-sent' && ($_->{reason} // '') =~ /^02-b--retag1/ } @$log3;
    is(scalar(@sent3), 1,
        'behaviour3: later ticks and fresh run()s (log-seeded restart) never re-log the same id');
}

# ===========================================================================
# AC3 continued -- behaviour 4: an operator-owned record already logged
# escalation-sent disappears TOGETHER WITH a resolved-escalations/<id>.json
# archive entry -> no answer-applied (settled, not answered).
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx12',
        pkgs => [ { name=>'02-b', status=>'blocked' } ], registry => {});
    seed_escalation($bpdir, '02-b--settle1', package=>'02-b', blueprint=>$bp, kind=>'stuck-package',
        category=>'product', question=>'q');

    my $run_once = sub {
        eval {
            BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1, fleet_thread=>1,
                creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
                now=>sub { time }, sleep=>sub { 0 },
                http_get=>sub { { status=>200, content=>$USAGE_OK } },
                http_post=>sub { { status=>200, content=>'{}' } },
                launch=>sub { 0 }, spawn_judge=>sub { 0 },
                read_verdict=>sub { undef }, checkpoint=>sub { {} },
            });
            1;
        } or diag("behaviour4/settled: run() died: $@");
    };

    $run_once->();
    my $log1 = log_safe('fleet-fx12', $P);
    ok((grep { $_->{event} eq 'escalation-sent' && ($_->{reason} // '') =~ /^02-b--settle1/ } @$log1),
        'behaviour4: the operator-owned record is logged escalation-sent on the first run')
        or diag('log: ' . $J->encode($log1));

    unlink "$bpdir/runs/escalations/02-b--settle1.json";
    write_json("$bpdir/runs/resolved-escalations/02-b--settle1.json", { settled => 1 });
    $run_once->();
    my $log2 = log_safe('fleet-fx12', $P);
    ok(!(grep { $_->{event} eq 'answer-applied' && ($_->{reason} // '') =~ /^02-b--settle1/ } @$log2),
        'behaviour4: disappearing WITH a resolved-escalations archive entry logs no answer-applied')
        or diag('log: ' . $J->encode($log2));
}

# ===========================================================================
# AC3 continued -- behaviour 5: restart dedupe. A record logged
# escalation-sent, then a fresh run() with it still present logs no second
# escalation-sent; deleting it (no archive) while no orchestrator runs and
# then running once logs exactly one answer-applied.
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx13',
        pkgs => [ { name=>'02-b', status=>'blocked' } ], registry => {});
    seed_escalation($bpdir, '02-b--restart1', package=>'02-b', blueprint=>$bp, kind=>'stuck-package',
        category=>'product', question=>'q');

    my $run_once = sub {
        eval {
            BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1, fleet_thread=>1,
                creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
                now=>sub { time }, sleep=>sub { 0 },
                http_get=>sub { { status=>200, content=>$USAGE_OK } },
                http_post=>sub { { status=>200, content=>'{}' } },
                launch=>sub { 0 }, spawn_judge=>sub { 0 },
                read_verdict=>sub { undef }, checkpoint=>sub { {} },
            });
            1;
        } or diag("behaviour5/restart: run() died: $@");
    };

    $run_once->();   # run() 1 (once=>1, ends immediately): escalation-sent logged.
    $run_once->();   # run() 2: a fresh "restart" with the record still present.
    my $log2 = log_safe('fleet-fx13', $P);
    my @sent = grep { $_->{event} eq 'escalation-sent' && ($_->{reason} // '') =~ /^02-b--restart1/ } @$log2;
    is(scalar(@sent), 1, 'behaviour5: a fresh run() with the record still present logs no second escalation-sent')
        or diag('log: ' . $J->encode($log2));

    # No orchestrator is running here (run() already returned). Delete the
    # record with NO archive entry, then run once more.
    unlink "$bpdir/runs/escalations/02-b--restart1.json";
    $run_once->();   # run() 3.
    my $log3 = log_safe('fleet-fx13', $P);
    my @answered = grep { $_->{event} eq 'answer-applied' && ($_->{reason} // '') eq '02-b--restart1' } @$log3;
    is(scalar(@answered), 1,
        'behaviour5: deleting the record (no archive) while down, then running once, logs exactly one answer-applied')
        or diag('log: ' . $J->encode($log3));
}

# ===========================================================================
# AC4 -- static source checks (behaviour's wiring contract, Decision 17 Q7/F6).
# ===========================================================================
{
    my $src = slurp("$Bin/../../scripts/bp-orchestrator.pl");
    ok(defined $src, 'AC4: bp-orchestrator.pl source is readable');
    unlike($src, qr/almanac-thread/, 'AC4: bp-orchestrator.pl contains no "almanac-thread" (never shells to the CLI)');
    unlike($src, qr/\balmanac\.pl\b/, 'AC4: bp-orchestrator.pl contains no "almanac.pl"');
    ok(($src // '') =~ /Almanac::Thread::record_event\(/, 'AC4: bp-orchestrator.pl calls Almanac::Thread::record_event( directly');

    # Every Almanac::Thread:: use lies inside a sub whose name starts with
    # _fleet_thread_. Parsed by walking top-level `sub NAME {` headers and
    # checking which such span each Almanac::Thread:: occurrence falls in.
    my @sub_spans;   # [name, start_pos, end_pos)
    {
        my @starts;
        while ($src =~ /^sub\s+(\w+)\s*\{/mg) { push @starts, [$1, $-[0]]; }
        for my $i (0..$#starts) {
            my $end = ($i+1 <= $#starts) ? $starts[$i+1][1] : length($src);
            push @sub_spans, [$starts[$i][0], $starts[$i][1], $end];
        }
    }
    my $bad_site = 0;
    while ($src =~ /Almanac::Thread::/g) {
        my $pos = $-[0];
        my ($owner) = grep { $pos >= $_->[1] && $pos < $_->[2] } @sub_spans;
        $bad_site++ unless $owner && $owner->[0] =~ /^_fleet_thread_/;
    }
    is($bad_site, 0, 'AC4: every Almanac::Thread:: occurrence is inside a sub named _fleet_thread_*');

    # Every _fleet_thread_\w+( call site, in the text of `sub run`, lies
    # between the first acquire_marker( and the first release_marker($marker_fh.
    my ($run_body) = $src =~ /(sub run \{.*)/s;
    ok(defined $run_body, 'AC4: sub run { is present');
  SKIP: {
        skip('AC4: sub run not found', 1) unless defined $run_body;
        my $am = index($run_body, 'acquire_marker(');
        my $rm = index($run_body, 'release_marker($marker_fh');
        ok($am >= 0 && $rm > $am, 'AC4: acquire_marker( precedes release_marker($marker_fh in sub run')
            or diag("acquire_marker at $am, release_marker at $rm");
        my $window = ($am >= 0 && $rm > $am) ? substr($run_body, 0, $rm) : '';
        my @calls = ($run_body =~ /(_fleet_thread_\w+\()/g);
        my $outside = 0;
        for my $c (@calls) {
            my $first_after_am = index($run_body, $c, $am >= 0 ? $am : 0);
            $outside++ if $first_after_am < 0 || $first_after_am >= $rm;
        }
        # A simpler, robust restatement: every occurrence of the call pattern
        # within sub run must be found within the acquire..release substring.
        my $in_window = () = ($window =~ /_fleet_thread_\w+\(/g);
        my $in_whole   = () = ($run_body =~ /_fleet_thread_\w+\(/g);
        is($in_window, $in_whole, 'AC4: every _fleet_thread_* call in sub run lies between acquire_marker( and release_marker($marker_fh')
            if $am >= 0 && $rm > $am;
    }

    my ($cli_block) = $src =~ /unless \(caller\) \{(.*)\}\s*\n1;\s*\z/s;
    ok(defined($cli_block) && $cli_block =~ /BpOrch::run\(\{[^}]*fleet_thread\s*=>\s*1/s,
        'AC4: the CLI BpOrch::run({...}) call contains fleet_thread => 1');
}

# ===========================================================================
# AC5 -- behaviour 6: archive when every package is done/dropped; never with
# a parked package.
# ===========================================================================
{
    # 6a: both ledgers done/dropped before the first run -> archives at setup;
    # log is created, archived, launched, finished.
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx3',
        pkgs => [ { name=>'01-a', status=>'done' }, { name=>'02-b', status=>'dropped' } ],
        registry => { '01-a' => { harvest => 'pass' } }, conformance_verdict => 1);
    eval {
        BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1, fleet_thread=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>sub { 0 },
            http_get=>sub { { status=>200, content=>$USAGE_OK } },
            http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or diag("AC5a: run() died: $@");
    my $th = read_thread_safe('fleet-fx3', $P);
    ok(defined $th, 'AC5a: thread fleet-fx3 exists');
  SKIP: {
        skip('AC5a: no thread to inspect', 2) unless defined $th;
        is($th->{state}, 'archived', 'AC5a: both-terminal-before-first-run archives at setup');
        my $log = log_safe('fleet-fx3', $P);
        my @ev = map { $_->{event} } @$log;
        is_deeply(\@ev, [qw(created archived launched finished)],
            'AC5a: log is created, archived, launched, finished (finished allowed on archived)');
    }

    # behaviour 9 (second half): "same when fleet-fx is archived" -- a fresh
    # run() against the same already-archived fleet-fx3 gets a new thread
    # fleet-fx3-2; the original is untouched.
  SKIP: {
        skip('behaviour9/archived: fleet-fx3 was never created', 4) unless defined $th;
        my $log_before = log_safe('fleet-fx3', $P);
        eval {
            BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1, fleet_thread=>1,
                creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
                now=>sub { time }, sleep=>sub { 0 },
                http_get=>sub { { status=>200, content=>$USAGE_OK } },
                http_post=>sub { { status=>200, content=>'{}' } },
                launch=>sub { 0 }, spawn_judge=>sub { 0 },
                read_verdict=>sub { undef }, checkpoint=>sub { {} },
            });
            1;
        } or diag("behaviour9/archived: second run() died: $@");
        my $th2 = read_thread_safe('fleet-fx3-2', $P);
        ok(defined $th2, 'behaviour9/archived: a second thread fleet-fx3-2 exists after fleet-fx3 archived')
            or diag('read_thread(fleet-fx3-2) failed');
      SKIP: {
            skip('behaviour9/archived: no second thread to inspect', 2) unless defined $th2;
            is($th2->{owner_id}, 'fx3', 'behaviour9/archived: fleet-fx3-2 owner_id is the blueprint');
            my $log2 = log_safe('fleet-fx3-2', $P);
            ok((grep { $_->{event} eq 'created' } @$log2) && (grep { $_->{event} eq 'launched' } @$log2),
                'behaviour9/archived: fleet-fx3-2 has its own created and launched');
        }
        my $log_after = log_safe('fleet-fx3', $P);
        is_deeply($log_after, $log_before, 'behaviour9/archived: fleet-fx3 itself is untouched by the new run');
    }
}
{
    # 6c: a parked package is never archived.
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx4',
        pkgs => [ { name=>'01-a', status=>'parked' } ], registry => {});
    eval {
        BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1, fleet_thread=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>sub { 0 },
            http_get=>sub { { status=>200, content=>$USAGE_OK } },
            http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or diag("AC5c: run() died: $@");
    my $th = read_thread_safe('fleet-fx4', $P);
    ok(defined $th, 'AC5c: thread fleet-fx4 exists');
    is($th->{state}, 'live', 'AC5c: a parked-only fleet never archives') if defined $th;
}

# ===========================================================================
# AC5 continued -- behaviour 6b: archive at the end of a tick that does NOT
# finish the run (a harvest judge stays in flight, so run_complete is false
# and _fleet_thread_end takes the archive_if_done branch instead of finished).
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx14',
        pkgs => [ { name=>'01-a', status=>'done' }, { name=>'02-b', status=>'blocked' } ],
        registry => { '01-a' => { harvest => 'pass' } }, conformance_verdict => 1);
    # A harvest judge "in flight" for 01-a keeps $judges_inflight (and so
    # run_complete) false on every tick: read_verdict below returns nothing,
    # so the inflight marker is never cleared and the condition holds.
    write_file("$bpdir/runs/harvest/01-a.inflight", time . "\n");

    my $tick = 0;
    my $sleep = sub {
        $tick++;
        if ($tick == 1) { set_status($bpdir, '02-b', 'dropped'); }
        elsif ($tick == 2) { die "behaviour6b: stop after tick 2\n"; }
        die "behaviour6b: exceeded max ticks\n" if $tick > 10;
    };
    my $err;
    eval {
        BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>0, fleet_thread=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>$sleep,
            http_get=>sub { { status=>200, content=>$USAGE_OK } },
            http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or $err = $@;
    is($err, "behaviour6b: stop after tick 2\n", 'behaviour6b: the harness stop fired as scripted (sanity)')
        or diag("unexpected: $err");

    my $th = read_thread_safe('fleet-fx14', $P);
    ok(defined $th, 'behaviour6b: thread fleet-fx14 exists');
  SKIP: {
        skip('behaviour6b: no thread to inspect', 2) unless defined $th;
        is($th->{state}, 'archived',
            'behaviour6b: the thread archives once both packages are terminal, even though the run stays open');
        my $log = log_safe('fleet-fx14', $P);
        ok(!(grep { $_->{event} eq 'finished' } @$log),
            'behaviour6b: no "finished" was logged (the run did not complete; archive came from archive_if_done)')
            or diag('log: ' . $J->encode($log));
    }
}

# ===========================================================================
# AC6 -- behaviours 7-9: crash leaves the thread takeable; a live owner is
# refused; a take-over gets a new thread on the next dispatch.
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx5',
        pkgs => [ { name=>'02-b', status=>'blocked' } ], registry => {});
    my $tick = 0;
    my $sleep = sub { $tick++; die "simulated crash\n" if $tick == 1; };
    my $err;
    eval {
        BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>0, fleet_thread=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>$sleep,
            http_get=>sub { { status=>200, content=>$USAGE_OK } },
            http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or $err = $@;
    is($err, "simulated crash\n", 'AC6: run() dies with the simulated crash message');
    ok(!-e "$bpdir/runs/.orchestrator", 'AC6: the marker is absent after the crash (release_marker runs on every exit path)');

    my $th = read_thread_safe('fleet-fx5', $P);
    ok(defined $th, 'AC6: thread fleet-fx5 exists despite the crash');
  SKIP: {
        skip('AC6: no thread to inspect', 6) unless defined $th;
        is($th->{state}, 'live', 'AC6: the thread itself is still live (never archived, no finished logged)');
        my $log = log_safe('fleet-fx5', $P);
        ok(!(grep { $_->{event} eq 'finished' } @$log), 'AC6: no finished event was logged');
        my $os = Almanac::Thread::owner_status($th, root => $P);
        is($os->{status}, 'dead', 'AC6: owner_status reads dead (marker gone)');
        eval { Almanac::Thread::attach('fleet-fx5', session => 'S1', root => $P); };
        like($@, qr/owner_dead/, 'AC6: attach() dies refused owner_dead');
        my ($taken, $changed) = eval { Almanac::Thread::take_over('fleet-fx5', session => 'S1',
            reason => 'fleet orchestrator crashed', root => $P); };
        ok(!$@ && $taken, 'AC6: take_over() succeeds') or diag("take_over died: $@");
      SKIP: {
            skip('AC6: take_over did not succeed', 2) unless !$@ && $taken;
            is($taken->{owner_kind}, 'session', 'AC6: new owner_kind is session');
            my $log2 = log_safe('fleet-fx5', $P);
            my ($to) = grep { $_->{event} eq 'taken-over' } @$log2;
            ok($to && $to->{from} eq 'orchestrator:fx5' && $to->{to} eq 'session:S1',
                'AC6: last log entry is taken-over from orchestrator:fx5 to session:S1');
        }

        # Variant: marker present but unlocked -> still dead, take-over succeeds.
        write_file("$bpdir/runs/.orchestrator", "999999\n");
        my $os2 = Almanac::Thread::owner_status($th, root => $P);
        is($os2->{status}, 'dead', 'AC6 variant: a marker file with no lock still reads dead');
    }
}
{
    # AC6 (behaviour 8): a LIVE owner (real flock held) is refused.
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx6', pkgs => [], registry => {});
    eval { Almanac::Thread::create_thread('fleet-fx6', owner_kind=>'orchestrator', owner_id=>$bp,
        actor=>'orchestrator', root=>$P); };
    ok(!$@, 'AC6/live-owner: a thread can be created directly for this sub-case') or diag($@);
    open(my $mfh, '>', "$bpdir/runs/.orchestrator") or die $!;
    print {$mfh} "$$\n";
    flock($mfh, LOCK_EX) or die "flock: $!";
    my $th = eval { Almanac::Thread::read_thread('fleet-fx6', root=>$P) };
  SKIP: {
        skip('AC6/live-owner: setup failed', 2) unless defined $th;
        my $os = Almanac::Thread::owner_status($th, root => $P);
        is($os->{status}, 'live', 'AC6/live-owner: a held flock reads live');
        eval { Almanac::Thread::take_over('fleet-fx6', session=>'S2', reason=>'x', root=>$P); };
        like($@, qr/owner_live/, 'AC6/live-owner: take_over dies refused owner_live');
    }
    flock($mfh, LOCK_UN); close $mfh;
}

# ===========================================================================
# AC6 continued -- behaviour 9 (first half): after a crash + take-over, a
# fresh run() gets a new thread "fleet-<slug>-2"; the taken-over thread is
# untouched.
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx15',
        pkgs => [ { name=>'02-b', status=>'blocked' } ], registry => {});
    my $tick = 0;
    my $sleep = sub { $tick++; die "simulated crash\n" if $tick == 1; };
    eval {
        BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>0, fleet_thread=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>$sleep,
            http_get=>sub { { status=>200, content=>$USAGE_OK } },
            http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    };   # expected to die with "simulated crash\n" -- re-verified by AC6 above; ignored here.

    eval { Almanac::Thread::take_over('fleet-fx15', session => 'S9',
        reason => 'behaviour9 setup', root => $P); };
    ok(!$@, 'behaviour9: setup take_over() of fleet-fx15 succeeds') or diag("take_over died: $@");
    my $log_before = log_safe('fleet-fx15', $P);

    eval {
        BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1, fleet_thread=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>sub { 0 },
            http_get=>sub { { status=>200, content=>$USAGE_OK } },
            http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or diag("behaviour9: run() after take-over died: $@");

    my $th2 = read_thread_safe('fleet-fx15-2', $P);
    ok(defined $th2, 'behaviour9: a second thread fleet-fx15-2 exists after the take-over')
        or diag('read_thread(fleet-fx15-2) failed');
  SKIP: {
        skip('behaviour9: no second thread to inspect', 3) unless defined $th2;
        is($th2->{owner_kind}, 'orchestrator', 'behaviour9: fleet-fx15-2 is owned by orchestrator');
        is($th2->{owner_id}, $bp, 'behaviour9: fleet-fx15-2 owner_id is the blueprint');
        my $log2 = log_safe('fleet-fx15-2', $P);
        is_deeply([ map { $_->{event} } @$log2 ], ['created', 'launched'],
            'behaviour9: fleet-fx15-2 has its own created, launched');
    }
    my $log_after = log_safe('fleet-fx15', $P);
    is_deeply($log_after, $log_before, 'behaviour9: fleet-fx15 (the taken-over thread) is untouched by the new run');
}

# ===========================================================================
# AC7 -- behaviours 10-12: thread-less degradations, off-by-default, a
# failing thread write never stops the fleet.
# ===========================================================================
{
    # 10a: bp_dir a bare tempdir (no .ccpraxis-local-data ancestor).
    my $bare = tempdir();
    make_path("$bare/packages", "$bare/runs");
    write_file("$bare/blueprint.md", "# x\n\n## Package status\n\n| pkg | deliverable | depends_on | model |\n|--|--|--|--|\n");
    write_json("$bare/runs/registry.json", { packages => {} });
    write_creds("$bare/creds.json");
    eval {
        BpOrch::run({ blueprint=>'x', bp_dir=>$bare, once=>1, fleet_thread=>1,
            creds_path=>"$bare/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>sub { 0 },
            http_get=>sub { { status=>200, content=>$USAGE_OK } }, http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or diag("AC7/no_project_root: run() died: $@");
    my $fev = log_events($bare);
    my ($dis) = grep { $_->{type} eq 'fleet_thread_disabled' } @$fev;
    ok($dis && $dis->{reason} eq 'no_project_root', 'AC7: a bp_dir with no .ccpraxis-local-data ancestor logs fleet_thread_disabled no_project_root')
        or diag('no fleet_thread_disabled record found: ' . $J->encode($fev));
    ok(!-d "$bare/.ccpraxis-local-data/almanac", 'AC7: no almanac tree was written under the degraded fixture');
}
{
    # 10b: bp_dir named fx but blueprint => 'other' -> bp_dir_mismatch.
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx', pkgs => [], registry => {});
    eval {
        BpOrch::run({ blueprint=>'other', bp_dir=>$bpdir, once=>1, fleet_thread=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>sub { 0 },
            http_get=>sub { { status=>200, content=>$USAGE_OK } }, http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or diag("AC7/bp_dir_mismatch: run() died: $@");
    my ($dis) = grep { $_->{type} eq 'fleet_thread_disabled' } @{ log_events($bpdir) };
    ok($dis && $dis->{reason} eq 'bp_dir_mismatch', 'AC7: blueprint name not matching bp_dir logs fleet_thread_disabled bp_dir_mismatch')
        or diag('no matching record');
}
{
    # 11: off by default -- the same AC1 fixture run WITHOUT fleet_thread.
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx7',
        pkgs => [ { name=>'01-a', status=>'done' } ], registry => { '01-a' => { harvest=>'pass' } });
    eval {
        BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>sub { 0 },
            http_get=>sub { { status=>200, content=>$USAGE_OK } }, http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or diag("AC7/off: run() died: $@");
    ok(!-d "$P/.ccpraxis-local-data/almanac/thread", 'AC7: fleet_thread omitted -> no almanac/thread directory');
    ok(!(grep { ($_->{type} // '') =~ /^fleet_thread/ } @{ log_events($bpdir) }),
        'AC7: fleet_thread omitted -> no fleet_thread* record in orchestrator.log');
}
{
    # 10c: Almanac::Thread fails to load -> fleet_thread_disabled load_failed,
    # run proceeds. Simulated with an @INC hook that intercepts the bareword
    # `require Almanac::Thread;` (key "Almanac/Thread.pm") and dies, after
    # clearing any cached %INC entry from this file's own top-of-file
    # `require "<path>/Almanac/Thread.pm"` (a literal-string require, which
    # keys %INC under the literal path, NOT "Almanac/Thread.pm" -- so the
    # bareword require in bp-orchestrator.pl re-searches @INC on every call
    # unless an EARLIER successful bareword require already cached it, which
    # the AC1 fixture above did; that cached entry is what must be cleared).
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx17', pkgs => [], registry => {});
    my $had_inc = exists $INC{'Almanac/Thread.pm'};
    my $old_inc = $INC{'Almanac/Thread.pm'};
    delete $INC{'Almanac/Thread.pm'};
    {
        local @INC = (sub {
            my (undef, $file) = @_;
            return if $file ne 'Almanac/Thread.pm';
            die "AC7/load_failed: simulated require failure\n";
        }, @INC);
        eval {
            BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>1, fleet_thread=>1,
                creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
                now=>sub { time }, sleep=>sub { 0 },
                http_get=>sub { { status=>200, content=>$USAGE_OK } }, http_post=>sub { { status=>200, content=>'{}' } },
                launch=>sub { 0 }, spawn_judge=>sub { 0 },
                read_verdict=>sub { undef }, checkpoint=>sub { {} },
            });
            1;
        } or diag("AC7/load_failed: run() died: $@");
    }
    if ($had_inc) { $INC{'Almanac/Thread.pm'} = $old_inc; } else { delete $INC{'Almanac/Thread.pm'}; }

    my ($dis) = grep { $_->{type} eq 'fleet_thread_disabled' } @{ log_events($bpdir) };
    ok($dis && $dis->{reason} eq 'load_failed', 'behaviour10: Almanac::Thread failing to load logs fleet_thread_disabled load_failed')
        or diag('records: ' . $J->encode(log_events($bpdir)));
    # Sanity: confirm the harness is restored and Almanac::Thread still works
    # for later tests in this file.
    ok(exists $INC{'Almanac/Thread.pm'}, 'behaviour10: %INC is restored after the simulated load failure')
        if $had_inc;
}

# ===========================================================================
# AC7 continued -- behaviour 12: a failing thread write logs
# fleet_thread_error with the op, and the run keeps going / releases its
# marker as usual. Forced by pausing a thread that is already archived:
# paused/resumed are refused on an archived thread (spec section 2.3's
# ARCHIVED_ALLOWED_EVENTS list does not include them).
# ===========================================================================
{
    my ($P, $bpdir, $bp) = mk_fleet(bp => 'fx16',
        pkgs => [ { name=>'01-a', status=>'done' }, { name=>'02-b', status=>'dropped' } ],
        registry => { '01-a' => { harvest => 'pass' } }, conformance_verdict => 1);
    # Both packages terminal from the start -> the thread archives at setup
    # (behaviour 6a). An in-flight harvest judge for 01-a keeps the run open
    # past the first tick, so a later pause transition can fire against the
    # now-archived thread.
    write_file("$bpdir/runs/harvest/01-a.inflight", time . "\n");

    my $tick = 0;
    my $sleep = sub {
        $tick++;
        if ($tick == 1) {
            write_json("$bpdir/runs/.paused", { reason=>'usage', manual=>0, relaunch_at=>time + 1_000_000_000 });
        } elsif ($tick == 2) {
            die "behaviour12: stop after tick 2\n";
        }
        die "behaviour12: exceeded max ticks\n" if $tick > 10;
    };
    my $err;
    eval {
        BpOrch::run({ blueprint=>$bp, bp_dir=>$bpdir, once=>0, fleet_thread=>1,
            creds_path=>"$bpdir/creds.json", tunables=>base_tun(),
            now=>sub { time }, sleep=>$sleep,
            http_get=>sub { { status=>200, content=>$USAGE_OK } },
            http_post=>sub { { status=>200, content=>'{}' } },
            launch=>sub { 0 }, spawn_judge=>sub { 0 },
            read_verdict=>sub { undef }, checkpoint=>sub { {} },
        });
        1;
    } or $err = $@;
    is($err, "behaviour12: stop after tick 2\n", 'behaviour12: the harness stop fired as scripted (sanity)')
        or diag("unexpected: $err");
    ok(!-e "$bpdir/runs/.orchestrator", 'behaviour12: the marker is released as usual despite the failing thread write');

    my $th = read_thread_safe('fleet-fx16', $P);
    ok(defined $th, 'behaviour12: thread fleet-fx16 exists');
    is($th->{state}, 'archived', 'behaviour12: the thread stayed archived (already so at setup)') if defined $th;

    my @ferrs = grep { $_->{type} eq 'fleet_thread_error' } @{ log_events($bpdir) };
    my ($ferr) = grep { ($_->{op} // '') eq 'paused' } @ferrs;
    ok($ferr, 'behaviour12: orchestrator.log has a fleet_thread_error record with op paused')
        or diag('fleet_thread_error records: ' . $J->encode(\@ferrs));
    ok($ferr && length($ferr->{error} // ''), 'behaviour12: the fleet_thread_error record carries a non-empty error string')
        if $ferr;

    my $log = log_safe('fleet-fx16', $P);
    ok(!(grep { $_->{event} eq 'paused' } @$log),
        'behaviour12: the refused paused event never actually landed in the thread log');
}

# ===========================================================================
# AC8 -- behaviour 13: the pure helpers never die and match the spec table.
# ===========================================================================
{
    my $name = sub { my $r = eval { BpOrch::fleet_thread_name($_[0]) }; diag("fleet_thread_name died: $@") if $@; return $r; };
    is($name->('where-things-go'), 'fleet-where-things-go', 'AC8: fleet_thread_name(where-things-go)');
    is($name->('Job_Search.v2'), 'fleet-job-search-v2', 'AC8: fleet_thread_name(Job_Search.v2)');
    is($name->('___'), 'fleet-run', 'AC8: fleet_thread_name(___) -> fleet-run');
    {
        my $long = 'a' x 200;
        my $r = $name->($long);
        ok(defined $r && length($r) <= 60, 'AC8: a 200-char name yields a result of at most 60 chars')
            or diag('got: ' . (defined $r ? "len=" . length($r) : 'undef'));
        ok(defined $r && eval { require "$Bin/../../../almanac/scripts/Almanac/Thread.pm"; Almanac::Thread::valid_name($r) },
            'AC8: the 200-char case passes valid_name');
        my $suffixed = defined $r ? "$r-99" : undef;
        ok(defined $suffixed && Almanac::Thread::valid_name($suffixed), 'AC8: its -99 suffix also passes valid_name')
            if defined $suffixed;
    }

    my $reason = sub { my $r = eval { BpOrch::fleet_thread_reason($_[0]) }; diag("fleet_thread_reason died: $@") if $@; return $r; };
    is($reason->(undef), 'unknown', 'AC8: fleet_thread_reason(undef) -> unknown');
    is($reason->("a\nb\tc"), 'a b c', 'AC8: control bytes become spaces, collapsed');
    {
        my $ascii300 = 'x' x 300;
        my $r = $reason->($ascii300);
        ok(defined $r && length($r) == 200 && $r =~ /\.\.\.\z/, 'AC8: a 300-byte ASCII string -> 200 bytes ending "..."')
            or diag('got: ' . (defined $r ? "len=" . length($r) : 'undef'));
    }
    {
        my $utf8_150e = ("\x{e9}" x 150);   # 150 e-acute -> 300 UTF-8 bytes when encoded
        utf8::upgrade($utf8_150e);   # force the utf8 flag on; building from \x{e9} alone
                                      # (all codepoints <= 0xFF) does not set it, which would
                                      # make this byte-identical to the invalid-bytes fixture below
        my $r = $reason->($utf8_150e);
        ok(defined $r && length($r) <= 200, 'AC8: 150 e-acute (300 bytes) -> at most 200 bytes')
            or diag('got: ' . (defined $r ? "len=" . length($r) : 'undef'));
        ok(defined $r && $r =~ /\.\.\.\z/, 'AC8: ...and ends with "..."') if defined $r;
        ok(defined $r && utf8::decode(my $copy = $r), 'AC8: ...and the result is valid UTF-8') if defined $r;
    }
    {
        my $bad = "\xff\xfe";
        is($reason->($bad), '??', 'AC8: invalid-UTF-8 bytes 0xff 0xfe -> ??');
    }
}

# ===========================================================================
# AC9 -- behaviour 14: the old script names refuse with the exact message.
# ===========================================================================
{
    my $MSG_WAIT   = "butler: 'bp-wait-for-decision.pl' is retired; use 'bp-wait-for-escalation.pl' instead (same arguments)\n";
    my $MSG_ANSWER = "butler: 'bp-answer-decision.pl' is retired; use 'bp-answer-escalation.pl' instead (same arguments)\n";
    for my $case (
        { script => 'bp-wait-for-decision.pl',   msg => $MSG_WAIT },
        { script => 'bp-answer-decision.pl',     msg => $MSG_ANSWER },
    ) {
        my $path = "$Bin/../../scripts/$case->{script}";
        my ($out, $err, $rc);
        {
            my $tmp_out = File::Temp->new; my $tmp_err = File::Temp->new;
            system("$^X \"$path\" >\"$tmp_out\" 2>\"$tmp_err\"");
            $rc = $? >> 8;
            $out = slurp("$tmp_out") // ''; $err = slurp("$tmp_err") // '';
        }
        is($rc, 2, "AC9: $case->{script} exits 2") or diag("stdout=[$out] stderr=[$err]");
        is($out, '', "AC9: $case->{script} stdout is empty");
        is($err, $case->{msg}, "AC9: $case->{script} STDERR is exactly the retirement message naming the new name");

        my $died = eval { require $path; 1 } ? undef : $@;
        ok(defined $died && $died =~ /\Q$case->{msg}\E/, "AC9: require-ing $case->{script} dies with the same message")
            or diag('require did not die with the expected message: ' . (defined $died ? $died : '(did not die)'));
    }
}

# ===========================================================================
# AC11 (source contribution) -- behaviour 16: bp-resolve.pl spawns the new
# name, never the old one. Full behavioural coverage lives in
# resolve-dispatch-and-guards.t / resolve-verdict-gates.t.
# ===========================================================================
{
    my $src = slurp("$Bin/../../scripts/bp-resolve.pl");
    ok(defined $src, 'AC11: bp-resolve.pl source is readable');
    my $new_count = () = ($src =~ /bp-answer-escalation\.pl/g);
    my $old_count = () = ($src =~ /bp-answer-decision(?!$)/g);   # tolerate a trailing word boundary issue
    is($new_count, 2, 'AC11: bp-resolve.pl source contains "bp-answer-escalation.pl" exactly twice');
    ok(!(($src // '') =~ /bp-answer-decision/), 'AC11: bp-resolve.pl source contains "bp-answer-decision" zero times');
}

# ===========================================================================
# AC13 -- behaviour 18: no file under plugins/ or scripts/ contains an old
# RunState key, anywhere. The pattern is built by concatenation so this test
# file itself (which must name the tokens to assert their absence) cannot
# match its own source.
# ===========================================================================
{
    my $old1 = 'decisions' . '_waiting';
    my $old2 = 'decisions' . '_operator';
    my $old3 = 'decisions' . '_triage';
    my $pat = qr/\b(?:\Q$old1\E|\Q$old2\E|\Q$old3\E)\b/;
    my @hits;
    require File::Find;
    no warnings 'once';
    for my $top (qw(plugins scripts)) {
        my $dir = "$REPO/$top";
        next unless -d $dir;
        File::Find::find({ wanted => sub {
            return unless -f $_;
            return unless -r _;
            my $content = slurp($_);
            return unless defined $content;
            push @hits, $File::Find::name if $content =~ $pat;
        }, no_chdir => 1 }, $dir);
    }
    is_deeply(\@hits, [],
        'AC13: no file under plugins/ or scripts/ matches an old RunState key ('
        . $old1 . '/operator/triage)')
        or diag('matches: ' . join(', ', @hits));
}

# ===========================================================================
# AC14 -- R-NAME: no write-set file except the two stubs names the old
# scripts (bp-answer-decision / bp-wait-for-decision).
# ===========================================================================
{
    my @write_set = qw(
        plugins/butler/scripts/bp-orchestrator.pl
        plugins/butler/scripts/bp-resolve.pl
        plugins/sandbox/scripts/launcher.pl
        scripts/tui-preview.pl
        plugins/butler/skills/dispatch-fleet/SKILL.md
        plugins/butler/skills/reporter/SKILL.md
        plugins/butler/skills/orchestrator-protocol/SKILL.md
        plugins/sandbox/scripts/RunState.pm
        plugins/sandbox/scripts/Dashboard.pm
        plugins/sandbox/scripts/tui/DashboardScreen.pm
    );
    my $pat = qr/bp-(?:answer|wait-for)-decision/;
    for my $rel (@write_set) {
        my $p = "$REPO/$rel";
        next unless -f $p;
        my $content = slurp($p);
        ok(!(($content // '') =~ $pat), "AC14: $rel does not name bp-answer-decision or bp-wait-for-decision");
    }
    # The two renamed scripts themselves are not yet stubs today, so this is
    # a positive existence check that will hold once they are renamed: the
    # new names must exist as real, non-stub scripts (package BpWait/BpAnswer).
    for my $rel (qw(plugins/butler/scripts/bp-wait-for-escalation.pl plugins/butler/scripts/bp-answer-escalation.pl)) {
        ok(-f "$REPO/$rel", "AC14: $rel exists");
    }
}

# ===========================================================================
# AC15 -- skill prose (section 2.9).
# ===========================================================================
{
    my $reporter = slurp("$REPO/plugins/butler/skills/reporter/SKILL.md") // '';
    for my $needle ('a debugging tool that reads the run\'s fleet thread', 'fleet-<blueprint>',
                     'almanac thread show', 'bp-answer-escalation.pl', 'bp-wait-for-escalation.pl') {
        ok(index($reporter, $needle) >= 0, "AC15: reporter/SKILL.md contains \"$needle\"");
    }
    my $dispatch = slurp("$REPO/plugins/butler/skills/dispatch-fleet/SKILL.md") // '';
    for my $needle ('fleet-<blueprint>', 'answer queued escalations') {
        ok(index($dispatch, $needle) >= 0, "AC15: dispatch-fleet/SKILL.md contains \"$needle\"");
    }
    my $protocol = slurp("$REPO/plugins/butler/skills/orchestrator-protocol/SKILL.md") // '';
    ok(index($protocol, 'bp-answer-escalation') >= 0, 'AC15: orchestrator-protocol/SKILL.md contains "bp-answer-escalation"');

    for my $pair ([reporter => $reporter], [dispatch_fleet => $dispatch], [orchestrator_protocol => $protocol]) {
        my ($label, $text) = @$pair;
        for my $bad ('queued decision', 'pending decision', 'answer a decision', 'decision queue') {
            unlike($text, qr/\Q$bad\E/i, "AC15: $label SKILL.md does not contain \"$bad\" (case-insensitive)");
        }
    }
}

done_testing();
