package RefusalMarker;
# Generic "do not sandbox here" marker for the sandbox launcher.
#
# A directory that must never become (or sit inside, or sit just below) a
# claude-sandbox project carries a file named MARKER_NAME. The launcher and
# bootstrap refuse to act on such a path and print the marker's own text as
# the error, so whoever placed the marker decides what the refusal says and
# where it points the operator. Nothing about any particular directory lives
# in this module: the marker file is the whole configuration.
#
# Marker file format (plain text):
#
#   allow-launcher: <launcher-id>     zero or more lines, any position
#   <anything else>                   the refusal message, printed verbatim
#
# An `allow-launcher:` line lets the named launcher past THIS marker. The id a
# launcher presents is $SandboxIdentity::ID (mirrored in $LAUNCHER_ID below),
# so a downstream fork that ships its own launcher changes its identity there
# and nothing here.
# There is deliberately no environment-variable or command-line override: a
# switch any caller can flip would turn the refusal into a suggestion.
#
# Where markers are looked for, relative to the launch target T:
#   here  -- T itself
#   above -- every ancestor of T, up to the filesystem root
#   below -- directories up to $SCAN_DEPTH levels under T (default 2)
# "below" exists because sandboxing a parent bind-mounts the marked directory
# too. It is depth-bounded on purpose: a full recursive walk would cost every
# ordinary launch a scan of its whole tree (node_modules and all). A marker
# deeper than $SCAN_DEPTH below the launch directory is NOT detected; place
# markers no deeper than that under any directory you might launch from.

use strict;
use warnings;
use Exporter qw(import);
use SandboxIdentity ();

our @EXPORT_OK = qw(
    MARKER_NAME
    parse_marker
    find_refusal
    refusal_message
);

use constant MARKER_NAME => '.claude-sandbox-refuse';

# The identity this copy of the launcher presents to `allow-launcher:` lines.
our $LAUNCHER_ID = $SandboxIdentity::ID;

# How many directory levels below the launch target are scanned for markers.
our $SCAN_DEPTH = 2;

# Cap on how much of a marker file is read; a marker is a short note.
use constant MAX_MARKER_BYTES => 16 * 1024;

# Strip bytes that could forge extra terminal lines' styling or control
# sequences when the message lands on STDERR. Newlines and tabs are kept --
# a multi-line message is the point -- but CR and every other C0/DEL byte
# become a space.
sub _sanitize {
    my ($s) = @_;
    return '' unless defined $s;
    $s =~ s/\r\n?/\n/g;
    $s =~ s/[\x00-\x08\x0b-\x1f\x7f]/ /g;
    return $s;
}

# parse_marker($text) -> { message => $str, allow => [ids...] }
# Pure. `allow-launcher:` lines are removed from the message; ids compare
# case-insensitively and are returned lowercased.
sub parse_marker {
    my ($text) = @_;
    $text = _sanitize($text);
    my (@allow, @keep);
    for my $line (split /\n/, $text, -1) {
        if ($line =~ /^\s*allow-launcher\s*:\s*(\S+)\s*$/i) {
            push @allow, lc $1;
        } else {
            push @keep, $line;
        }
    }
    my $message = join "\n", @keep;
    $message =~ s/\A\s+//;
    $message =~ s/\s+\z//;
    return { message => $message, allow => \@allow };
}

sub _read_marker {
    my ($file) = @_;
    open my $fh, '<:raw', $file or return '';
    my $buf = '';
    read $fh, $buf, MAX_MARKER_BYTES;
    close $fh;
    return $buf;
}

# A marker is a plain FILE with this name; a directory of the same name, or a
# dangling symlink, does not count.
sub _marker_in {
    my ($dir) = @_;
    my $f = "$dir/" . MARKER_NAME;
    return (-f $f) ? $f : undef;
}

sub _norm {
    my ($p) = @_;
    $p =~ s{\\}{/}g;
    $p =~ s{/+\z}{} unless $p =~ m{\A(?:[A-Za-z]:)?/\z};
    return $p;
}

# Every ancestor of $p, nearest first, ending at the filesystem root.
sub _ancestors {
    my ($p) = @_;
    my @out;
    while (1) {
        my $parent;
        if ($p =~ m{\A(.*)/[^/]+\z}) {
            $parent = $1;
            $parent .= '/' if $parent eq '' || $parent =~ /\A[A-Za-z]:\z/;
        }
        last unless defined $parent && length $parent && $parent ne $p;
        push @out, $parent;
        $p = $parent;
    }
    return @out;
}

# Directories up to $depth levels under $p, breadth-first. Symlinked
# directories are not followed: a link elsewhere is not part of what the
# launch target physically contains, and following links invites loops.
sub _descendants {
    my ($p, $depth) = @_;
    my @out;
    my @frontier = ($p);
    for (1 .. $depth) {
        my @next;
        for my $d (@frontier) {
            opendir my $dh, $d or next;
            my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
            closedir $dh;
            for my $n (sort @names) {
                my $c = $d eq '/' || $d =~ m{/\z} ? "$d$n" : "$d/$n";
                next if -l $c;
                push @next, $c if -d $c;
            }
        }
        push @out, @next;
        @frontier = @next;
    }
    return @out;
}

# find_refusal($target, \%opts) -> undef | {
#     marker => $marker_file, dir => $marked_dir,
#     relation => 'here'|'above'|'below', message => $str }
#
# Returns the first marker (here, then nearest ancestor, then shallowest
# descendant) that does not allow this launcher. A marker that allows the
# launcher is skipped, and the search continues: allowing one marker never
# lets a launcher past a different one.
#
# %opts: launcher_id (default $LAUNCHER_ID), scan_depth (default $SCAN_DEPTH).
sub find_refusal {
    my ($target, $opts) = @_;
    $opts ||= {};
    my $id    = lc($opts->{launcher_id} // $LAUNCHER_ID);
    my $depth = $opts->{scan_depth} // $SCAN_DEPTH;
    return undef unless defined $target && length $target;
    $target = _norm($target);

    my @where = (
        (map { [ $_, 'here'  ] } $target),
        (map { [ $_, 'above' ] } _ancestors($target)),
        (map { [ $_, 'below' ] } _descendants($target, $depth)),
    );
    for my $w (@where) {
        my ($dir, $relation) = @$w;
        my $file = _marker_in($dir) or next;
        my $m = parse_marker(_read_marker($file));
        next if grep { $_ eq $id } @{ $m->{allow} };
        return {
            marker   => $file,
            dir      => $dir,
            relation => $relation,
            message  => $m->{message},
        };
    }
    return undef;
}

# refusal_message($hit, $target, $launcher_id) -> printable text
sub refusal_message {
    my ($hit, $target, $id) = @_;
    $id //= $LAUNCHER_ID;
    my %why = (
        here  => 'this directory carries a refusal marker',
        above => 'a directory above it carries a refusal marker',
        below => 'a directory inside it carries a refusal marker',
    );
    my $msg = length($hit->{message} // '')
        ? $hit->{message}
        : 'The marker gives no reason. Read or remove the marker file to find out who placed it and why.';
    return "$id will not run here:\n\n"
         . "  $target\n\n"
         . "because $why{ $hit->{relation} }:\n\n"
         . "  $hit->{marker}\n\n"
         . "$msg\n\n"
         . "Aborting.";
}

1;
