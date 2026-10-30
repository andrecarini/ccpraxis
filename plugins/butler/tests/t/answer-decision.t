#!/usr/bin/env perl
# platform: any
# A7 unblock: bp-answer-escalation.pl — the mechanical, atomic unblock the reporter
# runs once a human has answered a runs/escalations/ decision. Part 1 exhausts the
# pure plan_answer/kind_family matrix (per-kind allowed actions, fail-closed on a
# bad pair). Part 2 drives the CLI end-to-end against a temp blueprint dir: a
# package park relaunch/accept/drop and a fleet-pause resume, asserting the ledger
# status, the corrective note, the registry reset, the pause clear, and the queue
# entry deletion.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $script = "$Bin/../../scripts/bp-answer-escalation.pl";
require $script;   # also loads BpOrch (the CLI requires bp-orchestrator.pl)

my $J = JSON::PP->new->canonical;

# ===========================================================================
# PART 1 — pure plan_answer / kind_family
# ===========================================================================

is(BpAnswer::kind_family('reauth'),         'fleet',   'kind_family: reauth -> fleet');
is(BpAnswer::kind_family('contract-drift'), 'fleet',   'kind_family: contract-drift -> fleet');
is(BpAnswer::kind_family('stuck-package'),  'package', 'kind_family: stuck-package -> package');
is(BpAnswer::kind_family('harvest-failure'),'package', 'kind_family: harvest-failure -> package');
is(BpAnswer::kind_family('harvest-spawn-failure'),'package','kind_family: harvest-spawn-failure -> package');
is(BpAnswer::kind_family(undef),            'package', 'kind_family: undef -> package (conservative)');

# package: default action relaunch
{
    my $p = BpAnswer::plan_answer('stuck-package', undef);
    ok($p->{ok}, 'plan: stuck-package default ok');
    is($p->{action}, 'relaunch',      'plan: default action is relaunch');
    is($p->{ledger_status}, 'pending','plan: relaunch -> ledger pending');
    is($p->{relaunch}, 1,             'plan: relaunch flag set');
    is($p->{reset_attempt}, 1,        'plan: relaunch resets the attempt budget');
    is($p->{clear_pause}, 0,          'plan: package never clears the fleet pause');
}
is(BpAnswer::plan_answer('stuck-package','accept')->{ledger_status}, 'done',    'plan: accept -> done');
is(BpAnswer::plan_answer('stuck-package','accept')->{relaunch},      0,         'plan: accept does not relaunch');
is(BpAnswer::plan_answer('harvest-failure','drop')->{ledger_status}, 'dropped', 'plan: drop -> dropped');
{
    my $bad = BpAnswer::plan_answer('stuck-package','frobnicate');
    is($bad->{ok}, 0, 'plan: unknown package action -> not ok');
    like($bad->{error}, qr/relaunch\|reset\|accept\|drop/, 'plan: error lists the valid actions');
}

# package: reset (#29) — the stronger relaunch (also resets resolve budget + supersedes)
{
    my $p = BpAnswer::plan_answer('stuck-package', 'reset');
    ok($p->{ok},               'plan: reset ok');
    is($p->{ledger_status}, 'pending', 'plan: reset -> ledger pending');
    is($p->{relaunch}, 1,      'plan: reset relaunches');
    is($p->{reset_attempt}, 1, 'plan: reset clears the attempt budget');
    is($p->{reset_resolve}, 1, 'plan: reset clears the resolve budget too');
    is($p->{supersede}, 1,     'plan: reset supersedes in-flight work');
}
{   # reset with no kind = direct --package mode -> still package family
    my $p = BpAnswer::plan_answer(undef, 'reset');
    ok($p->{ok} && $p->{family} eq 'package', 'plan: reset with undef kind -> package family');
    is($p->{supersede}, 1, 'plan: direct reset supersedes');
}
{   # relaunch is unchanged: leaves the resolve budget and does not supersede
    my $p = BpAnswer::plan_answer('stuck-package', 'relaunch');
    ok(!$p->{reset_resolve}, 'plan: relaunch leaves the resolve budget (unchanged)');
    ok(!$p->{supersede},     'plan: relaunch does not supersede (unchanged)');
}

