#!/usr/bin/env perl
# Hook path-walk termination, and drive-solo session scoping.
#
# TWO DEFECTS, both found from a live report ("an agent hangs at: running stop
# hooks... 1/2 - 56s"), neither visible to any existing test:
#
#  1. NON-TERMINATING ANCESTOR WALK. gate-drive-loop.sh and mark-wakeup.sh each
#     carried their own copy of
#         while [ -n "$d" ] && [ "$d" != "/" ]; do ... d=$(dirname "$d"); done
#     Claude Code puts a DRIVE-LETTER cwd in the hook payload on Windows
#     ("C:/Development/indocs"), and dirname walks that to "C:" and then returns
#     "C:" forever -- a fixed point that is neither empty nor "/". Measured
#     before the fix: mark-wakeup.sh ran 25,089ms and was still going when its
#     bound fired. It is PreToolUse on Bash AND Task, so that was the cost of
#     EVERY tool call in EVERY project on the machine without a
#     .ccpraxis-local-data ancestor.
#
#  2. SCOPING BY DIRECTORY, NOT BY SESSION. The Stop gate armed on "does an
#     ancestor contain .drive-solo/order.json" -- true for every session in a
#     tree where drive-solo had ever run, because order.json was never removed
#     when a run finished, and true for sessions that were not the driver.
#
# ⚠ EVERY HOOK INVOCATION BELOW IS BOUNDED BY `timeout`. A regression of defect
# 1 is an infinite loop; an unbounded test would hang the suite rather than fail
# it, which is the failure mode this repo has been bitten by before.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Cwd qw(abs_path);

my $HOOKS = abs_path("$Bin/../../hooks");
ok(-d $HOOKS, "hooks dir found at $HOOKS") or BAIL_OUT('no hooks dir');

my $HAVE_TIMEOUT = (system('command -v timeout >/dev/null 2>&1') == 0);
plan skip_all => 'no `timeout` available; refusing to run unbounded hook tests'
    unless $HAVE_TIMEOUT;

