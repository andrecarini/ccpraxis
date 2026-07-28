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

our @EXPORT_OK = qw(winify_path v_to_mount convert_v_to_mount
    claude_home_create_args parse_create_args parse_inspect_lines
    audit_claude_home);

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

# ---------------------------------------------------------------------
# claude-home create-args builder + auditor (spec 02-implement-config-
# safety-spec.md). Extracted here so a test can hold the launcher's
# `podman create` claude-home block accountable without executing
# launcher.pl's ~2300 lines of top-level side-effectful setup (s01 row
# 11; spec sec 2.1). launcher.pl calls this as:
#
#   claude_home_create_args(
#       claude_data  => $CLAUDE_DATA,
#       launcher_dir => $LAUNCHER_DIR,
#       statusline   => "$CLAUDE_HOST_CONFIG/ccpraxis/scripts/statusline.pl",
#   )
#
# — which is the same claude-home block that used to be written inline
# in launcher.pl's create-args closure:
#   '-v', "${CLAUDE_DATA}:/root/.claude",
#   '-v', "${LAUNCHER_DIR}:/root/.claude/.launcher:ro",
#   '-v', "${CLAUDE_HOST_CONFIG}/ccpraxis/scripts/statusline.pl:/root/.claude/statusline.pl:ro",
# plus the new CLAUDE_CONFIG_DIR -e literal that replaces the deleted
# single-file bind onto /root/.claude.json (spec B1/B6/B7).
# ---------------------------------------------------------------------

# Emit the complete claude-home block of the `podman create` arg list, in
# `-v` authoring form (convert_v_to_mount rewrites it at the boundary).
# Ordered. Dies on a missing/empty required option (a silently-empty host
# source would create an anonymous/garbage mount).
sub claude_home_create_args {
    my (%opt) = @_;
    for my $key (qw(claude_data launcher_dir statusline)) {
        die "MountSpec::claude_home_create_args: missing or empty required option '$key'\n"
            unless defined $opt{$key} && length $opt{$key};
    }
    my ($claude_data, $launcher_dir, $statusline) =
        @opt{qw(claude_data launcher_dir statusline)};

    # The -e value is a HARD-CODED LITERAL — never interpolated, never
    # derived from a variable. s01 sec 3 point 2: a present-but-empty
    # CLAUDE_CONFIG_DIR makes the config-file resolver fall back to
    # ~/.claude.json while the config-dir resolver yields cwd-relative
    # paths, so credentials would land in a project working tree. The
    # literal is the regression guard.
    return (
        '-e', 'CLAUDE_CONFIG_DIR=/root/.claude',
        '-v', "$claude_data:/root/.claude",
        '-v', "$launcher_dir:/root/.claude/.launcher:ro",
        '-v', "$statusline:/root/.claude/statusline.pl:ro",
    );
}

