#!/usr/bin/env perl
# Pins the assumption that the current container backend's host bind
# mount supports O_APPEND writes and utimensat (UTIME_NOW + explicit
# timestamp). Both syscalls used to fail silently on Hyper-V's 9p share,
# motivating the now-retired xfs-volume workaround. Re-failure of this
# test means the workaround needs to come back for this backend.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Test::More;
use TestSandbox qw(podman_run_capture create_probe_container new_temp_dir probe_image);

plan tests => 3;

my $host_dir = new_temp_dir();

my $c = create_probe_container(mounts => ['-v', "$host_dir:/probe"]);

# T1: O_APPEND write doesn't return EIO.
my ($rc_t1, $out_t1) = podman_run_capture('exec', $c, 'bash', '-c',
    'set -e; cd /probe; ' .
    ': > t1.log; ' .
    'echo a >> t1.log; ' .
    'echo b >> t1.log; ' .
    'echo c >> t1.log; ' .
    'printf "d\n" | dd of=t1.log oflag=append conv=notrunc bs=2 count=1 status=none; ' .
    '[ "$(wc -l < t1.log)" -ge 4 ] && grep -q c t1.log && grep -q d t1.log');
is($rc_t1, 0, 'T1 O_APPEND writes succeed (no EIO) on host bind') or diag($out_t1);

# T2: utimensat UTIME_NOW (`touch`) updates mtime.
my ($rc_t2, $out_t2) = podman_run_capture('exec', $c, 'bash', '-c',
    'set -e; cd /probe; ' .
    ': > t2.tmp; ' .
    'touch -t 202001010000 t2.tmp; ' .
    'BEFORE=$(stat -c %Y t2.tmp); ' .
    'sleep 1; ' .
    'touch t2.tmp; ' .
    'AFTER=$(stat -c %Y t2.tmp); ' .
    'NOW=$(date +%s); ' .
    '[ "$AFTER" -gt "$BEFORE" ] && [ $((NOW - AFTER)) -lt 60 ]');
is($rc_t2, 0, 'T2 utimensat UTIME_NOW updates mtime on host bind') or diag($out_t2);

# T3: utimensat with explicit timestamp doesn't return EPERM.
my ($rc_t3, $out_t3) = podman_run_capture('exec', $c, 'bash', '-c',
    'set -e; cd /probe; ' .
    ': > t3.tmp; ' .
    'touch -d "2020-01-01 00:00:00 UTC" t3.tmp; ' .
    '[ "$(stat -c %Y t3.tmp)" = "1577836800" ]');
is($rc_t3, 0, 'T3 utimensat explicit timestamp succeeds on host bind') or diag($out_t3);