# fleet: default resume; anything else rejected
{
    my $p = BpAnswer::plan_answer('reauth', undef);
    ok($p->{ok}, 'plan: reauth default ok');
    is($p->{action}, 'resume',  'plan: fleet default action is resume');
    is($p->{clear_pause}, 1,    'plan: resume clears the pause');
    is($p->{ledger_status}, undef, 'plan: fleet touches no ledger');
}
is(BpAnswer::plan_answer('contract-drift', undef)->{action}, 'resume', 'plan: contract-drift -> resume');
{
    my $bad = BpAnswer::plan_answer('reauth','relaunch');
    is($bad->{ok}, 0, 'plan: a package action on a fleet decision -> not ok');
    like($bad->{error}, qr/only supports --action resume/, 'plan: fleet error is specific');
}

# ===========================================================================
# PART 2 — CLI end-to-end against a temp blueprint dir
# ===========================================================================

sub write_file { my ($p,$c)=@_; my $d=$p; $d=~s{[\\/][^\\/]+$}{}; make_path($d) unless -d $d; open my $fh,'>:raw',$p or die "$p: $!"; print $fh $c; close $fh; }
sub slurp { my ($p)=@_; open my $fh,'<:raw',$p or return ''; local $/; my $c=<$fh>; close $fh; $c }

# Build a blueprint dir with one package ledger (status blocked), a registry, and
# a queued decision of $kind. Returns ($bpdir, $decision_id).
sub mk_bp {
    my (%o) = @_;
    my $pkg  = $o{pkg}  // 'alpha';
    my $kind = $o{kind} // 'stuck-package';
    my $bpdir = tempdir(CLEANUP => 1);
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nstatus: blocked\nwrite_set: p/$pkg/\n---\n\n# $pkg\n\n## Next action\n\nResolve the park.\n");
    write_file("$bpdir/runs/registry.json",
        $J->encode({ packages => { $pkg => { status=>'blocked', attempt=>3, pid=>4321 } } }));
    my $id = "$pkg--abc123";
    write_file("$bpdir/runs/escalations/$id.json",
        $J->encode({ package=>$pkg, blueprint=>'bp', kind=>$kind,
                     question=>'Decide.', context=>'looped', created_at=>10 }));
    write_file("$bpdir/runs/.paused",
        $J->encode({ reason=>'token-floor', manual=>JSON::PP::true, created_at=>10 })) if $o{paused};
    return ($bpdir, $id, $pkg);
}

# shell-quote each arg (the suite runs under sh on both host and sandbox) so a
# multi-word --note value reaches the CLI as a single argument.
sub shq { my ($s) = @_; $s =~ s/'/'\\''/g; return "'$s'"; }
sub run_cli {
    my ($bpdir, @args) = @_;
    my $cmd = join ' ', map { shq($_) } ($^X, $script, 'bp', '--bp-dir', $bpdir, @args);
    my $out = `$cmd 2>&1`;
    return ($? >> 8, $out);
}

# --- relaunch: ledger->pending + note + registry reset + queue cleared ----------
{
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'stuck-package');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch', '--note', 'Re-scope to use the existing helper.');
    is($rc, 0, 'relaunch: exit 0') or diag($out);
    like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*pending/m, 'relaunch: ledger status -> pending');
    like(slurp("$bpdir/packages/$pkg.md"), qr/## Human decision \(resolve\)/, 'relaunch: corrective section appended');
    like(slurp("$bpdir/packages/$pkg.md"), qr/Re-scope to use the existing helper\./, 'relaunch: the human note is in the ledger');
    ok(!-f "$bpdir/runs/escalations/$id.json", 'relaunch: queue entry deleted');
    my $reg = JSON::PP->new->decode(slurp("$bpdir/runs/registry.json"));
    is($reg->{packages}{$pkg}{status}, 'pending', 'relaunch: registry status -> pending');
    is($reg->{packages}{$pkg}{attempt}, 0, 'relaunch: registry attempt reset to 0 (fresh budget)');
    is($reg->{packages}{$pkg}{pid}, 4321, 'relaunch: registry merge preserved other fields');
    my $res = eval { JSON::PP->new->decode($out) };
    is($res->{action}, 'relaunch', 'relaunch: JSON action');
    ok($res->{ok}, 'relaunch: JSON ok=true');
}

