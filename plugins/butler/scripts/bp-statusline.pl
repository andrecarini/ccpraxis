#!/usr/bin/env perl
# bp-statusline.pl -- b37-spend-surfaces C8: the compact spend form for
# Claude Code's statusline. A plain filter script (stdin JSON -> stdout
# bytes, one line), following the same convention as this repo's existing
# scripts/statusline.pl (stdin JSON in, rendered bytes out), but this is a
# NEW, DIFFERENT file: it renders b36/b37's spend struct, not context/plan
# usage.
#
# Input (stdin, JSON): { spend => \%spend, now => N, width => N }
#   \%spend is the same struct SpendPanel::status() consumes (spec S0/S1;
#   see SpendPanel.pm's header for the full shape).
#
# Output (stdout, raw bytes, ONE line, no trailing newline): a compact
# rendering fit to EXACTLY $width display columns, measured and truncated
# via Dashboard's s04 display-width core (display_width/fit_spans/
# spans_text/spans_width) -- never raw `length`, never mid-glyph (fit_spans'
# whole-glyph-drop rule, D4).
#
# Total: never dies, whatever the input (malformed JSON, missing spend,
# missing SpendPanel/Dashboard) -- worst case prints an empty/blank line.
use strict;
use warnings;
use FindBin qw($Bin);
use JSON::PP qw(decode_json);
use Encode qw(encode);

binmode STDIN,  ':raw';
binmode STDOUT, ':raw';

# Loaded by full path (not `use lib` + bareword `use`), exactly as the
# t/54-spend-panel.t oracle itself loads these two modules -- SpendPanel.pm
# and Dashboard.pm live in the SANDBOX plugin's scripts/, this script lives
# in the BUTLER plugin's scripts/, so there is no shared @INC entry to rely
# on.
my $SANDBOX_SCRIPTS = "$Bin/../../sandbox/scripts";
eval { require "$SANDBOX_SCRIPTS/SpendPanel.pm"; 1 } or warn "bp-statusline.pl: SpendPanel.pm unavailable: $@";
eval { require "$SANDBOX_SCRIPTS/Dashboard.pm"; 1 }   or warn "bp-statusline.pl: Dashboard.pm unavailable: $@";

my $raw  = do { local $/; my $r = <STDIN>; defined $r ? $r : '' };
my $data = eval { decode_json($raw) };
$data = {} unless ref($data) eq 'HASH';

my $spend = $data->{spend};
my $now   = $data->{now};
my $width = (defined $data->{width} && !ref($data->{width}) && $data->{width} =~ /^\d+(?:\.\d+)?$/)
          ? int($data->{width}) : 40;

my $info = {};
if (defined &SpendPanel::status) {
    my $got = eval { SpendPanel::status($spend, $now) };
    $info = $got if ref($got) eq 'HASH';
}

# Status-dot glyphs, matching Dashboard's own s06 palette (grep _spend_glyph
# in Dashboard.pm) -- kept as a local literal table rather than reaching
# into Dashboard's PRIVATE _spend_glyph, since this script's contract is
# "render b37's own compact form", not "reuse the panel's internals".
my %GLYPH = (
    ok         => encode('UTF-8', "\x{1F7E2}"),
    exhausted  => encode('UTF-8', "\x{1F534}"),
    unreadable => encode('UTF-8', "\x{1F534}"),
    absent     => encode('UTF-8', "\x{1F7E1}"),
    disabled   => encode('UTF-8', "\x{26AA}"),
);
sub _glyph_for {
    my ($state) = @_;
    return (defined $state && exists $GLYPH{$state}) ? $GLYPH{$state} : $GLYPH{disabled};
}

my @spans;

# 1. Headline: the nearest-exhaustion window, if any (mirrors the panel's
# own 'nearest' line, spec S2/C6) -- the single most useful figure in a
# space-constrained statusline.
my $priority = (ref($info->{priority}) eq 'ARRAY') ? $info->{priority} : [];
if (@$priority && ref($priority->[0]) eq 'HASH') {
    my $top = $priority->[0];
    my $pct = (defined($top->{fraction}) && !ref($top->{fraction}) && $top->{fraction} =~ /^-?\d+(?:\.\d+)?$/)
            ? sprintf('%d%%', int($top->{fraction} * 100 + 0.5)) : '?';
    my $provider = (defined $top->{provider} && !ref $top->{provider}) ? $top->{provider} : '?';
    my $window   = (defined $top->{window}   && !ref $top->{window})   ? $top->{window}   : '?';
    push @spans, { text => encode('UTF-8', "$provider/$window $pct "), role => 'accent' };
}

# 2. One glyph+letter per provider, in declared order.
for my $spec ([ 'claude', 'C' ], [ 'go', 'G' ], [ 'zen', 'Z' ]) {
    my ($key, $abbr) = @$spec;
    my $sub = (ref($info->{$key}) eq 'HASH') ? $info->{$key} : {};
    my $state = (defined $sub->{state} && !ref $sub->{state}) ? $sub->{state} : 'absent';
    push @spans, { text => _glyph_for($state) . $abbr . ' ', role => 'body' };
}

my $out;
if (defined &Dashboard::fit_spans && defined &Dashboard::spans_text) {
    my $fitted = Dashboard::fit_spans(\@spans, $width, 'body');
    $out = Dashboard::spans_text($fitted);
} else {
    $out = '';
}
$out = '' unless defined $out;

print $out;
