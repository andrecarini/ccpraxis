package TestSandbox;
# Common helpers for plugins/sandbox/tests/.
#
# Mirrors the MSYS2-defense pattern from launcher.pl: disable MSYS argv
# path conversion, winify host paths upfront, and translate `-v` mount
# specs into `--mount type=bind|volume,source=,target=` to defeat the
# colon-as-PATH-list mangling on Git-for-Windows perl. Without these the
# test harness silently corrupts every podman command on Windows.
#
# All resources (containers, volumes, temp dirs) are tagged with the
# current PID + a counter so concurrent runs don't collide and the END
# block cleans up reliably even if a test aborts mid-flight.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../scripts";
use MountSpec qw(winify_path convert_v_to_mount);
use Exporter qw(import);
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);

our @EXPORT_OK = qw(
    podman_bin
    probe_image
    new_container_name
    new_temp_dir
    winify_path
    podman_run_capture
    create_probe_container
    register_cleanup_container
    register_cleanup_dir
    cleanup_all
);

our $WINDOWS_FAMILY = $^O =~ /^(MSWin32|cygwin|msys)$/;
# Detect docker OR podman — both supported. Same detection as
# launcher.pl / bootstrap.pl: probe `<cli> --version`, prefer docker.
sub _detect_container_cli {
    for my $candidate ($WINDOWS_FAMILY ? ('docker.exe', 'podman.exe') : ('docker', 'podman')) {
        my $rc = system("$candidate --version > /dev/null 2>&1");
        return $candidate if $rc == 0;
    }
    return undef;
}
our $PODMAN = _detect_container_cli() // die "TestSandbox: no container CLI on PATH (docker / podman)\n";
our $PROBE_IMAGE = 'docker.io/library/debian:bookworm-slim';

# Disable MSYS argv conversion process-wide. Same reasoning as launcher.pl:
# without this, podman -v HOST:CONTAINER args get split on `:`, each side
# POSIX→Windows-converted, and rejoined with `;` — yielding `;C`-suffixed
# garbage paths. Even single `/foo` args inside `podman exec` get rewritten
# to `C:\Program Files\Git\foo`.
$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $WINDOWS_FAMILY;

my @CLEANUP_CONTAINERS;
my @CLEANUP_DIRS;
my $COUNTER = 0;

sub podman_bin { $PODMAN }
sub probe_image { $PROBE_IMAGE }

sub _tag {
    $COUNTER++;
    return "claude-sandbox-test-$$-$COUNTER";
}

sub new_container_name { return _tag() . '-c' }

# winify_path comes from MountSpec.pm (imported above).

# Anchor temp dirs under $HOME (or $USERPROFILE on Windows). On WSL2-backed
# Docker/Podman, $HOME is reachable via /mnt/c automounts; same on Linux
# native; same on macOS via virtiofs. Git-Bash /tmp is in a 9p namespace
# the VM may not see (historical Hyper-V bug — kept the anchor for
# portability across backends).
sub new_temp_dir {
    my $home = $ENV{HOME} // $ENV{USERPROFILE};
    die "neither HOME nor USERPROFILE set" unless defined $home;
    my $base = "$home/.cache/sandbox-tests";
    require File::Path;
    File::Path::make_path($base) unless -d $base;
    my $d = tempdir(DIR => $base, CLEANUP => 0);
    $d = winify_path($d);
    register_cleanup_dir($d);
    return $d;
}

# Run a podman command. Returns ($exit_status >> 8, $combined_output).
# Uses system() with a list arg so MSYS doesn't get a second crack at the
# command string; captures stdout+stderr via a temp file redirect.
sub podman_run_capture {
    my @args = convert_v_to_mount(@_);
    require File::Temp;
    my ($fh, $tmp) = File::Temp::tempfile();
    close $fh;
    my $rc = system("$PODMAN @{[map { _arg_quote($_) } @args]} > " . _arg_quote($tmp) . " 2>&1");
    open my $rfh, '<', $tmp or die "open $tmp: $!";
    local $/;
    my $output = <$rfh>;
    close $rfh;
    unlink $tmp;
    return ($rc >> 8, $output // '');
}

# Arg quoting for system(STRING) calls. system() invokes /bin/sh on
# cygwin perl, so we have to defend against the same expansions any
# shell does. Double-quotes interpolate `$VAR` and backticks — fatal
# for test probes that pass shell scripts CONTAINING those characters
# (the in-container script's `$SECONDS` was getting expanded by the
# OUTER shell before podman ever saw it, yielding a script with empty
# vars). Strategy:
#   - if the string contains no single quotes, single-quote-wrap it
#     (POSIX literal — no interpolation, no escape sequences);
#   - if it has single quotes, fall back to double-quote escaping with
#     special care for the chars that bash interprets ($, `, ", \).
sub _arg_quote {
    my $s = shift;
    return $s if $s =~ /\A[\w.\/:=+\-,]+\z/;
    if ($s !~ /'/) {
        return "'$s'";
    }
    # Has single quotes — close, escape, reopen pattern: ' '\'' '
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

# Create+start a probe container running `sleep 600`. Mounts is an array
# of `-v SOURCE:TARGET[:OPTS]` pairs in launcher style — rewritten to
# `--mount` internally so they survive MSYS.
sub create_probe_container {
    my %opts = @_;
    my $mounts = $opts{mounts} || [];
    my $name = new_container_name();
    my @cmd = ('run', '-d', '--name', $name);
    push @cmd, @$mounts;
    push @cmd, $PROBE_IMAGE, 'sleep', '600';
    my ($rc, $out) = podman_run_capture(@cmd);
    die "create_probe_container($name) failed: $out" if $rc != 0;
    register_cleanup_container($name);
    return $name;
}

sub register_cleanup_container { push @CLEANUP_CONTAINERS, $_[0] }
sub register_cleanup_dir       { push @CLEANUP_DIRS,       $_[0] }

sub cleanup_all {
    for my $c (@CLEANUP_CONTAINERS) {
        system("$PODMAN rm -f " . _arg_quote($c) . " > /dev/null 2>&1");
    }
    @CLEANUP_CONTAINERS = ();
    for my $d (@CLEANUP_DIRS) {
        # Convert back to MSYS form if needed for remove_tree
        my $rm = $d;
        $rm =~ s|^([A-Za-z]):/|"/" . lc($1) . "/"|e if $WINDOWS_FAMILY;
        remove_tree($rm) if -d $rm;
    }
    @CLEANUP_DIRS = ();
}

END { cleanup_all() }

1;
