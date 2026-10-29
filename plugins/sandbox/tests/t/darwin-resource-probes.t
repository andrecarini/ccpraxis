#!/usr/bin/env perl
# platform: any
# The dashboard's Resources panel on a macOS host, and the probe bound that
# keeps a wedged probe from stalling the sampler.
#
# The host rows (RAM, swap, CPU, disk) were Windows-only: their probes were
# PowerShell CIM queries, and on any other host the keys were absent, so a Mac
# showed n/a for everything but the container. macOS now reads sysctl,
# vm_stat, ps and df, and Resources::darwin_* turn that text into the same
# CIM JSON shapes, so the existing parsers and build() serve both hosts.
#
# macOS also ships no `timeout`, so every probe ran unbounded there; the
# sampler now falls back to bounded-run.pl (perl fork/alarm/kill, exit 124).
#
# Fixtures are verbatim output from a macOS 27 / Apple Silicon host.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use JSON::PP ();
use Time::HiRes ();
use Resources ();

my $MEM = <<'TXT';
51539607552
total = 1024.00M  used = 0.25M  free = 1023.75M  (encrypted)
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                    15378.
Pages active:                                1009574.
Pages inactive:                              1015688.
Pages speculative:                               488.
Pages throttled:                                   0.
Pages wired down:                             197045.
Pages purgeable:                                5903.
"Translation faults":                      522501692.
TXT
my $CPU = "18\n  2.1\n  1.2\n  0.0\n 90.0\n";
my $DF  = <<'TXT';
Filesystem   1024-blocks      Used Available Capacity  Mounted on
/dev/disk3s5   971298980 132070812 811379424    14%    /System/Volumes/Data
TXT

# ---- memory ---------------------------------------------------------------
{
    my $j = JSON::PP->new->decode(Resources::darwin_memory_json($MEM));
    is($j->{TotalVisibleMemorySize}, 51539607552 / 1024, 'mem: total from hw.memsize, in KB');
    is($j->{FreePhysicalMemory}, int((15378 + 1015688 + 488) * 16384 / 1024),
        'mem: free counts free + inactive + speculative pages (macOS keeps file cache in inactive)');
    is($j->{SizeStoredInPagingFiles}, 1024 * 1024, 'mem: swap total from vm.swapusage (1024.00M -> KB)');
    is($j->{FreeSpaceInPagingFiles}, int(1023.75 * 1024), 'mem: swap free from vm.swapusage');
    my $parsed = Resources::parse_cim_memory(Resources::darwin_memory_json($MEM));
    is($parsed->{ram_total}, 51539607552, 'mem: the shared CIM parser reads it back in bytes');

    my $noswap = $MEM;
    $noswap =~ s/total = 1024\.00M  used = 0\.25M  free = 1023\.75M/total = 0.00M  used = 0.00M  free = 0.00M/;
    my $j2 = JSON::PP->new->decode(Resources::darwin_memory_json($noswap));
    is($j2->{SizeStoredInPagingFiles}, 0, 'mem: no swap configured reads as a real 0, not n/a');
    ok(!defined Resources::darwin_memory_json("sysctl: unknown oid\n"), 'mem: unparseable text -> undef (n/a), never a zero');
    ok(!defined Resources::darwin_memory_json(undef), 'mem: no output -> undef');
}

# ---- cpu ------------------------------------------------------------------
{
    my $j = JSON::PP->new->decode(Resources::darwin_cpu_json($CPU));
    is($j->{NumberOfLogicalProcessors}, 18, 'cpu: core count from hw.logicalcpu');
    is($j->{LoadPercentage}, int((2.1 + 1.2 + 0 + 90) / 18 + 0.5), 'cpu: sum of per-process %CPU over the core count');
    my $busy = JSON::PP->new->decode(Resources::darwin_cpu_json("2\n100\n100\n100\n"));
    is($busy->{LoadPercentage}, 100, 'cpu: clamped at 100');
    ok(!defined Resources::darwin_cpu_json("not a number\n1.0\n"), 'cpu: no core count -> undef');
}

# ---- disk -----------------------------------------------------------------
{
    is(Resources::darwin_disk_device($DF), '/System/Volumes/Data', 'disk: the device is the mount point');
    my $d = Resources::parse_cim_disk(Resources::darwin_disk_json($DF), Resources::darwin_disk_device($DF));
    is($d->{disk_total}, 971298980 * 1024, 'disk: size in bytes');
    is($d->{disk_free}, 811379424 * 1024, 'disk: free is the space AVAILABLE (APFS volumes share a container)');
    my $spaced = "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
               . "/dev/disk5s1 1000 400 600 40% /Volumes/My Disk\n";
    is(Resources::darwin_disk_device($spaced), '/Volumes/My Disk', 'disk: a mount point with spaces is kept whole');
    ok(!defined Resources::darwin_disk_json("df: /nope: No such file or directory\n"), 'disk: df error -> undef');
}

