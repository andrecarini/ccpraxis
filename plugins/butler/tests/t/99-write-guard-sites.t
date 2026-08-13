#!/usr/bin/env perl
# t/99-write-guard-sites.t — the four converted sites of a01-write-integrity-
# reread-under-lock (spec §3 S1-S4, §4 AC9-AC14/AC16/AC17).
#
# Every race is reproduced through the NAMED seams of spec §8, never by
# sleeping: $BpOrch::PID_ALIVE_FN (S1), $BpWrite::AFTER_LOCK_HOOK (S2/S3/S4),
# %BpOrch::DECISION_VALIDITY (S2). Assigning to a fully-qualified package
# variable (e.g. `$BpWrite::AFTER_LOCK_HOOK = ...`) autovivifies that package
# slot even though bp-write-guard.pl (package BpWrite) does not exist yet, so
# the seam-setup code itself never dies — what fails right now is the SITE
# FUNCTION silently ignoring the seam (today's behaviour), which is the
# correct failure mode for an oracle written before the primitive is wired in.
#
# CLI-level S1 envelope tests (AC9/AC16) use REAL pids ($$ = alive, a huge
# pinned-dead literal = dead — same technique as t/61-judge-starvation.t's
# $DEAD) rather than a seam, because bp-answer-decision.pl is invoked as a
# SUBPROCESS and cannot share an in-process coderef with the test. Liveness of
# a concrete pid is a synchronous OS fact, not a scheduling race, so this does
# not violate "no sleep, no timing".
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

require "$Bin/../../scripts/bp-orchestrator.pl";
my $ANSWER_SCRIPT = "$Bin/../../scripts/bp-answer-decision.pl";
require $ANSWER_SCRIPT;   # loads BpAnswer; also (re)loads BpOrch, harmlessly

my $J    = JSON::PP->new->canonical;
my $DEAD = 2_000_000_000;   # pinned dead-pid literal (t/61-judge-starvation.t:79 precedent)
my $NOW  = time;

# ═══════════════════════════════════════════════════════════════════════════
# Generic scaffolding
# ═══════════════════════════════════════════════════════════════════════════
sub write_file {
    my ($p, $c) = @_;
    (my $d = $p) =~ s{[\\/][^\\/]+$}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $p or die "write $p: $!";
    print $fh $c;
    close $fh;
}
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or return ''; local $/; my $c = <$fh>; close $fh; $c }
sub read_registry {
    my ($bpdir) = @_;
    my $txt = slurp("$bpdir/runs/registry.json");
    return {} unless length $txt;
    my $d = eval { JSON::PP->new->decode($txt) };
    return (ref $d eq 'HASH') ? $d : {};
}
sub log_events {
    my ($path) = @_;
    return () unless -f $path;
    return map { eval { $J->decode($_) } } grep { length } split /\n/, slurp($path);
}
sub shq { my ($s) = @_; $s =~ s/'/'\\''/g; "'$s'" }

