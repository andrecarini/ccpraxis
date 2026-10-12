#!/usr/bin/env perl
# platform: any
# Package 12 (orchestrator-liveness-false-dead), specs/12-orchestrator-liveness-false-dead-spec.md.
#
# Covers DC3, DC5 (section 4, File B) for todo 20261002-125337-de8b0000: a byte-type
# mismatch in Almanac::SessionLive::orchestrator_live -- it concatenates a raw-byte
# root with a utf8-flagged blueprint id -- upgrades the root's raw UTF-8 bytes as
# Latin-1, mangling a non-ASCII path segment ("C3 A9" -> "C3 83 C2 A9" on disk), so a
# held flock silently reads as dead.
#
# Fixture ruling (spec section 4 File B): synthetic and portable, NOT tied to this
# host -- a tempdir suffixed with the literal two-byte UTF-8 "e9accent" sequence
# (0xC3 0xA9, the same bytes as this host's own "Andre-accent" username), built from
# a RAW byte string (no utf8 flag), so the test reproduces the same upgrade bug on
# any host. Deliberately does NOT use fleet-thread.t's $ASCII_TMP_BASE workaround,
# which exists specifically to AVOID this bug in unrelated test files.
#
# WRITTEN AGAINST SPEC ONLY -- orchestrator_live still concatenates raw bytes at the
# time this file is written. Every risky call is wrapped in eval so an exception is a
# caught, reported failure for that assertion, never an abort of the whole file.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp ();
use File::Path qw(make_path);
use File::Spec ();
use Fcntl qw(:flock);
use Encode ();

BEGIN {
    my $dir = "$FindBin::Bin/../../scripts";
    $dir =~ s{\\}{/}g;
    unshift @INC, $dir;
}

my $SL_PM     = "$Bin/../../scripts/Almanac/SessionLive.pm";
my $THREAD_PM = "$Bin/../../scripts/Almanac/Thread.pm";
ok(-f $SL_PM,     'precondition: Almanac/SessionLive.pm exists') or BAIL_OUT('nothing to test');
ok(-f $THREAD_PM, 'precondition: Almanac/Thread.pm exists')      or BAIL_OUT('nothing to test');

sub load_sl     { local $@; eval { require Almanac::SessionLive; 1 } or diag("SessionLive load error: $@") }
sub load_thread { local $@; eval { require Almanac::Thread; 1 } or diag("Thread load error: $@") }
my $SL_LOADS     = load_sl();
my $THREAD_LOADS = load_thread();

# --------------------------------------------------------------------------
# Fixture: a tempdir whose last path segment carries the raw two-byte UTF-8
# sequence for "e9accent" ("Andr\xC3\xA9-liveness"), as a RAW (non-utf8-flagged)
# byte string -- these are plain \xNN escapes in the source, so the resulting
# scalar carries no UTF8 flag, exactly mirroring what Almanac::Store's
# canonical, byte-oriented root looks like on this host.
# --------------------------------------------------------------------------
my $raw_tmp_base = File::Temp::tempdir(DIR => File::Spec->tmpdir, CLEANUP => 1);
my $root = $raw_tmp_base . "/Andr\xC3\xA9-liveness";
make_path($root);

my $bp_flagged = Encode::decode('UTF-8', 'fx');

# =============================================================================
# AC-14 -- preconditions, asserted as `ok` so a non-discriminating fixture is
# visible; the naive-concatenation check proves the fixture reproduces
# de8b0000's mechanism.
# =============================================================================
ok($root =~ /[\x80-\xFF]/, 'AC-14: fixture root contains a non-ASCII byte');
ok(!utf8::is_utf8($root), 'AC-14: fixture root is NOT utf8-flagged (raw bytes)');
ok(-d $root, 'AC-14: fixture root directory exists on disk');
ok(utf8::is_utf8($bp_flagged), 'AC-14: $bp_flagged (Encode::decode of "fx") IS utf8-flagged');

my $marker_dir = "$root/.ccpraxis-local-data/blueprints/fx/runs";
make_path($marker_dir);
my $marker = "$marker_dir/.orchestrator";
{
    open(my $mfh0, '>', $marker) or die "fixture: cannot write $marker: $!";
    print {$mfh0} "$$\n";
    close $mfh0;
}
my $naive = "$root/.ccpraxis-local-data/blueprints/$bp_flagged/runs/.orchestrator";
ok(!-f $naive,
    'AC-14: the NAIVE concatenation (raw-byte root . flagged blueprint) fails to find the marker -- reproduces de8b0000\'s mechanism');
