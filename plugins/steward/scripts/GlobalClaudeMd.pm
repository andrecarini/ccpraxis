# GlobalClaudeMd -- ~/.claude/CLAUDE.md is built per host, not copied.
#
# global-config/ carries one shared file and one file per platform:
#
#   global-config/CLAUDE.md          every host
#   global-config/CLAUDE.windows.md  Windows hosts only
#   global-config/CLAUDE.macos.md    macOS hosts only
#
# The installed ~/.claude/CLAUDE.md is the shared file followed by this host's
# own file, when there is one (a Linux host has none). Every session on a
# machine is handed that file whole, so the selection has to happen here,
# once, by machinery: an earlier payload shipped both platforms' rules to
# every host with a note asking the reader to follow the matching section,
# which put a few dozen lines of the other OS's rules into every session.
#
# Because the installed file is not a copy of any one repo file, everything
# that compares ~/.claude/CLAUDE.md with the payload goes through render():
# promote.pl's refresh and its local-edit check, and the backup side's drift
# check. A hand edit to ~/.claude/CLAUDE.md cannot be exported back -- a line
# carries no record of which part it belongs to -- so it is refused with the
# offending lines shown, to be folded into the right part in the dev clone.
#
# Core modules only; no state. Callers: scripts/promote.pl (render_with), and
# on the backup side plugins/steward/scripts/ccpraxis-helpers.pl (check-claude-md,
# install-claude-md) and sync-export.pl, both through compare_installed(), so
# the drift check and the rebuild agree on what the build is.
package GlobalClaudeMd;
use strict;
use warnings;
use Exporter 'import';
use MachineLocalSettings ();
use Cwd ();

our @EXPORT_OK = qw(
    SHARED_RELPATH host_part_relpath all_part_relpaths render render_with
    render_from_dir compare_installed fold_hint
);

use constant SHARED_RELPATH => 'global-config/CLAUDE.md';

# host_platform() spelling => that platform's part. A platform with no entry
# gets the shared file alone.
my %PART_FOR = (
    windows => 'global-config/CLAUDE.windows.md',
    darwin  => 'global-config/CLAUDE.macos.md',
);

# The part for $platform (default: this host), or undef when it has none.
sub host_part_relpath {
    my ($platform) = @_;
    $platform //= MachineLocalSettings::host_platform();
    return $PART_FOR{$platform};
}

# Every file the installed CLAUDE.md can be built from, shared file first.
# The local-edit check accepts any line any of them ever held.
sub all_part_relpaths {
    return (SHARED_RELPATH, map { $PART_FOR{$_} } sort keys %PART_FOR);
}

# render($shared, $part) -> bytes: $shared, a blank line, then $part. An
# undef or empty $part leaves $shared exactly as it is, so a host with no
# part of its own installs the shared file byte for byte.
sub render {
    my ($shared, $part) = @_;
    $shared //= '';
    return $shared unless defined $part && length $part;
    my $nl = ($shared =~ /\r\n/) ? "\r\n" : "\n";
    my $out = $shared;
    if (length $out) {
        $out .= $nl unless $out =~ /\n\z/;
        $out .= $nl;
    }
    return $out . $part;
}

# render_with($read, $platform) -> bytes, or undef when the payload has no
# shared file. $read->($relpath) returns a payload file's bytes, or undef if
# it does not exist -- a git blob reader for promote, a file reader for the
# backup side. A missing platform part (a payload from before the split)
# renders as the shared file alone.
sub render_with {
    my ($read, $platform) = @_;
    my $shared = $read->(SHARED_RELPATH);
    return undef unless defined $shared;
    my $rel = host_part_relpath($platform);
    return render($shared, defined $rel ? $read->($rel) : undef);
}

# render_from_dir($root, $platform) -> bytes or undef: render_with() over the
# files of a checkout's working tree. The backup side builds from the live
# install this way -- the payload that was promoted, which is what promote
# itself installed.
sub render_from_dir {
    my ($root, $platform) = @_;
    return render_with(sub { _read_file("$root/$_[0]") }, $platform);
}

sub _read_file {
    my ($path) = @_;
    return undef unless defined $path && -f $path;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return defined $c ? $c : '';
}

sub _canon_path {
    my ($p) = @_;
    return undef unless defined $p;
    my $a = Cwd::abs_path($p) // $p;
    $a =~ s{\\}{/}g;
    $a =~ s{/+\z}{};
    return (MachineLocalSettings::is_windows_host() || $^O eq 'darwin') ? lc $a : $a;
}

