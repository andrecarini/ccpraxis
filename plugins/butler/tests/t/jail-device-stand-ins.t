#!/usr/bin/env perl
# platform: any
# A worker jail whose /dev nodes are empty files must say so.
#
# bp-jail.pl copies /dev/{null,zero,random,urandom} into each jail from the
# image's /opt/bp-jail-skel. A ROOTLESS image build cannot create device
# nodes; the Containerfile then leaves /opt/bp-jail-skel/dev/.no-device-nodes,
# and bp-jail.pl silently wrote EMPTY REGULAR FILES instead -- its own comment
# calls them "NOT functional for a real worker". Nothing read the marker.
#
# Now BpJailDevices.pm answers "are these real devices, and if not why", and
# both readers use it: bp-jail.pl warns on stderr and records the result in
# the jail's state when it creates one, and bp-preflight.pl reports the
# image's skeleton as a warning row in the sandbox.
#
# Nothing here needs root or a container. A fake skeleton stands in for
# /opt/bp-jail-skel (BP_JAIL_SKEL); a "real" node is a symlink to the host's
# own /dev/null etc., which -c follows to a character device.
BEGIN { $ENV{BP_CREDS_KEYCHAIN} = '0' }   # preflight is spawned below with the real HOME
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

my $SCRIPTS = "$Bin/../../scripts";
require "$SCRIPTS/BpJailDevices.pm";
my $WIN = $^O =~ /^(MSWin32|cygwin|msys)$/;

sub put { my ($p, $c) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $c; close $fh }

# fake_skel(%o) -> dir. real => 1 symlinks each node to the host's device;
# marker => text writes .no-device-nodes; files => 1 writes empty files.
sub fake_skel {
    my (%o) = @_;
    my $d = tempdir(CLEANUP => 1);
    make_path("$d/dev");
    for my $n (@BpJailDevices::DEVICES) {
        if ($o{real})  { symlink("/dev/$n", "$d/dev/$n") or die "symlink /dev/$n: $!" }
        if ($o{files}) { put("$d/dev/$n", '') }
    }
    put("$d/dev/.no-device-nodes", $o{marker}) if defined $o{marker};
    return $d;
}

my $ROOTLESS = 'mknod is not permitted in this image build (a rootless build cannot create device nodes); '
             . 'bp-jail.pl falls back to empty-file /dev stand-ins';

# ---- BpJailDevices::skeleton_state -------------------------------------------
{
    my $st = BpJailDevices::skeleton_state(fake_skel(marker => "$ROOTLESS\n"));
    is($st->{ok}, 0, 'skeleton: the rootless marker means no real nodes');
    like($st->{reason}, qr/\.no-device-nodes: mknod is not permitted/, 'skeleton: ...and the reason quotes the marker');
    is_deeply($st->{stand_ins}, [qw(null zero random urandom)], 'skeleton: ...all four would be stand-ins');

    my $files = BpJailDevices::skeleton_state(fake_skel(files => 1));
    is($files->{ok}, 0, 'skeleton: empty regular files are not devices, marker or not');
    like($files->{reason}, qr/no device node for \/dev\/null, \/dev\/zero/, 'skeleton: ...and the reason names them');

    my $none = BpJailDevices::skeleton_state("/nonexistent-bp-jail-skel-$$");
    is($none->{ok}, 0, 'skeleton: no skeleton at all is degraded too');
    like($none->{reason}, qr/does not exist/, 'skeleton: ...and says the image predates it');

    my $txt = BpJailDevices::warning_text($st->{stand_ins}, $st->{reason});
    like($txt, qr/EMPTY REGULAR FILES, not devices, for \/dev\/null, \/dev\/zero, \/dev\/random, \/dev\/urandom/,
        'warning: names every stand-in');
    like($txt, qr/rootful/, 'warning: ...and what would give real nodes');
  SKIP: {
        skip 'symlinks to /dev nodes are not meaningful on this host', 2 if $WIN || !-c '/dev/null';
        my $real = BpJailDevices::skeleton_state(fake_skel(real => 1));
        is($real->{ok}, 1, 'skeleton: real character devices and no marker is ok');
        is_deeply($real->{stand_ins}, [], 'skeleton: ...with no stand-ins');
    }
}

