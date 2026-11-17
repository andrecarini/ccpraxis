#!/usr/bin/perl
# platform: any
# claude-internals-check.pl -- read-only signature scan of the installed
# claude binary for the undocumented internals ccpraxis settings rely on
# (never-halt blueprint, package 08). A Claude Code update can rename or drop
# any of these with no error, and the settings that depend on them would then
# go inert silently. This script proves, by byte signature, that each one is
# still present.
#
# Usage:
#   perl claude-internals-check.pl [--binary <path>] [--data <path>] [--help]
#
#   --binary <path>   Scan this file instead of searching PATH.
#   --data <path>     Use this data file instead of claude-internals.json next
#                     to this script.
#   --help / -h       Print usage and exit 0.
#
# Never executes, writes or spawns anything. Only reads the data file and the
# binary, both opened read-only.
#
# Test-only seam (never document on a user-facing surface, same convention as
# CLAUDE_BINARY_BACKUP_ROOT in claude-binary-backup.pl):
#   CLAUDE_INTERNALS_CHUNK_BYTES   overrides the scan chunk size (default 8 MiB)
#   CLAUDE_INTERNALS_OVERLAP_BYTES overrides the scan overlap (default 4096)
#
# Exit codes:
#   0 = every entry PRESENT
#   1 = at least one entry CHANGED
#   2 = could not run: usage error, binary/data problem, invalid scan seam
#
# stdout is always exactly one JSON object, for every exit code.
#
# Self-contained: core Perl modules only.

use strict;
use warnings;
use File::Basename qw(dirname);
use JSON::PP qw(decode_json);
use Encode qw(decode);

binmode STDERR, ':encoding(UTF-8)';

my $DEFAULT_CHUNK   = 8388608; # 8 MiB
my $DEFAULT_OVERLAP = 4096;

# ─── Output helpers ─────────────────────────────────────────────────────────

# Output structures mix char strings (JSON-decoded id/description/etc.) with
# raw UTF-8 byte strings (paths built from %ENV / argv). Normalize byte
# strings up to chars before the ->utf8 encoder so each is encoded exactly
# once (else a non-ASCII path like "Andr\xc3\xa9" double-encodes on output).
# Copied from ccpraxis-helpers.pl's _decode_strings_recursive, per spec 2.1.1 --
# not imported, so this script stays self-contained.
sub _decode_strings_recursive {
    my $x = shift;
    if (ref $x eq 'HASH') {
        return { map { $_ => _decode_strings_recursive($x->{$_}) } keys %$x };
    } elsif (ref $x eq 'ARRAY') {
        return [ map { _decode_strings_recursive($_) } @$x ];
    } elsif (ref $x) {
        return $x;
    } elsif (defined $x && !utf8::is_utf8($x)) {
        return $x + 0 if $x =~ /^-?\d+$/;
        return $x + 0 if $x =~ /^-?\d+\.\d+$/;
        my $decoded = eval { decode('UTF-8', $x, Encode::FB_CROAK) };
        return defined $decoded ? $decoded : decode('cp1252', $x, Encode::FB_DEFAULT);
    }
    return $x;
}

sub emit_json {
    my ($obj) = @_;
    my $json = JSON::PP->new->utf8->canonical->pretty;
    print $json->encode(_decode_strings_recursive($obj));
}

sub die_error {
    my ($msg) = @_;
    emit_json({ status => 'error', error => $msg });
    print STDERR "claude-internals-check: $msg\n";
    exit 2;
}

# ─── Usage ──────────────────────────────────────────────────────────────────

sub usage_text {
    return <<'EOF';
claude-internals-check.pl -- read-only signature scan of the installed claude binary for the undocumented internals ccpraxis settings rely on.

Usage:
  perl claude-internals-check.pl [--binary <path>] [--data <path>] [--help]

  --binary <path>   Scan this file instead of searching PATH.
  --data <path>     Use this data file instead of claude-internals.json next
                    to this script.
  --help / -h       Print this message and exit 0.

Exit codes: 0 = every entry PRESENT, 1 = at least one entry CHANGED,
2 = could not run (usage error, binary/data problem, invalid scan seam).
EOF
}

