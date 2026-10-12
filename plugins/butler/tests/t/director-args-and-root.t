#!/usr/bin/env perl
# platform: windows
# never-halt package 04 (director args and data root). Immutable oracle,
# written blind to the implementation, from:
#   .ccpraxis-local-data/blueprints/never-halt/specs/
#   (the "director args and data root" spec for that package)
# 22 acceptance criteria (AC1..AC22), bug 0f1e.
#
# Everything here runs on FIXTURES ONLY: a per-file tempdir root R holds a
# fake HOME and a fake TMP, plus a sentinel .ccpraxis-local-data whose sole
# purpose is to catch an escaping walk before it can reach the real home.
# Neither the real ~/.ccpraxis-local-data nor the repo's own is ever read,
# written, or used as an expected value.
use strict;
use warnings;
BEGIN { $ENV{CCPRAXIS_NO_WAKELOCK} = 1 } # package 16 post-fix-batch (Decision 80): never a real wake-lock invocation here.
# AC15 (08-blueprint-parks fix-batch, SF-3): pin ALMANAC_HOME to an isolated
# tempdir before any production code loads (Decision 29) -- this file names
# no ALMANAC_HOME today. Deliberately NOT re-pinning HOME/USERPROFILE here:
# $RAW_HOST_HOME below (and the fixture override later in this file) depend
# on reading the REAL host HOME before any override, which is the whole
# point of the M1 regression a few lines down; pinning it this early would
# make that check vacuous instead of hardening it.
BEGIN {
    require File::Temp;
    $ENV{ALMANAC_HOME} = File::Temp::tempdir(CLEANUP => 1);
}
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Find;
use Cwd qw(getcwd);

my $IS_WIN = ($^O =~ /^(MSWin32|msys|cygwin)$/) ? 1 : 0;

# Raw host TMP/TEMP, captured BEFORE any fixture override, for AC17(d)'s 8.3
# probe (which needs to know what the host's OWN temp spelling looks like).
my $RAW_HOST_TMP  = $ENV{TMP};
my $RAW_HOST_TEMP = $ENV{TEMP};
# Raw host HOME, captured BEFORE any fixture override, so the M1 regression
# can assert its result never names the real home's data dir.
my $RAW_HOST_HOME = $ENV{HOME};
$RAW_HOST_HOME = $ENV{USERPROFILE} unless defined $RAW_HOST_HOME && length $RAW_HOST_HOME;

my $SCRIPTS          = "$Bin/../../scripts";
my $DRIVE_SCRIPT     = "$SCRIPTS/bp-drive-next.pl";
my $LIFECYCLE_SCRIPT = "$SCRIPTS/bp-lifecycle.pl";
my $DATAROOT_MODULE  = "$SCRIPTS/BpDataRoot.pm";

# ─────────────────────────────────────────────────────────────────────────
# Fixture layout (spec §4).
# ─────────────────────────────────────────────────────────────────────────
my $R = tempdir(CLEANUP => 1);
$R =~ s{\\}{/}g;

# Sentinel: an ancestor of both fake roots. Any walk that escapes the
# fixture and climbs to a REAL ancestor would never see this, so if a test
# below ever resolves to something UNDER $R/.ccpraxis-local-data by
# accident, that is itself informative — but the real intent is: an
# escaping walk in production would land in the real home, which none of
# these assertions ever reference.
make_path("$R/.ccpraxis-local-data/blueprints/sentinel-audited-bp/packages");

my $H = "$R/home";
make_path("$H/.ccpraxis-local-data/blueprints/home-audited-bp/packages");

my $T = "$H/AppData/Local/Temp";           # nested (bug shape: TMP under HOME)
make_path("$T/.ccpraxis-local-data/blueprints/temp-audited-bp/packages");

my $T2 = "$R/tmp";                          # sibling (TMP beside HOME)
make_path("$T2/.ccpraxis-local-data/blueprints/temp2-audited-bp/packages");

make_path("$T/probe/deep");
make_path("$T2/probe");
make_path("$H/noproj/deep");
make_path("$H/proj/src/deep");     # AC13's nested project lives under here
make_path("$R/gitroot");           # AC15(e)'s fake git toplevel

$ENV{HOME}       = $H;
$ENV{USERPROFILE}= $H;
$ENV{TMP}        = $T;
$ENV{TEMP}       = $T;
$ENV{TMPDIR}     = $T;
$ENV{BUTLER_STATE_DIR}   = "$R/state";
$ENV{CCPRAXIS_DATA_DIR}  = "$R/guard-data";   # Decision 11(13): set file-wide
make_path("$R/guard-data/blueprints");
$ENV{CCPRAXIS_NO_WAKELOCK} = 1;

# ─────────────────────────────────────────────────────────────────────────
# Generic helpers.
# ─────────────────────────────────────────────────────────────────────────

