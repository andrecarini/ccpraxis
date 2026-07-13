#!/usr/bin/env perl
# T1–T3: beacon list --scope sandbox falls back to the current project's
# local beacon dir when no registry exists (the sandbox condition).
#
# T1: a beacon placed in <tmp>/.ccpraxis-local-data/claude-home/beacons/
#     appears in `list --scope sandbox --format json` output.
#     FAILS against pre-fix code (sandbox_project_dirs() returns () when
#     $REGISTRY_LOCAL absent → no dirs scanned → []).
#     PASSES post-fix (beacon_dir_for_scope('sandbox') added to scan set).
#
# T2: the beacon appears exactly once (no-dup guard).
#
# T3: list --scope sandbox count agrees with count-project for same cwd.

use strict;
use warnings;
use Test::More tests => 8;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec ();
use Cwd qw(getcwd abs_path);
use JSON::PP ();

# ── Locate beacon.pl ────────────────────────────────────────────────────────
use FindBin qw($Bin);
# $Bin = plugins/beacon/tests/t   → go up two levels to plugins/beacon/
my $BEACON_PL = File::Spec->catfile($Bin, '..', '..', 'scripts', 'beacon.pl');
$BEACON_PL = abs_path($BEACON_PL);
ok(-f $BEACON_PL, "beacon.pl found at $BEACON_PL");

# ── Set up temp project dir ─────────────────────────────────────────────────
my $tmpdir = tempdir(CLEANUP => 1);
$tmpdir =~ s/\\/\//g;  # normalise to forward slashes

# Isolate from the REAL host vault/registry. beacon.pl derives
# $VAULT_DIR = "$HOME/.claude/claude-code-vault" and $REGISTRY_LOCAL under it;
# on the host that vault EXISTS, so `list --scope sandbox` would otherwise scan
# the real registry's projects and leak their beacons into this test (making it
# non-deterministic and breaking the list==count agreement post-fix). Point the
# subprocess HOME at an empty temp dir so $VAULT_DIR is absent — which is exactly
# the sandbox condition the fix targets (sandbox_project_dirs() -> () with no
# registry). The local beacon dir (beacon_dir_for_scope('sandbox')) is cwd-based,
# NOT HOME-based, so this isolation does not affect the fallback path under test.
my $fake_home = tempdir(CLEANUP => 1);
$fake_home =~ s/\\/\//g;

# UUID-shaped session id (satisfies beacon.pl's require_sid regex)
my $SID = 'deadbeef-dead-beef-dead-testsid0001';

# Build the beacon record.  Shape mirrors what cmd_light writes (schema 1).
my $now = do {
    use POSIX qw(strftime);
    strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);
};
my $record = {
    session_id        => $SID,
    schema_version    => 1,
    scope             => 'sandbox',
    sandbox_container => undef,
    cwd               => $tmpdir,
    git_root          => undef,
    project_slug      => 'test-project',
    created_at        => $now,
    last_active_at    => $now,
    label             => 'regression-test-beacon',
    summary           => undef,
    tags              => [],
    auto_lit          => JSON::PP::false,
    host_machine      => 'test-host',
};

# Write beacon file
my $beacons_dir = "$tmpdir/.ccpraxis-local-data/claude-home/beacons";
make_path($beacons_dir) or die "Cannot create beacons dir: $!" unless -d $beacons_dir;
my $beacon_file = "$beacons_dir/$SID.json";
{
    open my $fh, '>', $beacon_file or die "Cannot write beacon file: $!";
    print $fh JSON::PP->new->pretty->canonical->encode($record);
    close $fh;
}
ok(-f $beacon_file, "beacon fixture written: $beacon_file");

# ── Helper: run beacon.pl in the temp dir ───────────────────────────────────
sub run_beacon {
    my @args = @_;
    my $saved_cwd = getcwd();

    # Registry isolation (see $fake_home above): the child inherits %ENV, so
    # localise HOME/USERPROFILE to the empty fake home -> $VAULT_DIR absent ->
    # sandbox_project_dirs() returns () (the real sandbox condition).
    local $ENV{HOME}        = $fake_home;
    local $ENV{USERPROFILE} = $fake_home;

    # Portable chdir: use a subshell so beacon.pl's safe_getcwd() sees tempdir
    # as its working directory.  On Windows/Git-Bash we use the shell -c form.
    my $tmpdir_native = $tmpdir;
    $tmpdir_native =~ s{^/([a-zA-Z])/}{$1:/};  # /c/foo → C:/foo if needed

    # Build command string with shell-escaped path and args.
    # Use $^X (same perl interpreter) to avoid PATHEXT resolution issues.
    my $perl = $^X;
    my $args_str = join(' ', map { qq("$_") } @args);
    my $cmd = qq("$perl" "$BEACON_PL" $args_str 2>&1);

    # Change to tmpdir, run, restore.
    chdir($tmpdir_native) or die "Cannot chdir to $tmpdir_native: $!";
    my $out = `$cmd`;
    my $rc  = $? >> 8;
    chdir($saved_cwd) or warn "Cannot restore cwd: $!";

    return ($out, $rc);
}

# ── T1: fallback — beacon appears in JSON output ────────────────────────────
my ($list_out, $list_rc) = run_beacon('list', '--scope', 'sandbox', '--format', 'json');

is($list_rc, 0, 'T1: beacon.pl list --scope sandbox --format json exits 0');

my $decoded = eval { JSON::PP->new->decode($list_out) };
is(ref($decoded), 'ARRAY', 'T1: output is a JSON array');

my @matching = grep { ref($_) eq 'HASH' && ($_->{session_id} // '') eq $SID } @$decoded;
ok(scalar(@matching) >= 1,
    "T1: session_id $SID appears in list output (fallback to local beacon dir). "
    . "Got " . scalar(@$decoded) . " record(s). "
    . "Raw output: $list_out");

# ── T2: exactly once (no-dup guard) ─────────────────────────────────────────
is(scalar(@matching), 1,
    "T2: session_id $SID appears exactly once (no double-listing). "
    . "Got " . scalar(@matching) . " occurrence(s).");

# ── T3: list count agrees with count-project ─────────────────────────────────
# count-project reads <cwd>/.ccpraxis-local-data/claude-home/beacons directly,
# same formula as beacon_dir_for_scope('sandbox').  We compare the count of
# records list returns (for this temp project) against PROJECT_COUNT.
my $list_count = scalar(@$decoded);

my ($count_out, $count_rc) = run_beacon('count-project');
is($count_rc, 0, 'T3: count-project exits 0');

my $project_count;
if ($count_out =~ /^PROJECT_COUNT:\s*(\d+)/m) {
    $project_count = $1 + 0;
} else {
    $project_count = undef;
}

# count-project also adds host-vault beacons attributed to this project,
# but $VAULT_BEACON_DIR won't exist in a clean temp env, so n_host == 0.
# list --scope sandbox returns beacons from the local dir only.
# Both should see exactly 1 beacon.
is($project_count, $list_count,
    "T3: list count ($list_count) agrees with count-project (${\($project_count // 'undef')}).");
