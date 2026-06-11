#!/usr/bin/perl
# Semantic JSON diff — compares two JSON files ignoring key order/whitespace.
# Outputs a structured JSON report of all differences.
#
# Usage: perl json-diff.pl [--exclude key,...] [--deep-exclude key,...] left.json right.json
#
# --exclude        Remove these top-level keys before comparing
# --deep-exclude   Recursively remove these keys from all nested objects before comparing
#
# Exit codes: 0 = identical, 1 = different, 2 = error
use strict;
use warnings;
use JSON::PP;
use Getopt::Long;

my (@exclude, @deep_exclude);
GetOptions(
    'exclude=s'      => sub { push @exclude,      split /,/, $_[1] },
    'deep-exclude=s' => sub { push @deep_exclude, split /,/, $_[1] },
) or exit 2;

unless (@ARGV == 2) {
    print STDERR "Usage: $0 [--exclude key,...] [--deep-exclude key,...] left.json right.json\n";
    exit 2;
}

my $pretty    = JSON::PP->new->pretty->canonical;
my $canonical = JSON::PP->new->canonical;

sub read_json {
    open my $fh, '<', $_[0] or do { print STDERR "Cannot open $_[0]: $!\n"; exit 2 };
    local $/;
    return decode_json(<$fh>);
}

my ($left_path, $right_path) = @ARGV;
my $left  = read_json($left_path);
my $right = read_json($right_path);

# Remove top-level excluded keys
for my $k (@exclude) {
    delete $left->{$k};
    delete $right->{$k};
}

# Recursively strip deep-excluded keys from all nested objects
if (@deep_exclude) {
    my $strip;
    $strip = sub {
        my $obj = shift;
        return unless ref $obj eq 'HASH';
        delete $obj->{$_} for @deep_exclude;
        $strip->($_) for values %$obj;
    };
    $strip->($left);
    $strip->($right);
}

my %all_keys;
$all_keys{$_} = 1 for keys %$left, keys %$right;

my (@identical, %only_left, %only_right, %diverged);

for my $k (sort keys %all_keys) {
    my $in_left  = exists $left->{$k};
    my $in_right = exists $right->{$k};

    if ($in_left && !$in_right) {
        $only_left{$k} = $left->{$k};
    } elsif (!$in_left && $in_right) {
        $only_right{$k} = $right->{$k};
    } elsif ($canonical->encode($left->{$k}) eq $canonical->encode($right->{$k})) {
        push @identical, $k;
    } else {
        # Both keys exist with different values
        if (ref($left->{$k}) eq 'HASH' && ref($right->{$k}) eq 'HASH') {
            # Expand one level: compare sub-keys individually.
            # Uses "parent.child" dotted notation. If a top-level key already
            # contains a dot, it could collide with an expanded sub-key — warn
            # and skip expansion to avoid silent data corruption.
            my %sub_keys;
            $sub_keys{$_} = 1 for keys %{$left->{$k}}, keys %{$right->{$k}};
            my $has_collision = 0;
            for my $sk (keys %sub_keys) {
                if (exists $all_keys{"$k.$sk"}) {
                    print STDERR "Warning: dotted key collision between top-level '$k.$sk' and expanded '$k'.'$sk' — skipping expansion of '$k'\n";
                    $has_collision = 1;
                    last;
                }
            }
            if ($has_collision) {
                $diverged{$k} = { left => $left->{$k}, right => $right->{$k} };
            } else {
            for my $sk (sort keys %sub_keys) {
                my $dotted = "$k.$sk";
                my $in_l = exists $left->{$k}{$sk};
                my $in_r = exists $right->{$k}{$sk};
                if ($in_l && !$in_r) {
                    $only_left{$dotted} = $left->{$k}{$sk};
                } elsif (!$in_l && $in_r) {
                    $only_right{$dotted} = $right->{$k}{$sk};
                } elsif ($canonical->encode($left->{$k}{$sk}) eq $canonical->encode($right->{$k}{$sk})) {
                    push @identical, $dotted;
                } else {
                    $diverged{$dotted} = { left => $left->{$k}{$sk}, right => $right->{$k}{$sk} };
                }
            }
            }
        } else {
            $diverged{$k} = { left => $left->{$k}, right => $right->{$k} };
        }
    }
}

my $different = %only_left || %only_right || %diverged;

print $pretty->encode({
    status        => $different ? "different" : "identical",
    left          => $left_path,
    right         => $right_path,
    excluded      => \@exclude,
    deep_excluded => \@deep_exclude,
    identical     => \@identical,
    only_left     => \%only_left,
    only_right    => \%only_right,
    diverged      => \%diverged,
});

exit($different ? 1 : 0);
