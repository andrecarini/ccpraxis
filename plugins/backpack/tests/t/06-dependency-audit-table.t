#!/usr/bin/env perl
# ORACLE for b01-backpack-install-accounting criterion 4's required artifact
# (spec section 2.3 "The required audit table", case 9 of spec section 3),
# written BLIND to any implementation -- backpack.pl at HEAD has no `deps`
# subcommand and no concept of "load-bearing position" at all.
#
# OPERATOR DECISION 2026-08-13 (recorded in the spec verbatim): this host has
# zero real backpack entries (`.ccpraxis-local-data/claude-home/backpack.json`
# holds none), so the audit table is demonstrated against a SYNTHETIC fixture
# mirroring the incident's item shape -- including the six named items
# (curl-script:gh, curl-script:google-cloud-sdk, curl-script:jdk21,
# curl-script:flutter, curl-script:node, project-setup:gh-auth depending on
# gh). This file does NOT pad the fixture to a literal 15 items: the other
# nine would be undocumented filler carrying no test signal, and the spec's
# own instruction is to mirror the SHAPE, not fabricate a specific count.
#
# The spec requires the table to be labeled, IN THE OUTPUT, as fixture-
# derived and NOT an audit of the operator's real entries. backpack.pl has
# no way to know at runtime whether a given file is "real" or "synthetic" --
# that fact lives with whoever is invoking it -- so this commits to a
# `--note TEXT` flag (the same "explicit hand-off" pattern as `--declared` in
# 03-install-declared-reconciliation.t) that stamps the caller-supplied text
# verbatim into the report header. This test supplies the fixture-derived
# disclaimer via --note and asserts it comes through unaltered.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json);

my $BP = "$Bin/../../scripts/backpack.pl";
ok(-f $BP, 'backpack.pl exists') or BAIL_OUT('script missing');

unless (system('bash -c "exit 0" >/dev/null 2>&1') == 0) {
    plan skip_all => 'bash not available on this host';
}

my $dir = tempdir(CLEANUP => 1);

sub run_bp {
    my (@args) = @_;
    my $pid = open(my $fh, '-|');
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        open(STDIN, '<', '/dev/null');
        open(STDERR, '>&', \*STDOUT);
        exec($^X, $BP, @args);
        CORE::exit(127);
    }
    my @lines;
    my $timed_out = 0;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm 20;
        @lines = <$fh>;
        alarm 0;
    };
    if ($@) { $timed_out = 1; kill 'KILL', $pid; }
    alarm 0;
    close $fh;   # reaps the child; sets $? -- do NOT waitpid again afterward (that would
                 # reap a nonexistent process and clobber $? with an undefined value)
    my $rc = $timed_out ? -1 : ($? >> 8);
    return (join('', @lines), $rc, $timed_out);
}

# The synthetic, incident-shaped fixture. gh-auth is declared FIRST, and its
# dependency (gh) SECOND -- so gh-auth's current file position genuinely is
# load-bearing (it would need reordering to install correctly), while the
# five plain curl-script tools have no dependency to violate and so are NOT
# load-bearing regardless of position.
my @fixture_items = (
    { category => 'project-setup', name => 'gh-auth', install => 'true', verify => 'true',
      depends_on => [ 'curl-script:gh' ] },
    { category => 'curl-script', name => 'gh',              install => 'true', verify => 'true' },
    { category => 'curl-script', name => 'google-cloud-sdk', install => 'true', verify => 'true' },
    { category => 'curl-script', name => 'jdk21',            install => 'true', verify => 'true' },
    { category => 'curl-script', name => 'flutter',          install => 'true', verify => 'true' },
    { category => 'curl-script', name => 'node',             install => 'true', verify => 'true' },
);

my $fixture_path = "$dir/synthetic-fixture.json";
open my $fh, '>:raw', $fixture_path or die "write $fixture_path: $!";
print $fh encode_json({ version => 2, items => \@fixture_items });
close $fh;

my $disclaimer = "SYNTHETIC FIXTURE - mirrors the incident's item shape (BPK-01/02/03/04); "
                . "NOT an audit of any operator's real backpack.json";

my ($out, $rc, $timed_out) = run_bp('deps', $fixture_path, '--note', $disclaimer);
ok(!$timed_out, 'deps: terminates');
is($rc, 0, 'deps: exits 0 against a well-formed, cycle-free, dangling-ref-free fixture')
    or diag("  got:\n$out");

# --- The table is generated: one row named per declared item. ---
for my $it (@fixture_items) {
    my $label = "$it->{category}:$it->{name}";
    like($out, qr/\Q$label\E/, "deps: the table names $label");
}

# --- The table states declared dependencies. ---
like($out, qr/curl-script:gh\b/ ,'deps: gh-auth\'s row states its dependency (curl-script:gh)');

# --- Load-bearing distinction: gh-auth's position matters; the plain tools' don't. ---
my ($ghauth_line) = grep { /project-setup:gh-auth/ } split /\n/, $out;
ok(defined $ghauth_line, 'deps: gh-auth has its own table row') or diag("  got:\n$out");
SKIP: {
    skip('gh-auth row not found', 1) unless defined $ghauth_line;
    like($ghauth_line, qr/load.bearing.*(?:yes|true|1)\b/i,
        'deps: gh-auth\'s row is marked load-bearing (its declared position matters)');
}

my ($node_line) = grep { /curl-script:node/ } split /\n/, $out;
ok(defined $node_line, 'deps: the plain curl-script:node has its own table row') or diag("  got:\n$out");
SKIP: {
    skip('node row not found', 1) unless defined $node_line;
    like($node_line, qr/load.bearing.*(?:no|false|0)\b/i,
        'deps: curl-script:node (no dependency) is marked NOT load-bearing');
}

# --- Counter-fixture for the load-bearing detector: without this, "yes" vs
# "no" above could both be produced by a detector that never actually
# computes anything (e.g. always prints "load_bearing=no"). Prove the
# detector can say "yes" by requiring it on the ONE row that must be yes and
# NOT on a row that must be no, which the two assertions above jointly do --
# but make the discriminating power explicit as its own assertion too.
# ---------------------------------------------------------------------------
isnt(($ghauth_line // ''), ($node_line // ''),
    'deps: the load-bearing row and the not-load-bearing row are textually distinct (not a constant)');

# --- THE LABELING REQUIREMENT: the report explicitly states it is
# fixture-derived and explicitly disclaims being an audit of real entries.
# Two separate substrings, asserted separately, so a generic "note" that
# happens to contain one but not the other cannot pass by accident.
# ---------------------------------------------------------------------------
like($out, qr/SYNTHETIC FIXTURE/, 'deps: the output states it is a SYNTHETIC FIXTURE');
like($out, qr/NOT an audit/,      'deps: the output explicitly disclaims being a real audit');

done_testing();
