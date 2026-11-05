#!/usr/bin/env perl
# platform: any
# acxpraxis-step-2, 2026-11-05: package 15 depended on 03. 03 reported done, so
# the fresh-launch path correctly started 15; an audit-mode harvest judge then
# FAILED 03 and reopened it. 15's coordinator found 03 unfinished and parked
# itself blocked. The orchestrator filed an orphan escalation, the resolver
# answered `relaunch` (its only non-structural action), bp-answer flipped 15 to
# pending, and the WATCHDOG -- which treats any package with a recorded pid as
# "launched" -- relaunched it on the next tick without asking whether its
# dependencies were done. 21 watchdog relaunches in an hour, each one a fresh
# coordinator that read the ledger, saw 03 unfinished, and parked again.
#
# The rule under test: no launch site starts a package whose DAG dependencies
# are not all done (one rule, in _launch_hold, the check every launch site
# already calls), and a coordinator that parks while its dependencies are
# unfinished is put back to pending -- never escalated -- so it waits in the
# DAG like any other pending package and starts when they are done.
#
# Every orchestrator case drives the REAL BpOrch::run, one tick per call, with
# an injected launch recorder; nothing here starts a coordinator.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
require "$BUTLER/scripts/bp-orchestrator.pl";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $T0   = 1_900_000_000;
my $LIVE = 4_242_424;    # the dependency's coordinator: alive throughout

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
sub events {
    my ($dir, $type, $pkg) = @_;
    my @l = grep { length } split /\n/, (read_file("$dir/runs/orchestrator.log") // '');
    return grep { ($_->{type} // '') eq $type && (!defined $pkg || ($_->{package} // '') eq $pkg) }
           map { my $e = eval { $J->decode($_) }; ref $e eq 'HASH' ? $e : () } @l;
}
sub queued {
    my ($dir, $pkg) = @_;
    my $d = "$dir/runs/escalations";
    opendir(my $dh, $d) or return wantarray ? () : 0;
    my @f = sort grep { /\.json\z/ } readdir $dh; closedir $dh;
    return grep { my $r = eval { $J->decode(read_file("$d/$_")) };
                  ref $r eq 'HASH' && ($r->{package} // '') eq $pkg } @f;
}
sub ledger_status {
    my ($dir, $pkg) = @_;
    my $t = read_file("$dir/packages/$pkg.md") // '';
    return $t =~ /^status:\s*(\S+)/m ? $1 : undef;
}
sub set_status {
    my ($dir, $pkg, $st) = @_;
    my $t = read_file("$dir/packages/$pkg.md");
    $t =~ s/^status:.*$/status: $st/m;
    write_file("$dir/packages/$pkg.md", $t);
    # a done dependency has passed its audit, so the harvest judge leaves it alone.
    BpOrch::update_registry_pkg("$dir/runs", $pkg, { harvest => q(pass) }) if $st eq q(done);
}
my $bpn = 0;
# mk_bp([[pkg, deps, ledger status, write_set], ...], {registry seed}) -> dir
sub mk_bp {
    my ($pkgs, $reg) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    make_path("$dir/packages", "$dir/runs");
    write_file("$dir/blueprint.md", join("\n", "# T$bpn", '', '## Package status', '',
        '| pkg | deliverable | depends_on | model |', '|--|--|--|--|',
        (map { "| $_->[0] | d | $_->[1] | sonnet |" } @$pkgs), ''));
    for my $p (@$pkgs) {
        write_file("$dir/packages/$p->[0].md",
            "---\npackage: $p->[0]\nstatus: $p->[2]\nwrite_set: $p->[3]\ntest_paths: $p->[3]\n"
          . "last_updated: 2026-11-05T00:00:00Z\n---\n# $p->[0]\n\n## Next action\n\n"
          . "BLOCKED on dependency: wait for the other package to reach done.\n");
    }
    write_file("$dir/runs/registry.json", $J->encode({ packages => $reg })) if $reg;
    write_file("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-DWG-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-DWGREF-bbbbbbbbbbbbbbbb',
        expiresAt => ($T0 + 400 * 3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
    # the previous coordinator of the dependent ended cleanly, as in the incident.
    write_file("$dir/runs/p15-cost.jsonl",
        $J->encode({ type => 'result', subtype => 'success', num_turns => 9, session_id => 'sid-p15' }) . "\n");
    return $dir;
}
my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T00:00:00+00:00' } });
sub tick {
    my ($dir, $now, $launch) = @_;
    local $SIG{__WARN__} = sub { };
    BpOrch::run({
        blueprint => "T$bpn", bp_dir => $dir, creds_path => "$dir/creds.json",
        tunables  => { ceil5 => 85, ceil7 => 90, drain => 600, max_par => 3, cap => 5,
                       flat => 600, watch_tick => 0, keeper_int => 600, keeper_bo => 120, thresh_min => 60,
                       jit_lo => 0, jit_hi => 0, tele_retry => 3, usage_fail => 60, busy_path => "$dir/busy" },
        once => 1, now => sub { $now }, sleep => sub { },
        http_get  => sub { { status => 200, content => $USAGE_OK } },
        http_post => sub { { status => 200, content => '{}' } },
        pid_alive => sub { defined $_[0] && $_[0] eq $LIVE },
        spawn_judge => sub { 0 },
        launch    => $launch,
    });
}
# p03-make is running (live coordinator); p11-model is done; p15-cost depends on both.
sub world {
    my (%o) = @_;
    return mk_bp([
        ['p03-make',  '-',                   $o{dep_status} // 'running', 'src/make/'],
        ['p11-model', '-',                   'done',                      'src/model/'],
        ['p15-cost',  'p03-make, p11-model', $o{status},                  'src/cost/'],
    ], {
        'p03-make' => { attempt => 1, pid => $LIVE, status => 'running', session_id => 'sid-p03', harvest => ($o{dep_status} // q()) eq q(done) ? q(pass) : q() },
        q(p11-model) => { harvest => q(pass) },
        'p15-cost' => { attempt => ($o{attempt} // 0), pid => 999_999, status => 'running', session_id => 'sid-p15' },
    });
}

# =============================================================================
# W1 -- the incident's steady state: the resolver's `relaunch` left p15-cost
# pending with a recorded (dead) pid, so the watchdog owns it. Its dependency
# is still running. Across 10 ticks it must never be launched, and the hold
# must say why.
# =============================================================================
{
    my $dir = world(status => 'pending');
    my @calls;
    my $launch = sub { push @calls, $_[0]{pkg}; 0 };
    tick($dir, $T0 + 12 * $_, $launch) for 0 .. 9;
    is(scalar(grep { $_ eq 'p15-cost' } @calls), 0,
        'W1: a pending package with a recorded pid is NOT relaunched by the watchdog while a dependency is unfinished')
        or diag('launch calls: ' . join(',', @calls));
    is(scalar(events($dir, 'watchdog_relaunch', 'p15-cost')), 0, 'W1: no watchdog_relaunch line for it');
    my @held = grep { ($_->{reason} // '') eq 'deps_unmet' } events($dir, 'launch_held', 'p15-cost');
    ok(scalar @held, 'W1: the hold is logged as launch_held reason=deps_unmet');
    is_deeply($held[0]{unmet}, ['p03-make'], 'W1: the hold names exactly the unfinished dependency') if @held;
    is(scalar(queued($dir, 'p15-cost')), 0, 'W1: nothing is escalated for a dependency wait');
    is(ledger_status($dir, 'p15-cost'), 'pending', 'W1: the package stays pending');

    # the dependency finishes: the very next tick starts the dependent.
    set_status($dir, 'p03-make', 'done');
    tick($dir, $T0 + 200, $launch);
    is(scalar(grep { $_ eq 'p15-cost' } @calls), 1, 'W1: once every dependency is done, the dependent launches');
}

# =============================================================================
# W2 -- same, but the dead coordinator left the ledger reading `running`
# (a crash, not a park). The watchdog must hold it too: deps first.
# =============================================================================
{
    my $dir = world(status => 'running', attempt => 1);
    my @calls;
    my $launch = sub { push @calls, $_[0]{pkg}; 0 };
    tick($dir, $T0 + 12 * $_, $launch) for 0 .. 4;
    is(scalar(grep { $_ eq 'p15-cost' } @calls), 0,
        'W2: a crashed coordinator is not relaunched while a dependency of its package is unfinished');
}

# =============================================================================
# W3 -- the park itself. p15-cost's coordinator set `blocked` because p03-make
# is unfinished, and is now dead. The orchestrator must NOT file an orphan
# escalation (that is what fed the resolver loop): it puts the package back to
# pending, where the DAG holds it.
# =============================================================================
{
    my $dir = world(status => 'blocked', attempt => 1);
    my @calls;
    my $launch = sub { push @calls, $_[0]{pkg}; 0 };
    tick($dir, $T0 + 12 * $_, $launch) for 0 .. 4;
    is(scalar(events($dir, 'orphan_escalation', 'p15-cost')), 0,
        'W3: a park while a dependency is unfinished files no orphan escalation');
    is(scalar(queued($dir, 'p15-cost')), 0, 'W3: no escalation is queued for it');
    is(ledger_status($dir, 'p15-cost'), 'pending', 'W3: the ledger is put back to pending');
    my @rq = events($dir, 'dep_wait_requeued', 'p15-cost');
    is(scalar @rq, 1, 'W3: one dep_wait_requeued line records why');
    is_deeply($rq[0]{unmet}, ['p03-make'], 'W3: it names the unfinished dependency') if @rq;
    is(scalar(grep { $_ eq 'p15-cost' } @calls), 0, 'W3: and it is not launched while the dependency runs');
    is(scalar(events($dir, 'dag_stalled')), 0, 'W3: a dependency wait behind a live package is not a DAG stall');

    set_status($dir, 'p03-make', 'done');
    tick($dir, $T0 + 200, $launch);
    is(scalar(grep { $_ eq 'p15-cost' } @calls), 1, 'W3: it launches once the dependency is done');
}

# =============================================================================
# W4 -- control: with every dependency done, a self-park is a real question
# and is still escalated exactly as before. Without this, W3 would pass for an
# orchestrator that had simply stopped escalating parks.
# =============================================================================
{
    my $dir = world(status => 'blocked', attempt => 1, dep_status => 'done');
    my $launch = sub { 0 };
    tick($dir, $T0, $launch);
    is(scalar(events($dir, 'orphan_escalation', 'p15-cost')), 1,
        'W4: a park with every dependency done is still escalated');
    is(scalar(queued($dir, 'p15-cost')), 1, 'W4: one stuck-package escalation is queued');
    is(ledger_status($dir, 'p15-cost'), 'blocked', 'W4: the ledger is left as the coordinator set it');
}

# =============================================================================
# W5 -- the shared rule itself, at every site name the orchestrator passes it.
# =============================================================================
{
    my $dir = world(status => 'pending');
    my $meta = { 'p15-cost' => { deps => ['p03-make', 'p11-model'] }, 'p03-make' => { deps => [] },
                 'p11-model' => { deps => [] } };
    for my $site (qw(fresh watchdog cold-wedged)) {
        my %c = (runs => "$dir/runs", bpdir => $dir, log => "$dir/runs/orchestrator.log", bp => "T$bpn",
                 reg => {}, pkg => 'p15-cost', now => $T0, t => {}, site => $site, logged => {}, meta => $meta);
        my $h = BpOrch::_launch_hold({ %c, deps_status => { 'p03-make' => 'running', 'p11-model' => 'done' } });
        is(ref $h eq 'HASH' ? $h->{reason} : undef, 'deps_unmet', "W5: _launch_hold holds at site '$site' when a dependency is unfinished");
        my $ok = BpOrch::_launch_hold({ %c, deps_status => { 'p03-make' => 'done', 'p11-model' => 'done' } });
        ok(!defined $ok, "W5: _launch_hold releases at site '$site' once every dependency is done");
    }
}

# =============================================================================
# W6 -- the CLI seam bp-resume-sweep.sh gates its revivals on prints the same
# answer: the unfinished dependency, then nothing once it is done.
# =============================================================================
{
    my $dir = world(status => 'running', attempt => 1);
    my $orch = "$BUTLER/scripts/bp-orchestrator.pl";
    my $out = `perl "$orch" --deps-unmet "$dir" p15-cost 2>&1`;
    is($? >> 8, 0, 'W6: --deps-unmet exits 0');
    is($out, "p03-make\n", 'W6: --deps-unmet prints exactly the unfinished dependency');
    set_status($dir, 'p03-make', 'done');
    $out = `perl "$orch" --deps-unmet "$dir" p15-cost 2>&1`;
    is($out, '', 'W6: --deps-unmet prints nothing once every dependency is done');
    `perl "$orch" --deps-unmet "$dir" no-such-pkg 2>&1`;
    is($? >> 8, 2, 'W6: a package the blueprint does not list exits 2');
}

done_testing();