# --- accept: ledger->done, no relaunch note, queue cleared ----------------------
{
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'harvest-failure');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'accept');
    is($rc, 0, 'accept: exit 0') or diag($out);
    like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*done/m, 'accept: ledger status -> done');
    unlike(slurp("$bpdir/packages/$pkg.md"), qr/## Human decision/, 'accept: no corrective note (not a relaunch)');
    ok(!-f "$bpdir/runs/escalations/$id.json", 'accept: queue entry deleted');
}

# --- drop: ledger->dropped, queue cleared ---------------------------------------
{
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'stuck-package');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'drop');
    is($rc, 0, 'drop: exit 0') or diag($out);
    like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*dropped/m, 'drop: ledger status -> dropped');
    ok(!-f "$bpdir/runs/escalations/$id.json", 'drop: queue entry deleted');
}

# --- fleet resume: clears runs/.paused + queue, leaves ledgers alone ------------
{
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'reauth', paused => 1);
    ok(-f "$bpdir/runs/.paused", 'resume: precondition .paused present');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id);   # default action resume
    is($rc, 0, 'resume: exit 0') or diag($out);
    ok(!-f "$bpdir/runs/.paused", 'resume: runs/.paused cleared');
    ok(!-f "$bpdir/runs/escalations/$id.json", 'resume: queue entry deleted');
    like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*blocked/m, 'resume: package ledger untouched');
    my $res = eval { JSON::PP->new->decode($out) };
    is($res->{family}, 'fleet', 'resume: JSON family=fleet');
}

# --- guards: wrong action for kind, missing decision ----------------------------
{
    my ($bpdir, $id) = mk_bp(kind => 'reauth', paused => 1);
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch');
    is($rc, 2, 'guard: package action on a fleet decision -> exit 2') or diag($out);
    ok(-f "$bpdir/runs/.paused", 'guard: a rejected answer leaves the pause in place');
    ok(-f "$bpdir/runs/escalations/$id.json", 'guard: a rejected answer leaves the queue entry');
}
{
    my ($bpdir) = mk_bp();
    my ($rc, $out) = run_cli($bpdir, '--decision', 'nope--000');
    is($rc, 2, 'guard: missing decision -> exit 2');
}
{
    my ($bpdir, $id) = mk_bp(kind => 'stuck-package');
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'frobnicate');
    is($rc, 2, 'guard: unknown package action -> exit 2');
    ok(-f "$bpdir/runs/escalations/$id.json", 'guard: bad action leaves the queue entry');
}

