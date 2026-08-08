#!/usr/bin/env perl
# B6 graceful-reap: the container entrypoint's reap logic (container/heartbeat.sh).
# heartbeat.sh is *sourced* (its main loop is guarded off via the BASH_SOURCE==$0
# check) so the PURE reap_decision and the filesystem I/O edges can be exercised
# on the host without building or running a container.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $HB = "$Bin/../../container/heartbeat.sh";
ok(-f $HB, 'heartbeat.sh exists');

# Source heartbeat.sh (main loop guarded off), then run $code; env passed via %ENV.
sub hb_call {
    my ($env, $code) = @_;
    local %ENV = (%ENV, HBFILE => $HB, %{ $env || {} });
    chomp(my $out = `bash -c 'source "\$HBFILE" >/dev/null 2>&1; $code' 2>&1`);
    return $out;
}

my $have_jq = do { chomp(my $w = `bash -c 'command -v jq' 2>/dev/null`); $w ? 1 : 0 };

# ===========================================================================
# PART 1 — pure reap_decision  (HB_STALE RUN_ACTIVE GRACE_STARTED GRACE_EXPIRED)
# ===========================================================================
is(hb_call({}, 'reap_decision 0 0 0 0'), 'keep',     'fresh heartbeat -> keep');
is(hb_call({}, 'reap_decision 0 1 1 1'), 'keep',     'fresh heartbeat dominates everything -> keep');
is(hb_call({}, 'reap_decision 1 0 0 0'), 'reap',     'stale + no run -> reap (today behavior)');
is(hb_call({}, 'reap_decision 1 0 1 0'), 'reap',     'stale + run cleared during grace -> reap early');
is(hb_call({}, 'reap_decision 1 0 1 1'), 'reap',     'stale + no run wins even past the deadline -> reap');
is(hb_call({}, 'reap_decision 1 1 0 0'), 'signal',   'stale + active, grace not started -> signal');
is(hb_call({}, 'reap_decision 1 1 1 0'), 'keep',     'stale + active, in grace, not expired -> keep waiting');
is(hb_call({}, 'reap_decision 1 1 1 1'), 'hardstop', 'stale + active, grace expired -> hardstop');

# ===========================================================================
# PART 2 — I/O edges (mtime_age / hb_stale / busy_fresh)
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $f = "$root/sentinel";
    open my $fh, '>', $f or die; close $fh;

    utime(time, time - 10, $f);   # 10s old (age ~10 < HB 300) -> fresh
    is(hb_call({ALIVE=>$f, HB=>300}, 'hb_stale $(date +%s)'), '0', 'hb_stale: fresh sentinel -> 0');
    # stale sentinel (age ~400 > HB 300) -> stale
    utime(time, time - 400, $f);
    is(hb_call({ALIVE=>$f, HB=>300}, 'hb_stale $(date +%s)'), '1', 'hb_stale: old sentinel -> 1');
    # absent sentinel -> stale
    is(hb_call({ALIVE=>"$root/nope", HB=>300}, 'hb_stale $(date +%s)'), '1', 'hb_stale: absent -> 1');

    # busy-lease freshness
    my $busy = "$root/busy";
    open my $bf, '>', $busy or die; close $bf;
    utime(time, time - 10, $busy);
    is(hb_call({BUSY=>$busy, HB=>300}, 'busy_fresh $(date +%s)'), '1', 'busy_fresh: fresh -> 1');
    utime(time, time - 400, $busy);
    is(hb_call({BUSY=>$busy, HB=>300}, 'busy_fresh $(date +%s)'), '0', 'busy_fresh: stale -> 0');
    is(hb_call({BUSY=>"$root/nope", HB=>300}, 'busy_fresh $(date +%s)'), '0', 'busy_fresh: absent -> 0');

    is(hb_call({}, 'mtime_age "/no/such/file" 1000'), '999999999', 'mtime_age: absent -> huge');
}

