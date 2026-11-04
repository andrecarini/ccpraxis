#!/usr/bin/env perl
# platform: any
# ORACLE for package 01-awake-constants (blueprint wake-and-pause-consolidation),
# AC-1..AC-14, AC-16 of
# .ccpraxis-local-data/blueprints/wake-and-pause-consolidation/specs/01-awake-constants-spec.md
# (AC-15 lives in the existing suites it names, unedited except for description
# strings in keepawake-decision-core.t).
#
# Six timing quantities (FLEET_PAUSE_HORIZON, SOLO_PAUSE_HORIZON, LEASE_FRESH,
# HELPER_LEASE, AC_GRACE, AC_STALE) move from bare literals scattered across the
# butler and sandbox plugins into one module, plugins/butler/scripts/BpAwakeConst.pm.
# This file pins: the module's shape and values (Part A), that every converted
# call site (S1-S9) refers to the named constant and no longer to its literal
# (Part B), that the values read through those sites are unchanged (Part C),
# that the two sites which stay literal (heartbeat.sh, Almanac::SessionLive) are
# pinned equal to the constants they mirror (Part D), that KeepAwake.pm's header
# no longer claims a ~60s busy-lease refresh (Part E), and that the sandbox
# plugin keeps working with no butler plugin beside it via a path-based loader
# with a literal fallback (Part F, criterion 3).
#
# Written BLIND to the implementation: every regex and expected value below is
# taken directly from spec sections 2 and 4, not from reading any of
# BpAwakeConst.pm, bp-orchestrator.pl, bp-drive-next.pl, BpContinuityLease.pm,
# BpPowerPlan.pm, bp-keepawake.pl, BpAcWatch.pm, launcher.pl or KeepAwake.pm.
#
# Never BAIL_OUT: a load failure anywhere is `fail()`'d once and the file keeps
# going, so a single missing module cannot hide the rest of the red (AC-16
# wants every site's regex to report, not just the first).
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Spec ();
use Test::More;

(my $BUTLER_SCRIPTS  = "$Bin/../../scripts")             =~ s{\\}{/}g;
(my $SANDBOX_SCRIPTS = "$Bin/../../../sandbox/scripts")  =~ s{\\}{/}g;
(my $HEARTBEAT_SH     = "$Bin/../../../sandbox/container/heartbeat.sh") =~ s{\\}{/}g;
(my $ALMANAC_SCRIPTS  = "$Bin/../../../almanac/scripts")  =~ s{\\}{/}g;

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    return <$fh>;
}

# ---------------------------------------------------------------------------
# Part A: AC-1, AC-2 -- the module itself
# ---------------------------------------------------------------------------
my @CONST_NAMES = qw(FLEET_PAUSE_HORIZON SOLO_PAUSE_HORIZON LEASE_FRESH HELPER_LEASE AC_GRACE AC_STALE);
my %EXPECT = (
    FLEET_PAUSE_HORIZON => 32 * 3600,
    SOLO_PAUSE_HORIZON  => 12 * 3600,
    LEASE_FRESH         => 600,
    HELPER_LEASE        => 900,
    AC_GRACE            => 300,
    AC_STALE            => 1800,
);

my $AWAKE_CONST_PM = "$BUTLER_SCRIPTS/BpAwakeConst.pm";
my $AWAKE_LOADED = do {
    local $@;
    eval { require $AWAKE_CONST_PM; 1 };
};
if (!$AWAKE_LOADED) {
    fail("AC-1: BpAwakeConst.pm failed to load: $@");
} else {
    # AC-1: exactly the six names in %BpAwakeConst::, excluding the special blocks,
    # with the expected values.
    no strict 'refs';
    my @stash_subs = grep {
        defined &{"BpAwakeConst::$_"} && $_ !~ /^(?:BEGIN|END|INIT|CHECK|UNITCHECK)$/
    } keys %BpAwakeConst::;
    use strict 'refs';
    is_deeply([ sort @stash_subs ], [ sort @CONST_NAMES ],
        'AC-1: BpAwakeConst:: defines exactly the six named constants, nothing else');
    for my $name (@CONST_NAMES) {
        my $got = eval { BpAwakeConst->can($name) ? BpAwakeConst::->$name() : undef };
        no strict 'refs';
        $got = defined &{"BpAwakeConst::$name"} ? &{"BpAwakeConst::$name"}() : undef;
        use strict 'refs';
        is($got, $EXPECT{$name}, "AC-1: BpAwakeConst::$name() == $EXPECT{$name}");
    }
}

