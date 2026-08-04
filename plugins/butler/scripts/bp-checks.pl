#!/usr/bin/env perl
# bp-checks.pl -- derive the checks a package's WRITE SET implies, and fail a
# blueprint whose package omits one.
#
# WHY
#
# A package's gate answers "do my tests pass?". It needs to answer "is
# everything my write set can break still working?". Those are different
# questions. An external report (techcontas-ux-refine, 13 packages) had five
# defects reach the closing gate, every one because the check that would have
# caught it was in NO package's done-criteria: a production-mode build, a
# Firestore index declaration, a CJS/ESM route load, a lint error latent for
# weeks, and a workspace that was unbuildable for five days while every package
# reported green.
#
# `test_paths:` cannot close this. It is a SCOPE LIMITER -- which tests run --
# and says nothing about which KINDS of verification exist. A package can be
# perfectly compliant and never compile, lint, or load its own output.
#
# THE TABLE IS PROJECT-SUPPLIED. THIS IS THE LOAD-BEARING DESIGN DECISION.
#
# The originating report shipped a derivation table whose every row named a
# JS/TS/Firebase artefact: `tsc --noEmit`, Vitest, `functions/src/**`, Firestore
# composite indexes, `*.rules`. ccpraxis is stack-agnostic, and its OWN
# blueprints are pure Perl -- for those, every row is inapplicable. Hardcoding
# that table here would bake one stack's worldview into a generic tool and hand
# the first non-JS project a checklist of things it does not have.
#
# The report's own reasoning supports this: it rejected a fixed checklist
# because "a fixed list is what went stale". A plugin-level fixed list is the
# same mistake with a wider blast radius. So: the RULE and the MECHANISM ship
# here; the TABLE comes from the project's blueprint.md. A blueprint with no
# table degrades to exactly today's behaviour.
#
# AND IT MUST BE ENFORCED, NOT MERELY DECLARED. A `checks:` field that nothing
# checks is this repo's own b23 defect wearing a new name -- prose corrected,
# mechanism left alone, the two silently diverging for two months. It would be
# worse than no field at all, because it READS as coverage. Hence `audit`.
#
# TABLE FORMAT, in blueprint.md:
#
#   ```checks-table
#   *.ts        => typecheck
#   *.ts        => lint
#   functions/  => prod-build
#   *.rules     => rules-emulator
#   ```
#
# A row is `<pattern> => <check>`. A pattern ending in `/` matches by path
# PREFIX; one containing `*` is a glob over the path; anything else is a
# substring match. One pattern may imply several checks (one row each), which is
# why this is a list and not a hash.
#
# DUAL SHAPE: requireable module, plus a CLI behind `unless (caller)`.
#
#   BpChecks::parse_table($blueprint_text) -> \@rows        ([] when absent)
#   BpChecks::implied(\@rows, $write_set)  -> \@check_names (sorted, unique)
#   BpChecks::missing(\@rows, $write_set, $declared) -> \@check_names
#
# CLI:
#   bp-checks.pl audit  --blueprint <blueprint.md> [--packages-dir DIR]
#   bp-checks.pl derive --blueprint <blueprint.md> --write-set <SET>
#     exit 0 clean / no table · 1 a package omits an implied check · 2 usage

use strict;
use warnings;

package BpChecks;

use File::Basename ();
use File::Spec ();

# ------------------------------------------------------------ parse_table ---

sub parse_table {
    my ($text) = @_;
    return [] unless defined $text && length $text;

    # HTML-commented blocks are NOT a table. This is load-bearing, not tidiness:
    # blueprint.md's own template ships a commented EXAMPLE table, and without
    # this strip every blueprint created from that template would silently
    # inherit a JS/TS/Firebase checklist -- precisely the stack-agnosticism this
    # design exists to protect. (Caught by executing parse_table against the
    # template, which returned 4 rows.)
    #
    # It also gives authors the obvious way to disable their own table
    # temporarily: comment it out and it stops applying, which is what anyone
    # would expect.
    (my $live = $text) =~ s/<!--.*?-->//gs;

    my ($block) = $live =~ /^```checks-table\s*\n(.*?)^```/ms;
    return [] unless defined $block;

    my @rows;
    for my $line (split /\n/, $block) {
        next if $line =~ /^\s*(?:#|$)/;
        my ($pat, $check) = $line =~ /^\s*(\S+)\s*=>\s*(\S+)\s*$/;
        next unless defined $pat && defined $check;
        push @rows, { pattern => $pat, check => $check };
    }
    return \@rows;
}

# --------------------------------------------------------------- matching ---
#
# Deliberately three simple shapes rather than a regex dialect. A table a human
# writes in a blueprint should not need a grammar, and a pattern language nobody
# can predict produces checks nobody trusts.

sub _path_matches {
    my ($pattern, $path) = @_;
    return 0 unless defined $pattern && defined $path && length $path;

    if ($pattern =~ m{/$}) {                       # prefix: functions/
        return index($path, $pattern) == 0 ? 1 : 0;
    }
    if ($pattern =~ /\*/) {                        # glob: *.ts
        my $re = quotemeta $pattern;
        $re =~ s/\\\*/[^\/]*/g;
        return $path =~ /(?:^|\/)$re$/ ? 1 : 0;
    }
    return index($path, $pattern) >= 0 ? 1 : 0;    # substring
}

sub _split_set {
    my ($set) = @_;
    return () unless defined $set && length $set;
    return grep { length } split /:/, $set;
}

# ------------------------------------------------------------------ implied ---

sub implied {
    my ($rows, $write_set) = @_;
    return [] unless ref $rows eq 'ARRAY' && @$rows;

    my @paths = _split_set($write_set);
    my %hit;
    for my $r (@$rows) {
        for my $p (@paths) {
            if (_path_matches($r->{pattern}, $p)) { $hit{ $r->{check} } = 1; last }
        }
    }
    return [ sort keys %hit ];
}

sub missing {
    my ($rows, $write_set, $declared) = @_;
    my %have = map { $_ => 1 } _split_set($declared);
    return [ grep { !$have{$_} } @{ implied($rows, $write_set) } ];
}

# ------------------------------------------------------------------ ledgers ---

sub _slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return undef;
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t;
}

