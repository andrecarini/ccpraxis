#!/usr/bin/env perl
# platform: any
# almanac-doctor's STALE-PARK finding (todo 20261002-185449-c3eb0000, L3 of
# the where-things-go pkg08 red team). bp-blueprint.pl's unpark hook closes a
# blueprint's park item before it rewrites blueprint.md, so a crash between
# the two leaves a blueprint still parked whose only operator signal reads
# closed. Doctor must flag exactly that shape and nothing near it.
#
# Isolation: temp project roots and a temp home; doctor runs as a child with
# HOME/ALMANAC_HOME/USERPROFILE pinned and an explicit --root.
use strict;
use warnings;
use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);

use lib "$Bin/../../scripts";
use Almanac::Store ();

my $DOCTOR = "$Bin/../../scripts/almanac-doctor.pl";

sub mk_root { my $t = tempdir(CLEANUP => 1); $t =~ s{\\}{/}g; return $t }

sub write_bp {
    my ($root, $bp, $status) = @_;
    my $d = "$root/.ccpraxis-local-data/blueprints/$bp";
    make_path($d);
    open(my $fh, '>', "$d/blueprint.md") or die "fixture: $!";
    print {$fh} "---\nblueprint: $bp\nstatus: $status\n---\n# $bp\n";
    close $fh;
}

sub park_item {
    my ($root, $bp, %f) = @_;
    my $store = Almanac::Store->open(scope => 'project', type => 'inbox', root => $root);
    my %fields = (title => "Blueprint $bp parked: waiting on X", link => $bp,
                  created => '2026-10-01T00:00:00Z', %f);
    my @order = grep { exists $fields{$_} }
        qw(title status created link closed_at closed_reason closed_by);
    $store->create(fields => \%fields, order => \@order);
}

sub doctor {
    my ($root) = @_;
    my $home = mk_root();
    local $ENV{HOME} = $home;
    local $ENV{ALMANAC_HOME} = $home;
    local $ENV{USERPROFILE} = $home;
    delete local $ENV{CLAUDE_PROJECT_DIR};
    my $out = `"$^X" "$DOCTOR" --root "$root" 2>&1`;
    return $out;
}

{   # the interrupted unpark: parked, park item closed by the hook
    my $r = mk_root();
    write_bp($r, 'b1', 'parked');
    park_item($r, 'b1', status => 'answered', closed_at => '2026-10-02T00:00:00Z',
        closed_reason => 'blueprint b1 left parked (status now audited); park reason: x',
        closed_by => 'bp-blueprint.pl set-meta');
    my $out = doctor($r);
    like($out, qr/^STALE-PARK: project inbox\/b1: /m, 'interrupted unpark is flagged STALE-PARK');
    like($out, qr/bp-blueprint\.pl set-meta --file .*--field status/, '...with a concrete repair');
}

{   # healthy park: item still open
    my $r = mk_root();
    write_bp($r, 'b2', 'parked');
    park_item($r, 'b2', status => 'unanswered');
    unlike(doctor($r), qr/STALE-PARK/, 'a park whose item is still open is not flagged');
}

{   # completed unpark: blueprint no longer parked
    my $r = mk_root();
    write_bp($r, 'b3', 'audited');
    park_item($r, 'b3', status => 'answered', closed_at => '2026-10-02T00:00:00Z',
        closed_reason => 'blueprint b3 left parked (status now audited); park reason: x',
        closed_by => 'bp-blueprint.pl set-meta');
    unlike(doctor($r), qr/STALE-PARK/, 'a finished unpark is not flagged');
}

{   # parked, item answered by the operator (not the hook): not this finding
    my $r = mk_root();
    write_bp($r, 'b4', 'parked');
    park_item($r, 'b4', status => 'answered', closed_at => '2026-10-02T00:00:00Z');
    unlike(doctor($r), qr/STALE-PARK/, 'an item closed by anything other than the unpark hook is not flagged');
}

{   # archived blueprints are ignored
    my $r = mk_root();
    write_bp($r, '_archive', 'parked');
    unlike(doctor($r), qr/STALE-PARK/, 'the _archive directory is never read as a blueprint');
}

done_testing();
