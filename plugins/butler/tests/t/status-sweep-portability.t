#!/usr/bin/env perl
# platform: any
# bp-status.sh, bp-resume-sweep.sh and the shared bp-lib.sh helpers must run on
# every host shell: bash 5 with GNU coreutils (Linux, Git for Windows) AND
# macOS's /bin/bash 3.2 with BSD userland. Three defects, one per case below:
#
#   1. The "## Next action" awk looped on $0 without checking getline's return
#      value. At EOF getline returns 0 and leaves $0 alone, so a ledger whose
#      heading is followed only by blank lines hung the status read forever.
#      Cross-platform (gawk and BSD awk alike).
#   2. bp-resume-sweep.sh passed "${args[@]}" to bp-launch.sh. A cold start has
#      no extra args, and an empty array expanded that way is an
#      unbound-variable error under set -u on bash < 4.4, killing the sweep at
#      its first revival on a Mac.
#   3. file_age_min used `stat -c %Y`, which BSD stat does not have, so on a Mac
#      every ledger read as 0 minutes old.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 } # this file names bp-launch.sh; the launch it reaches is a stub
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use POSIX qw(WNOHANG);
use Time::HiRes ();

(my $S  = "$Bin/../../scripts") =~ s{\\}{/}g;
(my $BS = "$Bin/../../../blueprint/scripts") =~ s{\\}{/}g;
my $ROOT = tempdir(CLEANUP => 1);
$ROOT =~ s{\\}{/}g;
my $have_jq = do { my $o = `bash -c 'command -v jq' 2>/dev/null`; ($o // '') =~ /\S/ ? 1 : 0 };

sub write_file {
    my ($p, $c) = @_;
    open my $f, '>', $p or die "write $p: $!";
    print {$f} $c;
    close $f;
}
sub slurp { my ($p) = @_; open my $f, '<', $p or return ''; local $/; my $x = <$f>; close $f; $x // '' }

# run_bounded($secs, %env, @argv) -> ($rc, $out, $timed_out). Output to a file
# (never an in-memory handle: Git-for-Windows perl, CLAUDE.md).
my $rn = 0;
sub run_bounded {
    my ($secs, $env, @argv) = @_;
    my $out = "$ROOT/run." . (++$rn) . '.out';
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        $ENV{$_} = $env->{$_} for keys %$env;
        open(STDOUT, '>', $out) or POSIX::_exit(126);
        open(STDERR, '>&', \*STDOUT);
        exec(@argv) or POSIX::_exit(127);
    }
    my $end = Time::HiRes::time() + $secs;
    while (Time::HiRes::time() < $end) {
        if (waitpid($pid, WNOHANG) == $pid) { return ($? >> 8, slurp($out), 0) }
        Time::HiRes::sleep(0.05);
    }
    kill('KILL', $pid);
    waitpid($pid, 0);
    return (undef, slurp($out), 1);
}

sub mk_bp {
    my ($data, $name, %ledgers) = @_;
    my $d = "$data/blueprints/$name";
    make_path("$d/packages", "$d/runs");
    write_file("$d/blueprint.md", "# $name\n\n```\nblueprint: $name\nstatus: running\n```\n");
    write_file("$d/packages/$_.md", $ledgers{$_}) for keys %ledgers;
    return $d;
}

# ---- 1. bp-status.sh: "## Next action" at EOF, followed only by blank lines --
{
    my $data = "$ROOT/data1";
    mk_bp($data, 'alpha',
        p1 => "---\nstatus: blocked\n---\n# p1\n\n## Next action\n\n\n",
        p2 => "---\nstatus: pending\n---\n# p2\n\n## Next action\n\n  write the parser\n");
    my ($rc, $out, $to) = run_bounded(20, { CCPRAXIS_DATA_DIR => $data }, 'bash', "$S/bp-status.sh", 'alpha');
    ok(!$to, 'status: a ledger whose "## Next action" is followed only by blank lines does not hang the read');
    is($rc, 0, 'status: exits 0') or diag($out);
    like($out, qr/^p1\s+blocked\b/m, 'status: the package with no next action still gets its row');
    like($out, qr/^p2\s+pending\b.*\bwrite the parser$/m, 'status: the first non-blank line under the heading is the next action');
}

# ---- 2. bp-resume-sweep.sh --apply: a cold start passes NO extra args -------
SKIP: {
    skip 'bp-resume-sweep.sh requires jq', 3 unless $have_jq;
    # A private copy of the sweep with its collaborators stubbed: SCRIPT_DIR is
    # the script's own directory, so this is how the launch it reaches becomes
    # a recorder instead of a real coordinator.
    my $sd = "$ROOT/sweep-scripts";
    make_path($sd);
    copy("$S/$_", "$sd/$_") or die "copy $_: $!" for qw(bp-resume-sweep.sh bp-lib.sh);
    my $argv_log = "$ROOT/launch.argv";
    write_file("$sd/bp-launch.sh", "#!/bin/sh\n: > '$argv_log'\nfor a in \"\$\@\"; do printf '%s\\n' \"\$a\" >> '$argv_log'; done\n");
    chmod 0755, "$sd/bp-launch.sh";
    write_file("$sd/bp-cache-state.pl", "print \"cold\\n\";\n");
    write_file("$sd/bp-orchestrator.pl", "print \"unknown\\n\";\n");

    my $data = "$ROOT/data2";
    my $bp = mk_bp($data, 'beta', p1 => "---\nstatus: running\n---\n# p1\n\n## Next action\n\ngo\n");
    # A dead coordinator: a pid that was ours and has exited.
    my $dead = fork();
    POSIX::_exit(0) if defined $dead && $dead == 0;
    waitpid($dead, 0);
    write_file("$bp/runs/registry.json", qq({"packages":{"p1":{"pid":$dead,"session_id":"sid-1"}}}));

    my ($rc, $out, $to) = run_bounded(30, { CCPRAXIS_DATA_DIR => $data },
                                      'bash', "$sd/bp-resume-sweep.sh", 'beta', '--apply');
    ok(!$to && defined $rc && $rc == 0, 'sweep: --apply on a cold start completes (exit 0)')
        or diag("rc=" . ($rc // 'timeout') . "\n$out");
    like($out, qr{beta/p1\s+running\s+DEAD -> cold-start}, 'sweep: the dead coordinator is planned as a cold start');
    is(slurp($argv_log), "beta\np1\n", 'sweep: bp-launch.sh is called with exactly <bp> <pkg> -- no empty-array residue');
}

# ---- 3. file_age_min: GNU stat or BSD stat, both copies of the shared base ---
for my $c (['butler', "$S/bp-lib.sh"], ['blueprint', "$BS/bp-lib.sh"]) {
    my ($which, $lib) = @$c;
    my $f = "$ROOT/aged." . (++$rn);
    write_file($f, "x\n");
    my $t = time - 120 * 60 - 30;
    utime($t, $t, $f);
    local $ENV{LIB} = $lib;
    local $ENV{F}   = $f;
    my $age = `bash -c 'source "\$LIB"; file_age_min "\$F"' 2>&1`;
    $age =~ s/\s+\z//;
    is($age, '120', "file_age_min ($which copy): a file last touched 120 minutes ago is 120 minutes old");
}

done_testing();
