#!/usr/bin/env perl
# ccpraxis-install.pl - almanac plugin install hook: ensures ~/.claude/almanac-notes.md exists.
# See specs/12-migrate-memories-spec.md §2.8 for the full contract. Same shape as
# plugins/steward/ccpraxis-install.pl, picked up by install.pl's plugins/* glob with no
# registration anywhere.
#
# Usage: perl ccpraxis-install.pl <plan|apply> [--home H]
#   plan   (default) -- describe what would change; writes nothing.
#   apply  -- create an empty ~/.claude/almanac-notes.md stub if it is absent. Never touches an
#             existing file's bytes, and never opens/reads/writes any other tracked or installed doc.
use strict;
use warnings;
use File::Spec ();

sub _resolve_home {
    my ($opt_home) = @_;
    return $opt_home if defined $opt_home && length $opt_home;
    for my $k (qw(ALMANAC_HOME HOME USERPROFILE)) {
        return $ENV{$k} if defined $ENV{$k} && length $ENV{$k};
    }
    return '.';
}

sub _parse_args {
    my (@argv) = @_;
    my $mode = 'plan';
    my %o;
    my @pos;
    while (@argv) {
        my $a = shift @argv;
        if ($a eq '--home') {
            my $has_val = @argv && $argv[0] !~ /^--/;
            unless ($has_val) {
                print STDERR "usage: ccpraxis-install.pl <plan|apply> [--home H]\n";
                exit 2;
            }
            $o{home} = shift @argv;
        } elsif ($a =~ /^--/) {
            print STDERR "usage: ccpraxis-install.pl <plan|apply> [--home H]\n";
            exit 2;
        } else {
            push @pos, $a;
        }
    }
    if (@pos) {
        $mode = shift @pos;
    }
    if (@pos || ($mode ne 'plan' && $mode ne 'apply')) {
        print STDERR "usage: ccpraxis-install.pl <plan|apply> [--home H]\n";
        exit 2;
    }
    return ($mode, \%o);
}

unless (caller) {
    my ($mode, $o) = _parse_args(@ARGV);
    my $home = _resolve_home($o->{home});
    $home =~ s{\\}{/}g;
    $home =~ s{/\z}{} if length($home) > 1;

    my $claude_dir = "$home/.claude";
    my $target     = "$claude_dir/almanac-notes.md";

    unless (-d $claude_dir) {
        print "almanac-notes: skipped (no ~/.claude yet)\n";
        exit 0;
    }

    if (-e $target) {
        if ($mode eq 'plan') {
            print "almanac-notes: present <$target>\n";
        } elsif ($mode eq 'apply') {
            print "almanac-notes: present <$target>\n";
        }
        exit 0;
    }

    if ($mode eq 'plan') {
        print "almanac-notes: would create empty stub <$target>\n";
        exit 0;
    }

    # apply: create a zero-byte stub. Never deletes, never rewrites an
    # existing file (checked, above).
    if (open(my $fh, '>:raw', $target)) {
        close($fh);
        print "almanac-notes: created empty stub <$target>\n";
        exit 0;
    } else {
        print STDERR "almanac-notes: FAILED <$target>: $!\n";
        exit 2;
    }
}

1;
