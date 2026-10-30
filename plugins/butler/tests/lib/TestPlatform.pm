package TestPlatform;
use strict;
use warnings;

# =============================================================================
# TestPlatform.pm -- the per-file platform declaration this repo's tests will
# eventually carry, and the ONE pure module that turns the leading bytes of a
# file's text into one of exactly three distinguishable outcomes: a legal
# platform (legal_values()), `absent` (no marker found anywhere in the
# scanned prefix), or `invalid` (something marker-shaped but not legal).
#
# Nothing else in the tree consults this yet (blueprint test-platform-split,
# package 01-platform-marker): no `.t` gets a marker added (package 02),
# nothing enforces the marker's presence (package 03), and
# scripts/run-tests.pl is not touched (package 06). This module only makes
# the outcomes mechanically available.
#
# -----------------------------------------------------------------------
# WHY A MARKER AT ALL, AND WHY `absent` MUST NEVER DEFAULT
# -----------------------------------------------------------------------
# scripts/run-tests.pl classifies container tests by what they IMPORT,
# deliberately, so a new one is classified correctly without anybody
# remembering to mark it. This module instead defines an explicit per-file
# tag, because a test's platform NEED is a human intent no import can stand
# in for -- it has to be declared. The two schemes converge on the same
# property (a classifier that cannot silently go stale) by different
# routes: the import scheme makes forgetting structurally impossible; this
# scheme makes a missing/malformed declaration fail LOUDLY instead of
# quietly defaulting (package 03's job, not this module's). That is why
# `value` is defined if and only if `outcome eq 'legal'` -- a parser that
# ever defaulted `absent` to a platform would make package 03's enforcement
# decorative, which is this package's entire reason for existing (done
# criterion 3).
#
# -----------------------------------------------------------------------
# THE MARKER LINE -- exact syntax, pinned byte-for-byte (spec section 2)
# -----------------------------------------------------------------------
# Canonical form: `# platform: host` (also `linux`, `any`). The STRICT
# pattern below requires lowercase `platform`, tolerates whitespace around
# `platform`/`:` and leading indentation before `#`, and permits only
# trailing whitespace plus an optional `\r` after the captured value.
# Legality of the captured value is decided afterwards by exact string
# membership in legal_values() -- never by the regex itself, and never with
# aliasing/case-folding (`Host`, `win`, `host ` are all illegal; the retired value `windows` is
# illegal too, with a rename hint -- see renamed_values()).
#
# A line that is recognisably TRYING to be a marker -- wrong-case keyword,
# or trailing prose after an otherwise-legal value -- but fails the strict
# pattern is caught by a second, deliberately loose, case-insensitive
# pattern, and reported as `invalid`/`malformed-marker-line` rather than
# collapsed into `absent`. This exists because package 03 must be able to
# name THE FIX in its refusal message (its own done criterion 2), and "no
# marker -- add one" is a wrong fix for a file that already has a
# marker-shaped line on screen with the wrong case or extra text.
#
# PRECEDENCE IS PREFIX-WIDE, NOT PER-LINE: the loose pattern is consulted
# ONLY when the strict pattern found zero matches anywhere in the bounded
# prefix. A text with one malformed line and one strictly-valid line is
# `legal`, full stop -- the malformed line is not surfaced in that result at
# all. This is what stops a future "improvement" to the loose pattern from
# ever reclassifying a line that already parses.
#
# -----------------------------------------------------------------------
# THE PREFIX BOUND -- enforced in TWO places that must agree
# -----------------------------------------------------------------------
# prefix_bytes() returns 4096, a plain integer. read_prefix() reads at most
# that many bytes from disk (a single bounded read, never a full-file
# slurp, which is what keeps scanning hundreds of files cheap). parse_marker
# INDEPENDENTLY truncates whatever text it is given to
# substr($text, 0, prefix_bytes()) -- byte semantics, no "use utf8" in this
# file -- before applying either pattern. This makes the bound part of
# parse_marker's own pure contract, testable with a plain in-memory string
# and no fixture file on disk.
#
# -----------------------------------------------------------------------
# ADJUDICATED, NOT FIXED: an in-window marker outranks a real marker beyond
# the bound
# -----------------------------------------------------------------------
# The marker's contract IS "within the first prefix_bytes() bytes"; a line
# beyond the bound is not a marker, by definition, so a decoy inside the
# window winning over a real, contradicting marker past the bound is
# correct behaviour, not a bug -- widening the scan would break done
# criterion 5 (bounded, cheap scanning across hundreds of files). Detecting
# stray marker-shaped lines beyond the bound belongs to package 03's
# hygiene surface, which scans whole files and can afford to -- not here.
# The corpus currently has zero markers in all 345 `.t` files, so package
# 02's backfill cannot collide with a pre-existing out-of-bounds marker.
#
# -----------------------------------------------------------------------
# OUT OF SCOPE: classic-Mac `\r`-only line endings
# -----------------------------------------------------------------------
# Both regexes anchor with /m, which recognises only `\n` as a line
# separator, never a bare `\r`. A file using old-Mac-style `\r`-only line
# endings collapses into effectively one "line" for anchoring purposes, so
# a marker on any line but the first (or one at true end-of-string) is
# invisible. Not supported, deliberately -- classic Mac line endings are
# not a shape this repo's tooling produces or has ever produced.
#
# -----------------------------------------------------------------------
# NEVER DIES, NEVER WARNS -- for any input
# -----------------------------------------------------------------------
# Every failure path (undef input, unreadable file, binary garbage, a
# missing/directory path) returns a value; none of them throw or emit a
# warning. read_prefix() opens the file `:raw` (no `:crlf`, no
# `:encoding(...)`) precisely so no encoding layer can warn or die on
# malformed bytes -- decision D5. The marker regexes tolerate an optional
# trailing `\r` themselves (decision D4) so a marker line is recognised the
# same way whether the file has LF or CRLF endings.
#
# -----------------------------------------------------------------------
# MODULE SHAPE -- matches plugins/sandbox/scripts/Theme.pm's house shape
# -----------------------------------------------------------------------
#   * Core only -- no CPAN.
#   * No Exporter, no default or @EXPORT_OK list. Every call site is fully
#     qualified: TestPlatform::parse_marker($text). Consumers load it with
#     `use TestPlatform ();` after `use lib "$Bin/../lib";`.
#   * Pure logic only. No side effects beyond read_prefix's (read-only) file
#     access.
# =============================================================================