# ===========================================================================
# PART 3 — direct --package reset (#29): supersede in-flight work + fresh budget,
# with NO queued decision to consume.
# ===========================================================================
{
    my $DEAD  = 2_000_000_000;   # out of range -> kill 0 fails -> never alive (safe)
    my $bpdir = tempdir(CLEANUP => 1);
    my $pkg   = 'alpha';
    write_file("$bpdir/packages/$pkg.md",
        "---\npackage: $pkg\nstatus: running\nwrite_set: p/$pkg/\n---\n\n# $pkg\n\n## Next action\n\ngo\n");
    write_file("$bpdir/runs/registry.json",
        $J->encode({ packages => { $pkg => { status=>'running', attempt=>5, resolve_attempts=>1, pid=>$DEAD, model=>'sonnet' } } }));
    # an in-flight resolve judge (dead pid -> the kill is a safe no-op) + its markers
    write_file("$bpdir/runs/resolve/$pkg.pid", "$DEAD\n");
    write_file("$bpdir/runs/resolve/$pkg.inflight", "100\n");
    write_file("$bpdir/runs/resolve/$pkg.verdict.json", $J->encode({ verdict=>'park' }));
    # a stale queued decision for the package (direct reset clears it without an id)
    write_file("$bpdir/runs/escalations/$pkg--zzz999.json",
        $J->encode({ package=>$pkg, kind=>'stuck-package', question=>'?', created_at=>1 }));

    my ($rc, $out) = run_cli($bpdir, '--package', $pkg, '--action', 'reset', '--note', 'Fresh pass please.');
    is($rc, 0, 'reset: exit 0') or diag($out);
    like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*pending/m, 'reset: ledger -> pending');
    like(slurp("$bpdir/packages/$pkg.md"), qr/Fresh pass please\./, 'reset: note appended to ledger');
    my $reg = JSON::PP->new->decode(slurp("$bpdir/runs/registry.json"));
    is($reg->{packages}{$pkg}{status}, 'pending',        'reset: registry status -> pending');
    is($reg->{packages}{$pkg}{attempt}, 0,               'reset: attempt budget reset');
    is($reg->{packages}{$pkg}{resolve_attempts}, 0,      'reset: resolve budget reset');
    is($reg->{packages}{$pkg}{model}, 'sonnet',          'reset: registry merge preserved other fields');
    ok(!-e "$bpdir/runs/resolve/$pkg.inflight",     'reset: resolve .inflight cleared');
    ok(!-e "$bpdir/runs/resolve/$pkg.verdict.json", 'reset: stale resolve verdict cleared');
    ok(!-e "$bpdir/runs/resolve/$pkg.pid",          'reset: resolve pid file cleared');
    ok(!-e "$bpdir/runs/escalations/$pkg--zzz999.json", 'reset: queued decision for the package cleared');
    my $res = eval { JSON::PP->new->decode($out) };
    is($res->{action}, 'reset', 'reset: JSON action=reset');
    ok($res->{ok},              'reset: JSON ok=true');
}

# ===========================================================================
# --note - (stdin) and --note-file: free text with no command substitution.
# The reporter skill feeds the note as `--note - <<'EOF'`; the old
# `NOTE=$(cat <<'EOF' ...)` form is mis-parsed by bash 3.2 (macOS /bin/bash)
# as soon as the note holds an apostrophe or an unbalanced parenthesis. The
# script is driven here through `bash` with exactly that kind of note.
# ===========================================================================
{
    my $tricky = q{don't skip (the `parser`) step; keep $(HOME) literal};
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'stuck-package');
    my $sh = "$bpdir/answer.sh";
    write_file($sh, join("\n",
        'perl "$SCRIPT" bp --bp-dir "$BPDIR" --decision "$ID" --action relaunch --note - <<' . "'EOF'",
        $tricky, 'EOF', ''));
    local $ENV{SCRIPT} = $script;
    local $ENV{BPDIR}  = $bpdir;
    local $ENV{ID}     = $id;
    my $out = `bash "$sh" 2>&1`;
    is($? >> 8, 0, '--note -: a heredoc on stdin is accepted') or diag($out);
    my $ledger = slurp("$bpdir/packages/$pkg.md");
    ok(index($ledger, $tricky) >= 0, '--note -: the note lands byte-for-byte (quotes, parens, backticks, $(...) intact)')
        or diag($ledger);
    unlike($ledger, qr/\Q$tricky\E\n\n?\Q$tricky\E/, '--note -: and only once');
}
{
    my ($bpdir, $id, $pkg) = mk_bp(kind => 'stuck-package');
    my $nf = "$bpdir/note.txt";
    write_file($nf, "From a file: (a) and (b).\n\n");
    my ($rc, $out) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch', '--note-file', $nf);
    is($rc, 0, '--note-file: accepted') or diag($out);
    like(slurp("$bpdir/packages/$pkg.md"), qr/From a file: \(a\) and \(b\)\./, '--note-file: the note lands');
    my ($rc2, $out2) = run_cli($bpdir, '--decision', $id, '--action', 'relaunch', '--note-file', "$bpdir/missing.txt");
    is($rc2, 2, '--note-file: a missing file is a usage error (exit 2)') or diag($out2);
}

