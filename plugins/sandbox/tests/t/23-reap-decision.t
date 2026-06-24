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

done_testing();

sub spew { my ($p,$c)=@_; open my $fh,'>:raw',$p or die "$p: $!"; print $fh $c; close $fh; }