# ===========================================================================
# PART 3 — run_active / coordinators_live / signal_graceful_shutdown
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $data = "$root/data";
    make_path("$data/blueprints/alpha/runs");
    make_path("$data/blueprints/beta/runs");

    # run_active via a fresh busy-lease (no jq needed)
    my $busy = "$root/busy"; open my $bf,'>',$busy or die; close $bf; utime(time,time,$busy);
    is(hb_call({BUSY=>$busy, HB=>300, CCPRAXIS_DATA_DIR=>$data}, 'run_active $(date +%s)'),
       '1', 'run_active: fresh busy-lease -> 1');
    is(hb_call({BUSY=>"$root/nope", HB=>300, CCPRAXIS_DATA_DIR=>$data}, 'run_active $(date +%s)'),
       '0', 'run_active: no busy, no live coordinator -> 0');

    # coordinators_live via a registry naming a LIVE pid (this perl process)
  SKIP: {
        skip 'jq not available', 2 unless $have_jq;
        my $reg = "$data/blueprints/alpha/runs/registry.json";
        spew($reg, qq({"packages":{"p":{"pid":$$}}}));   # $$ = this live process
        is(hb_call({CCPRAXIS_DATA_DIR=>$data}, 'coordinators_live'), '1',
           'coordinators_live: a live pid in a registry -> 1');
        spew($reg, qq({"packages":{"p":{"pid":2147480000}}}));  # implausible dead pid
        is(hb_call({CCPRAXIS_DATA_DIR=>$data}, 'coordinators_live'), '0',
           'coordinators_live: only a dead pid -> 0');
        unlink $reg;
    }

    # signal_graceful_shutdown touches .shutdown in every blueprint runs dir
    hb_call({CCPRAXIS_DATA_DIR=>$data}, 'signal_graceful_shutdown');
    ok(-f "$data/blueprints/alpha/runs/.shutdown", 'signal: .shutdown written for alpha');
    ok(-f "$data/blueprints/beta/runs/.shutdown",  'signal: .shutdown written for beta');
}

# ===========================================================================
# HOST SUSPEND — incident 2026-08-08.
#
# A dispatch fleet was left running unattended. Windows entered connected
# standby at 20:23:33 and resumed at 02:03:50 (5h40m). This loop reaped the
# container at 02:03:52 — TWO SECONDS after the resume, before the manager
# could re-touch the sentinel. The operator came back to a dead container.
#
# The sentinel's mtime cannot distinguish "the manager died an hour ago" from
# "the entire machine was frozen for an hour", and reaping on that ambiguity
# destroys a container whose manager is alive and about to check in. The loop's
# OWN overshoot is the disambiguator: it knows how long it meant to sleep.
# ===========================================================================
{
    is(hb_call({}, 'suspend_detected 61 60 120'), '0',
       'suspend: a normal 61s tick is not a suspend');
    is(hb_call({}, 'suspend_detected 150 60 120'), '0',
       'suspend: a merely slow 150s tick is not a suspend (inside the slack)');
    is(hb_call({}, 'suspend_detected 180 60 120'), '1',
       'suspend: TICK + SLACK is the boundary, and it counts');
    is(hb_call({}, 'suspend_detected 20400 60 120'), '1',
       'suspend: the incident itself — a 5h40m gap between ticks is a suspended machine, '
     . 'not a slow one');

    # The decision must invert on exactly this input, or the incident recurs.
    is(hb_call({}, 'reap_decision 1 0 0 0 0'), 'reap',
       'post-wake: stale + no run WITHOUT the post-wake window still reaps (unchanged)');
    is(hb_call({}, 'reap_decision 1 0 0 0 1'), 'keep',
       'post-wake: the SAME inputs inside the post-wake window keep the container — '
     . 'this single flip is what the 2026-08-08 incident turns on');
    is(hb_call({}, 'reap_decision 1 1 1 1 1'), 'keep',
       'post-wake: the window outranks even an expired grace — a resume is not evidence '
     . 'about the manager, so nothing downstream of staleness should fire on it');

    # Every pre-existing 4-arg call must keep its exact meaning: the 5th
    # argument is optional precisely so this file's other 22 assertions, and
    # any other caller, are untouched.
    is(hb_call({}, 'reap_decision 1 0 0 0'), 'reap',
       'post-wake: a 4-arg call behaves exactly as before (optional 5th arg)');
}