ok(-f $marker, 'AC-14: sanity -- the real marker path does exist on disk');

# =============================================================================
# AC-15 -- orchestrator_live(root raw bytes, blueprint flagged) == 1 while held.
# =============================================================================
SKIP: {
    skip 'AC-15: Almanac::SessionLive not loadable', 1 unless $SL_LOADS;
    open(my $fh, '>', $marker) or die "fixture: cannot write $marker: $!";
    print {$fh} "12345\n";
    flock($fh, LOCK_EX) or die "flock: $!";

    my $v1 = eval { Almanac::SessionLive::orchestrator_live(root => $root, blueprint => $bp_flagged) };
    is($v1, 1,
        'AC-15: orchestrator_live returns 1 while the marker flock is held (raw-byte root, flagged blueprint) -- FAILS ON CURRENT CODE')
        or diag("err: $@");

    # =========================================================================
    # AC-16 -- same marker, still held: both other byte-combinations also give 1.
    # =========================================================================
    my $root_flagged = Encode::decode('UTF-8', $root);
    ok(utf8::is_utf8($root_flagged), 'AC-16 precondition: $root_flagged (Encode::decode of $root) is utf8-flagged');

    my $v2 = eval { Almanac::SessionLive::orchestrator_live(root => $root_flagged, blueprint => 'fx') };
    is($v2, 1, 'AC-16: flagged root + plain blueprint -> 1 while held') or diag("err: $@");

    my $v3 = eval { Almanac::SessionLive::orchestrator_live(root => $root_flagged, blueprint => $bp_flagged) };
    is($v3, 1, 'AC-16: both flagged -> 1 while held') or diag("err: $@");

    # =========================================================================
    # AC-17 -- after release (file left in place) every combination gives 0;
    # after unlink, 0 as well.
    # =========================================================================
    flock($fh, LOCK_UN);
    close $fh;

    is(eval { Almanac::SessionLive::orchestrator_live(root => $root, blueprint => $bp_flagged) }, 0,
        'AC-17: raw root + flagged blueprint -> 0 after release (marker left in place)');
    is(eval { Almanac::SessionLive::orchestrator_live(root => $root_flagged, blueprint => 'fx') }, 0,
        'AC-17: flagged root + plain blueprint -> 0 after release');
    is(eval { Almanac::SessionLive::orchestrator_live(root => $root_flagged, blueprint => $bp_flagged) }, 0,
        'AC-17: both flagged -> 0 after release');

    unlink $marker;
    is(eval { Almanac::SessionLive::orchestrator_live(root => $root, blueprint => $bp_flagged) }, 0,
        'AC-17: raw root + flagged blueprint -> 0 after unlink');
}

# =============================================================================
# AC-18 -- production call path: Almanac::Thread::owner_status.
# =============================================================================
SKIP: {
    skip 'AC-18: Almanac::Thread not loadable', 2 unless $THREAD_LOADS;
    make_path("$root/.ccpraxis-local-data/almanac");   # so Almanac::Store resolves the project scope

    open(my $fh2, '>', $marker) or die "fixture: cannot write $marker: $!";
    print {$fh2} "$$\n";
    flock($fh2, LOCK_EX) or die "flock: $!";

    my $thread = { state => 'live', owner_kind => 'orchestrator', owner_id => $bp_flagged };
    my $status_live = eval { Almanac::Thread::owner_status($thread, root => $root)->{status} };
    is($status_live, 'live',
        'AC-18: owner_status reports status "live" while the marker is held -- FAILS ON CURRENT CODE')
        or diag("err: $@");

    flock($fh2, LOCK_UN);
    close $fh2;

    my $status_dead = eval { Almanac::Thread::owner_status($thread, root => $root)->{status} };
    is($status_dead, 'dead',
        'AC-18: owner_status reports status "dead" after release -- required so a universal exception-to-"live" default cannot pass for the wrong reason')
        or diag("err: $@");
}

done_testing();
