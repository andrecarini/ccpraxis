#!/usr/bin/env perl
# 64-theme-tokens.t — ORACLE for package 02-design-tokens (blueprint
# unified-tui-design-system), specs/02-design-tokens-spec.md. Written BLIND to
# any Theme.pm implementation — directly from the spec's numbered behaviours
# (B-A1..B-H3) and acceptance criteria (AC-1..AC-20) — so this serves as an
# oracle, not an echo of whatever the implementer eventually writes. Do NOT
# weaken an assertion here to make a future implementation's life easier.
#
# TODAY'S EXPECTED STATE, recorded so a future reader is not surprised:
# Theme.pm does not exist yet. B-A1 fails and this file calls BAIL_OUT right
# after — "nothing else can mean anything" once the one module under test
# cannot load (spec §3-A). Everything that does NOT depend on Theme.pm is
# deliberately placed BEFORE that bail point so it still runs and reports
# honestly today: the surface-level emoji pending-adoption scan (§2.6.3), the
# statusline GENERATED-block guard's classification machinery including
# today's real-surface verdict (§2.7), a Dashboard.pm self-consistency sanity
# check, and assorted fixture self-tests. A static `use Theme ();` would abort
# compilation of this WHOLE file the moment Theme.pm is missing (BEGIN blocks
# run during compilation, before ANY runtime statement, regardless of where
# `use` sits textually) — which would make it impossible for the sections
# above to report honestly today. So the load is a guarded RUNTIME `require`
# instead: same substance (loadability via the "$Bin/../../scripts" @INC
# entry, spec §2.0 rule 5) but it lets everything above the load report first.
# Once package 02 lands Theme.pm, the bail stops firing and every section
# below it — B, C, D, F, and the Theme-dependent parts of A/E/G — starts
# running for real.
#
# NO SHAPE PINS (AC-19, Decision 15): no count/is_deeply over the FULL role
# set, glyph set, %EMOJI_PENDING, %PENDING_GLYPH_REGISTRATION,
# @GENERATED_SURFACES or _dash_glyph_table() anywhere below. Any
# is(scalar(...), N) with N > 2 is over a fixture THIS FILE built, and its
# description says "fixture". The two is_deeply(\@names_in_hash,
# \@sorted_roles, ...) calls in section G compare two LIVE outputs derived
# from the SAME current Theme::roles() call against each other (self-
# consistency between generated_block() and roles()) — not a hardcoded pin —
# so they stay green when a later package adds a role.
#
# CONTRAST FLOORS, NEVER EQUALITIES (ruling R3): every contrast assertion is
# cmp_ok($ratio, '>=', $floor, ...), so a later tweak that IMPROVES contrast
# can never turn this suite red.
#
# THE ACCENT FAMILY IS A BAND (AC-8): asserted via abs(lstar - $T) <= $E,
# never an exact L*.
#
# HARD CONSTRAINTS (AC-20, B-H3): this file spawns no process, opens no
# network connection, touches no container, needs no real terminal, and
# writes only under File::Temp::tempdir(CLEANUP => 1). It runs standalone via
# `perl <file>` — there is no `prove` on this host.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Temp qw(tempdir);
use Encode qw(encode decode);

my $SCRIPTS         = "$Bin/../../scripts";
my $ROOT            = "$Bin/../../../..";   # t -> tests -> sandbox -> plugins -> repo root
my $THEME_PM        = "$SCRIPTS/Theme.pm";
my $DASHBOARD_PM    = "$SCRIPTS/Dashboard.pm";
my $STATUSLINE_REL  = 'scripts/statusline.pl';
my $STATUSLINE_ABS  = "$ROOT/$STATUSLINE_REL";

use lib "$Bin/../../scripts";

# _dash_glyph_table() -> { decoded_char => declared_width }, the contract
# Dashboard::glyph_table() used to provide. That function was a thin derivation
# over Theme::glyphs() and was deleted as unreachable from shipped code; the
# derivation is reproduced here rather than the assertions being dropped,
# because what they check -- that a glyph this codebase emits is declared, at
# the width Theme declares -- is still worth checking. Note Theme::glyphs() is
# keyed by NAME, not by character, which is why this is not a straight alias.
sub _dash_glyph_table {
    my $g = Theme::glyphs();
    my %t;
    for my $name (keys %$g) {
        my $rec = $g->{$name};
        next unless ref($rec) eq 'HASH' && defined $rec->{char};
        $t{ $rec->{char} } = $rec->{width};
    }
    return \%t;
}

# ===========================================================================
# Literal constants (spec §2.7.1) — declared here, NOT sourced from Theme,
# so the GENERATED-block guard machinery below can run before Theme.pm
# exists. §2.7's own B-G1 separately proves Theme::generated_markers()
# returns these same two literals once Theme is loadable.
# ===========================================================================
my $BEGIN_MARKER = '# >>> BEGIN GENERATED FROM Theme.pm -- DO NOT EDIT BY HAND >>>';
my $END_MARKER   = '# <<< END GENERATED FROM Theme.pm <<<';
my $BEGIN_RE     = qr/^\Q$BEGIN_MARKER\E$/m;
my $END_RE       = qr/^\Q$END_MARKER\E$/m;

# ===========================================================================
# The drift-guard's surface table (spec §2.7.3) and the two pending-adoption
# lists (spec §2.5 / §2.6.3), on the %WAIVED shape proven at
# t/62-tui-adapter-contract.t:685-691 / :770-801. An entry PASSES while the
# debt is real; a STALE entry (debt now cleared but still listed) FAILS.
# Deliberately NO assertion anywhere on any of these three collections' size
# or non-emptiness — later packages legitimately empty them (AC-18, E-2, E-3).
# ===========================================================================
my @GENERATED_SURFACES = (
    { path    => $STATUSLINE_REL },
);

my %EMOJI_PENDING = (
);

# redteam.md M6(c): the verdict above is computed PER SURFACE, not per hit --
# any number of NEW emoji added to an already-listed, already-dirty surface
# is free. Pin the actual codepoints each waiver covers (spec §1.1's "five
# emoji already on disk"), so a hit whose codepoint is NOT in this recorded
# set is a NEW, unwaived regression even on a surface that already has a row.
# Deliberately NOT an assertion that every recorded codepoint is still
# present (that would duplicate the stale-entry arm and would redden package
# 06 mid-flight for a partial cleanup) -- this only catches ADDITIONS.
# Emptied 2026-08-08. The last row here waived four emoji in Dashboard.pm, and
# it was dead twice over: package 06 had already removed those codepoints (the
# file scans clean), and this table is read only inside the `$dirty && $listed`
# arm below, which %EMOJI_PENDING being empty makes unreachable for every
# surface. Package 10 correctly left it standing when it cleared the rows it
# owned -- its spec scoped it to its own surfaces -- so the row survived with no
# owner and no way to fire, which is precisely the stale-waiver rot this file's
# own header warns about. Removed rather than re-homed: there is no debt left to
# waive. The table stays declared, so a future package with real debt has the
# mechanism ready.
my %EMOJI_PENDING_CODEPOINTS = (
);

my @EMOJI_SURFACES = (
    'scripts/statusline.pl',
    'plugins/sandbox/scripts/Dashboard.pm',
    'plugins/butler/scripts/bp-statusline.pl',
);

my %PENDING_GLYPH_REGISTRATION = (
);

# ===========================================================================
# Scaffolding
# ===========================================================================

# slurp($path) -> file contents as raw bytes, or undef. Never require'd/do'ne.
sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return undef;
    local $/;
    my $s = <$fh>;
    close $fh;
    return $s;
}

# _write($path, $content) -> writes raw bytes, dies loudly on setup failure
# (a fixture-setup failure is not the thing under test, so it must be loud).
sub _write {
    my ($path, $content) = @_;
    open my $fh, '>:raw', $path or die "fixture setup: cannot write $path: $!";
    print $fh $content;
    close $fh;
    return;
}

# _within($got, $want, $tolerance, $desc) -> ok() with a diag on failure.
sub _within {
    my ($got, $want, $tol, $desc) = @_;
    my $ok = defined($got) && abs($got - $want) <= $tol;
    ok($ok, $desc)
        or diag(sprintf("  got %s, want %s within %s", defined($got) ? $got : '<undef>', $want, $tol));
    return $ok;
}

# _match_positions($text, $re) -> list of start offsets of every match of $re
# in $text. $re already carries /m; matching against a value copy each call
# keeps pos() state from leaking between the BEGIN-marker and END-marker scans.
sub _match_positions {
    my ($text, $re) = @_;
    my @pos;
    while ($text =~ /$re/g) { push @pos, $-[0]; }
    return @pos;
}

# _extract_generated_block($text) -> ($status, $payload), per spec §2.7.3.
#   'absent'    — neither marker present.
#   'malformed' — exactly one marker present, or END before BEGIN, or either
#                 marker duplicated.
#   'present'   — both markers, exactly once each, BEGIN before END. $payload
#                 is everything strictly between BEGIN's terminating "\n" and
#                 the first character of END's line.
sub _extract_generated_block {
    my ($text) = @_;
    my @begins = _match_positions($text, $BEGIN_RE);
    my @ends   = _match_positions($text, $END_RE);

    return ('absent', undef) if !@begins && !@ends;
    return ('malformed', undef) if @begins != 1 || @ends != 1;

    my ($begin_pos, $end_pos) = ($begins[0], $ends[0]);
    return ('malformed', undef) if $end_pos < $begin_pos;

    my $begin_line_end = index($text, "\n", $begin_pos);
    return ('malformed', undef) if $begin_line_end < 0;

    my $payload_start = $begin_line_end + 1;
    my $payload = substr($text, $payload_start, $end_pos - $payload_start);
    return ('present', $payload);
}

# _surface_verdict($status, $pending, $payload, $expected) -> one of the six
# verdicts of spec §2.7.3's truth table:
#   absent_pending | absent_not_pending | pending_but_present | match |
#   mismatch | malformed
# Pure and self-contained: does not touch a file, does not call Theme. The
# same function drives the real surface (today, via §self, with $expected
# undef until Theme loads) and every synthetic fixture below (B-G10, B-G11).
sub _surface_verdict {
    my ($status, $pending, $payload, $expected) = @_;
    return 'malformed' if $status eq 'malformed';
    my $is_pending = defined($pending) && length($pending);
    if ($status eq 'absent') {
        return $is_pending ? 'absent_pending' : 'absent_not_pending';
    }
    if ($status eq 'present') {
        return 'pending_but_present' if $is_pending;
        return (defined($expected) && $payload eq $expected) ? 'match' : 'mismatch';
    }
    return 'malformed';
}