# ===========================================================================
# THE REAP MUST BE LOUD.
#
# Before this, the loop simply `break`s: the container exits 0 and podman
# reports "Exited (0)". A clean exit code on a container that was supposed to
# still be running is the least useful true statement available, and it was
# the ONLY thing the operator had.
# ===========================================================================
{
    my $dir = tempdir(CLEANUP => 1);
    my $rec = "$dir/last-reap.txt";
    hb_call({ REAP_RECORD => $rec }, 'write_reap_record reap 20402 0 1');
    ok(-s $rec, 'record: a reap leaves a durable note behind');

    my $txt = do { local (@ARGV, $/) = ($rec); <> };
    $txt = '' unless defined $txt;
    like($txt, qr/verdict=reap/,              'record: names which branch fired');
    like($txt, qr/heartbeat_age_s=20402/,     'record: reports how stale the sentinel was');
    like($txt, qr/heartbeat_limit_s=/,        'record: and the limit it was measured against');
    like($txt, qr/run_active=0/,              'record: whether a butler run was live');
    like($txt, qr/host_suspends_detected=1/,  'record: whether the machine slept — the fact that '
                                            . 'reframes a stale sentinel from "manager died" to '
                                            . '"world was frozen"');
    like($txt, qr/why=\S/,                    'record: carries a human sentence, not just fields');
    like($txt, qr/asleep, not because the manager died/,
         'record: when a suspend was seen, the note says so IN WORDS — the reader is someone '
       . 'who came back to a stopped container with no other evidence');

    # A hardstop is a different story and must not be told as a reap.
    my $rec2 = "$dir/hard.txt";
    hb_call({ REAP_RECORD => $rec2 }, 'write_reap_record hardstop 700 1 0');
    my $t2 = do { local (@ARGV, $/) = ($rec2); <> };
    $t2 = '' unless defined $t2;
    like($t2, qr/verdict=hardstop/,        'record: a hardstop is recorded as a hardstop');
    like($t2, qr/graceful shutdown was signalled/,
         'record: and explains that coordinators were given a window to park first');
    unlike($t2, qr/no butler run was active/,
         'record: a hardstop must NOT claim no run was active — it fires precisely when one was');
}

