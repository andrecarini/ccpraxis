#!/usr/bin/env perl
# Regression oracle: the Resources sample round costs ONE powershell.exe, not three.
#
# WHY THIS EXISTS. The operator had to force-restart this machine twice with the
# process list full of powershell.exe and conhost.exe. The first fix (e13cc03)
# removed a spawn from the keep-awake probe -- real, but an order of magnitude
# too small, and the second restart happened anyway.
#
# The dominant source was here, and this repo's own terminal-minimize
# investigation had already measured it: _powershell_json driven by three
# separate CIM probes (cim_mem, cim_cpu, cim_disk) per Resources sample round,
# gated at a 23s interval -- ~470 powershell.exe per hour, each with the
# conhost.exe Windows attaches to it, for as long as a dashboard is open.
#
# The three queries are independent and were already sampled together, so they
# collapse into one invocation. This file pins that they stay collapsed.
#
# NEVER executes launcher.pl -- it builds container images and starts
# containers. The two subs under test are extracted from its source and eval'd,
# the same technique t/47 and t/58 already use.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Cwd qw(abs_path);

sub fwd { (my $p = shift) =~ s{\\}{/}g; $p }
my $ROOT     = fwd(abs_path("$Bin/../../../..") // "$Bin/../../../..");
my $LAUNCHER = "$ROOT/plugins/sandbox/scripts/launcher.pl";

ok(-f $LAUNCHER, 'sanity: launcher.pl exists') or do { done_testing(); exit };

my $src = do {
    open my $fh, '<:raw', $LAUNCHER or die "read launcher: $!";
    local $/; <$fh>;
};

# ---------------------------------------------------------------------------
# A1 -- structural: the combined command exists and the per-probe wiring uses it
# ---------------------------------------------------------------------------
like($src, qr/cim_all\s*=>/, 'A1: a combined cim_all command is declared');
like($src, qr/sub\s+_cim_all\b/, 'A1: _cim_all() exists');

my ($probes) = $src =~ /sub\s+_resources_probes\s*\{(.*?)\n\}/s;
ok(defined $probes, 'A1: _resources_probes is locatable');

if (defined $probes) {
    # Each of the three keys must go through _cim_all, NOT its own
    # _powershell_json call. That is the whole point.
    for my $k (qw(cim_mem cim_cpu cim_disk)) {
        like($probes, qr/\Q$k\E\s*\}?\s*=\s*sub\s*\{\s*_cim_all\(\)/,
            "A1: \$p{$k} is served from the single combined probe");
    }
    unlike($probes, qr/_powershell_json\(\s*\$cmd\{cim_(?:mem|cpu|disk)\}/,
        'A1: no probe calls _powershell_json per-key any more (that was the 3x cost)');
}

# ---------------------------------------------------------------------------
# A2 -- BEHAVIOURAL: one round, one spawn.
#
# The structural check above can be satisfied while still spawning three times
# (e.g. if the memo were dropped), so the count is measured for real by
# wrapping _powershell_json and pulling all three probe keys.
#
# Windows-only: off Windows _powershell_json returns undef by design and there
# is nothing to count.
# ---------------------------------------------------------------------------
SKIP: {
    skip 'powershell probes are Windows-only by design', 3
        unless $^O =~ /^(MSWin32|msys|cygwin)$/;

    my ($ps)  = $src =~ /(sub _ps_commands \{.*?\n\})/s;
    my ($bom) = $src =~ /(sub _strip_bom \{.*?\n\})/s;
    my ($pj)  = $src =~ /(sub _powershell_json \{.*?\n\})/s;
    my ($all) = $src =~ /(\{\n    my \(\$cim_cache.*?\n\})\n/s;

    ok((defined $ps && defined $bom && defined $pj && defined $all),
        'A2: the probe subs are extractable from launcher.pl')
        or skip('extraction failed', 2);

    my $pkg = 'ResSpawnBudget';
    my $ok = eval "package $pkg;\nuse strict;\nuse warnings;\nuse JSON::PP;\n"
           . "our \$WINDOWS_FAMILY = 1;\n$ps\n$bom\n$pj\n$all\n1;\n";  ## no critic
    ok($ok, 'A2: they eval cleanly into a fresh package') or do {
        diag("eval error: $@");
        skip('eval failed', 1);
    };

    my $spawns = 0;
    {
        no strict 'refs';       ## no critic
        no warnings 'redefine';
        my $orig = \&{"${pkg}::_powershell_json"};
        *{"${pkg}::_powershell_json"} = sub { $spawns++; return $orig->(@_) };
    }

    # One sample round pulls all three keys, in whatever order gather likes.
    my $r = \&{"${pkg}::_cim_all"};
    $r->()->{mem};
    $r->()->{cpu};
    $r->()->{disk};

    cmp_ok($spawns, '<=', 1,
        "A2: one sample round costs at most ONE powershell.exe (measured: $spawns; was 3)");
}

done_testing();
