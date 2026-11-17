package ContainerClaudeMd;
# ContainerClaudeMd.pm -- the sandbox container's CLAUDE.md, built for the host
# that launched it and the container runtime in use, never copied whole.
#
# plugins/sandbox/container/ carries one shared file and optional parts:
#
#   CLAUDE.md                       every launch
#   CLAUDE.<runtime>.md             runtime: podman | docker
#   CLAUDE.<host>.md                host:    windows | macos | linux
#   CLAUDE.<host>-<runtime>.md      that host under that runtime only
#
# The rendered file is the shared file followed by every part that exists, in
# that order, each after a blank line. A part that does not exist is skipped,
# so a host with nothing of its own to say ships no file for it.
#
# WHY. Every agent in the container is handed this file whole at session
# start. It used to carry each host's networking facts side by side -- WSL2's
# wslrelay.exe and `wsl --shutdown` next to a table of Docker Desktop vs Docker
# Engine host names -- so a container started from a Mac was told about WSL.
# The choice of what applies is made here, once, from facts the launcher
# already has (its host and its container CLI), not left to the reader.
#
# WHY NOT GlobalClaudeMd. plugins/steward/scripts/GlobalClaudeMd.pm does the
# same job for ~/.claude/CLAUDE.md and its render() is the join used below.
# It is not loaded from here for three reasons: it chooses along one axis (the
# host) where this file needs two (host and runtime); loading it means putting
# another plugin's scripts directory on the launcher's @INC, which the launcher
# deliberately limits to its own directory (see its BEGIN block); and it pulls
# in MachineLocalSettings, the settings.json machinery the launcher has no use
# for. The join itself is a few lines and is kept byte-compatible with it.
#
# Because the delivered file is not a copy of any one repo file, the launcher's
# "container CLAUDE.md upstream changed" check hashes render_dir()'s output, so
# editing any part that applies to this launch is noticed exactly like editing
# the shared file.
#
# Pure apart from render_dir's file reads, which go through a seam. No state.
use strict;
use warnings;

use constant SHARED => 'CLAUDE.md';

our @HOSTS    = qw(windows macos linux);
our @RUNTIMES = qw(podman docker);

# part_names($host, $runtime) -> candidate part file names, in render order.
# $host is HostPlatform::os_family's spelling, $runtime runtime_family's.
sub part_names {
    my ($host, $runtime) = @_;
    my @n;
    push @n, "CLAUDE.$runtime.md"       if _known($runtime, \@RUNTIMES);
    push @n, "CLAUDE.$host.md"          if _known($host, \@HOSTS);
    push @n, "CLAUDE.$host-$runtime.md" if _known($host, \@HOSTS) && _known($runtime, \@RUNTIMES);
    return @n;
}

# all_part_names() -> every part name any launch could use. A file in the
# container directory named CLAUDE.*.md that is not in this list is a part no
# launch will ever deliver (a misspelt host or runtime); the tests hold that.
sub all_part_names {
    my %seen;
    my @all;
    for my $h (@HOSTS) {
        for my $r (@RUNTIMES) {
            for my $n (part_names($h, $r)) {
                push @all, $n unless $seen{$n}++;
            }
        }
    }
    return @all;
}

# render($shared, @parts) -> bytes: $shared, then each defined, non-empty part
# after a blank line. With no parts, $shared comes back byte for byte. Line
# endings follow $shared, as GlobalClaudeMd::render does.
sub render {
    my ($shared, @parts) = @_;
    my $out = defined $shared ? $shared : '';
    my $nl  = ($out =~ /\r\n/) ? "\r\n" : "\n";
    for my $part (@parts) {
        next unless defined $part && length $part;
        if (length $out) {
            $out .= $nl unless $out =~ /\n\z/;
            $out .= $nl;
        }
        $out .= $part;
    }
    return $out;
}

# render_dir($dir, $host, $runtime, %seams) -> bytes, or undef when $dir has
# no shared CLAUDE.md.
#   read => sub { $path -> bytes, or undef if it does not exist }
# In list context also returns the part names that were used, for logging.
sub render_dir {
    my ($dir, $host, $runtime, %o) = @_;
    my $read = ref $o{read} eq 'CODE' ? $o{read} : \&_slurp;
    return undef unless defined $dir && length $dir;
    my $shared = $read->("$dir/" . SHARED);
    return undef unless defined $shared;
    my (@used, @bytes);
    for my $name (part_names($host, $runtime)) {
        my $b = $read->("$dir/$name");
        next unless defined $b && length $b;
        push @used, $name;
        push @bytes, $b;
    }
    my $text = render($shared, @bytes);
    return wantarray ? ($text, \@used) : $text;
}

sub _known {
    my ($v, $list) = @_;
    return 0 unless defined $v && !ref $v;
    return (grep { $_ eq $v } @$list) ? 1 : 0;
}

sub _slurp {
    my ($p) = @_;
    return undef unless -f $p;
    open my $fh, '<:raw', $p or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c;
}

1;