# prefix_bytes() -- the fixed byte bound both read_prefix() and
# parse_marker() enforce. A plain integer, not a config knob: 4096 is a
# safety margin against a pathological file (a huge blob accidentally
# placed above the marker), not a tight fit to a known maximum -- markers
# are expected in the first few lines of a file's header comment, not near
# a 4KB boundary.
sub prefix_bytes {
    return 4096;
}

# legal_values() -- the three legal platform declarations, in this exact
# order, list context. Exists so neither this module's own logic, its test,
# nor any future consumer hardcodes the three strings in more than one
# place.
#
#   host   -- runs on the host, not in the container lane (scripts/run-tests.pl
#             routes it to host-parallel). It does NOT mean "Windows only":
#             on macOS and Linux hosts these files run too. A test that
#             really is Windows-only skips itself (`plan skip_all`) off
#             Windows.
#   linux  -- may run in the Linux container lane when that lane is enabled.
#   any    -- no platform requirement; routes like `linux`.
sub legal_values {
    return ('host', 'linux', 'any');
}

# renamed_values() -- retired marker values and their replacements, as a flat
# (old => new) list. A retired value is NOT an alias: it stays illegal
# (parse_marker reports `invalid`/`unrecognized-value`). The table exists
# only so a refusal message can name the exact fix. `windows` was the
# original name of `host`; it was misleading, because the value means "host
# lane", not "Windows".
sub renamed_values {
    return (windows => 'host');
}