# ── S1/S2 fixture: a bare ledger + registry, no full run/ scaffolding ───────
sub mk_ledger_bp {
    my (%o) = @_;
    my $pkg    = $o{pkg}    // 'alpha';
    my $status = $o{status} // 'pending';
    my $bpdir  = tempdir(CLEANUP => 1);
    make_path("$bpdir/packages");
    make_path("$bpdir/runs");
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: bp\nstatus: $status\nwrite_set: p/$pkg/\n"
      . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $pkg\n");
    if ($o{registry} || $o{with_registry}) {
        write_file("$bpdir/runs/registry.json",
            $J->encode({ packages => { $pkg => ($o{registry} // { status => $status }) } }));
    }
    return ($bpdir, $pkg);
}
sub ledger_status {
    my ($bpdir, $pkg) = @_;
    my $txt = slurp("$bpdir/packages/$pkg.md");
    return ($txt =~ /^status:\s*(\S+)/m) ? $1 : undef;
}

# ═════════════════════════════════════════════════════════════════════════
# S1 — BpOrch::_set_ledger_status: coordinator-alive refusal
# AC9 (behaviors 13, 14, 16), AC10 (behavior 15)
# ═════════════════════════════════════════════════════════════════════════
{
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'blocked');
    my $runs = "$bpdir/runs";
    local $BpOrch::PID_ALIVE_FN = sub { 1 };   # coordinator alive
    my $ret = BpOrch::_set_ledger_status($bpdir, $pkg, 'pending', { runs => $runs });
    is($ret, 0, 'S1/AC9/behavior13: _set_ledger_status refuses (returns 0) while the coordinator pid is alive');
    is(ledger_status($bpdir, $pkg), 'blocked', "S1/AC9/behavior13: the ledger's status: line is byte-unchanged on refusal");
}
{
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'blocked');
    my $runs = "$bpdir/runs";
    local $BpOrch::PID_ALIVE_FN = sub { 0 };   # coordinator dead
    my $ret = BpOrch::_set_ledger_status($bpdir, $pkg, 'pending', { runs => $runs });
    is($ret, 1, 'S1/AC9/behavior15: _set_ledger_status proceeds (returns 1) when no coordinator pid is alive');
    is(ledger_status($bpdir, $pkg), 'pending', 'S1/AC9/behavior15: ledger status updated to the requested value');
}
{
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'blocked');
    my $runs = "$bpdir/runs";
    local $BpOrch::PID_ALIVE_FN = sub { 1 };   # alive, but supersede overrides (the --action reset shape)
    my $ret = BpOrch::_set_ledger_status($bpdir, $pkg, 'pending', { runs => $runs, supersede => 1 });
    is($ret, 1, 'S1/AC9/behavior14: supersede=>1 proceeds even while the coordinator is alive');
    is(ledger_status($bpdir, $pkg), 'pending', 'S1/AC9/behavior14: ledger updated under supersede');
}
{
    # edge case 4 (spec §5.4): internal callers passing no `runs` opt must not
    # trip the liveness check — the orchestrator writing its OWN packages'
    # ledgers must not refuse itself.
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'blocked');
    local $BpOrch::PID_ALIVE_FN = sub { 1 };
    my $ret = BpOrch::_set_ledger_status($bpdir, $pkg, 'pending');
    is($ret, 1, 'edge case 4: no `runs` opt -> no liveness check -> orchestrator does not refuse itself');
}
{
    # AC10: the read-back is not optional even on the successful (dead-coordinator) path.
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'blocked');
    my $runs = "$bpdir/runs";
    local $BpOrch::PID_ALIVE_FN = sub { 0 };
    local $BpWrite::AFTER_COMMIT_HOOK = sub {
        my $f = "$bpdir/packages/$pkg.md";
        my $txt = slurp($f);
        $txt =~ s/^status:.*$/status: clobbered-post-commit/m;
        write_file($f, $txt);
    };
    my $ret = BpOrch::_set_ledger_status($bpdir, $pkg, 'pending', { runs => $runs });
    is($ret, 0, 'S1/AC10: a failed read-back yields 0 even though the rename itself succeeded');
}

# ═════════════════════════════════════════════════════════════════════════
# S1b — BpOrch::update_registry_pkg: read-back confirmation
# AC10
# ═════════════════════════════════════════════════════════════════════════
{
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'blocked', with_registry => 1);
    my $runs = "$bpdir/runs";
    local $BpWrite::AFTER_COMMIT_HOOK = sub {
        write_file("$runs/registry.json", $J->encode({ packages => { $pkg => { status => 'clobbered' } } }));
    };
    my $ret = BpOrch::update_registry_pkg($runs, $pkg, { status => 'pending' });
    is($ret, 0, 'S1b/AC10: update_registry_pkg read-back-confirms its own write; a clobbered read-back yields 0');
}
{
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'blocked', with_registry => 1);
    my $runs = "$bpdir/runs";
    my $ret = BpOrch::update_registry_pkg($runs, $pkg, { status => 'pending' });
    is($ret, 1, 'S1b control: update_registry_pkg still succeeds on the ordinary (unmolested) path');
    is(read_registry($bpdir)->{packages}{$pkg}{status}, 'pending', 'S1b control: registry actually updated');
}