sub write_file {
    my ($path, $content) = @_;
    my $d = $path; $d =~ s{[\\/][^\\/]+\z}{};
    make_path($d) unless -d $d;
    open my $fh, '>:raw', $path or die "write $path: $!";
    print $fh $content;
    close $fh;
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

# Snapshot relative-path => "size:mtime" (or "DIR") for every entry under
# $root. Used to prove a rejected/failed call wrote NOTHING, anywhere.
sub snapshot_tree {
    my ($root) = @_;
    my %snap;
    return \%snap unless -d $root;
    my @stack = ($root);
    while (my $d = pop @stack) {
        opendir(my $dh, $d) or next;
        for my $e (readdir $dh) {
            next if $e eq '.' || $e eq '..';
            my $p = "$d/$e";
            my $rel = File::Spec->abs2rel($p, $root);
            if (-d $p) { $snap{$rel} = 'DIR'; push @stack, $p; }
            else {
                my @st = stat($p);
                $snap{$rel} = "@st[7,9]";
            }
        }
        closedir $dh;
    }
    return \%snap;
}

sub find_named_dirs {
    my ($root, $name) = @_;
    return () unless -d $root;
    my @hits;
    find(sub { push @hits, $File::Find::name if -d $_ && $_ eq $name }, $root);
    return @hits;
}

# One subprocess runner for BOTH bp-drive-next.pl and bp-lifecycle.pl.
# cwd is set with perl's own chdir (never a shell `cd`), restored after.
# STDOUT/STDERR are captured through real temp FILES, never an in-memory
# scalar reopen (Git-for-Windows "Bad file descriptor" landmine).
sub run_script_subprocess {
    my (%o) = @_;
    my $script = $o{script};
    my @args   = @{ $o{args} || [] };
    my $cwd    = $o{cwd};
    my %over   = %{ $o{env} || {} };

    my ($ofh, $opath) = tempfile('dar-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('dar-errXXXXXX', TMPDIR => 1); close $efh;

    local %ENV = %ENV;
    for my $k (keys %over) {
        if (defined $over{$k}) { $ENV{$k} = $over{$k} }
        else                   { delete $ENV{$k} }
    }
    $ENV{CCPRAXIS_NO_WAKELOCK} = 1;
    $ENV{CCPRAXIS_USAGE_VERDICT_JSON} = '{"action":"ok"}'
        unless exists $over{CCPRAXIS_USAGE_VERDICT_JSON};

    my $saved_cwd = getcwd();
    if (defined $cwd) {
        chdir($cwd) or die "chdir $cwd: $!";
    }

    open(my $oldout, '>&', \*STDOUT) or die "dup STDOUT: $!";
    open(my $olderr, '>&', \*STDERR) or die "dup STDERR: $!";
    open(STDOUT, '>', $opath) or do { open(STDOUT, '>&', $oldout); die "redirect STDOUT: $!" };
    open(STDERR, '>', $epath) or do { open(STDERR, '>&', $olderr); die "redirect STDERR: $!" };
    my $sysrc = system($^X, $script, @args);
    open(STDOUT, '>&', $oldout) or die "restore STDOUT: $!"; close $oldout;
    open(STDERR, '>&', $olderr) or die "restore STDERR: $!"; close $olderr;

    chdir($saved_cwd) if defined $cwd;

    my $out = slurp($opath) // '';
    my $err = slurp($epath) // '';
    unlink $opath, $epath;
    return (($sysrc == -1 ? -1 : $sysrc >> 8), $out, $err);
}

# ── in-process (BpDrive::run) capture ───────────────────────────────────
my $LOADED = do {
    local $@;
    eval { require $DRIVE_SCRIPT };
    !$@;
};

sub capture_inproc {
    my ($argv, $opts) = @_;
    $opts //= {};
    $opts->{now}                  //= sub { 1_830_297_600 };
    $opts->{verdict}              //= sub { { action => 'ok' } };
    $opts->{spawn}                //= sub { };
    $opts->{kill_pid}             //= sub { };
    $opts->{powershell_available} //= sub { 0 };
    my ($ofh, $opath) = tempfile('dar-ip-outXXXXXX', TMPDIR => 1); close $ofh;
    my ($efh, $epath) = tempfile('dar-ip-errXXXXXX', TMPDIR => 1); close $efh;
    open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
    open my $olderr, '>&STDERR' or die "dup STDERR: $!";
    open STDOUT, '>:raw', $opath or die "reopen STDOUT: $!";
    open STDERR, '>:raw', $epath or die "reopen STDERR: $!";
    $| = 1;
    my $rc  = eval { BpDrive::run($argv, $opts) };
    my $die = $@;
    open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
    open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
    my $out = slurp($opath) // '';
    my $err = slurp($epath) // '';
    unlink $opath, $epath;
    return ($rc, $out, $err, $die);
}

# Wrap a BpDataRoot:: call so a currently-undefined subroutine (the whole
# module doesn't exist yet) fails as a normal assertion, never a bare die
# that aborts the rest of the file.
sub try_call {
    my ($code) = @_;
    my $r = eval { $code->() };
    return ($r, $@);
}

sub make_pending_bp_dir {
    my ($data, $name) = @_;
    my $bp = "$data/blueprints/$name";
    make_path("$bp/packages");
    write_file("$bp/blueprint.md",
        "# $name\n\n## Package status\n\n"
      . "| pkg | deliverable | depends_on | model | status |\n"
      . "|-----|-------------|------------|-------|--------|\n"
      . "| p1 | thing | - | sonnet | pending |\n");
    write_file("$bp/packages/p1.md",
        "---\npackage: p1\nblueprint: $name\nstatus: pending\n"
      . "model: sonnet\nmax_turns: 80\nwrite_set: $name/p1/\n"
      . "test_paths: $name/p1/\nlast_updated: 2028-01-01T00:00:00Z\n---\n\n# p1\n");
    return $bp;
}

# bp-lifecycle.pl fixture: one archivable ("done") blueprint, same shape as
# lifecycle-reconcile.t's headline "all-done" case (fenced metadata block,
# not frontmatter).
sub lc_blueprint_md {
    my (%o) = @_;
    my $status = $o{status} // 'running';
    my $rows = '';
    for my $p (@{ $o{packages} || [] }) {
        $rows .= "| $p->{pkg} | thing | - | sonnet | $p->{table} |\n";
    }
    return "# Test Blueprint\n\n"
         . "```\nblueprint: $o{name}\ncreated: 2026-01-01\n"
         . "last_updated: 2026-01-01T00:00Z\nstatus: $status\n```\n\n"
         . "## Objective\n\nTest fixture.\n\n## Package status\n\n"
         . "| pkg | deliverable | depends_on | model | status |\n"
         . "|-----|-------------|------------|-------|--------|\n$rows"
         . "\n## Harvest log\n\n## Incidents\n\n";
}

sub lc_ledger_md {
    my (%o) = @_;
    return "---\npackage: $o{pkg}\nblueprint: $o{blueprint}\nstatus: $o{status}\n"
         . "last_updated: 2026-01-01T00:00Z\n---\n\n# Package $o{pkg}\n\n## Next action\n\nNone.\n";
}

sub make_lc_blueprint {
    my ($root, $name, %o) = @_;
    my $dir = "$root/blueprints/$name";
    make_path("$dir/packages");
    my @pkgs = @{ $o{packages} || [] };
    write_file("$dir/blueprint.md",
        lc_blueprint_md(name => $name, status => $o{status} // 'running', packages => \@pkgs));
    for my $p (@pkgs) {
        write_file("$dir/packages/$p->{pkg}.md",
            lc_ledger_md(pkg => $p->{pkg}, blueprint => $name, status => $p->{ledger}));
    }
    return $dir;
}

sub git_toplevel_for {
    my ($cwd) = @_;
    local $ENV{GIT_CEILING_DIRECTORIES} = $R;
    my ($ofh, $opath) = tempfile('dar-gitXXXXXX', TMPDIR => 1); close $ofh;
    my $devnull = File::Spec->devnull;
    my $rc = system("git -C \"$cwd\" rev-parse --show-toplevel > \"$opath\" 2>$devnull");
    my $top = slurp($opath) // '';
    unlink $opath;
    chomp $top;
    return ($rc == 0 && length $top) ? $top : undef;
}

my $USAGE_RE = qr/usage:\s*bp-drive-next\.pl/;

# ═══════════════════════════════════════════════════════════════════════
# AC1 — subprocess: unknown --data-dir on `next` (bug 0f1e's literal repro)
# ═══════════════════════════════════════════════════════════════════════
{
    my $F1 = tempdir(CLEANUP => 1); $F1 =~ s{\\}{/}g;
    make_pending_bp_dir($F1, 'B');
    my $before = snapshot_tree($F1);

    my ($rc, $out, $err) = run_script_subprocess(
        script => $DRIVE_SCRIPT,
        args   => ['next', '--scope', 'B', '--data-dir', 'R/x'],
        cwd    => $R,
        env    => { CCPRAXIS_DATA_DIR => $F1 },
    );
    is($rc, 2, 'AC1: unknown --data-dir on next exits 2');
    my ($line1) = split /\n/, $err;
    like($line1 // '', qr/^bp-drive-next next: unknown option '--data-dir'$/,
        'AC1: STDERR line 1 names --data-dir');
    like($err, $USAGE_RE, 'AC1: STDERR carries the usage block');
    is($out, '', 'AC1: STDOUT is empty');
    is_deeply(snapshot_tree($F1), $before, 'AC1: tree under the fixture data dir is unchanged');
}

# ═══════════════════════════════════════════════════════════════════════
# AC2 — in-process: every unknown-option shape on `next`
# ═══════════════════════════════════════════════════════════════════════
{
    my @cases = (
        { argv => ['next', '--bogus'],                              offender => '--bogus' },
        { argv => ['next', '--scope=B'],                             offender => '--scope=B' },
        { argv => ['next', '--help'],                                offender => '--help' },
        { argv => ['next', '--scope', '--data-dir', 'X'],            offender => '--data-dir' },
    );
    for my $c (@cases) {
        my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;
        make_pending_bp_dir($F, 'B');
        my $before = snapshot_tree($F);
        my ($rc, $out, $err) = capture_inproc($c->{argv}, { data_dir => $F });
        is($rc, 2, "AC2: @{$c->{argv}} returns 2");
        my $q = quotemeta($c->{offender});
        like($err, qr/unknown option '$q'/, "AC2: STDERR names offender $c->{offender}");
        is_deeply(snapshot_tree($F), $before, "AC2: fixture unchanged for @{$c->{argv}}");
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC3 — record-order rejects dash arguments
# ═══════════════════════════════════════════════════════════════════════
{
    for my $argv (['record-order', 'bp-a', '--force'], ['record-order', '--order', 'bp-a']) {
        my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;
        make_pending_bp_dir($F, 'bp-a');
        my ($rc, $out, $err) = capture_inproc($argv, { data_dir => $F });
        is($rc, 2, "AC3: @$argv returns 2");
        like($err, qr/unknown option '-/, "AC3: STDERR names a dash element for @$argv");
        ok(!-e "$F/.drive-solo/order.json", "AC3: no order.json written for @$argv");
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC4 — park rejects dash arguments (blueprint name OR reason word)
# ═══════════════════════════════════════════════════════════════════════
{
    for my $argv (['park', 'bp-a', '--why', 'stale'], ['park', '--bp', 'bp-a']) {
        my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;
        make_pending_bp_dir($F, 'bp-a');
        my ($rc, $out, $err) = capture_inproc($argv, { data_dir => $F });
        is($rc, 2, "AC4: @$argv returns 2");
        ok(!-e "$F/.drive-solo/parks.json", "AC4: no parks.json for @$argv");
        ok(!-e "$F/.drive-solo/run.md",     "AC4: no run.md for @$argv");
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC5 — rejection precedes root resolution
# ═══════════════════════════════════════════════════════════════════════
{
    my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;   # deliberately NO blueprints/
    my ($rc, $out, $err) = capture_inproc(['next', '--bogus'], { data_dir => $F });
    like($err, qr/unknown option/, 'AC5: unknown option fires even over a mis-resolved root');
    unlike($err, qr/no blueprints\//, 'AC5: ...and the fail-loud message never fires alongside it');
}
{
    my $before = snapshot_tree($R);
    my ($rc, $out, $err) = run_script_subprocess(
        script => $DRIVE_SCRIPT,
        args   => ['--data-dir', 'X', 'next'],
        cwd    => $R,
    );
    is($rc, 2, 'AC5: a leading flag is an unknown SUBCOMMAND, exit 2');
    like($err, qr/unknown subcommand '--data-dir'/, 'AC5: STDERR names the leading flag');
    is_deeply(snapshot_tree($R), $before, 'AC5: tree under R is unchanged');
}

# ═══════════════════════════════════════════════════════════════════════
# AC6 — bp-lifecycle.pl rejects unknown/abbreviated options
# ═══════════════════════════════════════════════════════════════════════
{
    my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;
    make_lc_blueprint($F, 'B', status => 'running', packages => [ { pkg => '01-a', ledger => 'done', table => 'done' } ]);
    my $before = snapshot_tree($F);

    my @cases = (
        { args => ['reconcile', '--all', '--data-dir', $F, '--bogus'],                    name_re => qr/bogus/ },
        { args => ['reconcile', '--blueprint', 'B', '--data-dir', $F, '--scope', 'all'],  name_re => qr/scope/ },
        { args => ['reconcile', '--all', '--data', $F],                                   name_re => qr/data/ },
    );
    for my $c (@cases) {
        my ($rc, $out, $err) = run_script_subprocess(script => $LIFECYCLE_SCRIPT, args => $c->{args}, cwd => $R);
        is($rc, 2, "AC6: @{$c->{args}} exits 2");
        like($err, qr/usage:\s*bp-lifecycle\.pl/, "AC6: @{$c->{args}} STDERR carries usage:");
        like($err, $c->{name_re}, "AC6: @{$c->{args}} STDERR names the offending option");
    }
    ok(-d "$F/blueprints/B", 'AC6: F/blueprints/B still in place');
    ok(!-d "$F/blueprints/_archive", 'AC6: no _archive/ materialized');
    is_deeply(snapshot_tree($F), $before, 'AC6: tree under F is unchanged');
}

# ═══════════════════════════════════════════════════════════════════════
# AC7 — bp-lifecycle.pl usage errors now exit 2, not 1
# ═══════════════════════════════════════════════════════════════════════
{
    my ($rc, $out, $err) = run_script_subprocess(script => $LIFECYCLE_SCRIPT, args => [], cwd => $R);
    is($rc, 2, 'AC7: no arguments exits 2 (was 1)');
}
{
    my ($rc, $out, $err) = run_script_subprocess(script => $LIFECYCLE_SCRIPT, args => ['frob'], cwd => $R);
    is($rc, 2, 'AC7: an unknown verb exits 2 (was 1)');
}

# ═══════════════════════════════════════════════════════════════════════
# AC8 — nested layout: the walk never adopts HOME/TMP/sentinel from deep in TMP
# ═══════════════════════════════════════════════════════════════════════
{
    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    delete local $ENV{CLAUDE_PROJECT_DIR};
    my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => "$T/probe/deep", git => sub { undef }) });
    ok(!$die, 'AC8: resolve() does not die') or diag($die);
  SKIP: {
        skip 'BpDataRoot::resolve unavailable', 4 unless ref $res eq 'HASH';
        is($res->{source}, 'cwd', 'AC8: source is cwd (nested TMP-under-HOME never adopts an ancestor)');
        isnt($res->{data_dir}, "$H/.ccpraxis-local-data", 'AC8: data_dir is not HOME\'s');
        isnt($res->{data_dir}, "$T/.ccpraxis-local-data", 'AC8: data_dir is not TMP\'s');
        isnt($res->{data_dir}, "$R/.ccpraxis-local-data", 'AC8: data_dir is not the sentinel\'s');
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC9 — sibling layout: TMP beside HOME, in isolation
# ═══════════════════════════════════════════════════════════════════════
{
    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    delete local $ENV{CLAUDE_PROJECT_DIR};
    # Spec §4: "Set ... TMP/TEMP/TMPDIR to the fake TMP under test." AC9's
    # fake TMP under test is T2, the sibling layout -- NOT the file-wide $T.
    # Without this, T2 is not in the stop set S at all, and the sibling case
    # is exercised only by the off-spec "any dir named tmp/temp is a stop"
    # rule (review must-fix 2), never by Decision 11(12)'s real TMP-env
    # definition.
    local $ENV{TMP}    = $T2;
    local $ENV{TEMP}   = $T2;
    local $ENV{TMPDIR} = $T2;
    my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => "$T2/probe", git => sub { undef }) });
    ok(!$die, 'AC9: resolve() does not die') or diag($die);
  SKIP: {
        skip 'BpDataRoot::resolve unavailable', 3 unless ref $res eq 'HASH';
        is($res->{source}, 'cwd', 'AC9: source is cwd');
        isnt($res->{data_dir}, "$T2/.ccpraxis-local-data", 'AC9: data_dir is not T2\'s');
        isnt($res->{data_dir}, "$R/.ccpraxis-local-data", 'AC9: data_dir is not the sentinel\'s');
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC10 — script level: the bug's exact repro, fails loud, writes nothing
# ═══════════════════════════════════════════════════════════════════════
{
    my $cwd = "$T/probe/deep";
    my $escapes = git_toplevel_for($cwd);
  SKIP: {
        skip "git -C $cwd rev-parse --show-toplevel still reports a toplevel ($escapes)", 5 if $escapes;
        my $before = snapshot_tree($R);
        my ($rc, $out, $err) = run_script_subprocess(
            script => $DRIVE_SCRIPT,
            args   => ['next', '--scope', 'all'],
            cwd    => $cwd,
            env    => {
                BP_PROJECT_ROOT       => undef,
                CCPRAXIS_DATA_DIR     => undef,
                CLAUDE_PROJECT_DIR    => undef,
                GIT_CEILING_DIRECTORIES => $R,
            },
        );
        is($rc, 2, 'AC10: exits 2');
        like($err, qr/no blueprints\//, 'AC10: STDERR names the missing blueprints/');
        like($err, qr/CCPRAXIS_DATA_DIR=/, 'AC10: STDERR names CCPRAXIS_DATA_DIR=');
        unlike($err, qr/--data-dir/, 'AC10: STDERR never mentions --data-dir');
        is($out, '', 'AC10: STDOUT is empty');
        my @drive_solo = find_named_dirs($R, '.drive-solo');
        is(scalar(@drive_solo), 0, 'AC10: no .drive-solo/ exists anywhere under R');
        is_deeply(snapshot_tree($R), $before, 'AC10: tree under R is unchanged');
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC11 — same bug shape hits bp-lifecycle.pl too
# ═══════════════════════════════════════════════════════════════════════
{
    my $cwd = "$T/probe/deep";
    my $escapes = git_toplevel_for($cwd);
  SKIP: {
        skip "git -C $cwd rev-parse --show-toplevel still reports a toplevel ($escapes)", 2 if $escapes;
        my $before = snapshot_tree($R);
        my ($rc, $out, $err) = run_script_subprocess(
            script => $LIFECYCLE_SCRIPT,
            args   => ['reconcile', '--all', '--no-archive'],
            cwd    => $cwd,
            env    => {
                BP_PROJECT_ROOT       => undef,
                CCPRAXIS_DATA_DIR     => undef,
                CLAUDE_PROJECT_DIR    => undef,
                GIT_CEILING_DIRECTORIES => $R,
            },
        );
        isnt($rc, 0, 'AC11: bp-lifecycle.pl also fails loud rather than adopting HOME');
        is_deeply(snapshot_tree($R), $before, 'AC11: tree under R is unchanged');
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC12 — cwd == HOME and cwd == TMP are both adopted (B15)
# ═══════════════════════════════════════════════════════════════════════
{
    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    delete local $ENV{CLAUDE_PROJECT_DIR};
    my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => $H, git => sub { undef }) });
    ok(!$die, 'AC12(H): resolve() does not die') or diag($die);
  SKIP: {
        skip 'BpDataRoot::resolve/same_path unavailable', 3 unless ref $res eq 'HASH';
        is($res->{source}, 'walk-up', 'AC12(H): source is walk-up');
        my ($sp1) = try_call(sub { BpDataRoot::same_path($res->{project_root}, $H) });
        ok($sp1, 'AC12(H): project_root same_path H');
        my ($sp2) = try_call(sub { BpDataRoot::same_path($res->{data_dir}, "$H/.ccpraxis-local-data") });
        ok($sp2, 'AC12(H): data_dir same_path H/.ccpraxis-local-data');
    }
}
{
    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    delete local $ENV{CLAUDE_PROJECT_DIR};
    my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => $T, git => sub { undef }) });
    ok(!$die, 'AC12(T/B15): resolve() does not die') or diag($die);
  SKIP: {
        skip 'BpDataRoot::resolve/same_path unavailable', 3 unless ref $res eq 'HASH';
        is($res->{source}, 'walk-up', 'AC12(T/B15): source is walk-up');
        my ($sp1) = try_call(sub { BpDataRoot::same_path($res->{project_root}, $T) });
        ok($sp1, 'AC12(T/B15): project_root same_path T');
        my ($sp2) = try_call(sub { BpDataRoot::same_path($res->{data_dir}, "$T/.ccpraxis-local-data") });
        ok($sp2, 'AC12(T/B15): data_dir same_path T/.ccpraxis-local-data');
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC13 — a project strictly below HOME is found, from itself or a descendant
# ═══════════════════════════════════════════════════════════════════════
{
    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    delete local $ENV{CLAUDE_PROJECT_DIR};
    make_path("$H/proj/.ccpraxis-local-data/blueprints/proj-audited-bp/packages");
    for my $cwd ("$H/proj/src/deep", "$H/proj") {
        my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => $cwd, git => sub { undef }) });
        ok(!$die, "AC13($cwd): resolve() does not die") or diag($die);
      SKIP: {
            skip 'BpDataRoot::resolve/same_path unavailable', 2 unless ref $res eq 'HASH';
            is($res->{source}, 'walk-up', "AC13($cwd): source is walk-up");
            my ($sp) = try_call(sub { BpDataRoot::same_path($res->{project_root}, "$H/proj") });
            ok($sp, "AC13($cwd): project_root same_path H/proj");
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC14 — a cwd below HOME with no project of its own does NOT adopt HOME
# ═══════════════════════════════════════════════════════════════════════
{
    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    delete local $ENV{CLAUDE_PROJECT_DIR};
    my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => "$H/noproj/deep", git => sub { undef }) });
    ok(!$die, 'AC14: resolve() does not die') or diag($die);
  SKIP: {
        skip 'BpDataRoot::resolve unavailable', 3 unless ref $res eq 'HASH';
        is($res->{source}, 'cwd', 'AC14: source is cwd');
        isnt($res->{data_dir}, "$H/.ccpraxis-local-data", 'AC14: HOME is not adopted');
        isnt($res->{data_dir}, "$R/.ccpraxis-local-data", 'AC14: the sentinel is not adopted');
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC15 — explicit-source priority, from a cwd under TMP
# ═══════════════════════════════════════════════════════════════════════
{
    my $cwd = "$T2/probe";

    # (a) data_dir arg beats CCPRAXIS_DATA_DIR
    {
        local $ENV{CCPRAXIS_DATA_DIR} = "$R/b";
        my @git_calls;
        my ($res, $die) = try_call(sub {
            BpDataRoot::resolve(cwd => $cwd, data_dir => "$R/a", git => sub { push @git_calls, $_[0]; undef });
        });
        ok(!$die, 'AC15(a): resolve() does not die') or diag($die);
      SKIP: {
            skip 'BpDataRoot::resolve unavailable', 2 unless ref $res eq 'HASH';
            is($res->{data_dir}, "$R/a", 'AC15(a): data_dir arg wins');
            is($res->{source}, 'arg', 'AC15(a): source is arg');
        }
        is(scalar(@git_calls), 0, 'AC15(d/a): git seam never called when data_dir arg present');
    }

    # (b) CCPRAXIS_DATA_DIR beats BP_PROJECT_ROOT
    {
        local $ENV{CCPRAXIS_DATA_DIR} = "$R/b";
        local $ENV{BP_PROJECT_ROOT}   = "$R/c";
        my @git_calls;
        my ($res, $die) = try_call(sub {
            BpDataRoot::resolve(cwd => $cwd, git => sub { push @git_calls, $_[0]; undef });
        });
        ok(!$die, 'AC15(b): resolve() does not die') or diag($die);
      SKIP: {
            skip 'BpDataRoot::resolve unavailable', 2 unless ref $res eq 'HASH';
            is($res->{data_dir}, "$R/b", 'AC15(b): CCPRAXIS_DATA_DIR wins over BP_PROJECT_ROOT');
            is($res->{source}, 'env:CCPRAXIS_DATA_DIR', 'AC15(b): source is env:CCPRAXIS_DATA_DIR');
        }
        is(scalar(@git_calls), 0, 'AC15(d/b): git seam never called when CCPRAXIS_DATA_DIR present');
    }

    # (c) BP_PROJECT_ROOT alone: verbatim, no stop-rule tolerance for explicit env
    {
        delete local $ENV{CCPRAXIS_DATA_DIR};
        local $ENV{BP_PROJECT_ROOT} = $H;
        my @git_calls;
        my ($res, $die) = try_call(sub {
            BpDataRoot::resolve(cwd => $cwd, git => sub { push @git_calls, $_[0]; undef });
        });
        ok(!$die, 'AC15(c): resolve() does not die') or diag($die);
      SKIP: {
            skip 'BpDataRoot::resolve unavailable', 3 unless ref $res eq 'HASH';
            is($res->{project_root}, $H, 'AC15(c): project_root eq H verbatim');
            is($res->{data_dir}, "$H/.ccpraxis-local-data", 'AC15(c): data_dir eq H/.ccpraxis-local-data');
            is($res->{source}, 'env:BP_PROJECT_ROOT', 'AC15(c): source is env:BP_PROJECT_ROOT');
        }
        is(scalar(@git_calls), 0, 'AC15(d/c): git seam never called when BP_PROJECT_ROOT present');
    }

    # (e) with no env at all, an existing git answer outranks the walk-up
    {
        delete local $ENV{CCPRAXIS_DATA_DIR};
        delete local $ENV{BP_PROJECT_ROOT};
        my ($res, $die) = try_call(sub {
            BpDataRoot::resolve(cwd => "$H/proj/src", git => sub { "$R/gitroot" });
        });
        ok(!$die, 'AC15(e): resolve() does not die') or diag($die);
      SKIP: {
            skip 'BpDataRoot::resolve unavailable', 2 unless ref $res eq 'HASH';
            is($res->{source}, 'git', 'AC15(e): source is git');
            is($res->{project_root}, "$R/gitroot", 'AC15(e): project_root eq the git answer');
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC16 — same_path table
# ═══════════════════════════════════════════════════════════════════════
{
    my @win_true = (
        ['C:/Users/X/Temp',            'c:\\users\\x\\temp\\'],
        ['/c/Users/X',                 'C:/Users/X'],
        ['C:/Users/ANDR~1/AppData',    'C:/Users/André/AppData'],
        ['C:/a/./b/../c',              'C:/a/c'],
    );
    my @win_false = (
        ['C:/Users/ANDR~1', 'C:/Users/Bob'],
        ['C:/a',            'C:/a/b'],
        ['C:/Users/André',  'D:/Users/André'],
    );
    if ($IS_WIN) {
        for my $p (@win_true) {
            my ($r, $die) = try_call(sub { BpDataRoot::same_path(@$p) });
            ok(!$die, "AC16(win-true @$p): same_path does not die") or diag($die);
            ok($r, "AC16(win-true): '$p->[0]' same_path '$p->[1]'") unless $die;
        }
        for my $p (@win_false) {
            my ($r, $die) = try_call(sub { BpDataRoot::same_path(@$p) });
            ok(!$die, "AC16(win-false @$p): same_path does not die") or diag($die);
            ok(!$r, "AC16(win-false): '$p->[0]' NOT same_path '$p->[1]'") unless $die;
        }
    } else {
        SKIP: { skip 'Windows-only path forms (Decision 11(12))', 1; }
        my ($r1, $d1) = try_call(sub { BpDataRoot::same_path('/home/A', '/home/a') });
        ok(!$d1, 'AC16(posix): same_path does not die') or diag($d1);
        ok(!$r1, 'AC16(posix): /home/A NOT same_path /home/a (case-sensitive)') unless $d1;
        my ($r2, $d2) = try_call(sub { BpDataRoot::same_path('/a/./b/..', '/a') });
        ok(!$d2, 'AC16(posix): same_path does not die') or diag($d2);
        ok($r2, 'AC16(posix): /a/./b/.. same_path /a (lexical collapse)') unless $d2;
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC17 — Windows-only stop-dir spelling tolerance (nested layout)
# ═══════════════════════════════════════════════════════════════════════
SKIP: {
    skip 'Windows-only path forms (Decision 11(12))', 4 unless $IS_WIN;

    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    delete local $ENV{CLAUDE_PROJECT_DIR};

    # (a) upper-cased TMP env value
    {
        local $ENV{TMP} = uc($T); local $ENV{TEMP} = uc($T); local $ENV{TMPDIR} = uc($T);
        my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => "$T/probe", git => sub { undef }) });
        ok(!$die, 'AC17(a): resolve() does not die') or diag($die);
        SKIP: { skip 'BpDataRoot::resolve unavailable', 1 unless ref $res eq 'HASH';
            is($res->{source}, 'cwd', 'AC17(a): upper-cased TMP is still recognised as the stop dir');
        }
    }

    # (b) /c/... vs C:/... spelling
    {
        (my $posix_t = $T) =~ s{^([A-Za-z]):/}{/\l$1/};
        local $ENV{TMP} = $posix_t; local $ENV{TEMP} = $posix_t; local $ENV{TMPDIR} = $posix_t;
        my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => "$T/probe", git => sub { undef }) });
        ok(!$die, 'AC17(b): resolve() does not die') or diag($die);
        SKIP: { skip 'BpDataRoot::resolve unavailable', 1 unless ref $res eq 'HASH';
            is($res->{source}, 'cwd', 'AC17(b): /c/... spelling is still recognised as the stop dir');
        }
    }

    # (c) backslash spelling
    {
        (my $back_t = $T) =~ s{/}{\\}g;
        local $ENV{TMP} = $back_t; local $ENV{TEMP} = $back_t; local $ENV{TMPDIR} = $back_t;
        my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => "$T/probe", git => sub { undef }) });
        ok(!$die, 'AC17(c): resolve() does not die') or diag($die);
        SKIP: { skip 'BpDataRoot::resolve unavailable', 1 unless ref $res eq 'HASH';
            is($res->{source}, 'cwd', 'AC17(c): backslash spelling is still recognised as the stop dir');
        }
    }

    # (d) 8.3 tolerance, only if the HOST's raw TMP/TEMP already has an 8.3 segment
    my $raw = defined $RAW_HOST_TMP && length $RAW_HOST_TMP ? $RAW_HOST_TMP
            : defined $RAW_HOST_TEMP && length $RAW_HOST_TEMP ? $RAW_HOST_TEMP
            : undef;
    SKIP: {
        skip 'host temp has no 8.3 segment', 2
            unless defined $raw && $raw =~ /~[0-9]/;
        (my $raw_fwd = $raw) =~ s{\\}{/}g;
        my $eightthree_root = "$raw_fwd/dar-8p3-" . $$;
        make_path("$eightthree_root/.ccpraxis-local-data/blueprints/eightthree-audited-bp/packages")
            or skip 'could not build an 8.3-rooted fixture', 2;
        my $long_cwd = Cwd::abs_path($eightthree_root) // $eightthree_root;
        $long_cwd =~ s{\\}{/}g;
        local $ENV{TMP} = $eightthree_root; local $ENV{TEMP} = $eightthree_root; local $ENV{TMPDIR} = $eightthree_root;
        my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => $long_cwd, git => sub { undef }) });
        ok(!$die, 'AC17(d): resolve() does not die') or diag($die);
        # $eightthree_root itself holds .ccpraxis-local-data (it IS the TMP
        # root under test, not a subdirectory below it), and $long_cwd is
        # that SAME directory, only spelled long. Per spec §2.2's normative
        # pseudocode, the "-d '$d/.ccpraxis-local-data'" check on the first
        # iteration (d == start) fires unconditionally and returns d --
        # there is no additional gate asking HOW is_stop(d) matched (lex,
        # real, or 8.3). R2 ("a cwd that IS the temp dir examines itself,
        # adopted if it holds .ccpraxis-local-data") applies regardless of
        # which comparison form recognised the match. So the correct
        # observable here is adoption (source 'walk-up'), never 'cwd' --
        # asserting 'cwd' would only pass an implementation that adds an
        # off-spec "lexical-match-only" self-adoption gate (review
        # should-fix 1), which this AC must not depend on.
      SKIP: { skip 'BpDataRoot::resolve unavailable', 2 unless ref $res eq 'HASH';
            is($res->{source}, 'walk-up',
                'AC17(d): 8.3 short/long TMP spellings still let the cwd adopt its own data root (R2)');
            my ($sp) = try_call(sub { BpDataRoot::same_path($res->{project_root}, $eightthree_root) });
            ok($sp, 'AC17(d): project_root same_path the 8.3 TMP root, whichever spelling it is returned in');
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# M1 regression (review must-fix 1) — a drive-letter-form cwd with no data
# root anywhere up to the drive root must never fall back to the PROCESS
# cwd. On a perl whose File::Basename::dirname applies Unix rules to a
# "C:/..."-form path (measured: $^O eq 'cygwin' on this host), dirname
# climbs "C:/x" -> "C:" -> "." , and "." resolves against getcwd(), not
# against the cwd ARGUMENT. That silently adopts whatever data root happens
# to sit under the process's real cwd -- the bug class this package exists
# to close, restated at the walk-up's own root step.
# ═══════════════════════════════════════════════════════════════════════
SKIP: {
    my $N = 5;
    skip 'drive-letter cwd form is Windows-only', $N unless $IS_WIN;

    (my $drive_R = $R) =~ s{\\}{/}g;
    if ($drive_R =~ m{^/([A-Za-z])(/.*)?$}) {
        $drive_R = uc($1) . ':' . (defined $2 ? $2 : '/');
    } elsif ($drive_R !~ m{^[A-Za-z]:/}) {
        # $R is neither already "X:/..." nor the simple "/x/..." single-letter
        # mount form (for example it is "/tmp/..."). Fall back to cygpath -w,
        # which knows this host's actual mount table, to get a real
        # drive-letter spelling of the SAME fixture directory.
        my $native = eval {
            open(my $fh, '-|', 'cygpath', '-w', $drive_R) or return undef;
            my $line = <$fh>;
            close $fh;
            chomp $line if defined $line;
            (defined $line && length $line) ? $line : undef;
        };
        if (defined $native) {
            $native =~ s{\\}{/}g;
            $drive_R = $native;
        }
    }
    skip 'could not derive a drive-letter form for the fixture root', $N
        unless $drive_R =~ m{^[A-Za-z]:/};

    # A decoy "process cwd", distinct from the resolve() cwd argument, so an
    # accidental fall-through to getcwd() is observable rather than
    # coincidentally correct.
    my $fakeproc = "$R/m1-fakeproc";
    make_path("$fakeproc/.ccpraxis-local-data/blueprints/decoy-bp/packages");
    my $saved_cwd = getcwd();
    unless (chdir($fakeproc)) {
        skip "could not chdir to $fakeproc: $!", $N;
    }

    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    delete local $ENV{CLAUDE_PROJECT_DIR};

    # A path under the real fixture root, in drive-letter spelling, that has
    # no .ccpraxis-local-data anywhere between it and the drive root -- EXCEPT
    # for $R itself, which line 48's file-scope sentinel deliberately seeds
    # with a .ccpraxis-local-data (to catch an escaping walk elsewhere in this
    # file). $R sits strictly above $target, so without a declared stop at
    # $R the walk-up would legitimately climb into it and adopt the sentinel
    # -- not a "rootless" outcome at all, just this fixture's own sentinel
    # getting in the way of THIS particular regression. Per spec 2.2's walk
    # algorithm, a stop dir strictly above the cwd is never examined ("d
    # itself is NOT examined"), so declaring $R (in the SAME drive-letter
    # spelling as the cwd argument) as a temp stop for the duration of this
    # block makes the walk halt at $R without looking inside it, restoring
    # the "no root found" contract this regression is actually about.
    local $ENV{TMP}    = $drive_R;
    local $ENV{TEMP}   = $drive_R;
    local $ENV{TMPDIR} = $drive_R;

    my $target = "$drive_R/m1-zz-nope/deep";
    my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => $target, git => sub { undef }) });
    chdir($saved_cwd) or diag("could not chdir back to $saved_cwd: $!");

    ok(!$die, 'M1 regression: resolve() does not die on a drive-letter-form cwd') or diag($die);
  SKIP: {
        skip 'BpDataRoot::resolve unavailable', 4 unless ref $res eq 'HASH';
        isnt($res->{project_root} // '', '.',
            'M1 regression: project_root is never the bare "." (a process-cwd escape)');
        isnt($res->{source}, 'walk-up',
            'M1 regression: a rootless drive-letter cwd never reports an adopted walk-up root');
        my ($sp) = try_call(sub {
            BpDataRoot::same_path($res->{data_dir} // '', "$fakeproc/.ccpraxis-local-data");
        });
        ok(!$sp, 'M1 regression: the decoy PROCESS-cwd data root is never adopted');
      SKIP: {
            skip 'no real host HOME/USERPROFILE to compare against', 1
                unless defined $RAW_HOST_HOME && length $RAW_HOST_HOME;
            my ($real_sp) = try_call(sub {
                BpDataRoot::same_path($res->{data_dir} // '', "$RAW_HOST_HOME/.ccpraxis-local-data");
            });
            ok(!$real_sp,
                'M1 regression: the result never names the REAL home\'s data dir');
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# S2 regression (review should-fix 2) — under MSYS2_ARG_CONV_EXCL=* (as both
# scripts set process-wide), a POSIX cwd that is NOT of the "/x/..." shape
# (for example "/tmp/...") must still let the default git step find a real
# git toplevel. The module translates only "/x/rest" -> "X:/rest"; other
# POSIX-absolute forms reach native git.exe untranslated and get resolved
# against the drive root instead. This regression builds its OWN git repo
# inside this file's fixture tree (never a repo outside the fixtures).
# ═══════════════════════════════════════════════════════════════════════
SKIP: {
    my $N = 2;
    skip 'MSYS2 argv translation only applies under msys/cygwin perl', $N
        unless $^O =~ /^(msys|cygwin)$/;

    my $git_version = eval {
        open(my $fh, '-|', 'git', '--version') or return undef;
        my $line = <$fh>;
        close $fh;
        $line;
    };
    skip 'git is not available on PATH', $N unless defined $git_version && length $git_version;

    my $posix_root = "/tmp/dar-s2-$$-" . time();
    my $made = eval { make_path("$posix_root/sub"); 1 };
    skip "could not create a real directory at $posix_root (no /tmp mount on this host)", $N
        unless $made && -d "$posix_root/sub";

    # bp-drive-next.pl's own BEGIN block sets MSYS2_ARG_CONV_EXCL=* process-wide
    # the moment it is require'd (already true for the rest of this file), so
    # git init's OWN "-C $posix_root" is exposed to the exact translation gap
    # under test. Hand-translate for the init call only -- the point of this
    # regression is resolve()'s handling below, not this fixture-building step.
    my $native_root = eval {
        open(my $fh, '-|', 'cygpath', '-w', $posix_root) or return undef;
        my $line = <$fh>;
        close $fh;
        chomp $line if defined $line;
        (defined $line && length $line) ? $line : undef;
    };
    skip 'could not translate the fixture path for git init (no cygpath)', $N
        unless defined $native_root;

    my $init_rc = system('git', '-C', $native_root, 'init', '-q');
    my $init_ok = (($init_rc == -1 ? -1 : $init_rc >> 8) == 0) && -d "$posix_root/.git";
    unless ($init_ok) {
        eval { remove_tree($posix_root) };
        skip "git init failed under $posix_root", $N;
    }

    local $ENV{MSYS2_ARG_CONV_EXCL} = '*';
    local $ENV{GIT_CEILING_DIRECTORIES} = $R;
    delete local $ENV{CCPRAXIS_DATA_DIR};
    delete local $ENV{BP_PROJECT_ROOT};
    delete local $ENV{CLAUDE_PROJECT_DIR};

    my ($res, $die) = try_call(sub { BpDataRoot::resolve(cwd => "$posix_root/sub") });
    eval { remove_tree($posix_root) };

    ok(!$die, 'S2 regression: resolve() does not die under MSYS2_ARG_CONV_EXCL=*') or diag($die);
  SKIP: {
        skip 'BpDataRoot::resolve unavailable', 1 unless ref $res eq 'HASH';
        is($res->{source}, 'git',
            'S2 regression: a /tmp-form cwd still reaches native git.exe under MSYS2_ARG_CONV_EXCL=*');
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC18 — the replacement fail-loud message, byte-pinned
# ═══════════════════════════════════════════════════════════════════════
{
    my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;   # no blueprints/
    my ($rc, $out, $err) = capture_inproc(['next', '--scope', 'all'], { data_dir => $F });
    is($rc, 2, 'AC18: exits 2');
    my ($line1) = split /\n/, $err;
    is($line1, 'bp-drive-next: no blueprints/ under the resolved data dir:',
        'AC18: STDERR line 1 is byte-equal to the pinned text');
    like($err, qr/Set CCPRAXIS_DATA_DIR=<project>\/\.ccpraxis-local-data and retry\./,
        'AC18: STDERR contains the pinned retry line');
    unlike($err, qr/--data-dir/, 'AC18: STDERR never mentions --data-dir');
}

# ═══════════════════════════════════════════════════════════════════════
# AC19 — resolve()/project_root()/data_dir()/same_path() are side-effect free
# ═══════════════════════════════════════════════════════════════════════
{
    for my $cwd ("$T/nonexistent/x", "$T/probe") {
        delete local $ENV{CCPRAXIS_DATA_DIR};
        delete local $ENV{BP_PROJECT_ROOT};

        my $cwd_before = getcwd();
        my %env_before = %ENV;
        my $tree_before = snapshot_tree($R);

        my ($ofh, $opath) = tempfile('dar-se-outXXXXXX', TMPDIR => 1); close $ofh;
        my ($efh, $epath) = tempfile('dar-se-errXXXXXX', TMPDIR => 1); close $efh;
        open my $oldout, '>&STDOUT' or die "dup STDOUT: $!";
        open my $olderr, '>&STDERR' or die "dup STDERR: $!";
        open STDOUT, '>:raw', $opath or die "reopen STDOUT: $!";
        open STDERR, '>:raw', $epath or die "reopen STDERR: $!";
        my $res = eval { BpDataRoot::resolve(cwd => $cwd) };
        my $die = $@;
        open STDOUT, '>&', $oldout or die "restore STDOUT: $!"; close $oldout;
        open STDERR, '>&', $olderr or die "restore STDERR: $!"; close $olderr;
        my $sout = slurp($opath) // ''; my $serr = slurp($epath) // '';
        unlink $opath, $epath;

        ok(!$die, "AC19($cwd): resolve() does not throw") or diag($die);
        is(getcwd(), $cwd_before, "AC19($cwd): getcwd() unchanged");
        is_deeply(\%ENV, \%env_before, "AC19($cwd): %ENV unchanged");
        is_deeply(snapshot_tree($R), $tree_before, "AC19($cwd): tree under R unchanged");
        is($sout, '', "AC19($cwd): STDOUT is empty");
        is($serr, '', "AC19($cwd): STDERR is empty");
    }
}

# ═══════════════════════════════════════════════════════════════════════
# AC20 — the walk-up is written ONCE, in BpDataRoot.pm, and both scripts use it
# ═══════════════════════════════════════════════════════════════════════
{
    my $drive_src = slurp($DRIVE_SCRIPT) // '';
    my $lc_src    = slurp($LIFECYCLE_SCRIPT) // '';

    # A plain ok()/regex assertion, never like()/unlike() on the whole
    # ~900-line file: Test::More dumps the FULL string it compared on a
    # like/unlike failure, which turns one red assertion into a
    # multi-thousand-line diagnostic. On failure we diag() only the matched
    # text (or its absence), never the whole source.
    my $src_has = sub {
        my ($src, $re, $label, %o) = @_;
        my $want = exists $o{want} ? $o{want} : 1;
        my $found = ($src =~ $re) ? 1 : 0;
        my $pass = $want ? $found : !$found;
        ok($pass, $label)
            or diag($found ? "matched: '$&'" : 'pattern not found in source');
    };

    $src_has->($drive_src, qr/-d\s*"\$d\/\.ccpraxis-local-data"/,
        'AC20: bp-drive-next.pl no longer contains its own .ccpraxis-local-data walk check', want => 0);
    $src_has->($lc_src, qr/-d\s*"\$d\/\.ccpraxis-local-data"/,
        'AC20: bp-lifecycle.pl no longer contains its own .ccpraxis-local-data walk check', want => 0);
    $src_has->($lc_src, qr/File::Spec->updir/,
        'AC20: bp-lifecycle.pl no longer ascends via File::Spec->updir', want => 0);

    $src_has->($drive_src, qr/BpDataRoot::/, 'AC20: bp-drive-next.pl calls BpDataRoot::');
    $src_has->($lc_src, qr/BpDataRoot::/, 'AC20: bp-lifecycle.pl calls BpDataRoot::');

    $src_has->($drive_src, qr/require\s+"\$DIR\/BpDataRoot\.pm"/,
        'AC20: bp-drive-next.pl requires BpDataRoot.pm from $DIR');
    $src_has->($lc_src, qr/require\s+"\$SCRIPT_DIR\/BpDataRoot\.pm"/,
        'AC20: bp-lifecycle.pl requires BpDataRoot.pm from $SCRIPT_DIR');

    for my $f ($DRIVE_SCRIPT, $LIFECYCLE_SCRIPT, $DATAROOT_MODULE) {
        my $sysrc = system($^X, '-c', $f);
        is(($sysrc == -1 ? -1 : $sysrc >> 8), 0, "AC20: perl -c passes for $f");
    }
}

# The five sibling suites (drive-next.t, drive-next-archives-finished.t, empty-scope-is-settled.t,
# lifecycle-derived.t, lifecycle-reconcile.t) stay green through this package's own test_paths
# (tooling-fixes 06); no assertion runs them here.

# ═══════════════════════════════════════════════════════════════════════
# AC22 — double-load safety
# ═══════════════════════════════════════════════════════════════════════
{
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, $_[0] };
    my $second_spelling = "$Bin/../../scripts/./BpDataRoot.pm";
    my $ok = eval { require $second_spelling; 1 };
    my $die = $@;
    ok($ok, 'AC22: a second require of BpDataRoot.pm under a different spelling does not die')
        or diag($die);
    is(scalar(@warnings), 0, 'AC22: the second require emits no warning (no "Subroutine ... redefined")')
        or diag(join("\n", @warnings));
}

# ═══════════════════════════════════════════════════════════════════════
# B20 (08-blueprint-parks, AC13, DC1/DC3) — park's full refusal list: exit 2,
# nothing written, in every one of these shapes. Written blind to the
# rewritten park's implementation, directly from spec §3 observable B20.
# ═══════════════════════════════════════════════════════════════════════
sub append_fence {
    my ($bp_dir, $status) = @_;
    open my $fh, '>>:raw', "$bp_dir/blueprint.md" or die "append fence: $!";
    print $fh "\n```\nstatus: $status\n```\n";
    close $fh;
}

{
    my @cases = (
        { label => 'missing reason',       argv => ['park', 'bp-a'] },
        { label => 'empty reason',         argv => ['park', 'bp-a', ''] },
        { label => "reason with '#'",      argv => ['park', 'bp-a', 'bad#reason'] },
        { label => "reason with '|'",      argv => ['park', 'bp-a', 'bad|reason'] },
        { label => 'reason with a newline',argv => ['park', 'bp-a', "bad\nreason"] },
        { label => 'reason over 200 bytes',argv => ['park', 'bp-a', ('x' x 201)] },
    );
    for my $c (@cases) {
        my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;
        make_pending_bp_dir($F, 'bp-a');
        my $before = snapshot_tree($F);
        my ($rc, $out, $err) = capture_inproc($c->{argv}, { data_dir => $F });
        is($rc, 2, "B20: $c->{label} exits 2");
        is($out, '', "B20: $c->{label} -- STDOUT empty");
        is_deeply(snapshot_tree($F), $before, "B20: $c->{label} -- tree unchanged, nothing written");
    }
}

{   # a blueprint that is not on disk
    my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;
    make_pending_bp_dir($F, 'bp-a');
    my $before = snapshot_tree($F);
    my ($rc, $out, $err) = capture_inproc(['park', 'ghost-bp', 'reason'], { data_dir => $F });
    is($rc, 2, 'B20: a blueprint not on disk exits 2');
    is_deeply(snapshot_tree($F), $before, 'B20: ...and the tree is unchanged');
}

{   # an archived blueprint
    my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;
    my $bp = make_pending_bp_dir($F, 'bp-a');
    append_fence($bp, 'archived');
    my $before = snapshot_tree($F);
    my ($rc, $out, $err) = capture_inproc(['park', 'bp-a', 'reason'], { data_dir => $F });
    is($rc, 2, 'B20: an archived blueprint exits 2');
    is_deeply(snapshot_tree($F), $before, 'B20: ...and the tree is unchanged (archived fence untouched)');
}

{   # --needs-operator with a data dir that is not <root>/.ccpraxis-local-data
    # (this file's OWN fixture dirs from tempdir() are never named that, so
    # this is the ordinary case, not a special one).
    my $F = tempdir(CLEANUP => 1); $F =~ s{\\}{/}g;
    make_pending_bp_dir($F, 'bp-a');
    my $before = snapshot_tree($F);
    my ($rc, $out, $err) = capture_inproc(['park', 'bp-a', '--needs-operator', 'reason'], { data_dir => $F });
    is($rc, 2, 'B20: --needs-operator over a non-project-shaped data dir exits 2');
    is_deeply(snapshot_tree($F), $before, 'B20: ...and the tree is unchanged (no inbox item, no park)');
}

done_testing();