# Frontmatter field read, tolerant of absence -- a ledger without `checks:` is
# not malformed, it is a package that declares none (and will be told so).
sub _fm {
    my ($text, $key) = @_;
    return undef unless defined $text;
    my ($fm) = $text =~ /\A---\s*\n(.*?)\n---\s*\n/s;
    return undef unless defined $fm;
    my ($v) = $fm =~ /^\Q$key\E:\s*(.*?)\s*$/m;
    return $v;
}

package main;

unless (caller) {
    my $verb = shift(@ARGV) // '';
    my %opt;
    while (@ARGV) {
        my $a = shift @ARGV;
        if    ($a =~ /^--blueprint=(.*)$/)     { $opt{blueprint}  = $1 }
        elsif ($a eq '--blueprint')            { $opt{blueprint}  = shift @ARGV }
        elsif ($a =~ /^--packages-dir=(.*)$/)  { $opt{pkgdir}     = $1 }
        elsif ($a eq '--packages-dir')         { $opt{pkgdir}     = shift @ARGV }
        elsif ($a =~ /^--write-set=(.*)$/)     { $opt{write_set}  = $1 }
        elsif ($a eq '--write-set')            { $opt{write_set}  = shift @ARGV }
        else { print STDERR "bp-checks: unrecognised argument '$a'\n"; exit 2 }
    }

    unless ($verb =~ /^(audit|derive)$/ && defined $opt{blueprint}) {
        print STDERR "usage: bp-checks.pl audit  --blueprint <blueprint.md> [--packages-dir DIR]\n"
                   . "       bp-checks.pl derive --blueprint <blueprint.md> --write-set <SET>\n";
        exit 2;
    }

    my $bp_text = BpChecks::_slurp($opt{blueprint});
    unless (defined $bp_text) {
        print STDERR "bp-checks: cannot read $opt{blueprint}\n";
        exit 2;
    }

    my $rows = BpChecks::parse_table($bp_text);

    # NO TABLE => NOTHING TO ENFORCE. Not a warning, not a nag: a stack-agnostic
    # tool must impose no checklist on a project that has not defined one.
    unless (@$rows) {
        print "bp-checks: no checks-table in $opt{blueprint} — nothing implied.\n";
        exit 0;
    }

    if ($verb eq 'derive') {
        print "$_\n" for @{ BpChecks::implied($rows, $opt{write_set}) };
        exit 0;
    }

    my $pkgdir = $opt{pkgdir}
        // File::Spec->catdir(File::Basename::dirname($opt{blueprint}), 'packages');
    unless (-d $pkgdir) {
        print STDERR "bp-checks: packages dir not found: $pkgdir\n";
        exit 2;
    }

    opendir(my $dh, $pkgdir) or do {
        print STDERR "bp-checks: cannot read $pkgdir: $!\n";
        exit 2;
    };
    my @ledgers = sort grep { /\.md\z/ } readdir $dh;
    closedir $dh;

    my @problems;
    for my $l (@ledgers) {
        my $text = BpChecks::_slurp("$pkgdir/$l") // next;
        my $pkg  = BpChecks::_fm($text, 'package') // $l;
        my $ws   = BpChecks::_fm($text, 'write_set');
        next unless defined $ws && length $ws;

        my $miss = BpChecks::missing($rows, $ws, BpChecks::_fm($text, 'checks'));
        push @problems, { pkg => $pkg, missing => $miss } if @$miss;
    }

    unless (@problems) {
        printf "bp-checks: %d package(s) audited against %d table row(s) — no omitted checks.\n",
            scalar(@ledgers), scalar(@$rows);
        exit 0;
    }

    printf STDERR "bp-checks: %d package(s) omit a check their write set implies:\n", scalar(@problems);
    for my $p (@problems) {
        printf STDERR "  %-40s missing: %s\n", $p->{pkg}, join(', ', @{ $p->{missing} });
    }
    print STDERR "\nAdd each to that package's `checks:` frontmatter, or remove the table row that implies it.\n";
    exit 1;
}

1;