# Lines of $a that $b does not have anywhere, as [ { n, text } ] with 1-based
# line numbers in $a. CRLF and LF compare equal.
sub _lines_not_in {
    my ($a, $b) = @_;
    my %in_b;
    for my $l (split /\n/, $b // '') { (my $t = $l) =~ s/\r\z//; $in_b{$t} = 1; }
    my @out;
    my @la = split /\n/, $a // '';
    for my $i (0 .. $#la) {
        (my $t = $la[$i]) =~ s/\r\z//;
        next if $t =~ /\A\s*\z/;   # a blank line says nothing about which part a line is from
        push @out, { n => $i + 1, text => $t } unless $in_b{$t};
    }
    return \@out;
}

# compare_installed(installed => PATH, live_root => DIR, platform => P?)
#
# Compares an installed ~/.claude/CLAUDE.md with what promote builds for this
# host from the live install's payload. Returns a hashref:
#   status         in_sync             a regular file equal to the build
#                  linked              a link to the shared payload file, on a
#                                      host with no part of its own (the link
#                                      IS the build there)
#                  differs             anything else that can be rebuilt
#                  symlinked_elsewhere a link to some other file
#                  missing_live        nothing installed
#                  missing_payload     the live install has no shared file
#   installed      PATH
#   host_part      this host's part (relpath), or undef
#   target         where a symlink points (absolute), when installed is one
#   reason         one line on what differs, for status differs
#   extra_lines    [ { n, text } ] installed lines the build does not have
#   missing_lines  [ { n, text } ] build lines the installed file does not have
#   rendered       the build's bytes (undef for missing_payload)
# A difference is never exported: a line carries no record of which part it
# came from, so it is shown, to be folded into the right part by hand.
sub compare_installed {
    my (%a) = @_;
    my ($installed, $live, $platform) = @a{qw(installed live_root platform)};
    my %r = (status => undef, installed => $installed, host_part => host_part_relpath($platform),
             target => undef, reason => undef, extra_lines => [], missing_lines => [], rendered => undef);

    my $rendered = render_from_dir($live, $platform);
    unless (defined $rendered) {
        $r{status} = 'missing_payload';
        return \%r;
    }
    $r{rendered} = $rendered;
    my $norm = sub { my $s = shift // ''; $s =~ s/\r\n/\n/g; return $s; };

    my $content;
    if (-l $installed) {
        my $t = readlink($installed) // '';
        (my $tn = $t) =~ s{\\}{/}g;
        unless ($tn =~ m{^/} || $tn =~ m{^[A-Za-z]:/}) {
            (my $dir = $installed) =~ s{\\}{/}g;
            $dir =~ s{/[^/]*\z}{};
            $tn = "$dir/$tn";
        }
        $r{target} = $tn;
        $content = _read_file($tn);
        my $shared_path = "$live/" . SHARED_RELPATH;
        my $to_shared = (defined _canon_path($tn) && _canon_path($tn) eq (_canon_path($shared_path) // ''));
        if ($to_shared && $norm->($content) eq $norm->($rendered)) {
            $r{status} = 'linked';
            return \%r;
        }
        if ($to_shared) {
            $r{status} = 'differs';
            $r{reason} = "a link to the shared file cannot carry this host's part ($r{host_part})";
        }
        else {
            $r{status} = 'symlinked_elsewhere';
        }
    }
    elsif (!-e $installed) {
        $r{status} = 'missing_live';
        return \%r;
    }
    else {
        $content = _read_file($installed) // '';
        if ($norm->($content) eq $norm->($rendered)) {
            $r{status} = 'in_sync';
            return \%r;
        }
        $r{status} = 'differs';
        $r{reason} = 'the file is not what promotion builds from the live install';
    }

    if (defined $content) {
        $r{extra_lines}   = _lines_not_in($content, $rendered);
        $r{missing_lines} = _lines_not_in($rendered, $content);
    }
    return \%r;
}

# The one-line resolution for installed lines the build does not have,
# worded as promote.pl's local-edit refusal is.
sub fold_hint {
    my ($platform) = @_;
    return "fold these lines into the dev clone's global-config/CLAUDE.md (every host) or this host's part ("
         . (host_part_relpath($platform) // 'none on this host')
         . ") and promote again; rebuilding ~/.claude/CLAUDE.md from the live install discards them.";
}

1;
