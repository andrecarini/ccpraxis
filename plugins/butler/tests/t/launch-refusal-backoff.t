#!/usr/bin/env perl
# platform: any
# Bug 20261104-163148-782c: when bp-launch.sh refused a package (an empty
# write_set in the incident), the orchestrator relaunched it on every ~12 s
# tick from BOTH the watchdog and the fresh-launch path, forever, with no
# backoff and no escalation, and logged watchdog_relaunch with the PREVIOUS
# coordinator's exit_reason ("success") for a coordinator that never started.
#
# The fix: bp-launch.sh exits 5 for a static ledger refusal; the orchestrator
# escalates that once (kind launch-refused), holds the package at every launch
# site until the ledger bytes change or the escalation is answered, archives
# the escalation when a later launch succeeds, and backs off any other
# non-zero exit 30/60/120... capped at 900 s.
#
# Every orchestrator case drives the REAL BpOrch::run (once => 1 per tick, one
# run() call per tick, so state crosses ticks only through disk, exactly as it
# crosses an orchestrator restart) with an injected launch recorder: nothing
# here ever execs bp-launch.sh's launch path, `claude` or a container. The
# bp-launch.sh contract case runs the real script, but only into its refusal
# checks, which all fire before anything is launched; stub jq/flock/claude/
# setsid/realpath record a sentinel if anything reached them.
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP;
use Cwd qw(abs_path);
use Digest::SHA qw(sha1_hex);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }

my $BUTLER = fwd(abs_path("$Bin/../..") // "$Bin/../..");
require "$BUTLER/scripts/bp-orchestrator.pl";

my $J    = JSON::PP->new->canonical;
my $ROOT = tempdir(CLEANUP => 1);
my $T0   = 1_900_000_000;

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
sub reg_of {
    my ($dir, $pkg) = @_;
    my $r = eval { $J->decode(read_file("$dir/runs/registry.json") // '') };
    return (ref $r eq 'HASH' && ref $r->{packages} eq 'HASH') ? ($r->{packages}{$pkg} || {}) : {};
}
sub queued {
    my ($dir, $pkg, $kind) = @_;
    my $d = "$dir/runs/escalations";
    opendir(my $dh, $d) or return wantarray ? () : 0;
    my @f = sort grep { /\.json\z/ } readdir $dh; closedir $dh;
    return grep { my $r = eval { $J->decode(read_file("$d/$_")) };
                  ref $r eq 'HASH' && ($r->{package} // '') eq $pkg && ($r->{kind} // '') eq $kind } @f;
}
sub ledger_text {
    my ($pkg, $ws, %o) = @_;
    return "---\npackage: $pkg\nstatus: pending\nwrite_set: $ws\ntest_paths: $ws\n"
         . ($o{priority} ? "priority: $o{priority}\n" : '')
         . "last_updated: 2026-11-04T00:00:00Z\n---\n# $pkg\n\n## Next action\n\ngo\n";
}
my $bpn = 0;
# mk_bp([[pkg, write_set], ...], {registry seed}) -> dir
sub mk_bp {
    my ($pkgs, $reg) = @_;
    my $dir = "$ROOT/bp" . (++$bpn);
    make_path("$dir/packages", "$dir/runs");
    write_file("$dir/blueprint.md", join("\n", "# T$bpn", '', '## Package status', '',
        '| pkg | deliverable | depends_on | model | status |', '|--|--|--|--|--|',
        (map { "| $_->[0] | d | - | sonnet | pending |" } @$pkgs), ''));
    write_file("$dir/packages/$_->[0].md", ledger_text($_->[0], $_->[1])) for @$pkgs;
    write_file("$dir/runs/registry.json", $J->encode({ packages => $reg })) if $reg;
    write_file("$dir/creds.json", $J->encode({ claudeAiOauth => {
        accessToken => 'sk-ant-LRB-aaaaaaaaaaaaaaaaaaaa', refreshToken => 'sk-ant-LRBREF-bbbbbbbbbbbbbbbb',
        expiresAt => ($T0 + 400 * 3600) * 1000, scopes => ['user:inference'],
        subscriptionType => 'max', rateLimitTier => 'x' } }));
    return $dir;
}
# the previous coordinator's stream: it ENDED CLEANLY, as in the incident.
sub prior_success_stream {
    my ($dir, $pkg) = @_;
    write_file("$dir/runs/$pkg.jsonl",
        $J->encode({ type => 'result', subtype => 'success', num_turns => 12, session_id => "sid-$pkg" }) . "\n");
}
my $USAGE_OK = $J->encode({ five_hour => { utilization => 10, resets_at => '2099-01-01T00:00:00+00:00' },
                            seven_day => { utilization => 5,  resets_at => '2099-01-01T00:00:00+00:00' } });
sub tick {
    my ($dir, $now, $launch, %o) = @_;
    local $SIG{__WARN__} = sub { };
    BpOrch::run({
        blueprint => "T$bpn", bp_dir => $dir, creds_path => "$dir/creds.json",
        tunables  => { ceil5 => 85, ceil7 => 90, drain => 600, max_par => ($o{max_par} // 2), cap => 5,
                       flat => 600, watch_tick => 0, keeper_int => 600, keeper_bo => 120, thresh_min => 60,
                       jit_lo => 0, jit_hi => 0, tele_retry => 3, usage_fail => 60, busy_path => "$dir/busy" },
        once => 1, now => sub { $now }, sleep => sub { },
        http_get  => sub { { status => 200, content => $USAGE_OK } },
        http_post => sub { { status => 200, content => '{}' } },
        pid_alive => ($o{pid_alive} || sub { 0 }),
        spawn_judge => sub { 0 },
        launch    => $launch,
    });
}
# what bp-launch.sh writes after a REAL start (and only then).
sub mark_started {
    my ($dir, $pkg, $now) = @_;
    my @g = gmtime($now);
    BpOrch::update_registry_pkg("$dir/runs", $pkg, {
        pid => 4_000_000 + $bpn, status => 'running', session_id => "sid-$pkg",
        attempt => ((reg_of($dir, $pkg)->{attempt} // 0) + 1),
        launched_at => sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $g[5] + 1900, $g[4] + 1, @g[3, 2, 1, 0]) });
}

# =============================================================================
# R1 -- the incident, watchdog path: a package whose previous coordinator ended
# (attempt 1, dead pid, clean terminal event) and whose ledger now has an empty
# write_set. bp-launch.sh refuses with 5. Across 10 ticks 12 s apart: ONE
# launch attempt, ONE launch_refused line, ONE launch-refused escalation, no
# launch_failed, and the registry records the ledger digest + decision id.
# =============================================================================
my ($R1_DIR, $R1_ID);
{
    my $dir = mk_bp([['p12', '']], { p12 => { attempt => 1, pid => 999_999, status => 'running', session_id => 'sid-p12' } });
    prior_success_stream($dir, 'p12');
    my @calls;
    my $launch = sub { push @calls, $_[0]{pkg}; 5 };
    tick($dir, $T0 + 12 * $_, $launch) for 0 .. 9;

    is(scalar(grep { $_ eq 'p12' } @calls), 1, 'R1: a refused package is launched ONCE across 10 ticks, not twice per tick')
        or diag('launch calls: ' . scalar @calls);
    is(scalar(events($dir, 'launch_refused', 'p12')), 1, 'R1: exactly one launch_refused line');
    is(scalar(events($dir, 'launch_failed', 'p12')), 0, 'R1: no launch_failed lines for a static refusal');
    my @q = queued($dir, 'p12', 'launch-refused');
    is(scalar @q, 1, 'R1: exactly one launch-refused escalation is queued');
    my $rec = @q ? $J->decode(read_file("$dir/runs/escalations/$q[0]")) : {};
    is($rec->{category}, 'scoping', 'R1: the escalation is category scoping');
    like($rec->{question} // '', qr/empty write_set/, 'R1: the escalation names the reason (empty write_set)');
    my $r = reg_of($dir, 'p12');
    is($r->{launch_refused_digest}, sha1_hex(read_file("$dir/packages/p12.md")),
        'R1: the registry records launch_refused_digest = SHA-1 of the ledger bytes');
    (my $id = $q[0] // '') =~ s/\.json\z//;
    is($r->{launch_refused_decision}, $id, 'R1: the registry records the escalation decision id');
    is($r->{last_launch_rc}, 5, 'R1: last_launch_rc is persisted');
    is($r->{attempt}, 1, 'R1: a refusal burns no attempt');
    ($R1_DIR, $R1_ID) = ($dir, $id);
}

# =============================================================================
# R3 -- the ledger is fixed: its bytes change, the next tick retries, the
# launch succeeds, and the escalation is archived (settled) and the state cleared.
# =============================================================================
{
    my $dir = $R1_DIR;
    write_file("$dir/packages/p12.md", ledger_text('p12', 'src/p12/'));
    my @calls;
    my $now = $T0 + 200;
    my $launch = sub { push @calls, $_[0]{pkg}; mark_started($dir, $_[0]{pkg}, $now); 0 };
    tick($dir, $now, $launch);
    is(scalar @calls, 1, 'R3: after the ledger changes, the very next tick retries the package once');
    ok($R1_ID && !-e "$dir/runs/escalations/$R1_ID.json", 'R3: the launch-refused escalation is no longer queued');
    my $arc = $R1_ID ? eval { $J->decode(read_file("$dir/runs/resolved-escalations/$R1_ID.json")) } : undef;
    is(ref $arc eq 'HASH' ? $arc->{resolved_by} : undef, 'auto-settle', 'R3: it was archived as settled, not deleted');
    my $r = reg_of($dir, 'p12');
    is($r->{last_launch_rc}, 0, 'R3: last_launch_rc is 0 after the successful launch');
    ok(!defined $r->{launch_refused_digest} && !defined $r->{launch_refused_decision}, 'R3: the refusal state is cleared');
    is(scalar(events($dir, 'launch_refusal_settled', 'p12')), 1, 'R3: one launch_refusal_settled line');
}

# =============================================================================
# Answering the escalation also releases the hold (ledger unchanged). The retry
# is refused again, so exactly one NEW escalation is queued.
# =============================================================================
{
    my $dir = mk_bp([['pa', '']], { pa => { attempt => 1, pid => 999_999, status => 'running', session_id => 'sid-pa' } });
    prior_success_stream($dir, 'pa');
    my @calls;
    my $launch = sub { push @calls, $_[0]{pkg}; 5 };
    tick($dir, $T0 + 12 * $_, $launch) for 0 .. 2;
    is(scalar @calls, 1, 'ANS: refused once, then held');
    my ($f) = queued($dir, 'pa', 'launch-refused');
    ok(defined $f, 'ANS: the escalation is queued');
    # the operator answers: the queued record leaves the queue for the archive.
    make_path("$dir/runs/resolved-escalations");
    write_file("$dir/runs/resolved-escalations/$f", read_file("$dir/runs/escalations/$f")) if $f;
    unlink "$dir/runs/escalations/$f" if $f;
    tick($dir, $T0 + 60, $launch);
    is(scalar @calls, 2, 'ANS: an answered escalation releases the hold: the package is retried');
    my @rel = events($dir, 'launch_refusal_released', 'pa');
    is((@rel ? $rel[0]{reason} : undef), 'escalation_answered', 'ANS: the release is logged as escalation_answered');
    tick($dir, $T0 + 72 + 12 * $_, $launch) for 0 .. 3;
    is(scalar @calls, 2, 'ANS: refused again, held again (no storm after the answer)');
    is(scalar(queued($dir, 'pa', 'launch-refused')), 1, 'ANS: exactly one fresh escalation for the second refusal');
}

# =============================================================================
# R2 -- fresh path, ONE free slot: a refused never-launched package that sorts
# first must not starve a ready sibling.
# =============================================================================
{
    my $dir = mk_bp([['a-refused', 'src/a/'], ['b-ready', 'src/b/']]);
    my (@calls, %started);
    my $now;
    my $launch = sub {
        my $p = $_[0]{pkg}; push @calls, $p;
        return 5 if $p eq 'a-refused';
        mark_started($dir, $p, $now); $started{$p} = 1; 0;
    };
    my $alive = sub { my $pid = shift; defined $pid && $pid == 4_000_000 + $bpn ? 1 : 0 };
    for my $i (0 .. 5) { $now = $T0 + 12 * $i; tick($dir, $now, $launch, max_par => 1, pid_alive => $alive); }
    ok($started{'b-ready'}, 'R2: the ready sibling is launched despite the refused package holding the first slot')
        or diag('calls: ' . join(',', @calls));
    is(scalar(grep { $_ eq 'a-refused' } @calls), 1, 'R2: the refused package was attempted once, then held');
    is(scalar(queued($dir, 'a-refused', 'launch-refused')), 1, 'R2: one escalation for the refused package');
}

# =============================================================================
# R4 + R5 -- a transient failure (exit 1) backs off 30, 60, 120, 240, 480, 900,
# 900 s; each boundary is probed one second early (held) and on time (retried).
# Every watchdog_relaunch after the first failure reports never_launched, with
# the stale verdict kept as prior_exit_reason.
# =============================================================================
{
    my $dir = mk_bp([['pt', 'src/pt/']], { pt => { attempt => 1, pid => 999_999, status => 'running', session_id => 'sid-pt' } });
    prior_success_stream($dir, 'pt');
    my @calls;
    my $now = $T0;
    my $launch = sub { push @calls, $now; 1 };
    my $at = sub { $now = shift; tick($dir, $now, $launch) };
    $at->($now);
    is(scalar @calls, 1, 'R4: the first attempt happens and fails');
    my @gaps;
    my $early_ok = 1;
    for my $want (30, 60, 120, 240, 480, 900, 900) {
        my $last = $calls[-1];
        my $n = scalar @calls;
        $at->($last + $want - 1);
        $early_ok = 0 if @calls != $n;
        $at->($last + $want);
        push @gaps, (@calls > $n ? $calls[-1] - $last : 'none');
    }
    ok($early_ok, 'R4: no retry one second before each backoff boundary');
    is_deeply(\@gaps, [30, 60, 120, 240, 480, 900, 900], 'R4: retries at 30/60/120/240/480 then capped at 900 s');
    is(eval { BpOrch::launch_backoff_secs(1, {}) }, 30, 'R4: launch_backoff_secs(1) = 30 by default');
    is(eval { BpOrch::launch_backoff_secs(20, {}) }, 900, 'R4: launch_backoff_secs caps at 900 by default');
    is(scalar(queued($dir, 'pt', 'launch-refused')), 0, 'R4: a transient failure is not escalated as a refusal');

    my @wr = events($dir, 'watchdog_relaunch', 'pt');
    is($wr[0]{exit_reason}, 'success', 'R5: the first relaunch reports the real prior verdict (a coordinator did end)');
    my @later = @wr[1 .. $#wr];
    ok(@later && !grep({ ($_->{exit_reason} // '') ne 'never_launched' } @later),
        'R5: every relaunch after a failed launch reports exit_reason never_launched')
        or diag('exit_reasons: ' . join(',', map { $_->{exit_reason} // '?' } @wr));
    is((@later ? $later[0]{prior_exit_reason} : undef), 'success', 'R5: the stale verdict is kept as prior_exit_reason');

    # a successful launch ends the never_launched state.
    my $ok = sub { push @calls, $now; mark_started($dir, 'pt', $now); 0 };
    $now = $calls[-1] + 900;
    tick($dir, $now, $ok);
    my $r = reg_of($dir, 'pt');
    is($r->{last_launch_rc}, 0, 'R4: a success resets last_launch_rc');
    ok(!$r->{launch_fail_streak}, 'R4: a success resets the backoff streak');
    ok(defined(&BpOrch::never_launched_since_failure) && !BpOrch::never_launched_since_failure($r), 'R5: never_launched is false once a coordinator started');
}

# =============================================================================
# bp-launch.sh's own exit-code contract: every static ledger refusal exits 5
# and launches nothing; an unknown option exits 2.
# =============================================================================
SKIP: {
    my $bash_ok = system('bash', '-c', 'exit 0') == 0;
    skip 'bash not available', 16 unless $bash_ok;
    my $proj = "$ROOT/proj";
    my $data = "$proj/.ccpraxis-local-data";
    my $bpd  = "$data/blueprints/bl";
    make_path("$bpd/packages", "$ROOT/stub");
    my $sentinel = fwd("$ROOT/stub-reached");
    for my $c (qw(jq flock claude setsid realpath)) {
        write_file("$ROOT/stub/$c", "#!/bin/sh\necho \"$c \$*\" >> '$sentinel'\nexit 97\n");
        chmod 0755, "$ROOT/stub/$c";
    }
    write_file("$bpd/packages/emptyws.md", ledger_text('emptyws', ''));
    write_file("$bpd/packages/badeffort.md",
        "---\npackage: badeffort\nstatus: pending\nwrite_set: src/x/\ntest_paths: src/x/\neffort: ludicrous\n---\n# b\n");
    write_file("$bpd/packages/okledger.md", ledger_text('okledger', 'src/ok/'));
    my $run = sub {
        my (@args) = @_;
        local $ENV{BP_ALLOW_HOST} = 1;
        local $ENV{CCPRAXIS_DATA_DIR} = fwd($data);
        local $ENV{BP_PROJECT_ROOT} = fwd($proj);
        local $ENV{BLS_STUB} = fwd("$ROOT/stub");
        local $ENV{BLS_SCRIPT} = "$BUTLER/scripts/bp-launch.sh";
        my $rc = system('bash', '-c', 'PATH="$BLS_STUB:$PATH" timeout 30 bash "$BLS_SCRIPT" "$@" >/dev/null 2>&1',
                        'bls', @args);
        return $rc == -1 ? -1 : $rc >> 8;
    };
    is($run->('bl', 'nosuch'), 5, 'CONTRACT: no ledger exits 5');
    is($run->('bl', 'emptyws'), 5, 'CONTRACT: an empty write_set exits 5');
    is($run->('bl', 'badeffort'), 5, 'CONTRACT: an unknown effort exits 5');
    is($run->('bl', 'okledger', '--bogus-flag'), 2, 'CONTRACT: an unknown option exits 2 (usage, not a ledger refusal)');
    ok(!-e $sentinel, 'CONTRACT: no stubbed command (claude, setsid, jq, flock) was ever reached')
        or diag(read_file($sentinel));
    for my $p (qw(nosuch emptyws badeffort okledger)) {
        ok(!-e "$bpd/runs/$p.pid", "CONTRACT: no pid file for $p");
        ok(!-e "$bpd/runs/$p.jsonl", "CONTRACT: no stream log for $p (the previous one would survive)");
    }
    ok(!-e "$bpd/runs/registry.json", 'CONTRACT: no registry write, so no attempt is burned');
    my $src = read_file("$BUTLER/scripts/bp-launch.sh") // '';
    like($src, qr/^#\s+5\s+static ledger refusal/m, 'CONTRACT: the header documents exit 5');
    like($src, qr/^#\s+3\s+the global parallelism cap/m, 'CONTRACT: the header documents exit 3');
}

done_testing();