# read_prefix($filepath) -- at most prefix_bytes() bytes of $filepath, read
# in binary mode. '' on ANY failure (undef path, missing file, directory,
# permission denied, zero-byte file) -- decision D7 conflates all of these
# with "empty" deliberately; a caller needing to distinguish them stats the
# path itself before calling this.
sub read_prefix {
    my ($filepath) = @_;
    return '' unless defined $filepath;
    open my $fh, '<:raw', $filepath or return '';
    my $buf = '';
    read($fh, $buf, prefix_bytes());   # short reads are fine; never dies
    close $fh;
    return $buf;
}

# parse_marker($text) -- see the header above for the full contract. Always
# returns a hashref with exactly these four keys: outcome (one of 'legal',
# 'absent', 'invalid'), value (defined iff outcome eq 'legal'), reason
# (defined iff outcome eq 'invalid'; one of 'unrecognized-value',
# 'conflicting-markers', 'malformed-marker-line'), raw (the array of every
# raw match in file order; [] iff outcome eq 'absent').
sub parse_marker {
    my ($text) = @_;
    $text = '' unless defined $text;                  # never die/warn on undef
    my $bounded = substr($text, 0, prefix_bytes());

    # Decision D9 -- strip a single leading UTF-8 BOM (EF BB BF), at byte
    # offset 0 only, before either pattern runs. `^[ \t]*#` cannot consume
    # the BOM's three bytes (they are not tab/space), so a marker that is
    # the very first line of a BOM-prefixed file would otherwise be
    # invisible to BOTH patterns -- not merely misclassified, but silently
    # `absent`, with nothing in `raw` to hint anything was there. This repo
    # has real BOM history (see the project CLAUDE.md on `.ps1` files read
    # as CP1252), so a BOM-prefixed file entering the corpus is a live risk,
    # not a hypothetical. No decoding happens here -- this is a literal
    # three-byte prefix check/strip, keeping the byte-semantic contract.
    substr($bounded, 0, 3) = '' if substr($bounded, 0, 3) eq "\xEF\xBB\xBF";

    # Decision D10 -- if the ORIGINAL text is longer than the bound (the
    # substr above actually cut something off) and the bounded text does not
    # end on a real line boundary (`\n`), drop the trailing partial line
    # before matching. Without this, a value or a whole marker line
    # straddling byte offset prefix_bytes() is fed to `\S+`/`.*?` as a
    # truncated fragment; because Perl's `$` under /m matches true
    # end-of-string too, the fragment still matches in full and produces a
    # captured value that never appears in the real file as a standalone
    # token -- silently FORGING an illegal value into a legal one (or vice
    # versa). A line the bound cut in half is not a line, and a marker is a
    # property of a COMPLETE line -- this is strictly safer than trying to
    # detect "looks truncated", which cannot distinguish a genuinely short
    # final line from a cut one.
    if (length($text) > prefix_bytes() && substr($bounded, -1) ne "\n") {
        my $last_nl = rindex($bounded, "\n");
        $bounded = ($last_nl == -1) ? '' : substr($bounded, 0, $last_nl + 1);
    }

    # THE DECLARATION IS POSITIONAL: it must appear before any heredoc, POD or
    # __DATA__/__END__. Bug 20260916-221455-96a7, both directions.
    #
    # Everything below is line-anchored raw-text matching, which cannot tell
    # code from the inside of a heredoc body, a POD block or a __DATA__ section.
    # That cut BOTH ways and the second way is the one nobody anticipated:
    #
    #   FORGERY  -- a file with no declaration anywhere perl executes, but a
    #               marker-shaped line inside a heredoc, parsed `legal`. Under
    #               package 06's routing that no longer merely guesses a
    #               platform, it SELECTS AN OPERATING SYSTEM.
    #   FALSE CONFLICT -- a file that correctly declares `# platform: host`
    #               at the top and then writes a marker-bearing fixture through
    #               a heredoc (the natural idiom in this suite, since package 02
    #               gave every .t a marker so fixtures need one too) parsed
    #               `invalid/conflicting-markers`: REFUSED and reported red,
    #               with the diagnostic pointing at a line its author never
    #               meant as a declaration.
    #
    # A positional rule fixes both at once and is far easier to explain than any
    # content rule: text after the first heredoc/POD/__DATA__ is not a
    # declaration, so it can neither forge one nor collide with one. Forgery now
    # yields `absent`, which REFUSES LOUDLY -- exactly what Decision 4 asks for
    # and what the old behaviour silently skipped.
    #
    # MEASURED BEFORE SHIPPING, across all 352 .t files in the tree: 352
    # unchanged, 0 changed. The rule is a no-op on the live corpus and only
    # affects the shapes the bug describes.
    $bounded = _code_prefix($bounded);

    my @raw = ($bounded =~ /^[ \t]*#[ \t]*platform[ \t]*:[ \t]*(\S+)[ \t]*\r?$/mg);

    if (@raw) {
        my %uniq = map { $_ => 1 } @raw;
        if (keys %uniq == 1) {
            my $v = $raw[0];
            my %legal = map { $_ => 1 } legal_values();
            return { outcome => 'legal', value => $v, reason => undef, raw => \@raw }
                if $legal{$v};
            return { outcome => 'invalid', value => undef,
                     reason => 'unrecognized-value', raw => \@raw };
        }
        return { outcome => 'invalid', value => undef,
                 reason => 'conflicting-markers', raw => \@raw };
    }

    # No strict match anywhere in the prefix -- and only then -- fall back to
    # the loose, "recognisably trying" pattern before declaring the file
    # markerless. This ordering is the whole precedence rule: it can only
    # ever run when @raw is empty.
    my @loose = ($bounded =~ /^([ \t]*#[ \t]*platform[ \t]*:.*?)\r?$/mgi);
    if (@loose) {
        return { outcome => 'invalid', value => undef,
                 reason => 'malformed-marker-line', raw => \@loose };
    }

    return { outcome => 'absent', value => undef, reason => undef, raw => [] };
}

# _code_prefix($text) -- everything up to, but not including, the first line
# that begins a region perl does not execute as code. PRIVATE.
#
# Deliberately a LINE SCAN rather than a perl parse. A real parse is the only
# way to be exactly right about heredocs, and it is far more surface to get
# subtly wrong than the thing it would fix -- the same reasoning
# guard-git-mutations.sh records for choosing a raw fallback over a quoting
# walk with escape/comment/heredoc sub-states.
#
# The three shapes, and why each is unambiguous enough for a line scan:
#   * `__DATA__` / `__END__` -- must be alone on a line, by perl's own rules.
#   * POD -- begins at `^=` followed by an identifier character, by perl's own
#     rules. `=cut` ends it, but we never resume: a declaration after a POD
#     block is already far past where a marker belongs.
#   * a heredoc INTRODUCER (`<<EOF`, `<<'EOF'`, `<<"EOF"`, `<<~EOF`) anywhere
#     in a line. This is the loose one: `<<` is also left-shift and can appear
#     in a string. Cutting early on a false positive costs a marker that sits
#     BELOW a heredoc introducer -- which yields `absent`, a LOUD refusal, not
#     a silent misclassification. Measured across the tree: no live file has a
#     marker in that position.
sub _code_prefix {
    my ($text) = @_;
    return '' unless defined $text;
    my $offset = 0;
    for my $line (split /(?<=\n)/, $text) {
        return substr($text, 0, $offset)
            if $line =~ /^__(?:DATA|END)__[ \t]*\r?\n?\z/
            || $line =~ /^=[A-Za-z]/
            || $line =~ /<<~?(?:'[^']*'|"[^"]*"|\\?[A-Za-z_]\w*)/;
        $offset += length $line;
    }
    return $text;
}

1;