# ---- bp-jail.pl: populate_dev reports the stand-ins it had to write ----------
SKIP: {
    skip 'bp-jail.pl builds Linux jails (cp -a, mknod); its /dev population is not exercised on Windows', 9 if $WIN;
    require "$SCRIPTS/bp-jail.pl";   # no `package`: its subs land in main; main() runs only `unless caller`
    my $jail = tempdir(CLEANUP => 1);
    my $res;
    {
        # mknod is attempted (and refused, unprivileged); keep its complaint out of the TAP stream
        open(my $saved, '>&', \*STDERR) or die;
        open(STDERR, '>', File::Spec->devnull) or die;
        $res = main::populate_dev($jail, fake_skel(marker => $ROOTLESS));
        open(STDERR, '>&', $saved) or die;
    }
    my $privileged = !grep { !-c "$jail/dev/$_" } @BpJailDevices::DEVICES;   # running as root: mknod worked
    skip 'running privileged: mknod made real nodes, so there is no fallback to observe', 9 if $privileged;
    is($res->{functional}, 0, 'populate_dev: a rootless skeleton yields a non-functional /dev');
    is_deeply($res->{stand_ins}, [qw(null zero random urandom)], 'populate_dev: ...naming all four stand-ins');
    like($res->{reason} // '', qr/\.no-device-nodes/, 'populate_dev: ...with the marker as the reason');
    ok(-f "$jail/dev/null" && !-s "$jail/dev/null", 'populate_dev: the stand-in really is an empty regular file');

    my $ok_jail = tempdir(CLEANUP => 1);
    my $real = (-c '/dev/null') ? main::populate_dev($ok_jail, fake_skel(real => 1)) : undef;
    ok(!defined $real || $real->{functional}, 'populate_dev: nodes copied from a real skeleton are functional');

    # action_create wires it: a stderr WARNING and a `devices` record in the state.
    open my $fh, '<', "$SCRIPTS/bp-jail.pl" or die;
    my $src = do { local $/; <$fh> };
    close $fh;
    my ($create) = $src =~ /(sub action_create \{.*?\n\}\n)/s;
    ok(defined $create, 'action_create has an extractable body');
    like($create // '', qr/my \$devices\s*=\s*populate_os_skeleton\(/, 'action_create keeps what the skeleton step reports');
    like($create // '', qr/devices\s*=>\s*\{\s*functional\s*=>/, '...records it in the jail state (devices.functional)');
    like($create // '', qr/print STDERR 'bp-jail: WARNING: '\s*\.\s*BpJailDevices::warning_text/,
        '...and warns on stderr when /dev is not functional');
}

# ---- bp-preflight.pl reports the image's skeleton as a warning ----------------
{
    my $run = sub {
        my ($skel) = @_;
        my $home = tempdir(CLEANUP => 1);
        local $ENV{HOME} = $home;
        local $ENV{USERPROFILE} = $home;
        local $ENV{BP_JAIL_SKEL} = $skel;
        return scalar `"$^X" "$SCRIPTS/bp-preflight.pl" --platform=sandbox-linux 2>&1`;
    };
    my $out = $run->(fake_skel(marker => $ROOTLESS));
    like($out, qr/^\[ warn \] jail\.devices\s+jailed workers get EMPTY REGULAR FILES/m,
        'preflight (sandbox): a rootless skeleton is a warning row') or diag($out);
    unlike($out, qr/^\[ FAIL \] jail\.devices/m, 'preflight (sandbox): ...never a failure');
    unlike($out, qr/^\s+- \[jail\.devices\]/m, 'preflight (sandbox): ...and not among the gating failures');
  SKIP: {
        skip 'symlinks to /dev nodes are not meaningful on this host', 1 if $WIN || !-c '/dev/null';
        like($run->(fake_skel(real => 1)), qr/^\[  ok  \] jail\.devices/m, 'preflight (sandbox): real nodes are ok');
    }
    my $mac = do {
        my $home = tempdir(CLEANUP => 1);
        local $ENV{HOME} = $home; local $ENV{USERPROFILE} = $home;
        scalar `"$^X" "$SCRIPTS/bp-preflight.pl" --platform=macos 2>&1`;
    };
    like($mac, qr/^\[ skip \] jail\.devices\s+n\/a on macos/m, 'preflight (host): jails are a sandbox matter, n/a elsewhere');
}

done_testing();