# ═════════════════════════════════════════════════════════════════════════
# S1 — CLI envelope (bp-answer-decision.pl, subprocess, REAL pids)
# AC9, AC16
# ═════════════════════════════════════════════════════════════════════════
sub mk_answer_bp {
    my (%o) = @_;
    my $pkg    = $o{pkg}    // 'alpha';
    my $status = $o{status} // 'blocked';
    my $bpdir  = tempdir(CLEANUP => 1);
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nblueprint: bp\nstatus: $status\nwrite_set: p/$pkg/\n"
      . "last_updated: 2020-01-01T00:00:00Z\n---\n\n# $pkg\n\n## Next action\n\nx\n\n"
      . "## Decisions & attempt log\n\n_(none yet)_\n");
    write_file("$bpdir/runs/registry.json",
        $J->encode({ packages => { $pkg => ($o{registry} // { status => $status, pid => $DEAD }) } }));
    return ($bpdir, $pkg);
}
sub run_answer_cli {
    my ($bpdir, @args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $ANSWER_SCRIPT, 'bp', '--bp-dir', $bpdir, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}
{
    my ($bpdir, $pkg) = mk_answer_bp(status => 'blocked', registry => { status => 'blocked', pid => $$ });   # alive: our own pid
    make_path("$bpdir/runs/needs-you");
    my $decfile = "$bpdir/runs/needs-you/$pkg--abc.json";
    write_file($decfile, $J->encode({ package => $pkg, blueprint => 'bp', kind => 'stuck-package',
        question => 'q', context => 'c', created_at => 10 }));
    my $before = slurp("$bpdir/packages/$pkg.md");

    my ($rc, $out) = run_answer_cli($bpdir, '--decision', "$pkg--abc", '--action', 'accept');
    is($rc, 6, 'S1/AC9: answering while the registry pid is alive exits 6');
    is(slurp("$bpdir/packages/$pkg.md"), $before, "S1/AC9: the ledger's status: line is byte-unchanged");
    ok(-f $decfile, 'S1/AC9/AC16/behavior16: the queued decision file is NOT deleted');
    my $decoded = eval { $J->decode($out) };
    ok(defined $decoded, 'S1/AC9: refusal still prints a JSON object on stdout') or diag($out);
    if ($decoded) {
        is($decoded->{ok}, JSON::PP::false, 'S1/AC9/AC16: JSON ok:false');
        is($decoded->{refused}, 'coordinator-alive', 'S1/AC9/AC16: JSON refused:"coordinator-alive"');
    }
}
{
    # --action reset proceeds and exits 0 (behavior 14) even with an alive pid.
    my ($bpdir, $pkg) = mk_answer_bp(status => 'blocked', registry => { status => 'blocked', pid => $$ });
    my ($rc, $out) = run_answer_cli($bpdir, '--package', $pkg, '--action', 'reset');
    is($rc, 0, 'S1/AC9/behavior14: --action reset proceeds and exits 0 despite an alive coordinator pid');
}
{
    # behavior16: a refused answer leaves runs/needs-you/ entirely unchanged.
    my ($bpdir, $pkg) = mk_answer_bp(status => 'blocked', registry => { status => 'blocked', pid => $$ });
    make_path("$bpdir/runs/needs-you");
    my $decfile = "$bpdir/runs/needs-you/$pkg--xyz.json";
    write_file($decfile, $J->encode({ package => $pkg, blueprint => 'bp', kind => 'stuck-package',
        question => 'q', context => 'c', created_at => 10 }));
    run_answer_cli($bpdir, '--decision', "$pkg--xyz", '--action', 'accept');
    opendir my $dh, "$bpdir/runs/needs-you" or die;
    my @files = sort grep { !/^\./ } readdir $dh;
    closedir $dh;
    is_deeply(\@files, ["$pkg--xyz.json"], 'S1/AC9/behavior16: runs/needs-you/ unchanged after a refused answer');
}
{
    # dead pid -> today's write proceeds, and the ledger status/read-back is honoured (AC10/behavior15/30).
    my ($bpdir, $pkg) = mk_answer_bp(status => 'blocked', registry => { status => 'blocked', pid => $DEAD });
    make_path("$bpdir/runs/needs-you");
    my $decfile = "$bpdir/runs/needs-you/$pkg--dd1.json";
    write_file($decfile, $J->encode({ package => $pkg, blueprint => 'bp', kind => 'stuck-package',
        question => 'q', context => 'c', created_at => 10 }));
    my ($rc, $out) = run_answer_cli($bpdir, '--decision', "$pkg--dd1", '--action', 'accept');
    isnt($rc, 6, 'S1/AC9 control: a dead coordinator pid never produces the coordinator-alive refusal (exit != 6)');
}

# ═════════════════════════════════════════════════════════════════════════
# S2 — BpOrch::queue_needs_you: refuse-a-decision-against-a-terminal-package
# AC11 (behaviors 17,18), AC12 (behaviors 19-23), AC17 (the S2 seam)
# ═════════════════════════════════════════════════════════════════════════
{
    # AC11 primary race: pending at read time, AFTER_LOCK_HOOK flips it to
    # 'done' inside the read-decide-write gap. The re-read (under
    # <bpdir>/packages/<pkg>.md.lock) must see 'done' and refuse.
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'pending');
    my $runs = "$bpdir/runs";
    local %BpOrch::DECISION_VALIDITY = ('stuck-package' => ['done', 'dropped']);
    local $BpWrite::AFTER_LOCK_HOOK = sub {
        my $f = "$bpdir/packages/$pkg.md";
        my $txt = slurp($f);
        $txt =~ s/^status:.*$/status: done/m;
        write_file($f, $txt);
    };
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => 'stuck-package', question => 'q', context => 'c', created_at => 10, category => 'unclassified' },
        $bpdir);
    is($ret, 0, 'S2/AC11/behavior17-18: stuck-package refused once the re-read (under the ledger lock) finds status done');
    my @files = glob("$runs/needs-you/*.json");
    is(scalar(@files), 0, 'S2/AC11: no decision file appears in runs/needs-you/');
    like(slurp("$runs/orchestrator.log"), qr/"type":"write_guard"/,
        'S2/AC11: a write_guard log event is emitted for the refusal');
}
{
    # AC12/behavior19: an unlisted kind is never silenced (Decision 5), whatever the re-read status.
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'pending');
    my $runs = "$bpdir/runs";
    local %BpOrch::DECISION_VALIDITY = ('stuck-package' => ['done', 'dropped']);
    local $BpWrite::AFTER_LOCK_HOOK = sub {
        my $f = "$bpdir/packages/$pkg.md";
        my $txt = slurp($f);
        $txt =~ s/^status:.*$/status: done/m;
        write_file($f, $txt);
    };
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => 'totally-unlisted-kind', question => 'q', context => 'c', created_at => 11, category => 'unclassified' },
        $bpdir);
    ok($ret, 'S2/AC12/behavior19: an unlisted kind still queues no matter the re-read status');
    my @f19 = glob("$runs/needs-you/*.json");
    is(scalar(@f19), 1, 'S2/AC12/behavior19: exactly one decision file for this fixture');
}
for my $kind (qw(judge-starved judge-fail harvest-failure)) {
    # AC12/behavior21: harvest/judge escalations legitimately target `done` packages.
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'done');
    my $runs = "$bpdir/runs";
    local %BpOrch::DECISION_VALIDITY = ('stuck-package' => ['done', 'dropped']);
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => $kind, question => 'q', context => 'c', created_at => 12, category => 'oracle' },
        $bpdir);
    ok($ret, "S2/AC12/behavior21: kind=$kind queues against a done package (harvest audits only run on done packages)");
}
for my $st (qw(blocked parked)) {
    # AC12/behavior20: _block_and_queue must not refuse its own escalation.
    my ($bpdir, $pkg) = mk_ledger_bp(status => $st);
    my $runs = "$bpdir/runs";
    local %BpOrch::DECISION_VALIDITY = ('stuck-package' => ['done', 'dropped']);
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => 'stuck-package', question => 'q', context => 'c', created_at => 13, category => 'unclassified' },
        $bpdir);
    ok($ret, "S2/AC12/behavior20: stuck-package still queues when status is $st (not in stuck-package's refusal set)");
}
{
    # AC12/behavior22: an unreadable ledger degrades toward delivery, not toward silence.
    my $bpdir = tempdir(CLEANUP => 1);
    make_path("$bpdir/packages");
    make_path("$bpdir/runs");
    my $pkg  = 'ghost';   # no packages/ghost.md at all
    my $runs = "$bpdir/runs";
    local %BpOrch::DECISION_VALIDITY = ('stuck-package' => ['done', 'dropped']);
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => 'stuck-package', question => 'q', context => 'c', created_at => 14, category => 'unclassified' },
        $bpdir);
    ok($ret, 'S2/AC12/behavior22: an unreadable ledger still queues (uncertainty resolves toward delivery)');
    my $log = slurp("$runs/orchestrator.log");
    unlike($log, qr/"type":"write_guard"[^\n]*"outcome":"refused"/,
        'S2/AC12/behavior22: no write_guard/refused event is logged for an unreadable ledger');
    like($log, qr/validity_unknown/, 'S2/AC12/behavior22: a validity_unknown event records the degradation instead');
}
{
    # AC12/behavior23: the existing dedupe still short-circuits, still returns the existing path.
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'pending');
    my $runs = "$bpdir/runs";
    local %BpOrch::DECISION_VALIDITY = ('stuck-package' => ['done', 'dropped']);
    my $ret1 = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => 'stuck-package', question => 'q', context => 'c', created_at => 15, category => 'unclassified' },
        $bpdir);
    my $ret2 = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => 'stuck-package', question => 'q', context => 'c', created_at => 16, category => 'unclassified' },
        $bpdir);
    is($ret2, $ret1, 'S2/AC12/behavior23: a repeat (package,kind) call returns the SAME existing path');
    my @f23 = glob("$runs/needs-you/*.json");
    is(scalar(@f23), 1, 'S2/AC12/behavior23: dedupe still short-circuits -- only one file total');
}
{
    # AC11 floor: %BpOrch::DECISION_VALIDITY must exist and carry at least the stuck-package row.
    ok(exists $BpOrch::DECISION_VALIDITY{'stuck-package'},
        'S2/AC11: %BpOrch::DECISION_VALIDITY carries a stuck-package row')
        if %BpOrch::DECISION_VALIDITY;
    ok(0, 'S2/AC11: %BpOrch::DECISION_VALIDITY is not yet defined/populated by the orchestrator')
        unless %BpOrch::DECISION_VALIDITY;
}

