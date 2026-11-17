# BpJailDevices.pm -- are a worker jail's /dev nodes real devices?
#
# bp-jail.pl gives every jail /dev/null, /dev/zero, /dev/random and
# /dev/urandom. mknod is denied at run time, so the nodes come from the image:
# the Containerfile bakes them into /opt/bp-jail-skel/dev. A ROOTLESS image
# build cannot create device nodes (a user namespace may not, whatever its
# capabilities), so there the Containerfile leaves
# /opt/bp-jail-skel/dev/.no-device-nodes instead, and bp-jail.pl falls back to
# EMPTY REGULAR FILES. A worker that redirects to /dev/null or reads
# /dev/urandom misbehaves against those, and nothing used to say so: the
# marker had no reader.
#
# One answer for both places that need it: bp-jail.pl, which warns when it
# builds such a jail and records it in the jail's state, and bp-preflight.pl,
# which reports the image's state as a warning in the sandbox. Whether to build
# the image rootful is the operator's call; this module only reports.
package BpJailDevices;
use strict;
use warnings;
no warnings 'redefine';   # may be require'd under more than one path spelling

our @DEVICES = qw(null zero random urandom);
our $MARKER  = '.no-device-nodes';

# skel_dir() -> the baked skeleton. BP_JAIL_SKEL is a test seam.
sub skel_dir {
    my $e = $ENV{BP_JAIL_SKEL};
    return (defined $e && length $e) ? $e : '/opt/bp-jail-skel';
}

# stand_ins($dev_dir) -> the device names under $dev_dir that are NOT
# character devices (missing, or a regular-file stand-in).
sub stand_ins {
    my ($dir) = @_;
    return grep { !-c "$dir/$_" } @DEVICES;
}

# skeleton_state($skel) -> { ok => 0|1, missing => [...], marker => $text|undef, reason => $text, stand_ins => [...] }
# ok only when every device is a real character device AND no marker says
# otherwise. reason is one line, for a warning.
sub skeleton_state {
    my ($skel) = @_;
    $skel = skel_dir() unless defined $skel && length $skel;
    my @missing = stand_ins("$skel/dev");
    my $marker;
    if (open my $fh, '<', "$skel/dev/$MARKER") {
        local $/;
        $marker = <$fh>;
        close $fh;
        $marker = '' unless defined $marker;
        $marker =~ s/\s+/ /g;
        $marker =~ s/^ //;
        $marker =~ s/ $//;
    }
    my $reason = !-d $skel        ? "$skel does not exist (the image predates the jail skeleton)"
               : defined $marker  ? "$skel/dev/$MARKER: " . (length $marker ? $marker : 'present')
               : @missing         ? 'no device node for /dev/' . join(', /dev/', @missing) . " in $skel"
               :                    "real device nodes in $skel/dev";
    my $ok = (!@missing && !defined $marker) ? 1 : 0;
    # stand_ins: what a jail built from this skeleton would get as empty
    # files -- the missing nodes, or all of them when only the marker speaks.
    return { ok => $ok, missing => \@missing, marker => $marker, reason => $reason,
             stand_ins => ($ok ? [] : @missing ? [@missing] : [@DEVICES]) };
}

# warning_text(\@names, $reason) -> the one-line warning both callers print.
sub warning_text {
    my ($names, $reason) = @_;
    my @n = @{ $names || [] };
    return 'jailed workers get EMPTY REGULAR FILES, not devices, for /dev/' . join(', /dev/', @n)
         . " ($reason). A worker that redirects to /dev/null or reads /dev/urandom will misbehave."
         . ' Device nodes need an image built rootful; a rootless build cannot create them.';
}

1;
