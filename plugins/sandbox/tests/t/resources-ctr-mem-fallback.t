#!/usr/bin/env perl
# platform: any
# The "ctr mem" gauge never shows a false 0.
#
# 2026-11-01, operator: "the ctr mem resource gauge is definitely wrong, it says 0b used". On the
# WSL podman machine there is no cgroup memory controller (`podman info`: controllers=[]), so
# `podman stats` reports MemUsage "0B / 10.43GB" for every container, while that container's
# processes held about 933 MB (summed PSS; 1.22 GB summed RSS). Resources::build passed the 0 on.
#
# AC1  parse_pss_kib: per-process "Pss: N kB" lines -> summed bytes; a zero sum, junk, undef -> undef
# AC2  build: stats 0 + a PSS reading -> the PSS figure
# AC3  build: stats 0 and no PSS -> undef (n/a), never 0
# AC4  build: a real stats figure wins over PSS
# AC5  the launcher's ctr_pss probe: podman exec of a plain grep (nothing for MSYS to mangle),
#      throttled, absent where the controller exists, last in the probe order
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use lib "$Bin/../../scripts";
use Resources ();

my $CTR = 'claude-acx-20f6a746';
sub stats_json { my ($mem) = @_; return qq([{"Name":"$CTR","MemUsage":"$mem","CPUPerc":"83.84%"}]) }
my $PSS = "Pss:              900000 kB\nPss:               32967 kB\n";

# --- AC1 ---------------------------------------------------------------------------------------------
is(Resources::parse_pss_kib($PSS), 932967 * 1024, 'AC1 per-process Pss lines are summed into bytes');
is(Resources::parse_pss_kib("Pss: 12 kB\r\n"), 12 * 1024, 'AC1 a CRLF line is fine');
is(Resources::parse_pss_kib("Pss: 0 kB\n"), undef, 'AC1 a zero sum is not a reading');
is(Resources::parse_pss_kib('Error: no such container'), undef, 'AC1 junk is not a reading');
is(Resources::parse_pss_kib(undef), undef, 'AC1 nothing is not a reading');

# --- AC2-AC4 -----------------------------------------------------------------------------------------
my $r = Resources::build({ container => $CTR, stats => stats_json('0B / 10.43GB'), ctr_pss => $PSS });
is($r->{ctr_mem_used}, 932967 * 1024, 'AC2 THE BUG: stats says 0B, the PSS fallback supplies the real figure');
ok(defined $r->{vm_mem_total} && $r->{vm_mem_total} > 0, 'AC2 the total still comes from stats');
is($r->{ctr_cpu_pct}, 83.84, 'AC2 cpu is untouched');

$r = Resources::build({ container => $CTR, stats => stats_json('0B / 10.43GB') });
ok(exists $r->{ctr_mem_used}, 'AC3 the key is still present (closed key set)');
is($r->{ctr_mem_used}, undef, 'AC3 stats 0B with no fallback renders n/a, not a false 0');

$r = Resources::build({ container => $CTR, stats => stats_json('512MB / 10.43GB'), ctr_pss => $PSS });
is($r->{ctr_mem_used}, 512 * 1000 * 1000, 'AC4 where stats can count memory, its figure wins');

# --- AC5 ---------------------------------------------------------------------------------------------
my $src = do { open my $fh, '<:raw', "$Bin/../../scripts/launcher.pl" or die $!; local $/; <$fh> };
my ($probes) = $src =~ /(sub _resources_probes \{.*?\n\})/s;
ok(defined $probes, 'precondition: _resources_probes is extractable');
like($probes // '', qr/my \(\$container\) = \@_;/, 'AC5 the probe builder receives the container');
like($src, qr/my \$probes = _resources_probes\(\$container\);/, 'AC5 and the sampler passes it');
my $cmd = q{$PODMAN exec $container sh -c 'grep -h ^Pss: /proc/[0-9]*/smaps_rollup'};
like($probes // '', qr/\Q$cmd\E/, 'AC5 a plain grep of smaps_rollup inside the container');
my ($inner) = ($probes // '') =~ /sh -c '([^']*)'/;
unlike($inner // '', qr/[\$\\"]/, 'AC5 the in-container command carries no $, backslash or double quote');
like($probes // '', qr/\$now - \$PSS_TRY_AT >= PSS_INTERVAL_SECS/, 'AC5 attempts are throttled');
like($src, qr/use constant PSS_INTERVAL_SECS => 60;/, 'AC5 to once a minute');
like($probes // '', qr/\$now - \$PSS_OK_AT < PSS_MAX_AGE_SECS\) \? \$PSS_TEXT : undef/, 'AC5 with a bounded carry-forward');
like($probes // '', qr/delete \$p\{ctr_pss\} if !defined \$container\s*\|\| eval \{ _podman_host_mem_bytes\(\); \$PODMAN_MEM_CONTROLLER \};/,
     'AC5 and no probe at all where podman stats can count memory');
my $rsrc = do { open my $fh, '<:raw', "$Bin/../../scripts/Resources.pm" or die $!; local $/; <$fh> };
like($rsrc, qr/my \@PROBE_ORDER = qw\(stats machine cim_mem cim_cpu cim_disk df ctr_pss\);/,
     'AC5 last in the probe order, so it only spends leftover budget');

done_testing();