# AC-2: source shape
{
    my $src = slurp($AWAKE_CONST_PM);
    if (!defined $src) {
        fail('AC-2: could not read BpAwakeConst.pm source');
    } else {
        my @lines = split /\n/, $src;
        my @filtered = grep { /\S/ && !/^\s*#/ } @lines;
        my @bad;
        my @const_names_seen;
        for my $line (@filtered) {
            if ($line =~ /^package BpAwakeConst;\s*$/) { next }
            if ($line =~ /^use (?:strict|warnings);\s*$/) { next }
            if ($line =~ /^use constant ([A-Z_]+)\s*=>\s*[0-9 *]+;\s*(?:#.*)?$/) {
                push @const_names_seen, $1;
                next;
            }
            if ($line =~ /^1;\s*$/) { next }
            push @bad, $line;
        }
        is(scalar(@bad), 0, 'AC-2: every non-comment, non-blank line matches an allowed shape')
            or diag("unexpected line(s): " . join(' | ', @bad));
        is_deeply([ sort @const_names_seen ], [ sort @CONST_NAMES ],
            'AC-2: the use-constant lines name exactly the six constants');

        # the line immediately preceding each `use constant` line in the
        # UNFILTERED file is a comment line.
        my @all_lines = split /\n/, $src;
        my @missing_comment;
        for my $i (0 .. $#all_lines) {
            if ($all_lines[$i] =~ /^use constant [A-Z_]+/) {
                my $prev = $i > 0 ? $all_lines[$i - 1] : '';
                push @missing_comment, $all_lines[$i] unless $prev =~ /^\s*#/;
            }
        }
        is(scalar(@missing_comment), 0, 'AC-2: every use-constant line is immediately preceded by a comment line')
            or diag("missing comment before: " . join(' | ', @missing_comment));
    }
}

# ---------------------------------------------------------------------------
# Part B + C: per-site source assertions and value checks, S1-S11
# ---------------------------------------------------------------------------

# -- S1, S2: bp-orchestrator.pl ---------------------------------------------
subtest 'S1 bp-orchestrator.pl:pause_holds_awake (AC-3)' => sub {
    my $path = "$BUTLER_SCRIPTS/bp-orchestrator.pl";
    my $src = slurp($path);
    if (!defined $src) { fail("could not read $path"); done_testing(); return }
    my ($body) = $src =~ /(sub pause_holds_awake \{.*?\n\})/s;
    ok(defined $body, 'sub pause_holds_awake is extractable') or do { done_testing(); return };
    like($body, qr/\$horizon\s*=\s*BpAwakeConst::FLEET_PAUSE_HORIZON\(\)\s+unless/,
        'AC-3: the horizon fallback refers to BpAwakeConst::FLEET_PAUSE_HORIZON()');
    unlike($body, qr/32\s*\*\s*3600/, 'AC-3: the literal 32 * 3600 is gone from the body');
    done_testing();
};

subtest 'S2 bp-orchestrator.pl:_tunables_base (AC-4)' => sub {
    my $path = "$BUTLER_SCRIPTS/bp-orchestrator.pl";
    my $src = slurp($path);
    if (!defined $src) { fail("could not read $path"); done_testing(); return }
    my ($body) = $src =~ /(sub _tunables_base \{.*?\n\})/s;
    ok(defined $body, 'sub _tunables_base is extractable') or do { done_testing(); return };
    like($body, qr/pause_horizon\s*=>\s*\$ENV\{BP_PAUSE_HORIZON_SECS\}\s*\/\/\s*BpAwakeConst::FLEET_PAUSE_HORIZON\(\)/,
        'AC-4: pause_horizon falls back to BpAwakeConst::FLEET_PAUSE_HORIZON(), env override kept');
    unlike($src, qr/\b32\s*\*\s*3600\b/, 'AC-4: no 32 * 3600 literal anywhere in bp-orchestrator.pl');

    # value check
    local $ENV{BP_PAUSE_HORIZON_SECS};
    delete $ENV{BP_PAUSE_HORIZON_SECS};
    my $loaded = do {
        local $@;
        eval { require $path; 1 };
    };
    if (!$loaded) {
        fail("AC-4 value check: could not load bp-orchestrator.pl: $@");
    } else {
        my $v = eval { BpOrch::_tunables_base()->{pause_horizon} };
        is($v, eval { BpAwakeConst::FLEET_PAUSE_HORIZON() },
            'AC-4: with BP_PAUSE_HORIZON_SECS unset, _tunables_base()->{pause_horizon} == FLEET_PAUSE_HORIZON');
    }
    done_testing();
};

# -- S3: bp-drive-next.pl ----------------------------------------------------
subtest 'S3 bp-drive-next.pl:$PAUSE_HORIZON_SECONDS (AC-5)' => sub {
    my $path = "$BUTLER_SCRIPTS/bp-drive-next.pl";
    my $src = slurp($path);
    if (!defined $src) { fail("could not read $path"); done_testing(); return }
    like($src, qr/our\s+\$PAUSE_HORIZON_SECONDS\s*=\s*BpAwakeConst::SOLO_PAUSE_HORIZON\(\)\s*;/,
        'AC-5: our $PAUSE_HORIZON_SECONDS is assigned from BpAwakeConst::SOLO_PAUSE_HORIZON()');
    unlike($src, qr/our\s+\$PAUSE_HORIZON_SECONDS\s*=\s*\d/,
        'AC-5: no literal-number assignment to $PAUSE_HORIZON_SECONDS remains');

    local $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    my $loaded = do {
        local $@;
        eval { require $path; 1 };
    };
    if (!$loaded) {
        fail("AC-5 value check: could not load bp-drive-next.pl: $@");
    } else {
        no strict 'vars';
        is($BpDrive::PAUSE_HORIZON_SECONDS, eval { BpAwakeConst::SOLO_PAUSE_HORIZON() },
            'AC-5: $BpDrive::PAUSE_HORIZON_SECONDS == SOLO_PAUSE_HORIZON');
    }
    done_testing();
};

# -- S4: BpContinuityLease.pm -----------------------------------------------
subtest 'S4 BpContinuityLease.pm:$BUSY_STALE_SECONDS (AC-6)' => sub {
    my $path = "$BUTLER_SCRIPTS/BpContinuityLease.pm";
    my $src = slurp($path);
    if (!defined $src) { fail("could not read $path"); done_testing(); return }
    like($src, qr/our\s+\$BUSY_STALE_SECONDS\s*=\s*BpAwakeConst::LEASE_FRESH\(\)\s*;/,
        'AC-6: $BUSY_STALE_SECONDS is assigned from BpAwakeConst::LEASE_FRESH()');

    my $loaded = do {
        local $@;
        eval { require $path; 1 };
    };
    if (!$loaded) {
        fail("AC-6 value check: could not load BpContinuityLease.pm: $@");
    } else {
        no strict 'vars';
        is($BpContinuityLease::BUSY_STALE_SECONDS, eval { BpAwakeConst::LEASE_FRESH() },
            'AC-6: $BpContinuityLease::BUSY_STALE_SECONDS == LEASE_FRESH');
    }
    done_testing();
};

# -- S5: BpPowerPlan.pm -------------------------------------------------------
subtest 'S5 BpPowerPlan.pm:$SANDBOX_HOLD_FRESH_SECONDS (AC-7)' => sub {
    my $path = "$BUTLER_SCRIPTS/BpPowerPlan.pm";
    my $src = slurp($path);
    if (!defined $src) { fail("could not read $path"); done_testing(); return }
    like($src, qr/our\s+\$SANDBOX_HOLD_FRESH_SECONDS\s*=\s*BpAwakeConst::LEASE_FRESH\(\)\s*;/,
        'AC-7: $SANDBOX_HOLD_FRESH_SECONDS is assigned from BpAwakeConst::LEASE_FRESH()');

    my $loaded = do {
        local $@;
        eval { require $path; 1 };
    };
    if (!$loaded) {
        fail("AC-7 value check: could not load BpPowerPlan.pm: $@");
    } else {
        no strict 'vars';
        is($BpPowerPlan::SANDBOX_HOLD_FRESH_SECONDS, eval { BpAwakeConst::LEASE_FRESH() },
            'AC-7: $BpPowerPlan::SANDBOX_HOLD_FRESH_SECONDS == LEASE_FRESH');
    }
    done_testing();
};

# -- S6: bp-keepawake.pl -------------------------------------------------------
subtest 'S6 bp-keepawake.pl:-LeaseSeconds (AC-8)' => sub {
    my $path = "$BUTLER_SCRIPTS/bp-keepawake.pl";
    my $src = slurp($path);
    if (!defined $src) { fail("could not read $path"); done_testing(); return }
    like($src, qr/'-LeaseSeconds',\s*lease_seconds\(/,
        'AC-8: -LeaseSeconds is followed by lease_seconds(...)');
    unlike($src, qr/'-LeaseSeconds',\s*'?\d+'?/,
        'AC-8: no literal-number -LeaseSeconds argument remains');

    my ($lease_seconds_body) = $src =~ /(sub lease_seconds \{.*?\n\})/s;
    ok(defined $lease_seconds_body, 'AC-8 precondition: sub lease_seconds is extractable');
    if (defined $lease_seconds_body) {
        my @defaults = $lease_seconds_body =~ /return\s+BpAwakeConst::HELPER_LEASE\(\)\s*unless/g;
        ok(scalar(@defaults) >= 1,
            'AC-8: lease_seconds() defaults to BpAwakeConst::HELPER_LEASE() when no override is given')
            or diag("sub lease_seconds body: $lease_seconds_body");
    }
    done_testing();
};

# -- S7-S9: BpAcWatch.pm -------------------------------------------------------
subtest 'S7-S9 BpAcWatch.pm:GRACE / _default_wakelock_state / _drive_solo_lock_state (AC-9)' => sub {
    my $path = "$BUTLER_SCRIPTS/BpAcWatch.pm";
    my $src = slurp($path);
    if (!defined $src) { fail("could not read $path"); done_testing(); return }
    like($src, qr/use constant GRACE\s*=>\s*BpAwakeConst::AC_GRACE\(\)\s*;/,
        'AC-9 (S7): use constant GRACE is assigned from BpAwakeConst::AC_GRACE()');

    my ($default_ws) = $src =~ /(sub _default_wakelock_state \{.*?\n\})/s;
    ok(defined $default_ws, 'sub _default_wakelock_state is extractable');
    if (defined $default_ws) {
        like($default_ws, qr{//\s*BpAwakeConst::AC_STALE\(\)},
            'AC-9 (S8): _default_wakelock_state falls back to BpAwakeConst::AC_STALE()');
        unlike($default_ws, qr{//\s*1800}, 'AC-9 (S8): no literal 1800 fallback remains');
    }

    my ($solo_ls) = $src =~ /(sub _drive_solo_lock_state \{.*?\n\})/s;
    ok(defined $solo_ls, 'sub _drive_solo_lock_state is extractable');
    if (defined $solo_ls) {
        like($solo_ls, qr/\$age\s*<\s*BpAwakeConst::HELPER_LEASE\(\)/,
            'AC-9 (S9): _drive_solo_lock_state compares $age against BpAwakeConst::HELPER_LEASE()');
        unlike($solo_ls, qr/<\s*900/, 'AC-9 (S9): no literal 900 comparison remains');
    }

    my $loaded = do {
        local $@;
        local $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
        eval { require $path; 1 };
    };
    if (!$loaded) {
        fail("AC-9 value check: could not load BpAcWatch.pm: $@");
    } else {
        is(eval { BpAcWatch::GRACE() }, eval { BpAwakeConst::AC_GRACE() },
            'AC-9: BpAcWatch::GRACE() == AC_GRACE');
    }
    done_testing();
};

# -- S10, S11: launcher.pl -----------------------------------------------------
subtest 'S10-S11 launcher.pl:$BUSY_STALE / $busy_stale (AC-10)' => sub {
    my $path = "$SANDBOX_SCRIPTS/launcher.pl";
    my $src = slurp($path);
    if (!defined $src) { fail("could not read $path"); done_testing(); return }
    like($src,
        qr/my \$BUSY_STALE\s*=\s*\(\$ENV\{BUSY_STALE_SECS\}[^;]*?\?\s*\$ENV\{BUSY_STALE_SECS\}\s*:\s*KeepAwake::lease_fresh\(\)\s*;/s,
        'AC-10: $BUSY_STALE falls back to KeepAwake::lease_fresh()');
    like($src,
        qr/my \$busy_stale\s*=\s*\(\$ENV\{BUSY_STALE_SECS\}[^;]*?\?\s*\$ENV\{BUSY_STALE_SECS\}\s*:\s*KeepAwake::lease_fresh\(\)\s*;/s,
        'AC-10: $busy_stale falls back to KeepAwake::lease_fresh()');
    unlike($src, qr/BUSY_STALE_SECS\}\s*:\s*\d/,
        'AC-10: no BUSY_STALE_SECS ... : <digit> literal fallback remains');
    done_testing();
};

# -- S12-S13: KeepAwake.pm -----------------------------------------------------
subtest 'S12-S13 KeepAwake.pm:should_stay_awake / $LEASE_FRESH_FALLBACK (AC-11)' => sub {
    my $path = "$SANDBOX_SCRIPTS/KeepAwake.pm";
    my $src = slurp($path);
    if (!defined $src) { fail("could not read $path"); done_testing(); return }
    my ($body) = $src =~ /(sub should_stay_awake \{.*?\n\})/s;
    ok(defined $body, 'sub should_stay_awake is extractable');
    if (defined $body) {
        like($body, qr/\$stale\s*=\s*lease_fresh\(\)\s+unless/,
            'AC-11: $stale defaults via lease_fresh()');
        unlike($body, qr/\$stale\s*=\s*\d/, 'AC-11: no literal-number default for $stale remains');
    }

    my ($fallback_literal) = $src =~ /my \$LEASE_FRESH_FALLBACK\s*=\s*(\d+)\s*;/;
    ok(defined $fallback_literal, 'AC-11: $LEASE_FRESH_FALLBACK literal is present')
        or diag('no $LEASE_FRESH_FALLBACK = <digits>; found');
    like($src, qr{'/\.\./\.\./butler/scripts/BpAwakeConst\.pm'},
        "AC-11: the loader names '/../../butler/scripts/BpAwakeConst.pm'");
    my ($eval_block) = $src =~ /(eval\s*\{.*?BpAwakeConst.*?\n\s*\};)/s;
    ok(defined $eval_block, 'AC-11: the BpAwakeConst loader sits inside an eval {} block');

    SKIP: {
        skip 'BpAwakeConst.pm failed to load; cannot compute expected value', 1
            unless $AWAKE_LOADED;
        is($fallback_literal, eval { BpAwakeConst::LEASE_FRESH() },
            'AC-11: $LEASE_FRESH_FALLBACK literal == BpAwakeConst::LEASE_FRESH');
    }

    # in-tree behaviour check
    my $loaded = do {
        local $@;
        local @INC = ("$SANDBOX_SCRIPTS", @INC);
        eval { require 'KeepAwake.pm'; 1 };
    };
    if (!$loaded) {
        fail("AC-11 behaviour check: could not load KeepAwake.pm: $@");
    } else {
        SKIP: {
            skip 'BpAwakeConst.pm failed to load; cannot compute expected value', 3
                unless $AWAKE_LOADED;
            my $lf = eval { BpAwakeConst::LEASE_FRESH() };
            is(eval { KeepAwake::lease_fresh() }, $lf, 'AC-11: KeepAwake::lease_fresh() == LEASE_FRESH (in-tree)');
            is(eval { KeepAwake::should_stay_awake($lf, undef) }, 1,
                "AC-11: should_stay_awake(LEASE_FRESH, undef) == 1");
            is(eval { KeepAwake::should_stay_awake($lf + 1, 'x') }, 0,
                "AC-11: should_stay_awake(LEASE_FRESH + 1, 'x') == 0");
        }
    }
    done_testing();
};

# ---------------------------------------------------------------------------
# Part D: AC-12 -- pins on sites that stay literal
# ---------------------------------------------------------------------------
subtest 'Pins: heartbeat.sh and Almanac::SessionLive (AC-12)' => sub {
    my $hb_src = slurp($HEARTBEAT_SH);
    if (!defined $hb_src) {
        fail("could not read $HEARTBEAT_SH");
    } else {
        my @matches = $hb_src =~ /^HB="\$\{HB:-(\d+)\}"/mg;
        is(scalar(@matches), 1, 'AC-12: heartbeat.sh has exactly one HB default line');
        SKIP: {
            skip 'no HB default line found', 1 unless @matches;
            SKIP: {
                skip 'BpAwakeConst.pm failed to load', 1 unless $AWAKE_LOADED;
                is($matches[0], eval { BpAwakeConst::LEASE_FRESH() },
                    'AC-12: heartbeat.sh HB default == LEASE_FRESH');
            }
        }
    }

    my $sl_path = "$ALMANAC_SCRIPTS/Almanac/SessionLive.pm";
    my $loaded = do {
        local $@;
        eval { require $sl_path; 1 };
    };
    if (!$loaded) {
        fail("AC-12: could not load Almanac/SessionLive.pm: $@");
    } else {
        SKIP: {
            skip 'BpAwakeConst.pm failed to load', 1 unless $AWAKE_LOADED;
            no strict 'vars';
            is($Almanac::SessionLive::ARMED_SECONDS, eval { BpAwakeConst::SOLO_PAUSE_HORIZON() } + 3600,
                'AC-12: Almanac::SessionLive::ARMED_SECONDS == SOLO_PAUSE_HORIZON + 3600');
        }
    }
    done_testing();
};

# ---------------------------------------------------------------------------
# Part E: AC-13 -- KeepAwake.pm header correction
# ---------------------------------------------------------------------------
subtest 'KeepAwake.pm header (AC-13)' => sub {
    my $src = slurp("$SANDBOX_SCRIPTS/KeepAwake.pm");
    if (!defined $src) {
        fail('could not read KeepAwake.pm');
    } else {
        unlike($src, qr/~60s/, 'AC-13: the header no longer claims a ~60s busy-lease refresh');
        like($src, qr/watch_tick/, 'AC-13: the header names watch_tick');
    }
    done_testing();
};

# ---------------------------------------------------------------------------
# Part F (criterion 3): sandbox plugin works with no butler plugin beside it.
# Never runs launcher.pl: only `perl -c` (compile-only) and a one-line
# -MKeepAwake -e print. No image build, no container start.
# ---------------------------------------------------------------------------
subtest 'Sandbox-only fixture: no butler plugin present (AC-14)' => sub {
    my $T = tempdir(CLEANUP => 1);
    (my $Tf = $T) =~ s{\\}{/}g;

    # Step 1: copy the whole sandbox/scripts tree (recursively, incl. tui/)
    my $src_root = $SANDBOX_SCRIPTS;
    my $dst_root = "$Tf/plugins/sandbox/scripts";
    make_path($dst_root);
    find({
        no_chdir => 1,
        wanted   => sub {
            my $full = $File::Find::name;
            (my $rel = $full) =~ s{^\Q$src_root\E/?}{};
            return if $rel eq '';
            my $dest = "$dst_root/$rel";
            if (-d $full) {
                make_path($dest);
            } else {
                (my $dest_dir = $dest) =~ s{/[^/]+$}{};
                make_path($dest_dir);
                copy($full, $dest) or diag("copy failed: $full -> $dest: $!");
            }
        },
    }, $src_root);

    ok(!-e "$Tf/plugins/butler", 'precondition: no butler plugin exists in the fixture');

    # Step 2: perl -c on the fixture's launcher.pl
    {
        local $ENV{PERL5LIB};
        delete $ENV{PERL5LIB};
        my @cmd = ($^X, '-c', "$dst_root/launcher.pl");
        my $out = run_capture(\@cmd);
        is($out->{exit}, 0, 'AC-14: perl -c on the fixture launcher.pl exits 0')
            or diag("stdout: $out->{stdout}\nstderr: $out->{stderr}");
    }

    # Step 3: KeepAwake::lease_fresh() with no butler plugin present -> 600
    {
        local $ENV{PERL5LIB};
        delete $ENV{PERL5LIB};
        my @cmd = ($^X, "-I$dst_root", '-MKeepAwake', '-e', 'print KeepAwake::lease_fresh()');
        my $out = run_capture(\@cmd);
        is($out->{stdout}, '600', 'AC-14: lease_fresh() with no butler plugin -> 600');
        is($out->{exit}, 0, 'AC-14: exit 0');
        is($out->{stderr}, '', 'AC-14: stderr empty');
    }

    # Step 4: sentinel -- a real BpAwakeConst.pm with a different value is read
    for my $shape (
        { label => 'plugins layout',      sbx => 'plugins/sandbox/scripts',      btl => 'plugins/butler/scripts' },
        { label => 'marketplace layout',  sbx => 'marketplaces/ccpraxis-local/sandbox/scripts',
                                            btl => 'marketplaces/ccpraxis-local/butler/scripts' },
    ) {
        my $R = tempdir(CLEANUP => 1);
        (my $Rf = $R) =~ s{\\}{/}g;
        my $sbx_dir = "$Rf/$shape->{sbx}";
        my $btl_dir = "$Rf/$shape->{btl}";
        make_path($sbx_dir);
        make_path($btl_dir);
        copy("$SANDBOX_SCRIPTS/KeepAwake.pm", "$sbx_dir/KeepAwake.pm")
            or diag("copy KeepAwake.pm failed: $!");
        open my $fh, '>', "$btl_dir/BpAwakeConst.pm" or die $!;
        print $fh "package BpAwakeConst; use constant LEASE_FRESH => 4242; 1;\n";
        close $fh;

        local $ENV{PERL5LIB};
        delete $ENV{PERL5LIB};
        my @cmd = ($^X, "-I$sbx_dir", '-MKeepAwake', '-e', 'print KeepAwake::lease_fresh()');
        my $out = run_capture(\@cmd);
        is($out->{stdout}, '4242', "AC-14: sentinel ($shape->{label}) -> 4242");
        is($out->{exit}, 0, "AC-14: sentinel ($shape->{label}) exit 0");
        is($out->{stderr}, '', "AC-14: sentinel ($shape->{label}) stderr empty");
    }

    # Step 5: broken BpAwakeConst.pm (dies on load) -> fallback 600
    {
        my $R = tempdir(CLEANUP => 1);
        (my $Rf = $R) =~ s{\\}{/}g;
        my $sbx_dir = "$Rf/plugins/sandbox/scripts";
        my $btl_dir = "$Rf/plugins/butler/scripts";
        make_path($sbx_dir);
        make_path($btl_dir);
        copy("$SANDBOX_SCRIPTS/KeepAwake.pm", "$sbx_dir/KeepAwake.pm")
            or diag("copy KeepAwake.pm failed: $!");
        open my $fh, '>', "$btl_dir/BpAwakeConst.pm" or die $!;
        print $fh "die \"boom\\n\";\n";
        close $fh;

        local $ENV{PERL5LIB};
        delete $ENV{PERL5LIB};
        my @cmd = ($^X, "-I$sbx_dir", '-MKeepAwake', '-e', 'print KeepAwake::lease_fresh()');
        my $out = run_capture(\@cmd);
        is($out->{stdout}, '600', 'AC-14: broken BpAwakeConst.pm -> fallback 600');
        is($out->{exit}, 0, 'AC-14: broken case exit 0');
        is($out->{stderr}, '', 'AC-14: broken case stderr empty');
    }

    done_testing();
};

# run_capture(\@cmd) -- list-form open (no shell) captures stdout; stderr is
# captured by redirecting the *parent's* STDERR to a File::Temp file for the
# duration of the call and restoring it afterward (house pattern; see
# plugins/steward/tests/t/sync-export-repo-pairing.t's _spawn). Never reopens
# STDERR onto an in-memory scalar (Git-for-Windows perl: "Bad file descriptor").
sub run_capture {
    my ($cmd) = @_;
    require File::Temp;
    my ($efh, $efile) = File::Temp::tempfile();
    close $efh;
    open(my $saved_stderr, '>&', \*STDERR) or die "cannot dup STDERR: $!";
    open(STDERR, '>', $efile) or die "cannot redirect STDERR to $efile: $!";

    my $stdout = '';
    my $exit = -1;
    my $pid = open(my $ofh, '-|', @$cmd);
    if ($pid) {
        local $/;
        $stdout = <$ofh>;
        $stdout = '' unless defined $stdout;
        close $ofh;
        $exit = $? >> 8;
    }

    open(STDERR, '>&', $saved_stderr) or warn "cannot restore STDERR: $!";
    close $saved_stderr;

    my $stderr = slurp($efile) // '';
    unlink $efile;
    return { stdout => $stdout, stderr => $stderr, exit => $exit };
}

done_testing();
