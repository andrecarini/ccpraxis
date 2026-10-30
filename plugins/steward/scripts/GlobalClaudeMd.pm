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
# Core modules only; no state. Callers: scripts/promote.pl,
# plugins/steward/scripts/ccpraxis-helpers.pl, sync-export.pl and
# scripts/backup/Export.pm (via their own lib paths to this directory).
package GlobalClaudeMd;
use strict;
use warnings;
use Exporter 'import';
use MachineLocalSettings ();

our @EXPORT_OK = qw(SHARED_RELPATH host_part_relpath all_part_relpaths render render_with);

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

1;
