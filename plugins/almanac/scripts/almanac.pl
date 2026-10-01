#!/usr/bin/env perl
# almanac.pl -- the almanac dispatcher (blueprint almanac-records, package
# 17-doctor-and-cli). See specs/17-doctor-and-cli-spec.md section 2.1.
#
# `almanac <type> <verb> [rest...]` validates <type> and <verb> against a
# static route table and then spawns the matching type script in a fresh
# process, list-form, no shell -- so a path with spaces or non-ASCII
# characters is never re-tokenized. `almanac doctor [rest...]` takes no verb
# and spawns almanac-doctor.pl with the remaining args unchanged.
#
# This dispatcher prints nothing of its own on a successful route: its whole
# job is to get argv to the right child unchanged and hand back that child's
# exit code, so a caller of `almanac todo list` sees byte-identical output to
# calling `almanac-todo.pl list` directly (AC1).
package Almanac::CLI;
use strict;
use warnings;

my $DIR;
BEGIN {
    $DIR = __FILE__;
    $DIR =~ s{\\}{/}g;
    # A bare filename (no '/' at all -- invoked as `perl almanac.pl ...` from
    # inside the scripts directory) has nothing for s{/[^/]+\z}{} to match,
    # which would otherwise leave $DIR equal to the script's own name.
    $DIR = ($DIR =~ m{/}) ? ($DIR =~ s{/[^/]+\z}{}r) : '.';
}

# routes() -> \%table -- pure, no I/O. The verb lists are the closed sets
# documented in each type script's own %VERBS (todo/note/task/decision) or
# $cmd eq chain (bug), restated here rather than derived at runtime so this
# sub has no dependency on those scripts even loading cleanly.
sub routes {
    return {
        todo     => { script => 'almanac-todo.pl',
                      verbs  => [qw(create list show edit complete reopen delete count)] },
        note     => { script => 'almanac-note.pl',
                      verbs  => [qw(create list show edit promote delete check-pointers)] },
        task     => { script => 'almanac-task.pl',
                      verbs  => [qw(add insert-at insert-before insert-after move-first
                                    move-last reorder status edit list show focus focused
                                    unfocus)] },
        decision => { script => 'almanac-decision.pl',
                      verbs  => [qw(file list show answer blocks)] },
        bug      => { script => 'almanac-bug.pl',
                      verbs  => [qw(file append update set-status takeover list collect verify)] },
        doctor   => { script => 'almanac-doctor.pl', verbs => undef },
    };
}

sub _types_line {
    my ($routes) = @_;
    return 'almanac types: ' . join(' ', sort keys %$routes) . "\n";
}

# _spawn($script, @args) -> $exit_code
#
# One `system` call, list form, no shell -- a caller-supplied path/argument
# containing spaces or non-ASCII characters reaches the child unchanged. This
# dispatcher inherits STDIN/STDOUT/STDERR and prints nothing of its own on a
# valid route (AC1's byte-for-byte requirement depends on that).
sub _spawn {
    my ($script, @args) = @_;
    my $path = "$DIR/$script";
    system($^X, $path, @args);
    if ($? == -1) {
        print STDERR "almanac: could not run $script: $!\n";
        return 2;
    }
    my $sig = $? & 127;
    if ($sig) {
        print STDERR "almanac: $script terminated by signal $sig\n";
        return 2;
    }
    return $? >> 8;
}

# run(@argv) -> $exit_code -- the whole dispatch decision, in one place, so
# main() below is just `exit run(@ARGV)`.
sub run {
    my (@argv) = @_;
    my $routes = routes();

    my $type = $argv[0];
    if (!defined $type || !length $type) {
        print STDERR "almanac: missing type\n";
        print STDERR _types_line($routes);
        return 2;
    }
    unless (exists $routes->{$type}) {
        print STDERR "almanac: unknown type '$type'\n";
        print STDERR _types_line($routes);
        return 2;
    }

    my $route = $routes->{$type};

    if (!defined $route->{verbs}) {
        # doctor: no verb, the rest passes through unchanged.
        my @rest = @argv[1 .. $#argv];
        return _spawn($route->{script}, @rest);
    }

    my $verb = $argv[1];
    if (!defined $verb || $verb =~ /\A--/) {
        print STDERR "almanac: missing verb for 'almanac $type'\n";
        print STDERR "almanac $type verbs: " . join(' ', @{ $route->{verbs} }) . "\n";
        return 2;
    }
    unless (grep { $_ eq $verb } @{ $route->{verbs} }) {
        print STDERR "almanac: unknown verb '$verb' for 'almanac $type'\n";
        print STDERR "almanac $type verbs: " . join(' ', @{ $route->{verbs} }) . "\n";
        return 2;
    }

    my @rest = @argv[2 .. $#argv];
    return _spawn($route->{script}, $verb, @rest);
}

unless (caller) {
    exit run(@ARGV);
}

1;
