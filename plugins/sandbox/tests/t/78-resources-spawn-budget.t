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
    # _powershell_json now resolves its timeout binary and its stderr path
    # rather than spelling either out inline: a bare `timeout` was picking up
    # C:\Windows\System32\timeout.exe from the launcher's PowerShell-inherited
    # PATH and killing every probe on argument syntax. Both helpers are stubbed
    # here because this file measures SPAWN COUNT, not command construction --
    # t/44's FIXBATCH-1 owns what the command looks like.
    my $stubs = "sub _timeout_prefix { '' }\n"
              . "sub _probe_err_path { '/dev/null' }\n";
    my $ok = eval "package $pkg;\nuse strict;\nuse warnings;\nuse JSON::PP;\n"
           . "our \$WINDOWS_FAMILY = 1;\n$stubs\n$ps\n$bom\n$pj\n$all\n1;\n";  ## no critic
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

# ===========================================================================
# B -- `podman system df` HAS ITS OWN CADENCE, and the policy is a pure
# function so it can be checked without running a probe.
#
# Operator, 2026-08-26: the podman disk figures "sometimes they appear
# sometimes they disappear. Why?" -- then, on the fix: "the podman query is
# something that could happen once every e.g. 10 minutes".
#
# Measured on their host, three consecutive runs: `podman machine list` 0.54s,
# `podman stats` 0.56s, `podman system df` 10.6s / 18.8s / 25.1s. All three
# shared a five-second bound, so the third almost always died -- and it takes
# pod_images/pod_containers/pod_volumes with it, which is why they flapped as a
# group of exactly three.
#
# Raising the budget alone would have left a 10-to-25-second command running
# back to back at the sampler's 23-second cadence: the heaviest thing in the
# system, continuously, to re-measure storage totals that move on the order of
# hours. This section is that half of the fix -- the same spawn-budget concern
# the rest of this file exists for, one probe over.
# ===========================================================================
{
    my ($iv)  = $src =~ /use constant DF_INTERVAL_SECS\s*=>\s*(\d+)/;
    my ($max) = $src =~ /use constant DF_MAX_AGE_SECS\s*=>\s*(\d+)/;
    ok(defined $iv && defined $max, 'B1: both df cadence constants are declared')
        or diag("  interval=" . ($iv // 'undef') . " max_age=" . ($max // 'undef'));

  SKIP: {
        skip('cadence constants not found', 7) unless defined $iv && defined $max;

        # The interval must be far above the sampler's own, or the probe is
        # still effectively running every round -- which is the defect.
        my ($sample) = do {
            my $rp = "$ROOT/plugins/sandbox/scripts/Resources.pm";
            open my $fh, '<', $rp or die "read Resources.pm: $!";
            local $/; my $rs = <$fh>; close $fh;
            $rs =~ /my \$SAMPLE_INTERVAL\s*=\s*(\d+)/;
        };
        ok(defined $sample, 'B1: the sampler cadence is readable from Resources.pm');
        cmp_ok($iv, '>', 10 * ($sample // 23),
            "B1 CANONICAL: the df interval ($iv s) is an order of magnitude above the sampler "
          . 'cadence -- the probe stops riding every round, which is the whole point');
        cmp_ok($max, '>', $iv,
            'B1: a cached reading is believed for LONGER than the re-probe interval, or a '
          . 'single miss would blank the row that the cache exists to hold steady');

        # The two decisions, extracted and exercised directly.
        my ($should)  = $src =~ /(sub _df_should_probe \{.*?\n\})/s;
        my ($believe) = $src =~ /(sub _df_believe_cached \{.*?\n\})/s;
        ok(defined $should && defined $believe, 'B2: both cadence deciders are extractable');

      SKIP: {
            skip('deciders not extractable', 3) unless defined($should) && defined($believe);
            my $pkg = 'DfCadence';
            my $ok = eval "package $pkg;\nuse strict;\nuse warnings;\n"
                   . "use constant DF_INTERVAL_SECS => $iv;\n"
                   . "use constant DF_MAX_AGE_SECS  => $max;\n$should\n$believe\n1;\n";  ## no critic
            ok($ok, 'B2: they eval cleanly into a fresh package') or diag("eval error: $@");

            no strict 'refs';   ## no critic
            my $sp = \&{"${pkg}::_df_should_probe"};
            my $bc = \&{"${pkg}::_df_believe_cached"};

            # THE FIRST ROUND ALWAYS PROBES, then not again until due. Asserted
            # across the boundary from both sides, so an off-by-one shows up.
            ok($sp->(1000, undef),          'B3: with no prior attempt the probe runs');
            ok(!$sp->(1000, 1000),          'B3: immediately after an attempt it does not');
            ok(!$sp->(1000 + $iv - 1, 1000), 'B3: one second before it is due, it does not');
            ok($sp->(1000 + $iv, 1000),      'B3: at the interval, it does');

            # ATTEMPTS are throttled, not successes -- the failure case is the
            # one that matters, because a probe that TIMES OUT and is retried
            # every round is the original defect wearing a longer timeout.
            ok(!$sp->(1000 + 23, 1000),
               'B3 CANONICAL: a FAILED attempt still counts as an attempt -- a timing-out probe '
             . 'is not retried on the next sampler round');

            # ...and the carry-forward is bounded, so a permanently-broken
            # probe degrades to n/a rather than showing figures that quietly
            # stopped being true.
            ok($bc->(1000 + $max - 1, 1000),
               'B4: a reading younger than the max age is still believed');
            ok(!$bc->(1000 + $max, 1000),
               'B4 CANONICAL: at the max age it is NOT -- a cache believed forever stops being a '
             . 'measurement and becomes a claim');
            ok(!$bc->(1000, undef),
               'B4: with no successful reading ever, nothing is believed');
        }
    }
}

done_testing();