# ---- build() over the three -------------------------------------------------
{
    my $r = Resources::build({
        cim_mem => Resources::darwin_memory_json($MEM),
        cim_cpu => Resources::darwin_cpu_json($CPU),
        cim_disk => Resources::darwin_disk_json($DF),
        device  => Resources::darwin_disk_device($DF),
    });
    ok(defined $r->{host_ram_used} && defined $r->{host_ram_total}, 'build: host RAM row filled');
    ok(defined $r->{host_swap_total}, 'build: host swap row filled');
    ok(defined $r->{host_cpu_pct} && $r->{host_cores} == 18, 'build: host CPU row filled');
    is($r->{host_disk_dev}, '/System/Volumes/Data', 'build: host disk row names the volume');
}

# ---- launcher wiring (source level; launcher.pl is never require'd) ---------
my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
open my $fh, '<:raw', $LAUNCHER or BAIL_OUT("cannot read $LAUNCHER: $!");
my $SRC = do { local $/; <$fh> };
close $fh;
my ($probes) = $SRC =~ /\nsub _resources_probes \{(.*?)\n\}\n/s;
ok(defined $probes, '_resources_probes is extractable');
$probes //= '';
my ($darwin) = $probes =~ /if \(\$\^O eq 'darwin'\) \{(.*?)\n        return \\%p;\n    \}/s;
ok(defined $darwin, '_resources_probes has a darwin branch');
$darwin //= '';
for my $k (qw(machine cim_mem cim_cpu cim_disk)) {
    like($darwin, qr/\$p\{$k\}\s*=\s*sub/, "darwin branch provides the $k probe");
}
is(scalar(() = $darwin =~ /\$\{t\}/g), 4, 'every darwin probe carries the timeout prefix');
like($darwin, qr/Resources::darwin_memory_json\(.*Resources::darwin_cpu_json\(.*Resources::darwin_disk_json\(/s,
    'the darwin probes hand their text to the Resources::darwin_* shapers');
my ($tbin) = $SRC =~ /\nsub _gnu_timeout_bin \{(.*?)\n\}\n/s;
like($tbin // '', qr{bounded-run\.pl}, '_gnu_timeout_bin falls back to bounded-run.pl');
like($tbin // '', qr{if \(!\$WINDOWS_FAMILY && -f \$bounded\)}, '...only off Windows');

# ---- bounded-run.pl ---------------------------------------------------------
SKIP: {
    skip 'bounded-run.pl is the fallback for POSIX hosts only', 5 if $^O eq 'MSWin32';
    my $br = "$Bin/../../scripts/bounded-run.pl";
    my $t0 = Time::HiRes::time();
    my $out = `"$^X" "$br" 1 sh -c 'echo started; sleep 20' 2>&1`;
    my ($rc, $took) = ($? >> 8, Time::HiRes::time() - $t0);
    is($rc, 124, 'bounded-run: a command past its bound exits 124 (GNU timeout\'s code)');
    ok($took < 5, sprintf('bounded-run: ...within the bound plus the TERM grace (%.1fs)', $took));
    like($out, qr/^started$/m, 'bounded-run: the command\'s stdout is inherited (capturable by backticks)');
    `"$^X" "$br" 5 sh -c 'exit 7'`;
    is($? >> 8, 7, 'bounded-run: a command that finishes keeps its own exit code');
    $t0 = Time::HiRes::time();
    `"$^X" "$br" 1 "$^X" -e '\$SIG{TERM}="IGNORE"; sleep 20'`;
    ok(Time::HiRes::time() - $t0 < 5, 'bounded-run: a command that ignores TERM is KILLed a second later');
}

# ---- live, on a Mac: the real commands parse -------------------------------
SKIP: {
    skip 'live macOS probe commands', 3 unless $^O eq 'darwin';
    ok(defined Resources::darwin_memory_json(scalar `/bin/sh -c 'sysctl -n hw.memsize vm.swapusage; vm_stat' 2>/dev/null`),
        'live: this Mac\'s memory probe parses');
    ok(defined Resources::darwin_cpu_json(scalar `/bin/sh -c 'sysctl -n hw.logicalcpu; ps -A -o %cpu=' 2>/dev/null`),
        'live: this Mac\'s CPU probe parses');
    ok(defined Resources::darwin_disk_device(scalar `df -kP "$Bin" 2>/dev/null`),
        'live: this Mac\'s df names a volume');
}

done_testing();
