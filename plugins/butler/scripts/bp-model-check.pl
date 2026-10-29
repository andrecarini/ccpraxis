#!/usr/bin/env perl
# bp-model-check.pl -- audit a blueprint's package ledgers for an unsupported
# model:/effort: frontmatter value (04-model-effort-ledger-validation).
#
# `bp-ledger.pl create` refuses an unsupported model:/effort: at creation time,
# and guard-blueprint-write.sh denies the hand-written path that would skip it.
# Neither can see a ledger that PREDATES this package or one that arrived
# through the guard's escape hatch -- this script is the defense-in-depth
# backstop for exactly those two populations (D-C). It mirrors bp-checks.pl's
# CLI/exit-code/output conventions on purpose, so the bp-auditor.md hunt-list
# item reads as a sibling of the existing `bp-checks.pl audit` item rather than
# a new pattern.
#
# Core Perl only. `package BpModelCheck;` with a bare `unless (caller)` main
# block (mirrors bp-checks.pl:177) -- requirable as a module without running
# the CLI, so another perl process can pull @MODELS/@EFFORTS (model-effort-
# check.t's AC-17 does exactly this, by PARSING the source, never by
# re-hardcoding the sets a second time).
#
# perl plugins/butler/scripts/bp-model-check.pl audit --blueprint <blueprint.md> [--packages-dir DIR]
#
# Exit 0: clean, one stdout summary line. Exit 1: at least one ledger carries an
# unsupported value, one stderr line per offender. Exit 2: usage/IO error.
#
# ABSENCE IS NOT A PROBLEM (D-A / bp-launch.sh:49-50,67-69). An absent model:
# defaults to sonnet; an absent effort: is an opt-out that passes no --effort
# flag at all. Flagging absence would report every ledger that deliberately
# takes the default -- this audits VALUES, it is not a second `validate`.
use strict;
use warnings;

package BpModelCheck;

use File::Basename ();
use File::Spec ();

# D-A/D-B: DUPLICATED, deliberately, from bp-ledger.pl's @MODELS/@EFFORTS --
# bp-ledger.pl loads core Perl only and cannot `require` this file. model-
# effort-check.t's AC-17 pins the two copies (plus bp-launch.sh's effort case
# arm) together by parsing the sources, so a drift is a test failure.
our @MODELS  = qw(sonnet opus haiku);
our @EFFORTS = qw(low medium high xhigh max);

# Raw UTF-8 bytes for an em dash -- same approach as bp-ledger.pl's $EMDASH
# (no `use utf8` in this file, so this is written as the literal byte string).
my $EMDASH = "\xE2\x80\x94";

sub _slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# Extract the frontmatter block (\A---...---), byte-wise, exactly the anchor
# bp-ledger.pl's validate_bytes() V2 uses. Returns undef if there is none.
sub _frontmatter {
    my ($text) = @_;
    return undef unless defined $text;
    my ($fm) = $text =~ /\A---\s*\n(.*?)\n---[ \t]*(?:\n|\z)/s;
    return $fm;
}

# check_text($text) -> ($model_problem, $effort_problem), each undef-or-string.
# Reads the FRONTMATTER block only -- a line below the closing `---` (i.e. in
# the body) is never read (B-46). Pure: no I/O, no exit, no warn.
sub check_text {
    my ($text) = @_;
    my $fm = _frontmatter($text);
    return (undef, undef) unless defined $fm;

    my ($model, $effort);
    for my $l (split(/\n/, $fm, -1)) {
        if (!defined $model && $l =~ /^model:\s*(.*?)\s*$/) { $model = $1 }
        if (!defined $effort && $l =~ /^effort:\s*(.*?)\s*$/) { $effort = $1 }
    }

    my $model_problem;
    if (defined $model && length $model && !grep { $_ eq $model } @MODELS) {
        $model_problem = "model \"$model\" is not a supported model; allowed values: "
                        . join(', ', @MODELS);
    }
    my $effort_problem;
    if (defined $effort && length $effort && !grep { $_ eq $effort } @EFFORTS) {
        $effort_problem = "effort \"$effort\" is not a supported effort; allowed values: "
                         . join(', ', @EFFORTS);
    }
    return ($model_problem, $effort_problem);
}

package main;

unless (caller) {
    my $verb = shift(@ARGV) // '';
    my %opt;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a =~ /^--blueprint=(.*)$/)     { $opt{blueprint} = $1 }
        elsif ($a eq '--blueprint')            { $opt{blueprint} = shift @ARGV }
        elsif ($a =~ /^--packages-dir=(.*)$/)  { $opt{pkgdir}    = $1 }
        elsif ($a eq '--packages-dir')         { $opt{pkgdir}    = shift @ARGV }
        else { print STDERR "bp-model-check: unrecognised argument '$a'\n"; exit 2 }
    }

    unless ($verb eq 'audit' && defined $opt{blueprint}) {
        print STDERR "usage: bp-model-check.pl audit --blueprint <blueprint.md> [--packages-dir DIR]\n";
        exit 2;
    }

    my $bp_text = BpModelCheck::_slurp($opt{blueprint});
    unless (defined $bp_text) {
        print STDERR "bp-model-check: cannot read $opt{blueprint}\n";
        exit 2;
    }

    # Normalise separators BEFORE dirname (bp-checks.pl:217-224's precedent):
    # a Windows backslash --blueprint path defeats File::Basename::dirname,
    # which returns '.' and silently roots the lookup at the CWD.
    my $pkgdir = $opt{pkgdir}
        // do {
            (my $bp = $opt{blueprint}) =~ s{\\}{/}g;
            File::Spec->catdir(File::Basename::dirname($bp), 'packages');
        };
    unless (-d $pkgdir) {
        print STDERR "bp-model-check: packages dir not found: $pkgdir\n";
        exit 2;
    }

    opendir(my $dh, $pkgdir) or do {
        print STDERR "bp-model-check: cannot read $pkgdir: $!\n";
        exit 2;
    };
    my @ledgers = sort grep { /\.md\z/i } readdir $dh;
    closedir $dh;

    my @problems;
    for my $l (@ledgers) {
        my $text = BpModelCheck::_slurp("$pkgdir/$l") // next;   # unreadable -> skip, not fatal
        my $fm   = BpModelCheck::_frontmatter($text) // next;    # no frontmatter -> skip, not fatal
        my ($pkg) = $fm =~ /^package:\s*(.*?)\s*$/m;
        $pkg = $l unless defined $pkg && length $pkg;

        my ($model_problem, $effort_problem) = BpModelCheck::check_text($text);
        my @f;
        push @f, { field => 'model',  detail => $model_problem }  if defined $model_problem;
        push @f, { field => 'effort', detail => $effort_problem } if defined $effort_problem;
        push @problems, { pkg => $pkg, fields => \@f } if @f;
    }

    unless (@problems) {
        printf "bp-model-check: %d package(s) audited %s no unsupported model/effort values.\n",
            scalar(@ledgers), $EMDASH;
        exit 0;
    }

    for my $p (@problems) {
        for my $f (@{ $p->{fields} }) {
            printf STDERR "bp-model-check: %s: %s\n", $p->{pkg}, $f->{detail};
        }
    }
    exit 1;
}

1;