# ===========================================================================
# THE RECORDED PIDS AND THE NAMESPACE THAT WROTE THEM.
#
# Coordinators and judges are launched in the sandbox container, so the pids in
# registry.json and runs/<kind>/<pkg>.pid are CONTAINER pids. Answered from the
# HOST through the project mount, the same number names some unrelated host
# process, and kill_pid TERMs/KILLs by process group -- so a host answer never
# signals a recorded pid itself. Since last night it then still flipped the
# ledger, which let a relaunch collide with a coordinator still editing the
# write-set. Now a host answer either DELIVERS the kill into the project's
# sandbox container (podman/docker exec, after checking the process there is
# this package's), or REFUSES with nothing changed.
#
# A live grandchild of this test, in its own process group, stands in for
# "a process that pid names"; double-forked so init reaps it once killed.
# The container is a FAKE CLI (CCPRAXIS_CONTAINER_CLI): `exec` runs the
# in-container program here, against a fake /proc (BP_ANSWER_PROC_ROOT) that
# gives the victim the environment bp-launch.sh would. No real container.
# ===========================================================================
use POSIX ();
sub spawn_victim {
    pipe(my $r, my $w) or die "pipe: $!";
    my $mid = fork();
    die "fork: $!" unless defined $mid;
    if ($mid == 0) {
        close $r;
        my $g = fork();
        POSIX::_exit(1) unless defined $g;
        if ($g == 0) { close $w; setpgrp(0, 0); sleep 60; POSIX::_exit(0) }
        print {$w} "$g\n";
        close $w;
        POSIX::_exit(0);
    }
    close $w;
    my $g = <$r>;
    close $r;
    waitpid($mid, 0);
    chomp $g;
    return $g;
}
sub gone_within { my ($p, $s) = @_; my $t = time + $s; while (time < $t) { return 1 unless kill 0, $p; select(undef, undef, undef, 0.1) } return kill(0, $p) ? 0 : 1 }
sub reap_victim { my ($p) = @_; kill 'KILL', $p if kill 0, $p }

my $LEDGER_RUNNING = sub { my ($pkg) = @_;
    "---\npackage: $pkg\nstatus: running\nwrite_set: p/$pkg/\n---\n\n# $pkg\n\n## Next action\n\ngo\n" };

# host-only (no sandbox recorded for the project) and in-namespace (IS_SANDBOX=1)
for my $case (['host', {}], ['sandbox', { IS_SANDBOX => '1' }]) {
    my ($where, $env) = @$case;
    if ($where eq 'host' && (-e '/run/.containerenv' || -e '/.dockerenv')) {
        SKIP: { skip 'pid namespace (host): this run is inside a container, which IS the pids\' namespace', 4 }
        next;
    }
    my $bpdir = tempdir(CLEANUP => 1);
    my $pkg   = 'alpha';
    write_file("$bpdir/packages/$pkg.md", $LEDGER_RUNNING->($pkg));
    my $victim = spawn_victim();
    write_file("$bpdir/runs/registry.json",
        $J->encode({ packages => { $pkg => { attempt => 5, pid => $victim } } }));
    my ($rc, $out);
    {
        local %ENV = %ENV;
        delete @ENV{qw(IS_SANDBOX BP_ALLOW_HOST)};
        $ENV{$_} = $env->{$_} for keys %$env;
        ($rc, $out) = run_cli($bpdir, '--package', $pkg, '--action', 'reset');
    }
    my $res = eval { JSON::PP->new->decode($out) } || {};
    if ($where eq 'host') {
        ok(!gone_within($victim, 1), 'pid namespace (host, no sandbox recorded): the process the recorded pid names here is NOT signalled');
        is($rc, 6, 'pid namespace (host, no sandbox recorded): a live recorded pid refuses the reset (exit 6)') or diag($out);
        is($res->{refused}, 'live-pid-not-signalled', '...with a named refusal') or diag($out);
        like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*running/m, '...and the ledger is untouched');
    } else {
        ok(gone_within($victim, 5), 'pid namespace (sandbox): the recorded coordinator is killed, as before');
        is_deeply($res->{superseded}, ["coordinator:$victim"], 'pid namespace (sandbox): reported as superseded')
            or diag($out);
        is($rc, 0, 'pid namespace (sandbox): the reset applies') or diag($out);
        like(slurp("$bpdir/packages/$pkg.md"), qr/^status:\s*pending/m, '...and the ledger goes pending');
    }
    reap_victim($victim);
}

