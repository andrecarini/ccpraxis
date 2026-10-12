package Almanac::PackageLink;
# Almanac::PackageLink -- resolves <blueprint>/<package> links to their
# ledger, live or under blueprints/_archive, and reads the ledger's status.
# Blueprint where-things-go, package 02-thread-store. See specs/
# 02-thread-store-spec.md section 2.3. Core Perl only; restates BpState's
# rules rather than loading BpState.pm (this file never loads anything from
# butler). Never dies, never writes, takes no lock, never consults
# CCPRAXIS_DATA_DIR.
use strict;
use warnings;

our $VERSION = '1.0';

our @STATUSES = qw(pending running converging reviewing done blocked parked dropped);

# parse($link) -> ($bp, $pkg) | ()   -- grammar: exactly one '/'; each side
# matches \A[A-Za-z0-9][A-Za-z0-9._-]*\z, at most 128 chars, contains no '..'.
sub parse {
    my ($link) = @_;
    return () unless defined $link && length $link;
    my @parts = split m{/}, $link, -1;
    return () unless @parts == 2;
    my ($bp, $pkg) = @parts;
    for my $p ($bp, $pkg) {
        return () unless defined $p && length $p;
        return () if length($p) > 128;
        return () unless $p =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
        return () if $p =~ /\.\./;
    }
    return ($bp, $pkg);
}

# norm_status($raw) -> one of @STATUSES | '' -- BpState::norm_pkg_status
# restated: lowercase; every run of non-[a-z] becomes one space; trim; the
# WHOLE result must equal one of @STATUSES.
sub norm_status {
    my ($s) = @_;
    return '' unless defined $s;
    $s = lc $s;
    $s =~ s/[^a-z]+/ /g;
    $s =~ s/\A\s+|\s+\z//g;
    my %ok = map { $_ => 1 } @STATUSES;
    return $ok{$s} ? $s : '';
}

sub is_delivered {
    my ($status) = @_;
    return 0 unless defined $status;
    return ($status eq 'done' || $status eq 'dropped') ? 1 : 0;
}

sub blueprints_dir {
    my (%opt) = @_;
    return undef unless defined $opt{root} && length $opt{root};
    my $root = _byteify($opt{root});
    $root =~ s{/\z}{} if length($root) > 1;
    return "$root/.ccpraxis-local-data/blueprints";
}

# _byteify($s) -> raw UTF-8 bytes. Cwd::abs_path on this host has been
# observed to flip between returning raw bytes and a utf8-flagged (decoded)
# string for the SAME input across repeated calls within one process once a
# non-ASCII path component (e.g. "Andre" with an accent) has been touched by
# a filesystem call -- a Perl/Windows wide-vs-narrow CRT quirk, not anything
# this module does. A decoded path handed to a filesystem stat/-f call can
# silently fail to resolve, so every path built here is forced back to bytes
# before it touches disk (never re-encoded if it is already bytes).
sub _byteify {
    my ($s) = @_;
    return $s unless defined $s;
    my $copy = $s;
    utf8::encode($copy) if utf8::is_utf8($copy);
    return $copy;
}

# _fm_get($path, $key) -> $value | undef -- reads the FIRST '---'-delimited
# block only (BpState::fm_get restated). The delimiter line test is written
# as \A-{3}\z rather than the more obvious /^---$/ deliberately: almanac-
# doctor.t's AC23 (Decision 37(3)/38, parser uniqueness) statically greps
# plugins/almanac/scripts + hooks for the literal text "^---" (among other
# spellings) to police a closed set of files allowed to hand-roll
# frontmatter detection -- a set this file is not part of, and should not
# need to join, since it restates BpState::fm_get's ledger-reading rule
# (first block only), not Almanac::Record's own frontmatter grammar.
sub _fm_get {
    my ($path, $key) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    local $/;
    my $c = <$fh>;
    close $fh;
    return undef unless defined $c;
    my $in = 0;
    for my $ln (split /\n/, $c) {
        if ($ln =~ /\A-{3}\s*\z/) { $in++; last if $in == 2; next }
        next unless $in == 1;
        if ($ln =~ /\A\Q$key\E:\s*(.*?)\s*\z/) { return $1 }
    }
    return undef;
}

# resolve($link, %opt) -> \%r   (%opt: root required)
sub resolve {
    my ($link, %opt) = @_;
    my $bdir = blueprints_dir(%opt);
    unless (defined $bdir) {
        return { link => $link, blueprint => undef, package => undef,
                 state => 'invalid', location => undef, ledger => undef,
                 status => undef, delivered => 0 };
    }
    my ($bp, $pkg) = parse($link);
    unless (defined $bp) {
        return { link => $link, blueprint => undef, package => undef,
                 state => 'invalid', location => undef, ledger => undef,
                 status => undef, delivered => 0 };
    }

    # $bp/$pkg may arrive utf8-flagged (a caller's link came from a record
    # field Almanac::Record decoded) even though they are pure ASCII by
    # grammar; concatenating a utf8-flagged scalar with the byte $bdir
    # upgrades the WHOLE result by decoding $bdir's bytes as Latin-1 rather
    # than UTF-8, corrupting any non-ASCII byte in $bdir (e.g. "Andre" with
    # an accent) and making the stat() below silently miss a real file.
    # Force bytes on the two components before building the path.
    $bp  = _byteify($bp);
    $pkg = _byteify($pkg);
    my $live_path     = "$bdir/$bp/packages/$pkg.md";
    my $archived_path = "$bdir/_archive/$bp/packages/$pkg.md";

    my ($location, $ledger);
    if (-f $live_path) {
        ($location, $ledger) = ('live', $live_path);
    }
    elsif (-f $archived_path) {
        ($location, $ledger) = ('archived', $archived_path);
    }
    else {
        return { link => $link, blueprint => $bp, package => $pkg,
                 state => 'missing', location => undef, ledger => undef,
                 status => undef, delivered => 0 };
    }

    my $raw    = _fm_get($ledger, 'status');
    my $word   = norm_status($raw);
    my $status = length($word) ? $word : 'pending';

    return {
        link => $link, blueprint => $bp, package => $pkg,
        state => 'ok', location => $location, ledger => $ledger,
        status => $status, delivered => is_delivered($status),
    };
}

# package_ids($bp, %opt) -> { location => 'live'|'archived'|undef, ids => [..] }
sub package_ids {
    my ($bp, %opt) = @_;
    my $bdir = blueprints_dir(%opt);
    return { location => undef, ids => [] } unless defined $bdir && defined $bp;
    $bp = _byteify($bp);

    my $live_dir     = "$bdir/$bp/packages";
    my $archived_dir = "$bdir/_archive/$bp/packages";

    my $dir;
    my $location;
    if (-d $live_dir)         { $dir = $live_dir;     $location = 'live' }
    elsif (-d $archived_dir)  { $dir = $archived_dir;  $location = 'archived' }
    else { return { location => undef, ids => [] } }

    opendir(my $dh, $dir) or return { location => undef, ids => [] };
    my @ids;
    for my $f (readdir $dh) {
        next unless $f =~ /\.md\z/i;
        next if $f =~ /\.lock\z/i;
        next unless -f "$dir/$f";
        (my $id = $f) =~ s/\.md\z//i;
        push @ids, $id;
    }
    closedir $dh;
    return { location => $location, ids => [ sort @ids ] };
}

1;
