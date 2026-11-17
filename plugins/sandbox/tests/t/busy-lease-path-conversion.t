#!/usr/bin/env perl
# platform: host
# THE BUSY-LEASE PROBE MUST SURVIVE MSYS2 PATH CONVERSION.
#
# Measured defect, 2026-09-16, reported as 20260915-230820-d33e. The container
# sampler cleared MSYS2_ARG_CONV_EXCL at startup -- copied from the resources
# and spend samplers, which clear it for good reason -- and then ran
#
#     podman exec <ctr> stat -c %Y /tmp/.butler-busy
#
# podman.exe is a NATIVE Windows binary, so MSYS2 rewrote that leading-slash
# argument on the way in. What the container actually saw was the HOST's temp
# directory:
#
#     stat: cannot statx 'C:/Users/ANDR~1/AppData/Local/Temp/.butler-busy':
#           No such file or directory
#
# _busy_lease_probe matched "no such file" and returned 'lease-absent' -- which
# asserts a fact about the CONTAINER, and which KeepAwake::on_probe releases the
# wake-lock for at once, with none of the tolerance it applies to 'probe-failed'.
# The lease was in fact being refreshed every 2-10 seconds throughout. The host
# slept under a live blueprint fleet; the launch log for that sixteen-hour
# session contains 503 heartbeats and ZERO keepawake events, because the lock
# was never taken out at all.
#
# Broken in efdd028 (2026-08-25), when the four podman calls moved off the
# render tick into the sampler. Three weeks, every sandbox, every fleet run.
#
# WHAT THIS FILE GUARDS, in the order the defect has to get through:
#   A. the command SHAPE -- no podman exec anywhere may hand a native binary a
#      bare leading-slash path; `sh -c '...'` is correct under either
#      conversion state and cannot be broken by a caller's environment.
#   B. the sampler's ENVIRONMENT -- it must keep the opt-out, not clear it.
#   C. the CLASSIFICATION -- even if both of the above are defeated, a stat
#      failure naming a path we did not ask for is 'probe-failed', never
#      'lease-absent'.
#   D. the DECISION -- that distinction must actually change what on_probe does
#      to the wake-lock, which is the only reason any of it matters.
#
# Structural for A and B (launcher.pl is a script, slurped for source-text
# assertions -- the convention container-sampler.t established); behavioural for
# C and D against the real module.
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use Test::More;
use KeepAwake ();

my $LAUNCHER = "$Bin/../../scripts/launcher.pl";
ok(-f $LAUNCHER, 'launcher.pl is present') or BAIL_OUT('no launcher to test');
my $SRC = do { local (@ARGV, $/) = ($LAUNCHER); <> };

# ===========================================================================
# A. NO PODMAN EXEC HANDS A NATIVE BINARY A BARE POSIX PATH.
#
# Stated as a rule over the whole file rather than as four expected spellings,
# so a NEW call site added later is caught too -- the defect arrived exactly
# that way, as a copy of an existing line into a new context.
# ===========================================================================
my @bare;
for my $line (split /\n/, $SRC) {
    next unless $line =~ /\$PODMAN\s+exec\b/;
    next if $line =~ /^\s*#/;
    # An argv element that begins with a slash and is not inside a quoted
    # `sh -c` / `bash -c` string is what MSYS2 rewrites.
    next if $line =~ /\b(?:sh|bash)\s+-c\b/;
    push @bare, $line if $line =~ m{\s/(?:tmp|root|home|etc|var|proc)/};
}
is(scalar @bare, 0, 'A1: no podman exec passes a bare container-side POSIX path')
    or diag("conversion-vulnerable call site(s):\n  " . join("\n  ", @bare));

like($SRC, qr/\$BUSY_LEASE_PATH\s*=\s*"\/tmp\/\.butler-busy"/,
     'A2: the lease path is declared once, so every call site spells it identically');
like($SRC, qr/sh -c 'stat -c %Y \$BUSY_LEASE_PATH'/,
     'A3: the lease stat is wrapped so the path is not an argv element');

