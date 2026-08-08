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

# Theme is loaded FIRST, and through a localised @INC rather than by absolute
# path. Both of those are load-bearing. %INC is keyed by the exact string a
# require names, so `require "$SANDBOX_SCRIPTS/Theme.pm"` keys an ABSOLUTE
# path while Dashboard.pm's own `require Theme` keys 'Theme.pm' -- the two
# never match, so Theme.pm compiled TWICE per invocation and emitted ~4 KB of
# "Subroutine ... redefined" warnings on every render of a statusline.
# Naming the file relative to a @INC entry keys 'Theme.pm', which is the key
# the sibling module will look for, so the second require is the no-op it
# should be. The load still comes from $SANDBOX_SCRIPTS, still sits inside an
# eval, and still degrades with a warn rather than ending the render.
my $HAVE_THEME = eval {
    local @INC = ($SANDBOX_SCRIPTS, @INC);
    require "Theme.pm";
    1;
} ? 1 : 0;
$HAVE_THEME or warn "bp-statusline.pl: Theme.pm unavailable: $@";

# Each load's SUCCESS is captured, not merely warned about. `defined
# &Dashboard::fit_spans` is not a health check: a module that fails part-way
# through its own top-level statements leaves every sub installed and its
# file-scoped state uninitialised, so the sub exists and is unusable. Gating
# on the eval is the only test that distinguishes the two.
#
# The same localised @INC serves a second purpose for Dashboard.pm, which is
# not cosmetic: Dashboard's own top-level `require tui::Layout` /
# `require tui::DashboardScreen` go through @INC, so loading Dashboard by
# absolute path alone made it die on any run that did not happen to have
# PERL5LIB pointing here -- i.e. every real one.
my $HAVE_SPENDPANEL = eval {
    local @INC = ($SANDBOX_SCRIPTS, @INC);
    require "SpendPanel.pm";
    1;
} ? 1 : 0;
$HAVE_SPENDPANEL or warn "bp-statusline.pl: SpendPanel.pm unavailable: $@";
my $HAVE_DASHBOARD = eval {
    local @INC = ($SANDBOX_SCRIPTS, @INC);
    require "Dashboard.pm";
    1;
} ? 1 : 0;
$HAVE_DASHBOARD or warn "bp-statusline.pl: Dashboard.pm unavailable: $@";

my $raw  = do { local $/; my $r = <STDIN>; defined $r ? $r : '' };
my $data = eval { decode_json($raw) };
$data = {} unless ref($data) eq 'HASH';

my $spend = $data->{spend};
my $now   = $data->{now};
my $width = (defined $data->{width} && !ref($data->{width}) && $data->{width} =~ /^\d+(?:\.\d+)?$/)
          ? int($data->{width}) : 40;

my $info = {};
if ($HAVE_SPENDPANEL && defined &SpendPanel::status) {
    my $got = eval { SpendPanel::status($spend, $now) };
    $info = $got if ref($got) eq 'HASH';
}

# Status glyphs, sourced from the SHARED token vocabulary by role name
# rather than from private literals: Theme::glyph() already returns UTF-8
# BYTES, which is exactly this script's output contract. The four emoji
# these replace are gone by design (no emoji anywhere on a ccpraxis
# terminal surface) -- a state is carried by a geometric glyph plus colour,
# never by a coloured picture whose width the terminal disagrees about.
my %GLYPH_ROLE = (
    ok         => 'status.ok',
    exhausted  => 'status.crit',
    unreadable => 'status.crit',
    absent     => 'status.warn',
    disabled   => 'status.idle',
);

# The DEGRADE path, for a tree where Theme.pm cannot be loaded: pairwise
# distinct ASCII, one byte and one column each, so the script still prints
# at most one line and still never dies.
my %GLYPH_FALLBACK = (
    ok         => 'o',
    exhausted  => 'x',
    unreadable => 'x',
    absent     => '!',
    disabled   => '-',
);

my %GLYPH;
for my $state (sort keys %GLYPH_ROLE) {
    my $g = ($HAVE_THEME && defined &Theme::glyph) ? Theme::glyph($GLYPH_ROLE{$state}) : undef;
    $GLYPH{$state} = (defined($g) && $g ne '') ? $g : $GLYPH_FALLBACK{$state};
}
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
if ($HAVE_DASHBOARD && defined &Dashboard::fit_spans && defined &Dashboard::spans_text) {
    my $fitted = Dashboard::fit_spans(\@spans, $width, 'body');
    $out = Dashboard::spans_text($fitted);
} else {
    $out = '';
}
$out = '' unless defined $out;

print $out;