# ─── Argument parsing ───────────────────────────────────────────────────────

sub parse_args {
    my (@argv) = @_;
    my %opt;
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--help' || $a eq '-h') {
            $opt{help} = 1;
        } elsif ($a eq '--binary') {
            my $v = shift @argv;
            die_error('--binary requires a value') unless defined $v;
            $opt{binary} = $v;
        } elsif ($a =~ /^--binary=(.*)\z/s) {
            $opt{binary} = $1;
        } elsif ($a eq '--data') {
            my $v = shift @argv;
            die_error('--data requires a value') unless defined $v;
            $opt{data} = $v;
        } elsif ($a =~ /^--data=(.*)\z/s) {
            $opt{data} = $1;
        } else {
            die_error("unknown argument: $a");
        }
    }
    return \%opt;
}

# ─── Data file loading & validation ─────────────────────────────────────────

sub entry_label {
    my ($e, $i) = @_;
    return (defined $e->{id} && length $e->{id}) ? $e->{id} : "entry $i";
}

# Returns an error string, or undef when the data file is valid. As a side
# effect, precompiles each regex signature's qr// onto the signature hash
# (key "_compiled") for reuse during the scan -- validation already proved it
# compiles, so the scanner does not compile it a second time.
sub validate_data {
    my ($data) = @_;
    return 'data file must be a JSON object' unless ref($data) eq 'HASH';
    my $schema = $data->{schema};
    return 'schema must be 1' unless defined $schema && "$schema" eq '1';
    my $entries = $data->{entries};
    return 'entries must be a non-empty array' unless ref($entries) eq 'ARRAY' && @$entries;

    my %seen_ids;
    for my $i (0 .. $#$entries) {
        my $e = $entries->[$i];
        return "entry $i: must be an object" unless ref($e) eq 'HASH';
        my $label = entry_label($e, $i);

        if (!defined $e->{id} || !length $e->{id}) {
            return "$label: id is missing";
        }
        unless ($e->{id} =~ /^[a-z0-9]+(-[a-z0-9]+)*\z/) {
            return "$label: id has invalid format";
        }
        if ($seen_ids{ $e->{id} }++) {
            return "$label: duplicate id";
        }
        unless (defined $e->{description} && !ref($e->{description}) && length $e->{description}) {
            return "$label: description must be a non-empty string";
        }
        unless (defined $e->{relied_by} && !ref($e->{relied_by}) && length $e->{relied_by}) {
            return "$label: relied_by must be a non-empty string";
        }
        my $fi = $e->{found_in};
        unless (ref($fi) eq 'HASH'
                && defined $fi->{version} && length $fi->{version}
                && defined $fi->{date} && $fi->{date} =~ /^\d{4}-\d{2}-\d{2}\z/) {
            return "$label: found_in must have a non-empty version and a date matching YYYY-MM-DD";
        }
        my $sigs = $e->{signatures};
        unless (ref($sigs) eq 'ARRAY' && @$sigs) {
            return "$label: signatures must be a non-empty array";
        }
        for my $j (0 .. $#$sigs) {
            my $s = $sigs->[$j];
            unless (ref($s) eq 'HASH') {
                return "$label: signature $j must be an object";
            }
            my $type = $s->{type} // '';
            unless ($type eq 'literal' || $type eq 'regex') {
                return "$label: signature $j has unknown type '$type'";
            }
            my $value = $s->{value};
            unless (defined $value && !ref($value) && length($value) && length($value) <= 256
                    && $value =~ /^[\x20-\x7e]+\z/) {
                return "$label: signature $j value must be a non-empty printable-ASCII string of at most 256 characters";
            }
            if ($type eq 'regex') {
                my $re = eval { qr/$value/ };
                if ($@ || !$re) {
                    return "$label: signature $j regex does not compile";
                }
                if ($value =~ /\(\?<[=!]/) {
                    return "$label: signature $j regex contains a forbidden lookbehind";
                }
                my $example = $s->{example};
                unless (defined $example && length($example) && length($example) <= 256
                        && $example =~ /^[\x20-\x7e]+\z/) {
                    return "$label: signature $j must carry a printable-ASCII example of 1-256 characters";
                }
                unless ($example =~ $re) {
                    return "$label: signature $j example does not match its regex";
                }
                $s->{_compiled} = $re;
            }
        }
    }
    return undef;
}

sub load_data {
    my ($path) = @_;
    die_error("data file not found: $path") unless -e $path;
    die_error("data file is not a regular file: $path") unless -f $path;
    open my $fh, '<:raw', $path or die_error("cannot read data file $path: $!");
    local $/;
    my $raw = <$fh>;
    close $fh;
    my $data = eval { decode_json($raw) };
    die_error("data file is not valid JSON: $path") if $@ || !defined $data;
    my $err = validate_data($data);
    die_error($err) if defined $err;
    return $data;
}

# ─── Binary location ────────────────────────────────────────────────────────

sub is_win_family { return $^O eq 'MSWin32' || $^O eq 'msys' || $^O eq 'cygwin'; }

sub search_path {
    my $path_env = defined $ENV{PATH} ? $ENV{PATH} : '';
    my $sep = ($^O eq 'MSWin32') ? ';' : ':';
    my @dirs = split /\Q$sep\E/, $path_env, -1;
    my @names = is_win_family() ? ('claude.exe', 'claude') : ('claude');
    for my $dir (@dirs) {
        next unless defined $dir && length $dir;
        for my $name (@names) {
            my $candidate = "$dir/$name";
            if (-f $candidate && -r $candidate) {
                return ($candidate, 'path', undef);
            }
        }
    }
    return (undef, undef, 'claude not found on PATH; pass --binary <path>');
}

sub locate_binary {
    my ($binary_arg) = @_;
    if (defined $binary_arg) {
        die_error("binary not found: $binary_arg") unless -e $binary_arg;
        die_error("binary is not a regular file: $binary_arg") unless -f $binary_arg;
        return ($binary_arg, 'argument');
    }
    my ($path, $source, $err) = search_path();
    die_error($err) if defined $err;
    return ($path, $source);
}

# ─── Scan seam ──────────────────────────────────────────────────────────────

sub scan_seam {
    my $chunk   = $ENV{CLAUDE_INTERNALS_CHUNK_BYTES};
    my $overlap = $ENV{CLAUDE_INTERNALS_OVERLAP_BYTES};
    $chunk   = $DEFAULT_CHUNK   unless defined $chunk   && length $chunk;
    $overlap = $DEFAULT_OVERLAP unless defined $overlap && length $overlap;
    die_error('invalid scan seam') unless $chunk =~ /^\d+\z/ && $overlap =~ /^\d+\z/;
    $chunk   += 0;
    $overlap += 0;
    die_error('invalid scan seam') unless $chunk > 0 && $overlap > 0 && $chunk >= $overlap;
    return ($chunk, $overlap);
}

# ─── Chunked scan ───────────────────────────────────────────────────────────

# Returns \@found (found[$ei][$si] booleans) on success, or dies via die_error
# on a read failure. Never slurps the file; peak memory stays near
# CHUNK + OVERLAP bytes regardless of binary size.
sub scan_binary {
    my ($path, $entries, $chunk, $overlap) = @_;

    open my $fh, '<:raw', $path or die_error("cannot read binary $path: $!");

    my @found;
    my $remaining = 0;
    for my $ei (0 .. $#$entries) {
        my $sigs = $entries->[$ei]{signatures};
        for my $si (0 .. $#$sigs) {
            $found[$ei][$si] = 0;
            $remaining++;
        }
    }

    my $tail = '';
    while (1) {
        my $new;
        my $n = read($fh, $new, $chunk);
        unless (defined $n) {
            my $err = $!;
            close $fh;
            die_error("cannot read binary $path: $err");
        }
        my $buf    = $tail . $new;
        my $at_eof = eof($fh);
        my $limit  = $at_eof ? length($buf) : length($buf) - $overlap;
        $limit = 0 if $limit < 0;

        if ($remaining > 0) {
            for my $ei (0 .. $#$entries) {
                my $sigs = $entries->[$ei]{signatures};
                for my $si (0 .. $#$sigs) {
                    next if $found[$ei][$si];
                    my $sig = $sigs->[$si];
                    my $start;
                    if ($sig->{type} eq 'literal') {
                        my $idx = index($buf, $sig->{value});
                        $start = $idx >= 0 ? $idx : undef;
                    } else {
                        $start = ($buf =~ $sig->{_compiled}) ? $-[0] : undef;
                    }
                    if (defined $start && $start < $limit) {
                        $found[$ei][$si] = 1;
                        $remaining--;
                    }
                }
            }
        }

        last if $at_eof || $remaining == 0;
        $tail = length($buf) > $overlap ? substr($buf, -$overlap) : $buf;
    }
    close $fh;
    return \@found;
}

# ─── Main ───────────────────────────────────────────────────────────────────

sub main {
    my $opt = parse_args(@ARGV);
    if ($opt->{help}) {
        print usage_text();
        exit 0;
    }

    # Separators FIRST, then dirname -- __FILE__ can carry backslashes on
    # Windows. Same shape as BpTurnCaps::script_dir_for; asserted repo-wide by
    # turn-cap-consistency.t's C9.
    (my $self = __FILE__) =~ s{\\}{/}g;
    my $script_dir = dirname($self);
    my $data_path  = defined $opt->{data} ? $opt->{data} : "$script_dir/claude-internals.json";
    my $data       = load_data($data_path);
    my $entries    = $data->{entries};

    my ($chunk, $overlap) = scan_seam();

    my ($bin_path, $bin_source) = locate_binary($opt->{binary});

    my $found = scan_binary($bin_path, $entries, $chunk, $overlap);

    my $size = -s $bin_path;

    my (@out_entries, @changed);
    my ($present_count, $changed_count) = (0, 0);
    for my $ei (0 .. $#$entries) {
        my $e    = $entries->[$ei];
        my $sigs = $e->{signatures};
        my @missing;
        for my $si (0 .. $#$sigs) {
            push @missing, $sigs->[$si]{value} unless $found->[$ei][$si];
        }
        my $state = @missing ? 'CHANGED' : 'PRESENT';
        if ($state eq 'CHANGED') {
            $changed_count++;
            push @changed, {
                id         => $e->{id},
                description=> $e->{description},
                relied_by  => $e->{relied_by},
                found_in   => $e->{found_in},
                missing    => \@missing,
            };
        } else {
            $present_count++;
        }
        push @out_entries, {
            id        => $e->{id},
            state     => $state,
            relied_by => $e->{relied_by},
            missing   => \@missing,
        };
    }

    my $status = @changed ? 'changed' : 'ok';
    emit_json({
        status        => $status,
        binary        => $bin_path,
        binary_source => $bin_source,
        size_bytes    => $size,
        data_file     => $data_path,
        entries       => \@out_entries,
        changed       => \@changed,
        summary       => "$present_count PRESENT, $changed_count CHANGED",
    });

    if (@changed) {
        for my $c (@changed) {
            print STDERR "CHANGED $c->{id}: $c->{relied_by} may no longer work\n";
        }
        exit 1;
    }
    exit 0;
}

main();