# run_hook($name, $payload_json, %env) -> ($exit, $elapsed_ms, $stderr)
# ALWAYS bounded. A hook that needs more than 20s has failed, whatever it prints.
sub run_hook {
    my ($name, $payload, %env) = @_;
    my $errf = "$Bin/.hook-err.$$";
    my @pre;
    for my $k (sort keys %env) {
        my $v = $env{$k};
        $v =~ s/'/'\\''/g;
        push @pre, "$k='$v'";
    }
    my $pre = @pre ? join(' ', @pre) . ' ' : '';
    my $pj = $payload; $pj =~ s/'/'\\''/g;
    my $t0 = time;
    my $rc = system("printf '%s' '$pj' | ${pre}timeout 20 bash '$HOOKS/$name' 2>'$errf' >/dev/null");
    my $ms = (time - $t0) * 1000;
    my $err = '';
    if (open my $fh, '<', $errf) { local $/; $err = <$fh> // ''; close $fh }
    unlink $errf;
    return ($rc >> 8, $ms, $err);
}

# The exit code `timeout` uses when it had to kill the child. A hook that
# returns this did not finish on its own.
use constant TIMED_OUT => 124;


# ===========================================================================
# A. The ancestor walk terminates on a Windows drive-letter path.
# ===========================================================================
{
    # dirname("C:") is "C:" -- the fixed point the old loop could not leave.
    my $fixed = `bash -c 'dirname "C:"' 2>/dev/null`;
    chomp $fixed;
    is($fixed, 'C:',
       'A1 dirname("C:") returns "C:" -- a fixed point that is neither empty '
     . 'nor "/", which is precisely why the old loop could not terminate');

    my $out = `bash -c 'source "$HOOKS/lib.sh"; bp_find_data_dir "C:/Development/indocs"; echo "rc=\$?"' 2>&1`;
    like($out, qr/rc=1/,
         'A2 bp_find_data_dir TERMINATES on a drive-letter path with no data dir');
    unlike($out, qr{\.ccpraxis-local-data},
           'A3 ... and reports nothing found rather than inventing a path');

    for my $p ('.', '/', 'C:', '//server/share') {
        my $o = `bash -c 'source "$HOOKS/lib.sh"; bp_find_data_dir "$p" >/dev/null 2>&1; echo done' 2>&1`;
        like($o, qr/done/, "A4 bp_find_data_dir terminates on '$p'");
    }
}

# COUNTER-FIXTURE: the OLD loop really did spin, so section A is guarding
# something real. Run the original shape with an explicit iteration cap and
# assert it hits the cap instead of ending -- the cap is what keeps THIS TEST
# from hanging while still demonstrating non-termination.
{
    my $script = q{
        d="C:/Development/indocs"; n=0
        while [ -n "$d" ] && [ "$d" != "/" ]; do
          n=$((n+1)); [ "$n" -ge 500 ] && break
          d=$(dirname "$d")
        done
        echo "iterations=$n"
    };
    my $out = `bash -c '$script' 2>&1`;
    like($out, qr/iterations=500/,
         'A5 counter-fixture: the ORIGINAL loop shape hits a 500-iteration cap '
       . 'without terminating (if this ever fails, A2 is guarding nothing)');
}


# ===========================================================================
# B. Neither hook hangs for an unrelated session.
# ===========================================================================
{
    my $cwd = 'C:/Development/some-project-with-no-ccpraxis-data';

    my ($rc, $ms) = run_hook('gate-drive-loop.sh',
        qq({"session_id":"unrelated","cwd":"$cwd","hook_event_name":"Stop"}));
    isnt($rc, TIMED_OUT, 'B1 gate-drive-loop does not hang for an unrelated session');
    is($rc, 0, 'B2 ... and allows the stop');

    ($rc, $ms) = run_hook('mark-wakeup.sh',
        qq({"session_id":"unrelated","cwd":"$cwd","tool_name":"Bash","tool_input":{"command":"ls"}}));
    isnt($rc, TIMED_OUT,
         'B3 mark-wakeup does not hang -- it is PreToolUse on Bash AND Task, so '
       . 'a hang here taxes every tool call in every unrelated project');
    is($rc, 0, 'B4 ... and permits the call');
}


# ===========================================================================
# C. Arming: a session becomes a driver by CALLING THE DIRECTOR, not by
#    sitting in a directory where drive-solo once ran.
# ===========================================================================
{
    my $tmp    = tempdir(CLEANUP => 1);
    my $active = "$tmp/active";
    my $proj   = "$tmp/proj";
    make_path("$proj/.ccpraxis-local-data/.drive-solo");
    open my $o, '>', "$proj/.ccpraxis-local-data/.drive-solo/order.json" or die;
    print $o '{"order":["demo"],"recorded_at":1}'; close $o;

    my %env = (CCPRAXIS_DRIVE_ACTIVE_DIR => $active);

    run_hook('mark-wakeup.sh',
        qq({"session_id":"sess-A","cwd":"$proj","tool_name":"Bash","tool_input":{"command":"ls -la"}}),
        %env);
    ok(!-e "$active/sess-A",
       'C1 an ORDINARY Bash call does not arm the session -- being in the '
     . 'project is not what makes a session a driver');

    run_hook('mark-wakeup.sh',
        qq({"session_id":"sess-A","cwd":"$proj","tool_name":"Bash","tool_input":{"command":"perl plugins/butler/scripts/bp-drive-next.pl next"}}),
        %env);
    ok(-f "$active/sess-A", 'C2 calling the director DOES arm that session');

    # A command that merely NAMES the director is not an invocation of it, and
    # must not arm a session that is only reading about the code.
    for my $cmd ('grep -rn bp-drive-next.pl plugins/',
                 'ls plugins/butler/scripts/bp-drive-next.pl',
                 'cat plugins/butler/scripts/bp-drive-next.pl') {
        unlink "$active/sess-mention";
        run_hook('mark-wakeup.sh',
            qq({"session_id":"sess-mention","cwd":"$proj","tool_name":"Bash","tool_input":{"command":"$cmd"}}),
            %env);
        ok(!-e "$active/sess-mention", "C2b a mention does not arm: $cmd");
    }

    # ... but every real subcommand does. The bias is one-directional on
    # purpose: a false positive costs one director call and self-disarms; a
    # false negative leaves a real driver ungated, which is the silent mid-run
    # death the pair exists to prevent.
    for my $verb ('next', 'record-order --order x', 'park') {
        unlink "$active/sess-verb";
        run_hook('mark-wakeup.sh',
            qq({"session_id":"sess-verb","cwd":"$proj","tool_name":"Bash","tool_input":{"command":"perl plugins/butler/scripts/bp-drive-next.pl $verb"}}),
            %env);
        ok(-f "$active/sess-verb", "C2c a real invocation arms: bp-drive-next.pl $verb");
    }

    my $rec = do { open my $f, '<', "$active/sess-A" or die; local $/; <$f> };
    like($rec, qr/\Q.ccpraxis-local-data\E/,
         'C3 the marker records the data dir, so the Stop hook needs no path '
       . 'walk of its own -- the walk that used to be there is the one that hung');

    # SCOPING: a second session in the SAME project is not the driver.
    my ($rc, $ms) = run_hook('gate-drive-loop.sh',
        qq({"session_id":"sess-B","cwd":"$proj","hook_event_name":"Stop"}), %env);
    is($rc, 0,
       'C4 a DIFFERENT session in the same project is not gated -- the old '
     . 'directory test caught every terminal in the tree');

    # A traversing session id must not be able to address another directory.
    my $out = `bash -c 'source "$HOOKS/lib.sh"; CCPRAXIS_DRIVE_ACTIVE_DIR="$active" bp_drive_marker "../../etc/passwd"; echo "rc=\$?"' 2>&1`;
    like($out, qr/rc=1/, 'C5 a session id containing a traversal is refused');
    $out = `bash -c 'source "$HOOKS/lib.sh"; CCPRAXIS_DRIVE_ACTIVE_DIR="$active" bp_drive_marker "a/b"; echo "rc=\$?"' 2>&1`;
    like($out, qr/rc=1/, 'C6 a session id containing a path separator is refused');
}


# ===========================================================================
# D. Staleness: a dead driver must not gate its session id forever.
# ===========================================================================
{
    my $tmp    = tempdir(CLEANUP => 1);
    my $active = "$tmp/active";
    my $proj   = "$tmp/proj";
    make_path($active);
    make_path("$proj/.ccpraxis-local-data/.drive-solo");
    open my $o, '>', "$proj/.ccpraxis-local-data/.drive-solo/order.json" or die;
    print $o '{"order":["demo"],"recorded_at":1}'; close $o;

    open my $m, '>', "$active/sess-dead" or die;
    print $m "$proj/.ccpraxis-local-data\n"; close $m;
    # 48h old.
    my $old = time - (48 * 3600);
    utime $old, $old, "$active/sess-dead";

    my ($rc) = run_hook('gate-drive-loop.sh',
        qq({"session_id":"sess-dead","cwd":"$proj","hook_event_name":"Stop"}),
        CCPRAXIS_DRIVE_ACTIVE_DIR => $active, CCPRAXIS_DRIVE_TTL_H => '12');
    is($rc, 0, 'D1 a stale marker allows the stop');
    ok(!-e "$active/sess-dead",
       'D2 ... and is REAPED, so a crashed driver cannot gate its session id '
     . 'forever (the disarm-on-settle path only covers clean finishes)');

    # COUNTER-FIXTURE: a FRESH marker survives the same code path, so D2 is
    # proving the TTL fires rather than that markers are always deleted.
    open my $m2, '>', "$active/sess-live" or die;
    print $m2 "$proj/.ccpraxis-local-data\n"; close $m2;
    run_hook('gate-drive-loop.sh',
        qq({"session_id":"sess-live","cwd":"$proj","hook_event_name":"Stop"}),
        CCPRAXIS_DRIVE_ACTIVE_DIR => $active, CCPRAXIS_DRIVE_TTL_H => '12');
    ok(-e "$active/sess-live",
       'D3 counter-fixture: a fresh marker is NOT reaped '
     . '(if this ever fails, D2 is proving nothing)');
}


# ===========================================================================
# E. No copy of the old walk survives in any hook.
# ===========================================================================
{
    opendir(my $dh, $HOOKS) or die;
    my @sh = grep { /\.sh$/ } readdir($dh);
    closedir $dh;

    my @offenders;
    for my $f (@sh) {
        open my $fh, '<', "$HOOKS/$f" or next;
        my @lines = <$fh>;
        close $fh;
        # Comments are blanked: this defect is DISCUSSED at length in comments
        # that quote the very loop they warn against.
        my $src = join '', map { my $l = $_; $l =~ s/^(\s*)#.*$/$1\n/; $l } @lines;
        push @offenders, $f if $src =~ /while\s+\[[^\]]*"\$d"\s*!=\s*"\/"/;
    }
    is_deeply(\@offenders, [],
        'E1 no hook still carries the non-terminating "walk until /" loop')
        or diag("still walking to '/': @offenders");

    ok(scalar(@sh) >= 5, 'E2 the scan actually saw the hook files (' . scalar(@sh) . ' found)');
}

# ===========================================================================
# F. The registry probe survives a hostile shell environment.
#
# Every hook runs under `set -u`. bp_drive_any_active globs the registry, and
# with nullglob enabled an unmatched glob leaves $1 UNSET — which under set -u
# aborts the hook rather than answering "nothing is active". A hook that dies
# here is a hook that stops enforcing, silently.
# ===========================================================================
{
    my $tmp = tempdir(CLEANUP => 1);

    for my $case ([ "$tmp/does-not-exist", 'a missing registry' ],
                  [ "$tmp/empty",          'an empty registry'  ]) {
        my ($dir, $what) = @$case;
        make_path($dir) if $what =~ /empty/;
        my $out = `bash -c 'set -u; shopt -s nullglob; source "$HOOKS/lib.sh"; CCPRAXIS_DRIVE_ACTIVE_DIR="$dir" bp_drive_any_active; echo "rc=\$?"' 2>&1`;
        like($out, qr/rc=1/, "F1 $what answers 'nothing active' under set -u + nullglob");
        unlike($out, qr/unbound variable/, "F2 $what does not abort the shell");
    }
}

# ===========================================================================
# G. Stale markers from DEAD sessions are reaped by whoever comes next.
#
# The per-session TTL is not enough on its own and this is the proof. That
# check only runs for the session whose id MATCHES a marker, and a dead driver
# never comes back to match its own — so before this, three 55h-old markers
# survived three consecutive stops by another session untouched.
#
# It never hung anything (an unmatched marker is only ever read by its owner),
# but one leaked marker keeps bp_drive_any_active true forever, so every
# session on the machine goes on to parse its payload and spawn a JSON reader
# on every stop instead of returning after two stats. A registry that only
# grows quietly reintroduces the cost this design removed.
# ===========================================================================
{
    my $tmp    = tempdir(CLEANUP => 1);
    my $active = "$tmp/active";
    my $proj   = "$tmp/proj";
    make_path($active);
    make_path("$proj/.ccpraxis-local-data/.drive-solo");
    open my $o, '>', "$proj/.ccpraxis-local-data/.drive-solo/order.json" or die;
    print $o '{"order":["demo"],"recorded_at":1}'; close $o;

    my $old = time - (55 * 3600);
    for my $s (qw(dead-1 dead-2 dead-3)) {
        open my $m, '>', "$active/$s" or die;
        print $m "$proj/.ccpraxis-local-data\n"; close $m;
        utime $old, $old, "$active/$s";
    }
    # A live one, so the reap has to discriminate rather than empty the dir.
    open my $m, '>', "$active/still-driving" or die;
    print $m "$proj/.ccpraxis-local-data\n"; close $m;

    my ($rc) = run_hook('gate-drive-loop.sh',
        qq({"session_id":"someone-else","cwd":"$proj","hook_event_name":"Stop"}),
        CCPRAXIS_DRIVE_ACTIVE_DIR => $active, CCPRAXIS_DRIVE_TTL_H => '12');
    is($rc, 0, 'G1 an unrelated session still stops cleanly');

    ok(!-e "$active/dead-$_", "G2 stale marker dead-$_ was reaped by a passing session")
        for (1 .. 3);

    ok(-e "$active/still-driving",
       'G3 counter-fixture: the FRESH marker survives the same sweep — the reap '
     . 'discriminates on age rather than clearing the registry');
}


# ===========================================================================
# H. The director call is bounded on every platform.
#
# It used to be `timeout 20` where timeout existed and UNBOUNDED where it did
# not — and stock macOS ships no `timeout`. An unbounded subprocess inside a
# Stop hook is exactly the shape that hung this hook to begin with.
# ===========================================================================
{
    open my $fh, '<', "$HOOKS/gate-drive-loop.sh" or die;
    my @lines = <$fh>; close $fh;
    my $src = join '', map { my $l = $_; $l =~ s/^(\s*)#.*$/$1\n/; $l } @lines;

    like($src, qr/command -v timeout/, 'H1 timeout is preferred when present');
    like($src, qr/gtimeout/,           'H2 gtimeout covers stock macOS + coreutils');
    like($src, qr/alarm\s+20/,         'H3 a perl-only fallback exists for the rest');

    # ⚠ THE FALLBACK MUST FORK. `alarm; exec` looks correct and bounds NOTHING
    # on Git-for-Windows perl, which emulates exec by spawning and waiting, so
    # the alarm lands on a wrapper that is merely waiting. Measured: a 60s
    # child ran the full 60s and exited 0. This assertion exists because that
    # form was written here first and only a live test caught it.
    unlike($src, qr/alarm\s+\d+;\s*exec/,
           'H4 the fallback does NOT use the alarm-then-exec form, which is '
         . 'silently unbounded on this platform');
    like($src, qr/fork\(\)/, 'H5 ... it forks, so the parent can kill the child');
    like($src, qr/waitpid/,  'H6 ... and reaps it');

    # Live proof that the two forms genuinely differ, so H4 is not folklore.
  SKIP: {
        my $exec_form = system(q{perl -e 'alarm 2; exec @ARGV or exit 127' perl -e 'sleep 8' >/dev/null 2>&1});
        my $fork_form = system(q{perl -e 'my $p=fork(); exit 127 unless defined $p; if(!$p){exec @ARGV; exit 127} $SIG{ALRM}=sub{kill 9,$p}; alarm 2; waitpid($p,0); my $r=$?; alarm 0; exit($r==0?0:124)' perl -e 'sleep 8' >/dev/null 2>&1});
        is($fork_form >> 8, 124,
           'H7 the fork form KILLS an over-running child (this is the one in use)');
        isnt($exec_form >> 8, 124,
           'H8 counter-fixture: the exec form does NOT — it let the child run to '
         . 'completion, which is why H4 forbids it');
    }
}

done_testing();