# ===========================================================================
# B. THE CONTAINER SAMPLER KEEPS THE OPT-OUT.
# ===========================================================================
my ($sampler) = ($SRC =~ /sub _container_sampler_main \{(.*?)\n\}/s);
ok(defined $sampler, 'B0: _container_sampler_main is present') or BAIL_OUT('sampler gone');
unlike($sampler, qr/delete \$ENV\{MSYS2_ARG_CONV_EXCL\}/,
       'B1: the container sampler does NOT clear the MSYS2 conversion opt-out');
like($sampler, qr/\$ENV\{MSYS2_ARG_CONV_EXCL\}\s*=\s*'\*'/,
     'B2: the container sampler sets the opt-out for its own subtree');

# ===========================================================================
# C. CLASSIFICATION -- the real strings, measured off this host.
# ===========================================================================
my $LEASE = '/tmp/.butler-busy';

my $rewritten = q{stat: cannot statx 'C:/Users/ANDR~1/AppData/Local/Temp/.butler-busy': No such file or directory};
is(KeepAwake::classify_lease_stat_failure($rewritten, $LEASE), 'path-rewritten',
   'C1: a stat failure naming the HOST temp dir is a rewritten path, not an absent lease');

my $genuine = qq{stat: cannot statx '$LEASE': No such file or directory};
is(KeepAwake::classify_lease_stat_failure($genuine, $LEASE), 'lease-absent',
   'C2: a stat failure naming OUR path is a genuinely absent lease');

my $busybox = qq{stat: can not stat '$LEASE': No such file or directory};
is(KeepAwake::classify_lease_stat_failure($busybox, $LEASE), 'lease-absent',
   'C3: an alternative stat phrasing of our own path is still lease-absent');

is(KeepAwake::classify_lease_stat_failure('No such file or directory', $LEASE), 'lease-absent',
   'C4: a message naming no path at all falls back to lease-absent, so a quiet '
   . 'stat variant cannot strand the lock held forever');

is(KeepAwake::classify_lease_stat_failure('Error: container is not running', $LEASE), undef,
   'C5: a non-ENOENT failure is not classified here at all');
is(KeepAwake::classify_lease_stat_failure(undef, $LEASE), undef,
   'C6: undef output is total, not fatal');

# ===========================================================================
# D. THE DISTINCTION CHANGES WHAT HAPPENS TO THE WAKE-LOCK.
#
# Without this, C is a pure function nobody's power bill depends on. The
# tolerance is picked HERE rather than read off a launcher.pl constant --
# keepawake-probe.t's established rule: drive the count, never pin the value.
# ===========================================================================
{
    my @acts;
    my $ka = KeepAwake->new(start => sub { 'handle' }, stop => sub { push @acts, 'stopped' });
    is($ka->on_probe({ state => 'ok', age => 5 }, 600, 2), 'start', 'D1: a fresh lease takes the lock');
    ok($ka->running, 'D2: ... and it is held');

    # The rewritten-path reading, routed as the fix routes it.
    is($ka->on_probe({ state => 'probe-failed', detail => 'rewritten' }, 600, 2), 'noop',
       'D3: a probe failure HOLDS the lock rather than releasing it');
    ok($ka->running, 'D4: ... the machine stays awake through it');
    $ka->on_probe({ state => 'probe-failed' }, 600, 2);
    ok($ka->running, 'D5: ... still held at the tolerance boundary');

    # And the misreading it replaces, to show the cost of getting C wrong.
    my $ka2 = KeepAwake->new(start => sub { 'handle' }, stop => sub { });
    $ka2->on_probe({ state => 'ok', age => 5 }, 600, 2);
    is($ka2->on_probe({ state => 'lease-absent' }, 600, 2), 'stop',
       'D6: read as lease-absent instead, the very same failure drops the lock at once');
    ok(!$ka2->running, 'D7: ... and the machine is free to sleep under a live run');
}

done_testing();