# ═════════════════════════════════════════════════════════════════════════
# S3/S4 harness (mirrors t/61-judge-starvation.t's shape; reimplemented here
# since a test file cannot `require` another test script as a module).
# ═════════════════════════════════════════════════════════════════════════
my $ROOT = tempdir(CLEANUP => 1);
sub write_creds {
    my ($p) = @_;
    write_file($p, $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-AAA-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-RRR-bbbbbbbbbbbbbbbb',
        expiresAt => ($NOW + 5 * 3600) * 1000, scopes => ['user:inference'], subscriptionType => 'max', rateLimitTier => 'x' } }));
}
my $bpn = 0;
sub mk_bp {
    my ($pkgs, $registry) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    mkdir $dir; mkdir "$dir/packages"; mkdir "$dir/runs";
    open my $b, '>', "$dir/blueprint.md" or die;
    print $b "# T$bpn\n\n## Package status\n\n| pkg | deliverable | depends_on | model | status |\n|--|--|--|--|--|\n";
    print $b "| $_->[0] | d | $_->[1] | sonnet | $_->[2] |\n" for @$pkgs;
    close $b;
    for my $p (@$pkgs) {
        write_file("$dir/packages/$p->[0].md",
            "---\npackage: $p->[0]\nblueprint: T$bpn\nstatus: $p->[2]\nwrite_set: $p->[3]\ntest_paths: $p->[3]\n"
          . "last_updated: 2026-06-24T00:00:00Z\n---\n# $p->[0]\n\n## Next action\n\ngo\n");
    }
    write_file("$dir/runs/registry.json", $J->encode({ packages => $registry })) if $registry;
    write_creds("$dir/creds.json");
    return $dir;
}
my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                             seven_day => { utilization => 5,  resets_at => '2099-01-01T12:00:00+00:00' } });
sub my_tun {
    my %o = @_;
    return { ceil5 => 85, ceil7 => 90, drain => 600, max_par => 2, cap => 5, flat => 600, watch_tick => 0,
        keeper_int => 600, keeper_bo => 120, thresh_min => 60, jit_lo => 0, jit_hi => 0, tele_retry => 3, usage_fail => 60,
        busy_path => "$ROOT/busy.$bpn", harvest => 'audit', resolve_cap => 1, corr_cap => 1, judge_to => 1800,
        judge_spawn_cap => 3, harvest_reaudit_cap => 2, harvest_defer_cap => 2, %o };
}
sub run_once {
    my ($dir, %o) = @_;
    my (@launched, @spawned);
    BpOrch::run({
        blueprint => 'T', bp_dir => $dir, creds_path => "$dir/creds.json",
        tunables => ($o{tunables} || my_tun(%{ $o{tun} || {} })),
        once => 1, now => ($o{now} || sub { $NOW }), sleep => sub { },
        http_get  => sub { { status => 200, content => $USAGE_OK } },
        http_post => sub { { status => 200, content => '{}' } },
        launch    => sub { push @launched, $_[0]; 0 },
        spawn_judge => ($o{spawn_judge} || sub { push @spawned, $_[0]; 0 }),
    });
    return { launched => \@launched, spawned => \@spawned };
}
sub reg_of { my $d = shift; BpOrch::read_registry("$d/runs") }
sub needs_you {
    my $d = shift . '/runs/needs-you';
    return () unless -d $d;
    opendir my $h, $d;
    my @j = map { eval { $J->decode(slurp("$d/$_")) } } grep { /\.json$/ } readdir $h;
    closedir $h;
    return @j;
}
sub seed_verdict {
    my ($dir, $kind, $pkg, $obj) = @_;
    my $f = BpOrch::judge_verdict_path("$dir/runs", $kind, $pkg);
    make_path("$dir/runs/$kind");
    write_file($f, $J->encode($obj));
}
sub mk_pid_file    { my ($dir, $kind, $pkg, $pid) = @_; write_file("$dir/runs/$kind/$pkg.pid", $pid); }
sub mk_judge_jsonl { my ($dir, $kind, $pkg, $obj) = @_; write_file("$dir/runs/$kind/$pkg.jsonl", $J->encode($obj) . "\n"); }
sub bump_last_updated {
    my ($dir, $pkg, $epoch) = @_;
    my @g = gmtime($epoch);
    my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5]+1900, $g[4]+1, $g[3], $g[2], $g[1], $g[0]);
    my $f = "$dir/packages/$pkg.md";
    my $txt = slurp($f);
    $txt =~ s/^last_updated:.*$/last_updated: $iso/m;
    write_file($f, $txt);
}