# ---- the sandbox recorded for the project: deliver into it, or refuse --------
SKIP: {
    skip 'pid namespace (container): this run is inside a container', 1 if -e '/run/.containerenv' || -e '/.dockerenv';
    require "$Bin/../../../sandbox/scripts/HostPlatform.pm";
    my $root = tempdir(CLEANUP => 1);
    my $cli  = "$root/bin/fake-ctr";
    skip "pid namespace (container): this temp path cannot be a CCPRAXIS_CONTAINER_CLI value ($cli)", 1
        unless HostPlatform::valid_override($cli);
    my $CTR = 'claude-proj-1234abcd';
    write_file("$root/data/claude-home/.launcher/container-name", "$CTR\n");
    write_file($cli, join "\n",
        '#!/bin/sh',
        'printf "%s\n" "$*" >> "$FAKE_CTR_LOG"',
        'case "$1" in',
        '  --version) echo "fake-ctr 1.0"; exit 0 ;;',
        '  container) [ -n "$FAKE_CTR_INSPECT_RC" ] && exit "$FAKE_CTR_INSPECT_RC"; echo "$FAKE_CTR_RUNNING"; exit 0 ;;',
        '  exec) shift; shift; [ -n "$FAKE_CTR_EXEC_RC" ] && exit "$FAKE_CTR_EXEC_RC"; exec "$@" ;;',
        'esac',
        'exit 99', '');
    chmod 0755, $cli;
    my $n = 0;
    # ctr_case(%o) -> ($rc, $res, $bpdir, $pkg, $log). %o: running ('true'|'false'),
    # inspect_rc, exec_rc, coord/judge (pids), env_pkg (BP_PACKAGE the fake /proc
    # gives them), args (CLI args after --bp-dir).
    my $ctr_case = sub {
        my (%o) = @_;
        my $bp  = 'bp' . (++$n);
        my $pkg = 'alpha';
        my $bpdir = "$root/data/blueprints/$bp";
        write_file("$bpdir/packages/$pkg.md", $LEDGER_RUNNING->($pkg));
        write_file("$bpdir/runs/registry.json",
            $J->encode({ packages => { $pkg => { attempt => 5, (defined $o{coord} ? (pid => $o{coord}) : ()) } } }));
        write_file("$bpdir/runs/resolve/$pkg.pid", "$o{judge}\n") if defined $o{judge};
        write_file("$bpdir/runs/escalations/$pkg--q1.json",
            $J->encode({ package => $pkg, blueprint => $bp, kind => 'stuck-package', question => '?', created_at => 1 }));
        my $proc = "$root/proc$n";
        for my $p (grep { defined } $o{coord}, $o{judge}) {
            write_file("$proc/$p/stat", "$p (claude) S 1 $p $p 0\n");
            write_file("$proc/$p/environ", join("\0", "BP_BLUEPRINT=$bp", 'BP_PACKAGE=' . ($o{env_pkg} // $pkg),
                                                'BP_ROLE=coordinator', '') );
        }
        my $log = "$root/ctr$n.log";
        my ($rc, $out);
        {
            local %ENV = %ENV;
            delete @ENV{qw(IS_SANDBOX BP_ALLOW_HOST FAKE_CTR_INSPECT_RC FAKE_CTR_EXEC_RC)};
            $ENV{CCPRAXIS_CONTAINER_CLI} = $cli;
            $ENV{FAKE_CTR_LOG}           = $log;
            $ENV{FAKE_CTR_RUNNING}       = $o{running} // 'true';
            $ENV{FAKE_CTR_INSPECT_RC}    = $o{inspect_rc} if defined $o{inspect_rc};
            $ENV{FAKE_CTR_EXEC_RC}       = $o{exec_rc}    if defined $o{exec_rc};
            $ENV{BP_ANSWER_PROC_ROOT}    = $proc;
            ($rc, $out) = run_cli($bpdir, @{ $o{args} || ['--package', $pkg, '--action', 'reset'] });
        }
        my $res = eval { JSON::PP->new->decode($out) } || { raw => $out };
        return ($rc, $res, $bpdir, $pkg, (slurp($log) // ''));
    };
    my $status = sub { my ($bpdir, $pkg) = @_; (slurp("$bpdir/packages/$pkg.md") =~ /^status:\s*(\S+)/m)[0] };

    {   # running container, this package's coordinator alive in it: killed there
        my $v = spawn_victim();
        my ($rc, $res, $bpdir, $pkg, $log) = $ctr_case->(coord => $v);
        is($rc, 0, 'container (running): the reset applies') or diag(explain $res);
        ok(gone_within($v, 5), 'container (running): the coordinator is killed through the container CLI');
        is_deeply($res->{superseded}, ["coordinator:$v"], '...reported as superseded') or diag(explain $res);
        like($log, qr/^exec \Q$CTR\E perl -e /m, '...by `exec` into the container the launcher recorded');
        my $reg = JSON::PP->new->decode(slurp("$bpdir/runs/registry.json"));
        ok(!defined $reg->{packages}{$pkg}{pid}, '...and the registry pid is cleared, as for an in-namespace kill');
        is($status->($bpdir, $pkg), 'pending', '...and only then does the ledger go pending');
        reap_victim($v);
    }
    {   # running container, the pid there belongs to another package: never signalled
        my $v = spawn_victim();
        my ($rc, $res, $bpdir, $pkg) = $ctr_case->(coord => $v, env_pkg => 'someone-else');
        is($rc, 0, 'container (not ours): the reset applies') or diag(explain $res);
        ok(!gone_within($v, 1), 'container (not ours): a process that is not this package\'s is NOT signalled');
        is_deeply($res->{superseded}, [], '...and nothing is reported superseded');
        reap_victim($v);
    }
    {   # a resolve judge in flight: killed, and its markers cleared after
        my $v = spawn_victim();
        my ($rc, $res, $bpdir, $pkg) = $ctr_case->(judge => $v);
        is($rc, 0, 'container (judge): the reset applies') or diag(explain $res);
        ok(gone_within($v, 5), 'container (judge): the in-flight judge is killed in the container');
        is_deeply($res->{superseded}, ["resolve-judge:$v"], '...reported as superseded');
        ok(!-e "$bpdir/runs/resolve/$pkg.pid", '...and its pid file is cleared');
        reap_victim($v);
    }
    {   # stopped container: nothing of it can be alive, nothing is exec'd
        my $v = spawn_victim();
        my ($rc, $res, $bpdir, $pkg, $log) = $ctr_case->(coord => $v, running => 'false');
        is($rc, 0, 'container (stopped): the reset applies -- a stopped container runs nothing') or diag(explain $res);
        unlike($log, qr/^exec /m, 'container (stopped): nothing is exec\'d');
        ok(!gone_within($v, 1), 'container (stopped): and no host process is signalled');
        reap_victim($v);
    }
    {   # the container cannot be queried: refuse, change nothing
        my ($rc, $res, $bpdir, $pkg) = $ctr_case->(coord => 4242, inspect_rc => 125);
        is($rc, 6, 'container (unqueryable): the reset is refused (exit 6)') or diag(explain $res);
        is($res->{refused}, 'sandbox-pids-unverifiable', '...with a named refusal');
        like($res->{hint} // '', qr/inside the sandbox/, '...telling the operator where to answer from');
        is($status->($bpdir, $pkg), 'running', '...and the ledger is untouched');
        ok(-e "$bpdir/runs/escalations/$pkg--q1.json", '...and the queued escalation stays queued');
    }
    {   # running, but `exec` fails: refuse, change nothing
        my ($rc, $res, $bpdir, $pkg) = $ctr_case->(coord => 4242, exec_rc => 125);
        is($rc, 6, 'container (exec fails): the reset is refused (exit 6)') or diag(explain $res);
        is($res->{refused}, 'sandbox-pids-unverifiable', '...with a named refusal');
        is($status->($bpdir, $pkg), 'running', '...and the ledger is untouched');
    }
    # The coordinator-alive gate (relaunch/accept/drop) asks the container too.
    {
        my $v = spawn_victim();
        my ($rc, $res, $bpdir, $pkg, $log) = $ctr_case->(coord => $v,
            args => ['--decision', 'alpha--q1', '--action', 'relaunch']);
        is($rc, 6, 'gate (container): a relaunch while the coordinator is alive in the container is refused') or diag(explain $res);
        is($res->{refused}, 'coordinator-alive', '...as coordinator-alive');
        like($log, qr/^exec \Q$CTR\E perl -e \S/m, '...having asked the container');
        ok(!gone_within($v, 1), '...and a probe never signals anything');
        reap_victim($v);
    }
    {
        my ($rc, $res, $bpdir, $pkg) = $ctr_case->(coord => 4242, inspect_rc => 125,
            args => ['--decision', 'alpha--q1', '--action', 'relaunch']);
        is($rc, 6, 'gate (unqueryable): the relaunch is refused') or diag(explain $res);
        is($res->{refused}, 'sandbox-pids-unverifiable', '...as unverifiable, not as a live coordinator');
    }
    {
        my ($rc, $res, $bpdir, $pkg) = $ctr_case->(coord => 2_000_000_000,
            args => ['--decision', 'alpha--q1', '--action', 'relaunch']);
        is($rc, 0, 'gate (container): a coordinator gone from the container does not block the relaunch') or diag(explain $res);
        is($status->($bpdir, $pkg), 'pending', '...and the ledger goes pending');
    }
}

# ---- the in-container program itself -----------------------------------------
{
    my $prog = do { no warnings q{once}; $main::SANDBOX_PID_PROG };
    ok(defined $prog && length $prog, 'the in-container program is defined');
    unlike($prog, qr/["\\\n]/, 'it holds no double quote, backslash or newline (survives a Windows command line)');
    my $proc = tempdir(CLEANUP => 1);
    my $run = sub { local $ENV{BP_ANSWER_PROC_ROOT} = $proc; system($^X, '-e', $prog, @_); return $? >> 8 };
    is($run->('probe', 'x', 'bp', 'p'), 45, 'a non-numeric pid is refused (45)');
    is($run->('probe', 1, 'bp', 'p'), 45, 'pid 1 is never touched (45)');
    is($run->('probe', 2_000_000_000, 'bp', 'p'), 41, 'a pid with no process is gone (41)');
    write_file("$proc/$$/stat", "$$ (perl) S 1\n");
    is($run->('probe', $$, 'bp', 'p'), 46, 'a live pid whose environment cannot be read is unknown (46), never "not ours"');
    write_file("$proc/$$/environ", "BP_BLUEPRINT=BP\0BP_PACKAGE=P\0");
    is($run->('probe', $$, 'bp', 'p'), 40, 'identity matches case-insensitively and a probe answers alive (40)');
    write_file("$proc/$$/stat", "$$ (perl) Z 1\n");
    is($run->('probe', $$, 'bp', 'p'), 41, 'a zombie is gone (41)');
}

# guard: --package and --decision together -> exit 2
{
    my ($bpdir, $id) = mk_bp(kind => 'stuck-package');
    my ($rc) = run_cli($bpdir, '--package', 'alpha', '--decision', $id);
    is($rc, 2, 'guard: --package + --decision -> exit 2');
}
# guard: --package for a missing ledger -> exit 2
{
    my $bpdir = tempdir(CLEANUP => 1);
    my ($rc) = run_cli($bpdir, '--package', 'ghost', '--action', 'reset');
    is($rc, 2, 'guard: reset a nonexistent package -> exit 2');
}

done_testing();