# ===========================================================================
# PART 5 — the HOST end of the same story: launcher.pl surfaces the record
#
# heartbeat.sh writing last-reap.txt is only half a fix. A record nobody reads
# leaves the operator exactly where the incident left them: a stopped
# container and "Exited (0)". These assertions cover the launcher's pure
# formatting region, extracted by sentinel and eval'd into a throwaway package
# (the t/58 precedent) -- launcher.pl is NEVER require'd or run, because doing
# so builds an image and starts a container inside the test run.
# ===========================================================================
{
    my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
    ok(-f $LAUNCHER, 'launcher.pl exists');

    my $src = do { local (@ARGV, $/) = ($LAUNCHER); <> };
    $src = '' unless defined $src;

    my $BEGIN_S = '# >>> s-reap-notice:BEGIN';
    my $END_S   = '# >>> s-reap-notice:END';
    my $nbegin  = () = $src =~ /\Q$BEGIN_S\E/g;
    is($nbegin, 1, "sentinel: BEGIN '$BEGIN_S' occurs exactly once in launcher.pl");

    my ($region) = $src =~ /\Q$BEGIN_S\E.*?\n(.*?)\Q$END_S\E/s;

    SKIP: {
        skip "reap-notice region not found in launcher.pl", 20 unless defined $region;

        # Purity: the region must be formatting only. Anything that shells out
        # or exits belongs in _surface_last_reap, outside the sentinels --
        # otherwise a failure to EXPLAIN a past death could prevent a launch.
        #
        # Scan CODE, not prose. A comment that quotes a backtick or writes the
        # word "system" is documenting the rule, not breaking it; punishing a
        # file for explaining itself has cost this repo five separate debugging
        # sessions (t/62, t/94, t/95, t/65 AC-M2, t/66). Blank every full-line
        # and trailing comment first. Quote-aware enough for this region, whose
        # string literals contain no '#'.
        my $code = join "\n", map {
            my $l = $_; $l =~ s/(?<!\$)#.*$//; $l;
        } split /\n/, $region;

        unlike($code, qr/\$PODMAN\b/,
            'purity: the notice region never touches podman');
        unlike($code, qr/\bsystem\s*\(|`[^`]*`|\bexit\s*\(/,
            'purity: the notice region has no subprocess or exit path');
        unlike($code, qr/\b_read_file\b|\b_write_file\b|\bopen\s+my\b/,
            'purity: the notice region does no file I/O -- the impure edge is its caller');

        # Counter-fixture for the scanner itself: the blanking must not be so
        # eager that it hides real code. A line that genuinely calls system()
        # has to survive it, or all three assertions above are vacuous.
        {
            my $probe = join "\n", map {
                my $l = $_; $l =~ s/(?<!\$)#.*$//; $l;
            } split /\n/, "# a comment mentioning system( and \$PODMAN\nsystem(\$PODMAN);";
            like($probe, qr/\bsystem\s*\(/,
                'counter-fixture: comment-blanking still leaves real system() calls visible');
            unlike($probe, qr/comment mentioning/,
                'counter-fixture: comment-blanking does remove prose');
        }

        my $pkg = 'ReapNotice';
        my $ok  = eval "package $pkg; use strict; use warnings;\n$region\n1;";  ## no critic
        ok($ok, 'extraction: the reap-notice region evals cleanly under strict/warnings')
            or diag("eval error: $@");

        my $parse  = $pkg->can('parse_reap_record');
        my $notice = $pkg->can('reap_notice_lines');
        ok(defined $parse && defined $notice,
            'extraction: the region defines parse_reap_record and reap_notice_lines');

        SKIP: {
            skip 'region did not eval', 13 unless defined $parse && defined $notice;

            # Round-trip the EXACT bytes heartbeat.sh writes, produced by
            # heartbeat.sh itself rather than hand-typed here -- a hand-typed
            # fixture would keep passing after the writer's format drifted.
            my $dir = tempdir(CLEANUP => 1);
            my $rec = "$dir/last-reap.txt";
            hb_call({ REAP_RECORD => $rec, HB => 600 },
                    'write_reap_record reap 20402 0 1');
            my $txt = do { local (@ARGV, $/) = ($rec); <> };
            $txt = '' unless defined $txt;

            my $f = $parse->($txt);
            is($f->{verdict}, 'reap',
                'parse: reads the verdict written by the real writer');
            is($f->{heartbeat_age_s}, '20402', 'parse: reads the heartbeat age');
            is($f->{host_suspends_detected}, '1', 'parse: reads the suspend count');
            like($f->{why}, qr/asleep, not because the manager died/,
                'parse: keeps the why= sentence WHOLE -- splitting on every "=" '
              . 'would truncate the one field a human actually reads');

            my $out = join "\n", $notice->($f);
            like($out, qr/shut itself down/,
                'notice: says the container stopped on its own, not that it crashed');
            like($out, qr/asleep, not because the manager died/,
                "notice: carries heartbeat.sh's own sentence rather than reconstructing one");
            like($out, qr/20402s old/,        'notice: shows how stale the sentinel was');
            like($out, qr/limit 600s/,        'notice: and the limit it was judged against');
            like($out, qr/keep-awake/,
                'notice: a suspend-shaped reap names the remedy -- the numbers alone '
              . 'do not tell the operator what to change');

            # Counter-fixture: the suspend advice must be able NOT to fire.
            my $rec2 = "$dir/nosuspend.txt";
            hb_call({ REAP_RECORD => $rec2, HB => 600 },
                    'write_reap_record reap 700 0 0');
            my $t2 = do { local (@ARGV, $/) = ($rec2); <> };
            my $o2 = join "\n", $notice->($parse->($t2 // ''));
            unlike($o2, qr/keep-awake/,
                'counter-fixture: no suspend detected -> no keep-awake advice, so the '
              . 'advice above is evidence and not a constant');

            # A hardstop is a different death and must read as one.
            my $rec3 = "$dir/hard.txt";
            hb_call({ REAP_RECORD => $rec3, HB => 600 },
                    'write_reap_record hardstop 700 1 0');
            my $t3 = do { local (@ARGV, $/) = ($rec3); <> };
            my $o3 = join "\n", $notice->($parse->($t3 // ''));
            like($o3, qr/graceful-shutdown window expired/,
                'notice: a hardstop is told as a hardstop, not as a self-reap');

            # An unreadable or absent record must be silent. A launcher that
            # shouts about a file it could not parse is worse than a quiet one.
            my @empty = $notice->($parse->(''));
            is(scalar(@empty), 0,
                'notice: an empty record produces no notice at all');
            my @junk = $notice->($parse->("garbage without any fields\n"));
            is(scalar(@junk), 0,
                'notice: an unparseable record produces no notice at all');
        }
    }
}

done_testing();

sub spew { my ($p,$c)=@_; open my $fh,'>:raw',$p or die "$p: $!"; print $fh $c; close $fh; }
