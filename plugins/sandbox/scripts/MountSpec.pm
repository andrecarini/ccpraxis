package MountSpec;
# Mount-spec helpers shared by launcher.pl and the test suite.
#
# Why this lives in its own module: on Git-for-Windows perl, MSYS argv
# conversion mangles `-v HOST:CONTAINER` mount specs (treats the `:` as
# a PATH-list separator). The launcher works around this by rewriting
# every `-v` pair into `--mount type=bind|volume,source=,target=` form
# before calling podman. The rewrite must handle BOTH bind mounts and
# named volumes correctly — type=bind on a bare volume name gets podman
# trying to statfs a non-existent host path. The detection rule lives
# here, exported, so a test can hold it accountable.

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(winify_path v_to_mount convert_v_to_mount);

our $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;

# Convert MSYS POSIX path (e.g. /c/Users/foo) to Windows drive-letter
# form (C:/Users/foo). podman.exe accepts forward slashes; only the
# drive letter has to be in `<letter>:` form. No-op for non-Windows.
sub winify_path {
    my $p = shift;
    return $p unless defined $p && length $p;
    return $p unless $WINDOWS_FAMILY;
    $p =~ s|^/([a-zA-Z])/|$1:/|;
    return $p;
}

# Rewrite one `SOURCE:TARGET[:OPTS]` spec into the comma-separated
# `--mount` value: `type=<kind>,source=<src>,target=<tgt>[,readonly]`.
# Kind is `bind` if SOURCE looks like a path (starts with `/`, `./`, or
# a drive letter), otherwise `volume`. Host paths are winified.
sub v_to_mount {
    my $spec = shift;
    my ($src, $tgt, $opts);
    # Drive-letter-aware: `X:/foo:/container[:opts]`. The drive's `:` is
    # part of SOURCE; the next `:` is the SOURCE/TARGET separator.
    if ($spec =~ m{^([A-Za-z]:[^:]+):([^:]+)(?::(.+))?$}) {
        ($src, $tgt, $opts) = ($1, $2, $3);
    } elsif ($spec =~ m{^([^:]+):([^:]+)(?::(.+))?$}) {
        ($src, $tgt, $opts) = ($1, $2, $3);
    } else {
        die "v_to_mount: cannot parse mount spec '$spec'\n";
    }
    # A path-shaped source = bind mount. A bare identifier = volume
    # (named or anonymous). Without this branch, named volume mounts
    # become bind mounts targeted at a host path that doesn't exist.
    my $is_path = ($src =~ m{^[/.]} || $src =~ m{^[A-Za-z]:});
    my $type = $is_path ? 'bind' : 'volume';
    $src = winify_path($src) if $is_path;
    my @kv = ("type=$type", "source=$src", "target=$tgt");
    if (defined $opts && length $opts) {
        push @kv, 'readonly' if $opts =~ /\bro\b/;
    }
    return join(',', @kv);
}

# Walk an argv list, rewriting every `-v SPEC` pair into `--mount KV`
# (so the launcher can author mounts in `-v` form for readability and
# still get the MSYS-safe `--mount` invocation at the boundary).
sub convert_v_to_mount {
    my @in = @_;
    my @out;
    while (@in) {
        my $a = shift @in;
        if ($a eq '-v' && @in) {
            my $spec = shift @in;
            push @out, '--mount', v_to_mount($spec);
        } else {
            push @out, $a;
        }
    }
    return @out;
}

1;
