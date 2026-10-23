#!/usr/bin/env perl
# bp-disarm-digest.pl <project_root> -- the evidence digest bp-judge-disarm.sh
# hands the disarm judge in its prompt.
#
# The judge used to discover all of this itself with Read/Grep/Glob and four
# allowlisted commands. On ccpraxis (three blueprints, long histories) that
# took more than its whole time bound twice in a row, so no agent could
# disarm at all (bug 20261023-130606-a417). Gathering the same facts here
# costs about a second, and leaves the judge to weigh them instead of
# collecting them.
#
# Read-only. Reads the project's own stores straight from disk (bug reports,
# todos, inbox, blueprint ledgers) plus `git status` and `git log`. Prints
# plain text sections, each capped so the prompt stays bounded. Never dies:
# a section it cannot read says so, and the judge can still look itself.
use strict;
use warnings;

$ENV{MSYS2_ARG_CONV_EXCL} = '*' if $^O =~ /^(MSWin32|cygwin|msys)$/;

use constant CAP => 20;

my $root = shift @ARGV;
unless (defined $root && length $root && -d $root) {
    print "digest unavailable: project root is not a directory\n";
    exit 0;
}
$root =~ s{\\}{/}g;
my $data = "$root/.ccpraxis-local-data";

# frontmatter($path) -> { key => value } for the leading --- block.
sub frontmatter {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or return undef;
    my $first = <$fh>;
    unless (defined $first && $first =~ /^---\s*$/) { close $fh; return {} }
    my %fm;
    while (my $l = <$fh>) {
        last if $l =~ /^---\s*$/;
        $fm{$1} = $2 if $l =~ /^([A-Za-z_][\w-]*):\s*(.*?)\s*$/;
    }
    close $fh;
    return \%fm;
}

sub md_files {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return ();
    my @f = sort grep { /\.md\z/ && -f "$dir/$_" } readdir $dh;
    closedir $dh;
    return map { "$dir/$_" } @f;
}

sub section {
    my ($title, @lines) = @_;
    my $n = scalar @lines;
    print "## $title ($n)\n";
    if (!$n) { print "  none\n\n"; return }
    my @shown = @lines > CAP ? @lines[0 .. CAP - 1] : @lines;
    print "  $_\n" for @shown;
    print "  ... and " . ($n - CAP) . " more\n" if $n > CAP;
    print "\n";
}

# Store records whose status is in %$want, as "<id> [<status>] <title>".
sub open_records {
    my ($dir, $want) = @_;
    return undef unless -d $dir;
    my @out;
    for my $f (md_files($dir)) {
        my $fm = frontmatter($f) or next;
        my $st = $fm->{status} // '';
        next unless $want->{$st};
        (my $id = $f) =~ s{.*/}{};
        $id =~ s/\.md\z//;
        push @out, "$id [$st] " . ($fm->{title} // '');
    }
    return \@out;
}

print "Evidence digest, gathered from disk by bp-disarm-digest.pl at "
    . scalar(gmtime()) . " UTC. Trust it as disk state; the stopping agent did not write it.\n\n";

for my $s (
    [ 'Open bug reports', "$data/bug-reports",   { map { $_ => 1 } qw(open triaging scheduled) } ],
    [ 'Open todos',       "$data/almanac/todo",  { open => 1 } ],
    [ 'Unanswered inbox items (questions waiting on the operator)', "$data/almanac/inbox", { unanswered => 1 } ],
) {
    my ($title, $dir, $want) = @$s;
    my $recs = open_records($dir, $want);
    if (defined $recs) { section($title, @$recs) }
    else { print "## $title\n  no store at $dir\n\n" }
}

# Blueprints: lifecycle from blueprint.md, package statuses from the ledgers.
{
    my @lines;
    my $bdir = "$data/blueprints";
    if (opendir(my $dh, $bdir)) {
        for my $bp (sort grep { !/^\./ && -f "$bdir/$_/blueprint.md" } readdir $dh) {
            my $life = '?';
            if (open(my $fh, '<:raw', "$bdir/$bp/blueprint.md")) {
                while (my $l = <$fh>) { if ($l =~ /^status:\s*(\S+)/) { $life = $1; last } }
                close $fh;
            }
            my (%count, @live);
            for my $f (md_files("$bdir/$bp/packages")) {
                my $fm = frontmatter($f) or next;
                my $st = $fm->{status} // 'unknown';
                $count{$st}++;
                (my $pkg = $f) =~ s{.*/}{};
                $pkg =~ s/\.md\z//;
                push @live, "$pkg=$st" unless $st =~ /\A(?:done|dropped)\z/;
            }
            my $counts = join(', ', map { "$count{$_} $_" } sort keys %count) || 'no packages';
            push @lines, "$bp [$life]: $counts" . (@live ? "; not finished: " . join(', ', @live) : '');
        }
        closedir $dh;
    }
    section('Blueprints', @lines);
}

# Git: uncommitted paths and the latest commits.
{
    my @st = `git -C "$root" status --porcelain 2>&1`;
    chomp @st;
    if ($? == 0) { section('git status --porcelain (uncommitted paths)', @st) }
    else { print "## git status\n  unavailable\n\n" }
    my @log = `git -C "$root" log --oneline -8 2>&1`;
    chomp @log;
    section('git log --oneline -8', $? == 0 ? @log : ('unavailable'));
}
exit 0;