# Parse a podman argv into the normalized shape used by audit_claude_home.
# Handles the POST-convert_v_to_mount `--mount type=bind|volume,source=…,
# target=…[,readonly]` form and also tolerates raw `-v SPEC` pairs (the
# authoring form), plus `-e KEY=VALUE`. Pure: no I/O, no path checks.
sub parse_create_args {
    my ($argv) = @_;
    my @in = @{ $argv // [] };
    my %result = (mounts => [], env => {});
    while (@in) {
        my $a = shift @in;
        if ($a eq '--mount' && @in) {
            my $spec = shift @in;
            my %kv;
            for my $pair (split /,/, $spec) {
                if ($pair =~ /^([^=]+)=(.*)$/) {
                    $kv{$1} = $2;
                } elsif ($pair eq 'readonly') {
                    $kv{readonly} = 1;
                }
            }
            push @{ $result{mounts} }, {
                type     => $kv{type} // 'bind',
                source   => $kv{source},
                target   => $kv{target},
                readonly => $kv{readonly} ? 1 : 0,
            };
        } elsif ($a eq '-v' && @in) {
            my $spec = shift @in;
            my ($src, $tgt, $opts);
            if ($spec =~ m{^([A-Za-z]:[^:]+):([^:]+)(?::(.+))?$}) {
                ($src, $tgt, $opts) = ($1, $2, $3);
            } elsif ($spec =~ m{^([^:]+):([^:]+)(?::(.+))?$}) {
                ($src, $tgt, $opts) = ($1, $2, $3);
            }
            if (defined $src && defined $tgt) {
                my $is_path = ($src =~ m{^[/.]} || $src =~ m{^[A-Za-z]:});
                push @{ $result{mounts} }, {
                    type     => $is_path ? 'bind' : 'volume',
                    source   => $src,
                    target   => $tgt,
                    readonly => (defined $opts && $opts =~ /\bro\b/) ? 1 : 0,
                };
            }
        } elsif ($a eq '-e' && @in) {
            my $kv = shift @in;
            if ($kv =~ /^([^=]+)=(.*)$/) {
                push @{ $result{env}{$1} }, $2;
            }
        }
    }
    return \%result;
}

# Parse the line-oriented output of the row-22 `podman inspect --format`
# template into the SAME shape as parse_create_args. Lines:
#   "MOUNT <type> <source> <destination> <RW-true|false>"
#   "ENV <KEY>=<VALUE>"
# Unknown lines are ignored. Pure: no I/O.
sub parse_inspect_lines {
    my ($lines) = @_;
    my %result = (mounts => [], env => {});
    for my $line (@{ $lines // [] }) {
        next unless defined $line;
        # SOURCE is matched greedily rather than as `\S+` (redteam M5): host
        # paths on the primary host platform routinely contain spaces
        # (`C:/Users/First Last/...`). With `\S+` the whole line failed to
        # match and was silently dropped as "unknown", so a container still
        # carrying the old `/root/.claude.json` bind would produce NO
        # violation and sail through the shape check — a false negative in
        # exactly the guard this package exists to add. TYPE, TARGET and the
        # true/false flag stay anchored, so the greedy middle can only absorb
        # the source. (A container TARGET containing spaces would still
        # mis-parse; every target here is a fixed /root/.claude* path.)
        if ($line =~ /^MOUNT\s+(\S+)\s+(.+)\s+(\S+)\s+(true|false)\s*$/) {
            my ($type, $source, $target, $rw) = ($1, $2, $3, $4);
            push @{ $result{mounts} }, {
                type     => $type,
                source   => $source,
                target   => $target,
                readonly => ($rw eq 'true') ? 0 : 1,
            };
        } elsif ($line =~ /^ENV\s+([^=]+)=(.*)$/) {
            push @{ $result{env}{$1} }, $2;
        }
        # else: unknown line, ignored.
    }
    return \%result;
}

# The shared structural predicate. Returns a (possibly empty) list of
# violation hashrefs { code => $CODE, detail => $human_string }; empty
# list == compliant. \&pred defaults to sub { -f $_[0] } (used by both
# t/02's synthetic classifier and the real filesystem in launcher.pl).
sub audit_claude_home {
    my ($parsed, %opt) = @_;
    my $is_file = $opt{is_file} // sub { -f $_[0] };
    my @violations;

    for my $m (@{ $parsed->{mounts} // [] }) {
        my $target = $m->{target};
        next unless defined $target;

        # Catches the deleted bind and the old container shape even where
        # the host source does not exist — any type, any ro-ness.
        if ($target eq '/root/.claude.json') {
            push @violations, {
                code   => 'claude_json_mount',
                detail => "mount destined at /root/.claude.json (source: "
                    . (defined $m->{source} ? $m->{source} : '(unknown)') . ")",
            };
        }

        # Deliberately does NOT match the dir bind's own target
        # /root/.claude (which is a directory anyway, so is_file is false).
        if (($m->{type} // '') eq 'bind'
            && $target =~ m{^/root/\.claude(\.json|/)}
            && defined $m->{source}
            && $is_file->($m->{source})
            && !$m->{readonly}) {
            push @violations, {
                code   => 'writable_single_file_bind',
                detail => "writable single-file bind at $target (source: $m->{source})",
            };
        }
    }

    my $env      = $parsed->{env} // {};
    my $cfg_vals = $env->{CLAUDE_CONFIG_DIR};
    if (!defined $cfg_vals || !@$cfg_vals) {
        push @violations, {
            code   => 'config_dir_env_missing',
            detail => 'no CLAUDE_CONFIG_DIR in env',
        };
    } else {
        if (@$cfg_vals > 1) {
            push @violations, {
                code   => 'config_dir_env_duplicate',
                detail => 'CLAUDE_CONFIG_DIR declared ' . scalar(@$cfg_vals) . ' times: '
                    . join(', ', map { defined $_ ? $_ : '(undef)' } @$cfg_vals),
            };
        }
        my $last = $cfg_vals->[-1];
        if (!defined $last || $last ne '/root/.claude') {
            push @violations, {
                code   => 'config_dir_env_wrong',
                detail => 'CLAUDE_CONFIG_DIR=' . (defined $last ? "'$last'" : '(undef)')
                    . " (expected '/root/.claude')",
            };
        }
    }

    return @violations;
}

1;