# _live_code_checks($text, $begin_pos) -> ($not_end_data, $pod_balanced, $not_in_heredoc)
# redteam.md M1: the guard is a pure TEXT matcher with no notion of Perl
# lexical context, so a block pasted after __END__/__DATA__, inside a
# heredoc/q{}, or swallowed by an unterminated POD directive ABOVE it (which
# can be introduced by an edit far away from the block) all leave the guard
# GREEN while the real file renders exactly what it rendered before. Three
# cheap structural facts computed over the PREFIX (everything before the
# BEGIN marker) that make "present" mean "live code", not merely "the bytes
# happen to be there":
#   not_end_data   -- the prefix is not a bare __END__/__DATA__ line (Perl
#                      discards everything after those, unconditionally).
#   pod_balanced    -- every column-0 POD directive above the block has a
#                      matching =cut; an unterminated one swallows the block.
#   not_in_heredoc  -- best-effort only (documented as such): the prefix does
#                      not end mid-heredoc-opener.
sub _live_code_checks {
    my ($text, $begin_pos) = @_;
    my $pre = substr($text, 0, $begin_pos);
    my $not_end_data   = ($pre !~ /^__(?:END|DATA)__$/m) ? 1 : 0;
    my $pod_opens       = () = $pre =~ /^=(?!cut\b)[a-zA-Z]\w*/mg;
    my $pod_cuts         = () = $pre =~ /^=cut\b/mg;
    my $pod_balanced    = ($pod_opens == $pod_cuts) ? 1 : 0;
    my $not_in_heredoc  = ($pre !~ /<<['"]?\w+['"]?\s*;?\s*\z/) ? 1 : 0;
    return ($not_end_data, $pod_balanced, $not_in_heredoc);
}

# _process_generated_surface($surface, $root, $expected) -> \%result
#   { outcome => 'skip' }                                    -- file missing
#   { outcome => 'checked', status, payload, verdict, text }  -- file read,
#     plus (only when status eq 'present') not_end_data, pod_balanced,
#     not_in_heredoc from _live_code_checks (redteam.md M1).
# CRLF is normalised to LF before extraction (spec §2.7.3, a Windows checkout
# must not fail the guard on line endings).
sub _process_generated_surface {
    my ($surface, $root, $expected) = @_;
    my $path = "$root/$surface->{path}";
    my $text = slurp($path);
    return { outcome => 'skip', path => $path } unless defined $text;
    $text =~ s/\r\n/\n/g;
    my ($status, $payload) = _extract_generated_block($text);
    my $verdict = _surface_verdict($status, $surface->{pending}, $payload, $expected);
    my %live_code;
    if ($status eq 'present') {
        my ($begin_pos) = _match_positions($text, $BEGIN_RE);
        @live_code{qw(not_end_data pod_balanced not_in_heredoc)} = _live_code_checks($text, $begin_pos);
    }
    return { outcome => 'checked', status => $status, payload => $payload, verdict => $verdict, text => $text, path => $path, %live_code };
}

# _is_emoji($cp) -> true iff $cp falls in any block of spec §2.6.1. Block-
# based and deliberately an over-approximation (spec's own framing). U+FE0F
# (variation selector-16) is flagged on its own as an explicit request for
# emoji presentation. U+200D (ZWJ) is deliberately NOT flagged.
sub _is_emoji {
    my ($cp) = @_;
    return 0 unless defined $cp;
    for my $r (
        [0x1F000, 0x1F0FF], [0x1F100, 0x1F1FF], [0x1F200, 0x1F2FF],
        [0x1F300, 0x1F5FF], [0x1F600, 0x1F64F], [0x1F650, 0x1F67F],
        [0x1F680, 0x1F6FF], [0x1F700, 0x1F77F], [0x1F780, 0x1F7FF],
        [0x1F800, 0x1F8FF], [0x1F900, 0x1F9FF], [0x1FA00, 0x1FAFF],
        [0x2600,  0x26FF],  [0x2700,  0x27BF],
    ) {
        return 1 if $cp >= $r->[0] && $cp <= $r->[1];
    }
    return 1 if $cp == 0xFE0F;
    return 0;
}

# _emoji_hits($text) -> list of { cp, line, how } for every emoji codepoint
# found in $text, per spec §2.6.3:
#   A — escape literals:  /\\x\{([0-9A-Fa-f]{2,6})\}/g, how = 'escape'.
#   B — encoded literals: decode as UTF-8 leniently, test every char's ord,
#       how = 'literal'. Line numbers are computed by counting "\n" in the
#       prefix in both cases (decoding preserves newlines).
sub _emoji_hits {
    my ($text) = @_;
    return () unless defined $text;
    my @hits;

    while ($text =~ /\\x\{([0-9A-Fa-f]{2,6})\}/g) {
        my $cp = hex($1);
        next unless _is_emoji($cp);
        my $prefix = substr($text, 0, $-[0]);
        my $line = 1 + ($prefix =~ tr/\n//);
        push @hits, { cp => $cp, line => $line, how => 'escape' };
    }

    my $decoded = decode('UTF-8', $text, Encode::FB_DEFAULT);
    my $pos = 0;
    for my $ch (split //, $decoded) {
        my $cp = ord($ch);
        if (_is_emoji($cp)) {
            my $prefix = substr($decoded, 0, $pos);
            my $line = 1 + ($prefix =~ tr/\n//);
            push @hits, { cp => $cp, line => $line, how => 'literal' };
        }
        $pos += length($ch);
    }

    return @hits;
}

# _balanced_braces($src, $from) -> the '{'...'}' substring balanced from the
# first '{' at-or-after $from, or undef if unbalanced. Verbatim shape reused
# from t/62-tui-adapter-contract.t (itself reused from t/54/t/59).
sub _balanced_braces {
    my ($src, $from) = @_;
    my $idx = index($src, '{', $from);
    return undef if $idx < 0;
    my $depth = 0;
    my $i     = $idx;
    my $len   = length($src);
    for (; $i < $len; $i++) {
        my $c = substr($src, $i, 1);
        if    ($c eq '{') { $depth++; }
        elsif ($c eq '}') { $depth--; last if $depth == 0; }
    }
    return undef if $depth != 0;
    return substr($src, $idx, $i - $idx + 1);
}

# _strip_sub_bodies($src) -> $src with every `sub NAME [(proto)] { ... }`
# body blanked (newlines preserved, everything else replaced with a space),
# leaving only Theme.pm's TOP-LEVEL code for B-A3's "no top-level %ENV /
# print / capability() call" scan.
sub _strip_sub_bodies {
    my ($src) = @_;
    my $out = $src;
    while ($out =~ /\bsub\s+\w+\s*(?:\([^)]*\))?\s*/g) {
        my $after = pos($out);
        my $body  = _balanced_braces($out, $after);
        last unless defined $body;
        my $body_start = index($out, $body, $after);
        last if $body_start < 0;
        (my $blanked = $body) =~ s/[^\n]/ /g;
        substr($out, $body_start, length($body), $blanked);
        pos($out) = $body_start + length($blanked);
    }
    return $out;
}

# ===========================================================================
# Everything below this comment, up to the Theme load, is INDEPENDENT of
# Theme.pm and is expected to be GREEN today, before Theme.pm exists.
# ===========================================================================

# Captured FIRST, before anything else touches the real surface, so the
# read-only proof at the very end of this file (B-G12/AC-17) has a true
# "at the start of the run" baseline.
my $statusline_bytes_start = slurp($STATUSLINE_ABS);

# ---------------------------------------------------------------------------
# Dashboard.pm self-consistency sanity (scaffolding, not itself an AC): the
# delegation TARGET (Dashboard::display_width / Dashboard::glyph_width)
# behaves as Dashboard.pm's own header documents, independent of Theme. The
# real cross-check (AC-11, B-E7..B-E10) needs Theme::glyphs() and runs after
# the Theme load below. Per spec's edge-case table, Dashboard.pm missing must
# not fail this file — it skips with a counted diag.
# ---------------------------------------------------------------------------
my $DASHBOARD_OK = eval { require Dashboard; 1 };
ok($DASHBOARD_OK, 'plugins/sandbox/scripts/Dashboard.pm loads (precondition for the width-agreement cross-check, B-E7..B-E10)')
    or diag("  require Dashboard failed: $@");
SKIP: {
    skip('Dashboard.pm did not load', 2) unless $DASHBOARD_OK;
    my $full_block = Encode::encode('UTF-8', "\x{2588}");   # gauge.full, Dashboard.pm:240, declared width 1
    is(Dashboard::display_width($full_block), 1,
        'sanity: Dashboard::display_width agrees with Dashboard\'s own declared width for gauge.full');
    my $up_triangle = Encode::encode('UTF-8', "\x{25B2}");  # scroll.up, Dashboard.pm:242, declared width 1
    is(tui::Layout::glyph_width($up_triangle), 1,
        'sanity: Dashboard::glyph_width agrees with Dashboard\'s own declared width for U+25B2 (scroll.up)');
}

# ---------------------------------------------------------------------------
# B-E6: emoji-detector non-vacuity, self-contained (no Theme needed). Proves
# the driver's finding: 0x26AA lives in Miscellaneous Symbols, not a 1F???
# block, and a naive >= 0x1F000 check would miss it.
# ---------------------------------------------------------------------------
for my $cp (0x1F4E6, 0x1F7E2, 0x1F534, 0x1F7E1, 0x26AA, 0xFE0F) {
    ok(_is_emoji($cp), sprintf('_is_emoji(0x%04X) is TRUE (B-E6, AC-10, fixture)', $cp));
}
for my $cp (0xFF5C, 0x2500, 0x2502, 0x25CF, 0x25CB, 0x25B3, 0x25B6, 0x2191, 0x00B7, 0x00D7, 0x280B, 0x2584, 0x0041, 0x200D) {
    ok(!_is_emoji($cp), sprintf('_is_emoji(0x%04X) is FALSE (B-E6, AC-10, fixture)', $cp));
}

# ---------------------------------------------------------------------------
# B-E11/B-E12/B-E13: the surface-level emoji pending-adoption list (§2.6.3,
# ruling R2b, AC-18). Self-contained: pure regex/decode scanning of files on
# disk, no Theme dependency.
# ---------------------------------------------------------------------------
for my $rel (@EMOJI_SURFACES) {
    my $path = "$ROOT/$rel";
    my $text = slurp($path);
    my $listed = exists $EMOJI_PENDING{$rel} ? 1 : 0;

    if (!defined $text) {
        if ($listed) {
            fail("emoji surface scan: '$rel' is listed in \%EMOJI_PENDING but does not exist at $path -- unknown key (B-E11, AC-18)");
        } else {
            SKIP: { skip("emoji surface scan: '$rel' does not exist at $path -- partial checkout, not an emoji defect", 1); }
        }
        next;
    }

    my @hits = _emoji_hits($text);
    my $dirty = @hits ? 1 : 0;

    if ($dirty && $listed) {
        pass("emoji surface scan: '$rel' has emoji, listed in \%EMOJI_PENDING -- $EMOJI_PENDING{$rel} (B-E11, AC-18)");
        diag(sprintf("  %s:%d U+%04X (%s)", $rel, $_->{line}, $_->{cp}, $_->{how})) for @hits;

        # redteam.md M6(c): per-HIT, not per-surface. The verdict above only
        # asks "does this surface have ANY emoji" -- so any number of NEW
        # emoji added to an already-listed, already-dirty surface (Dashboard.pm
        # is exactly that surface, and package 06 is about to rewrite it) is
        # currently free. Every hit's codepoint must be one this waiver was
        # actually recorded for.
        my $known = $EMOJI_PENDING_CODEPOINTS{$rel} || {};
        for my $hit (@hits) {
            ok(exists $known->{ $hit->{cp} },
                sprintf("emoji surface scan: '%s' hit U+%04X at line %d is a RECORDED codepoint for this waiver, not a new emoji hiding behind the existing row (M6, per-hit not per-surface)",
                    $rel, $hit->{cp}, $hit->{line}));
        }
    } elsif ($dirty && !$listed) {
        fail("emoji surface scan: '$rel' has emoji but is NOT listed in \%EMOJI_PENDING -- unrecorded regression (B-E11, AC-18)");
        diag(sprintf("  %s:%d U+%04X (%s)", $rel, $_->{line}, $_->{cp}, $_->{how})) for @hits;
    } elsif (!$dirty && $listed) {
        fail("emoji surface scan: '$rel' is listed in \%EMOJI_PENDING but is CLEAN -- STALE ENTRY, delete it (B-E11, AC-18)");
    } else {
        pass("emoji surface scan: '$rel' is clean and unlisted (B-E11, AC-18)");
    }
}

for my $key (sort keys %EMOJI_PENDING) {
    my $reason = $EMOJI_PENDING{$key};
    # redteam.md M6(a): the OLD regex was /\b(?:06|09|10)\b/ -- a bare \b06\b
    # is satisfied by ANY appearance of "06" including inside a date
    # ('...review 2026-10-06' is 34 chars and matches \b10\b via the '-10-'
    # substring, having named NO package at all). Require a real
    # "package NN-slug" identifier, or M6(b)'s no-owner hatch anchored to the
    # START of the reason (not merely present anywhere in a longer sentence).
    my $owner_ok = defined($reason)
        && ( $reason =~ /\bpackage\s+(?:06|09|10)-[a-z0-9-]+\b/
          || $reason =~ /\Ano package owns\b/ );
    ok((defined($reason) && length($reason) >= 20 && $owner_ok) ? 1 : 0,
        "emoji pending hygiene: \%EMOJI_PENDING{$key} reason is >= 20 chars and names a real 'package NN-slug' or starts with the exact 'no package owns' literal -- a bare \\bNN\\b cannot be satisfied by a date (M6, B-E12, AC-18)")
        or diag("  reason was: " . (defined $reason ? $reason : '<undef>'));
}

# ---------------------------------------------------------------------------
# M3 (redteam.md MEDIUM-3): @EMOJI_SURFACES has no membership floor (deleting
# an entry silently stops scanning that surface) and an orphan
# %EMOJI_PENDING key naming a surface nobody scans is never validated (reads
# as an active, honoured waiver while guarding nothing). Both membership, not
# a count -- AC-19/Decision 15 untouched.
# ---------------------------------------------------------------------------
for my $must ('scripts/statusline.pl', 'plugins/sandbox/scripts/Dashboard.pm') {
    ok((grep { $_ eq $must } @EMOJI_SURFACES) ? 1 : 0,
        "emoji scan set includes the load-bearing surface '$must' -- membership floor, not a count (M3)");
}
for my $key (sort keys %EMOJI_PENDING) {
    ok((grep { $_ eq $key } @EMOJI_SURFACES) ? 1 : 0,
        "\%EMOJI_PENDING key '$key' names a surface that is actually scanned -- orphan-waiver guard (M3)");
}

{
    my $tmpdir = tempdir(CLEANUP => 1);

    my $f1 = "$tmpdir/escape.txt";
    _write($f1, "line one\nsome text \\x{1F4E6} more\nline three\n");
    my @h1 = _emoji_hits(slurp($f1));
    ok((grep { $_->{cp} == 0x1F4E6 && $_->{how} eq 'escape' && $_->{line} == 2 } @h1) ? 1 : 0,
        'fixture: _emoji_hits finds an escape-literal \x{1F4E6} at the right line with how eq escape (B-E13, fixture)');

    my $f2 = "$tmpdir/literal.txt";
    _write($f2, "line one\n" . encode('UTF-8', "\x{1F534}") . "\nline three\n");
    my @h2 = _emoji_hits(slurp($f2));
    ok((grep { $_->{cp} == 0x1F534 && $_->{how} eq 'literal' } @h2) ? 1 : 0,
        'fixture: _emoji_hits finds a raw UTF-8-encoded literal U+1F534 with how eq literal (B-E13, fixture)');

    my $f3 = "$tmpdir/clean.txt";
    _write($f3, "sep \\x{FF5C} rule \\x{2500} corner \\x{250C}\n");
    my @h3 = _emoji_hits(slurp($f3));
    is(scalar(@h3), 0, 'fixture: _emoji_hits finds no hits for FF5C/2500/250C escapes (B-E13, fixture count)');
}

# ---------------------------------------------------------------------------
# B-G6/B-G8/B-G9(partial)/B-G10/B-G11/B-G13: the GENERATED-block guard's
# classification machinery (§2.7.3, ruling R1, AC-16/AC-17). Self-contained:
# _extract_generated_block / _surface_verdict only need the literal markers
# declared above, never Theme::generated_block(). The 'present'+'not
# pending' match/mismatch arm needs a real Theme payload and is re-checked
# after the Theme load below (that re-check is the authoritative one).
# ---------------------------------------------------------------------------
{
    my $tmpdir = tempdir(CLEANUP => 1);

    my $f_absent = "$tmpdir/absent.pl";
    _write($f_absent, "just some perl\nno markers here\n");
    my ($s, $p) = _extract_generated_block(slurp($f_absent));
    is($s, 'absent', 'fixture: _extract_generated_block -- no markers -> absent (B-G6)');
    is($p, undef, 'fixture: absent payload is undef (B-G6)');

    my $f_begin_only = "$tmpdir/begin-only.pl";
    _write($f_begin_only, "$BEGIN_MARKER\nsome payload\n");
    ($s, $p) = _extract_generated_block(slurp($f_begin_only));
    is($s, 'malformed', 'fixture: BEGIN marker only -> malformed (B-G6)');

    my $f_reversed = "$tmpdir/reversed.pl";
    _write($f_reversed, "$END_MARKER\nsome payload\n$BEGIN_MARKER\n");
    ($s, $p) = _extract_generated_block(slurp($f_reversed));
    is($s, 'malformed', 'fixture: END before BEGIN -> malformed (B-G6)');

    my $f_dup = "$tmpdir/dup.pl";
    _write($f_dup, "$BEGIN_MARKER\n$BEGIN_MARKER\npayload\n$END_MARKER\n");
    ($s, $p) = _extract_generated_block(slurp($f_dup));
    is($s, 'malformed', 'fixture: duplicated BEGIN -> malformed (B-G6)');

    my $f_present = "$tmpdir/present.pl";
    my $payload_text = "my \%X = (\n  'a' => 1,\n);\n";
    _write($f_present, "prefix\n$BEGIN_MARKER\n$payload_text$END_MARKER\nsuffix\n");
    ($s, $p) = _extract_generated_block(slurp($f_present));
    is($s, 'present', 'fixture: both markers once in order -> present (B-G6)');
    is($p, $payload_text, 'fixture: present payload is byte-equal to what was written between the markers (B-G6)');
}

{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $payload_text = "my \%X = (\n  'a' => 1,\n);\n";
    my $lf_text = "prefix\n$BEGIN_MARKER\n$payload_text$END_MARKER\nsuffix\n";
    (my $crlf_text = $lf_text) =~ s/\n/\r\n/g;
    my $f_crlf = "$tmpdir/crlf.pl";
    _write($f_crlf, $crlf_text);
    my $read_back = slurp($f_crlf);
    $read_back =~ s/\r\n/\n/g;
    my ($s, $p) = _extract_generated_block($read_back);
    is($s, 'present', 'fixture: CRLF-normalised file still extracts as present (B-G8)');
    is($p, $payload_text, 'fixture: CRLF-normalised payload compares byte-equal to the LF payload (B-G8)');
}

# ---------------------------------------------------------------------------
# M1 (redteam.md MEDIUM-1): the guard cannot tell a live GENERATED block from
# an inert one -- a block pasted after __END__/__DATA__, inside a heredoc, or
# swallowed by an unterminated POD directive above it all leave the guard
# GREEN while the real file renders exactly what it rendered before. These
# fixtures prove _live_code_checks (scaffolding above) actually catches each
# trap, plus a control case proving it does NOT false-positive on an ordinary
# legitimate block.
# ---------------------------------------------------------------------------
{
    my $tmpdir = tempdir(CLEANUP => 1);
    my $payload_text = "my \%X = (\n  'a' => 1,\n);\n";

    my $f_end = "$tmpdir/end.pl";
    _write($f_end, "prefix\n__END__\n$BEGIN_MARKER\n$payload_text$END_MARKER\nsuffix\n");
    {
        my $text = slurp($f_end);
        my ($begin_pos) = _match_positions($text, $BEGIN_RE);
        my ($not_end_data) = _live_code_checks($text, $begin_pos);
        is($not_end_data, 0, 'fixture: a block pasted after __END__ is caught by the live-code check (M1, not_end_data)');
    }

    my $f_pod = "$tmpdir/pod.pl";
    _write($f_pod, "prefix\n=head1 COLOURS\n$BEGIN_MARKER\n$payload_text$END_MARKER\nsuffix\n");
    {
        my $text = slurp($f_pod);
        my ($begin_pos) = _match_positions($text, $BEGIN_RE);
        my (undef, $pod_balanced) = _live_code_checks($text, $begin_pos);
        is($pod_balanced, 0, 'fixture: an unterminated POD block above the marker is caught by the live-code check (M1, pod_balanced)');
    }

    my $f_pod_closed = "$tmpdir/pod-closed.pl";
    _write($f_pod_closed, "prefix\n=head1 COLOURS\nsome docs\n=cut\n$BEGIN_MARKER\n$payload_text$END_MARKER\nsuffix\n");
    {
        my $text = slurp($f_pod_closed);
        my ($begin_pos) = _match_positions($text, $BEGIN_RE);
        my (undef, $pod_balanced) = _live_code_checks($text, $begin_pos);
        is($pod_balanced, 1, 'fixture: a CLOSED POD block above the marker does not trip the live-code check (M1, pod_balanced, control case)');
    }

    my $f_heredoc = "$tmpdir/heredoc.pl";
    _write($f_heredoc, "prefix\nmy \$doc = <<'EOT';\n$BEGIN_MARKER\n$payload_text${END_MARKER}\nEOT\nsuffix\n");
    {
        my $text = slurp($f_heredoc);
        my ($begin_pos) = _match_positions($text, $BEGIN_RE);
        my (undef, undef, $not_in_heredoc) = _live_code_checks($text, $begin_pos);
        is($not_in_heredoc, 0, 'fixture: a block opening inside a heredoc is caught by the live-code check (M1, not_in_heredoc, best-effort)');
    }

    my $f_clean = "$tmpdir/clean-present.pl";
    _write($f_clean, "prefix\n$BEGIN_MARKER\n$payload_text${END_MARKER}\nsuffix\n");
    {
        my $text = slurp($f_clean);
        my ($begin_pos) = _match_positions($text, $BEGIN_RE);
        my ($not_end_data, $pod_balanced, $not_in_heredoc) = _live_code_checks($text, $begin_pos);
        ok($not_end_data && $pod_balanced && $not_in_heredoc,
            'fixture: an ordinary present block with none of the M1 traps reads clean on all three live-code checks (control case)');
    }
}

# ---------------------------------------------------------------------------
# M2 (redteam.md MEDIUM-2): nothing checks that the marker appears only in
# files the guard scans. Package 05/09 may each reasonably decide to give
# their own file a GENERATED block; the moment they do, that second block is
# unguarded forever -- no test knows it exists, and it drifts silently.
# Membership assertion (not a count): every FILE carrying the BEGIN marker at
# column 0 is either a listed surface, the definer (Theme.pm), or this guard
# file. Scoped to .pl/.pm/.t (where such a marker could plausibly land) and
# excludes .git/ and .ccpraxis-local-data/ (this blueprint's own spec/report
# prose, and the deployed statusline.pl copy, spec §5's documented
# never-scan) to keep the walk bounded and read-only.
# ---------------------------------------------------------------------------
{
    require File::Find;
    my %ALLOWED = map { $_->{path} => 1 } @GENERATED_SURFACES;
    $ALLOWED{'plugins/sandbox/scripts/Theme.pm'}          = 1;   # the definer
    $ALLOWED{'plugins/sandbox/tests/t/64-theme-tokens.t'} = 1;   # this guard
    my @offenders;
    File::Find::find({
        no_chdir => 1,
        wanted   => sub {
            return unless -f $_;
            return unless /\.(?:pl|pm|t)\z/;
            return if $File::Find::name =~ m{[\\/]\.git[\\/]};
            return if $File::Find::name =~ m{\.ccpraxis-local-data[\\/]};
            return if -s $_ > 2_000_000;
            my $bytes = slurp($_);
            return unless defined $bytes;
            return unless $bytes =~ $BEGIN_RE;
            (my $rel = $File::Find::name) =~ s{\A\Q$ROOT\E[\\/]?}{};
            $rel =~ s{\\}{/}g;
            push @offenders, $rel unless $ALLOWED{$rel};
        },
    }, $ROOT);
    ok(!@offenders,
        'repo-wide: the BEGIN GENERATED marker (.pl/.pm/.t only) appears ONLY in a listed surface, the definer, or this guard file -- a block nobody scans drifts forever (M2)')
        or diag('  unlisted file(s) carrying the marker: ' . join(', ', @offenders));
}

{
    my $res = _process_generated_surface($GENERATED_SURFACES[0], $ROOT, undef);
    is($res->{outcome}, 'checked', "$STATUSLINE_REL exists and was read (precondition for B-G9)");
  SKIP: {
        skip("$STATUSLINE_REL missing -- partial checkout, not a drift defect (B-G13's own case)", 2)
            if $res->{outcome} ne 'checked';
      SKIP: {
            skip("$STATUSLINE_REL already carries a GENERATED block -- the authoritative match/mismatch verdict needs Theme::generated_block() and is asserted in the Theme-dependent re-check below (B-G9)", 2)
                if $res->{status} eq 'present';
            is($res->{status}, 'absent', "$STATUSLINE_REL carries no GENERATED block today (B-G9)");
            is($res->{verdict}, 'absent_pending',
                "$STATUSLINE_REL: absent block + pending set -> absent_pending, TODAY's green state (B-G9, AC-16a)")
                or diag('  ' . $GENERATED_SURFACES[0]{pending});
        }
    }
}

{
    my $fixture_surface = { path => 'scripts/does-not-exist-xyz-64.pl', pending => 'n/a' };
    my $res = _process_generated_surface($fixture_surface, $ROOT, undef);
    is($res->{outcome}, 'skip', 'fixture: a GENERATED-surface entry naming a nonexistent file is a skip, not a failure (B-G13)');
}

{
    is(_surface_verdict('absent', 'pending reason', undef, undef), 'absent_pending',
        'fixture: absent + pending -> absent_pending (B-G11)');
    is(_surface_verdict('absent', undef, undef, undef), 'absent_not_pending',
        'fixture: absent + not pending -> absent_not_pending (B-G11)');
    is(_surface_verdict('present', 'pending reason', 'anything', 'anything'), 'pending_but_present',
        'fixture: present + pending -> pending_but_present -- the INVERSE FAILURE arm (B-G10, B-G11)');
    is(_surface_verdict('present', undef, 'X', 'X'), 'match',
        'fixture: present + not pending + payload eq expected -> match (B-G11)');
    is(_surface_verdict('present', undef, 'X', 'Y'), 'mismatch',
        'fixture: present + not pending + payload ne expected -> mismatch (B-G11)');
    is(_surface_verdict('malformed', undef, undef, undef), 'malformed',
        'fixture: malformed (pending undef) -> malformed regardless (B-G11)');
    is(_surface_verdict('malformed', 'pending reason', undef, undef), 'malformed',
        'fixture: malformed (pending set) -> malformed regardless of pending (B-G11)');
}

# ===========================================================================
# A. Module — the load attempt (B-A1) and the bail point. See the file
# header for why this is a guarded runtime require rather than a static use.
# ===========================================================================
my $THEME_OK  = eval { require Theme; Theme->import(); 1 };
my $theme_err = $@;
ok($THEME_OK, 'Theme.pm loads via the "$Bin/../../scripts" @INC entry (B-A1, AC-1)')
    or diag("  require Theme failed: $theme_err");

if ($THEME_OK) {
    is(ref(Theme::roles()), 'HASH', 'Theme::roles() returns a hashref (B-A1)');
} else {
    fail('Theme::roles() returns a hashref (B-A1) -- Theme.pm did not load, nothing further can mean anything');
    BAIL_OUT("Theme.pm failed to load from $THEME_PM ($theme_err) -- per spec section 3-A / B-A1, nothing past "
        . "this point in t/64-theme-tokens.t can mean anything. This IS the correct red for package "
        . "02-design-tokens before Theme.pm is implemented: sections A2 onward (source-purity scan, "
        . "defensive copies, roles, colour maths, the neutral ramp and accent band, glyphs' own-table "
        . "check, capability/degradation, and the Theme-dependent parts of the GENERATED-block guard) "
        . "are all being skipped by this bail rather than reported as false failures against undefined "
        . "behaviour. Everything ABOVE this line ran and reported honestly regardless.");
}

# ===========================================================================
# Everything below this line depends on Theme.pm having loaded successfully.
# It is a no-op today (the BAIL_OUT above already stopped the run) and
# becomes live the moment package 02 lands Theme.pm.
# ===========================================================================

# --- B-A2: source-purity scan -----------------------------------------------
{
    my $src = slurp($THEME_PM);
    ok(defined($src), 'Theme.pm source is readable as text (precondition for B-A2)');
  SKIP: {
        skip('Theme.pm source unreadable', 11) unless defined $src;
        # whole-line `#` comments are stripped before the scan (spec §3-A:
        # "comment prose may discuss them").
        my $scanned = join("\n", map { /^\s*#/ ? '' : $_ } split /\n/, $src, -1);

        unlike($scanned, qr/\buse\s+utf8\b/, 'Theme.pm has no "use utf8" (§2.0 rule 2, B-A2)');
        unlike($scanned, qr/`/, 'Theme.pm source has no backtick spawn construct (B-A2, AC-20)');
        unlike($scanned, qr/\bqx\s*[\{\(\/\#\|]/, 'Theme.pm source has no qx// spawn construct (B-A2, AC-20)');
        unlike($scanned, qr/\bsystem\s*\(/, 'Theme.pm source has no system() call (B-A2, AC-20)');
        unlike($scanned, qr/\bexec\s*\(/, 'Theme.pm source has no exec() call (B-A2, AC-20)');
        unlike($scanned, qr/\bfork\s*\(/, 'Theme.pm source has no fork() call (B-A2, AC-20)');
        unlike($scanned, qr/\breadpipe\s*\(/, 'Theme.pm source has no readpipe() call (B-A2, AC-20)');
        unlike($scanned, qr/\bopen\s*\(|\bopen\s+my\b|\bopen\s+\$/, 'Theme.pm source has no open() file I/O (B-A2, AC-20)');
        unlike($scanned, qr/\bopendir\s*\(/, 'Theme.pm source has no opendir() call (B-A2, AC-20)');
        unlike($scanned, qr/IPC::Open[23]/, 'Theme.pm source has no IPC::Open2/3 (B-A2, AC-20)');

        # every `use` names strict/warnings or a best-effort core-module
        # allow-list; every `require` is the one permitted lazy Dashboard
        # require (§2.0 rule 4) or a core module.
        my %CORE = map { $_ => 1 } qw(strict warnings Encode constant POSIX Carp Exporter List::Util Scalar::Util);
        my @uses = ($scanned =~ /^\s*use\s+([A-Za-z0-9:_]+)/mg);
        my @reqs = ($scanned =~ /^\s*require\s+([A-Za-z0-9:_]+)/mg);
        my $uses_ok = !grep { $_ ne 'strict' && $_ ne 'warnings' && !exists $CORE{$_} } @uses;
        ok($uses_ok, 'every "use" in Theme.pm names strict/warnings or a core module -- no CPAN (B-A2, §2.0 rule 1)')
            or diag('  use targets: ' . join(', ', @uses));
        my $reqs_ok = !grep { $_ ne 'Dashboard' && !exists $CORE{$_} } @reqs;
        ok($reqs_ok, 'every "require" in Theme.pm is the permitted lazy Dashboard require or a core module (B-A2, §2.0 rule 4)')
            or diag('  require targets: ' . join(', ', @reqs));
    }
}

# --- B-A3: loading performs no I/O and reads no %ENV -----------------------
# Asserted INDIRECTLY per spec §3-A's own instruction: a source scan of
# Theme.pm's TOP-LEVEL code (sub bodies stripped) for %ENV / print / warn /
# say / capability(). No STDOUT/STDERR redirection is used here (this host's
# perl breaks on reopening std handles onto an in-memory scalar).
{
    my $src = slurp($THEME_PM);
  SKIP: {
        skip('Theme.pm source unreadable', 3) unless defined $src;
        my $top_level = _strip_sub_bodies($src);
        unlike($top_level, qr/%ENV/, 'Theme.pm: no top-level (outside any sub) reference to %ENV (B-A3, AC-12)');
        unlike($top_level, qr/\bprint\b|\bwarn\b|\bsay\b/, 'Theme.pm: no top-level print/warn/say (B-A3)');
        unlike($top_level, qr/\bcapability\s*\(/, 'Theme.pm: capability() is not called from top level (B-A3, AC-12)');
    }
}

# --- B-A4: defensive copies --------------------------------------------------
{
    my $r1 = Theme::roles();
    my ($some_role) = sort keys %$r1;
    ok(defined $some_role, 'precondition: Theme::roles() returns at least one role (for the defensive-copy check)');
  SKIP: {
        skip('no role to mutate', 2) unless defined $some_role;
        $r1->{$some_role}{rgb}[0] = 254;
        $r1->{__bogus_role__} = { rgb => [1, 2, 3], x256 => 16, attr => '', class => 'body', meaning => 'bogus bogus bogus' };
        my $r2 = Theme::roles();
        isnt($r2->{$some_role}{rgb}[0], 254, "Theme::roles(): mutating a returned nested rgb arrayref does not affect a later call (B-A4)");
        ok(!exists $r2->{__bogus_role__}, 'Theme::roles(): adding a key to a returned hashref does not affect a later call (B-A4)');
    }

    my $g1 = Theme::glyphs();
    my ($some_glyph) = sort keys %$g1;
    ok(defined $some_glyph, 'precondition: Theme::glyphs() returns at least one glyph (for the defensive-copy check)');
  SKIP: {
        skip('no glyph to mutate', 1) unless defined $some_glyph;
        $g1->{$some_glyph}{width} = 99;
        my $g2 = Theme::glyphs();
        isnt($g2->{$some_glyph}{width}, 99, 'Theme::glyphs(): mutating a returned glyph record does not affect a later call (B-A4)');
    }
}

# ===========================================================================
# B. Roles and the call-site API
# ===========================================================================
{
    my $roles = Theme::roles();
    my @REQUIRED_ROLES = qw(text.primary text.muted text.faint rule accent state.ok state.warn state.crit state.idle);
    for my $role (@REQUIRED_ROLES) {
        ok(exists $roles->{$role}, "Theme::roles() includes the required role '$role' (B-B1, AC-2)");
    }

    for my $role (sort keys %$roles) {
        my $rec = $roles->{$role};
        my $rgb_shape_ok = ref($rec->{rgb}) eq 'ARRAY' && @{$rec->{rgb}} == 3;
        ok($rgb_shape_ok, "role '$role': rgb is a 3-element arrayref (B-B2, AC-2)");
        my $rgb_range_ok = $rgb_shape_ok
            && !grep { !defined($_) || $_ !~ /\A\d+\z/ || $_ < 0 || $_ > 255 } @{$rec->{rgb}};
        ok($rgb_range_ok, "role '$role': every rgb channel is an integer 0..255 (B-B2, AC-2)");
        ok((defined($rec->{x256}) && $rec->{x256} =~ /\A\d+\z/ && $rec->{x256} >= 16 && $rec->{x256} <= 255) ? 1 : 0,
            "role '$role': x256 is an integer 16..255 (B-B2, AC-2)");
        ok((defined($rec->{attr}) && grep { $rec->{attr} eq $_ } ('', '1', '2', '7')) ? 1 : 0,
            "role '$role': attr is one of '', '1', '2', '7' (B-B2, AC-2)");
        ok((defined($rec->{class}) && grep { $rec->{class} eq $_ } qw(body large decor)) ? 1 : 0,
            "role '$role': class is one of body/large/decor (B-B2, AC-2)");
        ok((defined($rec->{meaning}) && length($rec->{meaning}) >= 12) ? 1 : 0,
            "role '$role': meaning is >= 12 characters (B-B2, AC-2)");
        like($role, qr/\A[a-z]+(?:\.[a-z]+)*\z/, "role name '$role' matches the dotted-lowercase shape (B-B2, AC-2)");
    }
}

{
    my $roles = Theme::roles();
    for my $role (sort keys %$roles) {
        my $rec = $roles->{$role};

        my $tc = Theme::sgr($role, 'truecolor');
        if (like($tc, qr/\A\e\[38;2;\d{1,3};\d{1,3};\d{1,3}m\z/, "sgr('$role','truecolor') matches the truecolor SGR shape (B-B3, AC-3)")) {
            my ($r, $g, $b) = $tc =~ /\A\e\[38;2;(\d{1,3});(\d{1,3});(\d{1,3})m\z/;
            is_deeply([$r, $g, $b], $rec->{rgb}, "sgr('$role','truecolor') numbers equal the role's rgb (B-B3, AC-3)");
        }

        my $x256 = Theme::sgr($role, '256');
        if (like($x256, qr/\A\e\[38;5;\d{1,3}m\z/, "sgr('$role','256') matches the 256-colour SGR shape (B-B4, AC-13)")) {
            my ($n) = $x256 =~ /\A\e\[38;5;(\d{1,3})m\z/;
            is($n, $rec->{x256}, "sgr('$role','256') number equals the role's x256 (B-B4, AC-13)");
        }

        my $none = Theme::sgr($role, 'none');
        my $expected_none = $rec->{attr} eq '' ? '' : "\e[$rec->{attr}m";
        is($none, $expected_none, "sgr('$role','none') matches the attr-only expectation (B-B5, AC-13)");
        like($none, qr/\A(?:\e\[(?:1|2|7)m)?\z/, "sgr('$role','none') carries no colour parameter of any kind (B-B5, AC-13)");
    }
}

{
    is(Theme::sgr(undef), '', "sgr(undef) returns '' (B-B6, AC-3)");
    is(Theme::sgr(''), '', "sgr('') returns '' (B-B6, AC-3)");
    is(Theme::sgr('no.such.role'), '', "sgr('no.such.role') returns '' (B-B6, AC-3)");

    my $died = !eval { Theme::sgr(undef); 1 };
    ok(!$died, 'sgr(undef) does not die (B-B6, AC-3)');

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, "@_" };
        Theme::sgr(undef);
        Theme::sgr('');
        Theme::sgr('no.such.role');
    }
    is(scalar(@warnings), 0, 'sgr() on undef/empty/unknown role emits no warnings (B-B6, AC-3, fixture count)');

    my $roles = Theme::roles();
    my ($any_role) = sort keys %$roles;
  SKIP: {
        skip('no role available', 1) unless defined $any_role;
        is(Theme::sgr($any_role, 'gibberish'), Theme::sgr($any_role, 'none'),
            "sgr(role, 'gibberish') behaves as 'none' (B-B6, AC-3)");
    }

    is(Theme::reset(), "\e[0m", "Theme::reset() is exactly ESC[0m (B-B7, AC-3)");

  SKIP: {
        skip('no role available', 3) unless defined $any_role;
        is(Theme::paint($any_role, 'x'), Theme::sgr($any_role) . 'x' . Theme::reset(),
            "paint(role,'x') equals sgr(role).text.reset() (B-B8, AC-3)");
        is(Theme::paint($any_role, undef), '', "paint(role, undef) is '' (B-B8, AC-3)");
        is(Theme::paint($any_role, ''), '', "paint(role, '') is '' (B-B8, AC-3)");
    }
    is(Theme::paint('no.such.role', 'x'), 'x', "paint('no.such.role','x') returns 'x' unchanged (B-B8, AC-3)");
}

{
    my $roles = Theme::roles();
    my $hexlike = qr/#[0-9A-Fa-f]{6}/;
    for my $role (sort keys %$roles) {
        for my $cap (qw(truecolor 256 none)) {
            unlike(Theme::sgr($role, $cap), $hexlike, "sgr('$role','$cap') contains no #RRGGBB literal (B-B9, AC-3)");
        }
        unlike(Theme::paint($role, 'x'), $hexlike, "paint('$role','x') contains no #RRGGBB literal (B-B9, AC-3)");
    }
}

# ===========================================================================
# H1 (redteam.md HIGH-1): paint() does not sanitise terminal escapes in
# caller text -- Theme.pm:460-467 is bare concatenation, reopening the
# live-C1/control-byte leak Dashboard.pm's _safe/_safe_char family already
# closed once (redteam-01.md MAJOR-2, Dashboard.pm:279-299, INV-3). paint()
# is the primitive packages 05/09/10 adopt wholesale for exactly this kind of
# untrusted string: container names, git branches, blueprint/session names,
# file paths. Corpus covers, per the dispatch: a raw ESC byte, a CSI
# cursor-move, a CSI screen-clear, an OSC 8 hyperlink, an OSC 0 title-set
# with both BEL and ST terminators, C0 controls (incl. bare CR), DEL, C1
# controls, and zero-width/combining characters. Every case is checked on
# BOTH paint() arms: the coloured arm (the legitimate sgr()/reset() wrapper
# -- which DOES emit ESC -- is stripped first) and the unknown-role
# passthrough arm (no wrapper at all, so the whole string must be clean).
# Corpus values are plain byte strings throughout (ASCII bytes for controls,
# Encode::encode('UTF-8', ...) for the wide C1/zero-width/combining
# codepoints) so there is no ambiguity about decoded-vs-byte-string
# representation feeding into the checks below.
# ===========================================================================
{
    my $roles = Theme::roles();
    my ($h1_role) = sort keys %$roles;

    my @HOSTILE = (
        ['raw ESC byte'                    => "before\x1bafter",                                          qr/\x1b/],
        ['CSI cursor move (ESC[10;20H)'    => "before\x1b[10;20Hafter",                                    qr/\x1b\[10;20H/],
        ['CSI screen clear (ESC[2J)'       => "before\x1b[2Jafter",                                        qr/\x1b\[2J/],
        ['OSC 8 hyperlink, BEL terminator' => "before\x1b]8;;http://evil.example/pwn\x07after",            qr/\x1b\]8;/],
        ['OSC 0 title-set, BEL terminator' => "before\x1b]0;pwned\x07after",                                qr/\x1b\]0;/],
        ['OSC 0 title-set, ST terminator'  => "before\x1b]0;pwned\x1b\\after",                              qr/\x1b\]0;/],
        ['C0 control NUL'                  => "before\x00after",                                            qr/\x00/],
        ['C0 control bare CR'              => "before\rafter",                                              qr/\r/],
        ['C0 control BEL'                  => "before\x07after",                                            qr/\x07/],
        ['DEL (0x7F)'                      => "before\x7fafter",                                            qr/\x7f/],
        ['C1 control NEL (U+0085)'         => "before" . encode('UTF-8', "\x{0085}") . "after",             qr/\xC2\x85/],
        ['C1 control CSI (U+009B)'         => "before" . encode('UTF-8', "\x{009B}") . "after",             qr/\xC2\x9B/],
        ['zero-width space (U+200B)'       => "before" . encode('UTF-8', "\x{200B}") . "after",             qr/\xE2\x80\x8B/],
        ['zero-width joiner (U+200D)'      => "before" . encode('UTF-8', "\x{200D}") . "after",             qr/\xE2\x80\x8D/],
        ['variation selector-16 (U+FE0F)'  => "before" . encode('UTF-8', "\x{FE0F}") . "after",             qr/\xEF\xB8\x8F/],
        ['combining acute accent (U+0301)' => "before" . encode('UTF-8', "\x{0301}") . "after",             qr/\xCC\x81/],

        # --- fix-batch round 2 additions -----------------------------------
        # redteam-01.md MAJOR-2's C1 half, reopened: the FIVE entries above
        # test the UTF-8 ENCODING of a C1 codepoint (2 bytes, e.g. 0xC2 0x9B
        # for U+009B) -- a form that is only dangerous to a terminal reading
        # UTF-8 if the decoder re-derives the single logical character, and
        # which the previous round's own report (test-writer-fixbatch.md
        # "Scaffolding notes") explicitly chose specifically to dodge "bare
        # \x{...} literal" byte/char ambiguity. That dodge is exactly why
        # this next class was never exercised: on the wire, an 8-bit-C1
        # terminal parses these as ONE control BYTE (0x9B, 0x9D, ...), not as
        # the two-byte UTF-8 sequence that encodes that same codepoint. U+009B
        # IS the single-byte CSI introducer -- byte-for-byte equivalent to
        # ESC[ -- so "before\x{9B}2Jafter" is still a screen-clear on any
        # terminal honouring 8-bit controls, and Dashboard.pm:289-299's own
        # comment names this exact class ("the live-C1/control-byte leak").
        #
        # ENCODING LEVEL -- READ BEFORE TOUCHING: every chr($cp) below is used
        # UN-ENCODED, i.e. as a single Perl CHARACTER of that ordinal (never
        # run through Encode::encode). The danger regex is qr/\x{HH}/, an
        # explicit brace-form Unicode codepoint escape -- this ALWAYS matches
        # by character-ordinal value, regardless of "use utf8" and regardless
        # of the target string's internal UTF8 flag, so it cannot pass merely
        # because the leaked byte's storage representation differs from what
        # a byte-pair regex like qr/\xC2\x9B/ (used above) expects. This is a
        # CHARACTER-level assertion throughout, not a byte-level one.
        ['C1 control CSI, raw 8-bit byte (U+009B) -- CSI introducer, byte-for-byte equivalent to ESC['
            => "before" . chr(0x9B) . "after",                                                              qr/\x{9B}/],
        ['C1 control OSC, raw 8-bit byte (U+009D) -- OSC introducer, byte-for-byte equivalent to ESC]'
            => "before" . chr(0x9D) . "after",                                                               qr/\x{9D}/],
        ['C1 control ST, raw 8-bit byte (U+009C) -- string terminator, byte-for-byte equivalent to ESC\\'
            => "before" . chr(0x9C) . "after",                                                               qr/\x{9C}/],
        ['C1 control DCS, raw 8-bit byte (U+0090) -- DCS introducer, byte-for-byte equivalent to ESC P'
            => "before" . chr(0x90) . "after",                                                               qr/\x{90}/],
        ['C1 control NEL, raw 8-bit byte (U+0085) -- next line, byte-for-byte equivalent to ESC E'
            => "before" . chr(0x85) . "after",                                                               qr/\x{85}/],
    );

    for my $case (@HOSTILE) {
        my ($label, $evil, $danger_re) = @$case;

        my $unknown_out = Theme::paint('no.such.role', $evil);
        unlike($unknown_out, $danger_re,
            "paint('no.such.role', evil): $label is neutralised on the unknown-role passthrough arm (H1, redteam-01.md MAJOR-2 regression)");
        unlike($unknown_out, qr/[\x00-\x08\x0B-\x1F\x7F]/,
            "paint('no.such.role', evil): $label -- output carries no C0/DEL control byte at all (H1)");

      SKIP: {
            skip("no role available for the coloured-arm half of '$label'", 2) unless defined $h1_role;
            my $known_out    = Theme::paint($h1_role, $evil);
            my $sgr_prefix   = Theme::sgr($h1_role);
            my $reset_suffix = Theme::reset();
            (my $known_payload = $known_out) =~ s/\A\Q$sgr_prefix\E//;
            $known_payload =~ s/\Q$reset_suffix\E\z//;
            unlike($known_payload, $danger_re,
                "paint('$h1_role', evil): $label is neutralised in the coloured arm too, after stripping the legitimate sgr()/reset() wrapper (H1)");
            unlike($known_payload, qr/[\x00-\x08\x0B-\x1F\x7F]/,
                "paint('$h1_role', evil): $label -- payload (wrapper stripped) carries no C0/DEL control byte (H1)");
        }
    }

    # Width invariant: a caller building a fixed-width layout from
    # Theme::display_width() over untrusted text, then painting that same
    # text, must not have display_width() disagree with what paint() actually
    # renders. Today paint() emits the raw injected bytes verbatim, so what
    # actually reaches the terminal is NOT "before"+"after" (a clean,
    # 12-display-column string) -- it is inflated by whatever of the injected
    # sequence Dashboard::display_width's SGR/bare-ESC-only stripping does
    # not fully remove.
  SKIP: {
        skip('Dashboard.pm did not load', scalar(@HOSTILE)) unless $DASHBOARD_OK;
        my $clean_width = Dashboard::display_width('beforeafter');
        for my $case (@HOSTILE) {
            my ($label, $evil) = @$case;
            my $emitted        = Theme::paint('no.such.role', $evil);
            my $emitted_width  = Dashboard::display_width($emitted);
            is($emitted_width, $clean_width,
                "$label: Dashboard::display_width() of what paint() actually emitted agrees with the clean text's width ($clean_width cols) -- paint() must not leave escape-sequence remnants that inflate the rendered column count a layout built from display_width() would not have reserved space for (H1 width invariant)");
        }
    }

    # Cross-check (do not duplicate policy): Theme's scrub must be AT LEAST
    # AS STRICT as Dashboard's own _safe-family behaviour (INV-3) over this
    # same hostile corpus -- checked here, in the TEST, using Dashboard's
    # PUBLIC sanitizing primitive (Dashboard::clip_pad), never by making
    # Theme.pm call Dashboard at runtime (Theme.pm:91-93's lazy require stays
    # one-directional on purpose; package 06 later inverts it).
  SKIP: {
        skip('Dashboard.pm did not load', scalar(@HOSTILE)) unless $DASHBOARD_OK;
        for my $case (@HOSTILE) {
            my ($label, $evil) = @$case;
            my $dash_w    = Dashboard::display_width($evil);
            my $dash_safe = tui::Frame::clip_pad($evil, $dash_w);
            my $dashboard_flagged_unsafe = ($dash_safe ne $evil) ? 1 : 0;
          SKIP: {
                skip("Dashboard's own sanitizer did not flag '$label' as unsafe -- nothing to cross-check", 1)
                    unless $dashboard_flagged_unsafe;
                my $theme_out = Theme::paint('no.such.role', $evil);
                isnt($theme_out, $evil,
                    "H1 cross-check: Dashboard's own INV-3 sanitizer (Dashboard::clip_pad) neutralises '$label' -- Theme::paint() must be AT LEAST as strict and may not pass it through byte-for-byte raw either (redteam-01.md MAJOR-2, do not reopen one layer up)");
            }
        }
    }

    # -----------------------------------------------------------------------
    # fix-batch round 2: property sweep over the FULL 8-bit C1 range,
    # U+0080-U+009F (ECMA-48 5th ed. table 2 / ISO 6429), not just the five
    # named codepoints above. This exists so a C1 control nobody thought to
    # name individually -- e.g. U+008E SS2, U+008F SS3, U+0091 PU1, U+0098 SOS
    # -- is covered by the SAME property rather than requiring its own row.
    # Every codepoint in this range is a single-byte C1 control on any
    # terminal honouring 8-bit controls, so "no codepoint in U+0080-U+009F
    # survives paint()" is the actual security property; a fixed named list
    # can never fully state it.
    #
    # ENCODING LEVEL: as above, chr($cp) is used UN-ENCODED (one Perl
    # CHARACTER of that ordinal, not run through Encode::encode), and the
    # danger check matches by character content (qr/\Q$ch\E/, i.e. "this
    # exact character", not a byte-pair pattern) -- so, again, a
    # byte/character representation mismatch cannot manufacture a false
    # green here.
    # -----------------------------------------------------------------------
    for my $cp (0x80 .. 0x9F) {
        my $ch      = chr($cp);
        my $evil    = "sweepbefore${ch}sweepafter";
        my $cp_desc = sprintf('U+%04X', $cp);

        my $unknown_out = Theme::paint('no.such.role', $evil);
        unlike($unknown_out, qr/\Q$ch\E/,
            "paint('no.such.role', evil): C1 sweep $cp_desc (8-bit C1 control range U+0080-U+009F) does not survive on the unknown-role passthrough arm (H1 round 2, whole-range property)");

      SKIP: {
            skip("no role available for the coloured-arm half of the C1 sweep ($cp_desc)", 1) unless defined $h1_role;
            my $known_out    = Theme::paint($h1_role, $evil);
            my $sgr_prefix   = Theme::sgr($h1_role);
            my $reset_suffix = Theme::reset();
            (my $known_payload = $known_out) =~ s/\A\Q$sgr_prefix\E//;
            $known_payload =~ s/\Q$reset_suffix\E\z//;
            unlike($known_payload, qr/\Q$ch\E/,
                "paint('$h1_role', evil): C1 sweep $cp_desc (8-bit C1 control range U+0080-U+009F) does not survive in the coloured arm, after stripping the legitimate sgr()/reset() wrapper (H1 round 2, whole-range property)");
        }
    }

    # =========================================================================
    # fix-batch round 3: BYTE-MODE properties for paint()'s scrub step. The
    # round 2 fix made _scrub() do a blind ordinal strip s/[\x80-\x9f]//g.
    # That is correct for a Perl CHARACTER string (proved by the char-mode C1
    # sweep just above, which stays green and is untouched here) but
    # DESTRUCTIVE for a Perl BYTE string, where 0x80-0x9F are commonly
    # CONTINUATION bytes of a multi-byte UTF-8 sequence, not standalone C1
    # controls. Byte strings are the established calling convention for the
    # module that will consume Theme: Dashboard.pm returns
    # Encode::encode('UTF-8', $out) at Dashboard.pm:313 and pushes
    # encoded spans at :446 and :461 -- package 06 wiring Dashboard to Theme
    # is exactly where this fires. This corpus is deliberately a PROPERTY
    # over an input CLASS (every codepoint Theme::glyphs() declares, plus a
    # handful of named non-glyph codepoints), not another enumerated list --
    # a fixed list is exactly what let the char-only and ESC-only corpora
    # miss this defect class twice before.
    #
    # REPRESENTATION, stated explicitly per assertion group below:
    #   - "BYTE-mode round-trip" and "BYTE-mode C1 sweep": every $evil value
    #     is a PERL BYTE STRING -- Encode::encode('UTF-8', chr($cp)) output,
    #     concatenated only with plain ASCII ('before'/'after'/'sweepbefore'/
    #     'sweepafter'), which is representation-identical under latin1 and
    #     utf8 and so does not upgrade the string to a decoded character
    #     string. This is the OPPOSITE representation from the char-mode C1
    #     sweep above (which uses chr($cp) UN-ENCODED on purpose, per that
    #     block's own comment) -- that contrast is the entire point.
    # =========================================================================
    {
        # Corpus: the six codepoints named in the fix-batch dispatch, UNION
        # every codepoint Theme::glyphs() actually declares TODAY -- derived
        # from a live Theme::glyphs() call, not hardcoded, so a glyph added
        # by a later package is covered automatically without editing this
        # file. This builds a list to ITERATE only; nothing below asserts
        # this set's size, so it does not reopen AC-19/Decision 15's NO SHAPE
        # PINS rule.
        my %CP_SET = map { $_ => 1 } (0x2026, 0x2500, 0x2502, 0x65E5, 0xFF5C, 0x00E9);
        my $glyphs_for_corpus = Theme::glyphs();
        $CP_SET{ $glyphs_for_corpus->{$_}{cp} } = 1 for keys %$glyphs_for_corpus;

        for my $cp (sort { $a <=> $b } keys %CP_SET) {
            my $desc          = sprintf('U+%04X', $cp);
            my $encoded_char  = Encode::encode('UTF-8', chr($cp));   # BYTES
            my $evil          = "before${encoded_char}after";        # BYTES throughout

            my $unknown_out = Theme::paint('no.such.role', $evil);
            is($unknown_out, $evil,
                "paint('no.such.role', evil): BYTE-mode round-trip for $desc is byte-identical on the unknown-role passthrough arm -- paint() must not corrupt a UTF-8-encoded non-ASCII byte string (fix-batch round 3, BYTES representation)");

          SKIP: {
                skip("no role available for the coloured-arm half of the byte round-trip ($desc)", 1) unless defined $h1_role;
                my $known_out    = Theme::paint($h1_role, $evil);
                my $sgr_prefix   = Theme::sgr($h1_role);
                my $reset_suffix = Theme::reset();
                (my $known_payload = $known_out) =~ s/\A\Q$sgr_prefix\E//;
                $known_payload =~ s/\Q$reset_suffix\E\z//;
                is($known_payload, $evil,
                    "paint('$h1_role', evil): BYTE-mode round-trip for $desc is byte-identical in the coloured arm too, after stripping the legitimate sgr()/reset() wrapper (fix-batch round 3, BYTES representation)");
            }
        }

        # ---------------------------------------------------------------
        # C1 stripping must ALSO hold in byte mode: the two-byte UTF-8
        # ENCODING of each C1 codepoint (C2 80 .. C2 9F) is what a byte-mode
        # caller would embed, and it must be removed just as reliably as the
        # character-mode form the sweep above already proves. Per the
        # dispatch, this half may land green or red depending on how the
        # blind strip happens to behave on a byte string -- it is recorded
        # either way, not asserted as a hard round-trip like the block
        # above.
        # ---------------------------------------------------------------
        for my $cp (0x80 .. 0x9F) {
            my $desc         = sprintf('U+%04X', $cp);
            my $encoded_char = Encode::encode('UTF-8', chr($cp));  # BYTES: "\xC2" . chr($cp)
            my $evil         = "sweepbefore${encoded_char}sweepafter";

            my $unknown_out = Theme::paint('no.such.role', $evil);
            unlike($unknown_out, qr/\Q$encoded_char\E/,
                "paint('no.such.role', evil): BYTE-mode C1 sweep $desc (encoded as C2 xx) does not survive on the unknown-role passthrough arm (fix-batch round 3, BYTES representation)");

          SKIP: {
                skip("no role available for the coloured-arm half of the byte-mode C1 sweep ($desc)", 1) unless defined $h1_role;
                my $known_out    = Theme::paint($h1_role, $evil);
                my $sgr_prefix   = Theme::sgr($h1_role);
                my $reset_suffix = Theme::reset();
                (my $known_payload = $known_out) =~ s/\A\Q$sgr_prefix\E//;
                $known_payload =~ s/\Q$reset_suffix\E\z//;
                unlike($known_payload, qr/\Q$encoded_char\E/,
                    "paint('$h1_role', evil): BYTE-mode C1 sweep $desc (encoded as C2 xx) does not survive in the coloured arm, after stripping the legitimate sgr()/reset() wrapper (fix-batch round 3, BYTES representation)");
            }
        }
    }
}

# ===========================================================================
# C. Colour maths and contrast
# ===========================================================================
_within(Theme::relative_luminance([0, 0, 0]), 0.0, 1e-9, 'relative_luminance([0,0,0]) == 0 within 1e-9 (B-C1, AC-4)');
_within(Theme::relative_luminance([255, 255, 255]), 1.0, 1e-9, 'relative_luminance([255,255,255]) == 1 within 1e-9 (B-C1, AC-4)');
_within(Theme::relative_luminance([128, 128, 128]), 0.2158, 1e-3, 'relative_luminance([128,128,128]) ~= 0.2158 within 1e-3 (B-C1, AC-4, fixture vector)');
_within(Theme::relative_luminance([5, 5, 5]), 0.001518, 1e-6, 'relative_luminance([5,5,5]) ~= 0.001518 within 1e-6 (B-C1, AC-4, fixture vector)');

_within(Theme::contrast_ratio([255, 255, 255], [0, 0, 0]), 21.0, 1e-6, 'contrast_ratio(white,black) == 21.0 within 1e-6 (B-C2, AC-4)');
is(Theme::contrast_ratio([255, 255, 255], [0, 0, 0]), Theme::contrast_ratio([0, 0, 0], [255, 255, 255]),
    'contrast_ratio is order-independent (B-C2, AC-4)');
_within(Theme::contrast_ratio([100, 100, 100], [100, 100, 100]), 1.0, 1e-9, 'contrast_ratio(x,x) == 1.0 (B-C2, AC-4)');

_within(Theme::lstar([0, 0, 0]), 0.0, 1e-6, 'lstar([0,0,0]) == 0 within 1e-6 (B-C3, AC-4)');
_within(Theme::lstar([255, 255, 255]), 100.0, 1e-6, 'lstar([255,255,255]) == 100 within 1e-6 (B-C3, AC-4)');
_within(Theme::lstar([119, 119, 119]), 50.0, 0.5, 'lstar([119,119,119]) ~= 50.0 within 0.5 (B-C3, AC-4, fixture vector)');

{
    my @bad_rgb = (
        ['not an arrayref (a scalar)' => 'not-an-arrayref'],
        ['wrong length (2 elements)'  => [1, 2]],
        ['wrong length (4 elements)'  => [1, 2, 3, 4]],
        ['non-integer channel'        => [1.5, 2, 3]],
        ['out-of-range channel (256)' => [256, 0, 0]],
        ['out-of-range channel (-1)'  => [-1, 0, 0]],
    );
    for my $fn (qw(relative_luminance lstar)) {
        for my $case (@bad_rgb) {
            my ($label, $bad) = @$case;
            my $sub = \&{"Theme::$fn"};
            my $ok = eval { $sub->($bad); 1 };
            ok(!$ok, "Theme::$fn dies on $label (B-C4, AC-4)");
            like($@, qr/\ATheme: /, "Theme::${fn}'s die message starts 'Theme: ' for $label (B-C4, AC-4)");
        }
    }
    for my $case (@bad_rgb) {
        my ($label, $bad) = @$case;
        my $ok = eval { Theme::contrast_ratio($bad, [0, 0, 0]); 1 };
        ok(!$ok, "Theme::contrast_ratio dies on a malformed first argument: $label (B-C4, AC-4)");
        like($@, qr/\ATheme: /, "Theme::contrast_ratio's die message starts 'Theme: ' for $label (B-C4, AC-4)");
    }
    my @bad_index = (
        ['below range (15)'   => 15],
        ['above range (256)'  => 256],
        ['non-integer (16.5)' => 16.5],
        ['not a number (abc)' => 'abc'],
    );
    for my $case (@bad_index) {
        my ($label, $bad) = @$case;
        my $ok = eval { Theme::x256_rgb($bad); 1 };
        ok(!$ok, "Theme::x256_rgb dies on $label (B-C4, AC-4)");
        like($@, qr/\ATheme: /, "Theme::x256_rgb's die message starts 'Theme: ' for $label (B-C4, AC-4)");
    }
}

{
    my $bg1 = Theme::reference_background();
    is_deeply($bg1, [30, 30, 30], 'Theme::reference_background() is [30,30,30] (B-C5, AC-5)');
    $bg1->[0] = 254;
    my $bg2 = Theme::reference_background();
    is_deeply($bg2, [30, 30, 30], 'mutating the returned reference_background() arrayref does not change the next call (B-C5, AC-5)');
}

{
    my $src = slurp($THEME_PM);
  SKIP: {
        skip('Theme.pm source unreadable', 3) unless defined $src;
        ok($src =~ /#?1E1E1E/i, "Theme.pm's source documents the value #1E1E1E (B-C6, AC-5)");
        ok($src =~ /reference background/i, "Theme.pm's source names it a reference background (B-C6, AC-5)");
        ok($src =~ /assum/i, "Theme.pm's source frames it as an assumption, not a measurement (B-C6, AC-5, §2.4.5)");
    }
}

{
    my %FLOOR = (body => 4.5, large => 3.0, decor => 1.5);
    my $roles = Theme::roles();
    my $bg = Theme::reference_background();
    for my $role (sort keys %$roles) {
        my $rec   = $roles->{$role};
        my $class = $rec->{class};
        my $floor = $FLOOR{ defined($class) ? $class : '' };
      SKIP: {
            skip("role '$role' has an unrecognised class '" . (defined $class ? $class : '<undef>') . "'", 2)
                unless defined $floor;
            my $ratio = Theme::contrast_ratio($rec->{rgb}, $bg);
            cmp_ok($ratio, '>=', $floor,
                sprintf("role '%s' (class %s): contrast against #1E1E1E is >= %.1f:1, floor never equality (got %.3f) (B-C7, AC-6)",
                    $role, $class, $floor, $ratio));

            # H2 (redteam.md HIGH-2): the x256 index is a SECOND, independent,
            # equally real rendering path (spec §2.3's ladder routes every
            # 256-capable terminal through it) -- the truecolor-only check
            # above says nothing about what a 256-colour terminal actually
            # shows. text.faint's x256=240 renders #585858, measuring 2.34:1
            # against the same 3.0:1 'large' floor it clears comfortably
            # (3.50) in truecolor -- illegible on a real, supported terminal
            # while passing every truecolor-only assertion in this suite.
            my $ratio256 = Theme::contrast_ratio(Theme::x256_rgb($rec->{x256}), $bg);
            cmp_ok($ratio256, '>=', $floor,
                sprintf("role '%s' (class %s): 256-rung fallback x256=%d contrast against #1E1E1E is >= %.1f:1, floor never equality (got %.3f) -- the 256 rung is a real rendering path, not a decoration (B-C7 extension, H2, AC-6/AC-13)",
                    $role, $class, $rec->{x256}, $floor, $ratio256));
        }
    }
}

# ===========================================================================
# H2b (reviewer.md M1/S1/S2, redteam.md's own framing of x256 as "declared,
# reviewable, byte-stable" rather than derived): H2 above puts a CONTRAST
# floor on the 256 rung; it says nothing about HUE fidelity. state.ok's x256
# fallback (index 76) renders rgb(95,215,0) -- a lime/yellow-green -- for a
# true medium-green rgb(26,168,74), Euclidean distance 111.6, and STILL
# passes every assertion in this suite (range/distinctness/ordering only).
# Assert a maximum acceptable approximation error, as a CEILING, never an
# exact pin. Neutral-ramp roles (Decision 11's three structural steps, plus
# 'rule' and 'state.idle' which sit outside the accent/hued family) must stay
# ACHROMATIC (r==g==b) -- judged against greys specifically, not the whole
# palette, because the numerically "closest" index to a neutral grey by raw
# distance alone can be a chromatic colour (a teal, per the dispatch's own
# example) that reads as visibly tinted even at a small Euclidean distance.
# ===========================================================================
{
    my %NEUTRAL = map { $_ => 1 } qw(text.primary text.muted text.faint rule state.idle);
    my $GENERAL_CEILING = 50.0;   # catches state.ok(111.6)/accent(71.5); clears the reviewer's own near-optimal fixes (34.1/32.2) with headroom
    my $NEUTRAL_CEILING = 30.0;   # a grey-ramp index against a genuinely-grey truecolor value is always a small distance
    my $roles = Theme::roles();
    for my $role (sort keys %$roles) {
        my $rec = $roles->{$role};
      SKIP: {
            skip("role '$role': rgb is not a well-formed 3-integer arrayref (see B-B2 above)", $NEUTRAL{$role} ? 2 : 1)
                unless ref($rec->{rgb}) eq 'ARRAY' && @{$rec->{rgb}} == 3
                    && !grep { !defined($_) || $_ !~ /\A\d+\z/ } @{$rec->{rgb}};
            my $approx = Theme::x256_rgb($rec->{x256});
            my $dist = sqrt(
                ($approx->[0] - $rec->{rgb}[0])**2 +
                ($approx->[1] - $rec->{rgb}[1])**2 +
                ($approx->[2] - $rec->{rgb}[2])**2
            );
            if ($NEUTRAL{$role}) {
                ok(($approx->[0] == $approx->[1] && $approx->[1] == $approx->[2]) ? 1 : 0,
                    sprintf("role '%s' (neutral ramp): its x256 fallback (index %d -> rgb(%d,%d,%d)) stays ACHROMATIC -- Decision 11's neutral ramp, judged against greys, not the whole palette (H2b)",
                        $role, $rec->{x256}, @$approx));
                cmp_ok($dist, '<=', $NEUTRAL_CEILING,
                    sprintf("role '%s' (neutral ramp): x256 approximation error is <= %.1f (got %.2f) -- a ceiling on error, never an exact pin (H2b)",
                        $role, $NEUTRAL_CEILING, $dist));
            } else {
                cmp_ok($dist, '<=', $GENERAL_CEILING,
                    sprintf("role '%s': x256 index %d (rgb(%d,%d,%d)) approximates truecolor rgb(%d,%d,%d) within %.1f Euclidean units (got %.2f) -- a ceiling on error, not an exact-match pin (H2b, reviewer.md M1/S1)",
                        $role, $rec->{x256}, @$approx, @{$rec->{rgb}}, $GENERAL_CEILING, $dist));
            }
        }
    }
}

is_deeply(Theme::x256_rgb(16),  [0, 0, 0],       'x256_rgb(16) == [0,0,0] (B-C8, AC-4, fixture vector)');
is_deeply(Theme::x256_rgb(231), [255, 255, 255], 'x256_rgb(231) == [255,255,255] (B-C8, AC-4, fixture vector)');
is_deeply(Theme::x256_rgb(232), [8, 8, 8],       'x256_rgb(232) == [8,8,8] (B-C8, AC-4, fixture vector)');
is_deeply(Theme::x256_rgb(255), [238, 238, 238], 'x256_rgb(255) == [238,238,238] (B-C8, AC-4, fixture vector)');
is_deeply(Theme::x256_rgb(196), [255, 0, 0],     'x256_rgb(196) == [255,0,0] (B-C8, AC-4, fixture vector)');

# ===========================================================================
# D. Ramp and accent family
# ===========================================================================
{
    my $roles = Theme::roles();
    my @need = qw(text.primary text.muted text.faint rule);
    my $have_all = !grep { !exists $roles->{$_} } @need;
  SKIP: {
        skip('one or more required roles for the ramp check are missing (see B-B1 above)', 3) unless $have_all;
        my $l_primary = Theme::lstar($roles->{'text.primary'}{rgb});
        my $l_muted   = Theme::lstar($roles->{'text.muted'}{rgb});
        my $l_faint   = Theme::lstar($roles->{'text.faint'}{rgb});
        my $l_rule    = Theme::lstar($roles->{'rule'}{rgb});
        cmp_ok($l_primary - $l_muted, '>=', 8.0, 'lstar(text.primary) - lstar(text.muted) >= 8.0 (B-D1, AC-7)');
        cmp_ok($l_muted - $l_faint, '>=', 8.0, 'lstar(text.muted) - lstar(text.faint) >= 8.0 (B-D1, AC-7)');
        cmp_ok($l_rule, '<', $l_faint, 'lstar(rule) < lstar(text.faint) -- decoration sits below the ramp (B-D2, AC-7)');
    }
}

{
    my @accent_roles = Theme::accent_roles();
    ok(scalar(@accent_roles) > 0, 'accent_roles() returns a non-empty list (B-D3, AC-8)');
    for my $must (qw(accent state.ok state.warn state.crit)) {
        ok((grep { $_ eq $must } @accent_roles) ? 1 : 0, "accent_roles() includes '$must' (B-D3, AC-8)");
    }

    my $roles = Theme::roles();
    for my $ar (@accent_roles) {
        ok(exists $roles->{$ar}, "accent role '$ar' exists in roles() (B-D4, AC-8)");
      SKIP: {
            skip("accent role '$ar' missing from roles()", 1) unless exists $roles->{$ar};
            is($roles->{$ar}{class}, 'body', "accent role '$ar' has class eq 'body' (B-D4, AC-8)");
        }
    }
}

{
    my $band = Theme::accent_lightness_band();
    ok(ref($band) eq 'HASH', 'accent_lightness_band() returns a hashref (B-D5, AC-8)');
  SKIP: {
        skip('accent_lightness_band() did not return a hashref', 3) unless ref($band) eq 'HASH';
        my ($T, $E) = ($band->{target}, $band->{tolerance});
        ok((defined($E) && $E > 0) ? 1 : 0, 'accent_lightness_band().tolerance > 0 (B-D5, AC-8)');
        cmp_ok($E, '<=', 5.0, 'accent_lightness_band().tolerance <= 5.0 -- the ceiling that keeps the band non-vacuous (B-D5, AC-8)');
        ok((defined($T) && $T >= 0 && $T <= 100) ? 1 : 0, 'accent_lightness_band().target is a number in 0..100 (B-D5, AC-8)');

        my @accent_roles = Theme::accent_roles();
        my $roles = Theme::roles();
        for my $ar (@accent_roles) {
          SKIP: {
                skip("accent role '$ar' missing from roles()", 1) unless exists $roles->{$ar};
                my $l = Theme::lstar($roles->{$ar}{rgb});
                cmp_ok(abs($l - $T), '<=', $E,
                    sprintf("accent role '%s': |lstar(%.2f) - target(%.2f)| <= tolerance(%.2f) -- the BAND, never an exact value (B-D6, AC-8)",
                        $ar, $l, $T, $E));
            }
        }
    }
}

# ===========================================================================
# E. Glyphs and emoji — the Theme-dependent remainder (B-E1..B-E5, B-E7..B-E10)
# ===========================================================================
{
    my $glyphs = Theme::glyphs();
    my %REQUIRED_GLYPHS = (
        'rule.h'      => { cp => 0x2500, width => 1 },
        'rule.v'      => { cp => 0x2502, width => 1 },
        'corner.tl'   => { cp => 0x250C, width => 1 },
        'corner.tr'   => { cp => 0x2510, width => 1 },
        'corner.bl'   => { cp => 0x2514, width => 1 },
        'corner.br'   => { cp => 0x2518, width => 1 },
        'sep.bar'     => { cp => 0xFF5C, width => 2 },
        'sep.dot'     => { cp => 0x00B7, width => 1 },
        # RE-POINTED TWICE. First 2026-08-26, when the meter stopped being a
        # full-height block (operator: "can we have blocks that are not full
        # height?") and became 0x2584/0x2581. Then 2026-08-27, when that turned
        # out to solve the wrong half of the problem: every block element is
        # anchored to the cell's top or bottom edge, so a half-height block
        # still sat on the baseline and the bar read as blocks resting on a
        # floor. The operator's words were "they're not vertically centered".
        #
        # 0x2501/0x2500 are box-drawing rules: vertically centred, and spanning
        # the full cell width so consecutive cells fuse into a continuous line
        # rather than showing gaps. 0x2501 is the heaviest centred horizontal
        # rule in the BMP.
        #
        # This table is the INDEPENDENT copy Theme is checked against, so the
        # codepoints move here by hand -- deriving them from Theme would make
        # the comparison circular and the guard useless.
        'gauge.full'  => { cp => 0x2501, width => 1 },
        'gauge.empty' => { cp => 0x2500, width => 1 },
        'scroll.up'   => { cp => 0x25B2, width => 1 },
        'scroll.down' => { cp => 0x25BC, width => 1 },
        'arrow.up'    => { cp => 0x2191, width => 1 },
        'arrow.down'  => { cp => 0x2193, width => 1 },
        'cursor'      => { cp => 0x25B6, width => 1 },
        'status.ok'   => { cp => 0x25CF, width => 1 },
        'status.warn' => { cp => 0x25B3, width => 1 },
        'status.crit' => { cp => 0x00D7, width => 1 },
        'status.idle' => { cp => 0x25CB, width => 1 },
    );
    for my $name (sort keys %REQUIRED_GLYPHS) {
        my $want = $REQUIRED_GLYPHS{$name};
        ok(exists $glyphs->{$name}, "Theme::glyphs() includes the required glyph '$name' (B-E1, AC-9)");
      SKIP: {
            skip("glyph '$name' missing", 2) unless exists $glyphs->{$name};
            is($glyphs->{$name}{cp}, $want->{cp}, sprintf("glyph '%s' codepoint is U+%04X (B-E1, AC-9)", $name, $want->{cp}));
            is($glyphs->{$name}{width}, $want->{width}, "glyph '$name' declared width is $want->{width} (B-E1, AC-9)");
        }
    }
}

{
    my $glyphs = Theme::glyphs();
    for my $name (sort keys %$glyphs) {
        my $g = $glyphs->{$name};
        is(length($g->{char}), 1, "glyph '$name': char is exactly one character (B-E2, AC-9)");
        is(ord($g->{char}), $g->{cp}, "glyph '$name': ord(char) == cp (B-E2, AC-9)");
        is($g->{bytes}, Encode::encode('UTF-8', $g->{char}), "glyph '$name': bytes eq Encode::encode('UTF-8', char) (B-E2, AC-9)");
        ok(($g->{width} == 1 || $g->{width} == 2) ? 1 : 0, "glyph '$name': width is 1 or 2 (B-E2, AC-9)");
        ok((defined($g->{desc}) && length($g->{desc}) >= 3) ? 1 : 0, "glyph '$name': desc is >= 3 characters (B-E2, AC-9)");
        like($name, qr/\A[a-z]+(?:\.[a-z0-9]+)*\z/, "glyph name '$name' matches the required shape (B-E2, AC-9)");
    }
}

{
    my $glyphs = Theme::glyphs();
    my ($any_name) = sort keys %$glyphs;
  SKIP: {
        skip('no glyph available', 2) unless defined $any_name;
        is(Theme::glyph($any_name), $glyphs->{$any_name}{bytes}, "glyph('$any_name') returns bytes (B-E3, AC-9)");
        is(Theme::glyph_width($any_name), $glyphs->{$any_name}{width}, "glyph_width('$any_name') returns width (B-E3, AC-9)");
    }
    is(Theme::glyph('no.such.glyph'), undef, "glyph('no.such.glyph') returns undef (B-E3, AC-9)");
    is(Theme::glyph_width('no.such.glyph'), undef, "glyph_width('no.such.glyph') returns undef (B-E3, AC-9)");
    is(Theme::glyph(undef), undef, 'glyph(undef) returns undef (B-E3, AC-9)');
    is(Theme::glyph_width(undef), undef, 'glyph_width(undef) returns undef (B-E3, AC-9)');
}

{
    my $glyphs = Theme::glyphs();
    my @STATES = qw(status.ok status.warn status.crit status.idle);
    my $have_all = !grep { !exists $glyphs->{$_} } @STATES;
  SKIP: {
        skip('not all four status.* glyphs are declared', 6) unless $have_all;
        for my $i (0 .. $#STATES) {
            for my $j (($i + 1) .. $#STATES) {
                isnt($glyphs->{ $STATES[$i] }{char}, $glyphs->{ $STATES[$j] }{char},
                    "glyph '$STATES[$i]' and '$STATES[$j]' are pairwise-distinct characters (B-E4, AC-14)");
            }
        }
    }
}

{
    my $glyphs = Theme::glyphs();
    for my $name (sort keys %$glyphs) {
        ok(!_is_emoji($glyphs->{$name}{cp}),
            sprintf("glyph '%s' (U+%04X) is not an emoji codepoint (B-E5, AC-10)", $name, $glyphs->{$name}{cp}));
    }
}

{
    # B-E7 CORRECTED for package 06 (driver ruling E-F, packages/06-dashboard-screen.md
    # 2026-08-07T20:40:59Z): the original claim here was "Theme::display_width delegates to
    # Dashboard::display_width". 06's mandate makes Dashboard delegate its OWN width core to
    # tui::Layout, and the driver ruled that merely repointing Theme.pm:395 at
    # `require tui::Layout;` would only trade a Theme<->Dashboard 2-cycle for a
    # Theme<->tui::Layout 2-cycle (tui::Layout does `use Theme;` at compile time for its glyph
    # table) -- not a DAG. So `Theme::display_width` is deleted OUTRIGHT, not repointed: it has
    # exactly one caller in the repository, this assertion. The CLAIM survives unchanged --
    # glyph-width measurement agrees across the width core -- its SUBJECT moves from
    # `Theme::display_width` (now gone) to `tui::Layout::display_width` measured directly
    # against each glyph's own declared width (which is itself Theme's declaration, so this
    # is still a real cross-check, not a tautology against Theme's own table).
    ok(!Theme->can('display_width'),
        "Theme.pm no longer defines display_width -- deleted outright per driver ruling E-F, not repointed to tui::Layout (B-E7)");

    my $LAYOUT_OK = eval { require tui::Layout; 1 };
    ok($LAYOUT_OK, 'plugins/sandbox/scripts/tui/Layout.pm loads (precondition for the corrected B-E7 width-agreement cross-check)')
        or diag("  require tui::Layout failed: $@");

    my $glyphs = Theme::glyphs();
  SKIP: {
        skip('tui::Layout.pm did not load', scalar(keys %$glyphs)) unless $LAYOUT_OK;
        for my $name (sort keys %$glyphs) {
            my $g = $glyphs->{$name};
            is(tui::Layout::display_width($g->{bytes}), $g->{width},
                "glyph '$name': tui::Layout::display_width agrees with Theme's own declared width -- direct measurement, no Theme::display_width/Dashboard delegation involved (B-E7, AC-11; corrected for package 06)");
        }
    }
}

{
    # NEW (correction #5, driver ruling E-F): Theme.pm's source must name no `Dashboard`
    # identifier anywhere -- not `require Dashboard`, not a qualified `Dashboard::` call, not
    # a bare mention -- which is what makes the dependency graph a genuine DAG rather than the
    # "inert 2-cycle" the driver flagged. (The Theme<->tui::Layout `use`-time cycle survives
    # regardless of this assertion; what this closes is the last back-edge OUT of Theme that
    # named Dashboard specifically.)
    my $src = slurp($THEME_PM);
  SKIP: {
        skip('Theme.pm not present on disk', 1) unless defined $src;
        unlike($src, qr/\bDashboard\b/,
            "Theme.pm's source names no 'Dashboard' identifier anywhere -- the last Theme->Dashboard back-edge is gone, not merely repointed (B-E7 cycle-closure, driver ruling E-F)");
    }
}

{
    my $glyphs = Theme::glyphs();
  SKIP: {
        skip('Dashboard.pm did not load', 1) unless $DASHBOARD_OK;

        for my $key (sort keys %PENDING_GLYPH_REGISTRATION) {
            ok(exists $glyphs->{$key},
                "PENDING_GLYPH_REGISTRATION key '$key' names a glyph Theme actually declares (B-E8, AC-11)")
                or diag("  '$key' is not in Theme::glyphs() -- an unknown/stale key, per spec §2.5's verdict table");
        }

        for my $name (sort keys %$glyphs) {
            my $g = $glyphs->{$name};
            my $measured = Dashboard::display_width($g->{bytes});
            my $agrees   = ($measured == $g->{width});
            my $listed   = exists $PENDING_GLYPH_REGISTRATION{$name};
            if ($agrees && !$listed) {
                pass("glyph '$name': declared width agrees with Dashboard::display_width, unlisted -> pass (B-E8, AC-11)");
            } elsif (!$agrees && $listed) {
                pass("glyph '$name': disagrees (declared $g->{width}, measured $measured), listed -> pass with diag (B-E8, AC-11)");
                diag("  $name: declared=$g->{width} measured=$measured -- $PENDING_GLYPH_REGISTRATION{$name}");
            } elsif (!$agrees && !$listed) {
                fail("glyph '$name': declared width $g->{width} disagrees with Dashboard::display_width's $measured, and is NOT listed -- a real defect (B-E8, AC-11)");
            } else {
                fail("glyph '$name': declared width agrees with Dashboard::display_width, but is STILL listed in \%PENDING_GLYPH_REGISTRATION -- STALE ENTRY, delete it (B-E8, AC-11)");
            }
        }
    }
}

{
    my $glyphs = Theme::glyphs();
  SKIP: {
        skip('Dashboard.pm did not load', 1) unless $DASHBOARD_OK;
        my $dt = _dash_glyph_table();
        for my $name (sort keys %$glyphs) {
            my $g = $glyphs->{$name};
          SKIP: {
                skip("glyph '$name' not present in _dash_glyph_table()", 1) unless exists $dt->{ $g->{char} };
                is(tui::Layout::glyph_width($g->{bytes}), $g->{width},
                    "glyph '$name': present in _dash_glyph_table() -- Dashboard::glyph_width agrees with declared width (B-E9, AC-11)");
            }
        }
    }
}

{
    my $glyphs = Theme::glyphs();
  SKIP: {
        skip('Dashboard.pm did not load', 1) unless $DASHBOARD_OK;
        my $dt = _dash_glyph_table();
        for my $char (sort keys %$dt) {
            my $cp = ord($char);
            next if _is_emoji($cp);
            my $dash_width = $dt->{$char};
            my ($match) = grep { $_->{char} eq $char } values %$glyphs;
            ok(defined($match),
                sprintf('_dash_glyph_table() entry U+%04X (non-emoji) is declared in _dash_glyph_table() (B-E10, AC-9)', $cp))
                or diag(sprintf('  U+%04X (Dashboard width %d) has no matching Theme::glyphs() entry', $cp, $dash_width));
          SKIP: {
                skip('no matching Theme glyph to compare width against', 1) unless defined $match;
                is($match->{width}, $dash_width,
                    sprintf('_dash_glyph_table() entry U+%04X width agrees with Theme\'s declared width (B-E10, AC-9)', $cp));
            }
        }
    }
}

# ===========================================================================
# F. Capability and degradation
# ===========================================================================
{
    my @CASES = (
        [{ NO_COLOR => '' },                                       'none',      'NO_COLOR present and empty'],
        [{ NO_COLOR => '1', COLORTERM => 'truecolor' },             'none',      'NO_COLOR wins over COLORTERM (rung 1)'],
        [{ CCPRAXIS_COLOR => '256' },                                '256',       'CCPRAXIS_COLOR=256'],
        [{ CCPRAXIS_COLOR => 'bogus', TERM => 'xterm-256color' },   '256',       'CCPRAXIS_COLOR=bogus falls through to the TERM rung'],
        [{},                                                        'none',      'TERM absent'],
        [{ TERM => 'dumb' },                                        'none',      'TERM=dumb'],
        [{ COLORTERM => '24bit', TERM => 'xterm' },                 'truecolor', 'COLORTERM=24bit'],
        [{ COLORTERM => 'TrueColor', TERM => 'xterm' },             'truecolor', 'COLORTERM=TrueColor (case-insensitive)'],
        [{ WT_SESSION => 'abc', TERM => 'xterm' },                  'truecolor', 'WT_SESSION set (Windows Terminal)'],
        [{ TERM => 'xterm-direct' },                                'truecolor', 'TERM=xterm-direct'],
        [{ TERM => 'screen-256color' },                             '256',       'TERM=screen-256color'],
        [{ TERM => 'xterm' },                                       'none',      'TERM=xterm alone'],
    );
    for my $case (@CASES) {
        my ($env, $want, $label) = @$case;
        is(Theme::detect_capability($env), $want, "detect_capability: $label -> $want (B-F1, AC-12)");
    }
}

{
    my $env = { TERM => 'xterm-256color', FOO => 'bar' };
    my $before = { %$env };
    Theme::detect_capability($env);
    is_deeply($env, $before, 'detect_capability does not mutate the passed hashref (B-F2, AC-12)');

    my %ENV_BEFORE = %ENV;
    Theme::detect_capability(\%ENV);
    is_deeply(\%ENV, \%ENV_BEFORE, 'detect_capability does not mutate %ENV (B-F2, AC-12)');
}

{
    for my $bad (undef, 'x') {
        my $ok = eval { Theme::detect_capability($bad); 1 };
        ok(!$ok, 'detect_capability(' . (defined $bad ? "'$bad'" : 'undef') . ') dies (B-F3, AC-12)');
        like($@, qr/\ATheme: /, "detect_capability's die message starts 'Theme: ' (B-F3, AC-12)");
    }
}

{
    my $c1 = Theme::capability();
    ok((grep { $c1 eq $_ } qw(truecolor 256 none)) ? 1 : 0, 'capability() returns one of the three literals (B-F4, AC-12)');
    my $c2 = Theme::capability();
    is($c2, $c1, 'capability() is stable across repeated calls in one process (B-F4, AC-12)');
}

{
    my $roles = Theme::roles();
    for my $role (sort keys %$roles) {
        for my $cap (qw(truecolor 256 none)) {
            my $s = Theme::sgr($role, $cap);
            ok(defined($s), "sgr('$role','$cap') is defined (B-F5, AC-13)");
            like($s, qr/\A(?:\e\[[0-9;]*m)*\z/, "sgr('$role','$cap') is only SGR sequences, never partial escapes or text (B-F5, AC-13)");
        }
    }
}

{
    my @accent_roles = Theme::accent_roles();
    my $roles = Theme::roles();
    my @x256s = map { $roles->{$_}{x256} } grep { exists $roles->{$_} } @accent_roles;
    my %seen;
    my $all_distinct = 1;
    for my $n (@x256s) { $all_distinct = 0 if $seen{$n}++; }
    ok($all_distinct, 'x256 indices of the accent roles are pairwise distinct (B-F6, AC-13)')
        or diag('  duplicate x256 indices: ' . join(',', grep { $seen{$_} > 1 } keys %seen));
}

{
    my $roles = Theme::roles();
    my @need = qw(text.primary text.muted text.faint);
    my $have_all = !grep { !exists $roles->{$_} } @need;
  SKIP: {
        skip('one or more required roles missing', 1) unless $have_all;
        my $l256 = sub { Theme::lstar(Theme::x256_rgb($roles->{ $_[0] }{x256})) };
        my $lp = $l256->('text.primary');
        my $lm = $l256->('text.muted');
        my $lf = $l256->('text.faint');
        ok(($lp > $lm && $lm > $lf) ? 1 : 0,
            sprintf('256-rung ordering fidelity: L256(primary)=%.2f > L256(muted)=%.2f > L256(faint)=%.2f (B-F7, AC-13)', $lp, $lm, $lf));
    }
}

{
    my $roles = Theme::roles();
    my $have_both = exists($roles->{'text.primary'}) && exists($roles->{'text.muted'});
  SKIP: {
        skip('text.primary/text.muted missing', 1) unless $have_both;
        isnt($roles->{'text.primary'}{attr}, $roles->{'text.muted'}{attr},
            'attr(text.primary) ne attr(text.muted) -- hierarchy survives the no-colour rung (B-F8, AC-14)');
    }
}

# ===========================================================================
# G. The generated block and the drift guard — the Theme-dependent remainder
# ===========================================================================
{
    my $markers = Theme::generated_markers();
    ok(ref($markers) eq 'HASH', 'generated_markers() returns a hashref (B-G1, AC-15)');
  SKIP: {
        skip('generated_markers() did not return a hashref', 6) unless ref($markers) eq 'HASH';
        is($markers->{begin}, $BEGIN_MARKER, 'generated_markers().begin is the exact spec literal (B-G1, AC-15)');
        is($markers->{end}, $END_MARKER, 'generated_markers().end is the exact spec literal (B-G1, AC-15)');
        unlike($markers->{begin}, qr/\n/, 'generated_markers().begin contains no newline (B-G1, AC-15)');
        unlike($markers->{end}, qr/\n/, 'generated_markers().end contains no newline (B-G1, AC-15)');
        like($markers->{begin}, qr/\A[\x20-\x7E]+\z/, 'generated_markers().begin is pure ASCII (B-G1, AC-15)');
        like($markers->{end}, qr/\A[\x20-\x7E]+\z/, 'generated_markers().end is pure ASCII (B-G1, AC-15)');
    }
}

my $theme_generated_block;   # captured here, reused by the read-only surface re-check below
{
    my $block = Theme::generated_block();
    $theme_generated_block = $block;
    ok(defined($block) && length($block) > 0, 'generated_block() returns a non-empty string (precondition, B-G2)');
  SKIP: {
        skip('generated_block() is empty/undef', 4) unless defined($block) && length($block);
        like($block, qr/\n\z/, 'generated_block() ends with a newline (B-G2, AC-15)');
        unlike($block, qr/\r/, 'generated_block() contains no CR (B-G2, AC-15)');
        my @lines = split /\n/, $block, -1;
        pop @lines if @lines && $lines[-1] eq '';
        ok(!(grep { /[ \t]\z/ } @lines), 'generated_block() has no trailing whitespace on any line (B-G2, AC-15)');
        ok(!(grep { $_ eq '' } @lines), 'generated_block() has no blank lines (B-G2, AC-15)');
    }
}

{
    my $b1 = Theme::generated_block();
    my $b2 = Theme::generated_block();
    is($b2, $b1, 'generated_block() is deterministic across two calls (B-G3, AC-15)');
}

{
    my $block = Theme::generated_block();
  SKIP: {
        skip('generated_block() unavailable', 4) unless defined $block;

        my $comment1 = '# THEME TOKENS -- generated from plugins/sandbox/scripts/Theme.pm.';
        my $comment2 = '# Regenerate: perl -Iplugins/sandbox/scripts -MTheme -e "print Theme::generated_block()"';
        my @markers_in_order = ($comment1, $comment2, 'my %THEME_RGB = (', ');', 'my %THEME_X256 = (', ');', 'my %THEME_ATTR = (', ');');
        my $pos = -1;
        my $order_ok = 1;
        for my $m (@markers_in_order) {
            my $idx = index($block, $m, $pos + 1);
            if ($idx <= $pos) { $order_ok = 0; last; }
            $pos = $idx;
        }
        ok($order_ok, 'generated_block(): the two comment lines and the three hash open/close markers appear, in order (B-G4, AC-15)')
            or diag('  expected in order: ' . join(' | ', @markers_in_order));

        my $roles = Theme::roles();
        my @sorted_roles = sort keys %$roles;
        for my $hashname (qw(THEME_RGB THEME_X256 THEME_ATTR)) {
            my ($body) = $block =~ /my \%\Q$hashname\E = \(\n(.*?)\n\);\n/s;
            ok(defined($body), "generated_block(): %$hashname block is present and well-formed (B-G4, AC-15)");
          SKIP: {
                skip("%$hashname body not found", 2) unless defined $body;
                my @body_lines = split /\n/, $body;
                my @names_in_hash = map { /^\s*'([a-z.]+)'/ ? $1 : () } @body_lines;
                is_deeply(\@names_in_hash, \@sorted_roles,
                    "generated_block(): %$hashname lists every role in roles(), in sort order (B-G4, AC-15)");
                my $grammar_re = $hashname eq 'THEME_RGB'  ? qr/\A  '[a-z.]+' => \[\d{1,3},\d{1,3},\d{1,3}\],\z/
                                : $hashname eq 'THEME_X256' ? qr/\A  '[a-z.]+' => \d{1,3},\z/
                                :                              qr/\A  '[a-z.]+' => '(?:|1|2|7)',\z/;
                my @offending = grep { $_ !~ $grammar_re } @body_lines;
                ok(!@offending, "generated_block(): every %$hashname role line matches its grammar regex (B-G4, AC-15)")
                    or diag('  offending line(s): ' . join(' | ', @offending));
            }
        }
    }
}

# ===========================================================================
# M4 (redteam.md MEDIUM-4): generated_block()'s payload is destined for
# scripts/statusline.pl, which is installed as ~/.claude/statusline.pl and
# EXECUTED by Claude Code on every render -- so the payload is executable
# source on the user's machine, and B-G5 below string-evals it in THIS
# process too. B-G4 above only grammar-checks lines strictly inside the
# three hash bodies; a line appended after the final ');' or inserted
# between the two comment lines is matched by nothing. This property held by
# CONSTRUCTION (verified by static tracing, redteam.md's own analysis), not
# by contract, until now.
# ===========================================================================
{
    my $block = Theme::generated_block();
  SKIP: {
        skip('generated_block() unavailable', 2) unless defined $block;

        unlike($block, qr/[^\x20-\x7E\n]/,
            'generated_block() is pure printable ASCII + LF -- no ESC, no C0, no non-ASCII (B-G2 extension, M4, AC-15)');

        my @bad = grep { length }
                  grep { !/\A(?:\#\ .*|my\ \%THEME_(?:RGB|X256|ATTR)\ =\ \(|\);|\ \ '[a-z.]+'\ =>\ (?:\[\d{1,3},\d{1,3},\d{1,3}\]|\d{1,3}|'(?:|1|2|7)'),)\z/ }
                  split /\n/, $block, -1;
        ok(!@bad,
            'generated_block(): EVERY line matches one of the four permitted shapes -- nothing unvalidated reaches an installed executable file (M4, AC-15)')
            or diag('  unpermitted line(s): ' . join(' | ', @bad));
    }
}

{
    my $block = Theme::generated_block();
    my $roles = Theme::roles();
  SKIP: {
        skip('generated_block() unavailable', 4) unless defined $block;

        my $probe = $block
            . '@Scratch64Roundtrip::__RGB{keys %THEME_RGB}   = values %THEME_RGB;' . "\n"
            . '@Scratch64Roundtrip::__X256{keys %THEME_X256} = values %THEME_X256;' . "\n"
            . '@Scratch64Roundtrip::__ATTR{keys %THEME_ATTR} = values %THEME_ATTR;' . "\n"
            . '1;' . "\n";

        my $ok = eval $probe;   ## no critic (BuiltinFunctions::ProhibitStringyEval)
        my $err = $@;
        ok($ok, "generated_block() evals cleanly, exactly as a consumer's own file would (B-G5, AC-15)")
            or diag("  eval error: $err");
      SKIP: {
            skip('eval failed', 3) unless $ok;
            is_deeply(\%Scratch64Roundtrip::__RGB, { map { $_ => $roles->{$_}{rgb} } keys %$roles },
                "eval'd %THEME_RGB matches roles()'s rgb for every role (B-G5, AC-15)");
            is_deeply(\%Scratch64Roundtrip::__X256, { map { $_ => $roles->{$_}{x256} } keys %$roles },
                "eval'd %THEME_X256 matches roles()'s x256 for every role (B-G5, AC-15)");
            is_deeply(\%Scratch64Roundtrip::__ATTR, { map { $_ => $roles->{$_}{attr} } keys %$roles },
                "eval'd %THEME_ATTR matches roles()'s attr for every role (B-G5, AC-15)");
        }
    }
}

{
    my $block = $theme_generated_block;
  SKIP: {
        skip('generated_block() unavailable', 4) unless defined $block;
        my $tmpdir = tempdir(CLEANUP => 1);

        my $f_match = "$tmpdir/match.pl";
        _write($f_match, "prefix\n$BEGIN_MARKER\n$block$END_MARKER\nsuffix\n");
        my ($s1, $p1) = _extract_generated_block(slurp($f_match));
        is($s1, 'present', 'fixture: comparator setup -- synthetic file with real generated_block() payload extracts as present (B-G7, AC-17)');
        is($p1, $block, 'fixture: comparator -- payload exactly equal to generated_block() compares equal (B-G7, AC-17)');

        (my $mutated = $block) =~ s/(\d)/$1 eq '9' ? '8' : '9'/e;
        ok($mutated ne $block, 'fixture setup: the one-digit-changed payload really does differ from generated_block() (B-G7)');
        my $f_mismatch = "$tmpdir/mismatch.pl";
        _write($f_mismatch, "prefix\n$BEGIN_MARKER\n${mutated}${END_MARKER}\nsuffix\n");
        my ($s2, $p2) = _extract_generated_block(slurp($f_mismatch));
        is($s2, 'present', 'fixture: mismatched payload still extracts as present (B-G7)');
        isnt($p2, $block, 'fixture: comparator -- one-digit-changed payload compares unequal (B-G7, AC-17)');

        my @want_lines = split /\n/, $block, -1;
        my @got_lines  = split /\n/, $mutated, -1;
        my $last_idx = ($#want_lines > $#got_lines) ? $#want_lines : $#got_lines;
        my $first_diff;
        for my $i (0 .. $last_idx) {
            my $w = $i <= $#want_lines ? $want_lines[$i] : undef;
            my $g = $i <= $#got_lines  ? $got_lines[$i]  : undef;
            if (!defined($w) || !defined($g) || $w ne $g) { $first_diff = $i + 1; last; }
        }
        ok(defined($first_diff), 'fixture: a first-differing line number is computable between the two payloads (B-G7, AC-17)');
    }
}

{
    my $expected = $theme_generated_block;
    my $res = _process_generated_surface($GENERATED_SURFACES[0], $ROOT, $expected);
  SKIP: {
        skip("$STATUSLINE_REL missing", 6) if $res->{outcome} ne 'checked';
        ok((grep { $res->{verdict} eq $_ } qw(absent_pending absent_not_pending pending_but_present match mismatch malformed)) ? 1 : 0,
            "$STATUSLINE_REL: full §2.7.3 verdict (with the real generated_block() as expected) is one of the six defined outcomes (B-G9, AC-16)")
            or diag('  verdict was: ' . (defined($res->{verdict}) ? $res->{verdict} : '<undef>'));
        diag(sprintf('  %s: status=%s verdict=%s', $STATUSLINE_REL, $res->{status}, $res->{verdict}));

        if ($res->{status} eq 'absent') {
            is($res->{verdict}, 'absent_pending', "$STATUSLINE_REL: still absent+pending today (B-G9, AC-16a)");
        } elsif ($res->{status} eq 'present') {
            isnt($res->{verdict}, 'pending_but_present',
                "$STATUSLINE_REL: a GENERATED block is present -- the pending marker must have been cleared, else this is the INVERSE FAILURE (B-G9, AC-16b)")
                or diag('  package 10 landed the block but did not clear @GENERATED_SURFACES[0]{pending} -- clearing it IS the on-disk proof of landing');
            is($res->{verdict}, 'match',
                "$STATUSLINE_REL: present block byte-exactly matches Theme::generated_block() (B-G9, AC-16)")
                or diag('  the statusline.pl GENERATED block has drifted from Theme.pm\'s canonical output -- regenerate it');
            ok($res->{not_end_data},
                "$STATUSLINE_REL: the GENERATED block is not below __END__/__DATA__ -- it must be live code, not inert text (M1)");
            ok($res->{pod_balanced},
                "$STATUSLINE_REL: no unterminated POD block above the GENERATED block -- POD would swallow it whole (M1)");
            ok($res->{not_in_heredoc},
                "$STATUSLINE_REL: the GENERATED block does not open inside a heredoc (M1, best-effort)");
        } else {
            fail("$STATUSLINE_REL: unexpected block status '$res->{status}' (B-G9)");
        }
    }
}

# --- B-G12/AC-17: read-only, checked last -----------------------------------
SKIP: {
    skip("$STATUSLINE_REL missing at the start of this run", 1) unless defined $statusline_bytes_start;
    is(slurp($STATUSLINE_ABS), $statusline_bytes_start,
        "read-only: ${STATUSLINE_REL}'s bytes are unchanged across the whole t/64 run (B-G12, AC-17)");
}

done_testing();