# ═════════════════════════════════════════════════════════════════════════
# S3 — harvest-verdict application vs a gap that closed
# AC13 (behaviors 24-27), AC17 (the S3 seam)
# ═════════════════════════════════════════════════════════════════════════
{
    # Control: unchanged world -> the verdict applies exactly as today (behavior 27).
    my $dir = mk_bp([['A', '—', 'done', 'p/a/']], { A => { status => 'done', corrective_attempts => 0 } });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict => 'fail', failures => ['criterion X unmet at p/a/x.pl:3'], reason => 'own bug' });
    run_once($dir);
    like(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_reopen"/,
        'S3/AC13 control/behavior27: a matching (unmoved) world still applies the verdict as today');
    like(slurp("$dir/packages/A.md"), qr/^status:\s*pending/m, 'S3/AC13 control: ledger reads status: pending');
}
{
    # Race: last_updated moves past the captured inflight epoch during the gap.
    my $dir = mk_bp([['A', '—', 'done', 'p/a/']], { A => { status => 'done', corrective_attempts => 0 } });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict => 'fail', failures => ['criterion X unmet at p/a/x.pl:3'], reason => 'own bug' });
    local $BpWrite::AFTER_LOCK_HOOK = sub { bump_last_updated($dir, 'A', $NOW + 3600); };
    run_once($dir);
    unlike(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_reopen"/,
        'S3/AC13/behavior25: the verdict is NOT applied once last_updated moved past the captured inflight epoch');
    like(slurp("$dir/packages/A.md"), qr/^status:\s*done/m,
        'S3/AC13/behavior25: ledger status unchanged (still done) when the verdict is refused as stale');
    is((reg_of($dir)->{A}{harvest} // ''), '', "S3/AC13/behavior26: registry harvest left '' so the package is re-audited");
    like(slurp("$dir/runs/orchestrator.log"), qr/verdict-stale/,
        'S3/AC13/behavior25: a write_guard refusal with reason token verdict-stale is logged');
}
{
    # Race: status moves off 'done' during the gap -> same refusal, different trigger.
    my $dir = mk_bp([['A', '—', 'done', 'p/a/']], { A => { status => 'done', corrective_attempts => 0 } });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'A', $NOW);
    seed_verdict($dir, 'harvest', 'A', { verdict => 'fail', failures => ['x'], reason => 'own bug' });
    local $BpWrite::AFTER_LOCK_HOOK = sub {
        my $f = "$dir/packages/A.md";
        my $txt = slurp($f);
        $txt =~ s/^status:.*$/status: blocked/m;
        write_file($f, $txt);
    };
    run_once($dir);
    unlike(slurp("$dir/runs/orchestrator.log"), qr/"type":"harvest_reopen"/,
        'S3/AC13/behavior25(status): the verdict is NOT applied once the ledger left done during the gap');
    my @arc = glob("$dir/runs/harvest/archive/A-*.verdict.json");
    ok(scalar(@arc) >= 1, 'S3/AC13/behavior26: a refused verdict is still archived (re-audited on a later tick, never lost)');
}

