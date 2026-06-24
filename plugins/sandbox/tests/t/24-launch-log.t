#!/usr/bin/env perl
# B1 launch logging: LaunchLog.pm — the launcher's durable per-launch JSON-line
# diagnostic log. Part 1 covers the pure formatter (format_event), including the
# André-byte round-trip (no Ã© re-encode). Part 2 covers the file I/O: distinct
# autoflushed file, crash-readability (readable without close), and the
# safe-no-op when the log failed to open.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use JSON::PP;
use File::Temp qw(tempdir);

use_ok('LaunchLog') or BAIL_OUT('LaunchLog.pm did not load');

# ===========================================================================
# PART 1 — format_event (pure)
# ===========================================================================
{
    my $line = LaunchLog::format_event('container_start', { name => 'c1', exit => 0 }, 1_700_000_000, 4321);
    my $rec  = JSON::PP->new->decode($line);
    is($rec->{type}, 'container_start', 'format: type recorded');
    is($rec->{pid}, 4321,               'format: pid recorded');
    is($rec->{name}, 'c1',              'format: caller field merged');
    is($rec->{exit}, 0,                 'format: numeric field merged');
    like($rec->{ts}, qr/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/, 'format: ISO-8601 Z timestamp');
    is($rec->{ts}, '2023-11-14T22:13:20Z', 'format: ts derives from the given epoch (UTC)');

    # deterministic for a fixed epoch+pid (canonical key order)
    is(LaunchLog::format_event('t', { b => 2, a => 1 }, 100, 7),
       LaunchLog::format_event('t', { a => 1, b => 2 }, 100, 7),
       'format: canonical + deterministic');

    # no trailing newline in the formatted unit (event() adds it)
    unlike($line, qr/\n/, 'format: single line, no embedded newline');

    # defaults: undef type -> "event"; missing fields ok
    is(JSON::PP->new->decode(LaunchLog::format_event(undef, undef, 1, 1))->{type}, 'event',
       'format: undef type -> "event"');
}

# André-byte round-trip: a UTF-8 byte string must pass through unmodified.
{
    my $andre = "Andr\xC3\xA9";   # UTF-8 bytes for "André" (flag off)
    my $line  = LaunchLog::format_event('path', { dir => $andre }, 1, 1);
    like($line,   qr/Andr\x{C3}\x{A9}/, 'André: UTF-8 bytes preserved verbatim');
    unlike($line, qr/\x{C3}\x{83}/,     'André: NOT double-encoded to Ã©');
}

# ===========================================================================
# PART 2 — open_log / event / close_log (file I/O)
# ===========================================================================
{
    my $root = tempdir(CLEANUP => 1);
    my $path = "$root/.ccpraxis-local-data/claude-home/sandbox-logs/launch-x.log";   # nested, must be created
    my $fh = LaunchLog::open_log($path);
    ok($fh, 'open_log: returns a handle');
    ok(-d "$root/.ccpraxis-local-data/claude-home/sandbox-logs", 'open_log: created the parent dir');

    is(LaunchLog::event($fh, 'a', { i => 1 }), 1, 'event: writes (returns 1)');
    is(LaunchLog::event($fh, 'b', { i => 2 }), 1, 'event: writes again');

    # crash-readability: readable NOW, before any close (autoflush)
    my @lines = do { open my $r, '<:raw', $path or die; my @l = <$r>; close $r; @l };
    is(scalar @lines, 2, 'autoflush: both lines on disk without a close');
    my $r0 = JSON::PP->new->decode($lines[0]);
    my $r1 = JSON::PP->new->decode($lines[1]);
    is($r0->{type}, 'a', 'autoflush: first line intact');
    is($r1->{i}, 2,      'autoflush: second line intact');
    like($lines[0], qr/\n$/, 'event: each record is newline-terminated');

    LaunchLog::close_log($fh);
}

# André round-trip THROUGH the file (the real path: :raw handle preserves bytes)
{
    my $root = tempdir(CLEANUP => 1);
    my $path = "$root/logs/u.log";
    my $fh = LaunchLog::open_log($path);
    LaunchLog::event($fh, 'project', { dir => "/home/Andr\xC3\xA9/proj" });
    LaunchLog::close_log($fh);
    open my $r, '<:raw', $path or die; my $raw = do { local $/; <$r> }; close $r;
    like($raw,   qr/Andr\x{C3}\x{A9}/, 'André through file: bytes intact');
    unlike($raw, qr/\x{C3}\x{83}/,     'André through file: not double-encoded');
    # and it parses back as UTF-8 (what a renderer / jq will do)
    my $rec = JSON::PP->new->utf8->decode($raw);
    ok(defined $rec->{dir}, 'André through file: parses as valid UTF-8 JSON');
}

# safe no-op when the log failed to open (undef handle)
is(LaunchLog::event(undef, 'x', {}), 0, 'event(undef): no-op returns 0, never dies');
{
    my $ok = eval { LaunchLog::close_log(undef); 1 };
    ok($ok, 'close_log(undef): tolerant, never dies');
}

# open_log on an unwritable path returns undef (degrade, do not die)
{
    my $bad = LaunchLog::open_log('');
    is($bad, undef, 'open_log(""): undef, no crash');
}

done_testing();
