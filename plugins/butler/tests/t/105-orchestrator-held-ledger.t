#!/usr/bin/env perl
# t/105-orchestrator-held-ledger.t — a02-api-and-guard-defects, DEFECT 5.
# A package row added to blueprint.md with NO packages/<pkg>.md ledger yet is
# derived as 'pending' (bp-orchestrator.pl:1902, ledger_fm(...) // 'pending'),
# enters ready_packages, is handed to bp-launch.sh, which hard-exits 1 ("no
# ledger at ...") -- every tick, forever, burning a launch slot each time.
# Spec §2.5/§2.6 / AC-11..AC-15.
#
# WRITTEN BLIND TO THE IMPLEMENTATION. `ledger_missing` does not exist yet in
# %meta anywhere, `ready_packages` has no filter for it, and `add-package` never
# writes a stderr notice. Every assertion tied to those is expected to FAIL
# against the pre-change tree.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use JSON::PP;
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
require "$BUTLER/scripts/bp-orchestrator.pl";

my $J = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);

sub write_file {
    my ($path, $bytes) = @_;
    open my $w, '>:raw', $path or die "write $path: $!";
    print $w $bytes; close $w or die "close $path: $!"; return $path;
}
sub read_file {
    my ($path) = @_;
    open my $r, '<:raw', $path or return undef;
    local $/; my $c = <$r>; close $r; return defined $c ? $c : '';
}
sub log_events {
    my ($path) = @_;
    return () unless -f $path;
    my @lines = split /\n/, (read_file($path) // '');
    return map { eval { $J->decode($_) } } grep { length } @lines;
}

# =============================================================================
# AC-11 (pure): BpOrch::ready_packages omits a pending package whose %meta entry
# carries ledger_missing => 1, and still returns an identical sibling with 0.
# =============================================================================
{
    my $meta = {
        heldpkg  => { deps => [], write_set => 'a/held/',  ledger_missing => 1 },
        readypkg => { deps => [], write_set => 'a/ready/', ledger_missing => 0 },
    };
    my $status = { heldpkg => 'pending', readypkg => 'pending' };
    my @r = BpOrch::ready_packages($meta, $status, []);
    ok(!(grep { $_ eq 'heldpkg' } @r),
        'AC-11: a pending package with ledger_missing=>1 is OMITTED from ready_packages');
    ok((grep { $_ eq 'readypkg' } @r),
        'AC-11: a pending package with ledger_missing=>0 is still returned');
}

# =============================================================================
# AC-12 (disk-backed _load_state): a blueprint.md row with no packages/<pkg>.md
# derives ledger_missing=>1; a sibling WITH a ledger derives 0; status stays
# 'pending' in both cases.
# =============================================================================
{
    my $dir = "$ROOT/bp12";
    mkdir $dir or die; mkdir "$dir/packages" or die; mkdir "$dir/runs" or die;
    write_file("$dir/blueprint.md", join("\n",
        '# T12', '', '## Package status', '',
        '| pkg | deliverable | depends_on | model | status |',
        '|--|--|--|--|--|',
        '| withledger | d | — | sonnet | pending |',
        '| noledger | d | — | sonnet | pending |',
        '',
    ));
    write_file("$dir/packages/withledger.md",
        "---\npackage: withledger\nstatus: pending\nwrite_set: a/wl/\ntest_paths: a/wl/\nlast_updated: 2026-08-01T00:00:00Z\n---\n# withledger\n");
    # NOTE: deliberately NO packages/noledger.md written.

    my ($meta, $status) = BpOrch::_load_state($dir, "$dir/runs");
    is($meta->{withledger}{ledger_missing}, 0, 'AC-12: a package WITH a ledger -> ledger_missing=0');
    is($meta->{noledger}{ledger_missing}, 1, 'AC-12: a package with NO ledger file -> ledger_missing=1');
    is($status->{noledger}, 'pending', 'AC-12: the ledger-less package\'s derived status is still \'pending\' (unchanged)');
    is($status->{withledger}, 'pending', 'AC-12: sibling status also \'pending\' (both fresh)');
}

# =============================================================================
# AC-13 / AC-14: full BpOrch::run() across >=2 ticks with an injected launch
# recorder that faithfully mimics bp-launch.sh's real failure mode (hard-exit 1
# when packages/<pkg>.md is absent -- spec §1, bp-launch.sh:42). Two sequential
# once=>1 calls model two ticks; state persists on disk (registry.json,
# orchestrator.log, ledger files) between them exactly as a real daemon's ticks
# would. Never lets the real bp-launch.sh run -- launch is always the injected
# recorder (spec §4.1 seam 5).
# =============================================================================
{
    my $dir = "$ROOT/bp1314";
    mkdir $dir or die; mkdir "$dir/packages" or die; mkdir "$dir/runs" or die;
    write_file("$dir/blueprint.md", join("\n",
        '# T1314', '', '## Package status', '',
        '| pkg | deliverable | depends_on | model | status |',
        '|--|--|--|--|--|',
        '| pkgready | d | — | sonnet | pending |',
        '| pkgheld | d | — | sonnet | pending |',
        '',
    ));
    write_file("$dir/packages/pkgready.md",
        "---\npackage: pkgready\nstatus: pending\nwrite_set: a/ready/\ntest_paths: a/ready/\nlast_updated: 2026-08-01T00:00:00Z\n---\n# pkgready\n\n## Next action\n\ngo\n");
    # NOTE: deliberately NO packages/pkgheld.md at the start.

    write_file("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-T105-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-T105REF-bbbbbbbbbbbbbbbb',
        expiresAt => (time + 5*3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));

    my $usage_ok = $J->encode({ five_hour=>{utilization=>10, resets_at=>'2099-01-01T00:00:00+00:00'},
                                 seven_day=>{utilization=>5,  resets_at=>'2099-01-01T00:00:00+00:00'} });

    my $NOW = time;
    my $tunables = { ceil5=>85, ceil7=>90, drain=>600, max_par=>4, cap=>5, flat=>600, watch_tick=>0,
                      keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
                      tele_retry=>3, usage_fail=>60, busy_path=>"$ROOT/busy1314" };

    my @launched;   # every $pkg name the injected launch closure was called with
    my $launch = sub {
        my ($a) = @_;
        my $pkg = $a->{pkg};
        push @launched, $pkg;
        # Faithful mimic of bp-launch.sh:42's real behaviour: hard-exit 1 when
        # the package's ledger file does not exist on disk.
        return (-f "$dir/packages/$pkg.md") ? 0 : 1;
    };

    my %run_opts = (
        blueprint => 'T1314', bp_dir => $dir, creds_path => "$dir/creds.json",
        tunables => $tunables, once => 1, now => sub { $NOW }, sleep => sub { },
        http_get  => sub { { status => 200, content => $usage_ok } },
        http_post => sub { { status => 200, content => '{}' } },
        launch    => $launch,
    );

    # ---- TICK 1: pkgheld has no ledger yet ----
    BpOrch::run({ %run_opts });
    my @launched_tick1 = @launched;

    ok((grep { $_ eq 'pkgready' } @launched_tick1),
        'AC-14: a ready sibling (pkgready) IS launched in the same tick as the held package');
    ok(!(grep { $_ eq 'pkgheld' } @launched_tick1),
        'AC-13: the launch recorder is NEVER called for the ledger-less package while its ledger is absent');

    my @events_tick1 = log_events("$dir/runs/orchestrator.log");
    my @failed_for_held = grep { ($_->{type} // '') eq 'launch_failed'
                               && (($_->{package} // '') eq 'pkgheld') } @events_tick1;
    is(scalar(@failed_for_held), 0,
        'AC-13: no launch_failed event is logged for the ledger-less package');

    my @awaiting = grep { ($_->{type} // '') eq 'awaiting_ledger'
                        && (($_->{package} // '') eq 'pkgheld') } @events_tick1;
    is(scalar(@awaiting), 1,
        'AC-13: exactly ONE awaiting_ledger event is written for the held package');
    like(($awaiting[0]{ledger} // ''), qr{packages/pkgheld\.md},
        'AC-13: the awaiting_ledger event names packages/pkgheld.md') if @awaiting;

    # ---- The ledger appears mid-run (simulates an author creating it) ----
    write_file("$dir/packages/pkgheld.md",
        "---\npackage: pkgheld\nstatus: pending\nwrite_set: a/held/\ntest_paths: a/held/\nlast_updated: 2026-08-01T00:00:00Z\n---\n# pkgheld\n\n## Next action\n\ngo\n");

    # ---- TICK 2: pkgheld now has a ledger ----
    @launched = ();
    BpOrch::run({ %run_opts });
    my @launched_tick2 = @launched;

    ok((grep { $_ eq 'pkgheld' } @launched_tick2),
        'AC-14: once the ledger file appears, the very next tick launches the previously-held package');

    my @events_all = log_events("$dir/runs/orchestrator.log");
    my @awaiting_all = grep { ($_->{type} // '') eq 'awaiting_ledger'
                            && (($_->{package} // '') eq 'pkgheld') } @events_all;
    is(scalar(@awaiting_all), 1,
        'AC-13: across both ticks, still exactly ONE awaiting_ledger event total (deduped, not re-fired once the ledger exists)');

    my @failed_all = grep { ($_->{type} // '') eq 'launch_failed'
                          && (($_->{package} // '') eq 'pkgheld') } @events_all;
    is(scalar(@failed_all), 0,
        'AC-13: across both ticks, still no launch_failed event for pkgheld (no attempt was ever burned on it)');
}

# =============================================================================
# ORACLE-GAP (redteam MAJOR-4, step6): BpOrch::dag_stall's own documented
# exhaustiveness invariant (bp-orchestrator.pl:421-425 -- "stalled == 1
# implies blockers || unresolvable is non-empty") is broken by the
# ledger_missing filter inside ready_packages: a pending package whose deps
# ARE met but whose ledger is missing makes ready_packages return empty for a
# reason OTHER than an unmet dependency, and dag_stall has no way to explain
# why. Measured (unit level, pure call, no process): with a01=done and
# a02=pending/ledger_missing=>1/deps=[a01] (a MET dependency), dag_stall
# reports stalled=1 but BOTH blockers and unresolvable come back empty --
# the invariant its own doc comment claims is violated. The only artefact
# anywhere is a single JSONL awaiting_ledger line that nothing reads (grepped
# across plugins/ by the red-team; no status/reporter/watcher/dashboard
# surface consumes it) -- an infinite, silent hold.
# =============================================================================
{
    my $meta = {
        a01 => { deps => [], write_set => 'a/a01/', ledger_missing => 0 },
        a02 => { deps => ['a01'], write_set => 'a/a02/', ledger_missing => 1 },
    };
    my $status = { a01 => 'done', a02 => 'pending' };
    my $r = BpOrch::dag_stall($meta, $status, []);
    is($r->{stalled}, 1, 'ORACLE-GAP(MAJOR-4) precondition: a held package with a MET dependency and nothing running is reported stalled');
    ok((scalar(@{ $r->{blockers} // [] }) || scalar(@{ $r->{unresolvable} // [] })),
        "ORACLE-GAP(MAJOR-4): dag_stall's own exhaustiveness invariant must hold -- stalled==1 must imply blockers or unresolvable is non-empty, but the held package explains neither")
        or diag('blockers=' . scalar(@{ $r->{blockers} // [] }) . ' unresolvable=' . scalar(@{ $r->{unresolvable} // [] }) . ' reason=' . ($r->{reason} // ''));
}

# =============================================================================
# ORACLE-GAP (redteam MAJOR-4, step6): held state must be observable by SOME
# surface other than one dedup'd JSONL line, so an operator who joins after
# the first tick (or any automated watcher) can find out why nothing is
# progressing. Run several MORE ticks than AC-13/14 with the ledger NEVER
# appearing (a genuinely permanent hold, not one that resolves on tick 2),
# then look for an artefact under runs/escalations/ -- the one surface this
# codebase already uses for "an operator needs to look at this"
# (queue_needs_you, bp-orchestrator.pl:1347). Today nothing ever calls
# queue_needs_you for a ledger_missing hold, so this directory stays empty
# forever no matter how many ticks pass.
# =============================================================================
{
    my $dir = "$ROOT/bp105held";
    mkdir $dir or die; mkdir "$dir/packages" or die; mkdir "$dir/runs" or die;
    write_file("$dir/blueprint.md", join("\n",
        '# T105held', '', '## Package status', '',
        '| pkg | deliverable | depends_on | model | status |',
        '|--|--|--|--|--|',
        '| pkgready | d | — | sonnet | pending |',
        '| pkgheld | d | — | sonnet | pending |',
        '',
    ));
    write_file("$dir/packages/pkgready.md",
        "---\npackage: pkgready\nstatus: pending\nwrite_set: a/ready/\ntest_paths: a/ready/\nlast_updated: 2026-08-01T00:00:00Z\n---\n# pkgready\n\n## Next action\n\ngo\n");
    # NOTE: deliberately NO packages/pkgheld.md, EVER, across every tick below.

    write_file("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-T105h-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-T105hREF-bbbbbbbbbbbbbbbb',
        expiresAt => (time + 5*3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));

    my $usage_ok = $J->encode({ five_hour=>{utilization=>10, resets_at=>'2099-01-01T00:00:00+00:00'},
                                 seven_day=>{utilization=>5,  resets_at=>'2099-01-01T00:00:00+00:00'} });
    my $NOW = time;
    my $tunables = { ceil5=>85, ceil7=>90, drain=>600, max_par=>4, cap=>5, flat=>600, watch_tick=>0,
                      keeper_int=>600, keeper_bo=>120, thresh_min=>60, jit_lo=>0, jit_hi=>0,
                      tele_retry=>3, usage_fail=>60, busy_path=>"$ROOT/busy105held" };
    my $launch = sub {
        my ($a) = @_;
        return (-f "$dir/packages/$a->{pkg}.md") ? 0 : 1;
    };
    my %run_opts = (
        blueprint => 'T105held', bp_dir => $dir, creds_path => "$dir/creds.json",
        tunables => $tunables, once => 1, now => sub { $NOW }, sleep => sub { },
        http_get  => sub { { status => 200, content => $usage_ok } },
        http_post => sub { { status => 200, content => '{}' } },
        launch    => $launch,
    );
    # Ten ticks, ledger never appears -- a genuinely permanent hold.
    for (1 .. 10) { BpOrch::run({ %run_opts }); }

    my @needs_you_files;
    if (opendir(my $dh, "$dir/runs/escalations")) {
        @needs_you_files = grep { /\.json$/ } readdir $dh;
        closedir $dh;
    }
    my $found;
    for my $f (@needs_you_files) {
        my $rec = eval { $J->decode(read_file("$dir/runs/escalations/$f")) };
        next unless ref $rec eq 'HASH';
        $found = $rec if (($rec->{package} // '') eq 'pkgheld');
    }
    ok(defined $found,
        'ORACLE-GAP(MAJOR-4): after 10 ticks of a permanent ledger_missing hold, SOME operator-visible signal exists under runs/escalations/ for the held package')
        or diag('escalations dir listing: ' . join(',', @needs_you_files) . '; the only artefact today is a single deduped awaiting_ledger JSONL line nothing reads');
}

# =============================================================================
# AC-15: `bp-blueprint.pl add-package` for a package with no ledger prints the
# spec's notice on stderr, exits 0, and the row is present in the table.
# =============================================================================
{
    my $SCRIPT = "$BUTLER/scripts/bp-blueprint.pl";
    my %CLEAN_ENV = map { ($_ => $ENV{$_}) } grep { !/^BP_/ } keys %ENV;
    my $pn = 0;

    my $dir = "$ROOT/bp15";
    mkdir $dir or die; mkdir "$dir/packages" or die;
    my $bp = "$dir/blueprint.md";
    write_file($bp, join("\n",
        '# T15', '', '## Package status', '',
        '| pkg | deliverable | depends_on | status | model |',
        '|---|---|---|---|---|',
        "| existing | first thing | \xE2\x80\x94 | \xE2\xAC\x9C pending | sonnet |",
        '',
    ));
    # deliberately NO packages/newpkg.md ledger exists.

    my ($outf, $errf) = ("$ROOT/o15", "$ROOT/e15");
    write_file($outf, ''); write_file($errf, '');
    local %ENV = (%CLEAN_ENV, BSCRIPT => fwd($SCRIPT), BOUT => fwd($outf), BERR => fwd($errf));
    my $rc = system('bash', '-c',
        'timeout 30 perl "$BSCRIPT" "$@" > "$BOUT" 2> "$BERR"', 'bp-blueprint',
        'add-package', '--file', $bp, '--pkg', 'newpkg', '--deliverable', 'a brand new thing');
    $rc = $rc >> 8;
    my $err = read_file($errf) // '';
    my $out = read_file($outf) // '';

    is($rc, 0, 'AC-15: add-package for a package with no ledger still exits 0');
    like($err, qr/no ledger/i, 'AC-15: stderr notice names "no ledger"');
    like($err, qr/newpkg/, 'AC-15: stderr notice names the package');
    like($err, qr/HOLD|hold/, 'AC-15: stderr notice says the orchestrator will HOLD it');
    like(read_file($bp), qr/\bnewpkg\b/, 'AC-15: the row was actually added to the table');
}

done_testing();