# ═════════════════════════════════════════════════════════════════════════
# S4 — judge-death / judge-exit path vs its own state moving
# AC14 (behaviors 28-30), AC17 (the S4 seam)
# ═════════════════════════════════════════════════════════════════════════
{
    # Control: unchanged world -> the second-starvation park behaves exactly as today.
    my $dir = mk_bp([['solo', '—', 'done', 'p/s/']], { solo => { harvest_starve_continuations => 1 } });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW);
    mk_pid_file($dir, 'harvest', 'solo', $DEAD);
    mk_judge_jsonl($dir, 'harvest', 'solo', { type => 'result', subtype => 'error_max_turns', num_turns => 29 });
    my $r = run_once($dir, tun => { harvest_reaudit_cap => 2 });
    is(scalar(grep { ($_->{kind} // '') eq 'judge-starved' } needs_you($dir)), 1,
        'S4/AC14 control/behavior30: an unmoved state still queues judge-starved exactly as today');
}
{
    # Race: the inflight marker reappears with a different epoch during the write gap
    # (spec §8: AFTER_LOCK_HOOK rewriting the inflight marker -- a fresh judge run
    # started concurrently with the death classification above).
    my $dir = mk_bp([['solo', '—', 'done', 'p/s/']], { solo => { harvest_starve_continuations => 1 } });
    BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW);
    mk_pid_file($dir, 'harvest', 'solo', $DEAD);
    mk_judge_jsonl($dir, 'harvest', 'solo', { type => 'result', subtype => 'error_max_turns', num_turns => 29 });
    local $BpWrite::AFTER_LOCK_HOOK = sub { BpOrch::mark_judge_inflight("$dir/runs", 'harvest', 'solo', $NOW + 999); };
    run_once($dir, tun => { harvest_reaudit_cap => 2 });
    is(scalar(grep { ($_->{kind} // '') eq 'judge-starved' } needs_you($dir)), 0,
        'S4/AC14/behavior28-29: no judge-starved decision is queued once the inflight marker moved during the gap');
    like(slurp("$dir/runs/orchestrator.log"), qr/judge-state-moved/,
        'S4/AC14/behavior29: a write_guard refusal event with reason token judge-state-moved is logged');
}

# ═════════════════════════════════════════════════════════════════════════
# AC16 — refusal reported through all three channels, cross-cutting check
# ═════════════════════════════════════════════════════════════════════════
{
    # S2's refusal (first block above) must have logged, returned falsy, AND left no
    # file on disk -- three independent channels, checked together for one refusal.
    my ($bpdir, $pkg) = mk_ledger_bp(status => 'pending');
    my $runs = "$bpdir/runs";
    local %BpOrch::DECISION_VALIDITY = ('stuck-package' => ['done', 'dropped']);
    local $BpWrite::AFTER_LOCK_HOOK = sub {
        my $f = "$bpdir/packages/$pkg.md";
        my $txt = slurp($f);
        $txt =~ s/^status:.*$/status: dropped/m;
        write_file($f, $txt);
    };
    my $ret = BpOrch::queue_needs_you($runs,
        { package => $pkg, blueprint => 'bp', kind => 'stuck-package', question => 'q', context => 'c', created_at => 20, category => 'unclassified' },
        $bpdir);
    ok(!$ret, 'AC16 channel 1: falsy return on refusal');
    my @f16 = glob("$runs/needs-you/*.json");
    is(scalar(@f16), 0, 'AC16 channel 2: no decision file (the site\'s own signalling channel)');
    like(slurp("$runs/orchestrator.log"), qr/"type":"write_guard"/, 'AC16 channel 3: a write_guard log event is present');
}

done_testing();
