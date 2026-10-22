#!/usr/bin/env perl
# almanac-gather.pl -- CLI wrapper over Almanac::Gather (blueprint
# where-things-go, package 10-gatherer-and-digest, spec sec 2.4). Prints one
# JSON line (project or all mode) or the rendered digest text.
use strict;
use warnings;
use Cwd ();
use JSON::PP ();

BEGIN {
    my $self = __FILE__;
    $self =~ s{\\}{/}g;
    $self = Cwd::abs_path($self) // $self;
    $self =~ s{\\}{/}g;
    my $dir = $self;
    $dir =~ s{/[^/]+\z}{};
    $dir = '.' unless length $dir;
    unshift @INC, $dir unless grep { $_ eq $dir } @INC;
}

use Almanac::Gather ();

sub _usage_die {
    print STDERR "usage: almanac-gather.pl [--all] [--root DIR] [--since ISO] [--no-refresh] "
               . "[--section NAME]... [--digest]\n";
    exit 2;
}

my (@sections, $all_mode, $root, $since, $no_refresh, $digest_mode);
my @args = @ARGV;
while (@args) {
    my $a = shift @args;
    if    ($a eq '--all')        { $all_mode   = 1 }
    elsif ($a eq '--root')       { $root       = shift @args; _usage_die() unless defined $root }
    elsif ($a eq '--since')      { $since      = shift @args; _usage_die() unless defined $since }
    elsif ($a eq '--no-refresh') { $no_refresh = 1 }
    elsif ($a eq '--section')    { my $s = shift @args; _usage_die() unless defined $s; push @sections, $s }
    elsif ($a eq '--digest')     { $digest_mode = 1 }
    else                         { _usage_die() }
}

_usage_die() if $digest_mode && ($all_mode || @sections);

my $rc = 0;
eval {
    if ($digest_mode) {
        my %dopt;
        $dopt{root} = $root if defined $root;
        my $text = Almanac::Gather::digest(%dopt);
        print "$text\n" if length $text;
    } else {
        my %opt = (mode => ($all_mode ? 'all' : 'project'));
        $opt{root}     = $root  if defined $root;
        $opt{since}    = $since if defined $since;
        $opt{sections} = \@sections if @sections;
        $opt{refresh}  = 0 if $no_refresh;
        my $r = Almanac::Gather::gather(%opt);
        print JSON::PP->new->utf8->canonical->encode($r), "\n";
    }
    1;
} or do {
    my $err = $@;
    $err = "$err";
    $err =~ s/\s+\z//;
    $err =~ s/[\r\n]+/ /g;
    print JSON::PP->new->utf8->encode({ error => $err }), "\n";
    $rc = 1;
};
exit $rc;
