#!/usr/bin/env perl
# platform: any
# A non-ASCII bug title reaches the sitrep as UTF-8 once, never twice.
#
# Measured 2026-10-31: the sitrep printed bug 20260826-121852-3570's title "... indefinitely —
# continuity gate ..." as "... indefinitely â continuity gate ...". Gather's bug section carried
# the title as raw UTF-8 bytes (AlmanacBug::load) while every other section carries decoded
# characters; the report is encoded once at output, so as soon as any other line held a non-ASCII
# character the bug title's bytes were upgraded and encoded a second time: E2 80 94 became
# C3 A2 C2 80 C2 94.
#
# A throwaway project gets one bug with an em dash (filed through almanac-bug.pl, the only
# sanctioned writer) and one todo with an e-acute, then the real sitrep runs against it.
use strict;
use warnings;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use File::Spec ();
use Test::More;

(my $S = "$Bin/../../scripts") =~ s{\\}{/}g;
my $ROOT = tempdir(CLEANUP => 1); $ROOT =~ s{\\}{/}g;
my $HOME = tempdir(CLEANUP => 1); $HOME =~ s{\\}{/}g;
local $ENV{HOME} = $HOME;
local $ENV{USERPROFILE} = $HOME;

my $DASH = "\xe2\x80\x94";      # U+2014 as UTF-8 bytes
my $EACUTE = "\xc3\xa9";        # U+00E9 as UTF-8 bytes

sub run_in {
    my ($dir, $stdin, @cmd) = @_;
    my $pid = open(my $kid, '|-') // die "fork: $!";
    if (!$pid) {
        chdir $dir or die "chdir: $!";
        open(STDOUT, '>', File::Spec->devnull) or die "devnull: $!";
        exec(@cmd) or die "exec: $!";
    }
    print {$kid} $stdin; close $kid;
    return $? >> 8;
}

is(run_in($ROOT, "body\n", $^X, "$S/almanac-bug.pl", 'file', '--project', $ROOT,
          '--title', "gate exists $DASH but is opt-in", '--severity', 'low', '--area', 'butler', '--body', '-'),
   0, 'fixture: bug filed');

sub sitrep {
    my $out = `"$^X" "$S/almanac-sitrep.pl" project --root "$ROOT" --no-refresh --no-snapshot 2>&1`;
    return $out;
}

my ($line) = grep { /opt-in/ } split /\n/, sitrep();
ok(defined $line, 'the bug is listed');
like($line // '', qr/exists \Q$DASH\E but/, 'bug title alone: the em dash is one UTF-8 sequence');

is(run_in($ROOT, "x\n", $^X, "$S/almanac.pl", 'todo', 'create', '--title', "caf$EACUTE todo", '--body', '-'),
   0, 'fixture: a todo with a non-ASCII title');

my $out = sitrep();
($line) = grep { /opt-in/ } split /\n/, $out;
like($out, qr/caf\Q$EACUTE\E todo/, 'the todo title is intact');
like($line // '', qr/exists \Q$DASH\E but/, 'THE BUG: next to a non-ASCII todo, the bug title is still encoded once');
unlike($line // '', qr/\xc3\xa2\xc2\x80\xc2\x94/, 'and never as the double-encoded C3 A2 C2 80 C2 94');

done_testing();
